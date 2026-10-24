"""Images: the original file exactly as imported (never modified), the float gray copy used for analysis and
display, and the pixels a figure carries.

`SourceImage.pixels` holds the original values in the original type (uint8/uint16/float32, gray or RGB), with
white-is-zero files turned the right way round (value' = max − value), exactly as the Mac app reads them. A Strict
figure carries these pixels, cropped only.
"""
from __future__ import annotations

import copy
import hashlib
import io
import os
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Optional

import numpy as np
from scipy import ndimage

from .model import DisplaySettings, GelProject, PixelRect, ValueScale


class ImageError(Exception):
    pass


# ---------------------------------------------------------------------------------------------------- decoding


def _imagej_range(description: Optional[str]) -> Optional[tuple[float, float]]:
    """"ImageJ=1.54p\\nmin=5.0\\nmax=503.0\\n…" → (5, 503)."""
    if not description or not description.startswith("ImageJ"):
        return None
    lo = hi = None
    for line in description.splitlines():
        k, _, v = line.partition("=")
        try:
            if k.strip() == "min":
                lo = float(v)
            elif k.strip() == "max":
                hi = float(v)
        except ValueError:
            pass
    return (lo, hi) if lo is not None and hi is not None and hi > lo else None


CMYK_MESSAGE = ("This image is in CMYK, a colour format for printing, which GelScribe doesn't support. Convert it to "
                "RGB and open that.")


HEIC_MESSAGE = "HEIC images aren't supported in the Python version. Export the image as PNG or TIFF and open that."
_HEIC_BRANDS = (b"heic", b"heix", b"hevc", b"hevx", b"heim", b"heis", b"mif1", b"msf1")


def _is_heic(data: bytes) -> bool:
    """An ISO base media file whose major brand says HEIC/HEIF (the Mac app reads these, this version doesn't)."""
    return len(data) >= 12 and data[4:8] == b"ftyp" and data[8:12] in _HEIC_BRANDS


def _decode_tiff(data: bytes):
    import tifffile
    with tifffile.TiffFile(io.BytesIO(data)) as tf:
        page = tf.pages[0]
        arr = page.asarray()
        photometric = int(page.photometric)
        if photometric == 5:   # separated: CMYK, a printing format, refused rather than converted
            raise ImageError(CMYK_MESSAGE)
        desc = page.description or ""
        ij = tf.imagej_metadata or {}
        cmap = page.colormap
        planar = int(page.planarconfig) == 2
        samples = page.samplesperpixel
        icc = page.tags.get(34675)   # InterColorProfile
        icc = bytes(icc.value) if icc is not None else None
    if photometric == 3 and cmap is not None:   # palette: look the colours up, as 8-bit gray when they are all gray, else RGB
        table = (cmap >> 8).astype(np.uint8) if cmap.dtype == np.uint16 else cmap.astype(np.uint8)
        if (table[0] == table[1]).all() and (table[1] == table[2]).all():
            arr, photometric = table[0][arr], 1
        else:
            arr, photometric = np.stack([table[c][arr] for c in range(3)], axis=-1), 2
    if planar and arr.ndim == 3 and arr.shape[0] == samples:
        arr = np.moveaxis(arr, 0, -1)
    inverted = photometric == 0
    rng = None
    if "min" in ij and "max" in ij:
        try:
            lo, hi = float(ij["min"]), float(ij["max"])
            rng = (lo, hi) if hi > lo else None
        except (TypeError, ValueError):
            rng = None
    rng = rng or _imagej_range(desc)
    return arr, inverted, rng, icc


def _decode_pil(data: bytes):
    from PIL import Image
    im = Image.open(io.BytesIO(data))
    im.load()
    mode = im.mode
    if mode == "CMYK":
        raise ImageError(CMYK_MESSAGE)
    if mode == "1":
        im, mode = im.convert("L"), "L"
    if mode == "P":   # 8-bit gray when every colour of the palette is gray, else RGB
        pal = im.getpalette() or []
        gray = all(pal[i] == pal[i + 1] == pal[i + 2] for i in range(0, len(pal) - 2, 3))
        im = im.convert("L" if gray else "RGB")
        mode = im.mode
    if mode in ("LA", "La"):
        im, mode = im.getchannel(0), "L"
    if mode in ("RGBA", "RGBa", "RGBX", "CMYK", "YCbCr", "LAB", "HSV"):
        im, mode = im.convert("RGB"), "RGB"
    if mode in ("I;16", "I;16L", "I;16B", "I;16N"):
        arr = np.array(im, dtype=np.uint16)
    elif mode == "I":
        arr = np.array(im, dtype=np.int64)
        arr = arr.clip(0, 65535).astype(np.uint16) if arr.max() > 255 or arr.min() < 0 else arr.astype(np.uint8)
    elif mode == "F":
        arr = np.array(im, dtype=np.float32)
    elif mode in ("L", "RGB"):
        arr = np.array(im, dtype=np.uint8)
    else:
        arr = np.array(im.convert("RGB"), dtype=np.uint8)
    desc = im.info.get("Description") or im.info.get("description")
    icc = im.info.get("icc_profile")
    return arr, False, _imagej_range(desc if isinstance(desc, str) else None), icc if isinstance(icc, bytes) else None


def _is_png16_color(data: bytes) -> bool:
    """A PNG with 16 bits per channel and colour (or gray with transparency), which Pillow would reduce to 8 bits: read
    from its IHDR (bit depth at byte 24, colour type at 25; 2 = RGB, 4 = gray + alpha, 6 = RGBA)."""
    return data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR" and len(data) > 25 and data[24] == 16 and data[25] in (2, 4, 6)


def _decode_png16(data: bytes):
    """Such a PNG at its full 16 bits (imagecodecs; transparency is dropped, as for the 8-bit ones)."""
    import imagecodecs
    from PIL import Image
    arr = imagecodecs.png_decode(data)
    try:
        icc = Image.open(io.BytesIO(data)).info.get("icc_profile")   # known before the pixels are read
    except Exception:   # Pillow can refuse a very large image that was read fine
        icc = None
    return arr, False, None, icc if isinstance(icc, bytes) else None


def _normalise(arr: np.ndarray) -> np.ndarray:
    """Gray (h, w) or RGB (h, w, 3), in uint8, uint16 or float32."""
    if arr.ndim == 3 and arr.shape[-1] in (1, 2):   # gray, or gray + alpha
        arr = arr[..., 0]
    if arr.ndim == 3 and arr.shape[-1] >= 3:
        arr = arr[..., :3]
    if arr.ndim != 2 and not (arr.ndim == 3 and arr.shape[-1] == 3):
        raise ImageError("The image has an unsupported layout.")
    if arr.dtype == np.bool_:
        arr = arr.astype(np.uint8) * 255
    elif arr.dtype in (np.int8,):
        arr = (arr.astype(np.int16) + 128).astype(np.uint8)
    elif arr.dtype == np.int16:
        arr = (arr.astype(np.int32) + 32768).astype(np.uint16)   # signed 16-bit, as ImageJ shows it
    elif arr.dtype == np.float64:
        arr = arr.astype(np.float32)
    elif arr.dtype not in (np.uint8, np.uint16, np.float32):
        arr = arr.astype(np.float32)
    return np.ascontiguousarray(arr)


class SourceImage:
    """The original file, exactly as imported. Never modified; everything else is derived from it."""

    def __init__(self, data: bytes):
        self.data = bytes(data)
        if _is_heic(self.data):
            raise ImageError(HEIC_MESSAGE)
        try:
            if self.data[:4] in (b"II*\x00", b"MM\x00*", b"II+\x00", b"MM\x00+"):
                arr, inverted, rng, icc = _decode_tiff(self.data)
            elif _is_png16_color(self.data):
                arr, inverted, rng, icc = _decode_png16(self.data)
            else:
                arr, inverted, rng, icc = _decode_pil(self.data)
        except ImageError:
            raise
        except Exception as e:   # anything the decoders can't read
            raise ImageError("The file could not be read as an image.") from e
        if arr.dtype.kind == "f":   # their values can't be kept exactly the way integers are
            raise ImageError(f"This image has {arr.dtype.itemsize * 8}-bit floating-point values, which GelScribe doesn't "
                             "support. Export it from your scanner's software as a 16-bit TIFF and open that.")
        if arr.dtype.kind in "iu" and arr.dtype.itemsize >= 4:   # 32-bit integers can't be kept exactly either (or shown as 16-bit)
            raise ImageError(f"This image has {arr.dtype.itemsize * 8}-bit integer values, which GelScribe doesn't support. "
                             "Export it from your scanner's software as a 16-bit TIFF and open that.")
        arr = _normalise(arr)
        #: the embedded colour profile's bytes, if the file has one: Strict stacking needs every gel to have the same
        self.icc_profile: Optional[bytes] = icc
        self.is_float = arr.dtype == np.float32
        self.bits = 32 if self.is_float else (16 if arr.dtype == np.uint16 else 8)
        max_value = 1.0 if self.is_float else float(2 ** self.bits - 1)
        if inverted:   # white-is-zero: the right way round, as the Mac app reads it
            arr = (max_value - arr).astype(arr.dtype) if not self.is_float else (1 - arr).astype(np.float32)
        self.pixels = arr
        self.scale = ValueScale(max_value, inverted)
        self.imagej_range = rng
        self.channels = 1 if arr.ndim == 2 else 3
        self.sha256 = hashlib.sha256(self.data).hexdigest()
        self._color: Optional[np.ndarray] = None
        self.gray = self._to_gray()

    def _unit(self) -> np.ndarray:
        """The pixels as float 0…1 (0 = black), in every channel the file has."""
        a = self.pixels.astype(np.float32)
        if self.is_float:
            lo, hi = float(np.nanmin(a)), float(np.nanmax(a))
            a = (a - lo) / (hi - lo) if hi > lo and (lo < 0 or hi > 1) else a
        else:
            a /= self.scale.max_value
        return a

    def _to_gray(self) -> np.ndarray:
        """Float 0…1 (0 = black), what analysis and the display mapping work on."""
        a = self._unit()
        if a.ndim == 3:
            a = a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722
        return np.clip(np.nan_to_num(a), 0, 1).astype(np.float32)

    @property
    def color(self) -> Optional[np.ndarray]:
        """An RGB image's channels as float 0…1, (h, w, 3), what the figure's colour pixels are made from; None for gray."""
        if self.channels != 3:
            return None
        if self._color is None:
            self._color = np.clip(np.nan_to_num(self._unit()), 0, 1).astype(np.float32)
        return self._color

    def turned(self, q: int) -> "SourceImage":
        """The same file q quarter turns clockwise: pixels reordered, nothing resampled, so Strict allows it."""
        q %= 4
        if q == 0:
            return self
        memo = self.__dict__.setdefault("_turns", {})   # made once: a change of angle turns the same picture again
        if q not in memo:
            t = copy.copy(self)
            t.pixels = np.ascontiguousarray(np.rot90(self.pixels, -q, axes=(0, 1)))
            t.gray = np.ascontiguousarray(np.rot90(self.gray, -q))
            t._color = None   # made again from the turned pixels when wanted
            t._turns = {}
            t.__dict__.pop("_wedges", None)
            memo[q] = t
        return memo[q]

    @property
    def width(self) -> int:
        return self.pixels.shape[1]

    @property
    def height(self) -> int:
        return self.pixels.shape[0]

    @property
    def color_model(self) -> str:
        return "Gray" if self.channels == 1 else "RGB"


# ---------------------------------------------------------------------------------------------------- gray ops


def median_4096(img: np.ndarray, include: Optional[np.ndarray] = None) -> float:
    """Histogram median, exact to 1/4096 (as the Mac app)."""
    v = img if include is None else img[include]
    if v.size == 0:
        return 1.0
    hist = np.bincount((v * 4095).astype(np.int64).ravel(), minlength=4096)
    acc = np.cumsum(hist)
    b = int(np.argmax(acc * 2 >= v.size))
    return b / 4095


def quantized(img: np.ndarray) -> np.ndarray:
    """Float 0…1 as the 16-bit level every display mapping looks up (the value times 65535, truncated)."""
    return np.clip(img * 65535, 0, 65535).astype(np.uint16)


def percentile_65536(img: np.ndarray, q: float) -> float:
    """img: float 0…1, or its 16-bit levels (quantized)."""
    levels = img if img.dtype == np.uint16 else (img * 65535).astype(np.int64)
    hist = np.bincount(levels.ravel(), minlength=65536)
    target = int(img.size * q / 100)
    acc = np.cumsum(hist)
    idx = np.nonzero(acc > target)[0]
    return float(idx[0]) / 65535 if idx.size else 1.0


_POOL: Optional[ThreadPoolExecutor] = None


def _bands(h: int, work, serial_below: int = 1 << 18, pixels: int = 0):
    """work(r0, r1) over bands of rows, on every core (numpy lets go of the GIL), in order; the results as a list."""
    global _POOL
    n = os.cpu_count() or 1
    if n < 2 or pixels < serial_below or h < 4:
        return [work(0, h)]
    if _POOL is None:
        _POOL = ThreadPoolExecutor(max_workers=n, thread_name_prefix="gelscribe-rotate")
    edges = np.linspace(0, h, min(n * 2, h) + 1).astype(int)
    return [f.result() for f in [_POOL.submit(work, int(a), int(b)) for a, b in zip(edges, edges[1:])]]


def _turn(h: int, w: int, degrees: float):
    """The turn of rotated(): its cosine and sine, the centre, and the columns' and rows' offsets from it (float32 all)."""
    t = np.float32(np.radians(degrees))
    c, s = np.float32(np.cos(t)), np.float32(np.sin(t))
    cx, cy = np.float32((w - 1) / 2), np.float32((h - 1) / 2)
    dx = np.arange(w, dtype=np.float32) - cx
    dy = np.arange(h, dtype=np.float32) - cy
    return c, s, cx, cy, dx, dy


def _source_coords(turn, r0: int, r1: int):
    """Where rows r0 up to r1 of the turned picture come from in the original (x and y, float32): the same arithmetic as for
    a whole picture, row by row."""
    c, s, cx, cy, dx, dy = turn
    sx = (c * dx)[None, :] - (s * dy[r0:r1])[:, None] + cx
    sy = (s * dx)[None, :] + (c * dy[r0:r1])[:, None] + cy
    return sx, sy


def rotation_inside(h: int, w: int, degrees: float) -> np.ndarray:
    """Where rotated() takes its pixels from the picture (True) rather than filling: the rest is the corners it uncovers."""
    turn = _turn(h, w, degrees)

    def band(r0, r1):
        sx, sy = _source_coords(turn, r0, r1)
        x0, y0 = np.floor(sx).astype(np.int64), np.floor(sy).astype(np.int64)
        return (x0 >= 0) & (y0 >= 0) & (x0 < w - 1) & (y0 < h - 1)
    return np.concatenate(_bands(h, band, pixels=h * w))


def rotated(img: np.ndarray, degrees: float, fill: float, levels: bool = False) -> np.ndarray:
    """Rotates about the centre (bilinear), keeping the canvas size; uncovered corners get fill. Positive degrees
    turn the picture counter-clockwise on screen. A colour image (h, w, 3) is turned in one pass, every channel as a gray
    one would be (fill: one gray for all, or one for each); the rows are split over the cores. levels: the result as the 16-bit
    levels (quantized) instead, made band by band as it goes."""
    if abs(degrees) <= 1e-6:
        return quantized(img) if levels else img
    h, w = img.shape[:2]
    turn = _turn(h, w, degrees)
    out = np.empty(img.shape, dtype=np.uint16 if levels else np.float32)
    flat = img.reshape(h * w, *img.shape[2:])
    filled = np.asarray(fill, dtype=np.float32)

    def band(r0, r1):
        sx, sy = _source_coords(turn, r0, r1)
        x0, y0 = np.floor(sx).astype(np.int64), np.floor(sy).astype(np.int64)
        ok = (x0 >= 0) & (y0 >= 0) & (x0 < w - 1) & (y0 < h - 1)
        x0o, y0o = x0[ok], y0[ok]
        fx, fy = sx[ok] - x0o, sy[ok] - y0o
        at = y0o * w + x0o
        if img.ndim == 3:
            fx, fy = fx[:, None], fy[:, None]
        top = flat[at] * (1 - fx) + flat[at + 1] * fx
        bot = flat[at + w] * (1 - fx) + flat[at + w + 1] * fx
        piece = np.empty((r1 - r0,) + img.shape[1:], dtype=np.float32)
        piece[...] = filled
        piece[ok] = top * (1 - fy) + bot * fy
        out[r0:r1] = quantized(piece) if levels else piece
    _bands(h, band, pixels=h * w)
    return out


_CROSS = ndimage.generate_binary_structure(2, 1)


def padding_mask(img: np.ndarray, tol: float = 1 / 255, min_pixels: int = 500) -> np.ndarray:
    """The flat wedges left in the corners when an image was rotated before export, dilated by 3 px.

    A wedge is a perfectly flat region that contains an image corner and whose value differs from the image's most
    common value (contrast-stretched exports often clip the gel background itself to one flat value reaching the
    corners, and that is gel, not padding)."""
    h, w = img.shape
    mask = np.zeros(img.shape, dtype=bool)
    if w <= 2 or h <= 2:
        return mask
    hist = np.bincount(np.floor(img * 255 + 0.5).astype(np.int64).ravel(), minlength=256)
    mode = float(np.argmax(hist)) / 255
    seen = np.zeros(img.shape, dtype=bool)
    for (y, x) in [(0, 0), (0, w - 1), (h - 1, 0), (h - 1, w - 1)]:
        if seen[y, x]:
            continue
        v = img[y, x]
        if abs(v - mode) <= 8 / 255:
            continue   # the background itself, even if flat
        near = np.abs(img - v) <= tol
        lab, _ = ndimage.label(near, structure=_CROSS)
        region = lab == lab[y, x]
        seen |= region
        if int(region.sum()) >= min_pixels:
            mask |= region
    if mask.any():
        mask = ndimage.binary_dilation(mask, structure=_CROSS, iterations=3)
    return mask


def lookup_table(d: DisplaySettings) -> np.ndarray:
    """65536-entry map from source value to 8-bit output: every 16-bit level keeps its own entry."""
    lo, hi = d.black, max(d.white, d.black + 1e-9)
    v = (np.arange(65536, dtype=np.float64) / 65535 - lo) / (hi - lo)
    v = np.clip(v, 0, 1)
    if d.gamma != 1:
        v = v ** (1 / d.gamma)
    if d.invert:
        v = 1 - v
    return np.floor(v * 255 + 0.5).astype(np.uint8)


def render_gray(img: np.ndarray, d: DisplaySettings, crop: Optional[PixelRect] = None) -> np.ndarray:
    """8-bit rendering of crop with the display mapping applied: gray, or RGB for a (h, w, 3) image, each channel mapped
    the way a gray one is. img: float 0…1, or its 16-bit levels (quantized), which skip the float work."""
    if crop is not None:
        h, w = img.shape[:2]
        r = crop.normalized(w, h)
        x0, y0 = int(np.floor(r.x0 + 0.5)), int(np.floor(r.y0 + 0.5))
        x1, y1 = min(w, int(np.floor(r.x1 + 0.5))), min(h, int(np.floor(r.y1 + 0.5)))
        img = img[y0:max(y0 + 1, y1), x0:max(x0 + 1, x1)]
    lv = img if img.dtype == np.uint16 else quantized(img)
    table = lookup_table(d)
    if lv.size < (1 << 21):
        return np.take(table, lv)
    out = np.empty(lv.shape, dtype=table.dtype)   # a big picture: the rows split over the cores
    _bands(lv.shape[0], lambda r0, r1: np.take(table, lv[r0:r1], out=out[r0:r1]), pixels=lv.size)
    return out


def auto_display(img: np.ndarray, keeping: DisplaySettings) -> DisplaySettings:
    """Levels spanning the 0.1–99.9th percentile, for 16-bit scans that arrive nearly black."""
    d = DisplaySettings(keeping.black, keeping.white, keeping.gamma, keeping.invert, keeping.bands_dark)
    d.black, d.white = percentile_65536(img, 0.1), percentile_65536(img, 99.9)
    if d.white - d.black < 1e-5:
        d.black, d.white = 0.0, 1.0
    return d


# ---------------------------------------------------------------------------------------------------- working image


@dataclass
class GelStats:
    """The gel's values inside the crop, padding left out: what brightness & contrast work from."""
    range: tuple[float, float]
    auto: tuple[float, float]
    counts: np.ndarray


class WorkingImage:
    """What detection works on, plus the pixels the figure shows.

    Analysis always fills padding (so wedge edges don't read as bands) and zeroes it in the darkness map. Whether any
    of that reaches the figure is up to the project: in Strict mode the figure gets the original pixels, cropped."""

    def __init__(self, source: SourceImage, project: GelProject):
        source = source.turned(project.turn)   # lossless, so before everything, Strict or not
        self.source = source
        self.strict = project.strict
        self.rotation = project.effective_rotation
        self.fill_padding_in_figure = project.effective_fill_padding
        img = source.gray.copy()
        wedges = source.__dict__.get("_wedges")   # the old wedges and the background of the original: the same for every angle
        if wedges is None:
            pad = padding_mask(img)
            wedges = source._wedges = (pad, median_4096(img, ~pad))
        pad, bg = wedges
        img[pad] = bg
        self._pad0 = pad   # the old wedges of the original, for the figure's pixels (see _processed)
        if abs(self.rotation) > 1e-6:
            img = rotated(img, self.rotation, bg)
            outside = ~rotation_inside(img.shape[0], img.shape[1], self.rotation)   # the corners it uncovered
            moved = rotated(pad.astype(np.float32), self.rotation, 1.0) > 0.5 if pad.any() else outside
            pad = outside | moved
            bg = median_4096(img, ~pad)
        self.analysis = img
        self.padding = pad
        self.background = float(bg)
        self._levels: dict = {}   # the 16-bit levels of the pixels each display mapping looks up, made once (see levels)
        self.figure_fill = {"background": self.background, "white": 1.0}.get(
            project.fill_mode, float(min(1, max(0, project.fill_value))))

    @property
    def width(self) -> int:
        return self.analysis.shape[1]

    @property
    def height(self) -> int:
        return self.analysis.shape[0]

    def gel_stats(self, crop: PixelRect, bins: int = 256) -> GelStats:
        r = crop.normalized(self.width, self.height)
        x0, y0 = int(np.floor(r.x0 + 0.5)), int(np.floor(r.y0 + 0.5))
        x1, y1 = min(self.width, int(np.floor(r.x1 + 0.5))), min(self.height, int(np.floor(r.y1 + 0.5)))
        sub = self.analysis[y0:y1, x0:x1]
        keep = ~self.padding[y0:y1, x0:x1]
        vals = sub[keep]
        if vals.size == 0:
            return GelStats((0.0, 1.0), (0.0, 1.0), np.zeros(bins, dtype=np.int64))
        fine = np.bincount((vals * 65535).astype(np.int64), minlength=65536)
        nz = np.nonzero(fine)[0]
        lo, hi = int(nz[0]), int(nz[-1])
        acc = np.cumsum(fine)
        n = vals.size

        def pct(q):
            idx = np.nonzero(acc > int(n * q / 100))[0]
            return int(idx[0]) if idx.size else hi

        levels = float((1 << min(max(self.source.bits if not self.source.is_float else 16, 1), 16)) - 1)
        bins = max(1, min(bins, int(np.floor((hi - lo) / 65535 * levels + 0.5)) + 1))
        span = float(max(hi - lo, 1))
        idx = np.arange(lo, hi + 1)
        f = fine[lo:hi + 1]
        b = np.minimum(bins - 1, ((idx - lo) / span * bins).astype(np.int64))
        counts = np.bincount(b, weights=f, minlength=bins).astype(np.int64)
        a, z = pct(0.1), max(pct(99.9), pct(0.1) + 1)
        return GelStats((lo / 65535, max(hi, lo + 1) / 65535), (a / 65535, z / 65535), counts)

    def darkness(self, bands_dark: bool) -> np.ndarray:
        """Signal strength on a 0…255 scale (bands positive), padding zeroed. A faint scan (a 16-bit gel using a
        sliver of its range) is scaled up so snapping sees its bands; gels spanning half the scale or more aren't."""
        st = self.gel_stats(PixelRect(0, 0, self.width, self.height), bins=1)
        gain = max(1.0, 0.5 / max(st.auto[1] - st.auto[0], 1e-6))
        d = (self.background - self.analysis) if bands_dark else (self.analysis - self.background)
        out = np.maximum(0, d) * 255 * gain
        out[self.padding] = 0
        return out.astype(np.float32)

    def _processed(self, color: bool = False, levels: bool = False) -> np.ndarray:
        """Non-strict figure pixels: the original gray, old wedges optionally painted, rotated. color: an RGB image's
        channels instead (same wedges, same rotation, same fill), else the gray copy every analysis uses."""
        img = self.source.color.copy() if color and self.source.color is not None else self.source.gray.copy()
        if self.fill_padding_in_figure:
            img[self._pad0] = self.figure_fill
        if abs(self.rotation) > 1e-6:
            return rotated(img, self.rotation, self.figure_fill, levels)
        return quantized(img) if levels else img

    def levels(self, color: bool = False, original: bool = False) -> np.ndarray:
        """The figure's pixels (processed: fill and rotation done; or original: the source as it is) as 16-bit levels, gray or
        for color an (h, w, 3) array. Made on first use and kept, so a change of display range is one table lookup."""
        key = (color, original)
        if key not in self._levels:
            if original:
                f = self.source.color if color else self.source.gray
            else:
                f = self._processed(color=color, levels=True)
            self._levels[key] = f if f.dtype == np.uint16 else quantized(f)
        return self._levels[key]

    def figure_image(self, project: GelProject) -> np.ndarray:
        """The gel as it goes into the figure. Strict: the original pixels cropped on whole pixels (same values,
        type and channels). Otherwise: fill, rotation and the display mapping applied, as 8-bit gray, or 8-bit RGB for a
        colour image."""
        r = project.effective_crop(self.width, self.height)
        if project.strict:
            return self.source.pixels[int(r.y0):int(r.y1), int(r.x0):int(r.x1)]
        return render_gray(self.levels(color=self.source.channels == 3), project.effective_display, r)

    def view_image(self, project: GelProject, enhance: bool = False) -> np.ndarray:
        """Full frame for the editing canvas, as 8-bit gray or RGB. Brightness & contrast always show here; in a
        Strict project they stay on screen (like ImageJ's display range before Apply)."""
        rgb = self.source.channels == 3   # a colour image stays in colour, whatever the display range does to it
        if enhance:   # the levels come from the gray copy, as for analysis
            shown = self.levels(color=rgb, original=project.strict)
            base = self.levels(original=project.strict) if rgb else shown
            return render_gray(shown, auto_display(base, DisplaySettings(invert=project.display.invert)))
        if project.strict and project.display.is_identity:
            px = self.source.pixels
            if self.source.is_float:
                return render_gray(self.source.gray, DisplaySettings())
            return (px >> 8).astype(np.uint8) if px.dtype == np.uint16 else px
        return render_gray(self.levels(color=rgb, original=project.strict), project.display)


def initial_display(w: WorkingImage) -> DisplaySettings:
    """Where brightness & contrast start for a new image, the way ImageJ opens it: the range ImageJ saved in the
    file, else for 16-bit images their darkest to brightest value, else unchanged."""
    d = DisplaySettings()
    if w.source.imagej_range is not None:
        d.set_range(w.source.imagej_range[0], w.source.imagej_range[1], w.source.scale)
    elif w.source.bits > 8:
        lo, hi = w.gel_stats(PixelRect(0, 0, w.width, w.height)).range
        if hi > lo:
            d.black, d.white = lo, hi
    return d
