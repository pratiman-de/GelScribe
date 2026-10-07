"""Starting GelScribe: one window per project, files from the command line (Windows' "Open with"), recent files."""
from __future__ import annotations

import sys
import traceback
from datetime import datetime
from pathlib import Path
from typing import Optional

from PySide6.QtCore import QTimer
from PySide6.QtWidgets import QApplication, QFileDialog, QMessageBox

from .. import __version__
from ..core.package import GelPackage, PROJECT_FILE, is_image_path, is_project_path
from . import keys, settings, theme
from .window import IMAGE_FILTER, MainWindow, app_icon
from .workspace import Workspace


class Controller:
    def __init__(self, app: QApplication):
        self.app = app
        self.windows: list[MainWindow] = []
        self.settings = settings()
        self._settings_dialog = None
        keys.guard_altgr(app)

    # windows
    def new_window(self, package: Optional[GelPackage] = None, folder: Optional[Path] = None) -> MainWindow:
        ws = Workspace(package, folder)
        w = MainWindow(self, ws)
        self.windows.append(w)
        if self.windows[:-1]:
            prev = self.windows[-2]
            w.move(prev.pos().x() + 28, prev.pos().y() + 28)
        w.show()
        w.raise_()
        w.activateWindow()
        return w

    def closed(self, w: MainWindow):
        if w in self.windows:
            self.windows.remove(w)

    def quit(self):
        for w in list(self.windows):
            if not w.close():
                return
        self.app.quit()

    def show_settings(self):
        """Edit › Settings…: one window for every document."""
        from .keys import SettingsDialog
        if self._settings_dialog is None:
            self._settings_dialog = SettingsDialog()
        self._settings_dialog.show()
        self._settings_dialog.raise_()
        self._settings_dialog.activateWindow()

    def set_appearance(self, mode: str):
        """View › Appearance: dark (the default) or light, for every window, remembered for next time."""
        self.settings.setValue("appearance", mode)
        theme.apply(self.app, mode)
        for w in self.windows:
            w.retheme()

    def _empty_window(self) -> Optional[MainWindow]:
        return next((w for w in self.windows if not w.ws.has_image and not w.ws.undo.count()), None)

    # files
    def open_path(self, path: Path):
        path = Path(path)
        try:
            if path.is_dir() or is_project_path(path):
                folder = GelPackage.project_folder(path)
                for w in self.windows:   # already open: bring it forward
                    if w.ws.folder and w.ws.folder.resolve() == folder.resolve():
                        w.raise_()
                        w.activateWindow()
                        return
                pkg = GelPackage.read(folder)
                empty = self._empty_window()
                if empty is not None:
                    empty.close()
                self.new_window(pkg, folder)
                self.remember(folder)
            elif is_image_path(path) or path.is_file():
                # an image starts a new untitled project; the image itself is never the document
                empty = self._empty_window()
                if empty is not None:
                    empty.ws.adopt_image(path)
                    empty.raise_()
                else:
                    self.new_window(GelPackage.create_from(path))
            self.set_last_dir(path.parent)
        except Exception as e:
            QMessageBox.warning(None, "GelScribe", f"{path.name} could not be opened.\n\n{e}")

    def open_dialog(self):
        path, _ = QFileDialog.getOpenFileName(
            None, "Open", self.last_dir(),
            f"GelScribe projects and images ({PROJECT_FILE} *.png *.tif *.tiff *.jpg *.jpeg);;"
            f"GelScribe projects ({PROJECT_FILE});;{IMAGE_FILTER}")
        if path:
            self.open_path(Path(path))

    def open_folder_dialog(self):
        path = QFileDialog.getExistingDirectory(None, "Open a .gelscribe project folder", self.last_dir())
        if path:
            self.open_path(Path(path))

    # remembered places
    def recent(self) -> list[str]:
        return [p for p in (self.settings.value("recentProjects", [], type=list)) if Path(p).exists()][:10]

    def remember(self, folder: Path):
        lst = [str(folder)] + [p for p in self.recent() if p != str(folder)]
        self.settings.setValue("recentProjects", lst[:10])

    def last_dir(self) -> str:
        return str(self.settings.value("lastDir", str(Path.home())))

    def set_last_dir(self, d: Path):
        self.settings.setValue("lastDir", str(d))

    def last_export_dir(self) -> str:
        return str(self.settings.value("lastExportDir", self.last_dir()))

    def set_last_export_dir(self, d: Path):
        self.settings.setValue("lastExportDir", str(d))


def log_errors() -> Path:
    """Without a console (pythonw), unexpected errors go to GelScribe.log next to the settings file, and the first one
    in a session says where. Qt carries on after an error in a click or a repaint."""
    log = Path(settings().fileName()).with_name("GelScribe.log")
    told = []

    def tell(value):
        QMessageBox.warning(None, "GelScribe", f"Something went wrong: {value}\n\nThe details are in {log}")

    def hook(kind, value, tb):
        text = "".join(traceback.format_exception(kind, value, tb))
        if sys.stderr:
            sys.stderr.write(text)
        try:
            log.parent.mkdir(parents=True, exist_ok=True)
            with open(log, "a", encoding="utf-8") as f:
                f.write(f"--- {datetime.now():%Y-%m-%d %H:%M:%S}, GelScribe {__version__}, {sys.platform}\n{text}\n")
        except OSError:
            pass
        if not told and QApplication.instance() is not None:
            told.append(True)
            QTimer.singleShot(0, lambda: tell(value))   # from the event loop, not from inside a paint
    sys.excepthook = hook
    return log


def run(argv: Optional[list[str]] = None) -> int:
    argv = list(sys.argv if argv is None else argv)
    if sys.platform == "win32":   # its own taskbar icon, not Python's
        try:
            import ctypes
            ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("GelScribe.GelScribe")
        except Exception:
            pass
    app = QApplication(argv)
    app.setApplicationName("GelScribe")
    app.setOrganizationName("GelScribe")
    app.setApplicationVersion(__version__)
    if sys.platform.startswith("linux"):   # the name of its menu entry (bootstrap.menu_entry), for the dock's icon
        app.setDesktopFileName("gelscribe")
    app.setWindowIcon(app_icon())
    theme.apply(app, str(settings().value("appearance", "dark")))
    log_errors()
    ctl = Controller(app)
    app._controller = ctl   # keep it alive
    files = [Path(a) for a in argv[1:] if not a.startswith("-")]
    if files:
        for f in files:
            ctl.open_path(f)
    if not ctl.windows:
        ctl.new_window()
    return app.exec()
