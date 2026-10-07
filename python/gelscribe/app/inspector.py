"""The inspector on the right: labels (Aa), ladder, names, figure and export. Panels update their values in place,
and never overwrite a field you're typing in."""
from __future__ import annotations

import math
from typing import Callable, Optional

from PySide6.QtCore import QPointF, QRectF, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QFontDatabase, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import (QAbstractItemView, QCheckBox, QComboBox, QDoubleSpinBox, QFrame, QGridLayout,
                               QHBoxLayout, QInputDialog, QLabel, QLineEdit, QListWidget, QMenu, QPlainTextEdit,
                               QPushButton, QScrollArea, QSlider, QSpinBox, QVBoxLayout, QWidget)

from ..core import labels as ql
from ..core import ladders as lib
from ..core.image import ImageError
from ..core.model import GelProject, TEXT_KINDS, format_size, parse_separator, separator_rgb
from . import theme
from .editors import SizeStepper, button, label
from .workspace import Workspace

TABS = [("labels", "Aa"), ("ladder", "Ladder"), ("names", "Names"), ("figure", "Figure"), ("export", "Export")]
KEEP_HELP = ("Each gel has its own setting. A gel scanned at a slightly different size needs it off to be stretched "
             "into line.")
OWN_LADDER_HELP = "Its ladder sizes start again from the top instead of carrying on from the gel above."


def section(title: str) -> QLabel:
    return label(title.upper(), "section")


def hrow(*widgets, stretch_at: Optional[int] = None, spacing: int = 6) -> QWidget:
    w = QWidget()
    r = QHBoxLayout(w)
    r.setContentsMargins(0, 0, 0, 0)
    r.setSpacing(spacing)
    for i, x in enumerate(widgets):
        if x == "stretch":
            r.addStretch(1)
        elif isinstance(x, QWidget):
            r.addWidget(x)
    return w


def set_idle(field, text: str):
    """Sets a field's text unless the user is typing in it."""
    if field.hasFocus():
        return
    if isinstance(field, QPlainTextEdit):
        if field.toPlainText() != text:
            field.setPlainText(text)
    elif field.text() != text:
        field.setText(text)


def breakable(text: str) -> str:
    """Long unbroken runs (a SHA-256) get invisible break points, so they wrap instead of widening the panel."""
    import re
    return re.sub(r"(\S{24,})", lambda m: "\u200b".join(m.group(1)[i:i + 8] for i in range(0, len(m.group(1)), 8)), text)


def narrow(combo: QComboBox) -> QComboBox:
    """A drop-down that doesn't make the panel as wide as its longest item."""
    combo.setSizeAdjustPolicy(QComboBox.SizeAdjustPolicy.AdjustToMinimumContentsLengthWithIcon)
    combo.setMinimumContentsLength(14)
    return combo


def clear_layout(lay):
    while lay.count():
        it = lay.takeAt(0)
        w = it.widget()
        if w is not None:
            w.deleteLater()
        elif it.layout() is not None:
            clear_layout(it.layout())


class Segmented(QWidget):
    """A row of buttons where one is chosen."""
    chosen = Signal(str)

    def __init__(self, items: list[tuple[str, str]]):
        super().__init__()
        r = QHBoxLayout(self)
        r.setContentsMargins(0, 0, 0, 0)
        r.setSpacing(2)
        self.buttons = {}
        for key, title in items:
            b = button(title, lambda _=False, k=key: self.chosen.emit(k))
            b.setCheckable(True)
            self.buttons[key] = b
            r.addWidget(b)

    def set(self, key: str):
        for k, b in self.buttons.items():
            b.setChecked(k == key)


class DragSlider(QWidget):
    """A float slider whose drag is one undo step: change(v, live) while dragging, then end()."""

    def __init__(self, title: str, lo: float, hi: float, step: float, fmt: str,
                 change: Callable[[float, bool], None], end: Callable[[], None]):
        super().__init__()
        self.lo, self.hi, self.step, self.fmt = lo, hi, step, fmt
        self.change, self.end = change, end
        r = QHBoxLayout(self)
        r.setContentsMargins(0, 0, 0, 0)
        self.title = QLabel(title)
        self.title.setFixedWidth(78)
        self.slider = QSlider(Qt.Orientation.Horizontal)
        self.slider.setRange(0, max(1, int(round((hi - lo) / step))))
        self.value_label = label("", "caption")
        self.value_label.setFixedWidth(60)
        self.value_label.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        r.addWidget(self.title)
        r.addWidget(self.slider, 1)
        r.addWidget(self.value_label)
        self._setting = False
        self.slider.valueChanged.connect(self._moved)
        self.slider.sliderReleased.connect(self.end)

    def _moved(self, i):
        if self._setting:
            return
        v = self.lo + i * self.step
        self.change(v, self.slider.isSliderDown())

    def set(self, v: float, text: Optional[str] = None):
        self._setting = True
        if not self.slider.isSliderDown():
            self.slider.setValue(int(round((min(max(v, self.lo), self.hi) - self.lo) / self.step)))
        self._setting = False
        self.value_label.setText(text if text is not None else self.fmt % v)


class Histogram(QWidget):
    """The gel's histogram on the file's value axis, with the current mapping drawn over it like ImageJ's."""

    def __init__(self):
        super().__init__()
        self.setFixedHeight(72)
        self.counts, self.values, self.axis, self.display, self.scale = [], (0, 1), (0, 1), None, None

    def set(self, counts, values, axis, display, scale):
        self.counts, self.values, self.axis, self.display, self.scale = list(counts), values, axis, display, scale
        self.update()

    def paintEvent(self, _e):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        r = QRectF(self.rect())
        path = QPainterPath()
        path.addRoundedRect(r, 6, 6)
        p.fillPath(path, QColor(*theme.C["hist_well"]))
        if not self.counts or self.display is None:
            return
        p.setClipPath(path)
        span = max(self.axis[1] - self.axis[0], 1e-9)
        W, H = r.width(), r.height()

        def x(v):
            return (v - self.axis[0]) / span * W
        top = math.log1p(max(self.counts) or 1)
        step = (self.values[1] - self.values[0]) / max(len(self.counts), 1)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QColor(*theme.C["hist_bars"]))
        for i, c in enumerate(self.counts):
            if c <= 0:
                continue
            x0, x1 = x(self.values[0] + i * step), x(self.values[0] + (i + 1) * step)
            h = math.log1p(c) / top * H
            p.drawRect(QRectF(x0, H - h, max(1.0, x1 - x0), h))
        d, s = self.display, self.scale
        pts = []
        for k in range(97):
            v = self.axis[0] + span * k / 96
            g = (s.gray(v) - d.black) / max(d.white - d.black, 1e-9)
            g = min(1.0, max(0.0, g))
            if d.gamma != 1:
                g = g ** (1 / d.gamma)
            if d.invert:
                g = 1 - g
            pts.append(QPointF(x(v), (1 - g) * H))
        p.setPen(QPen(QColor(61, 123, 246), 1.5))
        for a, b in zip(pts, pts[1:]):
            p.drawLine(a, b)


class Panel(QWidget):
    def __init__(self, ws: Workspace):
        super().__init__()
        self.ws = ws
        self.box = QVBoxLayout(self)
        self.box.setContentsMargins(16, 14, 16, 16)
        self.box.setSpacing(8)

    def add(self, *ws_):
        for w in ws_:
            if isinstance(w, QWidget):
                self.box.addWidget(w)
            else:
                self.box.addLayout(w)

    def gap(self, h: int = 10):
        self.box.addSpacing(h)

    def refresh(self):
        pass


# ---------------------------------------------------------------------------------------------------- Aa


class AngleSpin(QDoubleSpinBox):
    """Degrees, typed: 45, not 45.0."""

    def textFromValue(self, v: float) -> str:
        return f"{v:g}"


class LabelsPanel(Panel):
    def __init__(self, ws: Workspace):
        super().__init__(ws)
        self.add(section("Lanes"))
        self.lane_count = QLabel()
        self.lane_count.setStyleSheet("font-weight: 700; font-size: 15px;")
        self.add(self.lane_count)
        self.outer = QCheckBox("Count the edges as lanes")
        self.outer.toggled.connect(lambda v: ws.set_outer_lanes(v) if v != ws.project.lanes.outer_lanes else None)
        self.add(self.outer)
        self.clear = button("Clear dividers", ws.clear_dividers)
        self.add(hrow(button("Lane tool", lambda: ws.set_tool("lanes")), "stretch", self.clear))
        self.gap()
        self.add(section("Quick labels"))
        self.quick = QPlainTextEdit()
        self.quick.setPlaceholderText("µM: Ladder|0{L|P}|50{L|P}|…")
        self.quick.setFont(QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont))
        self.quick.setFixedHeight(74)
        self.quick.textChanged.connect(self._quick_typed)
        self.quick.installEventFilter(self)
        self.add(self.quick)
        self.add(label("One label per lane, separated by |. Braces put lanes under a label: 0{L|P} is 0 over L and P. "
                       "Braces nest for more rows: WT{0{L|P}|50{L|P}}. Row titles go first: µM: … (or Strain, µM: … "
                       "from the top). \\n starts a new line inside a label. The lanes follow as you type.", "caption"))
        self.copy_lanes = button("Copy", self._copy_lane_labels, tip="Copy these lane labels as one line")
        self.add(hrow(self.copy_lanes, button("Paste", self._paste_lane_labels,
                                               tip="Paste lane labels copied from another gel"), "stretch"))
        self.warn = label("", "warn")
        self.add(self.warn)
        self.status = label("", "caption")
        self.add(self.status)
        self.angle = AngleSpin()
        self.angle.setRange(-360, 360)
        self.angle.setDecimals(1)
        self.angle.setSingleStep(1)
        self.angle.setSuffix("°")
        self.angle.setFixedWidth(64)
        self.angle.setButtonSymbols(QDoubleSpinBox.ButtonSymbols.NoButtons)
        self.angle.setToolTip("0° is level, 90° is straight up. Press Enter to apply.")
        self.angle.editingFinished.connect(lambda: ws.set_label_angle(self.angle.value())
                                           if abs(self.angle.value() - ws.project.label_angle) > 1e-9 else None)
        self.angle_steps = Segmented([("0", "0°"), ("45", "45°"), ("90", "90°")])
        self.angle_steps.chosen.connect(lambda k: (ws.set_label_angle(float(k)), self.refresh()))   # the chosen one stays lit
        self.add(hrow(QLabel("Angle"), self.angle, "stretch", self.angle_steps))
        self.angle_caption = label("Lane labels stand at this angle, rising to the right. Each row of group labels has its "
                                   "own angle, below. Row titles and band names stay level.", "caption")
        self.add(self.angle_caption)
        self.gap()
        self.add(section("Rows, top to bottom"))
        self.rows_box = QVBoxLayout()
        self.rows_box.setSpacing(8)
        self.add(self.rows_box)
        add_row = button("+ Add Row")
        m = QMenu(add_row)
        m.addAction("Group Row (numbers over lanes, e.g. 0 · 125)", lambda: ws.add_row("groups"))
        m.addAction("Lane Labels Row (one per lane, e.g. L · P)", lambda: ws.add_row("lanes"))
        add_row.setMenu(m)
        self.add(hrow(add_row, "stretch"))
        self.gap()
        self.add(section("Lane labels"))
        self.lanes_grid = QGridLayout()
        self.lanes_grid.setHorizontalSpacing(8)
        self.lanes_grid.setVerticalSpacing(4)
        self.add(self.lanes_grid)
        self.gap()
        self.add(section("Title"))
        self.title = QLineEdit()
        self.title.editingFinished.connect(lambda: ws.set_title(self.title.text()) if self.title.text() != (ws.project.title or "") else None)
        self.add(self.title)
        self.gap()
        self.add(section("Text size"))
        self.add(hrow(QLabel("All text"), "stretch", button("A−", lambda: ws.scale_all_text(-0.5)),
                      button("A+", lambda: ws.scale_all_text(0.5))))
        self.steppers = {}
        for kind, title in TEXT_KINDS:
            st = SizeStepper(ws.project.style.size_for_kind(kind))
            st.changed.connect(lambda v, k=kind: ws.set_kind_size(v, k))
            self.steppers[kind] = st
            self.add(hrow(QLabel(title), "stretch", st))
        self.add(label("Click one label on the figure to size just that label.", "caption"))
        self.gap()
        self.add(section("Reuse on another gel"))
        self.add(label("Labels, row titles, title, band names, ladder settings and text sizes. Lane dividers and "
                       "ladder ticks belong to each image.", "caption"))
        self.reuse = hrow(button("Copy Labels", lambda: self.window().copy_labels()),
                          button("Paste Labels", lambda: self.window().paste_labels(False)), "stretch")
        self.add(self.reuse)
        self.add(label("New gel with these labels: File menu, Ctrl+Shift+N.", "caption"))
        self.box.addStretch(1)
        self._rows_sig = None
        self._lanes_sig = None
        self._lane_fields = []

    def eventFilter(self, obj, e):
        if obj is self.quick and e.type() == e.Type.FocusOut:
            self.ws.finish_quick_labels()
        return False

    def _quick_typed(self):
        if not self.quick.hasFocus():
            return
        text = self.quick.toPlainText()
        if text == self.ws.quick_labels:
            return
        self.ws.quick_labels = text
        self.ws.quick_labels_typed()

    def _copy_lane_labels(self):
        from PySide6.QtWidgets import QApplication
        t = ql.shorthand(self.ws.project)
        if t:
            QApplication.clipboard().setText(t)

    def _paste_lane_labels(self):
        from PySide6.QtWidgets import QApplication
        text = QApplication.clipboard().text().strip()
        if not text:
            self.ws.message.emit("Nothing to paste: copy lane labels from a gel first.")
            return
        if self.ws.paste_scheme(text, False):
            return
        self.ws.quick_labels = text
        self.ws.apply_quick_labels()

    def refresh(self):
        ws, p = self.ws, self.ws.project
        n = p.lane_count
        self.lane_count.setText(f"{n} lanes   <span style='color:{theme.C['dim']};font-weight:400;font-size:13px'>from "
                                f"{len(p.lanes.dividers)} dividers</span>")
        self.outer.blockSignals(True)
        self.outer.setChecked(p.lanes.outer_lanes)
        self.outer.blockSignals(False)
        self.clear.setEnabled(bool(p.lanes.dividers))
        if not self.quick.hasFocus() and not ws.typing_quick:
            ws.quick_labels = ql.shorthand(p)
        self.quick.blockSignals(True)
        set_idle(self.quick, ws.quick_labels)
        self.quick.blockSignals(False)
        self.copy_lanes.setEnabled(bool(ql.shorthand(p)))
        self.warn.setText(ws.last_error or "")
        self.warn.setVisible(bool(ws.last_error))
        count = ql.lane_count(ql.shorthand(p))
        if n == 0:
            self.status.setText(f"{count} lane labels ready. Place the lane dividers (L) and each label appears on its "
                                "lane." if count else "You can type the labels before or after placing the lanes.")
        elif count and count != n:
            self.status.setText(f"⚠ {count} labels for {n} lanes")
        else:
            self.status.setText("")
        self.status.setVisible(bool(self.status.text()))
        angle = p.label_angle
        self.angle.blockSignals(True)
        if not self.angle.hasFocus():
            self.angle.setValue(angle)
        self.angle.blockSignals(False)
        self.angle_steps.set(next((k for k in ("0", "45", "90") if abs(float(k) - angle) < 1e-9), ""))
        for w in (self.angle, self.angle_steps):   # there has to be a row of lane labels to stand at an angle
            w.setEnabled(any(r.type == "lanes" for r in p.rows))
        self._refresh_rows()
        self._refresh_lanes()
        set_idle(self.title, p.title or "")
        for kind, st in self.steppers.items():
            st.set_value(p.style.size_for_kind(kind))

    def _refresh_rows(self):
        p = self.ws.project
        sig = tuple((r.type, len(r.groups)) for r in p.rows)
        if sig != self._rows_sig:
            self._rows_sig = sig
            clear_layout(self.rows_box)
            self._row_widgets = []
            for ri in reversed(range(len(p.rows))):   # top to bottom
                self._row_widgets.append(self._row_card(ri))
        for ri, (name_field, group_fields, underline, angle) in self._row_widgets:
            if ri >= len(p.rows):
                continue
            row = p.rows[ri]
            if angle is not None:
                spin, steps = angle
                spin.blockSignals(True)
                if not spin.hasFocus():
                    spin.setValue(row.rotation)
                spin.blockSignals(False)
                steps.set(next((k for k in ("0", "45", "90") if abs(float(k) - row.rotation) < 1e-9), ""))
            set_idle(name_field, row.name or "")
            for gi, (tf, a, b) in enumerate(group_fields):
                if gi < len(row.groups):
                    g = row.groups[gi]
                    set_idle(tf, g.text)
                    for spin, v in ((a, g.first), (b, g.last)):
                        if not spin.hasFocus():
                            spin.blockSignals(True)
                            spin.setMaximum(max(p.lane_count, g.last, 1))
                            spin.setValue(v)
                            spin.blockSignals(False)
            if underline is not None:
                underline.blockSignals(True)
                underline.setChecked(row.underline)
                underline.blockSignals(False)

    def _row_card(self, ri: int):
        ws, row = self.ws, self.ws.project.rows[ri]
        card = QFrame()
        card.setProperty("card", True)
        v = QVBoxLayout(card)
        v.setContentsMargins(10, 8, 10, 8)
        v.setSpacing(5)
        name = QLineEdit()
        name.setPlaceholderText("Row title" if row.type == "lanes" else "Row title (e.g. µM)")
        name.editingFinished.connect(lambda: ws.set_row_name(ri, name.text()) if ri < len(ws.project.rows)
                                     and name.text() != (ws.project.rows[ri].name or "") else None)
        v.addWidget(hrow(QLabel("Abc" if row.type == "lanes" else "▤"), name,
                         button("✕", lambda: ws.delete_row(ri), "link", "Delete this row")))
        groups = []
        underline = None
        angle = None
        if row.type == "groups":
            for gi, g in enumerate(row.groups):
                tf = QLineEdit(g.text)
                tf.setFixedWidth(84)
                tf.editingFinished.connect(lambda gi=gi, tf=tf: ws.update_group(ri, gi, text=tf.text())
                                           if tf.text() != ws.project.rows[ri].groups[gi].text else None)
                a, b = QSpinBox(), QSpinBox()
                for s in (a, b):
                    s.setMinimum(1)
                    s.setMaximum(max(ws.project.lane_count, g.last, 1))
                    s.setFixedWidth(52)
                a.setValue(g.first)
                b.setValue(g.last)
                a.valueChanged.connect(lambda val, gi=gi: ws.update_group(ri, gi, first=val))
                b.valueChanged.connect(lambda val, gi=gi: ws.update_group(ri, gi, last=val))
                v.addWidget(hrow(tf, label("lanes", "caption"), a, QLabel("–"), b, "stretch",
                                 button("⊖", lambda _=False, gi=gi: ws.delete_group(ri, gi), "link", "Remove")))
                groups.append((tf, a, b))
            underline = QCheckBox("Underline")
            underline.toggled.connect(lambda on: ws.set_underline(ri, on))
            v.addWidget(hrow(button("⊕ Add group", lambda: ws.add_group(ri), "link"), "stretch", underline))
            spin = AngleSpin()   # these labels stand at an angle of their own, over the middle of their lanes; the underline stays flat
            spin.setRange(-360, 360)
            spin.setDecimals(1)
            spin.setSingleStep(1)
            spin.setSuffix("°")
            spin.setFixedWidth(64)
            spin.setButtonSymbols(QDoubleSpinBox.ButtonSymbols.NoButtons)
            spin.setToolTip("0° is level, 90° is straight up. Press Enter to apply. The underline stays level.")
            spin.editingFinished.connect(lambda: ws.set_row_angle(ri, spin.value())
                                         if ri < len(ws.project.rows) and abs(spin.value() - ws.project.rows[ri].rotation) > 1e-9
                                         else None)
            steps = Segmented([("0", "0°"), ("45", "45°"), ("90", "90°")])
            steps.chosen.connect(lambda k: (ws.set_row_angle(ri, float(k)), self.refresh()))
            v.addWidget(hrow(QLabel("Angle"), spin, "stretch", steps))
            angle = (spin, steps)
        else:
            v.addWidget(label("Edit these under Lane labels below, or click a label on the figure.", "caption"))
        self.rows_box.addWidget(card)
        return ri, (name, groups, underline, angle)

    def _refresh_lanes(self):
        p = self.ws.project
        row = next((r for r in p.rows if r.type == "lanes"), None)
        labels = list(row.labels) if row else []
        n = max(p.lane_count, len(labels))
        if n != self._lanes_sig:
            self._lanes_sig = n
            clear_layout(self.lanes_grid)
            self._lane_fields = []
            for i in range(n):
                num = label(str(i + 1), "caption")
                f = QLineEdit()
                f.setPlaceholderText(f"lane {i + 1}")
                f.editingFinished.connect(lambda i=i, f=f: self._lane_edited(i, f))
                self.lanes_grid.addWidget(num, i, 0)
                self.lanes_grid.addWidget(f, i, 1)
                self._lane_fields.append(f)
        for i, f in enumerate(self._lane_fields):
            set_idle(f, (labels[i] if i < len(labels) else "").replace("\n", "\\n"))

    def _lane_edited(self, i, f):
        v = f.text().replace("\\n", "\n")
        row = next((r for r in self.ws.project.rows if r.type == "lanes"), None)
        cur = row.labels[i] if row and i < len(row.labels) else ""
        if v != cur:
            self.ws.set_lane_label(i + 1, v)


# ---------------------------------------------------------------------------------------------------- ladder


class LadderPanel(Panel):
    def __init__(self, ws: Workspace):
        super().__init__(ws)
        self.add(section("Ladder"))
        self.preset = narrow(QComboBox())
        self.preset.activated.connect(lambda i: ws.choose_preset(self.preset.itemData(i)))
        self.add(self.preset)
        self.system_label = label("Gel & buffer", "caption")
        self.system = narrow(QComboBox())
        self.system.activated.connect(lambda i: ws.choose_system(self.system.itemData(i)))
        self.add(self.system_label, self.system)
        self.note = QLabel()
        self.note.setWordWrap(True)
        self.note.setProperty("caption", True)
        self.note.setOpenExternalLinks(True)
        self.add(self.note)
        self.add(label("Sizes, largest first: edit to match your ladder", "caption"))
        self.sizes = QLineEdit()
        self.sizes.returnPressed.connect(lambda: ws.set_ladder_sizes(self.sizes.text()))
        self.add(self.sizes)
        self.add(hrow(button("Use these sizes", lambda: ws.set_ladder_sizes(self.sizes.text())), "stretch",
                      button("Save as my ladder…", self._save)))
        self.gap()
        self.add(section("Placement"))
        self.side = Segmented([("left", "Left"), ("right", "Right")])
        self.side.chosen.connect(ws.set_ladder_side)
        self.unit = QLineEdit()
        self.unit.setFixedWidth(60)
        self.unit.editingFinished.connect(lambda: ws.set_unit(self.unit.text()) if ws.project.ladder is None
                                          or self.unit.text() != ws.project.ladder.unit else None)
        self.add(hrow(self.side, self.unit, "stretch"))
        self.size = SizeStepper(ws.project.style.size_for_kind("ladder"))
        self.size.changed.connect(lambda v: ws.set_kind_size(v, "ladder"))
        self.add(hrow(QLabel("Text size"), "stretch", self.size))
        self.unit_title = QLabel("kDa label")
        self.add(hrow(self.unit_title, "stretch", button("Place…", self._place, tip="Click on the figure where it goes"),
                      button("Automatic", lambda: ws.set_unit_y(None))))
        self.gap()
        self.add(section("Ticks, top to bottom"))
        self.add(label("Click each ladder band on the gel, top first. Each click takes the next size.", "caption"))
        self.ticks_grid = QGridLayout()
        self.ticks_grid.setVerticalSpacing(4)
        self.add(self.ticks_grid)
        self.add(hrow(button("Assign top-down", ws.assign_top_down), "stretch", button("Confirm all", ws.confirm_ticks)))
        self.warn = label("", "warn")
        self.add(self.warn)
        self.box.addStretch(1)
        self._ticks_sig = None
        self._presets_sig = None

    def _save(self):
        name, ok = QInputDialog.getText(self, "Save as my ladder", "Name for this ladder:")
        if ok and name.strip():
            self.ws.save_custom_ladder(name.strip())

    def _place(self):
        self.ws.begin_placing_unit()

    def refresh(self):
        ws, p = self.ws, self.ws.project
        presets = lib.all_presets()
        sig = tuple(x.id for x in presets)
        if sig != self._presets_sig:
            self._presets_sig = sig
            self.preset.clear()
            for x in presets:
                self.preset.addItem(x.display_name, x.id)
        i = self.preset.findData(ws.preset_id)
        if i >= 0:
            self.preset.setCurrentIndex(i)
        pr = ws.preset
        systems = pr.systems if pr else []
        self.system.clear()
        for s in systems:
            self.system.addItem(s.name, s.id)
        cur = ws.system
        if cur:
            self.system.setCurrentIndex(max(0, self.system.findData(cur.id)))
        self.system.setVisible(bool(systems))
        self.system_label.setVisible(bool(systems))
        note = ""
        if pr and systems:
            note = "Prestained bands run at different apparent sizes on each gel and buffer."
        if pr and pr.source:
            note += f" Check the <a href='{pr.source}' style='color:{theme.C['link']}'>vendor datasheet</a>."
        if pr and pr.notes and not systems:
            note += " " + pr.notes
        self.note.setText(note.strip())
        self.note.setVisible(bool(note))
        set_idle(self.sizes, ", ".join(format_size(s) for s in ws.ladder_sizes))
        lad = p.ladder
        self.side.set(lad.side if lad else "left")
        set_idle(self.unit, lad.unit if lad else (pr.unit if pr else "kDa"))
        self.unit_title.setText(f"{lad.unit if lad else 'kDa'} label")
        self.size.set_value(p.style.size_for_kind("ladder"))
        bands = lad.bands if lad else []
        # with several gels, each gel's ticks under its name, top to bottom; y in that gel's own pixels
        groups = [None] if not p.strips else p.stack_order
        sig = (len(bands), tuple(b.strip for b in bands), tuple(groups))
        if sig != self._ticks_sig:
            self._ticks_sig = sig
            clear_layout(self.ticks_grid)
            self._tick_fields = [None] * len(bands)
            row = 0
            for k in groups:
                members = [i for i, b in enumerate(bands) if b.strip == k or not p.strips]
                if p.strips and members:
                    self.ticks_grid.addWidget(label(ws.gel_name(k), "caption"), row, 0, 1, 4)
                    row += 1
                for i in members:
                    y = label("", "caption")
                    f = QLineEdit()
                    f.setFixedWidth(80)
                    f.editingFinished.connect(lambda i=i, f=f: self._tick_edited(i, f))
                    mark = label("", "caption")
                    dl = button("✕", lambda _=False, i=i: ws.delete_tick(i), "link", "Delete this tick")
                    self.ticks_grid.addWidget(y, row, 0)
                    self.ticks_grid.addWidget(f, row, 1)
                    self.ticks_grid.addWidget(mark, row, 2)
                    self.ticks_grid.addWidget(dl, row, 3)
                    self._tick_fields[i] = (y, f, mark)
                    row += 1
                if not p.strips:
                    break
        for i, fields in enumerate(self._tick_fields):
            if fields is None:
                continue
            y, f, mark = fields
            if i < len(bands):
                b = bands[i]
                y.setText(f"y {int(b.y)}")
                set_idle(f, "skip" if b.ignore else (format_size(b.size) if b.size is not None else ""))
                mark.setText("guess" if b.auto else "")
        w = p.ladder_warnings
        self.warn.setText(" ".join(w))
        self.warn.setVisible(bool(w))

    def _tick_edited(self, i, f):
        t = f.text().strip().replace(",", ".")
        bands = self.ws.project.ladder.bands if self.ws.project.ladder else []
        if i >= len(bands):
            return
        if t.lower() == "skip":
            if not bands[i].ignore:
                self.ws.set_tick(i, None, ignore=True)
            return
        try:
            v = float(t) if t else None
        except ValueError:
            return
        if v != bands[i].size or bands[i].auto:
            self.ws.set_tick(i, v, ignore=False if bands[i].ignore else None)


# ---------------------------------------------------------------------------------------------------- names


class NamesPanel(Panel):
    def __init__(self, ws: Workspace):
        super().__init__(ws)
        self.add(section("Band names"))
        self.add(hrow(button("Name a band", lambda: ws.set_tool("names"), "primary",
                             "Switches to the band-name tool (N)"), "stretch"))
        self.hint = label("Click the band in the lane next to the edge, then type its name.", "caption")
        self.add(self.hint)
        self.list = QVBoxLayout()
        self.list.setSpacing(8)
        self.add(self.list)
        self.box.addStretch(1)
        self._sig = None
        self._cards = []

    def refresh(self):
        ws, p = self.ws, self.ws.project
        self.hint.setVisible(not p.annotations)
        sig = len(p.annotations)
        if sig != self._sig:
            self._sig = sig
            clear_layout(self.list)
            self._cards = []
            for i in range(len(p.annotations)):
                card = QFrame()
                card.setProperty("card", True)
                v = QVBoxLayout(card)
                v.setContentsMargins(10, 8, 10, 8)
                gel = label("", "caption")
                v.addWidget(gel)
                text = QLineEdit()
                text.setToolTip("\\n starts a new line")
                text.editingFinished.connect(lambda i=i, t=text: self._text(i, t))
                v.addWidget(hrow(text, button("✕", lambda _=False, i=i: ws.delete_name(i), "link", "Delete")))
                marker = Segmented([("arrow", "Arrow"), ("tick", "Tick"), ("bracket", "Bracket"), ("none", "Text")])
                marker.chosen.connect(lambda k, i=i: ws.update_name(i, lambda a: setattr(a, "marker", k)))
                v.addWidget(marker)
                side = Segmented([("left", "Left"), ("right", "Right")])
                side.chosen.connect(lambda k, i=i: ws.update_name(i, lambda a: setattr(a, "side", k)))
                from ..core.model import Role
                size = SizeStepper(p.style.size_for(Role("annotation", i)))
                size.changed.connect(lambda val, i=i: ws.set_label_size(val, Role("annotation", i)))
                v.addWidget(hrow(side, "stretch", size))
                self.list.addWidget(card)
                self._cards.append((gel, text, marker, side, size))
        from ..core.model import Role
        for i, (gel, text, marker, side, size) in enumerate(self._cards):
            if i < len(p.annotations):
                a = p.annotations[i]
                gel.setText(ws.gel_name(a.strip))
                gel.setVisible(bool(p.strips))
                set_idle(text, a.text.replace("\n", "\\n"))
                marker.set(a.marker)
                side.set(a.side)
                size.set_value(p.style.size_for(Role("annotation", i)))

    def _text(self, i, t):
        v = t.text().replace("\\n", "\n")
        if i < len(self.ws.project.annotations) and v != self.ws.project.annotations[i].text:
            self.ws.update_name(i, lambda a: setattr(a, "text", v))
            self.ws.remember_name(v)


# ---------------------------------------------------------------------------------------------------- figure


class _GelList(QListWidget):
    """The gels top to bottom: a click chooses one, a drag moves it to another place."""

    def __init__(self, ws: Workspace):
        super().__init__()
        self.ws = ws
        self.setDragDropMode(QAbstractItemView.DragDropMode.InternalMove)
        self.setDefaultDropAction(Qt.DropAction.MoveAction)
        self.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.itemClicked.connect(lambda it: ws.choose_gel(ws.project.stack_order[self.row(it)]))
        self.itemDoubleClicked.connect(lambda it: ws.show_gel(ws.project.stack_order[self.row(it)]))   # that gel on its own
        self.model().rowsMoved.connect(self._moved)

    def keyPressEvent(self, e):
        super().keyPressEvent(e)
        if e.key() in (Qt.Key.Key_Up, Qt.Key.Key_Down, Qt.Key.Key_Home, Qt.Key.Key_End):   # the arrows choose, as a click does
            order = self.ws.project.stack_order
            if 0 <= self.currentRow() < len(order):
                self.ws.choose_gel(order[self.currentRow()])

    def _moved(self, _parent, start, _end, _dest, row):
        # the list moved its row already; the project follows once Qt is done with the drop
        to = row - 1 if row > start else row
        if to != start:
            QTimer.singleShot(0, lambda: self.ws.move_gel(start, to))


class GelsSection(QWidget):
    """The gels in the figure, top to bottom: which one the Figure tab acts on, adding, ordering and removing gels,
    and lining each one's lanes up under the lanes of the gel that has them."""

    def __init__(self, ws: Workspace):
        super().__init__()
        self.ws = ws
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(8)
        v.addWidget(section("Gels"))
        self.single_name = QLabel()
        self.single = hrow(self.single_name, "stretch",
                           button("Add Gel…", self._add, tip="Another gel, or the other pieces of a cut membrane, to stack under this one"))
        self.single_caption = label("More gels go under this one, each with a line above it, and share its lanes and labels.",
                                    "caption")
        self.list = _GelList(ws)
        self.up = button("↑", lambda: self._move(-1), tip="Move the chosen gel up")
        self.down = button("↓", lambda: self._move(1), tip="Move the chosen gel down")
        self.remove = button("Remove", ws.remove_active_gel, tip="Take the chosen gel out of the figure, with its ticks and names")
        self.buttons = hrow(button("Add Gel…", self._add, tip="More gels, or the other pieces of a cut membrane, at the bottom of the stack"),
                            "stretch", self.up, self.down, self.remove)
        self.list_caption = label("Click a gel to work on it, here or in the figure (Select tool). Double-click one to see it "
                                  "on its own. Drag one up or down to change the order.", "caption")
        # the line between gels: black or white by a click, or any color by its hex (neither segment is lit for another color)
        self.line = Segmented([("black", "Black"), ("white", "White")])
        self.line.chosen.connect(lambda c: ws.set_separator(c))
        self.hex = QLineEdit()
        self.hex.setPlaceholderText("#000000")
        self.hex.setFixedWidth(84)
        self.hex.setToolTip("The color of the line as #RRGGBB (RRGGBB and #RGB work too). Gray figures use its brightness.")
        self.hex.editingFinished.connect(self._hex_typed)
        self.thick = QDoubleSpinBox()
        self.thick.setRange(*GelProject.SEPARATOR_WIDTHS)
        self.thick.setDecimals(2)
        self.thick.setSingleStep(0.25)
        self.thick.setSuffix(" pt")
        self.thick.setKeyboardTracking(False)
        self.thick.setToolTip("How thick the line between gels is, 0.25 to 10 points. Until you set it, it is as thick as "
                              "the Lines width.")
        self.thick.valueChanged.connect(lambda v: ws.set_separator_width(v)
                                        if abs(v - ws.project.effective_separator_width) > 1e-9 else None)
        self.match = button("Match lines", lambda: ws.set_separator_width(None),
                            tip="Make the line as thick as the figure's other lines again (Lines, under Layout), and follow them")
        self.line_row = QWidget()
        lv = QVBoxLayout(self.line_row)
        lv.setContentsMargins(0, 0, 0, 0)
        lv.setSpacing(6)
        lv.addWidget(QLabel("Line between gels:"))
        lv.addWidget(hrow(self.line, self.hex, "stretch"))
        lv.addWidget(label("Gray figures use the color's brightness.", "caption"))
        lv.addWidget(hrow(QLabel("Thickness"), self.thick, "stretch", self.match))
        self.problem = label("", "warn")   # a gel whose image can't be read
        self.own = QCheckBox("Own ladder")
        self.own.setToolTip(OWN_LADDER_HELP)
        self.own.toggled.connect(lambda v: ws.set_own_ladder(v) if v != ws.project.has_own_ladder(ws.active_strip) else None)
        self.own_caption = label(OWN_LADDER_HELP, "caption")
        self.file = label("", "caption")
        self.auto = button("Auto-align", ws.auto_align, tip="Finds this gel's lanes and lines them up under the lane dividers")
        self.align_row = hrow(self.auto, "stretch",
                              button("←", lambda: ws.nudge_active_gel(-1), tip="Move the gel 1 px left (← with nothing selected; Shift for 10 px)"),
                              button("→", lambda: ws.nudge_active_gel(1), tip="Move the gel 1 px right (→ with nothing selected; Shift for 10 px)"))
        self.shift = QDoubleSpinBox()
        self.shift.setRange(-100000, 100000)
        self.shift.setDecimals(2)
        self.shift.setSuffix(" px")
        self.shift.setButtonSymbols(QDoubleSpinBox.ButtonSymbols.NoButtons)
        self.shift.setToolTip("x in this gel = stretch × x in the figure + shift. No other gel moves; the gel with the lanes "
                              "takes its lane dividers, labels, ticks and names with it.")
        self.shift.editingFinished.connect(lambda: self._set_shift())
        self.stretch = QDoubleSpinBox()
        self.stretch.setRange(-50, 100)
        self.stretch.setDecimals(2)
        self.stretch.setSuffix(" %")
        self.stretch.setButtonSymbols(QDoubleSpinBox.ButtonSymbols.NoButtons)
        self.stretch.setToolTip("How much wider this gel's lanes are than the gel with the lanes, in percent")
        self.stretch.editingFinished.connect(lambda: self._set_stretch())
        self.fields = hrow(QLabel("Shift"), self.shift, "stretch", QLabel("Stretch"), self.stretch)
        self.note = label("", "caption")
        self.strict_note = label("This gel keeps original pixels, so Stretch is off: it only shifts by whole pixels. "
                                 "Turn off Keep original pixels (Original image, above) to stretch it.", "caption")
        self.align_all = hrow(button("Auto-align All", ws.auto_align_all,
                                     tip="Lines every other gel up under this gel's lane dividers"), "stretch")
        for w in (self.single, self.single_caption, self.list, self.buttons, self.list_caption, self.line_row, self.problem, self.own,
                  self.own_caption, self.file, self.align_row, self.fields, self.align_all, self.note, self.strict_note):
            v.addWidget(w)
        self._rows = None

    def _add(self):
        self.window().add_gel_dialog()

    def _move(self, d: int):
        place = self.ws.project.position_of(self.ws.active_strip)
        self.ws.move_gel(place, place + d)

    def _hex_typed(self):
        c = parse_separator(self.hex.text())
        if c is not None:
            self.ws.set_separator(c)
        self.hex.setText(self._hex_of(self.ws.project.separator))   # as it was normalized, or what it was

    @staticmethod
    def _hex_of(colour: str) -> str:
        return "#%02x%02x%02x" % separator_rgb(colour)

    def _set_shift(self):
        if abs(self.shift.value() - self.ws.active_shift) > 1e-9:
            self.ws.set_shift(self.shift.value())

    def _set_stretch(self):
        k = self.ws.active_strip
        if k is not None and abs(self.stretch.value() - (self.ws.project.effective_alignment(k)[1] - 1) * 100) > 1e-6:
            self.ws.set_scale(1 + self.stretch.value() / 100)

    def refresh(self):
        ws, p = self.ws, self.ws.project
        several = bool(p.strips)
        for w in (self.single, self.single_caption):
            w.setVisible(not several)
        for w in (self.list, self.buttons, self.list_caption, self.line_row, self.own, self.own_caption):
            w.setVisible(several)
        self.line.set(p.separator if p.separator in ("black", "white") else "")
        if not self.hex.hasFocus():
            self.hex.setText(self._hex_of(p.separator))
        self.thick.blockSignals(True)
        if not self.thick.hasFocus():
            self.thick.setValue(p.effective_separator_width)
        self.thick.blockSignals(False)
        self.match.setEnabled(p.separator_width is not None)
        self.single_name.setText(p.image)
        problem = ws.unreadable_gel
        self.problem.setText(problem or "")
        self.problem.setVisible(bool(problem))
        if not several:
            for w in (self.file, self.align_row, self.fields, self.align_all, self.note, self.strict_note):
                w.setVisible(False)
            return
        order = p.stack_order
        rows = [f"Gel {n + 1}   {p.image if k is None else p.strips[k - 1].image}" + ("   LANES" if k is None else "")
                for n, k in enumerate(order)]
        if rows != self._rows:
            self._rows = rows
            self.list.blockSignals(True)
            self.list.clear()
            self.list.addItems(rows)
            self.list.blockSignals(False)
            self.list.setFixedHeight(self.list.sizeHintForRow(0) * len(rows) + 2 * self.list.frameWidth() + 4)
        k = ws.active_strip
        place = p.position_of(k)
        self.list.blockSignals(True)
        self.list.setCurrentRow(place)
        self.list.blockSignals(False)
        self.up.setEnabled(place > 0)
        self.down.setEnabled(place < len(order) - 1)
        self.remove.setVisible(k is not None)
        self.own.blockSignals(True)
        self.own.setChecked(p.has_own_ladder(k))
        self.own.blockSignals(False)
        self.own.setEnabled(place > 0)   # the top gel always starts the first ladder
        chosen = k is not None
        self.file.setVisible(chosen)
        for w in (self.align_row, self.fields):   # the gel with the lanes moves too (its dividers, labels, ticks and names with it)
            w.setVisible(True)
        self.auto.setVisible(chosen)
        self.align_all.setVisible(not chosen)
        self.strict_note.setVisible(chosen and p.is_strict(k))
        shift, scale = (p.effective_alignment(k) if chosen else (p.effective_main_shift, 1.0))
        self.shift.blockSignals(True)
        self.shift.setDecimals(2 if chosen and not p.is_strict(k) else 0)   # whole pixels for a gel that keeps its pixels
        self.shift.blockSignals(False)
        for f, v in ((self.shift, shift), (self.stretch, (scale - 1) * 100)):
            if not f.hasFocus():
                f.blockSignals(True)
                f.setValue(v)
                f.blockSignals(False)
        self.stretch.setEnabled(chosen and not p.is_strict(k))
        self.stretch.setToolTip("How much wider this gel's lanes are than the gel with the lanes, in percent" if chosen else
                                "Stretch is for the other gels: the gel with the lanes is the one they line up with")
        if chosen:
            w, h = ws.active_size
            self.file.setText(f"{p.strips[k - 1].image} · {w} × {h} px" if w else f"{p.strips[k - 1].image}")
            self.note.setText(ws.align_note or "Drag the gel sideways in the figure (Select tool), or Auto-align, until "
                                               "its lanes sit between the dividers.")
        else:
            self.note.setText(ws.align_note or "This gel's lane dividers are the ones every gel uses. Drag any gel sideways in "
                                               "the figure (Select tool) to line the edges up, or choose another gel to line "
                                               "it up on its own.")
        self.note.setVisible(True)


KEEPS_TEXT = ("The figure carries the original values, bit depth and color space, never resampled. Rotation and fill are "
              "off, crop only selects pixels, and brightness & contrast change the screen only.")
ADJUSTED_TEXT = ("Rotation, fill, and brightness & contrast change the exported pixels, and exports record exactly what was "
                 "done.")


class _KeepRows(QWidget):
    """Original image with several gels: one row for each, in stack order (the one with the lanes tagged), each with its own
    Keep original pixels switch, whichever gel is chosen. A click on a gel's name chooses it. Under a row: what the switch
    means for the chosen gel, that a gel that keeps its pixels is lined up by whole pixels, and why the gels that keep
    theirs can't be exported untouched."""

    def __init__(self, ws: Workspace):
        super().__init__()
        self.ws = ws
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(6)
        head = QLabel("Keep original pixels")
        head.setStyleSheet("font-weight: 600;")
        v.addWidget(head)
        self.box = QVBoxLayout()
        self.box.setSpacing(6)
        v.addLayout(self.box)
        v.addWidget(label("Each gel has its own setting. The gels that keep their pixels must be stored the same way "
                          "(bit depth, color).", "caption"))
        self._sig = None
        self.rows: list[dict] = []   # per gel: strip number, card, lock, switch, notes

    def _build(self, order):
        clear_layout(self.box)
        self.rows = []
        for n, k in enumerate(order):
            card = QFrame()
            card.setProperty("card", True)
            cv = QVBoxLayout(card)
            cv.setContentsMargins(8, 5, 8, 5)
            cv.setSpacing(3)
            lock = QLabel()
            name = button(f"Gel {n + 1}", lambda _=False, k=k: self.ws.choose_gel(k), "link", "Choose this gel")
            name.setStyleSheet("font-weight: 600;")
            switch = QCheckBox()
            switch.setToolTip(f"Keep original pixels for Gel {n + 1}. {KEEP_HELP}")
            switch.toggled.connect(lambda on, k=k: self.ws.set_strict(on, strip=k) if on != self.ws.project.is_strict(k) else None)
            tag = QLabel("LANES")
            tag.setStyleSheet(f"font-size: 9px; font-weight: 700; padding: 1px 5px; border-radius: 7px; "
                              f"background: {theme.ACCENT}; color: white;")
            tag.setToolTip("Its lane dividers are the ones every gel uses")
            tag.setVisible(k is None)
            cv.addWidget(hrow(lock, name, tag, "stretch", switch))
            notes = {"chosen": label("", "caption"), "lined": label(
                "Lined up by whole pixels, never stretched. Turn it off to stretch this gel into line.", "caption"),
                "problem": label("", "warn")}
            for w in notes.values():
                w.setWordWrap(True)
                cv.addWidget(w)
            self.box.addWidget(card)
            self.rows.append({"k": k, "card": card, "lock": lock, "switch": switch, "notes": notes})

    def refresh(self):
        ws, p = self.ws, self.ws.project
        order = p.stack_order
        if tuple(order) != self._sig:
            self._sig = tuple(order)
            self._build(order)
        problem = ws.strict_problem_detail
        for r in self.rows:
            k = r["k"]
            on, chosen = p.is_strict(k), ws.active_strip == k
            r["lock"].setText("🔒" if on else "🔓")
            r["switch"].blockSignals(True)
            r["switch"].setChecked(on)
            r["switch"].blockSignals(False)
            if bool(r["card"].property("chosen")) != chosen:
                r["card"].setProperty("chosen", chosen)
                r["card"].style().unpolish(r["card"])
                r["card"].style().polish(r["card"])
            n = r["notes"]
            n["chosen"].setText(KEEPS_TEXT if on else ADJUSTED_TEXT)
            n["chosen"].setVisible(chosen)
            n["lined"].setVisible(on and k is not None)
            says = problem is not None and problem[0] == k
            n["problem"].setText(f"Can't export untouched: {problem[1]}. Turn off Keep original pixels for a gel to export."
                                 if says else "")
            n["problem"].setVisible(says)


class FigurePanel(Panel):
    FONTS = ["Arial", "Helvetica", "Helvetica Neue", "Avenir Next", "Myriad Pro", "Calibri", "Segoe UI", "Times New Roman"]

    def __init__(self, ws: Workspace):
        super().__init__(ws)
        self.add(section("Original image"))
        self.strict = QCheckBox("🔒  Keep original pixels")
        self.strict.setToolTip(KEEP_HELP)
        self.strict.toggled.connect(lambda v: ws.set_strict(v) if v != ws.active_strict else None)
        self.add(self.strict)
        self.strict_caption = label("", "caption")
        self.add(self.strict_caption)
        self.keep_rows = _KeepRows(ws)   # with several gels: every gel's own switch
        self.add(self.keep_rows)
        self.gap()
        self.gels = GelsSection(ws)
        self.add(self.gels)
        self.gap()
        # brightness & contrast
        self.bc_anchor = section("Brightness & Contrast")
        self.add(self.bc_anchor)
        self.hist = Histogram()
        self.add(self.hist)
        self.axis_lo, self.axis_hi = label("", "caption"), label("", "caption")
        self.add(hrow(self.axis_lo, "stretch", self.axis_hi))
        self.min_row = self._value_row("Minimum", lambda v, live: self._set_min(v, live))
        self.max_row = self._value_row("Maximum", lambda v, live: self._set_max(v, live))
        self.bright = DragSlider("Brightness", -1, 1, 0.01, "%+.2f",
                                 lambda v, live: ws.change_contrast(lambda d: d.set_brightness(v, self._data()), live),
                                 ws.end_contrast_change)
        self.contrast = DragSlider("Contrast", -1, 1, 0.01, "%+.2f",
                                   lambda v, live: ws.change_contrast(lambda d: d.set_contrast(v, self._data()), live),
                                   ws.end_contrast_change)
        self.add(self.bright, self.contrast)
        self.imagej = button("ImageJ", ws.use_imagej_range, tip="The display range ImageJ saved in this file")
        self.add(hrow(button("Auto", ws.auto_contrast, tip="The darkest 0.1% of the gel to black, the brightest 0.1% to white"),
                      button("Reset", ws.reset_contrast, tip="The image's own range"), self.imagej, "stretch"))
        self.gamma = DragSlider("Gamma", 0.3, 3, 0.01, "%.2f",
                                lambda v, live: ws.change_contrast(lambda d: setattr(d, "gamma", v), live),
                                ws.end_contrast_change)
        self.add(self.gamma)
        self.invert = QCheckBox("Invert")
        self.invert.toggled.connect(lambda v: ws.change_contrast(lambda d: setattr(d, "invert", v))
                                    if v != ws.active_display.invert else None)
        self.add(self.invert)
        self.enhance_note = hrow(label("Auto contrast from an earlier version is on.", "caption"), "stretch",
                                 button("Turn Off", lambda: ws.set_view_enhance(False)))
        self.add(self.enhance_note)
        self.bc_caption = label("", "caption")
        self.add(self.bc_caption)
        self.use_in_exports = button("Use in Exports…", ws.request_contrast_for_export,
                                     tip="Turns off Keep original pixels for this gel so exports show this range; each file records it")
        self.add(hrow(self.use_in_exports, "stretch"))
        self.gap()
        # rotate
        self.rotate_title = section("Rotate")
        self.add(self.rotate_title)
        self.reset_rot = button("Reset", lambda: ws.set_rotation(0))
        self.add(hrow(button("Straighten…", lambda: ws.set_tool("straighten")), "stretch", self.reset_rot))
        self.angle = QDoubleSpinBox()
        self.angle.setRange(-45, 45)
        self.angle.setSingleStep(0.1)
        self.angle.setDecimals(2)
        self.angle.setSuffix("°")
        self.angle.setToolTip("↑ ↓ turn 0.1°. Positive turns counter-clockwise.")
        self.angle.editingFinished.connect(lambda: ws.set_rotation(self.angle.value())
                                           if abs(self.angle.value() - ws.active_rotation) > 1e-9 else None)
        self.add(hrow(QLabel("Angle"), "stretch", self.angle))
        self.rot_caption = label("Off while this gel keeps its original pixels: rotating resamples it. Straighten asks "
                                 "before turning that off.", "caption")
        self.add(self.rot_caption)
        lossless = "Lossless; this gel's crop, ticks and names start over"
        self.add(hrow(QLabel("Turn"), "stretch",
                      button("⟲ 90°", lambda: ws.turn_active(3), tip="A quarter turn counter-clockwise. " + lossless),
                      button("180°", lambda: ws.turn_active(2),
                             tip="Half a turn, for a scan made upside down. Lossless; ticks and names turn with it"),
                      button("⟳ 90°", lambda: ws.turn_active(1), tip="A quarter turn clockwise. " + lossless)))
        self.gap()
        # fill
        self.add(section("Fill"))
        self.fill = Segmented([("background", "Match gel"), ("white", "White"), ("custom", "Custom")])
        self.fill.chosen.connect(lambda k: ws.set_fill(k))
        self.add(self.fill)
        self.fill_value = DragSlider("Gray", 0, 1, 0.01, "%.2f",
                                     lambda v, live: ws.live_fill(v) if live else ws.set_fill("custom", v),
                                     lambda: ws.end_gesture("Fill"))
        self.add(self.fill_value)
        self.measured = label("", "caption")
        self.add(self.measured)
        self.wedges = QCheckBox("Also paint the old gray wedges")
        self.wedges.toggled.connect(lambda v: ws.edit("Wedge Fill", lambda p: setattr(p, "fill_padding", v))
                                    if v != ws.project.fill_padding else None)
        self.add(self.wedges)
        self.add(label("Paints the corners a rotation uncovers. Detection always ignores them.", "caption"))
        self.bands_dark = QCheckBox("Bands are dark on light")
        self.bands_dark.setToolTip("Used for snapping and lining gels up only")
        self.bands_dark.toggled.connect(lambda v: ws.set_bands_dark(v) if v != ws.active_display.bands_dark else None)
        self.add(self.bands_dark)
        self.gap()
        # crop
        self.crop_title = section("Crop")
        self.add(self.crop_title)
        self.edit_crop = button("Edit Crop", lambda: ws.set_tool("crop"))
        self.fit_lanes = button("Fit to Lanes", ws.fit_crop_to_lanes)
        self.add(hrow(self.edit_crop, self.fit_lanes, button("Reset", ws.reset_crop), "stretch"))
        self.crop_caption = label("", "caption")
        self.add(self.crop_caption)
        self.gap()
        # font & layout
        self.add(section("Font"))
        self.font = narrow(QComboBox())
        fams = set(QFontDatabase.families())
        for f in self.FONTS:
            if f in fams:
                self.font.addItem(f)
        self.font.activated.connect(lambda i: ws.set_style("Font", lambda s: setattr(s, "font", self.font.itemText(i))))
        self.add(self.font)
        self.gap()
        self.add(section("Layout"))
        self.gel_width = DragSlider("Gel width", 1, 8, 0.1, "%.1f in",
                                    lambda v, live: self._style("gel_width_in", v, live), lambda: ws.end_gesture("Gel Width"))
        self.lines = DragSlider("Lines", 0.25, 2, 0.05, "%.2f pt",
                                lambda v, live: self._style("line_width_pt", v, live), lambda: ws.end_gesture("Line Width"))
        self.ticks = DragSlider("Ticks", 1, 8, 0.5, "%.1f pt",
                                lambda v, live: self._style("tick_len_pt", v, live), lambda: ws.end_gesture("Tick Length"))
        self.add(self.gel_width, self.lines, self.ticks)
        self.border = QCheckBox("Border around the gel")
        self.border.toggled.connect(lambda v: ws.set_style("Border", lambda s: setattr(s, "border", v))
                                    if v != ws.project.style.border else None)
        self.add(self.border)
        self.box.addStretch(1)

    def _style(self, key, v, live):
        if live:
            self.ws.live(lambda p: setattr(p.style, key, v))
        else:
            self.ws.set_style(key, lambda s: setattr(s, key, v))

    def _value_row(self, title, change):
        w = QWidget()
        r = QHBoxLayout(w)
        r.setContentsMargins(0, 0, 0, 0)
        t = QLabel(title)
        t.setFixedWidth(78)
        s = QSlider(Qt.Orientation.Horizontal)
        s.setRange(0, 1000)
        f = QDoubleSpinBox()
        f.setDecimals(0)
        f.setFixedWidth(84)
        f.setButtonSymbols(QDoubleSpinBox.ButtonSymbols.NoButtons)
        r.addWidget(t)
        r.addWidget(s, 1)
        r.addWidget(f)
        row = {"slider": s, "field": f, "axis": (0.0, 1.0), "setting": False, "shown": None}

        def moved(i):
            if row["setting"]:
                return
            a = row["axis"]
            change(a[0] + (a[1] - a[0]) * i / 1000, s.isSliderDown())

        def typed():
            # a field also finishes when you just click out of it: only a value you changed is an edit
            if row["shown"] is None or f.value() != row["shown"]:
                row["shown"] = f.value()
                change(f.value(), False)
        s.valueChanged.connect(moved)
        s.sliderReleased.connect(self.ws.end_contrast_change)
        f.editingFinished.connect(typed)
        self.box.addWidget(w)
        return row

    def _data(self):
        st = self.ws.gel_stats
        return st.range if st else (0.0, 1.0)

    def _set_min(self, v, live):
        s = self.ws.value_scale
        lo, hi = self.ws.active_display.range_in(s)   # the chosen gel's own range
        self.ws.change_contrast(lambda d: d.set_range(v, max(hi, v + 1 / s.max_value), s), live)

    def _set_max(self, v, live):
        s = self.ws.value_scale
        lo, hi = self.ws.active_display.range_in(s)
        self.ws.change_contrast(lambda d: d.set_range(min(lo, v - 1 / s.max_value), v, s), live)

    def refresh(self):
        ws, p = self.ws, self.ws.project
        self.gels.refresh()
        gel = f" · {ws.active_name}" if p.strips else ""
        strict = ws.active_strict   # the chosen gel's own setting
        for w in (self.strict, self.strict_caption):   # one gel: the one switch; several: a row for each
            w.setVisible(not p.strips)
        self.keep_rows.setVisible(bool(p.strips))
        if p.strips:
            self.keep_rows.refresh()
        self.bc_anchor.setText(("Brightness & Contrast" + gel).upper())
        self.rotate_title.setText(("Rotate" + gel).upper())
        self.crop_title.setText(("Crop" + gel).upper())
        for cb, v in ((self.strict, strict), (self.invert, ws.active_display.invert), (self.wedges, p.fill_padding),
                      (self.bands_dark, ws.active_display.bands_dark), (self.border, p.style.border)):
            cb.blockSignals(True)
            cb.setChecked(v)
            cb.blockSignals(False)
        self.strict_caption.setText(KEEPS_TEXT if strict else ADJUSTED_TEXT)
        st, s, d = ws.gel_stats, ws.value_scale, ws.active_display
        if st is not None:
            a, z = s.value(st.range[0]), s.value(st.range[1])
            lo, hi = min(a, z), max(a, z)
            rmin, rmax = d.range_in(s)
            axis = (min(lo, rmin), max(hi, rmax, min(lo, rmin) + 1 / s.max_value))
            if self.min_row["slider"].isSliderDown() or self.max_row["slider"].isSliderDown():
                axis = self.min_row["axis"]   # the scale holds still while a handle is dragged, or the value runs ahead of it
            counts = list(reversed(st.counts)) if s.inverted else list(st.counts)
            self.hist.set(counts, (lo, hi), axis, d, s)
            self.axis_lo.setText(s.format(axis[0]))
            self.axis_hi.setText(s.format(axis[1]))
            for row, v in ((self.min_row, rmin), (self.max_row, rmax)):
                row["axis"] = axis
                row["setting"] = True
                if not row["slider"].isSliderDown():
                    row["slider"].setValue(int(round((v - axis[0]) / max(axis[1] - axis[0], 1e-9) * 1000)))
                row["setting"] = False
                f = row["field"]
                f.blockSignals(True)
                f.setRange(-1e9, 1e9)
                f.setDecimals(0 if s.max_value > 1 else 3)
                if not f.hasFocus():
                    f.setValue(v)
                    row["shown"] = f.value()
                f.blockSignals(False)
            data = st.range
            self.bright.set(d.brightness(data))
            self.contrast.set(d.contrast(data))
        self.gamma.set(d.gamma)
        ij = ws.imagej_range
        self.imagej.setVisible(ij is not None)
        if ij:
            self.imagej.setText(f"ImageJ {s.format(ij[0])}–{s.format(ij[1])}")
        self.enhance_note.setVisible(p.view_enhance and ws.active_strip is None)
        self.bc_caption.setText("On screen only, like ImageJ before Apply: exports keep the original values." if strict
                                else f"Exports use this range (display range {ws.display_range_text()}), and each file "
                                     "records it.")
        self.use_in_exports.setVisible(strict)
        self.use_in_exports.setEnabled(not d.is_identity)
        self.angle.blockSignals(True)
        if not self.angle.hasFocus():
            self.angle.setValue(0 if strict else ws.active_rotation)
        self.angle.blockSignals(False)
        self.angle.setEnabled(not strict)
        self.reset_rot.setEnabled(not strict and ws.active_rotation != 0)
        self.rot_caption.setVisible(strict)
        self.fill.set(p.fill_mode)
        self.fill_value.setVisible(p.fill_mode == "custom")
        self.fill_value.set(p.fill_value)
        for w in (self.fill, self.fill_value, self.wedges):
            w.setEnabled(not strict)
        self.measured.setText(f"Measured gel background ({ws.measured_background} of 255)")
        r = ws.active_strip_rect
        self.fit_lanes.setVisible(ws.active_strip is None)
        if r is not None:
            k = ws.active_strip
            own = p.strips[k - 1].left is not None or p.strips[k - 1].right is not None
            self.crop_caption.setText(f"Columns {int(r.x0)}–{int(r.x1)}, rows {int(r.y0)}–{int(r.y1)} of "
                                      f"{ws.active_size[0]} × {ws.active_size[1]} px."
                                      + ("" if own else f" The columns follow {ws.gel_name(None)}'s crop and the lining up."))
        elif ws.active_strip is not None:
            self.crop_caption.setText("This gel's image can't be read.")
        else:
            c = ws.crop
            self.crop_caption.setText(f"{int(c.width):,} × {int(c.height):,} px from ({int(c.x0)}, {int(c.y0)})")
        i = self.font.findText(p.style.font)
        if i >= 0:
            self.font.setCurrentIndex(i)
        self.gel_width.set(p.style.gel_width_in)
        self.lines.set(p.style.line_width_pt)
        self.ticks.set(p.style.tick_len_pt)


# ---------------------------------------------------------------------------------------------------- export


FILE_NAMES_HELP = "File names can identify samples or people. The SHA-256 fingerprints stay either way."


class ExportPanel(Panel):
    def __init__(self, ws: Workspace):
        super().__init__(ws)
        self.add(section("Export"))
        self.rows = {}
        for fmt in ("pdf", "tiff", "png", "svg"):
            b = QPushButton()
            b.setStyleSheet("text-align: left; padding: 9px 12px;")
            b.clicked.connect(lambda _=False, f=fmt: self.window().export(f))
            self.rows[fmt] = b
            self.add(b)
        self.add(button("Copy Figure", lambda: self.window().copy_figure(), tip="PDF and PNG on the clipboard"))
        self.gap()
        self.add(section("Provenance"))
        self.names = QCheckBox("Include file names in exported files")
        self.names.setToolTip(FILE_NAMES_HELP)
        self.names.toggled.connect(lambda v: ws.set_export_file_names(v) if v != ws.project.export_file_names else None)
        self.add(self.names)
        self.add(label(FILE_NAMES_HELP, "caption"))
        self.prov = QLabel()
        self.prov.setWordWrap(True)
        self.prov.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.prov.setFont(QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont))
        self.prov.setObjectName("prov")
        self.add(self.prov)
        self.intact = QLabel()
        self.add(self.intact)
        self.box.addStretch(1)

    def refresh(self):
        ws = self.ws
        if ws.layout is None:
            return
        r = ws.resampled_export_dpi
        n = ws.native_dpi
        details = {"pdf": "Vector text, gel embedded losslessly",
                   "tiff": f"{int(r)} dpi, LZW, gel resampled" if r else f"Native {n} dpi, LZW, gel pixels 1:1",
                   "png": f"{int(r)} dpi, gel resampled" if r else f"Native {n} dpi, gel pixels 1:1",
                   "svg": "Editable text, gel as lossless PNG"}
        for fmt, b in self.rows.items():
            b.setText(f"{fmt.upper():<6}  {details[fmt]}")
        self.names.setChecked(ws.project.export_file_names)
        try:
            self.prov.setText(breakable(ws.export_info().description))
        except ImageError as e:   # a gel whose image can't be read: there's no figure to describe
            self.prov.setText(str(e))
        gels = ws.gels_intact()
        checks = [(n, ok) for n, ok in gels if ok is not None]
        bad = [n for n, ok in checks if not ok]
        if not checks:
            text = ""
        elif len(gels) == 1:
            text = "✔  Image matches its import fingerprint" if not bad else "⚠  Image does not match its import fingerprint"
        else:
            text = ("✔  Every image matches its import fingerprint" if not bad else
                    f"⚠  {', '.join(bad)} {'does' if len(bad) == 1 else 'do'} not match the import fingerprint")
        self.intact.setText(text)
        self.intact.setStyleSheet(f"color: {theme.C['ok'] if not bad else theme.C['warn']};")


# ---------------------------------------------------------------------------------------------------- the inspector


class Inspector(QFrame):
    def __init__(self, ws: Workspace):
        super().__init__()
        self.ws = ws
        self.setObjectName("inspector")
        self.setFixedWidth(340)
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 8, 0, 0)
        v.setSpacing(4)
        tabs = QHBoxLayout()
        tabs.setContentsMargins(10, 0, 10, 4)
        tabs.setSpacing(4)
        self.tab_buttons = {}
        for key, title in TABS:
            b = button(title, lambda _=False, k=key: ws.choose_tab(k))
            b.setCheckable(True)
            self.tab_buttons[key] = b
            tabs.addWidget(b)
        v.addLayout(tabs)
        line = QFrame()
        line.setFixedHeight(1)
        line.setObjectName("rule")
        v.addWidget(line)
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        v.addWidget(self.scroll, 1)
        self.panels = {"labels": LabelsPanel(ws), "ladder": LadderPanel(ws), "names": NamesPanel(ws),
                       "figure": FigurePanel(ws), "export": ExportPanel(ws)}
        self.holder = QWidget()
        hv = QVBoxLayout(self.holder)
        hv.setContentsMargins(0, 0, 0, 0)
        for p in self.panels.values():
            hv.addWidget(p)
        self.scroll.setWidget(self.holder)
        self._current = None
        ws.changed.connect(self.refresh)
        ws.view_changed.connect(self.refresh)
        ws.reveal_contrast.connect(self._reveal_contrast)
        self.refresh()

    def refresh(self):
        tab = self.ws.inspector_tab
        if tab != self._current:
            self._current = tab
            for k, p in self.panels.items():
                p.setVisible(k == tab)
            self.scroll.verticalScrollBar().setValue(0)
        for k, b in self.tab_buttons.items():
            b.setChecked(k == tab)
        if self.ws.has_image:
            self.panels[tab].refresh()

    def _reveal_contrast(self):
        anchor = self.panels["figure"].bc_anchor
        QTimer.singleShot(50, lambda: self.scroll.ensureWidgetVisible(anchor, 0, 0) or
                          self.scroll.verticalScrollBar().setValue(anchor.y()))
