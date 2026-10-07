"""The canvas: the figure exactly as it exports, with the guides for placing lanes, ticks and names on top. Crop and
Straighten show the whole image instead, and so does the view of a stacked gel on its own (the switcher's Gel N)."""
from __future__ import annotations

import math
import sys
from typing import Optional

from PySide6.QtCore import QEvent, QPoint, QPointF, QRectF, Qt, Signal
from PySide6.QtGui import (QColor, QFont, QFontMetricsF, QKeyEvent, QMouseEvent, QPainter, QPainterPath, QPen,
                           QPolygonF, QWheelEvent)
from PySide6.QtWidgets import QWidget

from ..core import ops
from ..core import render
from ..core.layout import FigureLayout
from ..core.model import PixelRect, format_size, sround
from . import theme
from .workspace import FULL_IMAGE_TOOLS, Workspace

LANE = QColor(89, 204, 255)
TICK = QColor(255, 209, 26)
NAME = QColor(255, 102, 140)
GRAY = QColor(142, 142, 147)
ACCENT = QColor(61, 123, 246)


class Canvas(QWidget):
    tick_editor = Signal(int, QPoint)        # band index, where (global)
    name_editor = Signal(int, QPoint)
    text_editor = Signal(object, QPoint)     # Role
    zoom_changed = Signal(int)

    def __init__(self, ws: Workspace):
        super().__init__()
        self.ws = ws
        self.zoom: Optional[float] = None   # None = fit
        self.pan = QPointF(0, 0)
        self.drag = None
        self.press = None
        self.hover: Optional[QPointF] = None
        self.space_down = False
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.setMinimumSize(400, 300)
        if sys.platform != "darwin":   # touchscreens; a Mac trackpad pinch arrives as a native gesture (see event)
            self.grabGesture(Qt.GestureType.PinchGesture)
        ws.changed.connect(self.update)
        ws.view_changed.connect(self._view_changed)
        ws.zoom_request.connect(self.handle_zoom)

    def _view_changed(self):
        self.update()
        self.update_cursor()

    # ------------------------------------------------------------------------------------------------ mapping

    @property
    def full_view(self) -> bool:
        """Whether the canvas shows the chosen gel whole, in its own pixels: to crop or straighten it, or a stacked gel on its
        own (the gel with the lanes on its own is a figure, like a single gel's)."""
        return self.ws.tool in FULL_IMAGE_TOOLS or self.ws.views_other_gel

    crop_mode = full_view

    def available(self) -> QRectF:
        return QRectF(self.rect()).adjusted(28, 28, -28, -28)

    def content_size(self) -> tuple[float, float]:
        if self.full_view:   # the chosen gel's whole image
            w, h = self.ws.active_size
            return max(1, w), max(1, h)
        l = self.ws.shown_layout
        return (l.size[0], l.size[1]) if l else (1, 1)

    def fit_scale(self) -> float:
        sw, sh = self.content_size()
        a = self.available()
        return max(1e-4, min(a.width() / sw, a.height() / sh))

    def scale(self) -> float:
        return self.zoom if self.zoom is not None else self.fit_scale()

    def clamped(self, p: QPointF, sc: float) -> QPointF:
        """Pan stays on screen: a smaller figure up to the view's edges, a larger one until its edge is 20 px in."""
        sw, sh = self.content_size()
        a = self.available()
        lx = abs(a.width() - sw * sc) / 2 + 20
        ly = abs(a.height() - sh * sc) / 2 + 20
        return QPointF(min(lx, max(-lx, p.x())), min(ly, max(-ly, p.y())))

    def origin(self) -> QPointF:
        sw, sh = self.content_size()
        a = self.available()
        sc = self.scale()
        pn = self.clamped(self.pan, sc)
        return QPointF(round(a.center().x() - sw * sc / 2 + pn.x()), round(a.center().y() - sh * sc / 2 + pn.y()))

    def to_view(self, x: float, y: float) -> QPointF:
        o, sc = self.origin(), self.scale()
        return QPointF(o.x() + x * sc, o.y() + y * sc)

    def to_model(self, p: QPointF) -> tuple[float, float]:
        o, sc = self.origin(), self.scale()
        return (p.x() - o.x()) / sc, (p.y() - o.y()) / sc

    def px_view(self, x: float, y: float) -> QPointF:
        """Gel pixel → view point (figure mode)."""
        return self.to_view(*self.ws.shown_layout.point(x, y))

    def view_px(self, p: QPointF) -> tuple[float, float]:
        return self.ws.shown_layout.pixel(*self.to_model(p))

    def rect_view(self, x, y, w, h) -> QRectF:
        a, b = self.to_view(x, y), self.to_view(x + w, y + h)
        return QRectF(a, b)

    def gel_view(self) -> QRectF:
        g = self.ws.shown_layout.gel_rect
        return self.rect_view(g.x, g.y, g.w, g.h)

    def zoom_percent(self) -> int:
        return int(round(self.scale() * 100))

    def fit(self):
        self.zoom = None
        self.pan = QPointF(0, 0)
        self.update()
        self.zoom_changed.emit(self.zoom_percent())

    def handle_zoom(self, z: str):
        dpr = self.devicePixelRatioF() or 1
        if z == "fit":
            self.fit()
            return
        if z == "actual":
            self.zoom = (1 / (self.ws.shown_layout.pt_per_px * dpr)) if (self.ws.shown_layout and not self.full_view) else 1 / dpr
        elif z in ("in", "out"):
            self.zoom_by(1.25 if z == "in" else 0.8, self.available().center())
            return
        self.update()
        self.zoom_changed.emit(self.zoom_percent())

    def zoom_by(self, f: float, around: QPointF):
        mx, my = self.to_model(around)
        ns = min(60.0, max(0.02, self.scale() * f))
        sw, sh = self.content_size()
        a = self.available()
        cx, cy = a.center().x() - sw * ns / 2, a.center().y() - sh * ns / 2
        self.pan = self.clamped(QPointF(around.x() - mx * ns - cx, around.y() - my * ns - cy), ns)
        self.zoom = ns
        self.update()
        self.zoom_changed.emit(self.zoom_percent())

    # ------------------------------------------------------------------------------------------------ drawing

    def paintEvent(self, _e):
        p = QPainter(self)
        p.fillRect(self.rect(), theme.qcolor("canvas"))
        ws = self.ws
        if ws.working is None or ws.shown_layout is None:
            return
        p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        if self.full_view:
            self._draw_full(p)
            if ws.tool == "straighten":
                self._draw_straighten(p)
            elif ws.tool == "crop":
                self._draw_crop(p)
            else:
                self._draw_gel_view(p)
            return
        l = ws.shown_layout
        page = self.rect_view(0, 0, l.size[0], l.size[1])
        p.fillRect(page.translated(0, 6).adjusted(-2, 0, 2, 4), QColor(0, 0, 0, theme.C["page_shadow"]))
        p.fillRect(page, QColor(255, 255, 255))
        p.save()
        p.setClipRect(page)
        o, sc = self.origin(), self.scale()
        p.translate(o)
        p.scale(sc, sc)
        p.setRenderHint(QPainter.RenderHint.TextAntialiasing, True)
        smooth = sc * l.pt_per_px * (self.devicePixelRatioF() or 1) < 1
        self._draw_gel(p, l, smooth)
        render.draw_overlay(p, l)
        p.restore()
        if ws.show_guides:
            self._draw_guides(p, l)

    def _draw_gel(self, p: QPainter, l: FigureLayout, smooth: bool):
        """The gel of the figure, painted from each gel's own cached picture, placed as the stack places it (cut to its
        rows and columns, shifted and stretched to line up), with black or white lines between neighbours. Nothing is composed
        into one picture, so dragging a gel costs only a repaint."""
        g = l.gel_rect
        area = QRectF(g.x, g.y, g.w, g.h)
        layers = self.ws.gel_layers()
        crop, k = l.crop, l.pt_per_px
        p.save()
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, smooth)
        p.fillRect(area, QColor(255, 255, 255))
        line = QColor(*self.ws.line_rgb)
        for n, (q, img) in enumerate(layers):
            if n > 0:
                above = layers[n - 1][0]
                p.fillRect(QRectF(g.x, g.y + (above.bottom - crop.y0) * k, g.w, (q.top - above.bottom) * k), line)
            if img is None:
                continue
            # its picture's kept columns and rows, and where they go (cut at the picture's edges); the figure stays blank white
            # where the gel has no columns
            x0, x1 = q.source_left, q.source_right
            y0, y1 = q.source_top, q.source_bottom
            to = QRectF(g.x + (q.left - crop.x0) * k, g.y + (q.top - crop.y0) * k, (q.right - q.left) * k, (q.bottom - q.top) * k)
            cx0, cx1, cy0, cy1 = max(x0, 0.0), min(x1, float(img.width())), max(y0, 0.0), min(y1, float(img.height()))
            if cx1 <= cx0 or cy1 <= cy0 or x1 <= x0 or y1 <= y0:
                continue
            sx, sy = to.width() / (x1 - x0), to.height() / (y1 - y0)
            p.drawImage(QRectF(to.x() + (cx0 - x0) * sx, to.y() + (cy0 - y0) * sy, (cx1 - cx0) * sx, (cy1 - cy0) * sy),
                        img, QRectF(cx0, cy0, cx1 - cx0, cy1 - cy0))
        p.restore()

    def _draw_full(self, p: QPainter):
        ws = self.ws
        w, h = ws.active_size
        r = self.rect_view(0, 0, w, h)
        p.fillRect(r, QColor(255, 255, 255))
        img = ws.active_view
        if img is None:
            return
        p.save()
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, self.scale() * (self.devicePixelRatioF() or 1) < 1)
        p.drawImage(r, img)
        p.restore()

    def _lane_lines(self, p: QPainter, dashed: bool):
        """Where the lanes are in the chosen stacked gel: the lane dividers through its alignment, straight down from the top
        of the lanes gel's crop, which is where its lanes were lined up."""
        ws = self.ws
        k = ws.active_strip
        q = ws.shown_stack.piece(k) if (k is not None and ws.shown_stack) else None
        w, h = ws.active_size
        for d in ws.project.lanes.dividers:
            if q is not None:
                x = q.scale * d.x_at(ws.crop.y0, float(ws.image_h)) + q.shift
                self._line(p, self.to_view(x, 0), self.to_view(x, h), QColor(89, 204, 255, 160 if dashed else 115), 1, dash=dashed)
            else:   # faintly, to crop around the lanes
                self._line(p, self.to_view(d.x_top, 0), self.to_view(d.x_bottom, ws.image_h), QColor(89, 204, 255, 115), 1)

    def _draw_crop(self, p: QPainter):
        ws = self.ws
        w, h = ws.active_size
        full = self.rect_view(0, 0, w, h)
        k = ws.active_strip
        c = ws.active_strip_rect or ws.crop
        cr = self.rect_view(c.x0, c.y0, c.width, c.height)
        path = QPainterPath()
        path.setFillRule(Qt.FillRule.OddEvenFill)
        path.addRect(full)
        path.addRect(cr)
        p.fillPath(path, QColor(0, 0, 0, 140))
        self._lane_lines(p, dashed=False)
        p.setPen(QPen(QColor(255, 255, 255), 1.5))
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawRect(cr)
        pen = QPen(QColor(255, 255, 255), 4)
        pen.setCapStyle(Qt.PenCapStyle.FlatCap)
        p.setPen(pen)
        L = 16
        for (pt, dx, dy) in [(cr.topLeft(), 1, 1), (cr.topRight(), -1, 1), (cr.bottomLeft(), 1, -1),
                             (cr.bottomRight(), -1, -1)]:
            p.drawPolyline(QPolygonF([QPointF(pt.x() + dx * L, pt.y()), pt, QPointF(pt.x(), pt.y() + dy * L)]))
        for mid in [QPointF(cr.center().x(), cr.top()), QPointF(cr.center().x(), cr.bottom()),
                    QPointF(cr.left(), cr.center().y()), QPointF(cr.right(), cr.center().y())]:
            self._handle(p, mid, QColor(255, 255, 255))
        gel = f"{ws.gel_name(k)}: " if k is not None else ""
        self._badge(p, f"{gel}{int(c.width)} × {int(c.height)} px", QPointF(cr.center().x(), cr.bottom() + 18),
                    QColor(46, 46, 50, 240), QColor(255, 255, 255))

    # a stacked gel on its own: its whole image, what goes into the figure outlined, its lanes, ticks and names

    def _lane_span(self, k: int) -> tuple[float, float]:
        """The ladder lane's columns in gel k's own pixels: the lane geometry through the alignment."""
        ws = self.ws
        q = ws.shown_stack.piece(k) if ws.shown_stack else None
        lad, g = ws.project.ladder, ws.geometry
        if q is None or lad is None or g is None or not 1 <= lad.lane <= g.count:
            return 0.0, ws.active_size[0] * 0.12
        ry = ws.crop.y0
        a = q.scale * g.x(g.boundaries[lad.lane - 1], ry) + q.shift
        b = q.scale * g.x(g.boundaries[lad.lane], ry) + q.shift
        return min(a, b), max(a, b)

    def _draw_gel_view(self, p: QPainter):
        ws = self.ws
        k = ws.active_strip
        pr = ws.project
        w, h = ws.active_size
        c = ws.active_strip_rect
        if c is not None:   # outside the rows and columns that go into the figure, dimmed
            path = QPainterPath()
            path.setFillRule(Qt.FillRule.OddEvenFill)
            path.addRect(self.rect_view(0, 0, w, h))
            path.addRect(self.rect_view(c.x0, c.y0, c.width, c.height))
            p.fillPath(path, QColor(0, 0, 0, 110))
            p.setPen(QPen(QColor(255, 255, 255, 220), 1.5))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawRect(self.rect_view(c.x0, c.y0, c.width, c.height))
        self._lane_lines(p, dashed=True)
        sel, tool = ws.selection, ws.tool
        lad = pr.ladder
        if lad is not None:
            x0, x1 = self._lane_span(k)
            vx0, vx1 = self.to_view(x0, 0).x(), self.to_view(x1, 0).x()
            for i, b in enumerate(lad.bands):
                if b.strip != k:
                    continue
                y = self.to_view(0, b.y).y()
                s_ = sel == ("tick", i)
                col = GRAY if (b.ignore or b.size is None) else TICK
                self._line(p, QPointF(vx0, y), QPointF(vx1, y), QColor(0, 0, 0, 90), 4 if s_ else 3)
                self._line(p, QPointF(vx0, y), QPointF(vx1, y), col, 2 if s_ else 1.25, dash=b.size is None)
                if b.ignore:
                    self._badge(p, "skip", QPointF(vx1 + 16, y), GRAY, QColor(0, 0, 0))
                elif b.auto and b.size is not None:
                    self._badge(p, format_size(b.size) + "?", QPointF(vx1 + 16, y), QColor(0, 0, 0, 0), TICK, outline=TICK)
                else:
                    self._badge(p, format_size(b.size) if b.size is not None else "–", QPointF(vx1 + 14, y),
                                GRAY if b.size is None else TICK, QColor(0, 0, 0))
        full = self.rect_view(0, 0, w, h)
        for i, a in enumerate(pr.annotations):
            if a.strip != k:
                continue
            y = self.to_view(0, a.y).y()
            s_ = sel == ("name", i)
            col = QColor(NAME)
            col.setAlphaF(1 if s_ else 0.85)
            self._line(p, QPointF(full.left(), y), QPointF(full.right(), y), QColor(255, 102, 140, 90), 1, dash=True)
            right = a.side == "right"
            ex, d = (full.right() - 3, -1) if right else (full.left() + 3, 1)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(col)
            p.drawPolygon(QPolygonF([QPointF(ex, y), QPointF(ex + d * 11, y - 5), QPointF(ex + d * 11, y + 5)]))
            self._badge(p, (a.text.split("\n")[0] or "name")[:24], QPointF(ex + d * (18 + 3 * min(len(a.text), 24)), y),
                        col, QColor(0, 0, 0))
        # previews under the cursor: where a tick or name would go
        hv = self.hover
        if hv is None or self.drag is not None or tool not in ("ladder", "names") or not full.adjusted(-1, -1, 1, 1).contains(hv):
            return
        gx, gy = self.to_model(hv)
        free = bool(self._modifiers() & Qt.KeyboardModifier.AltModifier)
        y = ws.snap_in_gel(k, gx, gy, free)
        vy = self.to_view(0, y).y()
        if tool == "ladder":
            x0, x1 = self._lane_span(k)
            self._line(p, QPointF(self.to_view(x0, 0).x(), vy), QPointF(self.to_view(x1, 0).x(), vy), QColor(255, 209, 26, 191), 1.25, dash=True)
        else:
            self._line(p, QPointF(full.left(), vy), QPointF(full.right(), vy), QColor(255, 102, 140, 140), 1, dash=True)

    def hit_tick_gel(self, pt: QPointF) -> Optional[int]:
        """The tick of the gel on view that view point pt is on (the ladder lane, a little wider)."""
        ws = self.ws
        lad, k = ws.project.ladder, ws.active_strip
        if lad is None or k is None:
            return None
        x0, x1 = self._lane_span(k)
        vx0, vx1 = self.to_view(x0, 0).x(), self.to_view(x1, 0).x()
        best = None
        for i, b in enumerate(lad.bands):
            d = abs(pt.y() - self.to_view(0, b.y).y())
            if b.strip == k and d < 6 and vx0 - 30 <= pt.x() <= vx1 + 60 and (best is None or d < best[1]):
                best = (i, d)
        return best[0] if best else None

    def hit_name_gel(self, pt: QPointF) -> Optional[int]:
        """The band name of the gel on view that view point pt is on: at the side of the gel it was put on."""
        ws = self.ws
        k = ws.active_strip
        full = self.rect_view(0, 0, *ws.active_size)
        best = None
        for i, a in enumerate(ws.project.annotations):
            if a.strip != k:
                continue
            near = (full.right() - 150 < pt.x() <= full.right() + 20) if a.side == "right" else \
                (full.left() - 20 <= pt.x() < full.left() + 150)
            d = abs(pt.y() - self.to_view(0, a.y).y())
            if near and d < 8 and (best is None or d < best[1]):
                best = (i, d)
        return best[0] if best else None

    def _draw_straighten(self, p: QPainter):
        ws = self.ws
        r = self.rect_view(0, 0, *ws.active_size)
        p.save()
        p.setClipRect(r)
        grid = QColor(77, 204, 255, 82)
        step = r.height() / 12
        for k in range(1, 12):
            y = r.top() + step * k
            self._line(p, QPointF(r.left(), y), QPointF(r.right(), y), grid, 1)
        x = r.left() + step
        while x < r.right() - 1:
            self._line(p, QPointF(x, r.top()), QPointF(x, r.bottom()), grid, 1)
            x += step
        p.restore()
        if self.drag and self.drag[0] == "level":
            a, b = self.drag[1], self.drag[2]
            va, vb = self.to_view(*a), self.to_view(*b)
            self._line(p, va, vb, QColor(0, 0, 0, 128), 4)
            self._line(p, va, vb, LANE, 2)
            for v in (va, vb):
                self._circle(p, v, 4, LANE, QColor(255, 255, 255), 1.5)
            d = ops.leveling_angle(a, b)
            self._badge(p, f"{d:+.2f}°", QPointF((va.x() + vb.x()) / 2, (va.y() + vb.y()) / 2 - 18),
                        QColor(38, 38, 40, 240), QColor(255, 255, 255))
        else:
            a = 0 if ws.active_strict else ws.active_rotation
            gel = f"{ws.active_name} · " if ws.project.strips else ""
            self._badge(p, gel + f"Rotation {a:.2f}°" + (" · Strict on" if ws.active_strict else ""),
                        QPointF(r.center().x(), r.bottom() + 18), QColor(46, 46, 50, 240), QColor(255, 255, 255))

    def _draw_guides(self, p: QPainter, l: FigureLayout):
        ws = self.ws
        pr = ws.project
        crop = ws.crop
        H = float(ws.image_h)
        gel = self.gel_view()
        tool = ws.tool
        sel = ws.selection
        stack = ws.shown_stack
        # with several gels, the one the inspector and crop/straighten act on
        if stack is not None and stack.has_strips:
            q = stack.piece(ws.active_strip)
            if q is not None:
                a, b = self.px_view(0, q.top).y(), self.px_view(0, q.bottom).y()
                p.setPen(QPen(ACCENT, 2))
                p.setBrush(Qt.BrushStyle.NoBrush)
                p.drawRoundedRect(QRectF(gel.left() - 3, a - 3, gel.width() + 6, b - a + 6), 3, 3)
        # lane dividers: in the gel with the lanes as placed; through the other gels straight down from the top of
        # the crop, where their lanes were lined up
        for i, d in enumerate(pr.lanes.dividers):
            top = self.px_view(d.x_at(crop.y0, H), crop.y0)
            bot = self.px_view(d.x_at(crop.y1, H), crop.y1)
            s = sel == ("divider", i)
            faded = not (tool in ("lanes", "select") or s)
            c = QColor(LANE)
            c.setAlphaF(0.35 if faded else 0.95)
            self._line(p, top, bot, QColor(0, 0, 0, 38 if faded else 90), 4 if s else 3)
            self._line(p, top, bot, c, 2 if s else 1.25)
            for q in (stack.pieces if stack is not None else []):
                if q.strip is None:
                    continue
                x = d.x_at(crop.y0, H)
                a, b = self.px_view(x, q.top), self.px_view(x, q.bottom)
                self._line(p, a, b, QColor(0, 0, 0, 30 if faded else 76), 3)
                c2 = QColor(LANE)
                c2.setAlphaF(0.3 if faded else 0.75)
                self._line(p, a, b, c2, 1, dash=True)
            dy = min(max(d.dot_y, crop.y0), crop.y1)
            self._circle(p, self.px_view(d.x_at(dy, H), dy), 6 if s else 5, c, QColor(255, 255, 255, 100 if faded else 255), 1.5)
            if not faded:
                self._handle(p, top, c)
                self._handle(p, bot, c)
        g = ws.geometry
        if tool == "lanes" and g and g.count > 0:
            for n in range(1, g.count + 1):
                c = self.px_view(g.center(n, crop.y0), crop.y0)
                self._badge(p, str(n), QPointF(c.x(), gel.top() + 14), LANE, QColor(0, 0, 0))
        # ladder ticks
        lad = pr.ladder
        if lad and tool in ("ladder", "select"):
            for i, b in enumerate(lad.bands):
                fy = stack.figure_y(b.strip, b.y) if stack is not None else (b.y if crop.y0 <= b.y <= crop.y1 else None)
                if fy is None:   # outside the crop: not in the figure
                    continue
                ry = b.y if b.strip is None else crop.y0   # another gel's lanes run straight down from the crop's top
                y = self.px_view(0, fy).y()
                x0, x1 = gel.left(), gel.left() + gel.width() * 0.12
                if g and 1 <= lad.lane <= g.count:
                    x0 = self.px_view(g.x(g.boundaries[lad.lane - 1], ry), fy).x()
                    x1 = self.px_view(g.x(g.boundaries[lad.lane], ry), fy).x()
                s = sel == ("tick", i)
                col = GRAY if (b.ignore or b.size is None) else TICK
                self._line(p, QPointF(x0, y), QPointF(x1, y), QColor(0, 0, 0, 90), 4 if s else 3)
                self._line(p, QPointF(x0, y), QPointF(x1, y), col, 2 if s else 1.25, dash=b.size is None)
                if b.ignore:
                    self._badge(p, "skip", QPointF(x1 + 16, y), GRAY, QColor(0, 0, 0))
                elif b.auto and b.size is not None:   # a guess until confirmed: outlined, with a question mark
                    self._badge(p, format_size(b.size) + "?", QPointF(x1 + 16, y), QColor(0, 0, 0, 0), TICK, outline=TICK)
                else:
                    self._badge(p, format_size(b.size) if b.size is not None else "–", QPointF(x1 + 14, y),
                                GRAY if b.size is None else TICK, QColor(0, 0, 0))
        # selected label
        if sel and sel[0] == "text":
            for t in l.texts:
                if t.role == sel[1]:
                    p.setPen(QPen(ACCENT, 1.5))
                    p.setBrush(QColor(61, 123, 246, 30))
                    if t.rotation:   # a label at an angle: its own rotated box
                        p.drawPolygon(QPolygonF([self.to_view(*c) for c in t.box]))
                    else:
                        p.drawRoundedRect(self._text_view(t), 3, 3)
        # band names
        if tool in ("names", "select"):
            for i, a in enumerate(pr.annotations):
                fy = stack.name_y(a.strip, a.y) if stack is not None else a.y
                if fy is None:
                    continue
                y = self.px_view(0, fy).y()
                x = gel.right() if a.side == "right" else gel.left()
                s = sel == ("name", i)
                r = QRectF(x - 4 if a.side == "right" else x - 60, y - 7, 64, 14)
                c = QColor(NAME)
                c.setAlphaF(1 if s else 0.8)
                p.setPen(QPen(c, 2 if s else 1.25))
                p.setBrush(Qt.BrushStyle.NoBrush)
                p.drawRoundedRect(r, 5, 5)
        # placing the unit label: where it would go
        h = self.hover
        if ws.placing_unit and h is not None:
            left = not (lad and lad.side == "right")
            edge = gel.left() if left else gel.right()
            self._line(p, QPointF(edge - 60 if left else edge, h.y()), QPointF(edge if left else edge + 60, h.y()),
                       QColor(255, 209, 26, 204), 1.25, dash=True)
            self._badge(p, lad.unit if lad else "kDa", QPointF(edge - 76 if left else edge + 76, h.y()), TICK,
                        QColor(0, 0, 0))
            return
        # previews under the cursor
        if h is None or self.drag is not None or not gel.adjusted(-1, -1, 1, 1).contains(h):
            return
        px = self.view_px(h)
        free = bool(self._modifiers() & Qt.KeyboardModifier.AltModifier)
        if tool == "lanes":
            if self.hit_divider(h) is None:
                self._line(p, QPointF(h.x(), gel.top()), QPointF(h.x(), gel.bottom()), QColor(89, 204, 255, 153), 1, dash=True)
                self._circle(p, h, 4, QColor(89, 204, 255, 153), QColor(255, 255, 255, 178), 1)
        elif tool == "ladder":
            if self.hit_tick(h) is not None:
                return
            strip, y, fy = ws.snap_in_figure(px[0], px[1], free)
            vy = self.px_view(0, fy).y()
            ry = y if strip is None else crop.y0
            x0, x1 = h.x() - 40, h.x() + 40
            lane = g.lane_at(px[0], ry) if g else None
            if lane:
                x0 = self.px_view(g.x(g.boundaries[lane - 1], ry), fy).x()
                x1 = self.px_view(g.x(g.boundaries[lane], ry), fy).x()
            self._line(p, QPointF(x0, vy), QPointF(x1, vy), QColor(255, 209, 26, 191), 1.25, dash=True)
            s = ws.suggested_size(y, strip)
            if s is not None:
                self._badge(p, format_size(s), QPointF(x1 + 14, vy), QColor(255, 209, 26, 191), QColor(0, 0, 0))
        elif tool == "names":
            if self.hit_name(h) is not None:
                return
            vy = self.px_view(0, ws.snap_in_figure(px[0], px[1], free)[2]).y()
            side = "left" if (lad and lad.side == "right") else "right"
            ex = gel.right() if side == "right" else gel.left()
            d = 1 if side == "right" else -1
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(255, 102, 140, 204))
            p.drawPolygon(QPolygonF([QPointF(ex + d * 3, vy), QPointF(ex + d * 13, vy - 5), QPointF(ex + d * 13, vy + 5)]))
            self._line(p, QPointF(gel.left(), vy), QPointF(gel.right(), vy), QColor(255, 102, 140, 90), 1, dash=True)

    # helpers
    def _text_view(self, t) -> QRectF:
        b = t.bounds
        return self.rect_view(b.x, b.y, b.w, b.h).adjusted(-3, -2, 3, 2)

    def _line(self, p: QPainter, a: QPointF, b: QPointF, color: QColor, width: float, dash: bool = False):
        pen = QPen(color, width)
        pen.setCapStyle(Qt.PenCapStyle.RoundCap)
        if dash:
            pen.setDashPattern([5 / max(width, 0.5), 4 / max(width, 0.5)])
        p.setPen(pen)
        p.drawLine(a, b)

    def _circle(self, p, c: QPointF, r: float, fill: QColor, stroke: QColor, width: float):
        p.setPen(QPen(stroke, width))
        p.setBrush(fill)
        p.drawEllipse(c, r, r)

    def _handle(self, p, c: QPointF, color: QColor):
        p.setPen(QPen(color, 1.25))
        p.setBrush(QColor(255, 255, 255))
        p.drawRoundedRect(QRectF(c.x() - 4, c.y() - 4, 8, 8), 2, 2)

    def _badge(self, p, s: str, c: QPointF, color: QColor, text_color: QColor, outline: Optional[QColor] = None):
        f = QFont(self.font())
        f.setPixelSize(10)
        f.setBold(True)
        fm = QFontMetricsF(f)
        w, h = fm.horizontalAdvance(s), fm.height()
        r = QRectF(c.x() - w / 2 - 6, c.y() - h / 2 - 2, w + 12, h + 4)
        p.setPen(QPen(outline, 1.25) if outline else Qt.PenStyle.NoPen)
        p.setBrush(color if color.alpha() > 0 else QColor(27, 27, 29, 220))
        p.drawRoundedRect(r, r.height() / 2, r.height() / 2)
        p.setFont(f)
        p.setPen(text_color)
        p.drawText(r, Qt.AlignmentFlag.AlignCenter, s)

    def _modifiers(self):
        from PySide6.QtWidgets import QApplication
        return QApplication.keyboardModifiers()

    def tick_anchor(self, i: int) -> tuple[QPoint, bool]:
        """Where tick i's size editor opens: beside the ladder lane on the gel's side, past the size badge, so the whole
        lane stays free and the next band down can be clicked straight away. (Global point, opens to the right.)"""
        ws = self.ws
        lad = ws.project.ladder
        b = lad.bands[i]
        inward = lad.side != "right"   # a left ladder opens to the right
        if ws.views_other_gel and b.strip == ws.active_strip:   # a stacked gel on its own: beside its ladder lane
            x0, x1 = self._lane_span(b.strip)
            x = self.to_view(x1 if inward else x0, 0).x() + (34 if inward else -34)
            return self.mapToGlobal(QPoint(round(x), round(self.to_view(0, b.y).y()))), inward
        gel = self.gel_view()
        x = gel.left() + gel.width() * 0.12 if inward else gel.right() - gel.width() * 0.12
        g = ws.geometry
        fy = ws.figure_y(b.strip, b.y)
        fy = b.y if fy is None else fy
        ry = b.y if b.strip is None else ws.crop.y0
        if g and 1 <= lad.lane <= g.count:
            edge = g.boundaries[lad.lane if inward else lad.lane - 1]
            x = self.px_view(g.x(edge, ry), fy).x()
        x += 34 if inward else -34
        return self.mapToGlobal(QPoint(round(x), round(self.px_view(0, fy).y()))), inward

    # ------------------------------------------------------------------------------------------------ hit tests

    def hit_divider(self, pt: QPointF):
        ws = self.ws
        if ws.shown_layout is None:
            return None
        crop, H = ws.crop, float(ws.image_h)
        best = None
        for i, d in enumerate(ws.project.lanes.dividers):
            top = self.px_view(d.x_at(crop.y0, H), crop.y0)
            bot = self.px_view(d.x_at(crop.y1, H), crop.y1)
            dy = min(max(d.dot_y, crop.y0), crop.y1)
            dot = self.px_view(d.x_at(dy, H), dy)
            for q, part in ((top, "top"), (bot, "bottom"), (dot, "move")):
                dist = math.hypot(q.x() - pt.x(), q.y() - pt.y())
                if dist < 8 and (best is None or dist < best[2]):
                    best = (i, part, dist)
            dist = _seg_dist(pt, top, bot)
            if dist < 5 and (best is None or dist + 2 < best[2]):
                best = (i, "move", dist + 2)
        return (best[0], best[1]) if best else None

    def hit_tick(self, pt: QPointF) -> Optional[int]:
        ws = self.ws
        lad = ws.project.ladder
        if lad is None or ws.shown_layout is None:
            return None
        gel = self.gel_view()
        g = ws.geometry
        crop = ws.crop
        stack = ws.shown_stack
        best = None
        for i, b in enumerate(lad.bands):
            fy = stack.figure_y(b.strip, b.y) if stack is not None else (b.y if crop.y0 <= b.y <= crop.y1 else None)
            if fy is None:
                continue
            ry = b.y if b.strip is None else crop.y0
            y = self.px_view(0, fy).y()
            x0, x1 = gel.left() - 50, gel.left() + gel.width() * 0.15
            if g and 1 <= lad.lane <= g.count:
                x0 = min(gel.left() - 50, self.px_view(g.x(g.boundaries[lad.lane - 1], ry), fy).x())
                x1 = self.px_view(g.x(g.boundaries[lad.lane], ry), fy).x() + 30
                if lad.side == "right":
                    x1 = max(x1, gel.right() + 50)
            d = abs(pt.y() - y)
            if d < 6 and x0 <= pt.x() <= x1 and (best is None or d < best[1]):
                best = (i, d)
        return best[0] if best else None

    def hit_name(self, pt: QPointF) -> Optional[int]:
        if self.ws.shown_layout is None:
            return None
        gel = self.gel_view()
        stack = self.ws.shown_stack
        best = None
        for i, a in enumerate(self.ws.project.annotations):
            fy = stack.name_y(a.strip, a.y) if stack is not None else a.y
            if fy is None:
                continue
            y = self.px_view(0, fy).y()
            in_x = (gel.right() - 16 < pt.x() < gel.right() + 140) if a.side == "right" else \
                (gel.left() - 140 < pt.x() < gel.left() + 16)
            d = abs(pt.y() - y)
            if in_x and d < 8 and (best is None or d < best[1]):
                best = (i, d)
        return best[0] if best else None

    def hit_text(self, pt: QPointF):
        """The figure text under view point pt: tested against the text's own box, which for a lane label standing at an
        angle is the rotated rectangle, not the bigger one around it."""
        l = self.ws.shown_layout
        if l is None:
            return None
        x, y = self.to_model(pt)
        sc = self.scale()
        return next((t for t in l.texts if t.contains(x, y, 3 / sc, 2 / sc)), None)

    # ------------------------------------------------------------------------------------------------ mouse

    def _global(self, pt: QPointF) -> QPoint:
        return self.mapToGlobal(QPoint(int(pt.x()) + 12, int(pt.y()) + 8))

    def mousePressEvent(self, e: QMouseEvent):
        self.setFocus()
        self.press = None
        ws = self.ws
        if ws.working is None or ws.shown_layout is None or e.button() != Qt.MouseButton.LeftButton:
            return
        pt = e.position()
        if ws.tool == "pan" or self.space_down:
            self.drag = ("pan", pt, self.clamped(self.pan, self.scale()))
            self.setCursor(Qt.CursorShape.ClosedHandCursor)
            return
        if ws.tool == "straighten":
            q = self.to_model(pt)
            self.drag = ("level", q, q)
            self.update()
            return
        if ws.tool == "crop":
            self._begin_crop(pt)
            return
        if ws.views_other_gel:
            self._press_gel_view(pt, e)
            return
        if ws.placing_unit:   # "Place…" in the Ladder tab: this click sets the unit label's height
            ws.set_unit_y(self.view_px(pt)[1])
            self.update()
            return
        px = self.view_px(pt)
        gel = self.gel_view()
        in_gel = gel.adjusted(-2, -2, 2, 2).contains(pt)
        alt = bool(e.modifiers() & Qt.KeyboardModifier.AltModifier)
        tool = ws.tool
        stack = ws.shown_stack
        # with several gels, the gel whose rows a click is in; only the Select tool chooses it (the other tools act on it, a
        # tick or a name belongs to it, and never change the chosen gel)
        under = None
        if stack is not None and stack.has_strips and gel.top() <= pt.y() <= gel.bottom():
            under = stack.piece_at_figure_y(px[1])
        if tool == "lanes":
            hit = self.hit_divider(pt)
            if hit is not None:
                i, part = hit
                if alt:
                    ws.delete_divider(i)
                else:
                    ws.selection = ("divider", i)
                    d = ws.project.lanes.dividers[i]
                    self.drag = ("divider", i, part, type(d)(d.x_top, d.x_bottom, d.dot_y), px)
            elif self._edit_label(pt):
                pass
            elif in_gel:
                ws.add_divider(float(sround(px[0])), float(sround(min(max(px[1], ws.crop.y0), ws.crop.y1))))
                xs = [dd.x_top + dd.x_bottom for dd in ws.project.lanes.dividers]
                i = min(range(len(xs)), key=lambda k: abs(xs[k] / 2 - sround(px[0])))
                ws.selection = ("divider", i)
                d = ws.project.lanes.dividers[i]
                self.drag = ("divider", i, "move", type(d)(d.x_top, d.x_bottom, d.dot_y), px)
            else:
                ws.selection = None
        elif tool == "ladder":
            i = self.hit_tick(pt)
            if i is not None:
                ws.selection = ("tick", i)
                self.press = (pt, ("tick", i))
                self.drag = ("tick", i)
            elif self._edit_label(pt):
                pass
            elif in_gel or (gel.top() < pt.y() < gel.bottom() and abs(pt.x() - gel.left()) < 60):
                strip, y, _ = ws.snap_in_figure(px[0], px[1], alt)
                i = ws.add_tick(px[0], y, strip)
                ws.selection = ("tick", i)
                self.tick_editor.emit(i, self._global(pt))
            else:
                ws.selection = None
        elif tool == "names":
            i = self.hit_name(pt)
            if i is not None:
                ws.selection = ("name", i)
                self.press = (pt, ("name", i))
                self.drag = ("name", i)
            elif self._edit_label(pt):
                pass
            elif in_gel:
                strip, y, _ = ws.snap_in_figure(px[0], px[1], alt)
                i = ws.add_name(y, strip=strip)
                ws.selection = ("name", i)
                self.name_editor.emit(i, self._global(pt))
            else:
                ws.selection = None
        elif tool == "select":
            hit = self.hit_divider(pt)
            if hit is not None:
                i, part = hit
                ws.selection = ("divider", i)
                d = ws.project.lanes.dividers[i]
                self.drag = ("divider", i, part, type(d)(d.x_top, d.x_bottom, d.dot_y), px)
            elif (i := self.hit_tick(pt)) is not None:
                ws.selection = ("tick", i)
                self.press = (pt, ("tick", i))
                self.drag = ("tick", i)
            elif (i := self.hit_name(pt)) is not None:
                ws.selection = ("name", i)
                self.press = (pt, ("name", i))
                self.drag = ("name", i)
            elif self._edit_label(pt):
                pass
            elif in_gel and under is not None:
                # a click chooses the gel under it; dragging moves it sideways, to line its lanes up under the dividers
                ws.choose_gel(under.strip)
                ws.selection = None
                self.drag = self._strip_drag(under, pt, px)
            else:
                ws.selection = None
        self.update()

    def _strip_drag(self, q, pt: QPointF, px: tuple[float, float]):
        """Holding gel q (a piece of the stack) at view point pt: its shift now, how many figure pixels a view point is, and
        the column of the gel that is under the pointer."""
        ws = self.ws
        k = q.strip
        s0 = ws.project.effective_main_shift if k is None else ws.project.strips[k - 1].shift
        per_px = 1 / (self.scale() * ws.shown_layout.pt_per_px)
        return ("strip", k, s0, pt, per_px, q.to_piece(px[0], 0)[0])

    def _press_gel_view(self, pt: QPointF, e: QMouseEvent):
        """A click on the stacked gel on view (Ladder Ticks, Band Names and Select): its ticks and names are on its own pixels."""
        ws = self.ws
        k = ws.active_strip
        gx, gy = self.to_model(pt)
        alt = bool(e.modifiers() & Qt.KeyboardModifier.AltModifier)
        q = ws.shown_stack.piece(k) if ws.shown_stack else None
        if ws.placing_unit:
            if q is not None:
                ws.set_unit_y(q.to_figure(0, gy)[1])
            self.update()
            return
        in_gel = self.rect_view(0, 0, *ws.active_size).adjusted(-2, -2, 2, 2).contains(pt)
        i = self.hit_tick_gel(pt)
        j = self.hit_name_gel(pt) if i is None else None
        if i is not None:
            ws.selection = ("tick", i)
            self.press = (pt, ("tick", i))
            self.drag = ("gtick", i)
        elif j is not None:
            ws.selection = ("name", j)
            self.press = (pt, ("name", j))
            self.drag = ("gname", j)
        elif ws.tool == "ladder" and in_gel and q is not None:
            i = ws.add_tick(q.to_figure(gx, 0)[0], ws.snap_in_gel(k, gx, gy, alt), k)
            ws.selection = ("tick", i)
            self.tick_editor.emit(i, self._global(pt))
        elif ws.tool == "names" and in_gel:
            i = ws.add_name(ws.snap_in_gel(k, gx, gy, alt), strip=k)
            ws.selection = ("name", i)
            self.name_editor.emit(i, self._global(pt))
        else:
            ws.selection = None
        self.update()

    def mouseDoubleClickEvent(self, e: QMouseEvent):
        """Double-clicking a gel in the figure (Select tool) opens that gel on its own."""
        ws = self.ws
        pt = e.position()
        if e.button() == Qt.MouseButton.LeftButton and ws.tool == "select" and not self.full_view and ws.shown_layout is not None:
            stack = ws.shown_stack
            if stack is not None and stack.has_strips and self.gel_view().adjusted(-2, -2, 2, 2).contains(pt):
                q = stack.piece_at_figure_y(self.view_px(pt)[1])
                if q is not None:
                    self.drag = self.press = None
                    ws.show_gel(q.strip)
                    return
        super().mouseDoubleClickEvent(e)   # another press

    def _edit_label(self, pt: QPointF) -> bool:
        """One click on a figure label opens its editor, whatever the tool."""
        t = self.hit_text(pt)
        if t is None:
            return False
        ws = self.ws
        role = t.role
        if role.kind == "ladderLabel":
            if not ws.project.ladder or role.a >= len(ws.project.ladder.bands):
                return False
            ws.selection = ("tick", role.a)
            self.tick_editor.emit(role.a, self._global(pt))
        elif role.kind == "annotation":
            if role.a >= len(ws.project.annotations):
                return False
            ws.selection = ("name", role.a)
            self.name_editor.emit(role.a, self._global(pt))
        elif role.kind == "ladderUnit":
            # a click edits the unit, a drag moves it up or down (release tells them apart)
            ws.selection = ("text", role)
            self.press = (pt, ("text", role))
            self.drag = ("unit", ws.shown_layout.pixel(t.bounds.mid_x, t.bounds.mid_y)[1], pt)
        else:
            ws.selection = ("text", role)
            r = self._text_view(t)
            self.text_editor.emit(role, self.mapToGlobal(QPoint(int(r.left()), int(r.bottom()) + 6)))
        return True

    def mouseMoveEvent(self, e: QMouseEvent):
        pt = e.position()
        self.hover = pt
        ws = self.ws
        if self.press is not None and math.hypot(pt.x() - self.press[0].x(), pt.y() - self.press[0].y()) > 3:
            self.press = None   # it's a drag, not a click
        d = self.drag
        alt = bool(e.modifiers() & Qt.KeyboardModifier.AltModifier)
        if d is None:
            self.update_cursor()
            self.update()
            return
        if d[0] == "pan":
            start, sp = d[1], d[2]
            self.pan = self.clamped(QPointF(sp.x() + pt.x() - start.x(), sp.y() + pt.y() - start.y()), self.scale())
        elif d[0] == "divider":
            _, i, part, start, spx = d
            px = self.view_px(pt)
            if part == "move":
                dot = min(max(px[1], ws.crop.y0), ws.crop.y1)
                ws.drag_divider(i, start, "move", float(sround(px[0] - spx[0])), float(sround(dot)))
            else:
                ws.drag_divider(i, start, part, float(sround(px[0])))
        elif d[0] == "tick":
            px = self.view_px(pt)
            lad = ws.project.ladder
            lane_x = ws.project.lanes.centers[lad.lane - 1] if lad and lad.lane <= len(ws.project.lanes.centers) else px[0]
            ws.drag_tick(d[1], lane_x, px[1], alt)
        elif d[0] == "name":
            px = self.view_px(pt)
            last = ws.project.lanes.centers[-1] if ws.project.lanes.centers else px[0]
            ws.drag_name(d[1], last, px[1], alt)
        elif d[0] == "crop":
            r = self._crop_rect(d[1], d[2], d[3], self.to_model(pt))
            if ws.active_strip is not None:
                ws.live_strip_crop(r)
            else:
                ws.live_crop(r)
        elif d[0] == "gtick":
            k = ws.active_strip
            x0, x1 = self._lane_span(k)
            ws.move_tick(d[1], ws.snap_in_gel(k, (x0 + x1) / 2, self.to_model(pt)[1], alt))
        elif d[0] == "gname":
            k = ws.active_strip
            a = ws.project.annotations[d[1]] if d[1] < len(ws.project.annotations) else None
            n = len(ws.project.lanes.centers)
            x = ops.lane_x(ws.project, 1 if a is not None and a.side == "left" else n, k) if n else None
            ws.move_name(d[1], ws.snap_in_gel(k, self.to_model(pt)[0] if x is None else x, self.to_model(pt)[1], alt))
        elif d[0] == "strip":
            _, k, s0, start, per_px, column = d
            ws.live_strip_shift(k, s0 - ws.strip_scale(k) * (pt.x() - start.x()) * per_px)
            # the figure may have moved on the page (it starts at the leftmost column any gel keeps, and the gel with the lanes
            # holds still while the others move): slide the view so the gel's column is under the pointer again, which also
            # keeps the gels that didn't move where they were on screen
            piece = ws.shown_stack.piece(k) if ws.shown_stack else None
            if piece is not None and ws.shown_layout is not None:
                at = self.px_view(piece.to_figure(column, 0)[0], 0)
                now = self.clamped(self.pan, self.scale())
                self.pan = QPointF(now.x() + pt.x() - at.x(), now.y())
        elif d[0] == "level":
            self.drag = ("level", d[1], self.to_model(pt))
        elif d[0] == "unit" and self.press is None:
            ws.move_unit(d[1] + (pt.y() - d[2].y()) / (self.scale() * ws.shown_layout.pt_per_px))
        self.update()

    def mouseReleaseEvent(self, e: QMouseEvent):
        ws = self.ws
        d = self.drag
        self.drag = None
        if d is not None:
            kind = d[0]
            if kind == "divider":
                ws.selection = ("divider", ws.end_divider_drag(d[1]))   # the dividers may have changed places
            elif kind == "tick":
                ws.selection = ("tick", ws.end_tick_drag(d[1]))
            elif kind == "name":
                ws.end_gesture("Move Band Name")
            elif kind == "crop":
                ws.end_gesture("Crop" if ws.active_strip is None else "Gel Crop")
            elif kind == "gtick":
                ws.selection = ("tick", ws.end_tick_drag(d[1]))
            elif kind == "gname":
                ws.end_gesture("Move Band Name")
            elif kind == "strip":
                ws.end_gesture("Line Up Gel")
            elif kind == "level":
                ws.straighten(d[1], d[2])
            elif kind == "unit":
                ws.end_gesture("Move Unit Label")
        if self.press is not None:   # pressed and let go without moving: edit it
            pt, target = self.press
            self.press = None
            if target[0] == "tick":
                self.tick_editor.emit(target[1], self._global(pt))
            elif target[0] == "name":
                self.name_editor.emit(target[1], self._global(pt))
            elif target[0] == "text":
                self.text_editor.emit(target[1], self._global(pt))
        self.update_cursor()
        self.update()

    def leaveEvent(self, _e):
        self.hover = None
        self.update()

    def wheelEvent(self, e: QWheelEvent):
        pt = e.position()
        if e.modifiers() & Qt.KeyboardModifier.ControlModifier:
            dy = e.angleDelta().y() / 120 if e.angleDelta().y() else e.pixelDelta().y() / 40
            self.zoom_by(math.exp(dy * 0.15), pt)
            return
        if self.zoom is None:
            self.zoom = self.fit_scale()
        delta = e.pixelDelta() if not e.pixelDelta().isNull() else e.angleDelta() / 3
        now = self.clamped(self.pan, self.scale())
        self.pan = self.clamped(QPointF(now.x() + delta.x(), now.y() + delta.y()), self.scale())
        self.update()

    def event(self, e):
        if e.type() == QEvent.Type.NativeGesture and e.gestureType() == Qt.NativeGestureType.ZoomNativeGesture:
            self.zoom_by(1 + e.value(), e.position())
            return True
        if e.type() == QEvent.Type.Gesture:
            g = e.gesture(Qt.GestureType.PinchGesture)
            if g is not None:
                self.zoom_by(g.scaleFactor(), self.mapFromGlobal(g.centerPoint().toPoint()).toPointF())
                return True
        return super().event(e)

    # ------------------------------------------------------------------------------------------------ keys

    def keyPressEvent(self, e: QKeyEvent):
        ws = self.ws
        k = e.key()
        if k == Qt.Key.Key_Space and not e.isAutoRepeat():
            self.space_down = True
            self.setCursor(Qt.CursorShape.OpenHandCursor)
            return
        if k == Qt.Key.Key_Escape:
            if ws.tool == "crop":   # a stacked gel's crop goes back to what it was; the lanes gel's stays as dragged
                if ws.active_strip is not None:
                    ws.cancel_crop()
                else:
                    ws.set_tool("select")
                return
            if ws.placing_unit:
                ws.placing_unit = False
            ws.selection = None
            self.update()
            return
        if k in (Qt.Key.Key_Return, Qt.Key.Key_Enter) and ws.tool in FULL_IMAGE_TOOLS:
            ws.set_tool("select")
            return
        if k in (Qt.Key.Key_Left, Qt.Key.Key_Right) and ws.selection is None and ws.project.strips \
                and ws.tool not in FULL_IMAGE_TOOLS:
            # nothing selected and several gels: left and right move the chosen gel, the one with the lanes too (its dividers,
            # labels, ticks and names go with it), a pixel at a time (Shift: ten)
            step = 10 if e.modifiers() & Qt.KeyboardModifier.ShiftModifier else 1
            ws.nudge_active_gel(-step if k == Qt.Key.Key_Left else step)
            return
        if k in (Qt.Key.Key_Delete, Qt.Key.Key_Backspace) and ws.selection:
            kind, i = ws.selection
            if kind == "divider":
                ws.delete_divider(i)
            elif kind == "tick":
                ws.delete_tick(i)
            elif kind == "name":
                ws.delete_name(i)
            return
        super().keyPressEvent(e)   # tool keys are window shortcuts now (keys.py), so they work off the canvas too

    def keyReleaseEvent(self, e: QKeyEvent):
        if e.key() == Qt.Key.Key_Space and not e.isAutoRepeat():
            self.space_down = False
            self.update_cursor()
            return
        super().keyReleaseEvent(e)

    def update_cursor(self):
        ws = self.ws
        if self.space_down or ws.tool == "pan":
            self.setCursor(Qt.CursorShape.OpenHandCursor)
            return
        if ws.tool in FULL_IMAGE_TOOLS or ws.placing_unit:
            self.setCursor(Qt.CursorShape.CrossCursor)
            return
        if ws.views_other_gel:   # a stacked gel on its own
            h = self.hover
            if h is not None and (self.hit_tick_gel(h) is not None or self.hit_name_gel(h) is not None):
                self.setCursor(Qt.CursorShape.SizeVerCursor)
            else:
                self.setCursor(Qt.CursorShape.CrossCursor if ws.tool in ("ladder", "names") else Qt.CursorShape.ArrowCursor)
            return
        h = self.hover
        if ws.shown_layout is None or h is None:
            self.setCursor(Qt.CursorShape.ArrowCursor)
            return
        in_gel = self.gel_view().contains(h)
        if ws.tool == "lanes":
            hit = self.hit_divider(h)
            if hit:
                self.setCursor(Qt.CursorShape.SizeHorCursor if hit[1] == "move" else Qt.CursorShape.CrossCursor)
            elif self.hit_text(h):
                self.setCursor(Qt.CursorShape.PointingHandCursor)
            else:
                self.setCursor(Qt.CursorShape.CrossCursor if in_gel else Qt.CursorShape.ArrowCursor)
        elif ws.tool in ("ladder", "names"):
            if self.hit_tick(h) is not None or self.hit_name(h) is not None:
                self.setCursor(Qt.CursorShape.SizeVerCursor)
            elif self.hit_text(h):
                self.setCursor(Qt.CursorShape.PointingHandCursor)
            else:
                self.setCursor(Qt.CursorShape.CrossCursor if in_gel else Qt.CursorShape.ArrowCursor)
        else:
            if self.hit_divider(h):
                self.setCursor(Qt.CursorShape.SizeHorCursor)
            elif self.hit_tick(h) is not None or self.hit_name(h) is not None:
                self.setCursor(Qt.CursorShape.SizeVerCursor)
            elif self.hit_text(h):
                self.setCursor(Qt.CursorShape.PointingHandCursor)
            else:
                self.setCursor(Qt.CursorShape.ArrowCursor)

    # ------------------------------------------------------------------------------------------------ crop

    def _begin_crop(self, pt: QPointF):
        ws = self.ws
        c = ws.active_strip_rect or ws.crop
        r = self.rect_view(c.x0, c.y0, c.width, c.height)
        q = self.to_model(pt)
        t = 9
        nl, nr = abs(pt.x() - r.left()) < t, abs(pt.x() - r.right()) < t
        nt, nb = abs(pt.y() - r.top()) < t, abs(pt.y() - r.bottom()) < t
        in_y = r.top() - t < pt.y() < r.bottom() + t
        in_x = r.left() - t < pt.x() < r.right() + t
        if nl and nt:
            h = "tl"
        elif nr and nt:
            h = "tr"
        elif nl and nb:
            h = "bl"
        elif nr and nb:
            h = "br"
        elif nl and in_y:
            h = "l"
        elif nr and in_y:
            h = "r"
        elif nt and in_x:
            h = "t"
        elif nb and in_x:
            h = "b"
        else:
            h = "move" if r.contains(pt) else "new"
        self.drag = ("crop", h, PixelRect(c.x0, c.y0, c.x1, c.y1), q)

    def _crop_rect(self, h: str, r0: PixelRect, s, q) -> PixelRect:
        dx, dy = float(sround(q[0] - s[0])), float(sround(q[1] - s[1]))
        r = PixelRect(r0.x0, r0.y0, r0.x1, r0.y1)
        if h == "new":
            return PixelRect(sround(min(s[0], q[0])), sround(min(s[1], q[1])), sround(max(s[0], q[0])), sround(max(s[1], q[1])))
        if h == "move":
            W, H = (float(v) for v in self.ws.active_size)
            mx, my = min(max(dx, -r0.x0), W - r0.x1), min(max(dy, -r0.y0), H - r0.y1)
            return PixelRect(r0.x0 + mx, r0.y0 + my, r0.x1 + mx, r0.y1 + my)
        if "l" in h:
            r.x0 += dx
        if "r" in h:
            r.x1 += dx
        if "t" in h:
            r.y0 += dy
        if "b" in h:
            r.y1 += dy
        return r


def _seg_dist(p: QPointF, a: QPointF, b: QPointF) -> float:
    dx, dy = b.x() - a.x(), b.y() - a.y()
    l2 = dx * dx + dy * dy
    if l2 <= 0:
        return math.hypot(p.x() - a.x(), p.y() - a.y())
    t = max(0.0, min(1.0, ((p.x() - a.x()) * dx + (p.y() - a.y()) * dy) / l2))
    return math.hypot(p.x() - (a.x() + t * dx), p.y() - (a.y() + t * dy))
