"""Edits to a project, the same as the Mac app makes them."""
from __future__ import annotations

import math
import re
from typing import Callable, Optional

from . import labels as ql
from .ladders import LadderPreset, LadderSystem
from .model import (BandAnnotation, GelProject, LabelRow, Ladder, LadderBand, LaneDivider, LaneGeometry, Line,
                    PixelRect, sround)

# ---------------------------------------------------------------------------------------------------- lanes


def add_divider(p: GelProject, x: float, y: float, w: int, h: int) -> LaneDivider:
    """A vertical divider through the clicked point (one click per gap between lanes)."""
    d = LaneDivider.vertical(x, y)
    p.lanes.dividers.append(d)
    p.lanes.dividers.sort(key=lambda d: d.x_top + d.x_bottom)
    p.sync_lane_centers(w, h)
    return d


def set_dividers(p: GelProject, xs: list[float], w: int, h: int) -> None:
    """Replaces all dividers with vertical ones at xs, the dot a little inside the visible gel."""
    c = p.effective_crop(w, h)
    y = sround(c.y0 + c.height * 0.14)
    p.lanes.dividers = [LaneDivider.vertical(x, y) for x in sorted(xs)]
    p.sync_lane_centers(w, h)


def auto_dividers(p: GelProject, working, count: Optional[int]):
    """For the command line: detect the lane centres, then put a divider midway between each two. Returns the fit;
    with fewer than two lanes found nothing changes."""
    from . import detect
    fit = detect.lanes(working.darkness(p.display.bands_dark), count)
    if len(fit.centers) >= 2:
        p.lanes.outer_lanes = True
        set_dividers(p, [(a + b) / 2 for a, b in zip(fit.centers, fit.centers[1:])], working.width, working.height)
    return fit


def geometry(p: GelProject, w: int, h: int) -> Optional[LaneGeometry]:
    """Lane geometry, from dividers or (for dividerless configs) from centers."""
    g = LaneGeometry.resolve(p.lanes, float(w), float(h))
    if g is not None:
        return g
    c = p.lanes.centers
    if not c:
        return None
    half = p.lanes.width / 0.85 / 2
    lines = [Line(c[0] - half, c[0] - half)]
    for a, b in zip(c, c[1:]):
        m = (a + b) / 2
        lines.append(Line(m, m))
    lines.append(Line(c[-1] + half, c[-1] + half))
    return LaneGeometry(lines, float(h))


# ---------------------------------------------------------------------------------------------------- rotation


def rotate_marks(p: GelProject, delta: float, w: int, h: int) -> None:
    """Moves dividers, ticks and names with the image when it turns by delta degrees (counter-clockwise on screen,
    about the image centre), so they stay on their bands."""
    if abs(delta) <= 1e-9:
        return
    t = math.radians(delta)
    c, s = math.cos(t), math.sin(t)
    cx, cy = (w - 1) / 2, (h - 1) / 2
    H = float(h)

    def turn(x, y):
        dx, dy = x - cx, y - cy
        return c * dx + s * dy + cx, -s * dx + c * dy + cy

    for d in p.lanes.dividers:
        a, b = turn(d.x_top, 0), turn(d.x_bottom, H)
        dot = turn(d.x_at(d.dot_y, H), d.dot_y)
        m = 0 if abs(b[1] - a[1]) < 1e-9 else (b[0] - a[0]) / (b[1] - a[1])
        d.x_top = a[0] - m * a[1]
        d.x_bottom = a[0] + m * (H - a[1])
        d.dot_y = dot[1]
    centers = p.lanes.centers
    if p.ladder is not None:
        l = p.ladder
        x = centers[l.lane - 1] if 1 <= l.lane <= len(centers) else cx
        for band in l.bands:
            if band.strip is None:   # the other gels' marks are in their own pixels
                band.y = sround(turn(x, band.y)[1])
        if l.unit_y is not None and l.unit_strip is None:
            l.unit_y = sround(turn(x, l.unit_y)[1])
    for a in p.annotations:
        if a.strip is not None:
            continue
        x = (centers[-1] if centers else cx) if a.side == "right" else (centers[0] if centers else cx)
        a.y = sround(turn(x, a.y)[1])
        if a.y2 is not None:
            a.y2 = sround(turn(x, a.y2)[1])
    p.sync_lane_centers(w, h)


def set_rotation(p: GelProject, degrees: float, w: int, h: int) -> None:
    before = p.effective_rotation
    p.rotate_deg = sround(degrees * 100) / 100
    rotate_marks(p, p.effective_rotation - before, w, h)


def set_strict(p: GelProject, strict: bool, w: int, h: int, strip_sizes: list[Optional[tuple[int, int]]] = (),
               strip: Optional[int] = None) -> None:
    """Keep original pixels on or off for one gel: strip None = the gel with the lanes (the project's own setting, which
    the gels with no setting of their own follow), else gel k's own setting. Keeping them ignores the rotation (off
    applies it again); the marks of every gel whose rotation that changes follow, given the gels' working-image sizes (in
    strips order; None for a gel whose image can't be read)."""
    before = p.effective_rotation
    strip_before = [0.0 if p.is_strict(k + 1) else s.rotate_deg for k, s in enumerate(p.strips)]
    if strip is None:
        p.strict = strict
    elif 1 <= strip <= len(p.strips):
        p.strips[strip - 1].strict = strict
    rotate_marks(p, p.effective_rotation - before, w, h)
    for i, size in enumerate(strip_sizes):
        if size is not None and i < len(p.strips):
            now = 0.0 if p.is_strict(i + 1) else p.strips[i].rotate_deg
            rotate_strip_marks(p, i + 1, now - strip_before[i], size[0], size[1])


# ---------------------------------------------------------------------------------------------------- stacked gels


def lane_x(p: GelProject, lane: int, strip: int) -> Optional[float]:
    """Lane n's centre in gel k's own pixels (the lanes are the main image's, lined up through the alignment)."""
    if not (1 <= lane <= len(p.lanes.centers) and 1 <= strip <= len(p.strips)):
        return None
    shift, scale = p.lane_alignment(strip)   # the lanes are the lanes gel's, wherever it sits
    return scale * p.lanes.centers[lane - 1] + shift


def rotate_strip_marks(p: GelProject, strip: int, delta: float, w: int, h: int) -> None:
    """Moves gel k's ticks and names with its image when it turns by delta degrees (as rotate_marks)."""
    if abs(delta) <= 1e-9 or not 1 <= strip <= len(p.strips):
        return
    t = math.radians(delta)
    c, s = math.cos(t), math.sin(t)
    cx, cy = (w - 1) / 2, (h - 1) / 2

    def turn_y(x, y):
        return -s * (x - cx) + c * (y - cy) + cy

    if p.ladder is not None:
        x = lane_x(p, p.ladder.lane, strip)
        x = cx if x is None else x
        for b in p.ladder.bands:
            if b.strip == strip:
                b.y = sround(turn_y(x, b.y))
        if p.ladder.unit_y is not None and p.ladder.unit_strip == strip:
            p.ladder.unit_y = sround(turn_y(x, p.ladder.unit_y))
    n = len(p.lanes.centers)
    for a in p.annotations:
        if a.strip != strip:
            continue
        x = lane_x(p, n if a.side == "right" else 1, strip)
        x = cx if x is None else x
        a.y = sround(turn_y(x, a.y))
        if a.y2 is not None:
            a.y2 = sround(turn_y(x, a.y2))


def set_strip_rotation(p: GelProject, strip: int, degrees: float, w: int, h: int) -> None:
    """Straightens gel k (it resamples, so it only applies while that gel doesn't keep its original pixels); its marks
    move with it."""
    if not 1 <= strip <= len(p.strips):
        return
    s = p.strips[strip - 1]
    before = 0.0 if p.is_strict(strip) else s.rotate_deg
    s.rotate_deg = sround(degrees * 100) / 100
    rotate_strip_marks(p, strip, (0.0 if p.is_strict(strip) else s.rotate_deg) - before, w, h)


def turn(p: GelProject, strip: Optional[int], quarter_turns: int, w: int, h: int) -> None:
    """Turns a gel by quarter turns (strip None = the main image); w×h is its working image before. A half turn
    carries its marks across; a quarter turn makes lanes run the other way, so that gel's marks go (crop, and for the
    main image its dividers)."""
    q = quarter_turns % 4
    if q == 0:
        return
    if strip is not None:
        if not 1 <= strip <= len(p.strips):
            return
        s = p.strips[strip - 1]
        s.turn = (s.turn + q) % 4
        if q == 2:
            s.top, s.bottom = (None if s.bottom is None else h - s.bottom), (None if s.top is None else h - s.top)
            s.left, s.right = (None if s.right is None else w - s.right), (None if s.left is None else w - s.left)
            # a crop that doesn't fit the gel (it should have, before) goes back to the whole gel
            t, b = (0.0 if s.top is None else s.top), (float(h) if s.bottom is None else s.bottom)
            if not (t >= 0 and t < b <= h):
                s.top = s.bottom = None
            l, r = (0.0 if s.left is None else s.left), (float(w) if s.right is None else s.right)
            if not (l >= 0 and l < r <= w):
                s.left = s.right = None
        else:
            s.top = s.bottom = s.left = s.right = None   # a quarter turn swaps width and height: the crop starts over
    else:
        p.turn = (p.turn + q) % 4
        if q != 2:
            p.main_shift = 0.0   # a quarter turn swaps the gel's width and height: where it sat sideways starts over
        if q == 2:
            if p.crop is not None:
                r = p.crop
                p.crop = PixelRect(w - r.x1, h - r.y1, w - r.x0, h - r.y0)
            for d in p.lanes.dividers:
                d.x_top, d.x_bottom, d.dot_y = w - 1 - d.x_bottom, w - 1 - d.x_top, h - 1 - d.dot_y
            p.lanes.dividers.sort(key=lambda d: d.x_top + d.x_bottom)
        else:
            p.crop = None
            p.lanes.dividers = []
            p.lanes.centers = []
    l = p.ladder
    if l is not None:
        if q == 2:
            for b in l.bands:
                if b.strip == strip:
                    b.y = h - 1 - b.y
        else:
            l.bands = [b for b in l.bands if b.strip != strip]
        if l.unit_y is not None and l.unit_strip == strip:   # the unit label goes with its gel
            if q == 2:
                l.unit_y = h - 1 - l.unit_y
            else:
                l.unit_y = l.unit_strip = None
    if q == 2:
        for a in p.annotations:
            if a.strip == strip:
                a.y = h - 1 - a.y
                if a.y2 is not None:
                    a.y2 = h - 1 - a.y2
    else:
        remove_annotations(p, lambda a: a.strip == strip)
    if strip is None and q == 2:
        p.sync_lane_centers(w, h)


def remove_strip(p: GelProject, k: int) -> None:
    """Takes gel k (its number in strips) out, with its ticks and names; the gels under it move up one."""
    if not 1 <= k <= len(p.strips):
        return
    if k - 1 < p.main_slot:
        p.main_position = p.main_slot - 1
    del p.strips[k - 1]

    def renumber(s):
        return None if s is None else (s - 1 if s > k else s)

    if p.ladder is not None:
        p.ladder.bands = [b for b in p.ladder.bands if b.strip != k]
        for b in p.ladder.bands:
            b.strip = renumber(b.strip)
        if p.ladder.unit_strip == k:   # the unit label went with its gel
            p.ladder.unit_y = p.ladder.unit_strip = None
        else:
            p.ladder.unit_strip = renumber(p.ladder.unit_strip)
    remove_annotations(p, lambda a: a.strip == k)
    for a in p.annotations:
        a.strip = renumber(a.strip)


def reorder(p: GelProject, order: list[int]) -> None:
    """Puts the gels in a new order: order[i] is the current place (from 0 at the top) of the gel that goes to place
    i. Ignored unless it lists every place once."""
    ids = p.stack_order
    if len(order) != len(ids) or set(order) != set(range(len(ids))):
        return
    wanted = [ids[i] for i in order]
    old = p.strips
    number = {}   # old gel number → new
    strips = []
    for k in wanted:
        if k is not None:
            strips.append(old[k - 1])
            number[k] = len(strips)
    p.strips = strips
    p.main_position = wanted.index(None)
    if p.ladder is not None:
        p.ladder.bands = [b for b in p.ladder.bands if b.strip is None or b.strip in number]   # none should name a missing gel
        for b in p.ladder.bands:
            if b.strip is not None:
                b.strip = number[b.strip]
        if p.ladder.unit_strip is not None:
            p.ladder.unit_strip = number.get(p.ladder.unit_strip)
            if p.ladder.unit_strip is None:
                p.ladder.unit_y = None
    remove_annotations(p, lambda a: a.strip is not None and a.strip not in number)
    for a in p.annotations:
        if a.strip is not None:
            a.strip = number[a.strip]


def move_gel(p: GelProject, src: int, dst: int) -> None:
    """Moves the gel at place src in the stack (from 0 at the top) to place dst; the others keep their order. Each gel
    keeps its own settings, ticks and names."""
    order = list(range(len(p.stack_order)))
    if not (0 <= src < len(order) and 0 <= dst < len(order)) or src == dst:
        return
    order.insert(dst, order.pop(src))
    reorder(p, order)


def leveling_angle(a: tuple[float, float], b: tuple[float, float]) -> float:
    """The rotation change that levels a line from a to b: to horizontal if flatter than 45°, else vertical."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    if abs(dx) >= abs(dy):
        dxp, dyp = (-dx, -dy) if dx < 0 else (dx, dy)
        return math.degrees(math.atan2(dyp, dxp))
    dxp, dyp = (-dx, -dy) if dy < 0 else (dx, dy)
    return -math.degrees(math.atan2(dxp, dyp))


# ---------------------------------------------------------------------------------------------------- labels


def apply_quick_labels(p: GelProject, text: str, group_row_name: Optional[str] = None,
                       keep_titles: bool = True) -> ql.Result:
    """Lane labels from the shorthand. keep_titles: with no titles typed, keep the rows' current ones (pasting bare
    labels from another gel); off when the text is the project's own shorthand being edited."""
    typed, body = ql.split_row_name(text)
    names = ([r.name or "" for r in reversed([r for r in p.rows if r.type == "groups"])]
             if not typed and keep_titles else typed)
    if group_row_name is not None:
        names = names[:-1] + [group_row_name]
    items, warnings = ql.parse(body)
    r = ql.build(items, p.lane_count, p.ladder.lane if p.ladder else None, names)
    r.warnings = warnings + r.warnings
    layers = len(r.rows) - 1
    if len(typed) > layers:
        r.warnings.append(f"{len(typed)} row titles for {layers} label row{'' if layers == 1 else 's'} above the "
                          "lanes; the top ones were left out.")
    angle = p.label_angle   # the figure's one label angle survives retyping the labels
    group_angles = [row.rotation for row in p.rows if row.type == "groups"]   # and each group row's, by its place among them
    p.rows = r.rows
    if angle > 0:
        set_label_angle(p, angle)
    for row, was in zip([row for row in p.rows if row.type == "groups"], group_angles):
        row.rotation = was
    if r.ladder_lane is not None:
        if p.ladder is None:
            p.ladder = Ladder(lane=r.ladder_lane)
        else:
            p.ladder.lane = r.ladder_lane
    return r


def set_label_angle(p: GelProject, degrees: float) -> bool:
    """Stands the lane labels at degrees (0 horizontal, 90 straight up), any angle, brought into 0 to 360: set on every row
    of lane labels, so the figure has one angle (GelProject.label_angle). Returns False, changing nothing, when degrees isn't
    a number or there are no lane labels yet."""
    if not math.isfinite(degrees):
        return False
    angle = LabelRow.clamped_angle(degrees)
    rows = [r for r in p.rows if r.type == "lanes"]
    for r in rows:
        r.rotation = angle
    return bool(rows)


# ---------------------------------------------------------------------------------------------------- ladder


def add_tick(p: GelProject, y: float, size: Optional[float], auto: bool = False, lane: Optional[int] = None,
             gel_center_x: Optional[float] = None, strip: Optional[int] = None) -> LadderBand:
    """A tick at y (usually snapped to a band centre) on gel strip (None = the one with the lanes). The first tick
    also fixes the ladder lane and side."""
    if p.ladder is None:
        l = Ladder(lane=lane or 1)
        if lane is not None and gel_center_x is not None and lane <= len(p.lanes.centers):
            l.side = "right" if p.lanes.centers[lane - 1] > gel_center_x else "left"
        p.ladder = l
    elif lane is not None and not p.ladder.bands:
        p.ladder.lane = lane
    band = LadderBand(y, size, auto=auto and size is not None, strip=strip)
    p.ladder.bands.append(band)
    p.ladder.bands.sort(key=lambda b: p.stack_key(b.strip, b.y))
    return band


def ladder_sizes(p: GelProject, preset: Optional[LadderPreset]) -> list[float]:
    if p.ladder is not None and p.ladder.sizes is not None:
        return p.ladder.sizes
    return preset.sizes if preset else []


def suggested_size(p: GelProject, y: float, preset: Optional[LadderPreset], strip: Optional[int] = None) -> Optional[float]:
    """The size whose rank matches the tick's rank from the top, through the gels that share its ladder (see
    GelProject.ladder_groups). Ticks a crop hides don't count. A guess."""
    sizes = ladder_sizes(p, preset)
    key = p.stack_key(strip, y - 0.5)
    group = p.ladder_group_of(strip)
    above = len([b for b in (p.ladder.bands if p.ladder else [])
                 if not b.ignore and p.is_in_figure(b.strip, b.y) and p.ladder_group_of(b.strip) == group
                 and p.stack_key(b.strip, b.y) < key])
    return sizes[above] if above < len(sizes) else None


def set_own_ladder(p: GelProject, strip: Optional[int], on: bool) -> None:
    """Gel strip (None = the one with the lanes) starts its ladder sizes again from the top of the list, or with on False
    carries on from the gel above. With a ladder chosen (it has a size list), the sizes are then assigned top-down
    again, as Assign top-down does. Setting what's already set changes nothing."""
    if strip is None:
        if p.own_ladder == on:
            return
        p.own_ladder = on
    elif 1 <= strip <= len(p.strips):
        if p.strips[strip - 1].own_ladder == on:
            return
        p.strips[strip - 1].own_ladder = on
    else:
        return
    if p.ladder is not None and p.ladder.sizes:
        p.assign_ladder(p.ladder.sizes)


def apply_preset(p: GelProject, preset: LadderPreset) -> None:
    """Adopts a preset's size list and guesses sizes for the ticks top-down (marked auto)."""
    if p.ladder is None:
        p.ladder = Ladder()
    p.ladder.name = preset.display_name
    p.ladder.unit = preset.unit
    sys_ = preset.system(p.ladder.system) or (preset.systems[0] if preset.systems else None)
    sizes = sys_.sizes if sys_ else preset.sizes
    p.ladder.sizes = list(sizes)
    p.ladder.system = sys_.name if sys_ else None
    p.assign_ladder(sizes)


def apply_system(p: GelProject, preset: LadderPreset, system: LadderSystem) -> None:
    """A gel system's apparent sizes. Ticks keep their protein: the i-th size of the old list becomes the i-th of
    the new one (None if that band runs off the new gel). Guess/confirmed flags stay."""
    if p.ladder is None:
        p.ladder = Ladder()
    old = p.ladder.sizes if p.ladder.sizes is not None else preset.sizes
    for b in p.ladder.bands:
        if b.size is None or b.size not in old:
            continue
        k = old.index(b.size)
        b.size = system.sizes[k] if k < len(system.sizes) else None
    p.ladder.name = preset.display_name
    p.ladder.unit = preset.unit
    p.ladder.sizes = list(system.sizes)
    p.ladder.system = system.name


def parse_sizes(text: str) -> list[float]:
    """"250, 130 | 100 70" → [250, 130, 100, 70]; largest first."""
    out = []
    for tok in re.split(r"[,;| \t\n]+", text):
        tok = tok.replace("kDa", "").replace("bp", "")
        try:
            v = float(tok)
        except ValueError:
            continue
        if v > 0:
            out.append(v)
    return sorted(out, reverse=True)


# ---------------------------------------------------------------------------------------------------- names


def add_annotation(p: GelProject, text: str, y: float, marker: str = "arrow", side: Optional[str] = None,
                   strip: Optional[int] = None) -> BandAnnotation:
    s = side or ("left" if p.ladder is not None and p.ladder.side == "right" else "right")
    a = BandAnnotation(y, text, marker=marker, side=s, strip=strip)
    p.annotations.append(a)
    return a


def _keep_annotations(p: GelProject, keep: list[int]) -> None:
    p.annotations = [p.annotations[i] for i in keep]
    p.style.remap_name_sizes(keep)   # every name keeps its own single-name size


def remove_annotations(p: GelProject, is_removed: Callable[[BandAnnotation], bool]) -> int:
    """Takes out the band names is_removed picks, so every other name keeps its own single-name size. Returns how many
    went."""
    keep = [i for i, a in enumerate(p.annotations) if not is_removed(a)]
    removed = len(p.annotations) - len(keep)
    if removed:
        _keep_annotations(p, keep)
    return removed


def delete_annotation(p: GelProject, index: int) -> None:
    """Takes out band name number index (from 0), as remove_annotations does."""
    if 0 <= index < len(p.annotations):
        _keep_annotations(p, [i for i in range(len(p.annotations)) if i != index])


# ---------------------------------------------------------------------------------------------------- rows


def rows_message(height: int) -> str:
    """What to tell the user when rows can't be used."""
    return f"Rows must be top,bottom with top < bottom, inside 0–{height}."


def set_strip_rows(p: GelProject, k: int, top: float, bottom: float, height: int) -> bool:
    """Sets the rows of gel k (its number in strips) that go into the figure. top and bottom are clamped to 0…height (the
    gel's height in its turned image). Returns False, with the rows left as they were, when that leaves no rows (top must
    be less than bottom) or either isn't a number."""
    if not (1 <= k <= len(p.strips) and math.isfinite(top) and math.isfinite(bottom) and height > 0):
        return False
    h = float(height)
    t, b = min(max(top, 0.0), h), min(max(bottom, 0.0), h)
    if not t < b:
        return False
    p.strips[k - 1].top, p.strips[k - 1].bottom = t, b
    return True


def crop_message(width: int, height: int) -> str:
    """The message for a crop that can't be used."""
    return f"A crop must be X0,Y0,X1,Y1 with X0 < X1 and Y0 < Y1, inside 0–{width} across and 0–{height} down."


def set_strip_crop(p: GelProject, k: int, left: float, top: float, right: float, bottom: float, width: int,
                   height: int) -> bool:
    """Sets the crop of gel k (its number in strips): the columns and rows of it that go into the figure, clamped to the gel's
    image (width × height, after its quarter turns). Returns False, with the crop left as it was, when that leaves nothing
    (left must be less than right, top less than bottom) or a value isn't a number."""
    if not (1 <= k <= len(p.strips) and all(math.isfinite(v) for v in (left, top, right, bottom)) and width > 0 and height > 0):
        return False
    w, h = float(width), float(height)
    l, r = min(max(left, 0.0), w), min(max(right, 0.0), w)
    t, b = min(max(top, 0.0), h), min(max(bottom, 0.0), h)
    if not (l < r and t < b):
        return False
    s = p.strips[k - 1]
    s.left, s.right, s.top, s.bottom = l, r, t, b
    return True


def align_strip(p: GelProject, k: int, shift: float, scale: float) -> None:
    """Stores the fit of gel k to the lanes (find_alignment's shift and scale): the fit is to the lanes wherever the gel with
    the lanes sits, and a gel's shift is its place in the figure (GelProject.shift_to_store)."""
    s = p.strips[k - 1]
    s.shift, s.scale = p.shift_to_store(shift, scale), scale


def place_gel(p: GelProject, k: Optional[int], v: float) -> None:
    """Puts gel k (None = the gel with the lanes) at shift v: whole pixels for the lanes gel and for a gel that keeps its
    original pixels, hundredths of a pixel for the others. No other gel's place changes."""
    if not math.isfinite(v):
        return
    limit = 1_000_000.0
    if k is not None:
        p.strips[k - 1].shift = min(max(sround(v) if p.is_strict(k) else sround(v * 100) / 100, -limit), limit)
    else:
        p.main_shift = min(max(sround(v), -limit), limit)


def set_row_angle(p: GelProject, row: int, degrees: float) -> bool:
    """Stands the group labels of row row (its place in rows, index 0 on the gel) at degrees, any angle, brought into
    0 ..< 360: each group row has its own, the underline stays flat. Returns False, changing nothing, when degrees isn't a
    number or row isn't a row of group labels (lane labels share the figure's one angle: set_label_angle)."""
    if not (math.isfinite(degrees) and 0 <= row < len(p.rows) and p.rows[row].type == "groups"):
        return False
    p.rows[row].rotation = LabelRow.clamped_angle(degrees)
    return True


# ---------------------------------------------------------------------------------------------------- crop


def suggest_crop(p: GelProject, w: int, h: int) -> PixelRect:
    """Lanes with a small margin across; top to bottom, stopping below the lowest labelled ladder band."""
    r = PixelRect(0, 0, w, h)
    g = geometry(p, w, h)
    if g is not None and g.count > 0:
        first, last = g.boundaries[0], g.boundaries[g.count]
        r.x0 = max(0.0, min(first.x_top, first.x_bottom) - 6)
        r.x1 = min(float(w), max(last.x_top, last.x_bottom) + 6)
    labelled = [b.y for b in (p.ladder.bands if p.ladder else []) if not b.ignore and b.size is not None and b.strip is None]
    if labelled:
        ys = sorted(b.y for b in p.ladder.bands if b.strip is None)
        gaps = sorted(b - a for a, b in zip(ys, ys[1:]))
        step = gaps[len(gaps) // 2] if gaps else 60
        r.y1 = min(float(h), max(labelled) + max(40, step * 0.6))
    return r.normalized(w, h)
