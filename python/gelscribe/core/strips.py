"""Several gels in one figure: pieces of a cut membrane, or more gels of the same samples, each scanned on its own and
stacked top to bottom under one set of lanes, with a line between each. The same as the Mac app does it.

The figure's gel is made of "figure pixels" on the main image's grid (the main image is the gel with the lanes): its crop
keeps its own columns and rows, the other gels sit above or below it in stack order, each keeping the rows of its own crop
and the columns it was given (by default those under the lanes gel's crop) and mapped onto that grid (shifted sideways to
line its lanes up, and stretched when that gel doesn't keep its original pixels), with a separator line between neighbours,
black, white or a colour. The figure runs from the leftmost to the rightmost column any gel keeps; where a gel has no pixels
it's blank white. Lanes and labels live in the main image's coordinates, which are figure coordinates too; each other gel's
marks are converted on the way in and out.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Callable, NamedTuple, Optional

import numpy as np
from scipy import ndimage

from . import detect
from .image import ImageError, SourceImage, WorkingImage, render_gray
from .layout import FigureLayout, layout
from .model import GelProject, PixelRect, format_size, separator_gray, separator_rgb, sround


@dataclass
class Piece:
    #: None = the main image, else the gel's number in strips
    strip: Optional[int]
    #: its rows in the figure, half-open, in figure pixels
    top: float
    bottom: float
    #: its own first row (working-image pixels) shown at top
    source_top: float
    #: x in the gel = scale × figure x + shift; y likewise, from source_top
    scale: float
    shift: float
    #: its working image
    width: int
    height: int
    #: its kept columns in the figure, half-open, in figure pixels: its own columns through the shift and stretch
    left: float = 0.0
    right: float = 0.0
    #: its own first kept column and the one after its last (working-image pixels), shown from left to right
    source_left: float = 0.0
    source_right: float = 0.0

    def to_piece(self, x: float, y: float) -> tuple[float, float]:
        return self.scale * x + self.shift, self.source_top + (y - self.top) * self.scale

    def to_figure(self, x: float, y: float) -> tuple[float, float]:
        return (x - self.shift) / self.scale, self.top + (y - self.source_top) / self.scale

    def contains(self, fy: float) -> bool:
        return self.top <= fy < self.bottom

    @property
    def source_bottom(self) -> float:
        """Its own rows that are in the figure end here."""
        return self.source_top + (self.bottom - self.top) * self.scale


class StackGeometry:
    """Where every gel sits in the figure, and how to convert between figure pixels and a gel's own pixels."""

    def __init__(self, p: GelProject, main_w: int, main_h: int, strip_sizes: list[Optional[tuple[int, int]]]):
        """strip_sizes: each stacked gel's working-image size (after its turn), in strips order, so a list that is
        index-aligned with p.strips. A gel without a size (None, or past the end of the list: not decoded) is left out of
        the stack but keeps its number, so no other gel moves into its place."""
        c = p.effective_crop(main_w, main_h)
        #: the line's colour: "black" is the darkest value of the output's storage and "white" the brightest; a colour is its
        #: own numbers in an RGB storage and its luminance in a gray one
        self.separator_colour = p.separator

        def strip(k: int) -> Optional[Piece]:
            if k - 1 >= len(strip_sizes) or strip_sizes[k - 1] is None:
                return None
            s, (w, h) = p.strips[k - 1], strip_sizes[k - 1]
            shift, scale = p.lane_alignment(k)   # lined up with the lanes gel wherever that sits; the figure is on its grid
            a, b = s.used_rows(h)
            left, right, follows_left, follows_right = s.columns(w, c, shift, scale)
            rows = max(1, sround((b - a) / scale))
            # an edge the gel followed is the lanes gel's crop edge itself, so such a gel never makes the figure wider
            return Piece(k, 0, rows, a, scale, shift, w, h,
                         c.x0 if follows_left else (left - shift) / scale,
                         c.x1 if follows_right else (right - shift) / scale, left, right)

        order = p.stack_order
        m = order.index(None)
        above_gels = [q for q in (strip(k) for k in reversed(order[:m])) if q is not None]
        below_gels = [q for q in (strip(k) for k in order[m + 1:]) if q is not None]

        def clean(v: float) -> float:
            return sround(v * 1e6) / 1e6
        # the figure runs from the leftmost to the rightmost column any gel keeps, in whole figure pixels (rounded first, so
        # a column that is exactly a whole number stays there)
        x0 = float(math.floor(min([c.x0] + [clean(q.left) for q in above_gels + below_gels])))
        x1 = float(math.ceil(max([c.x1] + [clean(q.right) for q in above_gels + below_gels])))
        pt_per_px = p.style.gel_width_in * 72 / max(x1 - x0, 1)
        sep = max(1, int(sround(p.effective_separator_width / pt_per_px)))
        self.separator = sep
        # the main image keeps its own rows; the gels above it stack upward from its crop, the ones below downward
        above: list[Piece] = []
        y = c.y0
        for s in above_gels:
            rows = s.bottom
            s.bottom = y - sep
            s.top = s.bottom - rows
            y = s.top
            above.insert(0, s)
        y0 = y
        below: list[Piece] = []
        y = c.y1
        for s in below_gels:
            rows = s.bottom
            s.top = y + sep
            s.bottom = s.top + rows
            y = s.bottom
            below.append(s)
        main = Piece(None, c.y0, c.y1, c.y0, 1.0, 0.0, main_w, main_h, c.x0, c.x1, c.x0, c.x1)
        self.pieces: list[Piece] = above + [main] + below
        #: the figure's gel in figure pixels: from the leftmost to the rightmost column any gel keeps (the main image's crop
        #: and the other gels' crops through their alignment), and from the top of the topmost gel to the bottom of the lowest
        self.crop = PixelRect(x0, y0, x1, y)

    @property
    def has_strips(self) -> bool:
        return len(self.pieces) > 1

    def piece(self, strip: Optional[int]) -> Optional[Piece]:
        return next((q for q in self.pieces if q.strip == strip), None)

    def piece_at_figure_y(self, y: float) -> Optional[Piece]:
        """The gel whose rows hold figure row y; in a separator, the nearer of the two."""
        for q in self.pieces:
            if q.contains(y):
                return q
        return min(self.pieces, key=lambda q: min(abs(q.top - y), abs(q.bottom - y)), default=None)

    def figure_y(self, strip: Optional[int], y: float, inside: bool = True) -> Optional[float]:
        """Figure row of a mark at y in its own gel, if that gel is in the figure and the row is inside it."""
        q = self.piece(strip)
        if q is None:
            return None
        if strip is None:   # the main image: its crop
            return y if not inside or q.top <= y <= q.bottom else None
        fy = q.to_figure(0, y)[1]
        return fy if not inside or q.top - 0.5 <= fy <= q.bottom + 0.5 else None

    def name_y(self, strip: Optional[int], y: float) -> Optional[float]:
        """Figure row of a band name at y in its own gel. With one gel a name stays where it was put, even outside the
        crop; with several, only inside its own gel (elsewhere it would point at another gel's bands)."""
        if self.has_strips:
            return self.figure_y(strip, y)
        return y if strip is None else None


# ---------------------------------------------------------------------------------------------------- pixels


def _describe(px: np.ndarray) -> str:
    bits = 32 if px.dtype == np.float32 else (16 if px.dtype == np.uint16 else 8)
    return f"{bits}-bit {'gray' if px.ndim == 2 else 'RGB'}"


def strict_mismatch(main: np.ndarray, strip: np.ndarray, main_icc: Optional[bytes] = None,
                    strip_icc: Optional[bytes] = None, reference: str = "the gel with the lanes") -> Optional[str]:
    """Why Strict can't stack these images untouched, or None when it can: they must share one pixel format (bit depth,
    channels) and one color profile (the ICC data embedded in the file, not just the name of the color space), or the
    exported pixels couldn't be the original values with their original colors. Said of the stacked gel, without its
    name, against the reference gel (the one with the lanes unless told otherwise): "is 8-bit RGB, the gel with the
    lanes 8-bit gray", "has a different color profile from the gel with the lanes"."""
    if main.dtype != strip.dtype or main.ndim != strip.ndim:
        return f"is {_describe(strip)}, {reference} {_describe(main)}"
    if main_icc != strip_icc:
        return f"has a different color profile from {reference}"
    return None


def strict_problem_detail(main: np.ndarray, strips: list[Optional[np.ndarray]], name: Callable[[int], str],
                          main_icc: Optional[bytes] = None, strips_icc: Optional[list] = None,
                          keeps: Optional[list] = None) -> Optional[tuple[int, str]]:
    """The first gel that keeps its original pixels but can't be stacked untouched with the others that do, as (its number
    in strips, "Gel 2 is 8-bit RGB, the gel with the lanes 8-bit gray" with the gel called name(k)); or None. A gel that
    couldn't be read (None) is skipped. strips_icc: each gel's embedded color profile, in the same order (see
    strict_mismatch). keeps: whether each gel keeps its original pixels, the one with the lanes first and then the
    stacked gels in strips order (all of them by default); only those have to match each other, and the first of them
    is the one the others are compared with."""
    n = len(strips)
    keep = [True] * (n + 1) if keeps is None else [bool(keeps[i]) if i < len(keeps) else True for i in range(n + 1)]
    imgs = [main] + list(strips)
    icc = [main_icc] + [strips_icc[i] if strips_icc is not None and i < len(strips_icc) else main_icc for i in range(n)]
    ref = next((i for i in range(n + 1) if keep[i] and imgs[i] is not None), None)
    if ref is None:
        return None
    reference = "the gel with the lanes" if ref == 0 else name(ref)
    for i in range(ref + 1, n + 1):
        m = strict_mismatch(imgs[ref], imgs[i], icc[ref], icc[i], reference) if keep[i] and imgs[i] is not None else None
        if m:
            return i, f"{name(i)} {m}"
    return None


def strict_problem(main: np.ndarray, strips: list[Optional[np.ndarray]], name: Callable[[int], str],
                   main_icc: Optional[bytes] = None, strips_icc: Optional[list] = None,
                   keeps: Optional[list] = None) -> Optional[str]:
    """strict_problem_detail's message alone."""
    found = strict_problem_detail(main, strips, name, main_icc, strips_icc, keeps)
    return found[1] if found else None


def strict_problem_detail_for(main: SourceImage, strips: list[Optional[SourceImage]], name: Callable[[int], str],
                              keeps: Optional[list] = None) -> Optional[tuple[int, str]]:
    """strict_problem_detail for the images themselves (their pixels and embedded color profiles); a gel that couldn't be
    read is None."""
    return strict_problem_detail(main.pixels, [w.pixels if w is not None else None for w in strips], name, main.icc_profile,
                                 [w.icc_profile if w is not None else None for w in strips], keeps)


def strict_problem_for(main: SourceImage, strips: list[Optional[SourceImage]], name: Callable[[int], str],
                       keeps: Optional[list] = None) -> Optional[str]:
    """strict_problem for the images themselves; a gel that couldn't be read is None."""
    found = strict_problem_detail_for(main, strips, name, keeps)
    return found[1] if found else None


def keeps_original(p: GelProject) -> list[bool]:
    """Whether each gel keeps its original pixels: the one with the lanes first, then the stacked gels in strips order."""
    return [p.is_strict(None)] + [p.is_strict(k) for k in range(1, len(p.strips) + 1)]


def output_is_gray(p: GelProject) -> bool:
    """Whether a stack in which no gel keeps its original pixels is stored as 8-bit gray (else 8-bit RGB). Every gel is gray
    then (a gel that doesn't keep its pixels is mapped to 8-bit gray, whatever it was scanned as), so only the colour of the
    line between gels decides: a gray line (black, white, or a color with red = green = blue) fits a gray figure, any
    other colour needs RGB to be kept exactly."""
    r, g, b = separator_rgb(p.separator)
    return r == g == b


def converted_storage(p: GelProject, sources: list[Optional[SourceImage]]) -> Optional[str]:
    """What the gels that don't keep their original pixels are converted to in a stacked figure, for its note. When some
    gels keep theirs, the format the figure is stored in: that of the first gel that keeps them ("16-bit gray"). When none
    does, 8-bit gray, or 8-bit RGB when the line between gels is a colour (output_is_gray). None when every gel keeps its
    pixels, or without a stack. sources: each gel's image, the one with the lanes first."""
    keeps = keeps_original(p)
    if not p.strips or all(keeps):
        return None
    if not any(keeps):
        return "8-bit gray" if output_is_gray(p) else "8-bit RGB"
    src = sources[keeps.index(True)] if keeps.index(True) < len(sources) else None
    return _describe(src.pixels) if src is not None else None


def _white(dtype) -> float:
    return 1.0 if dtype == np.float32 else float(np.iinfo(dtype).max)


def _line_value(colour: str, dtype, rgb: bool):
    """The separator's value in the output's storage: black is the darkest value and white the brightest; a colour is its own
    red, green and blue in an RGB storage and its gray level (Rec. 709 luminance, see separator_gray) in a gray one, 16-bit
    values as 8-bit ones everywhere, times 257."""
    r, g, b = separator_rgb(colour)
    v = (r, g, b) if rgb else (separator_gray(colour),)
    if dtype == np.uint16:
        v = tuple(x * 257 for x in v)
    elif dtype == np.float32:
        v = tuple(x / 255 for x in v)
    return np.array(v if rgb else v[0], dtype=dtype)


def _compose(stack: StackGeometry, image_for: Callable[[Piece], Optional[np.ndarray]], dtype, rgb: bool,
             interpolate: Callable[[Piece], bool]) -> np.ndarray:
    """Each gel's kept columns and rows of image_for(piece) (a full-frame image in that gel's working pixels) in their place;
    blank white where no gel has pixels, and the separator rows in the line's colour."""
    c = stack.crop
    W, H = int(sround(c.width)), int(sround(c.height))
    out = np.full((H, W, 3) if rgb else (H, W), _white(dtype), dtype=dtype)
    line = _line_value(stack.separator_colour, dtype, rgb)
    for n, q in enumerate(stack.pieces):
        if n > 0:
            prev = stack.pieces[n - 1]
            out[int(sround(prev.bottom - c.y0)):int(sround(q.top - c.y0))] = line
        img = image_for(q)
        if img is None:
            continue
        if rgb and img.ndim == 2:
            img = np.repeat(img[..., None], 3, axis=2)
        dst = int(sround(q.top - c.y0))
        rows = int(sround(q.bottom - q.top))
        h, w = img.shape[:2]
        x_src = q.scale * c.x0 + q.shift
        if not interpolate(q) or (q.scale == 1 and float(x_src).is_integer() and float(q.source_top).is_integer()):
            # whole pixels: the gel's own values, cut and placed; its kept columns only
            xs, ys = int(sround(x_src)), int(sround(q.source_top))
            ca, cb = max(0, int(sround(q.left - c.x0))), min(W, int(sround(q.right - c.x0)))
            sx0, sx1 = max(0, xs + ca), min(w, xs + cb)
            sy0, sy1 = max(0, ys), min(h, ys + rows)
            if sx1 > sx0 and sy1 > sy0:
                out[dst + sy0 - ys:dst + sy1 - ys, sx0 - xs:sx1 - xs] = img[sy0:sy1, sx0:sx1]
            continue
        # stretched or shifted by a fraction: each output pixel's centre looked up in the gel (bilinear)
        fx = c.x0 + np.arange(W) + 0.5   # the pixel centres in figure columns
        px = x_src + (np.arange(W) + 0.5) * q.scale - 0.5
        py = q.source_top + (np.arange(rows) + 0.5) * q.scale - 0.5
        yy, xx = np.meshgrid(py, px, indexing="ij")
        ok = (xx >= -0.5) & (xx <= w - 0.5) & (yy >= -0.5) & (yy <= h - 0.5) & ((fx >= q.left) & (fx < q.right))[None, :]
        planes = [img] if img.ndim == 2 else [img[..., ch] for ch in range(img.shape[2])]
        sampled = [ndimage.map_coordinates(pl.astype(np.float32), [yy, xx], order=1, mode="nearest") for pl in planes]
        v = sampled[0] if img.ndim == 2 else np.stack(sampled, axis=-1)
        region = out[dst:dst + rows]
        if dtype != np.float32:
            v = np.clip(np.floor(v + 0.5), 0, _white(dtype))
        region[ok] = v[ok].astype(dtype)
    return out


def _stored_as(gray8: np.ndarray, dtype) -> np.ndarray:
    """An 8-bit gray rendering in another storage: 8 to 16 bit by 257 (so 255 is the brightest 16-bit value), to
    floating point by 255. Gray goes to color where the composition needs it."""
    if dtype == np.uint16:
        return gray8.astype(np.uint16) * 257
    if dtype == np.float32:
        return gray8.astype(np.float32) / 255
    return gray8


def figure_image(main: WorkingImage, strips: list[WorkingImage], p: GelProject, stack: StackGeometry) -> Optional[np.ndarray]:
    """The gel as it goes into the figure. Each gel is on its own: one that keeps its original pixels goes in untouched
    on whole pixels, unscaled (None if their formats differ: see strict_mismatch), and one that doesn't is processed
    and mapped to 8-bit gray, stretched and shifted by a fraction where it needs, then stored the way the others are.
    With every gel kept, that is the main image's format; with none kept, 8-bit gray, or 8-bit RGB when the line between
    gels is a colour (output_is_gray); with some of each, the format of the ones kept (8 to 16 bit by 257, gray to color
    by copying). The separator rows are black or white
    (GelProject.separator): the darkest or brightest value of that storage."""
    from . import render
    if not stack.has_strips:
        return main.figure_image(p)
    render.check_raster_size(int(sround(stack.crop.width)), int(sround(stack.crop.height)))   # never a blank gel
    gels = [main] + list(strips)
    keeps = keeps_original(p)[:len(gels)]
    if any(keeps):
        if strict_problem_for(main.source, [w.source for w in strips], str, keeps):
            return None
        ref = gels[keeps.index(True)].source.pixels
        dtype, rgb = ref.dtype, ref.ndim == 3
    else:
        dtype, rgb = np.uint8, not output_is_gray(p)   # none keeps its pixels: 8-bit gray, or RGB for a coloured line

    def pixels(i: int) -> np.ndarray:
        if keeps[i]:
            return gels[i].source.pixels
        shown = p.effective_display if i == 0 else p.strip_project(i).effective_display
        return _stored_as(render_gray(gels[i]._processed(), shown), dtype)
    images = [pixels(i) for i in range(len(gels))]
    return _compose(stack, lambda q: images[q.strip or 0] if (q.strip or 0) < len(images) else None, dtype, rgb,
                    lambda q: not keeps[q.strip or 0])


def view_image(views: list[Optional[np.ndarray]], stack: StackGeometry) -> Optional[np.ndarray]:
    """The gel for the screen: each gel's full-frame view image (8-bit gray or RGB, brightness & contrast applied), cut
    and placed as in the figure."""
    rgb = any(v is not None and v.ndim == 3 for v in views)
    return _compose(stack, lambda q: views[q.strip or 0] if (q.strip or 0) < len(views) else None,
                    np.uint8, rgb, lambda q: True)


# ---------------------------------------------------------------------------------------------------- lining up


@dataclass
class Alignment:
    shift: float
    scale: float
    #: the worst-placed lane after lining up, in figure pixels, and the typical lane spacing, for scale
    worst: float
    pitch: float


#: why no alignment was found: the gel's lanes couldn't be found (no lane signal, or not as many as the lanes gel has) ...
NO_LANES = "lanes"
#: ... or the lanes found don't sit where the lanes gel's do
MISFIT = "misfit"

#: the least lane-over-gap contrast (see lane_contrast) that counts as lanes. The tutorial's pieces score 0.41 to 0.86. The
#: bar is low on purpose: a real piece with faint lanes, or a dye front across it, scores much lower than a clean one, and
#: the fit is still checked against half a lane.
LANE_CONTRAST = 0.08
#: and the least modulation depth. The contrast above can't tell a gel of noise from a real one with a few strong
#: columns (about one gel of pure noise in ten gets past 0.08), but modulation can: the tutorial's lanes score 0.63 and up, noise
#: never more than 0.05.
LANE_MODULATION = 0.08


@dataclass
class AlignResult:
    #: None when no fit was found, and problem says why: NO_LANES or MISFIT
    alignment: Optional[Alignment]
    problem: Optional[str] = None

    def message(self, gel_number: int, strict: bool) -> Optional[str]:
        """What to tell the user when there's no alignment (gel_number counted from the top; strict: that gel keeps its
        original pixels, so it can't stretch), or None when there is one."""
        if self.alignment is not None:
            return None
        if self.problem == MISFIT:
            return (f"Gel {gel_number}'s lanes don't line up with the lanes gel's. Line it up by hand"
                    + (f" or turn off Keep original pixels for Gel {gel_number} to let it stretch." if strict else "."))
        return f"Couldn't find Gel {gel_number}'s lanes. Line it up by hand."


class Contrast(NamedTuple):
    #: (lane − gap) / (hi − lo)
    spread: float
    #: (lane − gap) / (lane + gap)
    modulation: float


def lane_contrast(col: np.ndarray, centers: list[float], pitch: float) -> Optional[Contrast]:
    """How clearly a gel's column darkness profile col shows lanes at centers (evenly enough spaced by about pitch). lane
    is the mean darkness within ±15% of a pitch of the lane centres, gap the same at the midpoints between them, and hi
    and lo the 95th and 5th percentile of the profile across the lanes. The contrast is (lane − gap) relative to hi − lo,
    and the modulation depth relative to lane + gap. None when the profile is flat (a blank gel)."""
    n = len(col)
    w = max(1, int(sround(pitch * 0.15)))

    def window(c: float) -> float:
        i = int(sround(c))
        seg = col[max(0, i - w):min(n, i + w + 1)]
        return float(seg.mean()) if seg.size else 0.0

    lane = float(np.mean([window(c) for c in centers]))
    gap = float(np.mean([window((a + b) / 2) for a, b in zip(centers, centers[1:])]))
    a, b = max(0, int(sround(centers[0] - pitch / 2))), min(n, int(sround(centers[-1] + pitch / 2)) + 1)
    if b <= a or not lane + gap > 0:
        return None
    lo, hi = np.percentile(col[a:b], [5, 95])
    if not hi > lo:
        return None
    return Contrast((lane - gap) / float(hi - lo), (lane - gap) / (lane + gap))


def find_alignment(centers: list[float], strip: WorkingImage, bands_dark: bool,
                   rows: Optional[tuple[float, float]] = None, allow_scale: bool = True) -> AlignResult:
    """Finds len(centers) lanes in the gel's rows that are in the figure and fits x_gel = scale × x_main + shift to the
    main image's lane centres. allow_scale False (Strict): scale 1 and a whole-pixel shift. It never invents a fit: a
    gel without lane signal, or lanes that don't sit near the lanes gel's (the worst one more than half a lane spacing
    off) give no alignment, and the result says which."""
    n = len(centers)
    if n < 2:
        return AlignResult(None, NO_LANES)
    dark = strip.darkness(bands_dark)
    if rows is not None:
        a, b = max(0, int(sround(rows[0]))), min(dark.shape[0], int(sround(rows[1])))
        if b - a >= 8:
            dark = dark[a:b]
    fit = detect.lanes(dark, n)
    if len(fit.centers) != n or fit.pitch <= 0:
        return AlignResult(None, NO_LANES)
    # each lane where its signal is centred: the comb is evenly spaced, real lanes not quite
    col = dark.astype(np.float64).sum(axis=0)
    half = fit.pitch * 0.45
    ys = []
    for c in fit.centers:
        a, b = max(0, int(c - half)), min(dark.shape[1] - 1, int(c + half))
        if b <= a:
            ys.append(c)
            continue
        v = col[a:b + 1] - col[a:b + 1].min()
        mass = float(v.sum())
        ys.append(float((v * np.arange(a, b + 1)).sum() / mass) if mass > 0 else c)
    contrast = lane_contrast(col, ys, fit.pitch)
    if contrast is None or contrast.spread < LANE_CONTRAST or contrast.modulation < LANE_MODULATION:
        return AlignResult(None, NO_LANES)
    x = np.array(centers, dtype=np.float64)
    y = np.array(ys, dtype=np.float64)
    if allow_scale:
        mx, my = x.mean(), y.mean()
        sxx = float(((x - mx) ** 2).sum())
        scale = float(((x - mx) * (y - my)).sum() / sxx) if sxx > 0 else 1.0
        if not 0.5 < scale < 2:
            return AlignResult(None, MISFIT)
        shift = float(my - scale * mx)
    else:
        scale, shift = 1.0, float(sround(float((y - x).mean())))
    worst = float(np.max(np.abs(y - (scale * x + shift)) / scale))
    gaps = sorted(float(b - a) for a, b in zip(centers, centers[1:]))
    pitch = gaps[len(gaps) // 2] if gaps else 0.0
    if pitch > 0 and worst > 0.5 * pitch:
        return AlignResult(None, MISFIT)
    return AlignResult(Alignment(sround(shift * 100) / 100, sround(scale * 10000) / 10000, sround(worst * 10) / 10, pitch))


def suggest_alignment(centers: list[float], strip: WorkingImage, bands_dark: bool,
                      rows: Optional[tuple[float, float]] = None, allow_scale: bool = True) -> Optional[Alignment]:
    """find_alignment without the reason: the alignment, or None when there isn't a trustworthy one."""
    return find_alignment(centers, strip, bands_dark, rows, allow_scale).alignment


def stretch_note(gel_number: int, whole_pixels: Alignment, stretched: Optional[Alignment]) -> Optional[str]:
    """For a gel that keeps its original pixels, lined up by whole pixels (whole_pixels) while stretching it would fit
    (stretched): when its worst lane is off by more than a quarter of a lane spacing, what it would take. Counted from
    the top, and only ever about a stacked gel, never the one with the lanes."""
    if stretched is None or whole_pixels.pitch <= 0 or whole_pixels.worst <= whole_pixels.pitch / 4:
        return None
    pct = abs(stretched.scale - 1) * 100
    if not math.isfinite(pct) or pct < 0.05:   # nothing to stretch away
        return None
    way = "farther apart" if stretched.scale > 1 else "closer together"
    return (f"Gel {gel_number}'s lanes are {pct:.1f}% {way}, so they're up to {format_size(whole_pixels.worst)} px off. "
            f"Turn off Keep original pixels for Gel {gel_number} to stretch it.")


def align_gel(p: GelProject, k: int, w: WorkingImage) -> tuple[AlignResult, Optional[str]]:
    """Gel k (its number in strips; w its working image) lined up under p's lanes by its own Keep original pixels
    setting: a whole-pixel shift when it keeps them, a shift and a stretch when it doesn't. With the fit and a note
    (stretch_note) when whole pixels leave a lane more than a quarter of a lane off."""
    s = p.strips[k - 1]
    rows, keep = s.used_rows(w.height), p.is_strict(k)
    r = find_alignment(p.lanes.centers, w, s.display.bands_dark, rows, allow_scale=not keep)
    note = None
    if keep and r.alignment is not None and r.alignment.pitch > 0 and r.alignment.worst > r.alignment.pitch / 4:
        free = find_alignment(p.lanes.centers, w, s.display.bands_dark, rows, allow_scale=True).alignment
        note = stretch_note(p.position_of(k) + 1, r.alignment, free)
    return r, note


# ---------------------------------------------------------------------------------------------------- the whole figure


def unreadable_message(p: GelProject, k: int) -> str:
    """"Gel 2's image (b.png) can't be read.": gel k (its number in strips) counted from the top of the figure."""
    return f"Gel {p.position_of(k) + 1}'s image ({p.strips[k - 1].image}) can't be read."


def strip_images(pkg, tolerant: bool = False) -> list[Optional[WorkingImage]]:
    """The stacked gels' working images for a package, each with its own turn, rotation and brightness & contrast, in
    strips order. A gel whose image can't be read raises ImageError ("Gel 2's image (b.png) can't be read."), or with
    tolerant is None in its place, so the list stays index-aligned and no other gel's image moves into its place."""
    out: list[Optional[WorkingImage]] = []
    for k in range(1, len(pkg.project.strips) + 1):
        data = pkg.strip_data(k)
        try:
            if data is None:
                raise ImageError("missing")
            out.append(WorkingImage(SourceImage(data), pkg.project.strip_project(k)))
        except ImageError:
            if not tolerant:
                raise ImageError(unreadable_message(pkg.project, k)) from None
            out.append(None)
    return out


class StackedFigure:
    """One project's whole figure, every gel included: what the command line and the app export from."""

    def __init__(self, p: GelProject, main: WorkingImage, strips: list[Optional[WorkingImage]]):
        """strips: each stacked gel's working image in strips order, None for one that couldn't be read (see
        unreadable: such a figure can't be exported, and no other gel's image takes its place)."""
        self.project, self.main = p, main
        n = len(p.strips)
        self.strips: list[Optional[WorkingImage]] = (list(strips[:n]) + [None] * n)[:n]
        self.stack = StackGeometry(p, main.width, main.height,
                                   [(w.width, w.height) if w is not None else None for w in self.strips])
        self.layout: FigureLayout = layout(p, main.width, main.height, self.stack)

    @property
    def unreadable(self) -> Optional[str]:
        """"Gel 2's image (b.png) can't be read." for the topmost gel whose image couldn't be read, or None."""
        bad = [k + 1 for k, w in enumerate(self.strips) if w is None]
        return unreadable_message(self.project, min(bad, key=self.project.position_of)) if bad else None

    @property
    def strict_problem(self) -> Optional[str]:
        """Why the gels that keep their original pixels can't be exported untouched, or None."""
        p = self.project
        return strict_problem_for(self.main.source, [w.source if w is not None else None for w in self.strips],
                                  lambda k: f"gel {p.position_of(k) + 1}", keeps_original(p))

    @property
    def gel(self) -> Optional[np.ndarray]:
        if self.unreadable:
            raise ImageError(self.unreadable)
        return figure_image(self.main, self.strips, self.project, self.stack)

    def changed_warnings(self, names: bool = True) -> list[str]:
        """One line per gel whose image no longer matches the SHA-256 taken when it was added (render.changed_warnings)."""
        from . import render
        return render.changed_warnings(self.project, [self.main.source.sha256] +
                                       [w.source.sha256 if w is not None else None for w in self.strips], names)

    def info(self, resampled_dpi: Optional[float] = None):
        from . import render
        if self.unreadable:
            raise ImageError(self.unreadable)
        storage = converted_storage(self.project, [self.main.source] + [w.source for w in self.strips])
        return render.export_info(self.project, self.main.source.sha256, resampled_dpi,
                                  render.native_dpi(self.layout) if resampled_dpi else None, self.main.source.scale,
                                  [(w.source.sha256, w.source.scale, (w.width, w.height)) for w in self.strips],
                                  (self.main.width, self.main.height), storage,
                                  self.changed_warnings(self.project.export_file_names))

    def export(self, fmt: str, dpi: Optional[float] = None) -> bytes:
        """pdf, png, tiff or svg; PNG and TIFF at dpi when it differs from native (None: the project's own setting)."""
        from . import render
        if self.unreadable:
            raise ImageError(self.unreadable)
        if self.strict_problem:
            raise ValueError(self.strict_problem)
        with render.figure_memory():
            gel = self.gel
            if fmt == "pdf":
                return render.pdf(self.layout, gel, self.info())
            if fmt == "svg":
                return render.svg(self.layout, gel, self.info()).encode("utf-8")
            want = dpi if dpi is not None else self.project.style.export_dpi
            return render.raster_data(self.layout, gel, fmt, self.info(render.resample_dpi(want, self.layout)), want)
