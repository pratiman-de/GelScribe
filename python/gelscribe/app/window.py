"""The document window: tool palette, canvas (or the drop zone while there's no image), inspector, menus."""
from __future__ import annotations

import re
from pathlib import Path
from typing import Optional

from PySide6.QtCore import QByteArray, QMimeData, QPoint, QSize, Qt
from PySide6.QtGui import QAction, QActionGroup, QIcon, QImage, QKeySequence
from PySide6.QtWidgets import (QApplication, QFileDialog, QFrame, QHBoxLayout, QLabel, QMainWindow, QMessageBox,
                               QPushButton, QStackedWidget, QToolButton, QVBoxLayout, QWidget)

from .. import __version__
from ..core.model import Role
from ..core.package import EXTENSION, ProjectError, is_project_path
from ..core.scheme import MIME
from . import icons, keys, theme
from .canvas import Canvas
from .editors import NameEditor, TextEditor, TickEditor, button, label, text_width
from .inspector import Inspector
from .workspace import TOOL_HINT, TOOL_TITLE, TOOLS, Workspace

RESOURCES = Path(__file__).parent / "resources"
IMAGE_FILTER = "Images (*.png *.tif *.tiff *.jpg *.jpeg)"


def file_stem(text: str) -> str:
    """A title as the start of a file name: line breaks become spaces, and characters a Mac or PC file name can't hold
    become dashes."""
    t = re.sub(r"\s*\n\s*", " ", text)
    return re.sub(r'[\\/:*?"<>|\x00-\x1f]', "-", t).strip(" .") or "figure"


def app_icon() -> QIcon:
    import sys
    base = Path(getattr(sys, "_MEIPASS", ""), "gelscribe", "app", "resources") if hasattr(sys, "_MEIPASS") else RESOURCES
    p = base / ("icon.ico" if sys.platform == "win32" else "icon.png")   # the .ico has each size Windows asks for
    return QIcon(str(p if p.exists() else RESOURCES / "icon.png"))


class DropZone(QWidget):
    """The empty window: drop a gel or blot image, or choose one. More than one stacks them in one figure."""

    def __init__(self, on_images):
        super().__init__()
        self.on_images = on_images
        self.setAcceptDrops(True)
        outer = QVBoxLayout(self)
        outer.addStretch(1)
        card = QFrame()
        card.setObjectName("dropcard")
        card.setFixedWidth(500)
        v = QVBoxLayout(card)
        v.setContentsMargins(40, 40, 40, 40)
        v.setSpacing(12)
        logo = QLabel()
        logo.setPixmap(app_icon().pixmap(QSize(112, 112)))
        logo.setAlignment(Qt.AlignmentFlag.AlignCenter)
        v.addWidget(logo)
        t = QLabel("Drop a gel/blot image")
        t.setStyleSheet("font-size: 20px; font-weight: 700;")
        t.setAlignment(Qt.AlignmentFlag.AlignCenter)
        v.addWidget(t)
        s = label("PNG, TIFF or JPEG. Source files are never modified.\nDrop more than one to stack them in one figure.",
                  "caption")
        s.setAlignment(Qt.AlignmentFlag.AlignCenter)
        s.setStyleSheet("font-size: 13px;")
        v.addWidget(s)
        b = button("Choose Image…", self._choose, "primary")
        b.setStyleSheet("padding: 8px 18px; font-size: 14px;")
        row = QHBoxLayout()
        row.addStretch(1)
        row.addWidget(b)
        row.addStretch(1)
        v.addLayout(row)
        self.card = card
        h = QHBoxLayout()
        h.addStretch(1)
        h.addWidget(card)
        h.addStretch(1)
        outer.addLayout(h)
        outer.addStretch(1)

    def _choose(self):
        paths, _ = QFileDialog.getOpenFileNames(self, "Choose a gel or blot image (several stack into one figure)", "",
                                                IMAGE_FILTER)
        if paths:
            self.on_images([Path(x) for x in paths])

    def _target(self, on: bool):
        self.card.setProperty("targeted", on)
        self.card.style().unpolish(self.card)
        self.card.style().polish(self.card)

    def dragEnterEvent(self, e):
        if e.mimeData().hasUrls():
            e.acceptProposedAction()
            self._target(True)

    def dragLeaveEvent(self, e):
        self._target(False)

    def dropEvent(self, e):
        self.dragLeaveEvent(e)
        urls = [Path(u.toLocalFile()) for u in e.mimeData().urls() if u.isLocalFile()]
        if urls:
            self.on_images(urls)


class GelSwitcher(QWidget):
    """One pill above the canvas when there are several gels: Figure, then each gel from the top (the one with the lanes is
    tagged). The chosen one is filled with the accent color: Figure while the whole figure shows, else the gel on view.
    A gel here is the chosen gel too, and the Gels list follows it."""

    def __init__(self, ws: Workspace):
        super().__init__()
        self.ws = ws
        row = QHBoxLayout(self)
        row.setContentsMargins(0, 8, 0, 4)
        row.addStretch(1)
        self.pill = QFrame()
        self.pill.setObjectName("pill")
        self.inner = QHBoxLayout(self.pill)
        self.inner.setContentsMargins(3, 3, 3, 3)
        self.inner.setSpacing(2)
        row.addWidget(self.pill)
        row.addStretch(1)
        self.buttons: list[tuple[QPushButton, Optional[int]]] = []   # Figure first (None), then each gel's number
        self._sig = None
        self.setVisible(False)

    def refresh(self):
        ws, p = self.ws, self.ws.project
        several = bool(p.strips) and ws.has_image
        self.setVisible(several)
        if not several:
            self._sig = None
            return
        order = p.stack_order
        sig = tuple(order)
        if sig != self._sig:   # rebuilt when gels come, go or change places
            self._sig = sig
            while self.inner.count():
                it = self.inner.takeAt(0)
                if it.widget() is not None:
                    it.widget().deleteLater()
            self.buttons = []
            figure = QPushButton("Figure")
            figure.setCheckable(True)
            figure.clicked.connect(lambda _=False: ws.show_figure())
            self.inner.addWidget(figure)
            self.buttons.append((figure, -1))
            for n, k in enumerate(order):
                b = QPushButton(f"Gel {n + 1}" + ("  LANES" if k is None else ""))
                b.setCheckable(True)
                b.setToolTip(f"Gel {n + 1} on its own" + (": the gel with the lanes, as a figure of its own" if k is None else ""))
                b.clicked.connect(lambda _=False, k=k: ws.show_gel(k))
                self.inner.addWidget(b)
                self.buttons.append((b, k))
        shown = ws.shows_gel
        for b, k in self.buttons:
            b.setChecked(not shown if k == -1 else (shown and k == ws.active_strip))


class MainWindow(QMainWindow):
    def __init__(self, controller, ws: Workspace):
        super().__init__()
        self.ctl = controller
        self.ws = ws
        self.setWindowIcon(app_icon())
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)   # frees the image and caches when it closes
        self.setAcceptDrops(True)
        self.resize(1440, 920)
        self.setMinimumSize(980, 640)
        central = QWidget()
        h = QHBoxLayout(central)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(0)
        self.palette_frame = self._palette()
        h.addWidget(self.palette_frame)
        self.stack = QStackedWidget()
        self.drop = DropZone(self.adopt_images)
        self.canvas = Canvas(ws)
        self.stack.addWidget(self.drop)
        self.stack.addWidget(self.canvas)
        self.switcher = GelSwitcher(ws)   # just above the canvas, with several gels
        centre = QWidget()
        cv = QVBoxLayout(centre)
        cv.setContentsMargins(0, 0, 0, 0)
        cv.setSpacing(0)
        cv.addWidget(self.switcher)
        cv.addWidget(self.stack, 1)
        h.addWidget(centre, 1)
        self.inspector = Inspector(ws)
        h.addWidget(self.inspector)
        self.setCentralWidget(central)
        self._status()
        self._menus()
        self.canvas.tick_editor.connect(self.show_tick_editor)
        self.canvas.name_editor.connect(self.show_name_editor)
        self.canvas.text_editor.connect(self.show_text_editor)
        self.canvas.zoom_changed.connect(lambda z: self.zoom_label.setText(f"{z}%"))
        ws.changed.connect(self.refresh)
        ws.view_changed.connect(self.refresh)
        ws.undo.cleanChanged.connect(self.refresh)
        ws.message.connect(self.show_message)
        ws.ask_straighten.connect(self.ask_straighten)
        ws.ask_contrast_export.connect(self.ask_contrast_export)
        ws.ask_export_dpi.connect(self.ask_export_dpi)
        self.refresh()

    # ------------------------------------------------------------------------------------------------ chrome

    def _palette(self) -> QFrame:
        f = QFrame()
        f.setObjectName("palette")
        f.setFixedWidth(58)
        v = QVBoxLayout(f)
        v.setContentsMargins(8, 12, 8, 12)
        v.setSpacing(6)
        self.tool_buttons = {}
        for tid, title, key, _hint in TOOLS:
            b = QToolButton()
            b.setIcon(icons.tool_icon(tid))
            b.setIconSize(QSize(22, 22))
            b.setCheckable(True)
            b.setToolTip(f"{title} ({key})")
            b.clicked.connect(lambda _=False, t=tid: self.ws.set_tool(t))
            self.tool_buttons[tid] = b
            v.addWidget(b)
        line = QFrame()
        line.setFixedHeight(1)
        line.setObjectName("sep")
        v.addWidget(line)
        self.text_button = self._tool_button("text", "Text sizes", self._text_sizes_menu)
        self.snap_button = self._tool_button("snap", "Snap to band centres (hold Alt to place freely)",
                                             lambda: self._toggle("snapping"), checkable=True)
        self.contrast_button = self._tool_button("contrast", "Brightness & Contrast (Ctrl+Shift+B)",
                                                 self.ws.show_brightness_contrast)
        self.guides_button = self._tool_button("eye", "Show or hide guides (Ctrl+')", lambda: self._toggle("show_guides"),
                                               checkable=True)
        for b in (self.text_button, self.snap_button, self.contrast_button, self.guides_button):
            v.addWidget(b)
        v.addStretch(1)
        return f

    def _tool_button(self, name, tip, on, checkable=False) -> QToolButton:
        b = QToolButton()
        b.setIcon(icons.icon(name))
        b.setIconSize(QSize(22, 22))
        b.setToolTip(tip)
        b.setCheckable(checkable)
        b.clicked.connect(lambda _=False: on())
        return b

    def _toggle(self, attr):
        setattr(self.ws, attr, not getattr(self.ws, attr))
        self.ws.view_changed.emit()

    def _text_sizes_menu(self):
        self.ws.set_tab("labels")
        self.ws.inspector_visible = True
        self.ws.view_changed.emit()

    def _status(self):
        sb = self.statusBar()
        self.tool_label = QLabel()
        self.tool_label.setObjectName("toolname")
        self.hint_label = QLabel()
        sb.addWidget(self.tool_label)
        sb.addWidget(self.hint_label, 1)
        self.problem_label = QLabel()   # a gel whose image can't be read, said wherever you're working
        self.problem_label.setProperty("warn", True)
        sb.addPermanentWidget(self.problem_label)
        self.lanes_label = QLabel()
        sb.addPermanentWidget(self.lanes_label)
        self.zoom_out_button = self._zoom_button("−", "out")
        sb.addPermanentWidget(self.zoom_out_button)
        self.zoom_label = QPushButton("100%")
        self.zoom_label.setProperty("link", True)
        self.zoom_label.setMinimumWidth(text_width(self.zoom_label, "6400%", pad=8))   # the widest zoom, whatever the font
        self.zoom_label.setToolTip("Zoom to fit (Ctrl+0)")
        self.zoom_label.clicked.connect(lambda: self.ws.zoom_request.emit("fit"))
        sb.addPermanentWidget(self.zoom_label)
        self.zoom_in_button = self._zoom_button("+", "in")
        sb.addPermanentWidget(self.zoom_in_button)

    def _zoom_button(self, text, z):
        b = QPushButton(text)
        b.setProperty("link", True)
        b.setFixedWidth(22)
        b.clicked.connect(lambda: self.ws.zoom_request.emit(z))
        return b

    def _menus(self):
        mb = self.menuBar()
        ctl, ws = self.ctl, self.ws
        self.key_actions: dict[str, QAction] = {}   # the ones Settings › Shortcuts can change, by id

        def act(menu, text, fn, shortcut=None, checkable=False, key=None):
            a = QAction(text, self)
            if shortcut:
                a.setShortcut(QKeySequence(shortcut))
            if key:
                self.key_actions[key] = a   # its keys come from apply_keys
            a.setCheckable(checkable)
            a.triggered.connect(fn)
            menu.addAction(a)
            return a

        f = mb.addMenu("&File")
        act(f, "&New", ctl.new_window, QKeySequence.StandardKey.New)
        self.a_new_labels = act(f, "New Gel with These Labels…", self.new_gel_with_labels, key="newGelWithLabels")
        self.a_add_gel = act(f, "Add Gel…", self.add_gel_dialog)   # more gels, or a cut membrane's other pieces, below
        f.addSeparator()
        act(f, "&Open…", ctl.open_dialog, QKeySequence.StandardKey.Open)
        act(f, "Open Project Folder…", ctl.open_folder_dialog)
        self.recent_menu = f.addMenu("Open Recent")
        f.aboutToShow.connect(self._fill_recent)   # not on every change: it looks at the disk
        self.recent_menu.aboutToShow.connect(self._fill_recent)
        self._fill_recent()
        f.addSeparator()
        act(f, "&Close", self.close, QKeySequence.StandardKey.Close)
        self.a_save = act(f, "&Save", self.save, QKeySequence.StandardKey.Save)
        act(f, "Save &As…", self.save_as, "Ctrl+Shift+S")
        f.addSeparator()
        act(f, "E&xit", ctl.quit, "Ctrl+Q")

        e = mb.addMenu("&Edit")
        undo = ws.undo.createUndoAction(self, "&Undo")
        undo.setShortcut(QKeySequence.StandardKey.Undo)
        redo = ws.undo.createRedoAction(self, "&Redo")
        redo.setShortcuts([QKeySequence.StandardKey.Redo, QKeySequence("Ctrl+Y")])
        e.addAction(undo)
        e.addAction(redo)
        e.addSeparator()
        self.a_copy_labels = act(e, "Copy Labels", self.copy_labels, key="copyLabels")
        self.a_paste_labels = act(e, "Paste Labels", lambda: self.paste_labels(False), key="pasteLabels")
        self.a_paste_pos = act(e, "Paste Labels and Positions", lambda: self.paste_labels(True),
                               key="pasteLabelsAndPositions")
        e.addSeparator()
        act(e, "Settings…", ctl.show_settings, "Ctrl+,").setMenuRole(QAction.MenuRole.PreferencesRole)

        v = mb.addMenu("&View")
        act(v, "Zoom to Fit", lambda: ws.zoom_request.emit("fit"), key="zoomFit")
        act(v, "Actual Pixels", lambda: ws.zoom_request.emit("actual"), key="zoomActual")
        act(v, "Zoom In", lambda: ws.zoom_request.emit("in"), key="zoomIn")
        act(v, "Zoom Out", lambda: ws.zoom_request.emit("out"), key="zoomOut")
        v.addSeparator()
        self.a_guides = act(v, "Show Guides", lambda: self._toggle("show_guides"), checkable=True, key="toggleGuides")
        self.a_inspector = act(v, "Show Inspector", lambda: self._toggle("inspector_visible"), checkable=True,
                               key="toggleInspector")
        v.addSeparator()
        looks = v.addMenu("Appearance")
        group = QActionGroup(self)
        self.appearance_actions = {}
        for key, title in (("dark", "Dark"), ("light", "Light")):
            a = QAction(title, self, checkable=True)
            a.setChecked(theme.mode == key)
            a.triggered.connect(lambda _=False, k=key: ctl.set_appearance(k))
            group.addAction(a)
            looks.addAction(a)
            self.appearance_actions[key] = a

        x = mb.addMenu("E&xport")
        self.export_actions = [act(x, "PDF…", lambda: self.export("pdf"), key="exportPDF"),
                               act(x, "TIFF…", lambda: self.export("tiff"), key="exportTIFF"),
                               act(x, "PNG…", lambda: self.export("png"), key="exportPNG"),
                               act(x, "SVG…", lambda: self.export("svg"), key="exportSVG")]
        x.addSeparator()
        self.export_actions.append(act(x, "Copy Figure", self.copy_figure, key="copyFigure"))
        x.addSeparator()
        self.res_menu = x.addMenu("PNG and TIFF Resolution")
        self.res_menu.aboutToShow.connect(self._fill_resolutions)

        fm = mb.addMenu("F&ormat")
        act(fm, "Bigger Text", lambda: ws.bump_text(0.5), key="biggerText")
        act(fm, "Smaller Text", lambda: ws.bump_text(-0.5), key="smallerText")

        t = mb.addMenu("&Tools")
        for tid, title, _key, _hint in TOOLS:   # window shortcuts: a tool's key works anywhere but a text field
            act(t, title, lambda _=False, tid=tid: ws.set_tool(tid), key="tool:" + tid)
        t.addSeparator()
        self.a_snap = act(t, "Snap to Band Centers", lambda: self._toggle("snapping"), None, True)
        act(t, "Brightness && Contrast…", ws.show_brightness_contrast, key="brightnessContrast")

        hm = mb.addMenu("&Help")
        act(hm, "Check for Updates…", ctl.check_for_updates)
        hm.addSeparator()
        act(hm, "About GelScribe", self.about)
        keys.store().changed.connect(self.apply_keys)
        self.apply_keys()

    def apply_keys(self):
        """The shortcuts from Settings › Shortcuts: on the menu commands and tools, and in the palette's tips."""
        s = keys.store()
        for sid, a in self.key_actions.items():
            a.setShortcut(s.sequence(sid))

        def tip(text, sid):
            k = s.shown(sid)
            return f"{text} ({k})" if k else text
        for tid, b in self.tool_buttons.items():
            b.setToolTip(tip(TOOL_TITLE[tid], "tool:" + tid))
        self.contrast_button.setToolTip(tip("Brightness & Contrast", "brightnessContrast"))
        self.guides_button.setToolTip(tip("Show or hide guides", "toggleGuides"))

    def retheme(self):
        """After View › Appearance: what the window paints itself (icons, canvas, histogram) follows the new look."""
        for tid, b in self.tool_buttons.items():
            b.setIcon(icons.tool_icon(tid))
        for name, b in (("text", self.text_button), ("snap", self.snap_button), ("contrast", self.contrast_button),
                        ("eye", self.guides_button)):
            b.setIcon(icons.icon(name))
        for key, a in self.appearance_actions.items():
            a.setChecked(theme.mode == key)
        self.inspector.refresh()
        self.inspector.panels["figure"].hist.update()
        self.canvas.update()

    def _fill_resolutions(self):
        m = self.res_menu
        m.clear()
        ws = self.ws
        if ws.layout is None:
            return
        g = QActionGroup(m)
        current = ws.resampled_export_dpi
        native = QAction(f"Native, {ws.native_dpi} dpi (gel pixels 1:1)", m, checkable=True)
        native.setChecked(current is None)
        native.triggered.connect(lambda: ws.request_export_dpi(None))
        g.addAction(native)
        m.addAction(native)
        options = [d for d in (300.0, 600.0, 1200.0) if abs(d - ws.native_dpi) > 0.5]
        if current is not None and current not in options:
            options = sorted(options + [current])
        for d in options:
            a = QAction(f"{int(d)} dpi (gel resampled)", m, checkable=True)
            a.setChecked(current == d)
            a.triggered.connect(lambda _=False, d=d: ws.request_export_dpi(d))
            g.addAction(a)
            m.addAction(a)

    def show_message(self, m: str):
        self.statusBar().showMessage(m, 6000)

    def refresh(self, *_):
        ws = self.ws
        self.stack.setCurrentWidget(self.canvas if ws.has_image else self.drop)
        self.switcher.refresh()
        self.setWindowTitle(f"{ws.title}[*] - GelScribe")
        self.setWindowModified(ws.dirty)
        for tid, b in self.tool_buttons.items():
            b.setChecked(ws.tool == tid)
        lanes = self.tool_buttons["lanes"]   # the lane dividers are the lanes gel's: not on another gel's view
        if lanes.isEnabled() == ws.views_other_gel:
            lanes.setEnabled(not ws.views_other_gel)
            if ws.views_other_gel:
                lanes.setToolTip(f"Lane dividers are set on {ws.gel_name(None)}, the gel with the lanes.")
            else:
                self.apply_keys()   # the tip with its shortcut again
        self.snap_button.setChecked(ws.snapping)
        self.guides_button.setChecked(not ws.show_guides)
        self.a_guides.setChecked(ws.show_guides)
        self.a_inspector.setChecked(ws.inspector_visible)
        self.a_snap.setChecked(ws.snapping)
        self.inspector.setVisible(ws.inspector_visible and ws.has_image)
        self.palette_frame.setVisible(ws.has_image)
        has = ws.has_image
        for a in self.export_actions + [self.a_copy_labels, self.a_paste_labels, self.a_paste_pos, self.a_new_labels,
                                        self.a_add_gel]:
            a.setEnabled(has)
        self.tool_label.setText(TOOL_TITLE[ws.tool] if has else "")
        hint = ws.tool_note or TOOL_HINT[ws.tool]
        self.hint_label.setText(hint if has else "")
        self.lanes_label.setText(f"{ws.project.lane_count} lanes   " if has else "")
        self.zoom_label.setText(f"{self.canvas.zoom_percent()}%")
        for b in (self.zoom_out_button, self.zoom_label, self.zoom_in_button):   # nothing to zoom without an image
            b.setVisible(has)
        problem = ws.unreadable_gel if has else None
        self.problem_label.setText(problem or "")
        self.problem_label.setVisible(bool(problem))

    def _fill_recent(self):
        recent = self.ctl.recent()
        self.recent_menu.clear()
        for p in recent:
            self.recent_menu.addAction(Path(p).name, lambda p=p: self.ctl.open_path(Path(p)))
        self.recent_menu.setEnabled(bool(recent))

    # ------------------------------------------------------------------------------------------------ editors

    def show_tick_editor(self, i: int, at: QPoint):
        ws = self.ws
        lad = ws.project.ladder
        if not lad or i >= len(lad.bands):
            return
        b = lad.bands[i]
        ed = TickEditor(self, b.size, b.auto, ws.suggested_size(b.y - 0.001, b.strip), ws.ladder_sizes,
                        lad.unit or (ws.preset.unit if ws.preset else "kDa"),
                        lambda s: ws.set_tick(i, s), lambda: ws.set_tick(i, None, ignore=True), lambda: ws.delete_tick(i))
        ed.show_beside(*self.canvas.tick_anchor(i))   # not below the band: that's where the next click goes

    def show_name_editor(self, i: int, at: QPoint):
        ws = self.ws
        if i >= len(ws.project.annotations):
            return
        a = ws.project.annotations[i]
        role = Role("annotation", i)

        def commit(text, marker):
            if not text.strip():
                ws.delete_name(i)
                return
            def fn(an):
                an.text, an.marker = text, marker
            ws.update_name(i, fn)
            ws.remember_name(text)

        ed = NameEditor(self, a.text, a.marker, ws.project.style.size_for(role), ws.recent_names, commit,
                        lambda v: ws.set_label_size(v, role), lambda: ws.delete_name(i), ws.forget_name)
        ed.show_at(at)

    def show_text_editor(self, role: Role, at: QPoint):
        ws = self.ws
        kind_titles = {"title": "Title", "rowName": "Row title", "laneLabel": "Lane label", "groupLabel": "Group label",
                       "ladderUnit": "Ladder unit", "ladderLabel": "Ladder size", "annotation": "Band name"}
        scope = ("the title" if role.kind == "title" else
                 "this label only" if role.size_key else "all " + ("ladder sizes" if role.kind.startswith("ladder")
                                                                   else "labels of this kind"))
        ed = TextEditor(self, kind_titles.get(role.kind, "Label"), ws.text_for(role), ws.project.style.size_for(role),
                        scope, lambda v: ws.set_text(role, v), lambda v: ws.set_label_size(v, role))
        ed.show_at(at)

    # ------------------------------------------------------------------------------------------------ questions

    def ask_straighten(self, delta: float):
        m = QMessageBox(self)
        m.setWindowTitle("Turn off Keep original pixels to straighten?")
        m.setText("Turn off Keep original pixels to straighten?")
        extra = "" if self.ws.project.display.is_identity else " Brightness & contrast will reach exports too."
        m.setInformativeText("Rotating resamples the gel, so the exported pixels will no longer be the originals. "
                             "The exports record the rotation, and your original file stays untouched." + extra)
        ok = m.addButton(f"Turn Off and Rotate {delta:+.2f}°", QMessageBox.ButtonRole.AcceptRole)
        m.addButton(QMessageBox.StandardButton.Cancel)
        m.exec()
        if m.clickedButton() is ok:
            self.ws.confirm_straighten(delta)

    def ask_contrast_export(self):
        m = QMessageBox(self)
        m.setWindowTitle("Use brightness & contrast in exports?")
        m.setText("Use brightness & contrast in exports?")
        which = "the gel" if not self.ws.project.strips else self.ws.active_name
        m.setInformativeText(f"Exports will show {which} at display range {self.ws.display_range_text()} instead of "
                             "its original values, like ImageJ's Apply. Each file records the range, and your original "
                             "file stays untouched. With Keep original pixels off you can also rotate and fill.")
        ok = m.addButton("Turn Off Keep Original Pixels", QMessageBox.ButtonRole.AcceptRole)
        m.addButton(QMessageBox.StandardButton.Cancel)
        m.exec()
        if m.clickedButton() is ok:
            self.ws.set_strict(False)

    def confirm_changed_images(self) -> bool:
        """Before a figure is exported or copied: a gel's image no longer matches the SHA-256 taken when it was added."""
        lines = self.ws.changed_warnings()
        if not lines:
            return True
        m = QMessageBox(self)
        m.setIcon(QMessageBox.Icon.Warning)
        m.setWindowTitle("A gel's image has changed")
        m.setText("A gel's image has changed")
        m.setInformativeText("\n".join(lines))
        ok = m.addButton("Export Anyway", QMessageBox.ButtonRole.AcceptRole)
        m.addButton(QMessageBox.StandardButton.Cancel)
        m.exec()
        return m.clickedButton() is ok

    def ask_export_dpi(self, dpi: float):
        m = QMessageBox(self)
        m.setWindowTitle("Resample the gel for PNG and TIFF?")
        m.setText("Resample the gel for PNG and TIFF?")
        m.setInformativeText(f"At {int(dpi)} dpi the gel's pixels are recalculated, so PNG and TIFF exports won't carry "
                             f"the original values (native is {self.ws.native_dpi} dpi). Your original file, PDF and SVG "
                             "are unaffected, and each PNG or TIFF records the resampling.")
        ok = m.addButton(f"Use {int(dpi)} dpi", QMessageBox.ButtonRole.AcceptRole)
        m.addButton("Keep Native", QMessageBox.ButtonRole.RejectRole)
        m.exec()
        if m.clickedButton() is ok:
            self.ws.set_export_dpi(dpi)

    # ------------------------------------------------------------------------------------------------ files

    def adopt_image(self, path: Path):
        try:
            if is_project_path(path) or path.is_dir():
                self.ctl.open_path(path)
            elif self.ws.has_image:
                self.ctl.open_path(path)
            else:
                self.ws.adopt_image(path)
        except Exception as e:
            QMessageBox.warning(self, "GelScribe", f"{path.name} could not be opened.\n\n{e}")

    def adopt_images(self, paths: list[Path]):
        """Images dropped on the window. Into the empty one the first starts the project and the others stack under it
        as more gels; into one that has an image they're opened as projects of their own, each in its own window."""
        images = [x for x in paths if not (is_project_path(x) or x.is_dir())]
        if self.ws.has_image or len(images) < 2 or len(images) != len(paths):
            self.adopt_image(paths[0])
            for path in paths[1:]:   # each of the others in a window of its own
                self.ctl.open_path(path)
            return
        try:
            failed = self.ws.adopt_images(images)
        except Exception as e:
            QMessageBox.warning(self, "GelScribe", f"{images[0].name} could not be opened.\n\n{e}")
            return
        self.tell(failed)

    def tell(self, problems: list[str]):
        """What couldn't be done, in one box."""
        if problems:
            QMessageBox.warning(self, "GelScribe", "\n\n".join(problems))

    def add_gel_dialog(self):
        """File › Add Gel…: more gels, or the other pieces of a cut membrane, at the bottom of the stack."""
        if not self.ws.has_image:
            return
        paths, _ = QFileDialog.getOpenFileNames(self, "Choose the gels to stack under this one, top first",
                                                self.ctl.last_dir(), IMAGE_FILTER)
        if paths:
            self.tell(self.ws.add_gels([Path(x) for x in paths]))

    def dragEnterEvent(self, e):
        if e.mimeData().hasUrls():
            e.acceptProposedAction()

    def dropEvent(self, e):
        paths = [Path(u.toLocalFile()) for u in e.mimeData().urls() if u.isLocalFile()]
        if paths:
            self.adopt_images(paths)

    def save(self) -> bool:
        if not self.ws.has_image:
            return False
        if self.ws.folder is None:
            return self.save_as()
        try:
            self.ws.save_to(self.ws.folder)
        except (OSError, ProjectError) as e:   # nothing was written: the window and its changes stay as they were
            QMessageBox.warning(self, "GelScribe", f"Could not save.\n\n{e}")
            return False
        self.ctl.remember(self.ws.folder)
        return True

    def save_as(self) -> bool:
        if not self.ws.has_image:
            return False
        start = str((self.ws.folder.parent if self.ws.folder else Path(self.ctl.last_dir())) /
                    (file_stem(self.ws.project.title or Path(self.ws.project.image).stem) + EXTENSION))
        path, _ = QFileDialog.getSaveFileName(self, "Save GelScribe Project", start, f"GelScribe project (*{EXTENSION})")
        if not path:
            return False
        folder = Path(path)
        if folder.suffix.lower() != EXTENSION:
            folder = folder.with_name(folder.name + EXTENSION)
        if folder.exists() and not (folder / "project.json").exists() and any(folder.iterdir()):
            QMessageBox.warning(self, "GelScribe", f"{folder.name} already exists and isn't a GelScribe project.")
            return False
        try:
            self.ws.save_to(folder)
        except (OSError, ProjectError) as e:
            QMessageBox.warning(self, "GelScribe", f"Could not save.\n\n{e}")
            return False
        self.ctl.remember(folder)
        self.ctl.set_last_dir(folder.parent)
        return True

    def closeEvent(self, e):
        self.ws.finish_quick_labels(normalize=False)
        if self.ws.has_image and self.ws.dirty:
            m = QMessageBox(self)
            m.setWindowTitle("GelScribe")
            m.setText(f"Save the changes to “{self.ws.title}”?")
            m.setInformativeText("Your changes will be lost if you don't save them.")
            m.setStandardButtons(QMessageBox.StandardButton.Save | QMessageBox.StandardButton.Discard
                                 | QMessageBox.StandardButton.Cancel)
            r = m.exec()
            keep = r == QMessageBox.StandardButton.Cancel
            if r == QMessageBox.StandardButton.Save:
                try:
                    keep = not self.save()
                except Exception:   # whatever went wrong, the window and its changes stay
                    e.ignore()
                    raise
            if keep:
                e.ignore()
                return
        self.ws.dispose()
        self.ctl.closed(self)
        e.accept()

    def new_gel_with_labels(self):
        path, _ = QFileDialog.getOpenFileName(self, "Choose the next gel image. It gets this project's labels, titles, "
                                              "band names and ladder.", self.ctl.last_dir(), IMAGE_FILTER)
        if not path:
            return
        try:
            pkg = self.ws.package_for_new_gel(Path(path))
        except Exception as e:
            QMessageBox.warning(self, "GelScribe", f"{Path(path).name} could not be opened.\n\n{e}")
            return
        self.ctl.new_window(pkg)

    # ------------------------------------------------------------------------------------------------ export, reuse

    def export(self, fmt: str):
        ws = self.ws
        if not ws.has_image:
            return
        if ws.export_problem:   # no use asking where to put it
            QMessageBox.warning(self, "GelScribe", f"Export failed.\n\n{ws.export_problem}")
            return
        if not self.confirm_changed_images():
            return
        base = file_stem(ws.project.title or Path(ws.project.image).stem)
        filt = {"pdf": "PDF (*.pdf)", "tiff": "TIFF (*.tiff *.tif)", "png": "PNG (*.png)", "svg": "SVG (*.svg)"}[fmt]
        path, _ = QFileDialog.getSaveFileName(self, f"Export {fmt.upper()}",
                                              str(Path(self.ctl.last_export_dir()) / f"{base}.{fmt}"), filt)
        if not path:
            return
        failed = None
        QApplication.setOverrideCursor(Qt.CursorShape.WaitCursor)
        try:
            Path(path).write_bytes(ws.export_bytes(fmt))
        except Exception as e:
            failed = e
        finally:
            QApplication.restoreOverrideCursor()
        if failed is not None:
            QMessageBox.warning(self, "GelScribe", f"Export failed.\n\n{failed}")
            return
        self.ctl.set_last_export_dir(Path(path).parent)
        self.statusBar().showMessage(f"Exported {Path(path).name}", 5000)

    def copy_figure(self):
        ws = self.ws
        if not ws.has_image:
            return
        if ws.export_problem:
            QMessageBox.warning(self, "GelScribe", f"Copy failed.\n\n{ws.export_problem}")
            return
        if not self.confirm_changed_images():
            return
        md = QMimeData()
        failed = None
        QApplication.setOverrideCursor(Qt.CursorShape.WaitCursor)
        try:
            md.setData("application/pdf", QByteArray(ws.export_bytes("pdf")))
            md.setImageData(QImage.fromData(ws.export_bytes("png"), "PNG"))
        except Exception as e:
            failed = e
        finally:
            QApplication.restoreOverrideCursor()
        if failed is not None:
            QMessageBox.warning(self, "GelScribe", f"Copy failed.\n\n{failed}")
            return
        QApplication.clipboard().setMimeData(md)
        self.statusBar().showMessage("Figure copied (PDF and PNG)", 4000)

    def copy_labels(self):
        text = self.ws.scheme_text(positions=True)
        md = QMimeData()
        md.setData(MIME, QByteArray(text.encode("utf-8")))
        md.setText(text)
        QApplication.clipboard().setMimeData(md)
        self.statusBar().showMessage("Labels copied: paste them into another gel's window", 4000)

    def paste_labels(self, positions: bool):
        md = QApplication.clipboard().mimeData()
        text = bytes(md.data(MIME)).decode("utf-8") if md.hasFormat(MIME) else md.text()
        if not text or not self.ws.paste_scheme(text, positions):
            self.statusBar().showMessage("Nothing to paste: copy labels from another gel first.", 5000)

    def about(self):
        m = QMessageBox(self)
        m.setWindowTitle("About GelScribe")
        m.setIconPixmap(app_icon().pixmap(QSize(96, 96)))
        m.setText(f"<b style='font-size:16px'>GelScribe</b><br>Version {__version__}")
        m.setInformativeText(f"<a href='https://github.com/pratiman-de' style='color:{theme.C['link']}'>github.com/pratiman-de</a>"
                             "<br>Copyright © 2026 Pratiman De")
        m.exec()
