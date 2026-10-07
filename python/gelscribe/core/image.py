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
        self.gray = self._to_gray()

    def _to_gray(self) -> np.ndarray:
        """Float 0…1 (0 = black), what analysis and the display mapping work on."""
        a = self.pixels.astype(np.float32)
        if self.is_float:
            lo, hi = float(np.nanmin(a)), float(np.nanmax(a))
            a = (a - lo) / (hi - lo) if hi > lo and (lo < 0 or hi > 1) else a
        else:
            a /= self.scale.max_value
        if a.ndim == 3:
            a = a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722
        return np.clip(np.nan_to_num(a), 0, 1).astype(np.float32)

    def turned(self, q: int) -> "SourceImage":
        """The same file q quarter turns clockwise: pixels reordered, nothing resampled, so Strict allows it."""
        q %= 4
        if q == 0:
            return self
        t = copy.copy(self)
        t.pixels = np.ascontiguousarray(np.rot90(self.pixels, -q, axes=(0, 1)))
        t.gray = np.ascontiguousarray(np.rot90(self.gray, -q))
        return t

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


def percentile_65536(img: np.ndarray, q: float) -> float:
    hist = np.bincount((img * 65535).astype(np.int64).ravel(), minlength=65536)
    target = int(img.size * q / 100)
    acc = np.cumsum(hist)
    idx = np.nonzero(acc > target)[0]
    return float(idx[0]) / 65535 if idx.size else 1.0


def rotated(img: np.ndarray, degrees: float, fill: float) -> np.ndarray:
    """Rotates about the centre (bilinear), keeping the canvas size; uncovered corners get fill. Positive degrees
    turn the picture counter-clockwise on screen."""
    if abs(degrees) <= 1e-6:
        return img
    h, w = img.shape
    t = np.float32(np.radians(degrees))
    c, s = np.float32(np.cos(t)), np.float32(np.sin(t))
    cx, cy = np.float32((w - 1) / 2), np.float32((h - 1) / 2)
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    dx, dy = xs - cx, ys - cy
    sx = c * dx - s * dy + cx
    sy = s * dx + c * dy + cy
    x0, y0 = np.floor(sx).astype(np.int64), np.floor(sy).astype(np.int64)
    ok = (x0 >= 0) & (y0 >= 0) & (x0 < w - 1) & (y0 < h - 1)
    out = np.full(img.shape, fill, dtype=np.float32)
    x0o, y0o = x0[ok], y0[ok]
    fx, fy = sx[ok] - x0o, sy[ok] - y0o
    top = img[y0o, x0o] * (1 - fx) + img[y0o, x0o + 1] * fx
    bot = img[y0o + 1, x0o] * (1 - fx) + img[y0o + 1, x0o + 1] * fx
    out[ok] = top * (1 - fy) + bot * fy
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
    """8-bit gray rendering of crop with the display mapping applied."""
    if crop is not None:
        h, w = img.shape
        r = crop.normalized(w, h)
        x0, y0 = int(np.floor(r.x0 + 0.5)), int(np.floor(r.y0 + 0.5))
        x1, y1 = min(w, int(np.floor(r.x1 + 0.5))), min(h, int(np.floor(r.y1 + 0.5)))
        img = img[y0:max(y0 + 1, y1), x0:max(x0 + 1, x1)]
    return lookup_table(d)[(img * 65535).astype(np.int64)]


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
        pad = padding_mask(img)
        bg = median_4096(img, ~pad)
        img[pad] = bg
        if abs(self.rotation) > 1e-6:
            img = rotated(img, self.rotation, bg)
            probe = rotated(np.zeros(img.shape, np.float32), self.rotation, -1.0)
            moved = rotated(pad.astype(np.float32), self.rotation, 1.0)
            pad = (probe < -0.5) | (moved > 0.5)
            bg = median_4096(img, ~pad)
        self.analysis = img
        self.padding = pad
        self.background = float(bg)
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

    def _processed(self) -> np.ndarray:
        """Non-strict figure pixels: the original gray, old wedges optionally painted, rotated."""
        img = self.source.gray.copy()
        if self.fill_padding_in_figure:
            img[padding_mask(img)] = self.figure_fill
        if abs(self.rotation) > 1e-6:
            img = rotated(img, self.rotation, self.figure_fill)
        return img

    def figure_image(self, project: GelProject) -> np.ndarray:
        """The gel as it goes into the figure. Strict: the original pixels cropped on whole pixels (same values,
        type and channels). Otherwise: fill, rotation and the display mapping applied, as 8-bit gray."""
        r = project.effective_crop(self.width, self.height)
        if project.strict:
            return self.source.pixels[int(r.y0):int(r.y1), int(r.x0):int(r.x1)]
        return render_gray(self._processed(), project.effective_display, r)

    def view_image(self, project: GelProject, enhance: bool = False) -> np.ndarray:
        """Full frame for the editing canvas, as 8-bit gray or RGB. Brightness & contrast always show here; in a
        Strict project they stay on screen (like ImageJ's display range before Apply)."""
        base = self.source.gray if project.strict else self._processed()
        if enhance:
            return render_gray(base, auto_display(base, DisplaySettings(invert=project.display.invert)))
        if project.strict and project.display.is_identity:
            px = self.source.pixels
            if self.source.is_float:
                return render_gray(self.source.gray, DisplaySettings())
            return (px >> 8).astype(np.uint8) if px.dtype == np.uint16 else px
        return render_gray(base, project.display)


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
