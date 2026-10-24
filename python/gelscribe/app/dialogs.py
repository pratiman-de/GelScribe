"""Message boxes in the app's look: the app icon on the left, a bold question over a dim explanation, and a right-aligned
row of buttons whose primary (the Enter key) is filled with the accent. Esc is the cancel button. The colors come from
theme.py's stylesheet, so a dialog follows dark and light like every window."""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Optional, Sequence

from PySide6.QtCore import Qt
from PySide6.QtGui import QPixmap
from PySide6.QtWidgets import QDialog, QHBoxLayout, QLabel, QPushButton, QVBoxLayout, QWidget

RESOURCES = Path(__file__).parent / "resources"
TEXT_WIDTH = 340


def _icon_path() -> Path:
    base = Path(getattr(sys, "_MEIPASS", ""), "gelscribe", "app", "resources") if hasattr(sys, "_MEIPASS") else RESOURCES
    p = base / "icon.png"
    return p if p.exists() else RESOURCES / "icon.png"


def _pixmap(size: int, ratio: float) -> QPixmap:
    px = QPixmap(str(_icon_path()))
    if px.isNull():
        return px
    px = px.scaled(round(size * ratio), round(size * ratio), Qt.AspectRatioMode.KeepAspectRatio,
                   Qt.TransformationMode.SmoothTransformation)
    px.setDevicePixelRatio(ratio)
    return px


class MessageDialog(QDialog):
    """heading (bold), detail (dim) and buttons, given as labels left to right. `primary` is the index of the filled,
    default button; `cancel` the one Esc and the close button stand for (default: the last button). `destructive`
    makes the primary red. Read the answer from clicked_label() (None until a button was used)."""

    def __init__(self, parent: Optional[QWidget], heading: str, detail: str = "", buttons: Sequence[str] = ("OK",),
                 *, title: str = "GelScribe", primary: int = 0, cancel: Optional[int] = None,
                 destructive: bool = False, rich: bool = False, icon_size: int = 40):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.setWindowFlag(Qt.WindowType.WindowContextHelpButtonHint, False)
        self.setModal(True)
        self._heading, self._detail = heading, detail
        self._clicked: Optional[QPushButton] = None
        self._buttons: list[QPushButton] = []

        root = QVBoxLayout(self)
        root.setContentsMargins(20, 20, 20, 20)
        root.setSpacing(20)
        row = QHBoxLayout()
        row.setSpacing(16)
        icon = QLabel()
        icon.setPixmap(_pixmap(icon_size, self.devicePixelRatioF()))
        icon.setFixedSize(icon_size, icon_size)
        row.addWidget(icon, 0, Qt.AlignmentFlag.AlignTop)
        text = QVBoxLayout()
        text.setSpacing(6)
        head = QLabel(heading)
        head.setObjectName("msgHeading")
        head.setTextFormat(Qt.TextFormat.PlainText)
        text.addWidget(head)
        for lab in [head] + ([self._label(detail, rich)] if detail else []):
            lab.setWordWrap(True)
            lab.setFixedWidth(TEXT_WIDTH)
            if lab is not head:
                text.addWidget(lab)
        text.addStretch(1)
        row.addLayout(text, 1)
        root.addLayout(row)

        bar = QHBoxLayout()
        bar.setSpacing(8)
        bar.addStretch(1)
        for i, label in enumerate(buttons):
            b = QPushButton(label)
            b.setProperty("dialog", True)
            b.setProperty("primary", i == primary)
            b.setProperty("destructive", destructive and i == primary)
            b.setAutoDefault(False)
            b.setDefault(i == primary)
            b.clicked.connect(lambda _=False, b=b: self._use(b))
            self._buttons.append(b)
            bar.addWidget(b)
        root.addLayout(bar)
        self._cancel = self._buttons[len(buttons) - 1 if cancel is None else cancel]
        self.setSizeGripEnabled(False)
        root.setSizeConstraint(QVBoxLayout.SizeConstraint.SetFixedSize)
        if 0 <= primary < len(self._buttons):
            self._buttons[primary].setFocus()

    def _label(self, text: str, rich: bool) -> QLabel:
        lab = QLabel(text)
        lab.setObjectName("msgDetail")
        if rich:
            lab.setTextFormat(Qt.TextFormat.RichText)
            lab.setOpenExternalLinks(True)
        else:
            lab.setTextFormat(Qt.TextFormat.PlainText)
        return lab

    # what QMessageBox offered, for the tests and the callers
    def text(self) -> str:
        return self._heading

    def informativeText(self) -> str:
        return self._detail

    def buttons(self) -> list[QPushButton]:
        return list(self._buttons)

    def clickedButton(self) -> Optional[QPushButton]:
        return self._clicked

    def clicked_label(self) -> Optional[str]:
        return self._clicked.text() if self._clicked is not None else None

    def _use(self, b: QPushButton):
        self._clicked = b
        self.done(QDialog.DialogCode.Accepted if b is not self._cancel else QDialog.DialogCode.Rejected)

    def reject(self):   # Esc, or the window's close button
        if self._clicked is None:
            self._clicked = self._cancel
        super().reject()


def ask(parent: Optional[QWidget], heading: str, detail: str = "", buttons: Sequence[str] = ("OK",), **kw) -> str:
    """Shows the dialog and waits; returns the label of the button used (the cancel button's for Esc)."""
    box = MessageDialog(parent, heading, detail, buttons, **kw)
    box.exec()
    return box.clicked_label() or buttons[-1]


def warn(parent: Optional[QWidget], text: str, title: str = "GelScribe") -> None:
    """A problem to read and dismiss: the first paragraph is the heading, the rest the explanation."""
    heading, _, detail = text.partition("\n\n")
    ask(parent, heading, detail, ("OK",), title=title)
