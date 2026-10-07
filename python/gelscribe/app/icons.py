"""Line icons for the tool palette, drawn with Qt so they look the same on every system."""
from __future__ import annotations

from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QIcon, QPainter, QPainterPath, QPen, QPixmap, QPolygonF

from . import theme


def _make(draw, color=None, size=40) -> QIcon:
    color = color or theme.C["icon"]   # drawn for the current look; windows redraw them when it changes
    icon = QIcon()
    for c, mode in ((color, QIcon.Mode.Normal), ("#ffffff", QIcon.Mode.Selected)):
        pm = QPixmap(size, size)
        pm.fill(Qt.GlobalColor.transparent)
        p = QPainter(pm)
        p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        p.scale(size / 20, size / 20)
        pen = QPen(QColor(c), 1.5)
        pen.setCapStyle(Qt.PenCapStyle.RoundCap)
        pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
        p.setPen(pen)
        p.setBrush(Qt.BrushStyle.NoBrush)
        draw(p, QColor(c))
        p.end()
        icon.addPixmap(pm, mode)
        icon.addPixmap(pm, QIcon.Mode.Normal, QIcon.State.On) if mode == QIcon.Mode.Selected else None
    return icon


def _select(p, c):
    path = QPainterPath()
    path.moveTo(6, 3)
    path.lineTo(6, 16)
    path.lineTo(9.2, 12.8)
    path.lineTo(11.5, 17.5)
    path.lineTo(13.5, 16.6)
    path.lineTo(11.2, 12)
    path.lineTo(15.5, 12)
    path.closeSubpath()
    p.setBrush(c)
    p.drawPath(path)


def _lanes(p, c):
    p.drawRoundedRect(QRectF(3, 4, 14, 12), 2, 2)
    p.drawLine(QPointF(7.7, 4), QPointF(7.7, 16))
    p.drawLine(QPointF(12.3, 4), QPointF(12.3, 16))


def _ladder(p, c):
    p.drawRoundedRect(QRectF(3, 7, 14, 6), 1.5, 1.5)
    for x in (6, 9, 12, 15):
        p.drawLine(QPointF(x, 7), QPointF(x, 9.5 if x % 2 else 10.5))


def _names(p, c):
    path = QPainterPath()
    path.moveTo(3.5, 4)
    path.lineTo(10, 4)
    path.lineTo(16.5, 10.5)
    path.lineTo(10.5, 16.5)
    path.lineTo(3.5, 9.5)
    path.closeSubpath()
    p.drawPath(path)
    p.drawEllipse(QPointF(7, 7.4), 1.2, 1.2)


def _crop(p, c):
    p.drawPolyline(QPolygonF([QPointF(6, 2.5), QPointF(6, 14), QPointF(17.5, 14)]))
    p.drawPolyline(QPolygonF([QPointF(2.5, 6), QPointF(14, 6), QPointF(14, 17.5)]))


def _straighten(p, c):
    p.drawLine(QPointF(3, 16), QPointF(17, 16))
    p.drawLine(QPointF(3, 16), QPointF(14, 6))
    path = QPainterPath()
    path.arcMoveTo(QRectF(-3, 10, 12, 12), 0)
    path.arcTo(QRectF(-3, 10, 12, 12), 0, 42)
    p.drawPath(path)


def _pan(p, c):
    for a, b in (((10, 2.5), (10, 17.5)), ((2.5, 10), (17.5, 10))):
        p.drawLine(QPointF(*a), QPointF(*b))
    for tip, d in (((10, 2.5), (0, 1)), ((10, 17.5), (0, -1)), ((2.5, 10), (1, 0)), ((17.5, 10), (-1, 0))):
        x, y = tip
        dx, dy = d
        p.drawLine(QPointF(x, y), QPointF(x + dx * 2.5 + dy * 2.2, y + dy * 2.5 + dx * 2.2))
        p.drawLine(QPointF(x, y), QPointF(x + dx * 2.5 - dy * 2.2, y + dy * 2.5 - dx * 2.2))


def _text(p, c):
    f = p.font()
    f.setPixelSize(9)
    f.setBold(True)
    p.setFont(f)
    p.drawText(QRectF(1, 6, 9, 10), Qt.AlignmentFlag.AlignCenter, "a")
    f.setPixelSize(13)
    p.setFont(f)
    p.drawText(QRectF(8, 3, 11, 14), Qt.AlignmentFlag.AlignCenter, "A")


def _snap(p, c):
    p.drawEllipse(QPointF(10, 10), 5.5, 5.5)
    for a, b in (((10, 2), (10, 6)), ((10, 14), (10, 18)), ((2, 10), (6, 10)), ((14, 10), (18, 10))):
        p.drawLine(QPointF(*a), QPointF(*b))


def _contrast(p, c):
    p.drawEllipse(QPointF(10, 10), 6.5, 6.5)
    path = QPainterPath()
    path.moveTo(10, 3.5)
    path.arcTo(QRectF(3.5, 3.5, 13, 13), 90, 180)
    path.closeSubpath()
    p.setBrush(c)
    p.drawPath(path)


def _eye(p, c):
    path = QPainterPath()
    path.moveTo(2.5, 10)
    path.quadTo(10, 2.5, 17.5, 10)
    path.quadTo(10, 17.5, 2.5, 10)
    p.drawPath(path)
    p.drawEllipse(QPointF(10, 10), 2.4, 2.4)


TOOL_ICONS = {"select": _select, "lanes": _lanes, "ladder": _ladder, "names": _names, "crop": _crop,
              "straighten": _straighten, "pan": _pan}


def tool_icon(tool: str) -> QIcon:
    return _make(TOOL_ICONS[tool])


def icon(name: str) -> QIcon:
    return _make({"text": _text, "snap": _snap, "contrast": _contrast, "eye": _eye}[name])
