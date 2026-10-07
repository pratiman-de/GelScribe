"""Figure layout: where every label, tick and line goes, in points with y pointing down. The same engine draws the
screen and every export, so what you see is what you get."""
from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field
from functools import lru_cache
from typing import NamedTuple, Optional

from .model import GelProject, LADDER_UNIT, LabelRow, PixelRect, Role, TITLE, format_size

#: fonts are made at this many pixels per point, so fractional sizes (7.5 pt) stay exact and nothing depends on
#: the screen's DPI
TEXT_SCALE = 100


def ensure_gui() -> None:
    """Font metrics need a Qt GUI application; make an off-screen one when used without the app (tests, scripts)."""
    from PySide6.QtGui import QGuiApplication
    if QGuiApplication.instance() is None:
        import os
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        global _app_keepalive
        _app_keepalive = QGuiApplication([])


_app_keepalive = None


class FontSpec(NamedTuple):
    family: str
    size: float
    bold: bool = False
    italic: bool = False


@lru_cache(maxsize=256)
def qfont(f: FontSpec):
    from PySide6.QtGui import QFont
    ensure_gui()
    q = QFont(f.family)
    q.setPixelSize(max(1, int(math.floor(f.size * TEXT_SCALE + 0.5))))
    q.setBold(f.bold)
    q.setItalic(f.italic)
    q.setKerning(True)
    q.setHintingPreference(QFont.HintingPreference.PreferNoHinting)
    return q


@lru_cache(maxsize=256)
def _fm(f: FontSpec):
    from PySide6.QtGui import QFontMetricsF
    return QFontMetricsF(qfont(f))


class Metrics(NamedTuple):
    ascent: float
    descent: float
    cap_height: float
    leading: float


@lru_cache(maxsize=256)
def metrics(f: FontSpec) -> Metrics:
    m = _fm(f)
    s = TEXT_SCALE * (max(1, int(math.floor(f.size * TEXT_SCALE + 0.5))) / (f.size * TEXT_SCALE)) if f.size > 0 else 1
    return Metrics(m.ascent() / s, m.descent() / s, m.capHeight() / s, m.leading() / s)


@lru_cache(maxsize=4096)
def text_width(s: str, f: FontSpec) -> float:
    px = max(1, int(math.floor(f.size * TEXT_SCALE + 0.5)))
    return _fm(f).horizontalAdvance(s) * f.size / px if f.size > 0 else 0.0


def line_height(f: FontSpec) -> float:
    """Baseline to baseline within one label."""
    m = metrics(f)
    return m.ascent + m.descent + max(m.leading, 0.03 * f.size)


# ---------------------------------------------------------------------------------------------------- results


@dataclass
class Rect:
    x: float
    y: float
    w: float
    h: float

    @property
    def min_x(self):
        return self.x

    @property
    def min_y(self):
        return self.y

    @property
    def max_x(self):
        return self.x + self.w

    @property
    def max_y(self):
        return self.y + self.h

    @property
    def mid_x(self):
        return self.x + self.w / 2

    @property
    def mid_y(self):
        return self.y + self.h / 2

    def union(self, o: "Rect") -> "Rect":
        x0, y0 = min(self.x, o.x), min(self.y, o.y)
        return Rect(x0, y0, max(self.max_x, o.max_x) - x0, max(self.max_y, o.max_y) - y0)

    def offset(self, dx: float, dy: float) -> "Rect":
        return Rect(self.x + dx, self.y + dy, self.w, self.h)

    def inset(self, dx: float, dy: float) -> "Rect":
        return Rect(self.x + dx, self.y + dy, self.w - 2 * dx, self.h - 2 * dy)

    def contains(self, x: float, y: float) -> bool:
        return self.x <= x <= self.max_x and self.y <= y <= self.max_y


@dataclass
class FigureText:
    string: str
    font: FontSpec
    #: baseline anchor, points, y down
    origin: tuple[float, float]
    #: "left", "center" or "right"
    align: str
    #: degrees, counter-clockwise on screen, about origin
    rotation: float
    role: Role
    #: axis-aligned bounds, y down
    bounds: Rect
    #: for labels with line breaks: baseline to baseline, and the first line's baseline relative to origin
    line_height: float = 0.0
    first_baseline: float = 0.0

    @property
    def lines(self) -> list[str]:
        return self.string.split("\n")

    def _extent(self) -> tuple[float, float, float, float]:
        """The text's own box in its own frame (x along the text from origin, y down from the baseline): ascent of its first
        line to descent of its last. (u0, u1, v0, v1)."""
        m = metrics(self.font)
        ends = []
        for line in self.lines:
            w = text_width(line, self.font)
            dx = 0 if self.align == "left" else (-w / 2 if self.align == "center" else -w)
            ends.append((dx, dx + w))
        return (min(e[0] for e in ends), max(e[1] for e in ends), self.first_baseline - m.ascent,
                self.first_baseline + (len(self.lines) - 1) * self.line_height + m.descent)

    @property
    def box(self) -> list[tuple[float, float]]:
        """The text's own box as four corners in figure points: a rotated rectangle for rotated text (the axis-aligned
        bounds around it are bigger). What a click on the text is tested against."""
        u0, u1, v0, v1 = self._extent()
        t = math.radians(self.rotation)
        ox, oy = self.origin
        return [(ox + u * math.cos(t) + v * math.sin(t), oy - u * math.sin(t) + v * math.cos(t))
                for u, v in ((u0, v0), (u1, v0), (u1, v1), (u0, v1))]

    def contains(self, x: float, y: float, pad_x: float = 0.0, pad_y: float = 0.0) -> bool:
        """Whether the point (figure points) is inside the text's own box, which for rotated text is the rotated rectangle.
        pad_x and pad_y widen the box along and across the text."""
        u0, u1, v0, v1 = self._extent()
        t = math.radians(self.rotation)
        dx, dy = x - self.origin[0], y - self.origin[1]
        u, v = dx * math.cos(t) - dy * math.sin(t), dx * math.sin(t) + dy * math.cos(t)   # the point in the text's own frame
        return u0 - pad_x <= u <= u1 + pad_x and v0 - pad_y <= v <= v1 + pad_y


@dataclass
class FigureLine:
    points: list[tuple[float, float]]
    width: float


@dataclass
class FigureLayout:
    size: tuple[float, float]
    #: where the cropped gel image goes, points, y down
    gel_rect: Rect
    crop: PixelRect
    #: points per gel pixel
    pt_per_px: float
    texts: list[FigureText] = field(default_factory=list)
    lines: list[FigureLine] = field(default_factory=list)
    #: filled polygons (arrowheads)
    fills: list[list[tuple[float, float]]] = field(default_factory=list)
    border_width: Optional[float] = None

    def point(self, x: float, y: float) -> tuple[float, float]:
        """Gel pixel → figure point."""
        return (self.gel_rect.x + (x - self.crop.x0) * self.pt_per_px,
                self.gel_rect.y + (y - self.crop.y0) * self.pt_per_px)

    def pixel(self, px: float, py: float) -> tuple[float, float]:
        """Figure point → gel pixel."""
        return ((px - self.gel_rect.x) / self.pt_per_px + self.crop.x0,
                (py - self.gel_rect.y) / self.pt_per_px + self.crop.y0)


# ---------------------------------------------------------------------------------------------------- engine


def spread_1d(targets: list[float], sep: float) -> list[float]:
    """Positions ≥ sep apart, order kept, each cluster centred on its targets (minimal total displacement)."""
    clusters: list[list[float]] = []   # [start, n, acc]
    for t in targets:
        clusters.append([t, 1, t])
        while len(clusters) > 1 and clusters[-2][0] + clusters[-2][1] * sep > clusters[-1][0]:
            b = clusters.pop()
            a = clusters.pop()
            acc = a[2] + b[2] - b[1] * a[1] * sep
            n = a[1] + b[1]
            clusters.append([acc / n, n, acc])
    return [c[0] + k * sep for c in clusters for k in range(int(c[1]))]


def spread_1d_gaps(targets: list[float], gaps: list[float]) -> list[float]:
    """Like spread_1d, with its own minimum distance between each neighbouring pair (gaps[i] between i and i + 1)."""
    offset = [0.0] * len(targets)
    clusters: list[list] = []   # [first, last, start]
    for i in range(len(targets)):
        clusters.append([i, i, targets[i]])
        while len(clusters) > 1:
            b, a = clusters[-1], clusters[-2]
            if not a[2] + offset[a[1]] + gaps[a[1]] > b[2]:
                break
            base = offset[a[1]] + gaps[a[1]]
            for k in range(b[0], b[1] + 1):
                offset[k] += base
            clusters.pop()
            clusters.pop()
            mean = sum(targets[k] - offset[k] for k in range(a[0], b[1] + 1)) / (b[1] - a[0] + 1)
            clusters.append([a[0], b[1], mean])
    out = [0.0] * len(targets)
    for c in clusters:
        for k in range(c[0], c[1] + 1):
            out[k] = c[2] + offset[k]
    return out


def layout(p: GelProject, image_width: int, image_height: int, stack=None) -> FigureLayout:
    """stack: where the other gels go, for a figure of several (see strips.StackGeometry); their ticks and names are
    left out without it."""
    st = p.style
    crop = stack.crop if stack is not None else p.effective_crop(image_width, image_height)

    def figure_y(strip, y):
        """Figure row of a mark at y in its own gel, if it's in the figure."""
        if stack is not None:
            return stack.figure_y(strip, y)
        return y if strip is None and crop.y0 <= y <= crop.y1 else None

    def name_y(strip, y):
        if stack is not None:
            return stack.name_y(strip, y)
        return y if strip is None else None
    gel_w = st.gel_width_in * 72
    s = gel_w / crop.width
    gel_h = crop.height * s
    lw = st.line_width_pt
    texts: list[FigureText] = []
    lines: list[FigureLine] = []
    fills: list[list[tuple[float, float]]] = []

    def X(px):
        return (px - crop.x0) * s

    def Y(py):
        return (py - crop.y0) * s

    centers = p.lanes.centers

    def lane_x(n: int) -> Optional[float]:
        if n < 1 or n > len(centers):
            return None
        c = centers[n - 1]
        return X(c) if crop.x0 <= c <= crop.x1 else None

    lane_half = p.lanes.width * s / 2

    def text(string: str, f: FontSpec, at: tuple[float, float], align: str, rotation: float = 0.0,
             role: Role = TITLE, anchor: str = "bottom") -> FigureText:
        lns = string.split("\n")
        m = metrics(f)
        lh = line_height(f)
        first = -(len(lns) - 1) * lh * (1 if anchor == "bottom" else 0.5)
        corners = []
        for k, ln in enumerate(lns):
            w = text_width(ln, f)
            dx = 0 if align == "left" else (-w / 2 if align == "center" else -w)
            base = first + k * lh
            corners += [(dx, base - m.ascent), (dx + w, base - m.ascent), (dx, base + m.descent), (dx + w, base + m.descent)]
        t = math.radians(rotation)
        ox, oy = at
        pts = [(ox + cx * math.cos(t) + cy * math.sin(t), oy - cx * math.sin(t) + cy * math.cos(t)) for cx, cy in corners]
        xs, ys = [q[0] for q in pts], [q[1] for q in pts]
        b = Rect(min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys))
        return FigureText(string, f, at, align, rotation, role, b, lh, first)

    # --- label rows, stacked upward from the gel's top edge
    y_above = 2.0
    for ri, row in enumerate(p.rows):
        kind = "groupLabel" if row.type == "groups" else "laneLabel"

        def font(role: Role) -> FontSpec:
            return FontSpec(st.font, st.size_for(role), row.bold)

        # the row is as tall as its biggest label; every label sits on the same baseline
        if row.type == "lanes":
            roles = [Role("laneLabel", ri, i + 1) for i, lab in enumerate(row.labels) if lab != ""]
        else:
            roles = [Role("groupLabel", ri, gi) for gi in range(len(row.groups))]
        sizes = [st.size_for(r) for r in roles]
        big = FontSpec(st.font, max(sizes) if sizes else st.size_for_kind(kind), row.bold)
        m = metrics(big)
        row_texts: list[FigureText] = []
        row_height = m.ascent + m.descent
        text_baseline = -(y_above + m.descent)
        leftmost = math.inf

        # lane labels and group labels may stand at an angle; row titles, names and ladder sizes stay horizontal
        angle = LabelRow.clamped_angle(row.rotation)
        t = math.radians(angle)
        sn, cs = math.sin(t), math.cos(t)

        def turned(lab: str, f: FontSpec, over: float, bottom: float, role: Role) -> FigureText:
            """A label standing at angle (not 0), over x = over. Any angle. The end of its middle line (half a cap height
            above the baseline) nearest the gel sits over x: the start while the text rises (under 180°), the end while it
            falls (over 180°), the middle when it's level (180°). Lines of a longer label stack along the text's own "down"
            direction, the block centred on that line. The label then goes up or down so its lowest point is exactly on
            bottom, where horizontal labels' descenders end, so the gap above the gel (or above a group's underline) is the
            usual one."""
            half_cap = metrics(f).cap_height / 2
            w = max(text_width(line, f) for line in lab.split("\n"))
            along = 0.0 if sn > 1e-9 else w if sn < -1e-9 else w / 2
            # the middle line's point `along` the text: O + along (cos t, -sin t) - (c/2)(sin t, cos t), over x
            ox = over - along * cs + half_cap * sn
            probe = text(lab, f, (ox, 0.0), "left", angle, role, "middle")
            return text(lab, f, (ox, bottom - probe.bounds.max_y), "left", angle, role, "middle")

        if row.type == "lanes":
            if angle != 0:
                # The row reaches up to its highest rotated corner, so the rows above keep their usual gap above that point.
                highest = 0.0   # how far the highest corner is above the line horizontal descenders end on
                for i, lab in enumerate(row.labels):
                    if lab == "":
                        continue
                    x = lane_x(i + 1)
                    if x is None:
                        continue
                    role = Role("laneLabel", ri, i + 1)
                    tx = turned(lab, font(role), x, -y_above, role)
                    row_texts.append(tx)
                    highest = max(highest, -y_above - tx.bounds.min_y)
                    leftmost = min(leftmost, tx.bounds.min_x)
                if row_texts:
                    row_height = highest
            else:
                for i, lab in enumerate(row.labels):
                    if lab == "":
                        continue
                    x = lane_x(i + 1)
                    if x is None:
                        continue
                    role = Role("laneLabel", ri, i + 1)
                    tx = text(lab, font(role), (x, text_baseline), "center", 0, role)
                    row_texts.append(tx)
                    leftmost = min(leftmost, tx.bounds.min_x)
        else:
            rise = 2.5 if row.underline else 0
            text_baseline = -(y_above + rise + m.descent)
            row_height += rise
            highest = 0.0   # as for lane labels
            for gi, g in enumerate(row.groups):
                lo, hi = lane_x(g.first), lane_x(g.last)
                if lo is None or hi is None:
                    continue
                if row.underline:   # flat under the span, whatever the angle of the text
                    inset = lane_half * (1 - 2 * st.group_line_inset)
                    ly = -(y_above + 1.2)
                    lines.append(FigureLine([(lo - inset, ly), (hi + inset, ly)], lw))
                    leftmost = min(leftmost, lo - inset)
                if g.text != "":
                    role = Role("groupLabel", ri, gi)
                    if angle != 0:
                        # the same rules as turned lane labels, over the middle of the span, the lowest point where horizontal
                        # text would end: above the underline, with the usual gap
                        tx = turned(g.text, font(role), (lo + hi) / 2, -(y_above + rise), role)
                        row_texts.append(tx)
                        highest = max(highest, -y_above - tx.bounds.min_y)
                    else:
                        tx = text(g.text, font(role), ((lo + hi) / 2, text_baseline), "center", 0, role)
                        row_texts.append(tx)
                    leftmost = min(leftmost, tx.bounds.min_x)
            if angle != 0 and row_texts:
                row_height = highest
        if angle == 0:
            row_height += max([(len(t.lines) - 1) * t.line_height for t in row_texts], default=0)
        if row.name:   # stays horizontal, left of the row's leftmost point, on the baseline horizontal labels have
            right = leftmost - 3.5 if math.isfinite(leftmost) else -3.5
            nb = text_baseline
            nf = FontSpec(st.font, st.size_for(Role("rowName", ri)))
            name_lines = len(row.name.split("\n")) - 1
            row_height = max(row_height, metrics(nf).ascent + m.descent + name_lines * line_height(nf))
            row_texts.append(text(row.name, nf, (right, nb), "right", 0, Role("rowName", ri)))
        texts += row_texts
        y_above += row_height + st.row_gap_pt

    if p.title:
        f = FontSpec(st.font, st.title_size, True)
        m = metrics(f)
        texts.append(text(p.title, f, (gel_w / 2, -(y_above + 2 + m.descent)), "center", 0, TITLE))

    # --- ladder ticks; crowded labels spread apart and joined to their tick by a leader
    ladder_column_width = 0.0
    if p.ladder is not None:
        ladder = p.ladder
        f = FontSpec(st.font, st.size_for_kind("ladder"))
        m = metrics(f)
        tl = st.tick_len_pt
        right = ladder.side == "right"
        edge = gel_w if right else 0
        d = 1 if right else -1
        marks = sorted(((i, b, fy) for i, b in enumerate(ladder.bands) if not b.ignore and b.size is not None
                        for fy in [figure_y(b.strip, b.y)] if fy is not None), key=lambda ibf: ibf[2])
        band_y = [Y(fy) for _, _, fy in marks]
        label_y = spread_1d(band_y, f.size * st.label_sep)
        moved = any(abs(a - b) > 0.3 for a, b in zip(band_y, label_y))
        conn = st.leader_pt if moved else 0
        tx = edge + d * (tl + conn + 1.5)
        for k, (i, band, _) in enumerate(marks):
            lines.append(FigureLine([(edge, band_y[k]), (edge + d * tl, band_y[k])], lw))
            if conn > 0:
                lines.append(FigureLine([(edge + d * tl, band_y[k]), (edge + d * (tl + conn), label_y[k])], lw))
            t = text(format_size(band.size), f, (tx, label_y[k] + m.cap_height / 2), "left" if right else "right",
                     0, Role("ladderLabel", i))
            ladder_column_width = max(ladder_column_width, t.bounds.w + tl + conn + 1.5)
            texts.append(t)
        if marks:
            # where the user put it (centred on that row of its gel, like the numbers), else heading the column
            fy = figure_y(ladder.unit_strip, ladder.unit_y) if ladder.unit_y is not None else None
            y = Y(fy) + m.cap_height / 2 if fy is not None else -(2 + m.descent)
            texts.append(text(ladder.unit, f, (tx, y), "left" if right else "right", 0, LADDER_UNIT,
                              "bottom" if fy is None else "middle"))

    # --- band names at the edge; markers at the true y, text spread if crowded
    for side in ("left", "right"):
        # each name at its figure row (another gel's names converted from that gel's own pixels)
        items = []
        for i, a in enumerate(p.annotations):
            fy = name_y(a.strip, a.y) if a.side == side and a.text != "" else None
            if fy is None:
                continue
            b = copy.copy(a)
            b.y = fy
            if a.y2 is not None:
                y2 = name_y(a.strip, a.y2)
                b.y2 = fy if y2 is None else y2
            items.append((i, b))
        items.sort(key=lambda ia: ia[1].y)
        if not items:
            continue
        right = side == "right"
        d = 1 if right else -1
        shares = p.ladder is not None and p.ladder.side == side and ladder_column_width > 0
        edge = (gel_w if right else 0) + d * (ladder_column_width + 4 if shares else 0)
        name_size = st.size_for_kind("name")
        f_base = FontSpec(st.font, name_size)
        cap = metrics(f_base).cap_height
        anchor_y = [Y((a.y + a.y2) / 2) if a.marker == "bracket" and a.y2 is not None else Y(a.y) for _, a in items]
        line_counts = [len(a.text.split("\n")) for _, a in items]
        if all(n == 1 for n in line_counts):
            text_y = spread_1d(anchor_y, name_size * st.label_sep)
        else:
            lh = line_height(f_base)
            text_y = spread_1d_gaps(anchor_y, [name_size * st.label_sep + (a + b - 2) * lh / 2
                                                for a, b in zip(line_counts, line_counts[1:])])
        for k, (i, a) in enumerate(items):
            y = Y(a.y)
            if a.marker == "arrow":
                tip, hl, hw = edge + d * 1, 0.5 * name_size, 0.22 * name_size
                fills.append([(tip, y), (tip + d * hl, y - hw), (tip + d * hl, y + hw)])
                end = edge + d * 8
                lines.append(FigureLine([(tip + d * hl * 0.8, y), (end, y)], lw))
            elif a.marker == "tick":
                end = edge + d * st.tick_len_pt
                lines.append(FigureLine([(edge, y), (end, y)], lw))
            elif a.marker == "bracket":
                y2 = Y(a.y2 if a.y2 is not None else a.y)
                bx = edge + d * 3
                lines.append(FigureLine([(edge, y), (bx, y), (bx, y2), (edge, y2)], lw))
                end = bx
            else:
                end = edge
            start = end + d * 1.5
            if abs(text_y[k] - anchor_y[k]) > 0.3:   # leader to a displaced label
                lines.append(FigureLine([(end, anchor_y[k]), (end + d * 2.5, text_y[k])], lw))
                start = end + d * 4
            f = FontSpec(st.font, st.size_for(Role("annotation", i)), a.bold, a.italic)
            texts.append(text(a.text, f, (start, text_y[k] + cap / 2), "left" if right else "right", 0,
                              Role("annotation", i), "middle"))

    # --- bounding box, then shift so the gel origin lands on the gel's own pixel grid (exact raster export)
    bbox = Rect(0, 0, gel_w, gel_h)
    for t in texts:
        bbox = bbox.union(t.bounds)
    for l in lines:
        for (x, y) in l.points:
            bbox = bbox.union(Rect(x - lw, y - lw, 2 * lw, 2 * lw))
    for poly in fills:
        for (x, y) in poly:
            bbox = bbox.union(Rect(x, y, 0, 0))
    margin = 2.2
    tx = math.ceil((margin - bbox.min_x) / s) * s
    ty = math.ceil((margin - bbox.min_y) / s) * s

    def shift(q):
        return (q[0] + tx, q[1] + ty)

    for t in texts:
        t.origin = shift(t.origin)
        t.bounds = t.bounds.offset(tx, ty)
    lines = [FigureLine([shift(q) for q in l.points], l.width) for l in lines]
    fills = [[shift(q) for q in poly] for poly in fills]
    pw = math.ceil((bbox.max_x + tx + margin) / s) * s
    ph = math.ceil((bbox.max_y + ty + margin) / s) * s
    return FigureLayout((pw, ph), Rect(tx, ty, gel_w, gel_h), crop, s, texts, lines, fills,
                        lw if st.border else None)
