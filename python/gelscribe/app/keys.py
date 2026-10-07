"""Keyboard shortcuts you can change in Edit › Settings… › Shortcuts: the commands, defaults and rules of the Mac app.
Tools are single keys that work anywhere in the window except while you type in a field; commands need Ctrl, so typing
never sets them off (Alt alone opens Windows menus). Changes are saved in GelScribe.ini."""
from __future__ import annotations

import json
import sys
from typing import Callable, Optional

from PySide6.QtCore import QEvent, QKeyCombination, QObject, Qt, Signal
from PySide6.QtGui import QKeyEvent, QKeySequence
from PySide6.QtWidgets import (QDialog, QFrame, QGridLayout, QHBoxLayout, QLabel, QLineEdit, QPlainTextEdit,
                               QPushButton, QScrollArea, QTabWidget, QTextEdit, QVBoxLayout, QWidget)

from . import settings
from .editors import button, label
from .workspace import TOOLS

TOOLS_SECTION = "Tools (a single key, anywhere except while typing)"
#: id, title, section, default ("" for none). Text sizes and zoom use the keys Qt reports on Windows: Ctrl+Shift+=
#: arrives as Ctrl+Shift++ and Ctrl+Shift+- as Ctrl+Shift+_.
DEFS: list[tuple[str, str, str, str]] = [
    *[("tool:" + tid, title, TOOLS_SECTION, key) for tid, title, key, _hint in TOOLS],
    ("exportPDF", "Export PDF…", "Export", "Ctrl+E"),
    ("exportTIFF", "Export TIFF…", "Export", ""),
    ("exportPNG", "Export PNG…", "Export", ""),
    ("exportSVG", "Export SVG…", "Export", ""),
    ("copyFigure", "Copy Figure", "Export", "Ctrl+Shift+C"),
    ("newGelWithLabels", "New Gel with These Labels…", "Labels", "Ctrl+Shift+N"),
    ("copyLabels", "Copy Labels", "Labels", "Ctrl+Alt+C"),
    ("pasteLabels", "Paste Labels", "Labels", "Ctrl+Alt+V"),
    ("pasteLabelsAndPositions", "Paste Labels and Positions", "Labels", "Ctrl+Alt+Shift+V"),
    ("biggerText", "Bigger Text", "Text", "Ctrl+Shift++"),
    ("smallerText", "Smaller Text", "Text", "Ctrl+Shift+_"),
    ("zoomFit", "Zoom to Fit", "View", "Ctrl+0"),
    ("zoomActual", "Actual Pixels", "View", "Ctrl+1"),
    ("zoomIn", "Zoom In", "View", "Ctrl+="),
    ("zoomOut", "Zoom Out", "View", "Ctrl+-"),
    ("toggleGuides", "Show or Hide Guides", "View", "Ctrl+'"),
    ("toggleInspector", "Show or Hide Inspector", "View", "Ctrl+Alt+I"),
    ("brightnessContrast", "Brightness & Contrast…", "View", "Ctrl+Shift+B"),
]
TITLE = {d[0]: d[1] for d in DEFS}

#: Keys the menus and text fields already use; a second command on them would never run.
RESERVED = {"Ctrl+N": "New", "Ctrl+O": "Open…", "Ctrl+W": "Close", "Ctrl+S": "Save", "Ctrl+Shift+S": "Save As…",
            "Ctrl+Q": "Exit", "Ctrl+Z": "Undo", "Ctrl+Y": "Redo", "Ctrl+Shift+Z": "Redo", "Ctrl+X": "Cut",
            "Ctrl+C": "Copy", "Ctrl+V": "Paste", "Ctrl+A": "Select All", "Ctrl+,": "Settings…"}


def normal(text: str) -> str:
    """One spelling per key combination: "ctrl+e" → "Ctrl+E"."""
    return QKeySequence(text).toString(QKeySequence.SequenceFormat.PortableText) if text else ""


def shown(text: str) -> str:
    return QKeySequence(text).toString(QKeySequence.SequenceFormat.NativeText) if text else ""


DEFAULT = {d[0]: normal(d[3]) for d in DEFS}
RESERVED = {normal(k): v for k, v in RESERVED.items()}


class KeyStore(QObject):
    """The shortcuts in use: the defaults, with the user's changes on top ("" means none)."""
    changed = Signal()

    def __init__(self):
        super().__init__()
        try:
            loaded = json.loads(str(settings().value("shortcuts", "{}", type=str) or "{}"))
            self._changes = {k: normal(v) for k, v in loaded.items() if k in DEFAULT}
        except (ValueError, TypeError, AttributeError):
            self._changes = {}

    def text(self, sid: str) -> str:
        return self._changes.get(sid, DEFAULT[sid])

    def sequence(self, sid: str) -> QKeySequence:
        return QKeySequence(self.text(sid))

    def shown(self, sid: str) -> str:
        return shown(self.text(sid))

    def is_changed(self, sid: str) -> bool:
        return sid in self._changes

    @property
    def any_changed(self) -> bool:
        return bool(self._changes)

    def set(self, sid: str, text: str) -> Optional[str]:
        """Sets a shortcut; another command that had the same keys loses them. Returns that command, if any."""
        text = normal(text)
        displaced = None
        if text:
            for other in DEFAULT:
                if other != sid and self.text(other) == text:
                    self._changes[other] = ""
                    displaced = other
        if text == DEFAULT[sid]:
            self._changes.pop(sid, None)
        else:
            self._changes[sid] = text
        if displaced is not None and DEFAULT[displaced] == "":
            self._changes.pop(displaced, None)   # "none" is its default anyway
        self._save()
        return displaced

    def reset(self, sid: str) -> None:
        self._changes.pop(sid, None)
        self._save()

    def reset_all(self) -> None:
        self._changes = {}
        self._save()

    def _save(self) -> None:
        settings().setValue("shortcuts", json.dumps(self._changes, sort_keys=True))
        self.changed.emit()


_store: Optional[KeyStore] = None


def store() -> KeyStore:
    global _store
    if _store is None:
        _store = KeyStore()
    return _store


class AltGrGuard(QObject):
    """Windows reports AltGr as Ctrl+Alt, so on a Czech, Polish or Hungarian keyboard the key that types @ or & looks like
    Ctrl+Alt+V or Ctrl+Alt+C, and the menu command that has those keys would run instead of the field getting its
    character. While a text field has the focus, a Ctrl+Alt key that produces a printable character is the field's: it is
    accepted as a ShortcutOverride, which keeps the shortcut from firing and lets the key through to the field."""
    FIELDS = (QLineEdit, QPlainTextEdit, QTextEdit)   # a spin box types in a QLineEdit of its own

    def __init__(self, always: bool = False):
        super().__init__()
        self.active = always or sys.platform == "win32"   # elsewhere Ctrl+Alt is a real chord, and AltGr isn't Ctrl+Alt

    @staticmethod
    def types_text(e: QKeyEvent) -> bool:
        mods = e.modifiers()
        text = e.text()
        return bool(mods & Qt.KeyboardModifier.ControlModifier and mods & Qt.KeyboardModifier.AltModifier
                    and text and text.isprintable())

    def eventFilter(self, obj, e):
        if self.active and e.type() == QEvent.Type.ShortcutOverride and isinstance(obj, self.FIELDS) \
                and self.types_text(e):
            e.accept()
            return True
        return False


_guard: Optional[AltGrGuard] = None


def guard_altgr(app) -> None:
    """Installs the AltGrGuard for the whole application, once."""
    global _guard
    if _guard is None:
        _guard = AltGrGuard()
        app.installEventFilter(_guard)


# ---------------------------------------------------------------------------------------------------- Settings


MODIFIERS = (Qt.Key.Key_Shift, Qt.Key.Key_Control, Qt.Key.Key_Alt, Qt.Key.Key_Meta, Qt.Key.Key_AltGr,
             Qt.Key.Key_CapsLock)
MOD_MASK = (Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.AltModifier | Qt.KeyboardModifier.ShiftModifier
            | Qt.KeyboardModifier.MetaModifier)


def combo(e: QKeyEvent) -> Optional[str]:
    """The key press as a shortcut, or None for keys a shortcut can't use (space, arrows, F-keys…)."""
    k = e.key()
    if not 0x21 <= k <= 0x7E:   # one printable character
        return None
    mods = e.modifiers() & MOD_MASK
    return QKeySequence(QKeyCombination(Qt.KeyboardModifier(mods), Qt.Key(k))).toString(
        QKeySequence.SequenceFormat.PortableText)


class Recorder(QPushButton):
    """Shows a shortcut; click it and press keys to change it. Delete clears it, Esc cancels."""

    def __init__(self, sid: str, note: Callable[[Optional[str]], None]):
        super().__init__()
        self.sid, self.note = sid, note
        self.recording = False
        self.setMinimumWidth(150)
        self.clicked.connect(self._toggle)
        self.refresh()

    def refresh(self):
        self.setText("Press keys…" if self.recording else (store().shown(self.sid) or "None"))
        self.setProperty("recording", self.recording)
        self.setProperty("none", not self.recording and not store().text(self.sid))
        self.style().unpolish(self)
        self.style().polish(self)

    def _toggle(self):
        self.recording = not self.recording
        if self.recording:
            self.note(None)
            self.setFocus()
        self.refresh()

    def _stop(self):
        self.recording = False
        self.refresh()

    def focusOutEvent(self, e):
        if self.recording:
            self._stop()
        super().focusOutEvent(e)

    def event(self, e):
        # while recording, every key comes here: no shortcut fires, Tab doesn't move on
        if self.recording and e.type() == QEvent.Type.ShortcutOverride:
            e.accept()
            return True
        if self.recording and e.type() == QEvent.Type.KeyPress:
            self._key(e)
            return True
        return super().event(e)

    def _key(self, e: QKeyEvent):
        k = e.key()
        if k in MODIFIERS:
            return   # waiting for the key itself
        if k == Qt.Key.Key_Escape:
            self._stop()
            return
        if k in (Qt.Key.Key_Delete, Qt.Key.Key_Backspace):
            store().set(self.sid, "")
            self._stop()
            return
        c = combo(e)
        if c is None:
            self.note("That key can't be a shortcut: use a letter, number or punctuation key.")
            return
        mods = e.modifiers() & MOD_MASK
        if self.sid.startswith("tool:"):
            if mods:
                self.note("Tools take a single key without Ctrl, Alt or Shift.")
                return
        elif not mods & Qt.KeyboardModifier.ControlModifier:
            self.note("Menu commands need Ctrl with the key, so typing never sets them off.")
            return
        elif c in RESERVED:
            self.note(f"{shown(c)} is already {RESERVED[c]}; pick other keys.")
            return
        moved = store().set(self.sid, c)
        if moved:
            self.note(f"{shown(c)} was {TITLE[moved]}'s shortcut; that one has none now.")
        self._stop()


class SettingsDialog(QDialog):
    """Edit › Settings…: Shortcuts."""

    def __init__(self):
        super().__init__()
        self.setWindowTitle("Settings")
        self.resize(600, 680)
        tabs = QTabWidget()
        tabs.addTab(self._shortcuts(), "Shortcuts")
        v = QVBoxLayout(self)
        v.setContentsMargins(14, 14, 14, 14)
        v.addWidget(tabs)
        store().changed.connect(self.refresh)
        self.refresh()

    def _shortcuts(self) -> QWidget:
        page = QWidget()
        v = QVBoxLayout(page)
        v.setContentsMargins(14, 14, 14, 14)
        v.addWidget(label("Click a shortcut, then press the new keys. Delete clears it, Esc cancels. Tools take a "
                          "single key; menu commands need Ctrl.", "caption"))
        self.note_label = label("", "warn")
        self.note_label.hide()
        v.addWidget(self.note_label)
        rows = QWidget()
        grid = QGridLayout(rows)
        grid.setContentsMargins(0, 0, 8, 0)
        grid.setVerticalSpacing(6)
        grid.setColumnStretch(0, 1)
        self.rows: list[tuple[str, QPushButton, Recorder]] = []
        r, section = 0, None
        for sid, title, sec, _default in DEFS:
            if sec != section:
                section = sec
                head = label(sec.upper(), "section")
                head.setContentsMargins(0, 12 if r else 0, 0, 2)
                grid.addWidget(head, r, 0, 1, 3)
                r += 1
            reset = button("↺", lambda _=False, s=sid: self._reset(s), "link")
            reset.setFixedWidth(22)
            rec = Recorder(sid, self.note)
            grid.addWidget(QLabel(title), r, 0)
            grid.addWidget(reset, r, 1)
            grid.addWidget(rec, r, 2)
            self.rows.append((sid, reset, rec))
            r += 1
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setWidget(rows)
        v.addWidget(scroll, 1)
        self.reset_all = button("Reset All to Defaults", self._reset_all)
        bottom = QHBoxLayout()
        bottom.addStretch(1)
        bottom.addWidget(self.reset_all)
        v.addLayout(bottom)
        return page

    def note(self, text: Optional[str]):
        self.note_label.setText(text or "")
        self.note_label.setVisible(bool(text))

    def _reset(self, sid: str):
        store().reset(sid)
        self.note(None)

    def _reset_all(self):
        store().reset_all()
        self.note(None)

    def recorder(self, sid: str) -> Recorder:
        return next(rec for s, _reset, rec in self.rows if s == sid)

    def refresh(self):
        s = store()
        for sid, reset, rec in self.rows:
            rec.refresh()
            reset.setVisible(s.is_changed(sid))
            reset.setToolTip(f"Back to {shown(DEFAULT[sid]) or 'none'}")
        self.reset_all.setEnabled(s.any_changed)
