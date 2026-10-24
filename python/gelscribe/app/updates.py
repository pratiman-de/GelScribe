"""The update notice in the window: a background check, a small non-modal notice, and Help › Check for Updates…."""
from __future__ import annotations

import threading
import time
from typing import Callable, Optional

from PySide6.QtCore import QObject, Qt, QUrl, Signal
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import QDialog, QHBoxLayout, QVBoxLayout, QWidget

from .. import __version__
from ..core import updates
from . import dialogs
from .editors import button, label, text_width


class UpdateNotice(QDialog):
    """"GelScribe 0.3 is available": Download opens the release page, Later closes, Don't show this again turns the
    automatic check off. Not modal: the window behind it stays usable."""

    def __init__(self, release: updates.Release, current: str, on_off: Callable[[], None],
                 parent: Optional[QWidget] = None):
        super().__init__(parent)
        self.release = release
        self.setWindowTitle("GelScribe update")
        self.setWindowModality(Qt.WindowModality.NonModal)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        v = QVBoxLayout(self)
        v.setContentsMargins(16, 14, 16, 14)
        v.addWidget(label(f"<b>GelScribe {release.version} is available</b>"))
        text = f"You have {current}."
        notes = updates.notes_excerpt(release.notes)
        if notes:
            text += "\n\n" + notes
        self.text = label(text, "caption")
        self.text.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop)   # spare room goes below, not above
        v.addWidget(self.text)
        row = QHBoxLayout()
        self.off_button = button("Don't show this again", lambda: (on_off(), self.close()), "link")
        self.off_button.setMinimumWidth(text_width(self.off_button, "Don't show this again", pad=8))
        self.later_button = button("Later", self.close)
        self.download_button = button("Download", self.download)
        self.download_button.setDefault(True)
        row.addWidget(self.off_button)
        row.addStretch(1)
        row.addWidget(self.later_button)
        row.addWidget(self.download_button)
        v.addLayout(row)
        self.setMinimumWidth(380)

    def showEvent(self, e):
        super().showEvent(e)
        # tall enough for the wrapped notes, and a line to spare: at a fractional scale (Windows at 150%) a line can wrap
        # a word earlier than the height was worked out for
        self.text.setMinimumHeight(self.text.heightForWidth(self.text.width()) + self.text.fontMetrics().lineSpacing())
        self.adjustSize()

    def download(self):
        QDesktopServices.openUrl(QUrl(self.release.url))   # the release page, in the browser
        self.close()


class UpdateChecker(QObject):
    """Runs the fetch on a worker thread and hands the result back on the main thread."""
    finished = Signal(object, bool)   # Result, manual

    def __init__(self, fetch: Callable[[str], object] = updates.fetch_latest):
        super().__init__()
        self.fetch = fetch   # tests replace this
        self.thread: Optional[threading.Thread] = None

    def start(self, manual: bool = False):
        def work():
            result = updates.check(self.fetch, __version__)
            try:
                self.finished.emit(result, manual)
            except RuntimeError:   # the app was closed while the request was out: nobody is left to tell
                pass
        self.thread = threading.Thread(target=work, name="GelScribe update check", daemon=True)
        self.thread.start()


class UpdateController(QObject):
    """Owned by the app Controller: the throttle, the stored setting, and what to show."""

    def __init__(self, settings, front_window: Callable[[], Optional[QWidget]],
                 fetch: Callable[[str], object] = updates.fetch_latest):
        super().__init__()
        self.settings = settings
        self.front_window = front_window
        self.checker = UpdateChecker(fetch)
        self.checker.finished.connect(self._done)
        self.notice: Optional[UpdateNotice] = None
        self.alert: Optional[dialogs.MessageDialog] = None

    # the two stored values: "updateCheckEnabled" and "lastUpdateCheck" (seconds since 1970)
    def enabled(self) -> bool:
        return self.settings.value("updateCheckEnabled", True, type=bool)

    def set_enabled(self, on: bool):
        self.settings.setValue("updateCheckEnabled", bool(on))

    def last_check(self) -> Optional[float]:
        v = self.settings.value("lastUpdateCheck", None)
        try:
            return float(v) if v not in (None, "") else None
        except (TypeError, ValueError):
            return None

    def check(self, manual: bool = False, now: Optional[float] = None) -> bool:
        """On launch (manual=False) only when it is on and a day has passed. Returns whether a check started."""
        if not updates.due(self.enabled(), self.last_check(), time.time() if now is None else now, manual):
            return False
        self.checker.start(manual)
        return True

    def _done(self, result: updates.Result, manual: bool):
        if result.status != "error":
            self.settings.setValue("lastUpdateCheck", time.time())
        if result.status == "newer" and result.release is not None:
            self.show_notice(result.release)
        elif manual:
            self.show_alert(f"GelScribe {__version__} is the latest version." if result.status == "current"
                            else "Couldn't check for updates. Check your internet connection.")

    def show_notice(self, release: updates.Release):
        if self.notice is not None:
            self.notice.close()
        notice = UpdateNotice(release, __version__, lambda: self.set_enabled(False), self.front_window())
        self.notice = notice
        notice.destroyed.connect(lambda *_: setattr(self, "notice", None) if self.notice is notice else None)
        notice.show()
        notice.raise_()

    def show_alert(self, text: str):
        self.alert = dialogs.MessageDialog(self.front_window(), text)
        self.alert.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.alert.open()   # a sheet-like alert that does not block the event loop
