"""The small editors that open when you click a label, a ladder number or a band name, and the controls they share."""
from __future__ import annotations

from typing import Callable, Optional

from PySide6.QtCore import QPoint, QRect, QSize, Qt, Signal
from PySide6.QtGui import QFontMetrics, QKeyEvent
from PySide6.QtWidgets import (QDoubleSpinBox, QFrame, QHBoxLayout, QLabel, QLayout, QLineEdit, QMenu,
                               QPlainTextEdit, QPushButton, QSizePolicy, QVBoxLayout, QWidget)

from ..core.model import format_size

EDITOR_WIDTH = 270


def text_width(w: QWidget, *samples: str, pad: int = 0) -> int:
    """The widest of the sample texts in this widget's font (the app's font size and scale, not a guess in pixels) plus
    padding. Sizes made from this follow Segoe UI at 150%, bigger fonts and every platform's own widths."""
    w.ensurePolished()   # the stylesheet's font size applies at polish time
    fm = QFontMetrics(w.font())
    return max((fm.horizontalAdvance(t) for t in samples), default=0) + pad


def fit_width(w: QWidget, *samples: str, floor: int = 0, chrome: int = 16) -> QWidget:
    """A field just wide enough for its widest real value: the samples, or the floor in pixels if that is more.
    `chrome` is the field's own padding and border (the stylesheet's 6 px each side plus the border)."""
    w.setFixedWidth(max(floor, text_width(w, *samples, pad=chrome)))
    return w


class _Fit:
    """Spin boxes size themselves for the widest number their range allows, so a huge range pushes the value out of
    sight (the Minimum field on Windows). These size for the widest value they really show: the sample texts and the
    current text, whatever the range."""
    samples: tuple = ()

    def _fitted(self, hint: QSize) -> QSize:
        le = self.lineEdit()
        shown = self.prefix() + le.text() + self.suffix() if le is not None else ""
        extra = hint.width() - self._natural_text_width()
        widest = text_width(self, shown, *self.samples) + 6
        return QSize(max(extra + widest, 0), hint.height())

    def _natural_text_width(self) -> int:
        self.ensurePolished()
        fm = QFontMetrics(self.font())
        w = 0
        for v in (self.minimum(), self.maximum()):
            t = self.textFromValue(v)[:18] + self.prefix() + self.suffix() + " "
            w = max(w, fm.horizontalAdvance(t))
        return w

    def sizeHint(self) -> QSize:
        return self._fitted(super().sizeHint())

    def minimumSizeHint(self) -> QSize:
        return self._fitted(super().minimumSizeHint())


class FitDoubleSpinBox(_Fit, QDoubleSpinBox):
    pass


class ElidedButton(QPushButton):
    """A button whose one line of text gives way (…) instead of widening the panel or being cut off at the edge. The whole
    text is the tooltip."""

    def __init__(self, text: str = "", inset: int = 24):
        super().__init__()
        self._full, self._inset = "", inset
        self.setSizePolicy(QSizePolicy.Policy.Preferred, QSizePolicy.Policy.Fixed)   # its hint is a wish, not a minimum
        self.setText(text)

    def setText(self, text: str):
        self._full = text
        self._elide()

    def fullText(self) -> str:
        return self._full

    def _elide(self):
        avail = max(self.width() - self._inset - 4, 20) if self.width() > 40 else 10 ** 6
        shown = QFontMetrics(self.font()).elidedText(self._full, Qt.TextElideMode.ElideRight, avail)
        QPushButton.setText(self, shown)
        self.setToolTip(self._full if shown != self._full else "")

    def resizeEvent(self, e):
        super().resizeEvent(e)
        self._elide()

    def minimumSizeHint(self) -> QSize:
        return QSize(40, super().minimumSizeHint().height())


def label(text: str, kind: str = "") -> QLabel:
    l = QLabel(text)
    if kind:
        l.setProperty(kind, True)
    l.setWordWrap(kind in ("caption", "warn"))
    return l


def button(text: str, on: Optional[Callable] = None, kind: str = "", tip: str = "") -> QPushButton:
    b = QPushButton(text)
    if kind:
        b.setProperty(kind, True)
    if on:
        b.clicked.connect(on)
    if tip:
        b.setToolTip(tip)
    b.setCursor(Qt.CursorShape.PointingHandCursor)
    return b


class FlowLayout(QLayout):
    """Wraps its items like words in a line (recent names, ladder sizes)."""

    def __init__(self, parent=None, spacing: int = 6):
        super().__init__(parent)
        self._items = []
        self._spacing = spacing
        self.setContentsMargins(0, 0, 0, 0)

    def addItem(self, item):
        self._items.append(item)

    def count(self):
        return len(self._items)

    def itemAt(self, i):
        return self._items[i] if 0 <= i < len(self._items) else None

    def takeAt(self, i):
        return self._items.pop(i) if 0 <= i < len(self._items) else None

    def hasHeightForWidth(self):
        return True

    def heightForWidth(self, w):
        return self._place(QRect(0, 0, w, 0), dry=True)

    def setGeometry(self, rect):
        super().setGeometry(rect)
        self._place(rect, dry=False)

    def sizeHint(self):
        return self.minimumSize()

    def minimumSize(self):
        s = QSize()
        for it in self._items:
            s = s.expandedTo(it.minimumSize())
        return s

    def _place(self, rect, dry):
        x, y, line = rect.x(), rect.y(), 0
        for it in self._items:
            sz = it.sizeHint()
            if x + sz.width() > rect.right() and line > 0:
                x, y, line = rect.x(), y + line + self._spacing, 0
            if not dry:
                it.setGeometry(QRect(QPoint(x, y), sz))
            x += sz.width() + self._spacing
            line = max(line, sz.height())
        return y + line - rect.y()


class LabelField(QPlainTextEdit):
    """A label's text. Enter finishes; Ctrl+Enter (or Alt+Enter) puts a line break in the label. Grows a line at a
    time."""
    submitted = Signal()

    def __init__(self, text: str = "", placeholder: str = ""):
        super().__init__()
        self.setPlainText(text)
        self.setPlaceholderText(placeholder)
        self.setTabChangesFocus(True)
        self.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setLineWrapMode(QPlainTextEdit.LineWrapMode.WidgetWidth)
        self.setToolTip("Enter to finish · Ctrl+Enter starts a new line")
        self.textChanged.connect(self._fit)
        self._fit()

    def _fit(self):
        lines = max(1, self.document().blockCount())
        lh = self.fontMetrics().lineSpacing()
        self.setFixedHeight(min(6, lines) * lh + 14)

    def keyPressEvent(self, e: QKeyEvent):
        if e.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter):
            if e.modifiers() & (Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.AltModifier
                                | Qt.KeyboardModifier.MetaModifier | Qt.KeyboardModifier.ShiftModifier):
                self.insertPlainText("\n")
            else:
                self.submitted.emit()
            return
        super().keyPressEvent(e)

    def focus_all(self):
        self.setFocus()
        self.selectAll()

    def text(self) -> str:
        return self.toPlainText()


class SizeStepper(QWidget):
    """"− 7 pt +" in one box: half-point steps, typing allowed."""
    changed = Signal(float)

    def __init__(self, value: float):
        super().__init__()
        self.value = value
        row = QHBoxLayout(self)
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(2)
        self.minus = button("−", lambda: self._set(self.value - 0.5))
        self.plus = button("+", lambda: self._set(self.value + 0.5))
        self.field = QLineEdit(format_size(value))
        fit_width(self.field, "100.5", floor=46)
        self.field.setAlignment(Qt.AlignmentFlag.AlignRight)
        self.field.editingFinished.connect(self._typed)
        for b in (self.minus, self.plus):
            b.setFixedWidth(28)
        row.addWidget(self.minus)
        row.addWidget(self.field)
        row.addWidget(QLabel("pt"))
        row.addWidget(self.plus)

    def _typed(self):
        try:
            self._set(float(self.field.text().replace(",", ".")))
        except ValueError:
            self.field.setText(format_size(self.value))

    def _set(self, v: float):
        v = min(max(round(v * 2) / 2, 3), 48)
        self.value = v
        self.field.setText(format_size(v))
        self.changed.emit(v)

    def set_value(self, v: float):
        self.value = v
        if not self.field.hasFocus():
            self.field.setText(format_size(v))


class Popup(QFrame):
    """A small editor floating next to what was clicked; closes when you click elsewhere or press Esc."""

    def __init__(self, parent: QWidget, title: str):
        super().__init__(parent, Qt.WindowType.Popup | Qt.WindowType.FramelessWindowHint)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.setObjectName("popup")
        self.setFixedWidth(EDITOR_WIDTH + 32)
        self.box = QVBoxLayout(self)
        self.box.setContentsMargins(16, 14, 16, 14)
        self.box.setSpacing(10)
        t = QLabel(title)
        t.setStyleSheet("font-weight: 700; font-size: 14px;")
        self.box.addWidget(t)

    def show_at(self, global_pos: QPoint):
        self.adjustSize()
        self._place(global_pos.x(), global_pos.y())

    def show_beside(self, anchor: QPoint, to_right: bool):
        """Level with the anchor and to its right (or left), for when what's below must stay clickable."""
        self.adjustSize()
        self._place(anchor.x() if to_right else anchor.x() - self.width(), anchor.y() - self.height() // 2)

    def _place(self, x: int, y: int):
        screen = self.screen().availableGeometry() if self.screen() else None
        if screen is not None:
            x = min(max(screen.left() + 4, x), screen.right() - self.width() - 4)
            y = min(max(screen.top() + 4, y), screen.bottom() - self.height() - 4)
        self.move(x, y)
        self.show()

    def keyPressEvent(self, e):
        if e.key() == Qt.Key.Key_Escape:
            self.close()
            return
        super().keyPressEvent(e)


def size_row(stepper: SizeStepper) -> QWidget:
    w = QWidget()
    r = QHBoxLayout(w)
    r.setContentsMargins(0, 0, 0, 0)
    r.addWidget(label("Size", "caption"))
    r.addStretch(1)
    r.addWidget(stepper)
    return w


class TickEditor(Popup):
    """Band size for a ladder tick: type it or pick one of the ladder's sizes."""

    def __init__(self, parent, initial: Optional[float], guess: bool, suggestion: Optional[float], sizes: list[float],
                 unit: str, on_commit: Callable[[Optional[float]], None], on_skip: Callable[[], None],
                 on_delete: Callable[[], None]):
        super().__init__(parent, "Band size")
        self.on_commit = on_commit
        value = initial if initial is not None else suggestion
        row = QHBoxLayout()
        self.field = QLineEdit(format_size(value) if value is not None else "")
        fit_width(self.field, "10000.5", floor=110)
        self.field.returnPressed.connect(self._commit)
        row.addWidget(self.field)
        row.addWidget(label(unit, "caption"))
        row.addStretch(1)
        self.box.addLayout(row)
        if guess:
            self.box.addWidget(label("A guess from the ladder's list: confirm it or pick another.", "caption"))
        chips = QWidget()
        flow = FlowLayout(chips)
        for s in sizes:
            b = button(format_size(s), lambda _=False, s=s: self._pick(s), "chip")
            b.setCheckable(True)
            b.setChecked(value is not None and abs(s - value) < 1e-9)
            flow.addWidget(b)
        self.box.addWidget(chips)
        bottom = QHBoxLayout()
        bottom.addWidget(button("Not a ladder band", lambda: (on_skip(), self.close()), "link",
                                "A click that landed on something else: it keeps no size"))
        bottom.addStretch(1)
        bottom.addWidget(button("🗑", lambda: (on_delete(), self.close()), "danger", "Delete this tick"))
        done = button("Done", self._commit, "primary")
        done.setDefault(True)
        bottom.addWidget(done)
        self.box.addLayout(bottom)

    def showEvent(self, e):
        super().showEvent(e)
        self.field.setFocus()
        self.field.selectAll()

    def _pick(self, s: float):
        self.on_commit(s)
        self.close()

    def _commit(self):
        t = self.field.text().strip().replace(",", ".")
        try:
            v = float(t) if t else None
        except ValueError:
            return
        self.on_commit(v)
        self.close()


class NameEditor(Popup):
    """A band name: its text, marker, size and your recent names."""

    MARKERS = [("arrow", "Arrow"), ("tick", "Tick"), ("bracket", "Bracket"), ("none", "Text")]

    def __init__(self, parent, text: str, marker: str, size: float, recent: list[str],
                 on_commit: Callable[[str, str], None], on_size: Callable[[float], None], on_delete: Callable[[], None],
                 on_forget: Callable[[str], None]):
        super().__init__(parent, "Band name")
        self.on_commit = on_commit
        self.marker = marker
        self.field = LabelField(text, "Name")
        self.field.submitted.connect(self._commit)
        self.box.addWidget(self.field)
        seg = QHBoxLayout()
        seg.setSpacing(2)
        self.marker_buttons = {}
        for key, title in self.MARKERS:
            b = button(title, lambda _=False, k=key: self._marker(k))
            b.setCheckable(True)
            b.setChecked(key == marker)
            self.marker_buttons[key] = b
            seg.addWidget(b)
        self.box.addLayout(seg)
        stepper = SizeStepper(size)
        stepper.changed.connect(on_size)
        self.box.addWidget(size_row(stepper))
        if recent:
            self.box.addWidget(label("Recent", "caption"))
            chips = QWidget()
            flow = FlowLayout(chips)
            for name in recent:
                b = button(name, lambda _=False, n=name: self._recent(n), "chip",
                           "Right-click to remove it from the recent names")
                b.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
                b.customContextMenuRequested.connect(lambda _p, b=b, n=name: self._forget_menu(b, n, on_forget))
                flow.addWidget(b)
            self.box.addWidget(chips)
        bottom = QHBoxLayout()
        bottom.addWidget(button("🗑  Delete", lambda: (on_delete(), self.close()), "danger"))
        bottom.addStretch(1)
        done = button("Done", self._commit, "primary")
        bottom.addWidget(done)
        self.box.addLayout(bottom)

    def showEvent(self, e):
        super().showEvent(e)
        self.field.focus_all()

    def _marker(self, k):
        self.marker = k
        for key, b in self.marker_buttons.items():
            b.setChecked(key == k)

    def _recent(self, name):
        self.on_commit(name, self.marker)
        self.close()

    def _forget_menu(self, b, name, on_forget):
        m = QMenu(self)
        m.addAction("Remove from Recent Names", lambda: (on_forget(name), b.hide()))
        m.exec(b.mapToGlobal(QPoint(0, b.height())))

    def _commit(self):
        self.on_commit(self.field.text(), self.marker)
        self.close()


class TextEditor(Popup):
    """A title, row title, group or lane label: its text and size."""

    def __init__(self, parent, title: str, text: str, size: float, scope: str, on_commit: Callable[[str], None],
                 on_size: Callable[[float], None]):
        super().__init__(parent, title)
        self.on_commit = on_commit
        self.field = LabelField(text)
        self.field.submitted.connect(self._commit)
        self.box.addWidget(self.field)
        stepper = SizeStepper(size)
        stepper.changed.connect(on_size)
        self.box.addWidget(size_row(stepper))
        self.box.addWidget(label(f"The size changes {scope}. Ctrl+Enter starts a new line.", "caption"))
        bottom = QHBoxLayout()
        bottom.addStretch(1)
        bottom.addWidget(button("Done", self._commit, "primary"))
        self.box.addLayout(bottom)

    def showEvent(self, e):
        super().showEvent(e)
        self.field.focus_all()

    def _commit(self):
        self.on_commit(self.field.text())
        self.close()
