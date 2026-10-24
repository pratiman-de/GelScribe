"""Drawing the figure on screen and writing it out as PDF, PNG, TIFF and SVG.

Strict exports carry the gel's original pixels: raster files are composed with the gel pasted in unscaled on whole
pixels (never redrawn), and the PDF gets the original samples written straight into its image, so 16-bit gels stay
16-bit everywhere. Every file records how it was made (PDF Subject, PNG Description, TIFF ImageDescription, SVG desc).
"""
from __future__ import annotations

import base64
import io
import math
import struct
import zlib
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Optional

import numpy as np

from .image import ImageError
from .layout import TEXT_SCALE, FigureLayout, FigureText, ensure_gui, qfont
from .model import GelProject, PixelRect, ValueScale, format_size, sround

#: what a figure that can't be put together says (the same on the Mac): never a blank gel, never a crash
FIGURE_TOO_LARGE = "The figure is too large to make. Crop the gels or lower the export resolution."
#: the biggest raster a figure is drawn as, as on the Mac: a longer side, or more pixels altogether, is refused
MAX_SIDE = 100_000
MAX_PIXELS = 500_000_000


def check_raster_size(width: int, height: int) -> None:
    """Raises ImageError(FIGURE_TOO_LARGE) for a raster that is empty, has a side over MAX_SIDE or more than MAX_PIXELS
    pixels, before any memory is asked for."""
    if not (0 < width <= MAX_SIDE and 0 < height <= MAX_SIDE and width * height <= MAX_PIXELS):
        raise ImageError(FIGURE_TOO_LARGE)


@contextmanager
def figure_memory():
    """Putting a figure together that needs more memory than there is is the "too large" error, not a crash."""
    try:
        yield
    except MemoryError:
        raise ImageError(FIGURE_TOO_LARGE) from None


# ---------------------------------------------------------------------------------------------------- provenance


@dataclass
class ExportInfo:
    title: str
    #: provenance written into the file
    description: str


#: the headline when some gels keep their original pixels and some don't (the per-gel list tells which)
MIXED_PIXELS = ("Gel pixels: mixed. Some gels keep their original values and some were changed; "
                "see each gel below.")


def changed_warnings(p: GelProject, shas: list, names: bool = True) -> list[str]:
    """One line per gel, top to bottom, whose image no longer matches the SHA-256 taken when it was added, for the note
    and for the warning before an export. shas: each image's SHA-256 now, the lanes gel's first and then the stacked gels'
    in strips order (None for one that isn't known; a gel with no recorded fingerprint is never reported). names: say
    which file (a note leaves the file names out when the project says so)."""
    out = []
    for k in p.stack_order:
        recorded = p.image_sha256 if k is None else p.strips[k - 1].image_sha256
        i = 0 if k is None else k
        if recorded is not None and i < len(shas) and shas[i] is not None and shas[i] != recorded:
            name = p.image if k is None else p.strips[k - 1].image
            out.append(f"Warning: Gel {p.position_of(k) + 1}'s image{f' ({name})' if names else ''} has changed since it "
                       "was added; its SHA-256 no longer matches.")
    return out


COPIED_NOTE = "original values, copied to all three channels"


def export_info(p: GelProject, source_sha256: Optional[str], resampled_dpi: Optional[float] = None,
                native_dpi: Optional[float] = None, scale: Optional[ValueScale] = None,
                strips: list = (), size: Optional[tuple[int, int]] = None, storage: Optional[str] = None,
                changed: list = (), unconverted: list = (),
                copied: list = ()) -> ExportInfo:
    """strips: each stacked gel's (sha256, value scale) or (sha256, value scale, (width, height)), in strips order. size:
    the working image's width and height, and likewise each gel's, so the note can give the crop and rows that were
    actually used (clamped to the image); without them it gives them as stored. storage: the format the gels that
    don't keep their original pixels are converted to (strips.converted_storage): that of the ones kept when some do
    ("16-bit gray"), else "8-bit gray" or "8-bit RGB"; for a single adjusted colour image "8-bit RGB" when it was not
    that already. changed: the lines of changed_warnings, which the note starts with. unconverted: the gels (0 the one with
    the lanes, then the stacked ones) that were in storage's format already, which the note doesn't say were converted.
    copied: the gels that keep their original gray values in a colour figure, which the note says are copied to all three
    channels."""
    if p.crop is None:
        c = "full frame"
    else:
        k = p.crop
        r = (p.effective_crop(*size) if size is not None
             else PixelRect(math.floor(min(k.x0, k.x1)), math.floor(min(k.y0, k.y1)),
                            math.ceil(max(k.x0, k.x1)), math.ceil(max(k.y0, k.y1))))
        c = f"crop {int(r.x0)},{int(r.y0)},{int(r.x1)},{int(r.y1)}"
    if p.turn % 4:
        c = f"turned {p.turn % 4 * 90}°, {c}"
    if scale is not None:
        lo, hi = p.display.range_in(scale)
        levels = f"display range {scale.format(lo)}–{scale.format(hi)} of {scale.format(scale.max_value)}"
    else:
        levels = f"levels {p.display.black}–{p.display.white}"
    adjusted = (f"rotation {float(p.rotate_deg)}°, {levels}, gamma {float(p.display.gamma)}"
                + (", inverted" if p.display.invert else ""))
    keeps = [p.is_strict(k) for k in [None, *range(1, len(p.strips) + 1)]]   # the lanes gel, then the others
    mixed = any(keeps) and not all(keeps)   # the lanes gel's setting alone says nothing about the others
    if storage and not p.strips and not p.strict:   # an adjusted colour image stored as 8-bit RGB
        adjusted = adjusted + f", converted to {storage}"
    pixels = (MIXED_PIXELS if mixed else
              f"Gel pixels: original values, bit depth and color space, not resampled (strict); {c}." if p.strict
              else f"Gel pixels: adjusted ({adjusted}); {c}.")
    if resampled_dpi is not None:
        frm = f" from {int(math.floor(native_dpi + 0.5))} dpi" if native_dpi is not None else ""
        dpi = int(math.floor(resampled_dpi + 0.5))
        pixels = (f"{MIXED_PIXELS} Resampled to {dpi} dpi{frm}; {c}." if mixed else
                  f"Gel pixels: resampled to {dpi} dpi{frm}"
                  + (", otherwise unadjusted" if p.strict else f" after adjustments ({adjusted})") + f"; {c}.")
    names = p.export_file_names   # off: no gel's file name is written into the file; the fingerprints are
    hsh = (f" Source {p.image} sha256 {source_sha256}." if names else f" Source sha256 {source_sha256}.") if source_sha256 else ""
    ladder = ""
    if p.ladder is not None and p.ladder.name:
        ladder = f" Ladder: {p.ladder.name}" + (f", apparent sizes for {p.ladder.system}" if p.ladder.system else "") + "."
    pieces = ""
    if p.strips:
        pieces = f" {len(p.strips) + 1} separately scanned gels, {"left to right" if p.is_side_by_side else "top to bottom"}, with a {p.separator} line between each:"
        # what converting into the output's storage did: 8-bit values times 257 for 16-bit
        conversion = f"converted to {storage}" + (" (values times 257)" if storage.startswith("16-bit") else "") if storage else None
        for n, k in enumerate(p.stack_order):
            if k is None:
                main = "the reference for vertical placement" if p.is_side_by_side else "as above (its lanes are the figure's)"
                if mixed and p.strict and 0 in copied:   # (as the Mac app orders it: this comes first)
                    main += f", {COPIED_NOTE}"
                if mixed and p.turn % 4:   # the headline that said so is the mixed one now
                    main += f", turned {p.turn % 4 * 90}°"
                if mixed and not p.strict:   # and so is the one that said what was done to this gel's pixels
                    main += f", {adjusted}"
                if size is not None:   # the kept rectangle, as the figure took it
                    r = p.effective_crop(*size)
                    main += f", columns {int(r.x0)}–{int(r.x1)}, rows {int(r.y0)}–{int(r.y1)}"
                if p.effective_main_shift != 0 and not p.is_side_by_side:
                    main += f", shifted {format_size(p.effective_main_shift)} px"
                if not p.strict and conversion and 0 not in unconverted:
                    main += f", {conversion}"
                pieces += f" {n + 1}. {p.image}, {main};" if names else f" {n + 1}. {main};"
                continue
            i, s = k - 1, p.strips[k - 1]
            shift, sc = p.effective_alignment(k)
            keep = p.is_strict(k)
            parts = ["original pixels"] if keep else []
            if keep and k in copied:
                parts.append(COPIED_NOTE)
            if s.turn % 4:
                parts.append(f"turned {s.turn % 4 * 90}°")
            if not keep and s.rotate_deg != 0:
                parts.append(f"rotation {float(s.rotate_deg)}°")
            gel_size = strips[i][2] if i < len(strips) and len(strips[i]) > 2 else None
            if gel_size is not None and size is not None:   # the columns and rows that went into the figure, as whole pixels
                left, right = p.kept_columns(k, gel_size[0], size[0], size[1])
                top, bottom = s.used_rows(gel_size[1])
                parts.append(f"columns {int(left)}–{int(right)}, rows {int(top)}–{int(bottom)}")
            else:   # without the sizes: the numbers stored, an edge with none being where the lanes gel's crop falls on this gel
                def edge(v, none):
                    return none if v is None or not math.isfinite(v) else max(0, int(sround(v)))
                parts.append(f"columns {edge(s.left, 'crop')}–{edge(s.right, 'crop')}, rows {edge(s.top, 0)}–{edge(s.bottom, 'end')}")
            parts.append(f"shifted {format_size(shift)} px{' vertically' if p.is_side_by_side else ''}")
            if sc != 1:
                parts.append(f"sized {sc:.4f}× in both directions (resampled)" if p.is_side_by_side
                             else f"stretched (scaled {sc:.4f}×)")
            vs = strips[i][1] if i < len(strips) else None
            if not keep:   # brightness & contrast only reach the pixels of a gel that doesn't keep its original ones
                if vs is not None:
                    lo, hi = s.display.range_in(vs)
                    parts.append(f"display range {vs.format(lo)}–{vs.format(hi)} of {vs.format(vs.max_value)}")
                if s.display.gamma != 1:
                    parts.append(f"gamma {float(s.display.gamma)}")
                if s.display.invert:
                    parts.append("inverted")
                if conversion and k not in unconverted:
                    parts.append(conversion)
            h = f" sha256 {strips[i][0]}" if i < len(strips) and strips[i][0] else ""
            label = f"{s.image}{h}" if names else h.strip()
            pieces += f" {n + 1}. {label + ', ' if label else ''}{', '.join(parts)};"
        pieces = pieces[:-1] + "."
    warnings = "".join(f"{w}\n" for w in changed)
    return ExportInfo(p.title or (p.image if names else "GelScribe figure"),
                      f"{warnings}GelScribe figure. {pixels}{ladder}{hsh}{pieces}")


def native_dpi(lay: FigureLayout) -> float:
    """Resolution of a native raster: one gel pixel per output pixel."""
    return 72 / lay.pt_per_px


def resample_dpi(requested: Optional[float], lay: FigureLayout) -> Optional[float]:
    """The resolution a raster export is redrawn at, or None when it stays native."""
    if requested is None or requested <= 0 or abs(requested - native_dpi(lay)) <= 0.5:
        return None
    return requested


# ---------------------------------------------------------------------------------------------------- Qt drawing


def qimage(arr: np.ndarray):
    """A QImage of a gel array (gray or RGB, 8 or 16 bit), for the screen and the PDF."""
    from PySide6.QtGui import QImage
    a = np.ascontiguousarray(arr)
    h, w = a.shape[:2]
    if a.dtype == np.float32:
        a = np.ascontiguousarray((np.clip(a, 0, 1) * 65535 + 0.5).astype(np.uint16))
    if a.ndim == 2 and a.dtype == np.uint8:
        img = QImage(a.data, w, h, a.strides[0], QImage.Format.Format_Grayscale8)
    elif a.ndim == 2:
        img = QImage(a.data, w, h, a.strides[0], QImage.Format.Format_Grayscale16)
    else:
        if a.dtype == np.uint16:
            a = np.ascontiguousarray((a >> 8).astype(np.uint8))
        img = QImage(a.data, w, h, a.strides[0], QImage.Format.Format_RGB888)
    return img.copy()   # own the pixels


def draw_text(painter, t: FigureText) -> None:
    from PySide6.QtCore import QPointF
    from PySide6.QtGui import QFontMetricsF
    painter.save()
    painter.translate(t.origin[0], t.origin[1])
    if t.rotation:
        painter.rotate(-t.rotation)   # y down: negative = counter-clockwise
    painter.scale(1 / TEXT_SCALE, 1 / TEXT_SCALE)
    f = qfont(t.font)
    painter.setFont(f)
    fm = QFontMetricsF(f)
    for k, s in enumerate(t.lines):   # each line aligned on its own
        w = fm.horizontalAdvance(s)
        dx = 0 if t.align == "left" else (-w / 2 if t.align == "center" else -w)
        painter.drawText(QPointF(dx, (t.first_baseline + k * t.line_height) * TEXT_SCALE), s)
    painter.restore()


def draw_overlay(painter, lay: FigureLayout, color=None) -> None:
    """Everything except the gel pixels. The gel rectangle is clipped out first, so no overlay (border, tick, arrow
    or anti-aliased edge) can ever touch a gel pixel."""
    from PySide6.QtCore import QPointF, QRectF, Qt
    from PySide6.QtGui import QBrush, QColor, QPainterPath, QPen, QPolygonF
    color = color or QColor(0, 0, 0)
    painter.save()
    w, h = lay.size
    clip = QPainterPath()
    clip.setFillRule(Qt.FillRule.OddEvenFill)
    clip.addRect(QRectF(-w, -h, 3 * w, 3 * h))
    g = lay.gel_rect
    clip.addRect(QRectF(g.x, g.y, g.w, g.h))
    painter.setClipPath(clip, Qt.ClipOperation.IntersectClip)
    pen = QPen(color)
    pen.setCapStyle(Qt.PenCapStyle.FlatCap)
    pen.setJoinStyle(Qt.PenJoinStyle.MiterJoin)
    painter.setBrush(Qt.BrushStyle.NoBrush)
    if lay.border_width is not None:   # entirely outside the gel
        bw = lay.border_width
        pen.setWidthF(bw)
        painter.setPen(pen)
        painter.drawRect(QRectF(g.x - bw / 2, g.y - bw / 2, g.w + bw, g.h + bw))
    for l in lay.lines:
        if len(l.points) < 2:
            continue
        pen.setWidthF(l.width)
        painter.setPen(pen)
        painter.drawPolyline(QPolygonF([QPointF(x, y) for x, y in l.points]))
    painter.setPen(Qt.PenStyle.NoPen)
    painter.setBrush(QBrush(color))
    for poly in lay.fills:
        if len(poly) >= 3:
            painter.drawPolygon(QPolygonF([QPointF(x, y) for x, y in poly]))
    painter.setBrush(Qt.BrushStyle.NoBrush)
    painter.setPen(QPen(color))
    for t in lay.texts:
        draw_text(painter, t)
    painter.restore()


def draw(painter, lay: FigureLayout, gel_img=None, smooth: bool = False) -> None:
    """The whole figure in a y-down point space: the gel image (a QImage) in its rectangle, then the overlay."""
    from PySide6.QtCore import QRectF
    from PySide6.QtGui import QPainter
    if gel_img is not None:
        painter.save()
        painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, smooth)
        g = lay.gel_rect
        painter.drawImage(QRectF(g.x, g.y, g.w, g.h), gel_img)
        painter.restore()
    draw_overlay(painter, lay)


# ---------------------------------------------------------------------------------------------------- raster


def _overlay_gray(lay: FigureLayout, k: float, W: int, H: int) -> np.ndarray:
    """The overlay alone, black on white, at k pixels per point."""
    from PySide6.QtGui import QImage, QPainter
    check_raster_size(W, H)
    ensure_gui()
    img = QImage(W, H, QImage.Format.Format_Grayscale8)
    if img.isNull():   # the memory for it couldn't be had
        raise ImageError(FIGURE_TOO_LARGE)
    img.fill(255)
    p = QPainter(img)
    if not p.isActive():   # no drawing context: the labels would go nowhere
        raise ImageError(FIGURE_TOO_LARGE)
    p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
    p.setRenderHint(QPainter.RenderHint.TextAntialiasing, True)
    p.scale(k, k)
    draw_overlay(p, lay)
    p.end()
    ptr = img.constBits()
    a = np.frombuffer(ptr, dtype=np.uint8, count=img.sizeInBytes()).reshape(H, img.bytesPerLine())[:, :W]
    return a.copy()


def _like(gel: Optional[np.ndarray], gray: np.ndarray) -> np.ndarray:
    """The overlay in the gel's own type and channels (white = full scale)."""
    if gel is None or gel.dtype == np.uint8:
        out = gray
    elif gel.dtype == np.uint16:
        out = (gray.astype(np.uint32) * 257).astype(np.uint16)
    else:
        out = (gray.astype(np.float32) / 255)
    if gel is not None and gel.ndim == 3:
        out = np.repeat(out[..., None], 3, axis=2)
    return out


def raster(lay: FigureLayout, gel: Optional[np.ndarray]) -> np.ndarray:
    """At the gel's native resolution, one gel pixel = one output pixel, in the gel's own type and channels. The gel
    is pasted in on whole pixels, so its values come through exactly."""
    k = 1 / lay.pt_per_px
    W, H = int(math.floor(lay.size[0] * k + 0.5)), int(math.floor(lay.size[1] * k + 0.5))
    out = _like(gel, _overlay_gray(lay, k, W, H))
    if gel is not None:
        gx = int(math.floor(lay.gel_rect.x * k + 0.5))
        gy = int(math.floor(lay.gel_rect.y * k + 0.5))
        gh, gw = gel.shape[:2]
        out[gy:gy + gh, gx:gx + gw] = gel[:max(0, min(gh, H - gy)), :max(0, min(gw, W - gx))]
    return out


def raster_at(lay: FigureLayout, gel: Optional[np.ndarray], dpi: float) -> np.ndarray:
    """The figure redrawn at dpi: text and lines drawn at that density, the gel resampled (cubic) into its place.
    Same type and channels as the gel."""
    from scipy import ndimage
    k = dpi / 72
    W, H = int(math.floor(lay.size[0] * k + 0.5)), int(math.floor(lay.size[1] * k + 0.5))
    out = _like(gel, _overlay_gray(lay, k, W, H))
    if gel is not None:
        g = lay.gel_rect
        gx, gy = int(math.floor(g.x * k + 0.5)), int(math.floor(g.y * k + 0.5))
        gw, gh = int(math.floor(g.max_x * k + 0.5)) - gx, int(math.floor(g.max_y * k + 0.5)) - gy
        src = gel.astype(np.float32)
        zoom = (gh / gel.shape[0], gw / gel.shape[1]) + ((1,) if gel.ndim == 3 else ())
        z = ndimage.zoom(src, zoom, order=3, mode="nearest", grid_mode=True)[:gh, :gw]
        top = 1.0 if gel.dtype == np.float32 else float(np.iinfo(gel.dtype).max)
        z = np.clip(z, 0, top)
        z = z.astype(np.float32) if gel.dtype == np.float32 else np.floor(z + 0.5).astype(gel.dtype)
        out[gy:gy + z.shape[0], gx:gx + z.shape[1]] = z
    return out


# ---------------------------------------------------------------------------------------------------- file formats


def _png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def encode_png(arr: np.ndarray, dpi: float, info: Optional[ExportInfo] = None) -> bytes:
    """PNG of an 8- or 16-bit gray or RGB array (written directly, so 16-bit colour works too), with its resolution
    and provenance."""
    a = arr
    if a.dtype == np.float32:
        a = (np.clip(a, 0, 1) * 65535 + 0.5).astype(np.uint16)
    h, w = a.shape[:2]
    depth = 16 if a.dtype == np.uint16 else 8
    ctype = 0 if a.ndim == 2 else 2
    raw = a.astype(">u2" if depth == 16 else np.uint8).reshape(h, -1).tobytes() if depth == 16 \
        else a.reshape(h, -1).tobytes()
    stride = len(raw) // h
    scan = b"".join(b"\x00" + raw[i * stride:(i + 1) * stride] for i in range(h))
    out = [b"\x89PNG\r\n\x1a\n", _png_chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, depth, ctype, 0, 0, 0))]
    ppm = int(math.floor(dpi / 0.0254 + 0.5))
    out.append(_png_chunk(b"pHYs", struct.pack(">IIB", ppm, ppm, 1)))
    if info is not None:
        for key, val in (("Title", info.title), ("Description", info.description), ("Software", "GelScribe")):
            out.append(_png_chunk(b"iTXt", key.encode("latin-1") + b"\x00\x00\x00\x00\x00" + val.encode("utf-8")))
    out.append(_png_chunk(b"IDAT", zlib.compress(scan, 6)))
    out.append(_png_chunk(b"IEND", b""))
    return b"".join(out)


def encode_tiff(arr: np.ndarray, dpi: float, info: Optional[ExportInfo] = None) -> bytes:
    """LZW-compressed TIFF (lossless) in the array's own type, with its resolution and provenance."""
    import tifffile
    buf = io.BytesIO()
    photometric = "minisblack" if arr.ndim == 2 else "rgb"
    # as UTF-8 bytes, which tifffile writes as they are (it refuses a str with "4–12%" in it), the same as the Mac app
    tifffile.imwrite(buf, arr, photometric=photometric, compression="lzw", resolution=(dpi, dpi),
                     resolutionunit="INCH", description=info.description.encode("utf-8") if info else None,
                     software="GelScribe", metadata=None)
    return buf.getvalue()


def raster_data(lay: FigureLayout, gel: Optional[np.ndarray], fmt: str, info: ExportInfo,
                dpi: Optional[float] = None) -> bytes:
    """PNG or TIFF, native unless dpi asks for another resolution (see resample_dpi)."""
    r = resample_dpi(dpi, lay)
    with figure_memory():
        if r is not None:
            img, d = raster_at(lay, gel, r), r
        else:
            img, d = raster(lay, gel), native_dpi(lay)
        return encode_png(img, d, info) if fmt == "png" else encode_tiff(img, d, info)


# ---------------------------------------------------------------------------------------------------- PDF


def pdf(lay: FigureLayout, gel: Optional[np.ndarray], info: ExportInfo) -> bytes:
    """Vector text and lines; the gel embedded losslessly with its original samples (16-bit stays 16-bit)."""
    from PySide6.QtCore import QBuffer, QByteArray, QIODevice, QMarginsF, QSizeF
    from PySide6.QtGui import QPageLayout, QPageSize, QPainter, QPdfWriter
    import pikepdf
    ensure_gui()
    data = QByteArray()
    buf = QBuffer(data)
    buf.open(QIODevice.OpenModeFlag.WriteOnly)
    w = QPdfWriter(buf)
    w.setResolution(72)
    w.setTitle(info.title)
    w.setCreator("GelScribe")
    w.setPageLayout(QPageLayout(QPageSize(QSizeF(lay.size[0], lay.size[1]), QPageSize.Unit.Point, "Figure",
                                          QPageSize.SizeMatchPolicy.ExactMatch),
                                QPageLayout.Orientation.Portrait, QMarginsF(0, 0, 0, 0)))
    p = QPainter(w)
    if not p.isActive():   # no drawing context: the page would be blank
        raise ImageError(FIGURE_TOO_LARGE)
    p.setRenderHint(QPainter.RenderHint.LosslessImageRendering, True)
    p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
    with figure_memory():
        image = qimage(gel) if gel is not None else None
    if image is not None and image.isNull():   # a gel too big for a QImage would be left out
        p.end()
        raise ImageError(FIGURE_TOO_LARGE)
    draw(p, lay, image)
    p.end()
    buf.close()
    raw = bytes(data.data())
    with pikepdf.open(io.BytesIO(raw)) as doc:
        doc.docinfo["/Subject"] = info.description
        doc.docinfo["/Title"] = info.title
        doc.docinfo["/Creator"] = "GelScribe"
        if gel is not None:
            _put_original_samples(doc, gel)
        out = io.BytesIO()
        doc.save(out)
        return out.getvalue()


def _put_original_samples(doc, gel: np.ndarray) -> None:
    """Replaces the gel's image in the PDF with its original samples, so the PDF carries exactly the pixels the
    figure uses at their own bit depth."""
    import pikepdf
    a = gel
    if a.dtype == np.float32:
        a = (np.clip(a, 0, 1) * 65535 + 0.5).astype(np.uint16)
    h, w = a.shape[:2]
    bpc = 16 if a.dtype == np.uint16 else 8
    samples = (a.astype(">u2") if bpc == 16 else a).tobytes()
    for page in doc.pages:
        images = page.get_images() if hasattr(page, "get_images") else page.images
        for name, obj in list(images.items()):
            if int(obj.get("/Width", 0)) == w and int(obj.get("/Height", 0)) == h:
                obj.write(zlib.compress(samples, 6), filter=pikepdf.Name.FlateDecode)
                obj.BitsPerComponent = bpc
                obj.ColorSpace = pikepdf.Name.DeviceGray if a.ndim == 2 else pikepdf.Name.DeviceRGB
                for key in ("/DecodeParms", "/SMask", "/Decode", "/Mask"):
                    if key in obj:
                        del obj[key]
                return


# ---------------------------------------------------------------------------------------------------- SVG


def svg(lay: FigureLayout, gel: Optional[np.ndarray], info: ExportInfo) -> str:
    """Text stays text; the gel is embedded as a lossless PNG of exactly the pixels the figure uses."""
    def n(v):
        return f"{v:.3f}"

    def esc(s):
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")

    W, H = lay.size
    out = ['<?xml version="1.0" encoding="UTF-8"?>\n'
           f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
           f'width="{n(W)}pt" height="{n(H)}pt" viewBox="0 0 {n(W)} {n(H)}">\n'
           f"<title>{esc(info.title)}</title>\n<desc>{esc(info.description)}</desc>\n"]
    g = lay.gel_rect
    if gel is not None:
        png = base64.b64encode(encode_png(gel, 72 / lay.pt_per_px, info)).decode("ascii")
        out.append(f'<image x="{n(g.x)}" y="{n(g.y)}" width="{n(g.w)}" height="{n(g.h)}" '
                   f'preserveAspectRatio="none" style="image-rendering:pixelated" '
                   f'xlink:href="data:image/png;base64,{png}"/>\n')
    out.append('<g fill="none" stroke="#000" stroke-linecap="butt" stroke-linejoin="miter">\n')
    if lay.border_width is not None:
        bw = lay.border_width
        out.append(f'<rect x="{n(g.x - bw / 2)}" y="{n(g.y - bw / 2)}" width="{n(g.w + bw)}" height="{n(g.h + bw)}" '
                   f'stroke-width="{n(bw)}"/>\n')
    for l in lay.lines:
        pts = " ".join(f"{n(x)},{n(y)}" for x, y in l.points)
        out.append(f'<polyline points="{pts}" stroke-width="{n(l.width)}"/>\n')
    out.append('</g>\n<g fill="#000" stroke="none">\n')
    for poly in lay.fills:
        out.append('<polygon points="' + " ".join(f"{n(x)},{n(y)}" for x, y in poly) + '"/>\n')
    for t in lay.texts:
        anchor = {"left": "start", "center": "middle"}.get(t.align, "end")
        attrs = (f'x="{n(t.origin[0])}" y="{n(t.origin[1])}" font-family="{esc(t.font.family)}" '
                 f'font-size="{n(t.font.size)}" text-anchor="{anchor}"')
        if t.font.bold:
            attrs += ' font-weight="bold"'
        if t.font.italic:
            attrs += ' font-style="italic"'
        if t.rotation:
            attrs += f' transform="rotate({n(-t.rotation)} {n(t.origin[0])} {n(t.origin[1])})"'
        lines = t.lines
        if len(lines) == 1:
            out.append(f"<text {attrs}>{esc(t.string)}</text>\n")
        else:   # one text object per label, a tspan per line, so it stays one editable label
            spans = "".join(f'<tspan x="{n(t.origin[0])}" y="{n(t.origin[1] + t.first_baseline + k * t.line_height)}">'
                            f"{esc(s)}</tspan>" for k, s in enumerate(lines))
            out.append(f"<text {attrs}>{spans}</text>\n")
    out.append("</g>\n</svg>\n")
    return "".join(out)
