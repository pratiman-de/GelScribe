"""One open project: its document, undo history, image caches and every edit the window can make."""
from __future__ import annotations

import hashlib
import math
import re
from dataclasses import astuple
from pathlib import Path
from types import SimpleNamespace
from typing import Callable, Optional

import threading

from PySide6.QtCore import QObject, QRunnable, Qt, QThreadPool, QTimer, Signal
from PySide6.QtGui import QImage, QUndoCommand, QUndoStack

from ..core import labels as ql
from ..core import ladders as lib
from ..core import ops
from ..core import render
from ..core import strips as stacked
from ..core.detect import snap_band
from ..core.image import ImageError, SourceImage, WorkingImage
from ..core.layout import FigureLayout, layout as make_layout
from ..core.model import (SIDE_SCALES, BandAnnotation, DisplaySettings, GelProject, LabelGroup, LabelRow, Ladder, LaneDivider,
                          PixelRect, Role, ValueScale, format_size, parse_separator, separator_gray, separator_rgb, sround)
from ..core.package import GelPackage, is_gelscribe_folder, is_plain_name, names_in, uses_image
from ..core.scheme import LabelScheme
from . import settings

TOOLS = [  # id, title, key, hint
    ("select", "Select", "V", "Click a label to edit · drag a name or the unit label to move it"),
    ("lanes", "Lane Dividers", "L", "Click between lanes · drag an end to tilt · Alt-click to delete"),
    ("ladder", "Ladder Ticks", "K", "Click a ladder band · snaps to its centre (Alt = free)"),
    ("names", "Band Names", "N", "Click a band to name it · snaps to its centre (Alt = free)"),
    ("crop", "Crop", "C", "Drag edges or corners · Enter when done"),
    ("straighten", "Straighten", "R", "Drag along a band row or a lane edge · the image turns to level it"),
    ("pan", "Pan", "H", "Drag to move · Ctrl+scroll or pinch to zoom"),
]
TOOL_TITLE = {t[0]: t[1] for t in TOOLS}
TOOL_HINT = {t[0]: t[3] for t in TOOLS}
FULL_IMAGE_TOOLS = ("crop", "straighten")
TOOL_TAB = {"lanes": "labels", "ladder": "ladder", "names": "names", "crop": "figure", "straighten": "figure"}


class _Job:
    """One background build of exact pixels for a project's angles (see Workspace.build_exact)."""

    def __init__(self, project: GelProject):
        self.project = project
        self.cancel = threading.Event()
        self.done = threading.Event()
        self.main = None
        self.strips: list = []
        self.main_out = None
        self.strip_out: list = []
        self.error: Optional[BaseException] = None


class _Run(QRunnable):
    def __init__(self, job: _Job, signal):
        super().__init__()
        self.job, self.signal = job, signal

    def run(self):
        job, p = self.job, self.job.project
        try:
            source, wanted = job.main
            if wanted and not job.cancel.is_set():
                w = WorkingImage(source, p)
                dark_box: list = []
                side = threading.Thread(target=lambda: dark_box.append(w.darkness(p.display.bands_dark)))
                side.start()   # (the snapping map is independent of the picture: made alongside it)
                view = w.view_image(p, p.view_enhance) if not job.cancel.is_set() else None
                side.join()
                dark = dark_box[0]
                key = (id(source.data), p.strict, p.rotate_deg, p.fill_padding, p.fill_mode, p.fill_value,
                       p.display.bands_dark, p.turn)
                job.main_out = (w, dark, key, view)
            for k, old in job.strips:
                if job.cancel.is_set():
                    break
                s = p.strips[k - 1]
                w = WorkingImage(old["source"], p.strip_project(k))
                d = s.display
                key = (old["key"][0], p.is_strict(k), s.rotate_deg, s.turn, p.fill_padding, p.fill_mode, p.fill_value,
                       d.bands_dark)
                c = {"key": key, "source": old["source"], "working": w, "dark": w.darkness(d.bands_dark),
                     "view": w.view_image(p.strip_project(k)), "qview": None, "image": s.image,
                     "rot": 0.0 if p.is_strict(k) else s.rotate_deg}
                c["view_key"] = (key, d.black, d.white, d.gamma, d.invert)
                job.strip_out.append((k, c))
        except BaseException as e:   # (the main thread goes on with the exact pixels made there)
            job.error = e
        job.done.set()
        try:
            self.signal.emit(job)
        except RuntimeError:   # the window was closed meanwhile
            pass


class _Step(QUndoCommand):
    def __init__(self, ws: "Workspace", before: GelProject, after: GelProject, name: str):
        super().__init__(name)
        self.ws, self.before, self.after = ws, before, after
        self._done = False   # the first redo is the edit itself; later ones replay it

    def redo(self):
        self.ws._set_project(self.after, replay=self._done)
        self._done = True

    def undo(self):
        self.ws._set_project(self.before, replay=True)


class _GelsStep(QUndoCommand):
    """Adding or removing a gel: the project and the gels' images go back together."""

    def __init__(self, ws: "Workspace", before: GelProject, before_images: dict, after: GelProject, after_images: dict,
                 name: str):
        super().__init__(name)
        self.ws, self.before, self.before_images, self.after, self.after_images = ws, before, before_images, after, after_images
        self._done = False

    def redo(self):
        self.ws.strip_images = dict(self.after_images)
        self.ws._set_project(self.after, replay=self._done)
        self._done = True

    def undo(self):
        self.ws.strip_images = dict(self.before_images)
        self.ws._set_project(self.before, replay=True)


#: set_strict's default: the gel that is chosen
_CHOSEN = object()
#: the longest side of the small copy of a gel's picture that is turned while its angle is being changed
PREVIEW_SIDE = 1000


class Workspace(QObject):
    changed = Signal()            # the project (or image) changed: repaint, refresh panels
    view_changed = Signal()       # tool, tab, guides, inspector
    message = Signal(str)         # a warning to show
    ask_straighten = Signal(float)    # a straighten waiting for Strict to go off
    ask_contrast_export = Signal()
    ask_export_dpi = Signal(float)
    zoom_request = Signal(str)    # "fit", "actual", "in", "out"
    reveal_contrast = Signal()
    _built = Signal(object)       # a background build of exact pixels finished (from its thread)

    def __init__(self, package: Optional[GelPackage] = None, folder: Optional[Path] = None):
        super().__init__()
        self.settings = settings()
        self.project = package.project.copy() if package else GelProject()
        self.image_data: Optional[bytes] = package.image_data if package else None
        #: the stacked gels' images by file name, byte-for-byte
        self.strip_images: dict = dict(package.strip_images) if package else {}
        self._active: Optional[int] = None   # the gel the Figure tab works on; see active_strip
        self.align_note: Optional[str] = None
        self.folder = Path(folder) if folder else None
        self.undo = QUndoStack(self)
        self._gesture_start: Optional[GelProject] = None
        self.tool = "lanes"
        #: whether the canvas shows one gel on its own (the switcher's Gel N) instead of the figure; view state, not saved
        self._shows_gel = False
        #: why the last tool change didn't happen, for the status line
        self.tool_note: Optional[str] = None
        #: the chosen stacked gel's crop when the Crop tool began, for Esc to put back (see remember_crop)
        self._crop_backup: Optional[tuple] = None
        self._single = None   # the gel with the lanes as a figure of its own (shown_stack, shown_layout), until the next change
        self.inspector_tab = "labels"
        self.inspector_visible = True
        self.show_guides = True
        self.snapping = True
        self.selection = None            # ("text", Role) | ("divider", i) | ("tick", i) | ("name", i)
        self.placing_unit = False
        self.preset_id = str(self.settings.value("lastLadderPreset", "thermo-pageruler-prestained"))
        if self.project.ladder and self.project.ladder.name:
            p = lib.find_by_display_name(self.project.ladder.name)
            if p:
                self.preset_id = p.id
        self.recent_names: list[str] = list(self.settings.value("recentNames", [], type=list))
        self.last_error: Optional[str] = None
        self.quick_labels = ql.shorthand(self.project)
        self.typing_quick = False
        self._quick_pause = QTimer(self)
        self._quick_pause.setSingleShot(True)
        self._quick_pause.setInterval(1000)
        self._quick_pause.timeout.connect(lambda: self.finish_quick_labels(normalize=False))
        # caches
        self.source: Optional[SourceImage] = None
        self.working: Optional[WorkingImage] = None
        self.dark = None
        self.view_full: Optional[QImage] = None
        self.view_array = None
        self.layout: Optional[FigureLayout] = None
        self.stack: Optional[stacked.StackGeometry] = None
        self.image_w = self.image_h = 0
        self._image_key = self._view_key = self._stats_key = None
        self._stats = None
        self._strip_cache: dict = {}       # by image name: key, source, working, dark, view key, view array, view image
        self._strip_failures: dict = {}    # image name → the settings it failed to decode with, reported once
        #: each stacked gel's working-image size, index-aligned with project.strips; None for a gel that can't be read
        self.strip_sizes: list[Optional[tuple[int, int]]] = []
        #: why the gel with the lanes can't be shown ("Gel 1's image (file) can't be read."), None when it can
        self.main_problem: Optional[str] = None
        self._main_failed = None           # the settings the main image failed to decode with, reported once
        self._digests: dict = {}           # id(image bytes) → (the bytes, their SHA-256), so a panel refresh doesn't hash
        self._seen: dict = {}              # image file name → its bytes, for every image this project has had this session
        self._composed = (None, None)
        # a gel's angle while it is being changed (see live_rotation): its exact pixels wait, and the picture built at the
        # last exact angle is shown turned by the difference. The angles the pixels were built at, and small copies of
        # the pictures to turn (quick to draw).
        self._lazy = False
        self._built_rot = 0.0
        self._small: dict = {}
        self._settle_timer = QTimer(self)
        self._settle_timer.setSingleShot(True)
        self._settle_timer.setInterval(250)
        self._settle_timer.timeout.connect(self.build_exact)
        self._job: Optional[_Job] = None   # the background build of the exact pixels, while one runs
        self._keep_lazy = False
        self._built.connect(self._land)
        self.refresh_caches()
        if package is not None:   # a loaded project: rows and marks that don't fit their gels (a damaged file) are put right
            before = self.project.copy()
            self.project.normalize((self.image_w, self.image_h) if self.working is not None else None, self.strip_sizes)
            if self.project != before:
                self.refresh_caches()
        self._note_images()

    # ------------------------------------------------------------------------------------------------ document

    @property
    def has_image(self) -> bool:
        return self.image_data is not None

    @property
    def title(self) -> str:
        return self.folder.name if self.folder else "Untitled"

    @property
    def dirty(self) -> bool:
        return not self.undo.isClean() or (self.has_image and self.folder is None)

    def package(self) -> GelPackage:
        return GelPackage(self.project.copy(), self.image_data, dict(self.strip_images))

    def save_to(self, folder: Path) -> None:
        """Writes the project to a .gelscribe folder. Raises ProjectError (or OSError), having written nothing, when it
        can't be saved there."""
        self.finish_quick_labels(normalize=False)
        self._note_images()
        self.package().write(folder)
        self._drop_removed_copies(Path(folder))
        self.folder = Path(folder)
        self.undo.setClean()
        self.view_changed.emit()

    def _note_images(self) -> None:
        """Remembers every image the project has had this session, by file name, for _drop_removed_copies."""
        if self.image_data is not None:
            self._seen[self.project.image] = self.image_data
        self._seen.update(self.strip_images)

    def _drop_removed_copies(self, folder: Path) -> None:
        """The copy in a .gelscribe package of a gel that was taken out goes at the next save, unless a gel is stored under
        that name (ignoring case) or the file isn't that very image. The original it came from is never touched, and in a
        plain folder (a project.json that isn't inside a .gelscribe package) no image is ever deleted: they're the user's."""
        if not is_gelscribe_folder(folder):
            return
        for name, data in list(self._seen.items()):
            if uses_image(self.project, name) or not is_plain_name(name):
                continue
            try:
                if (folder / name).is_file() and (folder / name).read_bytes() == data:
                    (folder / name).unlink()
            except OSError:
                continue   # left where it is
            del self._seen[name]

    def dispose(self) -> None:
        """Its window is closing: nothing more reaches it (a dirty undo stack still signals as it's destroyed)."""
        self._quick_pause.stop()
        self._settle_timer.stop()
        self._drop_job()
        self.undo.blockSignals(True)
        self.blockSignals(True)

    def adopt_image(self, path: Path) -> None:
        """Starts the project around an image (the drop zone, Choose Image). Undoable, back to the empty window."""
        pkg = GelPackage.create_from(path)
        before = self.project.copy()
        old_data = self.image_data
        cmd = _ImageStep(self, before, old_data, pkg.project, pkg.image_data)
        self.undo.push(cmd)

    # ------------------------------------------------------------------------------------------------ edits

    def _set_project(self, p: GelProject, replay: bool = False) -> None:
        """Makes p the project. The chosen gel stays chosen (found again by its image, wherever it sits now); an undo or
        redo also drops the selection, whose numbers may mean other ticks or names in the other state."""
        chosen = self._chosen_image()
        if not self._keep_lazy:
            self._lazy = False   # an undo, redo or loaded project: exact pixels
        self.project = p.copy()
        self._active = next((i + 1 for i, s in enumerate(p.strips) if s.image == chosen), None) if chosen else None
        if replay:
            self.selection = None
        self._changed()

    def _chosen_image(self) -> Optional[str]:
        """The file name of the chosen stacked gel; None while it's the gel with the lanes."""
        k = self.active_strip
        return self.project.strips[k - 1].image if k is not None else None

    def _changed(self) -> None:
        self.refresh_caches()
        if not self.project.strips:
            self._shows_gel = False   # one gel left: no switcher, no gel view (and it doesn't come back with the gel)
        self.changed.emit()

    def edit(self, name: str, fn: Callable[[GelProject], None]) -> None:
        if self.typing_quick:
            self.finish_quick_labels(normalize=False)   # close the typing run first: clean undo
        if self._gesture_start is not None:
            self.end_gesture("Edit")
        self._lazy = False   # (an edit that is not the live dragging of an angle gets its exact pixels now)
        self._drop_job()
        before = self.project.copy()
        after = self.project.copy()
        fn(after)
        if after == before:
            return
        self.undo.push(_Step(self, before, after, name))

    def live(self, fn: Callable[[GelProject], None]) -> None:
        """Live, unrecorded update during a drag; end_gesture makes it one undo step."""
        if self._gesture_start is None:
            self._gesture_start = self.project.copy()
        fn(self.project)
        self._changed()

    def end_gesture(self, name: str) -> None:
        start, self._gesture_start = self._gesture_start, None
        if start is None or start == self.project:
            return
        end = self.project.copy()
        self.project = start
        self.undo.push(_Step(self, start, end, name))

    # ------------------------------------------------------------------------------------------------ caches

    def refresh_caches(self) -> None:
        self._single = None
        if self.image_data is None:
            self.source = self.working = self.dark = self.view_full = self.view_array = self.layout = None
            self.stack = None
            self.image_w = self.image_h = 0
            self._image_key = self._view_key = None
            self.strip_sizes = []
            self.main_problem = None
            return
        p = self.project
        key = (id(self.image_data), p.strict, p.rotate_deg, p.fill_padding, p.fill_mode, p.fill_value,
               p.display.bands_dark, p.turn)
        # only the angle changed while it is being dragged: the pixels for it are made when it stops (settle)
        only_angle = (self._lazy and self.working is not None and self._image_key is not None
                      and key[:2] + key[3:] == self._image_key[:2] + self._image_key[3:])
        if only_angle:
            key = self._image_key
        if key != self._image_key:
            if key == self._main_failed:   # told already: not tried again on every redraw
                return
            try:
                if self.source is None or self.source.data is not self.image_data:
                    self.source = SourceImage(self.image_data)
                self.working = WorkingImage(self.source, p)
                self.dark = self.working.darkness(p.display.bands_dark)
            except Exception:   # an unreadable image
                self._main_failed = key
                self.source = self.working = self.dark = self.view_full = self.view_array = self.layout = None
                self.stack = None
                self.image_w = self.image_h = 0
                self._image_key = self._view_key = None
                self.main_problem = f"{self.gel_name(None)}'s image ({p.image}) can't be read."
                self.message.emit(self.main_problem)
                return
            self.main_problem = None
            self._main_failed = None
            self.image_w, self.image_h = self.working.width, self.working.height
            self._image_key, self._view_key = key, None
            self._built_rot = p.effective_rotation
        d = p.display
        vk = (key, p.view_enhance, d.black, d.white, d.gamma, d.invert)
        if vk != self._view_key:
            self.view_array = self.working.view_image(p, p.view_enhance)
            self.view_full = render.qimage(self.view_array)
            self._view_key = vk
        self._refresh_strip_caches(p)
        self.stack = stacked.StackGeometry(p, self.image_w, self.image_h, self.strip_sizes)
        self.layout = make_layout(p, self.image_w, self.image_h, self.stack)

    # ------------------------------------------------------------------------------------------------ rotation preview

    def pending_rotation(self, strip: Optional[int] = None) -> float:
        """How far (degrees, counter-clockwise) a gel's angle is ahead of its built pixels: 0 when they are exact. While it is not
        0 the canvas draws the gel's picture turned by it."""
        p = self.project
        if strip is None:
            return p.effective_rotation - self._built_rot if self.working is not None else 0.0
        c = self._strip_cache.get(p.strips[strip - 1].image) if 1 <= strip <= len(p.strips) else None
        if c is None:
            return 0.0
        return (0.0 if p.is_strict(strip) else p.strips[strip - 1].rotate_deg) - c.get("rot", 0.0)

    def figure_fill(self, strip: Optional[int] = None) -> float:
        """The gray (0 to 1) the corners an angle uncovers are filled with, for a gel."""
        gel = self.working if strip is None else self.strip_working(strip)
        return gel.figure_fill if gel is not None else 1.0

    def preview_image(self, strip: Optional[int] = None) -> Optional[QImage]:
        """A gel's picture (as built, at its last exact angle) at a size that is quick to turn and draw, for the preview of an
        angle being changed; cached until the picture changes. The canvas draws it over the whole gel's frame."""
        full = self.view_full if strip is None else self._strip(strip, "qview")
        if full is None:
            return None
        key = (id(full), full.width(), full.height())
        hit = self._small.get(strip)
        if hit is None or hit[0] != key:
            long = max(full.width(), full.height())
            small = full if long <= PREVIEW_SIDE else full.scaled(
                max(1, round(full.width() * PREVIEW_SIDE / long)), max(1, round(full.height() * PREVIEW_SIDE / long)),
                Qt.AspectRatioMode.IgnoreAspectRatio, Qt.TransformationMode.SmoothTransformation)
            hit = self._small[strip] = (key, small)
        return hit[1]

    @property
    def rotation_pending(self) -> bool:
        return self.working is not None and (self.pending_rotation(None) != 0 or
                                             any(self.pending_rotation(k + 1) != 0 for k in range(len(self.project.strips))))

    def _drop_job(self) -> None:
        if self._job is not None:
            self._job.cancel.set()
            self._job = None

    def build_exact(self) -> None:
        """Starts making the exact pixels for the angles that are only being previewed, on another thread (a newer angle drops
        the job and the pixels it was making); the window stays alive and the preview stays up until they land."""
        self._settle_timer.stop()
        if not self.rotation_pending or self.source is None:
            return
        self._drop_job()
        p = self.project.copy()
        job = _Job(p)
        job.main = (self.source, self.pending_rotation(None) != 0)
        job.strips = []
        for k in range(1, len(p.strips) + 1):
            c = self._strip_cache.get(p.strips[k - 1].image)
            if c is not None and self.pending_rotation(k) != 0:
                job.strips.append((k, c))
        self._job = job
        QThreadPool.globalInstance().start(_Run(job, self._built))

    def _land(self, job: "_Job") -> None:
        """A background build finished (on the main thread): its pixels replace the previewed ones when they are still the ones
        wanted (the angles unchanged since)."""
        if job is not self._job:
            return
        self._job = None
        if job.error is not None or job.cancel.is_set():
            return
        p, q = self.project, job.project
        if job.main_out is not None:
            if p.effective_rotation != q.effective_rotation or self._image_key is None or self._image_key[0] != id(self.image_data):
                return
            working, dark, key, view = job.main_out
            self.working, self.dark = working, dark
            self._image_key, self._built_rot = key, q.effective_rotation
            d = q.display
            self.view_array, self.view_full = view, render.qimage(view)
            self._view_key = (key, q.view_enhance, d.black, d.white, d.gamma, d.invert)
        for k, c in job.strip_out:
            if k > len(p.strips) or p.strips[k - 1].image != c["image"]:
                continue
            now = 0.0 if p.is_strict(k) else p.strips[k - 1].rotate_deg
            if now != c["rot"]:
                continue
            c["qview"] = render.qimage(c["view"])
            self._strip_cache[c["image"]] = c
        self._lazy = False
        self.refresh_caches()
        self.changed.emit()

    def settle(self) -> None:
        """The exact pixels for any angle that is only being previewed, now: what exports, detection and everything that reads pixels
        want. A build in the background that is making them is waited for."""
        self._settle_timer.stop()
        self._lazy = False
        if not self.rotation_pending:
            return
        job = self._job
        if job is not None and job.done.wait(timeout=60) and job is self._job:
            self._land(job)
            if not self.rotation_pending:
                return
        self._drop_job()
        self.refresh_caches()
        self.changed.emit()

    def live_rotation(self, degrees: float) -> None:
        """Live, while the angle of the chosen gel is dragged (a slider) or stepped: the picture shows at once as the last exact one
        turned by the difference, and the exact pixels are made, on another thread, when the angle has held still for a moment
        (or end_rotation)."""
        d = min(max(degrees, -45), 45)
        k = self.active_strip
        size = self.gel_size(k)
        if size is None:
            return
        w, h = size
        self._lazy = True
        self._drop_job()   # whatever was being made is for an older angle
        if k is not None:
            self.live(lambda p: ops.set_strip_rotation(p, k, d, w, h))
        else:
            self.live(lambda p: ops.set_rotation(p, d, self.image_w, self.image_h))
        self._settle_timer.start()

    def end_rotation(self) -> None:
        """The change of angle is over: one undo step, and the exact pixels are made (in the background)."""
        self._settle_timer.stop()
        self._lazy = True
        self._keep_lazy = True   # (the undo step's first redo must not ask for them on this thread)
        try:
            self.end_gesture("Rotate Gel" if self.active_strip is not None else "Rotate")
        finally:
            self._keep_lazy = False
        self.build_exact()

    # ------------------------------------------------------------------------------------------------ stacked gels

    def _refresh_strip_caches(self, p: GelProject) -> None:
        sizes: list[Optional[tuple[int, int]]] = []
        for i, s in enumerate(p.strips):
            data = self.strip_images.get(s.image)
            c = self._strip_cache.get(s.image)
            if data is not None:
                key = (id(data), p.is_strict(i + 1), s.rotate_deg, s.turn, p.fill_padding, p.fill_mode, p.fill_value,
                       s.display.bands_dark)
                if (self._lazy and c is not None and c["key"][:2] + c["key"][3:] == key[:2] + key[3:]):
                    key = c["key"]   # only its angle changed, while it is being dragged: see refresh_caches
                if c is None or c["key"] != key:
                    c = self._decode_strip(p, i + 1, data, key, c)
            else:
                c = None   # no picture stored for this gel
            if c is None:   # it can't be read: its place stays, empty, so no other gel's image moves into it
                self._strip_cache.pop(s.image, None)
                sizes.append(None)
                continue
            d = s.display
            vk = (c["key"], d.black, d.white, d.gamma, d.invert)
            if c["view_key"] != vk:
                c["view"] = c["working"].view_image(p.strip_project(i + 1))
                c["qview"] = render.qimage(c["view"])
                c["view_key"] = vk
            self._strip_cache[s.image] = c
            sizes.append((c["working"].width, c["working"].height))
        names = {s.image for s in p.strips}
        self._strip_cache = {k: v for k, v in self._strip_cache.items() if k in names}
        self._strip_failures = {k: v for k, v in self._strip_failures.items() if k in names}
        self.strip_sizes = sizes

    def _decode_strip(self, p: GelProject, k: int, data: bytes, key: tuple, old: Optional[dict]) -> Optional[dict]:
        """Gel k's decoded images for these settings (the old ones' source is kept when only a setting changed), or None
        when it can't be read; that is said once."""
        s = p.strips[k - 1]
        if self._strip_failures.get(s.image) == key:
            return None
        try:
            source = old["source"] if old is not None and old["source"].data is data else SourceImage(data)
            w = WorkingImage(source, p.strip_project(k))
            return {"key": key, "source": source, "working": w, "dark": w.darkness(s.display.bands_dark),
                    "view_key": None, "view": None, "qview": None, "rot": 0.0 if p.is_strict(k) else s.rotate_deg}
        except Exception:   # an unreadable image
            self._strip_failures[s.image] = key
            self.message.emit(stacked.unreadable_message(p, k))
            return None

    @property
    def unreadable_gel(self) -> Optional[str]:
        """Why the figure can't be made: "Gel N's image (file) can't be read." for the gel nearest the top whose image
        can't be read (N counted from the top), or None when every gel is there."""
        p = self.project
        bad: list[Optional[int]] = [k + 1 for k, size in enumerate(self.strip_sizes) if size is None]
        if self.main_problem:
            bad.append(None)
        if not bad:
            return None
        first = min(bad, key=p.position_of)
        return self.main_problem if first is None else stacked.unreadable_message(p, first)

    def _strip(self, k: Optional[int], what: str):
        if k is None or not 1 <= k <= len(self.project.strips):
            return None
        c = self._strip_cache.get(self.project.strips[k - 1].image)
        return c[what] if c else None

    def strip_working(self, k: int) -> Optional[WorkingImage]:
        return self._strip(k, "working")

    @property
    def strip_workings(self) -> list[Optional[WorkingImage]]:
        """Every stacked gel's working image by its number in strips, None for one that can't be read: no gel's picture
        takes another's place."""
        return [self.strip_working(k + 1) for k in range(len(self.project.strips))]

    def gel_size(self, strip: Optional[int]) -> Optional[tuple[int, int]]:
        """A gel's working-image size (None = the gel with the lanes); None while it can't be read."""
        if strip is None:
            return (self.image_w, self.image_h) if self.working is not None else None
        return self.strip_sizes[strip - 1] if 1 <= strip <= len(self.strip_sizes) else None

    def gel_name(self, strip: Optional[int]) -> str:
        """A gel's name: its place in the stack, counted from the top (None = the gel with the lanes)."""
        return f"Gel {self.project.position_of(strip) + 1}"

    @property
    def active_strip(self) -> Optional[int]:
        """The gel the Figure tab, crop and straighten work on: None = the one with the lanes, else its number in
        project.strips."""
        k = self._active
        return k if k is not None and 1 <= k <= len(self.project.strips) else None

    @active_strip.setter
    def active_strip(self, k: Optional[int]) -> None:
        self._active = k

    def choose_gel(self, k: Optional[int]) -> None:
        """Makes gel k (None = the gel with the lanes) the chosen one. With a gel view showing, the view moves to it (and
        zooms to fit); on the figure it only chooses."""
        if k != self.active_strip:
            self.active_strip = k
            self.align_note = None
            self.selection = None
            self.remember_crop()
            if self._shows_gel:
                self._gel_view_changed()
            self.view_changed.emit()

    @property
    def shows_gel(self) -> bool:
        """Whether one gel is shown on its own: the switcher's Gel N rather than Figure (only with several gels)."""
        return self._shows_gel and bool(self.project.strips)

    @property
    def views_other_gel(self) -> bool:
        """Whether the gel on view is a stacked one, shown whole; the gel with the lanes is a figure of its own."""
        return self.shows_gel and self.active_strip is not None

    @property
    def views_lanes_gel(self) -> bool:
        return self.shows_gel and self.active_strip is None

    @property
    def lanes_tool_off(self) -> bool:
        """The lane dividers belong to the gel with the lanes, so they can't be set while another gel is on view. Side by side
        every gel has its own lanes, set in that gel's own view; the figure itself has no dividers to set."""
        return (not self.shows_gel) if self.project.is_side_by_side else self.views_other_gel

    @property
    def lanes_tool_note(self) -> str:
        if self.project.is_side_by_side:
            return "Lane dividers are set in each gel's own view: choose a gel in the switcher above the figure."
        return f"Lane dividers are set on {self.gel_name(None)}, the gel with the lanes."

    @property
    def lane_gel(self) -> Optional[int]:
        """The gel whose lane dividers the Lane tool edits: the gel on view when the gels sit side by side, else the gel with the
        lanes (None)."""
        return self.active_strip if self.project.is_side_by_side and self.shows_gel else None

    @property
    def lane_set(self):
        """Its dividers and lanes."""
        return self.project.lanes_of(self.lane_gel)

    @property
    def lane_gel_size(self) -> tuple[int, int]:
        return self.gel_size(self.lane_gel) or (self.image_w, self.image_h)

    @property
    def lane_rows(self) -> tuple[float, float]:
        """The rows of that gel the figure keeps (where the divider ends are)."""
        k = self.lane_gel
        if k is not None and 1 <= k <= len(self.project.strips):
            return self.project.strips[k - 1].used_rows(self.lane_gel_size[1])
        c = self.crop
        return c.y0, c.y1

    def show_gel(self, k: Optional[int]) -> None:
        """The switcher's Gel N: gel k (None = the gel with the lanes) is chosen and shown on its own, zoomed to fit."""
        if not self.project.strips or (k is not None and not 1 <= k <= len(self.project.strips)):
            return
        if k != self.active_strip:
            self.active_strip = k
            self.align_note = None
        self._shows_gel = True
        self.selection = None
        self.remember_crop()
        self._gel_view_changed()
        self.view_changed.emit()

    def show_figure(self) -> None:
        """The switcher's Figure: the stacked figure again, zoomed to fit. The chosen gel stays chosen."""
        self._shows_gel = False
        if self.lanes_tool_off and self.tool == "lanes":   # side by side the figure has no dividers to set
            self.tool = "select"
        self.selection = None
        self.zoom_request.emit("fit")
        self.view_changed.emit()

    def _gel_view_changed(self) -> None:
        """A gel view opened or moved to another gel: the lane divider tool is only for the gel with the lanes, and the
        view fits."""
        if self.lanes_tool_off and self.tool == "lanes":
            self.tool = "select"
        self.selection = None
        self.zoom_request.emit("fit")

    @property
    def shown_stack(self) -> Optional[stacked.StackGeometry]:
        """The stack the canvas draws the figure from: the whole figure's, or for the gel with the lanes on its own, a stack
        of that gel alone."""
        if not self.views_lanes_gel or self.working is None:
            return self.stack
        return self._lanes_alone()[0]

    @property
    def shown_layout(self) -> Optional[FigureLayout]:
        if not self.views_lanes_gel or self.working is None:
            return self.layout
        return self._lanes_alone()[1]

    def _lanes_alone(self):
        if self._single is None:
            alone = self.project.copy()
            alone.arrangement = "top_to_bottom"   # on its own it is a figure of its own, drawn in its own pixels
            stack = stacked.StackGeometry(alone, self.image_w, self.image_h, [])
            self._single = (stack, make_layout(self.project, self.image_w, self.image_h, stack))
        return self._single

    @property
    def active_name(self) -> str:
        return "Image" if not self.project.strips else self.gel_name(self.active_strip)

    @property
    def active_working(self) -> Optional[WorkingImage]:
        return self.working if self.active_strip is None else self.strip_working(self.active_strip)

    @property
    def active_view(self) -> Optional[QImage]:
        return self.view_full if self.active_strip is None else self._strip(self.active_strip, "qview")

    @property
    def active_size(self) -> tuple[int, int]:
        """The chosen gel's working-image size; 0 × 0 while that gel can't be read."""
        return self.gel_size(self.active_strip) or (0, 0)

    @property
    def active_display(self) -> DisplaySettings:
        k = self.active_strip
        return self.project.display if k is None else self.project.strips[k - 1].display

    @property
    def active_strict(self) -> bool:
        """Whether the chosen gel keeps its original pixels."""
        return self.project.is_strict(self.active_strip)

    @property
    def active_rotation(self) -> float:
        k = self.active_strip
        return self.project.rotate_deg if k is None else self.project.strips[k - 1].rotate_deg

    @property
    def active_strip_rect(self) -> Optional[PixelRect]:
        """The chosen stacked gel's kept columns and rows in its own pixels: its own where it has set them, else the columns
        under the lanes gel's crop through the alignment."""
        k = self.active_strip
        size = self.gel_size(k) if k is not None else None
        if k is None or size is None or self.working is None:
            return None
        left, right = self.project.kept_columns(k, size[0], self.image_w, self.image_h)
        top, bottom = self.project.strips[k - 1].used_rows(size[1])
        return PixelRect(left, top, right, bottom)

    def figure_y(self, strip: Optional[int], y: float) -> Optional[float]:
        g = self.shown_stack
        return g.figure_y(strip, y, inside=False) if g else (y if strip is None else None)

    def clamp_mark_y(self, y: float, strip: Optional[int] = None) -> float:
        """Row y of gel strip (None = the one with the lanes) moved into the rows that gel shows in the figure: a tick or
        name belongs between them."""
        size = self.gel_size(strip)
        return y if size is None else self.project.clamp_y(y, strip, *size)

    def _snapped_in(self, q, x: float, fy: float, free: bool) -> float:
        """Row fy of the figure in a gel's own pixels, kept inside the rows that gel shows, snapped to a band there."""
        lx, ly = q.to_piece(x, min(max(fy, q.top), q.bottom - 1))
        d = self._strip(q.strip, "dark")
        y = float(sround(ly))
        if self.snapping and not free and d is not None:
            side = self.project.is_side_by_side
            base = self.project.lanes_of(q.strip).width if side else self.project.lanes.width
            w = (base if base > 0 else 100) * (1.0 if side else q.scale)
            s = snap_band(d, lx, ly, w)
            y = s if s is not None else y
        return self.project.clamp_y(y, q.strip, q.width, q.height)

    def snap_in_figure(self, x: float, y: float, free: bool) -> tuple[Optional[int], float, float]:
        """Snapping in whichever gel holds figure point (x, y): that gel, y in its own pixels, and y in the figure."""
        g = self.shown_stack
        if g is not None and g.side_by_side:   # side by side: the gel under the click, any gel
            q = g.piece_at_figure_x(x, y)
            if q is not None:
                ly = self._snapped_in(q, x, y, free)
                return q.strip, ly, q.to_figure(0, ly)[1]
        q = g.piece_at_figure_y(y) if (g and g.has_strips) else None
        if q is None or q.strip is None:
            sy = self.snapped_y(x, y, free)
            return None, sy, sy
        ly = self._snapped_in(q, x, y, free)
        return q.strip, ly, q.to_figure(0, ly)[1]

    def snap_in_gel(self, strip: Optional[int], x: float, y: float, free: bool) -> float:
        """Row y of gel strip (None = the gel with the lanes) in its own pixels, kept inside the rows it shows in the figure and
        snapped to the centre of a band at column x of that gel, unless snapping is off or free."""
        y = self.clamp_mark_y(float(sround(y)), strip)
        d = self.dark if strip is None else self._strip(strip, "dark")
        if self.snapping and not free and d is not None:
            side = self.project.is_side_by_side
            base = self.project.lanes_of(strip).width if side else self.project.lanes.width
            lane_w = base if base > 0 else 100
            if strip is not None and not side:
                lane_w *= self.project.effective_alignment(strip)[1]
            s = snap_band(d, x, y, lane_w)
            y = s if s is not None else y
        return self.clamp_mark_y(y, strip)

    def gel_layers(self) -> list[tuple[stacked.Piece, Optional[QImage]]]:
        """The gels in the figure, top to bottom, each with its cached picture (the whole frame, brightness & contrast
        applied; None for one that can't be read). The canvas paints the figure from these, so moving a gel or changing
        its contrast never composes the stack again."""
        g = self.shown_stack
        if g is None or self.view_full is None:
            return []
        return [(q, self.view_full if q.strip is None else self._strip(q.strip, "qview")) for q in g.pieces]

    @property
    def line_rgb(self) -> tuple[int, int, int]:
        """The line between gels as the screen shows it: its own color when any gel is in color, else its gray level (the
        same as the composite and the exports do)."""
        views = [self.view_array] + [self._strip(k + 1, "view") for k in range(len(self.project.strips))]
        if any(v is not None and v.ndim == 3 for v in views):
            return separator_rgb(self.project.separator)
        g = separator_gray(self.project.separator)
        return g, g, g

    def display_cropped(self) -> Optional[QImage]:
        """The figure's gel composed into one picture, exactly as the stack lays it out (the canvas paints gel_layers
        instead, which is much quicker to change)."""
        if self.view_full is None:
            return None
        g = self.stack
        if g is None or not g.has_strips:
            r = self.crop
            return self.view_full.copy(int(r.x0), int(r.y0), int(r.width), int(r.height))
        key = (self._view_key, tuple(self._strip(k + 1, "view_key") for k in range(len(self.project.strips))),
               tuple(astuple(q) for q in g.pieces), tuple(g.crop.to_json()), g.separator_colour)
        if self._composed[0] != key:
            views = [self.view_array] + [self._strip(k + 1, "view") for k in range(len(self.project.strips))]
            img = stacked.view_image(views, g)
            self._composed = (key, render.qimage(img) if img is not None else None)
        return self._composed[1]

    def add_gel(self, data: bytes, name: str) -> int:
        """Adds a gel at the bottom of the stack, chooses it, and lines it up under the lanes if there are any yet. Its
        image goes in under a name no other image in the project (or its folder) has. Raises ImageError for a file that
        isn't an image GelScribe can read, such as a 32-bit floating-point one."""
        pkg = self.package()
        k = pkg.add_strip(data, name, names_in(self.folder) if self.folder else ())
        self.undo.push(_GelsStep(self, self.project.copy(), dict(self.strip_images), pkg.project, pkg.strip_images,
                                 "Add Gel"))
        self._note_images()
        self.active_strip = k
        self.inspector_tab = "figure"
        self.inspector_visible = True
        if self.project.is_side_by_side or len(self.project.lanes.centers) >= 2:
            self.auto_align()
        else:
            self.align_note = f"Place the lane dividers on {self.gel_name(None)}, then Auto-align lines this gel up."
        self.view_changed.emit()   # (a new gel doesn't keep its original pixels, so how it is stored matters to nothing yet)
        return k

    def add_gels(self, paths: list[Path]) -> list[str]:
        """Adds each image as a gel at the bottom, in order. A file that can't be added is left out, and said so in the
        list this returns (one text for each)."""
        failed = []
        for path in paths:
            try:
                self.add_gel(Path(path).read_bytes(), Path(path).name)
            except Exception as e:   # unreadable, not an image, or one GelScribe doesn't support
                failed.append(f"{Path(path).name} could not be added.\n\n{e}")
        return failed

    def remove_active_gel(self) -> None:
        """Takes the chosen gel out, with its ticks and names; the gel that takes its place is chosen next."""
        k = self.active_strip
        if k is None:
            return
        place = self.project.position_of(k)
        pkg = self.package()
        pkg.remove_strip(k)   # drops its image too, unless another gel is stored under that name
        self.undo.push(_GelsStep(self, self.project.copy(), dict(self.strip_images), pkg.project, pkg.strip_images,
                                 "Remove Gel"))
        self.selection = None
        order = self.project.stack_order
        self.active_strip = order[min(place, len(order) - 1)]
        self.align_note = None
        self.view_changed.emit()

    def set_separator(self, colour: str) -> None:
        """The line between gels: "black", "white" or a color like "#ff3300" (undoable; the same color again changes
        nothing, so registers nothing)."""
        c = parse_separator(colour)
        if c is not None:
            self.edit("Line Between Gels", lambda p: setattr(p, "separator", c))

    def set_separator_width(self, v: Optional[float]) -> None:
        """How thick the line between gels is, in points (0.25 to 10); None = as thick as the figure's lines again, following
        them. Not a number: nothing changes."""
        if v is not None:
            if not math.isfinite(v):
                return
            lo, hi = GelProject.SEPARATOR_WIDTHS
            v = min(max(v, lo), hi)
        self.edit("Line Between Gels Thickness", lambda p: setattr(p, "separator_width", v))

    def move_gel(self, src: int, dst: int) -> None:
        """Moves a gel from place src to place dst in the stack (from 0 at the top). The chosen gel stays chosen, and
        stays chosen through undo and redo."""
        self.edit("Move Gel", lambda p: ops.move_gel(p, src, dst))

    def _alignment(self, p: GelProject, k: int) -> Optional[tuple[stacked.AlignResult, Optional[str]]]:
        """Gel k lined up under the lanes of project p (as it is, or as an edit is about to make it), by that gel's own
        Keep original pixels setting: the fit, or why there is none, and a note when whole pixels fit it badly and
        stretching would do better. None when there are no lanes yet or the gel's image can't be read."""
        if p.is_side_by_side or not 1 <= k <= len(p.strips) or len(p.lanes.centers) < 2:
            return None
        c = self._strip_cache.get(p.strips[k - 1].image)
        if c is None:
            return None
        return stacked.align_gel(p, k, WorkingImage(c["source"], p.strip_project(k)))

    def _no_alignment(self, p: GelProject, k: int, r: Optional[stacked.AlignResult]) -> str:
        """What to tell the user when gel k could not be lined up (r: what _alignment gave)."""
        if len(p.lanes.centers) < 2:
            return f"Place the lane dividers on {self.gel_name(None)} first."
        if r is None:
            return stacked.unreadable_message(p, k)
        return r.message(p.position_of(k) + 1, p.is_strict(k)) or ""

    def _note(self, r: stacked.Alignment, keep: bool, hint: Optional[str] = None) -> str:
        lanes = f" ({r.worst / r.pitch * 100:.0f}% of a lane)" if r.pitch > 0 else ""
        tail = ("; keeping original pixels allows a shift only." if keep
                else (f"; stretched {(r.scale - 1) * 100:.2f}%." if r.scale != 1 else "."))
        return f"Lanes line up within {format_size(r.worst)} px{lanes}{tail}" + (f" {hint}" if hint else "")

    def _align_vertically(self, p: GelProject, k: int) -> Optional[str]:
        """Side by side, gel k lined up vertically with the gel with the lanes (the ladder bands both have, else the tops), in p.
        The note says which. None for a gel that can't be read."""
        size = self.gel_size(k)
        if size is None:
            return None
        c = p.effective_crop(self.image_w, self.image_h)
        return ops.align_vertically(p, k, (c.y0, c.y1), size[1])

    def set_arrangement(self, arrangement: str) -> None:
        """Stacks the gels top to bottom or puts them side by side (undoable). Each gel keeps its lanes, ticks, names and crop; the
        placement of each gel starts over, and going side by side lines them up by their ladder bands (or tops) straight away."""
        if arrangement == self.project.arrangement:
            return
        notes: list[str] = []

        def fn(p):
            ops.set_arrangement(p, arrangement)
            if arrangement == "side_by_side":   # gels arrive sized and lined up
                for k in range(1, len(p.strips) + 1):
                    n = self._align_vertically(p, k)
                    if n is not None:
                        notes.append(f"{self.gel_name(k)}: {n}")
        self.edit("Arrangement", fn)
        self.align_note = " ".join(notes) if notes else None
        if self.lanes_tool_off and self.tool == "lanes":
            self.tool = "select"
        self.refresh_caches()
        self.view_changed.emit()

    def auto_align(self) -> None:
        """Finds the chosen gel's lanes and lines them up under the lanes (a whole-pixel shift while that gel keeps its
        original pixels, a shift and a stretch when it doesn't). With no trustworthy fit it changes nothing and says why."""
        k = self.active_strip
        if k is None:
            return
        if self.project.is_side_by_side:   # vertical: the ladder bands both gels have, else the tops
            note: list = []
            self.edit("Auto-align Gel", lambda p: note.append(self._align_vertically(p, k)))
            self.align_note = note[0] if note else None
            self.view_changed.emit()
            return
        found = self._alignment(self.project, k)
        r, hint = found if found else (None, None)
        if r is None or r.alignment is None:
            self.align_note = self._no_alignment(self.project, k, r)
            self.view_changed.emit()
            return
        a = r.alignment

        self.edit("Auto-align Gel", lambda p: ops.align_strip(p, k, a.shift, a.scale))
        self.align_note = self._note(a, self.project.is_strict(k), hint)
        self.view_changed.emit()

    def auto_align_all(self) -> None:
        """Lines every stacked gel up under the lanes, in one step."""
        if self.project.is_side_by_side:
            notes: list[str] = []

            def vertical(p):
                for k in range(1, len(p.strips) + 1):
                    n = self._align_vertically(p, k)
                    if n is not None:
                        notes.append(f"{self.gel_name(k)}: {n}")
            self.edit("Auto-align Gels", vertical)
            self.align_note = " ".join(notes) if notes else None
            self.view_changed.emit()
            return
        if len(self.project.lanes.centers) < 2:
            self.align_note = f"Place the lane dividers on {self.gel_name(None)} first."
            self.view_changed.emit()
            return
        found, missed, hints = {}, [], []
        for k in range(1, len(self.project.strips) + 1):
            r, hint = self._alignment(self.project, k) or (None, None)
            if r is not None and r.alignment is not None:
                found[k] = r.alignment
                if hint:
                    hints.append(hint)
            else:
                missed.append(self._no_alignment(self.project, k, r))
        if found:
            def fn(p):
                for k, a in found.items():
                    ops.align_strip(p, k, a.shift, a.scale)
            self.edit("Auto-align Gels", fn)
        worst = max((a.worst for a in found.values()), default=None)
        note = (f"Lined up {len(found)} gel{'' if len(found) == 1 else 's'}; the worst lane is {format_size(worst)} px off."
                if worst is not None else "")
        self.align_note = " ".join([note] + hints + missed).strip()
        self.view_changed.emit()

    def gel_shift(self, k: Optional[int]) -> float:
        """Where a gel sits sideways: the Shift field's number (k None = the gel with the lanes, in whole pixels)."""
        if k is None:
            return 0.0 if self.project.is_side_by_side else self.project.effective_main_shift
        return self.project.effective_alignment(k)[0]

    @property
    def active_shift(self) -> float:
        return self.gel_shift(self.active_strip)

    def set_shift(self, v: float) -> None:
        """The Shift field: the chosen gel's place sideways, the gel with the lanes' too."""
        k = self.active_strip
        if k is None and self.project.is_side_by_side:
            return   # the gel with the lanes is what the others are placed against
        self.edit("Line Up Gel", lambda p: ops.place_gel(p, k, v))

    def set_scale(self, v: float) -> None:
        k = self.active_strip
        if k is None or self.project.is_strict(k):
            return
        side = self.project.is_side_by_side
        lo, hi = SIDE_SCALES if side else (0.5, 2.0)
        new = min(max(sround(v * 10000) / 10000, lo), hi)
        size = self.gel_size(k)

        def fn(p):
            if side and size is not None:   # sized about the top of what the gel shows, which stays where it is
                shift, scale = p.effective_alignment(k)
                top = p.strips[k - 1].used_rows(size[1])[0]
                p.strips[k - 1].shift = top - new * ((top - shift) / scale)
            p.strips[k - 1].scale = new
        self.edit("Stretch Gel", fn)

    def strip_scale(self, k: Optional[int]) -> float:
        """A gel's stretch in the figure; 1 for the gel with the lanes (k None), which isn't stretched."""
        return 1.0 if k is None else self.project.effective_alignment(k)[1]

    def live_strip_shift(self, k: Optional[int], v: float) -> None:
        """Live, while a gel is dragged sideways (k None = the gel with the lanes)."""
        if k is None and self.project.is_side_by_side:
            return
        if k is None or 1 <= k <= len(self.project.strips):
            self.live(lambda p: ops.place_gel(p, k, v))

    def nudge_active_gel(self, dx: float) -> None:
        """Moves the chosen gel's picture dx figure pixels to the right (left when negative); the lanes gel takes its lane
        dividers, labels, ticks and names along, and no other gel moves."""
        k = self.active_strip
        sc = self.strip_scale(k)
        self.edit("Nudge Gel", lambda p: ops.place_gel(
            p, k, (p.effective_main_shift if k is None else p.strips[k - 1].shift) - sc * dx))

    def nudge_active_gel_rows(self, dy: float) -> None:
        """Moves the chosen gel's picture dy figure rows down (up when negative) against the gel with the lanes, side by side."""
        k = self.active_strip
        if k is None or not self.project.is_side_by_side:
            return
        sc = self.strip_scale(k)
        self.edit("Nudge Gel", lambda p: ops.place_gel(p, k, p.strips[k - 1].shift - sc * dy))

    def live_strip_rows(self, top: float, bottom: float) -> None:
        """Live, while only the chosen gel's rows are dragged: whole rows inside the gel, at least 8 of them. A drag that
        stays beyond one end of the gel has no rows to take, so the gel keeps the rows it had."""
        k = self.active_strip
        h = self.active_size[1]
        if k is None or h <= 0:
            return
        t, b = min(max(top, 0), h), min(max(bottom, 0), h)
        if not t < b:
            return
        self.live(lambda p: ops.set_strip_rows(p, k, float(sround(max(0, min(t, b - 8)))),
                                               float(sround(min(h, max(b, t + 8)))), h))

    def live_strip_crop(self, r: PixelRect) -> None:
        """Live, while the chosen gel's crop is dragged: whole pixels inside the gel, at least 8 of them each way. A drag that
        starts and stays beyond an edge of the gel has nothing to take, so the gel keeps the crop it had. Dragging only the rows
        leaves a gel that follows the lanes gel's crop following it."""
        k = self.active_strip
        size = self.gel_size(k) if k is not None else None
        if k is None or size is None or size[0] <= 0 or size[1] <= 0:
            return
        w, h = float(size[0]), float(size[1])
        l, rt = min(max(min(r.x0, r.x1), 0.0), w), min(max(max(r.x0, r.x1), 0.0), w)
        t, b = min(max(min(r.y0, r.y1), 0.0), h), min(max(max(r.y0, r.y1), 0.0), h)
        if not (l < rt and t < b):
            return
        now = self.active_strip_rect
        s = self.project.strips[k - 1]
        own = s.left is not None or s.right is not None
        left, right = float(sround(max(0.0, min(l, rt - 8)))), float(sround(min(w, max(rt, l + 8))))
        top, bottom = float(sround(max(0.0, min(t, b - 8)))), float(sround(min(h, max(b, t + 8))))

        def fn(p):
            ops.set_strip_crop(p, k, left, top, right, bottom, size[0], size[1])
            if not own and now is not None and left == now.x0 and right == now.x1:
                p.strips[k - 1].left = p.strips[k - 1].right = None
        self.live(fn)

    def remember_crop(self) -> None:
        """The chosen stacked gel's crop when the Crop tool began (or when the gel was chosen in it), for Esc to put back. The
        gel with the lanes isn't kept: its crop is made as you drag, and Esc just leaves."""
        k = self.active_strip
        if self.tool != "crop" or k is None:
            self._crop_backup = None
            return
        s = self.project.strips[k - 1]
        self._crop_backup = (s.image, s.left, s.right, s.top, s.bottom)

    def cancel_crop(self) -> None:
        """Esc in the Crop tool: the stacked gel's crop goes back to what it was when the tool began (one undo step), and the
        tool is left. Return leaves it with the crop as dragged."""
        b, self._crop_backup = self._crop_backup, None
        if b is not None:
            i = next((j for j, s in enumerate(self.project.strips) if s.image == b[0]), None)
            if i is not None:
                s = self.project.strips[i]
                if (s.left, s.right, s.top, s.bottom) != b[1:]:
                    def fn(p):
                        (p.strips[i].left, p.strips[i].right, p.strips[i].top, p.strips[i].bottom) = b[1:]
                    self.edit("Cancel Crop", fn)
        self.set_tool("select")

    def turn_active(self, q: int) -> None:
        """Turns the chosen gel by quarter turns; a half turn keeps its marks, a quarter turn clears them. Its lanes
        now run the other way, so the gels it moves are lined up again in the same step."""
        k = self.active_strip
        size = self.gel_size(k)
        if size is None:   # a gel that can't be read has no picture to turn
            return
        w, h = size
        turned = self.project.copy()
        ops.turn(turned, k, q, w, h)
        found, results = {}, {}
        for j in ([k] if k is not None else range(1, len(turned.strips) + 1)):
            got = self._alignment(turned, j)
            r = results[j] = got[0] if got else None
            if r is not None and r.alignment is not None:
                found[j] = r.alignment

        def fn(p):
            ops.turn(p, k, q, w, h)
            for j, a in found.items():
                ops.align_strip(p, j, a.shift, a.scale)
        self.edit("Turn 180°" if q % 2 == 0 else "Turn 90°", fn)
        self.selection = None   # a quarter turn took the gel's ticks and names out; a half turn moved them
        if k in found:
            self.align_note = self._note(found[k], self.project.is_strict(k))
        else:
            self.align_note = (self._no_alignment(turned, k, results[k]) if k is not None and results.get(k) is not None
                               else None)
        self.view_changed.emit()

    @property
    def pixels_kept(self) -> str:
        """"all", "some" or "none" of the gels keep their original pixels."""
        keeps = stacked.keeps_original(self.project)
        return "all" if all(keeps) else "some" if any(keeps) else "none"

    @property
    def strict_problem_detail(self) -> Optional[tuple[int, str]]:
        """The gel (its number in strips) the gels that keep their pixels can't be stacked untouched because of, and the
        sentence about it ("Gel 2 is 8-bit RGB, the gel with the lanes 8-bit gray"), or None."""
        if self.working is None:
            return None
        return stacked.strict_problem_detail_for(self.working.source, [w.source if w is not None else None
                                                                       for w in self.strip_workings], self.gel_name,
                                                 stacked.keeps_original(self.project))

    @property
    def strict_problem(self) -> Optional[str]:
        """Why the gels that keep their original pixels can't be stacked untouched ("Gel 2 is 8-bit RGB, the gel with the
        lanes 8-bit gray"), or None."""
        if self.working is None:
            return None
        return stacked.strict_problem_for(self.working.source, [w.source if w is not None else None
                                                                for w in self.strip_workings], self.gel_name,
                                          stacked.keeps_original(self.project))

    @property
    def crop(self) -> PixelRect:
        return self.project.effective_crop(self.image_w, self.image_h)

    @property
    def geometry(self):
        w, h = self.lane_gel_size
        return ops.geometry(self.project, w, h, self.lane_gel)

    @property
    def measured_background(self) -> int:
        return int(sround(self.working.background * 255)) if self.working else 255

    def _sync(self, p: GelProject) -> None:
        w, h = self.lane_gel_size
        p.sync_lane_centers(w, h, self.lane_gel)

    # ------------------------------------------------------------------------------------------------ tools

    def set_tool(self, t: str) -> None:
        self.tool_note = None
        if t == "lanes" and self.lanes_tool_off:   # another gel's view: the dividers are the lanes gel's
            self.tool_note = self.lanes_tool_note
            self.message.emit(self.tool_note)
            t = "select"
        if t == self.tool:
            if self.tool_note:
                self.view_changed.emit()
            return
        self.tool = t
        self.remember_crop()
        self.placing_unit = False
        if t in TOOL_TAB:   # the inspector follows: Ladder Ticks opens the Ladder tab, Crop the Figure tab, and so on
            self.inspector_tab = TOOL_TAB[t]
        if t == "straighten":
            self.inspector_visible = True   # the angle and Strict live there
        self.view_changed.emit()

    def set_tab(self, t: str) -> None:
        self.inspector_tab = t
        self.view_changed.emit()

    def choose_tab(self, tab: str) -> None:
        """A click on an inspector tab: the tool follows, as the tab follows the tool. Figure and Export have no tool of
        their own, so they go to Select (a stray click can't add a tick), unless you're cropping, straightening or
        panning."""
        tool = {"labels": "lanes", "ladder": "ladder", "names": "names"}.get(tab)
        if tool is None and self.tool not in (("crop", "straighten", "pan") if tab == "figure" else ("pan",)):
            tool = "select"
        if tool:
            self.set_tool(tool)
        self.set_tab(tab)

    # ------------------------------------------------------------------------------------------------ lanes

    def add_divider(self, x: float, y: float) -> None:
        w, h = self.lane_gel_size
        gel = self.lane_gel
        self.edit("Add Lane Divider", lambda p: ops.add_divider(p, x, y, w, h, gel))

    def drag_divider(self, i: int, start: LaneDivider, kind: str, a: float, b: float = 0.0) -> None:
        """Live: kind "move" (dx=a, dot_y=b), "top" or "bottom" (x=a). Dragging one end keeps the other visible end
        (at the crop's top or bottom row) in place."""
        H = float(self.lane_gel_size[1])
        ya, yb = self.lane_rows
        gel = self.lane_gel

        def line(xa, y_a, xb, y_b):
            m = 0 if abs(y_b - y_a) < 1e-6 else (xb - xa) / (y_b - y_a)
            return xa - m * y_a, xa + m * (H - y_a)

        def fn(p):
            dividers = p.lanes_of(gel).dividers
            if i >= len(dividers):
                return
            d = LaneDivider(start.x_top, start.x_bottom, start.dot_y)
            if kind == "move":
                d.x_top += a
                d.x_bottom += a
                d.dot_y = b
            elif kind == "top":
                d.x_top, d.x_bottom = line(a, ya, start.x_at(yb, H), yb)
            else:
                d.x_top, d.x_bottom = line(start.x_at(ya, H), ya, a, yb)
            dividers[i] = d
            self._sync(p)
        self.live(fn)

    def end_divider_drag(self, i: Optional[int] = None) -> Optional[int]:
        """The drag of divider i is over: the dividers are put in order again, and it's one undo step. Returns where
        divider i is now (the order may have changed under it)."""
        dividers = self.lane_set.dividers
        moved = dividers[i] if i is not None and i < len(dividers) else None
        if self._gesture_start is not None:
            dividers.sort(key=lambda d: d.x_top + d.x_bottom)
            if moved is not None:
                i = next(j for j, d in enumerate(dividers) if d is moved)
            self._sync(self.project)
        self.end_gesture("Move Lane Divider")
        return i

    def delete_divider(self, i: int) -> None:
        gel = self.lane_gel

        def fn(p):
            dividers = p.lanes_of(gel).dividers
            if i < len(dividers):
                del dividers[i]
                self._sync(p)
        self.edit("Delete Lane Divider", fn)
        self.selection = None

    def clear_dividers(self) -> None:
        gel = self.lane_gel

        def fn(p):
            l = p.lanes_of(gel)
            l.dividers.clear()
            l.centers.clear()
            p.set_lanes_of(l, gel)
        self.edit("Clear Lane Dividers", fn)
        self.selection = None

    def set_outer_lanes(self, on: bool) -> None:
        gel = self.lane_gel

        def fn(p):
            l = p.lanes_of(gel)
            l.outer_lanes = on
            p.set_lanes_of(l, gel)
            self._sync(p)
        self.edit("Edge Lanes", fn)

    # ------------------------------------------------------------------------------------------------ ladder

    @property
    def preset(self) -> Optional[lib.LadderPreset]:
        return lib.preset(self.preset_id)

    def snapped_y(self, x: float, y: float, free: bool) -> float:
        """Row y of the gel with the lanes, snapped to a band there unless free, and kept inside the rows its crop shows."""
        out = float(sround(y))
        if self.snapping and not free and self.dark is not None:
            w = self.project.lanes.width if self.project.lanes.width > 0 else 100
            s = snap_band(self.dark, x, y, w)
            out = s if s is not None else out
        return self.clamp_mark_y(out, None)

    @property
    def ladder_sizes(self) -> list[float]:
        p = self.project
        if p.ladder and p.ladder.sizes is not None:
            return p.ladder.sizes
        pr = self.preset
        if pr is None:
            return []
        key = (p.ladder.system if p.ladder else None) or self.settings.value("lastGelSystem")
        sys_ = pr.system(key) or (pr.systems[0] if pr.systems else None)
        return sys_.sizes if sys_ else pr.sizes

    def suggested_size(self, y: float, strip: Optional[int] = None) -> Optional[float]:
        """The size a new tick at y (in its gel) would get: rank from the top, through the gels that share its ladder,
        leaving out ticks a crop hides. A guess."""
        return ops.suggested_size(self.project, y, SimpleNamespace(sizes=self.ladder_sizes), strip)

    def add_tick(self, x: float, y: float, strip: Optional[int] = None) -> int:
        """A tick at y in its gel's own pixels (strip None = the gel with the lanes); x is the figure x clicked."""
        g = self.geometry
        lane = None if self.project.is_side_by_side else (g.lane_at(x, y if strip is None else self.crop.y0) if g else None)
        y = self.clamp_mark_y(y, strip)
        size = self.suggested_size(y, strip)
        pr = self.preset
        last_sys = self.settings.value("lastGelSystem")

        def fn(p):
            ops.add_tick(p, y, size, True, lane, (self.crop.x0 + self.crop.x1) / 2, strip)
            if pr is not None and p.ladder.name is None:
                p.ladder.name, p.ladder.unit = pr.display_name, pr.unit
                if p.ladder.sizes is None:
                    sys_ = pr.system(last_sys) or (pr.systems[0] if pr.systems else None)
                    p.ladder.sizes = list(sys_.sizes if sys_ else pr.sizes)
                    p.ladder.system = sys_.name if sys_ else None
        self.edit("Add Ladder Tick", fn)
        bands = self.project.ladder.bands if self.project.ladder else []
        return next((i for i, b in enumerate(bands) if b.y == y and b.size == size and b.strip == strip), len(bands) - 1)

    def set_tick(self, i: int, size: Optional[float], ignore: Optional[bool] = None) -> None:
        """A size the user chose, so it's no longer a guess."""
        def fn(p):
            if not p.ladder or i >= len(p.ladder.bands):
                return
            b = p.ladder.bands[i]
            b.size, b.auto = size, False
            if ignore is not None:
                b.ignore = ignore
                if ignore:
                    b.size = None
        self.edit("Set Band Size", fn)

    def move_tick(self, i: int, y: float) -> None:
        def fn(p):
            if p.ladder and i < len(p.ladder.bands):
                b = p.ladder.bands[i]
                size = self.gel_size(b.strip)
                b.y = y if size is None else p.clamp_y(y, b.strip, *size)
        self.live(fn)

    def drag_tick(self, i: int, x: float, fy: float, free: bool) -> None:
        """Live, while tick i is dragged to figure row fy, snapping at figure column x: it stays in its own gel."""
        bands = self.project.ladder.bands if self.project.ladder else []
        if i >= len(bands):
            return
        k = bands[i].strip
        if self.stack is not None and self.stack.side_by_side and self.stack.piece(k) is not None:   # snaps in that gel's own ladder lane
            q = self.stack.piece(k)
            own = self.project.ladder_lane_x(k, self.project.ladder.lane if self.project.ladder else 1)
            self.move_tick(i, self._snapped_in(q, q.to_figure(own[0], 0)[0] if own else x, fy, free))
        elif k is None:
            self.move_tick(i, self.snapped_y(x, fy, free))
        elif self.stack and self.stack.piece(k):
            self.move_tick(i, self._snapped_in(self.stack.piece(k), x, fy, free))

    def end_tick_drag(self, i: Optional[int] = None) -> Optional[int]:
        """The drag of tick i is over: the ticks are put in order again, and it's one undo step. Returns where tick i is
        now (the order may have changed under it)."""
        bands = self.project.ladder.bands if self.project.ladder else []
        moved = bands[i] if i is not None and i < len(bands) else None
        if self._gesture_start is not None and self.project.ladder:
            p = self.project
            bands.sort(key=lambda b: p.stack_key(b.strip, b.y))
            if moved is not None:
                i = next(j for j, b in enumerate(bands) if b is moved)
        self.end_gesture("Move Ladder Tick")
        return i

    def delete_tick(self, i: int) -> None:
        def fn(p):
            if p.ladder and i < len(p.ladder.bands):
                del p.ladder.bands[i]
        self.edit("Delete Ladder Tick", fn)
        self.selection = None

    def confirm_ticks(self) -> None:
        def fn(p):
            for b in (p.ladder.bands if p.ladder else []):
                b.auto = False
        self.edit("Confirm Band Sizes", fn)

    def assign_top_down(self) -> None:
        sizes = list(self.ladder_sizes)
        self.edit("Assign Sizes Top-Down", lambda p: p.assign_ladder(sizes))
        self._drop_selection("tick")   # the ticks are in order now: its number may mean another tick

    def set_own_ladder(self, on: bool) -> None:
        """The chosen gel's ladder sizes start again from the top of the list (on), or carry on from the gel above; the
        sizes are assigned top-down again either way, as Assign Top-Down does."""
        k = self.active_strip
        self.edit("Own Ladder" if on else "Shared Ladder", lambda p: ops.set_own_ladder(p, k, on))
        self._drop_selection("tick")

    def _drop_selection(self, *kinds: str) -> None:
        """Clears the selection when it is one of these kinds (its number may mean another item after an edit)."""
        if self.selection and self.selection[0] in kinds:
            self.selection = None

    def set_ladder_sizes(self, text: str) -> None:
        sizes = ops.parse_sizes(text)
        pr = self.preset

        def fn(p):
            if p.ladder is None:
                p.ladder = Ladder(unit=pr.unit if pr else "kDa")
            p.ladder.sizes = sizes or None
            if pr is not None and sizes != pr.sizes:
                p.ladder.name = f"Custom (from {pr.display_name})"
        self.edit("Edit Ladder Sizes", fn)

    def choose_preset(self, pid: str) -> None:
        self.preset_id = pid
        self.settings.setValue("lastLadderPreset", pid)
        pr = self.preset
        if pr is None:
            return
        last_sys = self.settings.value("lastGelSystem")

        def fn(p):
            if p.ladder is None:
                p.ladder = Ladder()
            p.ladder.name, p.ladder.unit = pr.display_name, pr.unit
            sys_ = pr.system(p.ladder.system) or pr.system(last_sys) or (pr.systems[0] if pr.systems else None)
            p.ladder.sizes = list(sys_.sizes if sys_ else pr.sizes)
            p.ladder.system = sys_.name if sys_ else None
        self.edit("Choose Ladder", fn)

    @property
    def system(self) -> Optional[lib.LadderSystem]:
        pr = self.preset
        return pr.system(self.project.ladder.system if self.project.ladder else None) if pr else None

    def choose_system(self, sid: str) -> None:
        pr = self.preset
        sys_ = next((s for s in (pr.systems if pr else []) if s.id == sid), None)
        if sys_ is None:
            return
        self.settings.setValue("lastGelSystem", sys_.name)
        self.edit("Gel & Buffer", lambda p: ops.apply_system(p, pr, sys_))

    def save_custom_ladder(self, name: str) -> None:
        sizes = list(self.ladder_sizes)
        if not sizes or not name.strip():
            return
        mine = lib.load_user()
        pid = "user-" + re.sub(r"[^a-z0-9]", "-", name.lower())
        mine = [m for m in mine if m.id != pid]
        mine.append(lib.LadderPreset(pid, name, "Mine", "", [], self.project.ladder.unit if self.project.ladder else "kDa",
                                     sizes, notes="Saved from a GelScribe project"))
        try:
            lib.save_user(mine)
        except OSError as e:
            self.message.emit(str(e))
            return
        self.preset_id = pid

        def fn(p):
            if p.ladder:
                p.ladder.name = name
        self.edit("Name Ladder", fn)

    def set_ladder_side(self, side: str) -> None:
        def fn(p):
            if p.ladder is None:
                p.ladder = Ladder()
            p.ladder.side = side
        self.edit("Ladder Side", fn)

    def set_unit(self, unit: str) -> None:
        def fn(p):
            if p.ladder is None:
                p.ladder = Ladder()
            p.ladder.unit = unit
        self.edit("Ladder Unit", fn)

    def begin_placing_unit(self) -> None:
        """Place… in the Ladder tab: the next click on the figure sets the height of the unit label."""
        self.set_tool("select")   # a change of tool ends placing, so first
        self.placing_unit = True
        self.view_changed.emit()

    def _unit_spot(self, fy: float) -> tuple[Optional[int], float]:
        """Figure row fy as a row of the gel it falls in: that gel (None = the one with the lanes) and the row in its own
        pixels, kept inside the rows it shows. The unit label goes with its gel."""
        g = self.stack
        if g is not None and g.side_by_side:   # the unit label goes with the gel the figure's ladder sizes come from
            q = next((q for q in g.pieces if self.project.is_ladder_label_gel(q.strip)), None)
        else:
            q = g.piece_at_figure_y(fy) if (g and g.has_strips) else None
        if q is None or q.strip is None:
            return None, self.clamp_mark_y(float(sround(fy)), None)
        return q.strip, self.clamp_mark_y(float(sround(q.to_piece(0, fy)[1])), q.strip)

    def set_unit_y(self, fy: Optional[float]) -> None:
        """Puts the unit label level with figure row fy (None = automatic, above the column of sizes)."""
        pr = self.preset

        def fn(p):
            if p.ladder is None:
                p.ladder = Ladder(unit=pr.unit if pr else "kDa")
            if fy is None:
                p.ladder.unit_y = p.ladder.unit_strip = None
            else:
                p.ladder.unit_strip, p.ladder.unit_y = self._unit_spot(fy)
        self.edit("Automatic Unit Label" if fy is None else "Place Unit Label", fn)
        self.placing_unit = False

    def move_unit(self, fy: float) -> None:
        """Live, while the unit label is dragged to figure row fy."""
        def fn(p):
            if p.ladder:
                p.ladder.unit_strip, p.ladder.unit_y = self._unit_spot(fy)
        self.live(fn)

    # ------------------------------------------------------------------------------------------------ names

    def add_name(self, y: float, text: str = "", strip: Optional[int] = None) -> int:
        """A name at y in its gel's own pixels (strip None = the gel with the lanes)."""
        y = self.clamp_mark_y(y, strip)
        self.edit("Add Band Name", lambda p: ops.add_annotation(p, text, y, strip=strip))
        return len(self.project.annotations) - 1

    def drag_name(self, i: int, x: float, fy: float, free: bool) -> None:
        """Live, while name i is dragged to figure row fy, snapping at figure column x: it stays in its own gel."""
        if i >= len(self.project.annotations):
            return
        a = self.project.annotations[i]
        k = a.strip
        if self.stack is not None and self.stack.side_by_side and self.stack.piece(k) is not None:
            # snaps in the lane of that gel next to the edge the name is on
            q = self.stack.piece(k)
            c = self.project.lanes_of(k).centers
            own = (c[0] if c else None) if a.side == "left" else (c[-1] if c else None)
            self.move_name(i, self._snapped_in(q, q.to_figure(own, 0)[0] if own is not None else x, fy, free))
        elif k is None:
            self.move_name(i, self.snapped_y(x, fy, free))
        elif self.stack and self.stack.piece(k):
            self.move_name(i, self._snapped_in(self.stack.piece(k), x, fy, free))

    def update_name(self, i: int, fn_a: Callable[[BandAnnotation], None]) -> None:
        def fn(p):
            if i < len(p.annotations):
                fn_a(p.annotations[i])
        self.edit("Edit Band Name", fn)

    def move_name(self, i: int, y: float) -> None:
        def fn(p):
            if i < len(p.annotations):
                a = p.annotations[i]
                size = self.gel_size(a.strip)
                a.y = y if size is None else p.clamp_y(y, a.strip, *size)
        self.live(fn)

    def delete_name(self, i: int) -> None:
        self.edit("Delete Band Name", lambda p: ops.delete_annotation(p, i))   # the other names keep their sizes
        self.selection = None

    def remember_name(self, name: str) -> None:
        name = name.strip()
        if not name:
            return
        self.recent_names = [n for n in self.recent_names if n != name and not (name.startswith(n) and len(n) < len(name))]
        self.recent_names.insert(0, name)
        self.recent_names = self.recent_names[:10]
        self.settings.setValue("recentNames", self.recent_names)

    def forget_name(self, name: str) -> None:
        self.recent_names = [n for n in self.recent_names if n != name]
        self.settings.setValue("recentNames", self.recent_names)

    # ------------------------------------------------------------------------------------------------ rotation, strict

    def set_rotation(self, degrees: float) -> None:
        d = min(max(degrees, -45), 45)
        k = self.active_strip
        if k is not None:
            size = self.gel_size(k)
            if size is None:   # a gel that can't be read has no picture to turn
                return
            w, h = size
            self.edit("Rotate Gel", lambda p: ops.set_strip_rotation(p, k, d, w, h))
            return
        self.edit("Rotate", lambda p: ops.set_rotation(p, d, self.image_w, self.image_h))

    def set_strict(self, on: bool, strip: Optional[int] = _CHOSEN) -> None:
        """Keep original pixels on or off for one gel: the chosen one unless strip names another (None = the gel with the
        lanes)."""
        k = self.active_strip if strip is _CHOSEN else strip
        sizes = list(self.strip_sizes)
        self.edit("Strict On" if on else "Strict Off",
                  lambda p: ops.set_strict(p, on, self.image_w, self.image_h, sizes, k))

    def straighten(self, a: tuple[float, float], b: tuple[float, float]) -> None:
        """Levels the line a→b (image pixels). In a Strict project this first asks to turn Strict off."""
        if math.hypot(b[0] - a[0], b[1] - a[1]) <= 20 or self.gel_size(self.active_strip) is None:
            return
        delta = ops.leveling_angle(a, b)
        if abs(delta) < 0.01:
            return
        if self.active_strict:
            self.ask_straighten.emit(delta)
            return
        self.set_rotation(self.active_rotation + delta)

    def confirm_straighten(self, delta: float) -> None:
        sizes, k, size = list(self.strip_sizes), self.active_strip, self.gel_size(self.active_strip)
        if size is None:
            return
        w, h = size

        def fn(p):
            ops.set_strict(p, False, self.image_w, self.image_h, sizes, k)
            if k is not None:
                ops.set_strip_rotation(p, k, p.strips[k - 1].rotate_deg + delta, w, h)
            else:
                ops.set_rotation(p, p.rotate_deg + delta, self.image_w, self.image_h)
        self.edit("Straighten", fn)

    # ------------------------------------------------------------------------------------------------ brightness & contrast

    @property
    def value_scale(self) -> ValueScale:
        """How the chosen gel's file stores its values, so the range can be shown in its own numbers."""
        w = self.active_working
        return w.source.scale if w else ValueScale(255)

    @property
    def imagej_range(self):
        w = self.active_working
        return w.source.imagej_range if w else None

    @property
    def gel_stats(self):
        """The chosen gel's values inside what the figure shows of it, kept until its pixels or crop change."""
        w = self.active_working
        if w is None:
            return None
        k = self.active_strip
        c = self.active_strip_rect or self.crop
        gel_key = ("main", self._image_key) if k is None else (k, self._strip(k, "key"))
        key = (gel_key, c.x0, c.y0, c.x1, c.y1)
        if key != self._stats_key:
            if self._gesture_start is not None and self._stats is not None and self._stats_key[0] == gel_key:
                return self._stats   # while its crop or place is dragged the histogram waits: it's worked out again at the end
            self._stats = w.gel_stats(c)
            self._stats_key = key
        return self._stats

    def display_range_text(self) -> str:
        s = self.value_scale
        lo, hi = self.active_display.range_in(s)
        return f"{s.format(lo)}–{s.format(hi)} of {s.format(s.max_value)}"

    def change_contrast(self, fn: Callable[[DisplaySettings], None], live: bool = False) -> None:
        k = self.active_strip

        def f(p):
            if k is not None:
                fn(p.strips[k - 1].display)
                return
            fn(p.display)
            p.view_enhance = False
        if live:
            self.live(f)
        else:
            self.edit("Brightness & Contrast", f)

    def end_contrast_change(self) -> None:
        self.end_gesture("Brightness & Contrast")

    def auto_contrast(self) -> None:
        s = self.gel_stats
        if s:
            def fn(d):
                d.black, d.white = s.auto
            self.change_contrast(fn)

    def reset_contrast(self) -> None:
        s = self.gel_stats
        if not s:
            return
        w = self.active_working
        wide = w is not None and w.source.bits > 8

        def fn(d):
            d.black, d.white = (s.range if wide else (0.0, 1.0))
            d.gamma = 1.0
        self.change_contrast(fn)

    def use_imagej_range(self) -> None:
        r, sc = self.imagej_range, self.value_scale
        if r:
            self.change_contrast(lambda d: d.set_range(r[0], r[1], sc))

    def show_brightness_contrast(self) -> None:
        self.inspector_visible = True
        self.inspector_tab = "figure"
        self.view_changed.emit()
        self.reveal_contrast.emit()

    def request_contrast_for_export(self) -> None:
        if self.active_strict:
            self.ask_contrast_export.emit()

    def set_view_enhance(self, on: bool) -> None:
        self.edit("Enhance View" if on else "Normal View", lambda p: setattr(p, "view_enhance", on))

    # ------------------------------------------------------------------------------------------------ fill, crop, figure

    def set_fill(self, mode: str, value: Optional[float] = None) -> None:
        def fn(p):
            p.fill_mode = mode
            if value is not None:
                p.fill_value = min(max(value, 0), 1)
        self.edit("Fill", fn)

    def live_fill(self, value: float) -> None:
        """Live, while the custom gray is dragged; end_gesture makes it one undo step."""
        def fn(p):
            p.fill_mode, p.fill_value = "custom", min(max(value, 0.0), 1.0)
        self.live(fn)

    def live_crop(self, r: PixelRect) -> None:
        def fn(p):
            p.crop = r.normalized(self.image_w, self.image_h)
            self._sync(p)
        self.live(fn)

    def reset_crop(self) -> None:
        k = self.active_strip
        if k is not None:
            def rows(p):
                s = p.strips[k - 1]
                s.top = s.bottom = s.left = s.right = None
            self.edit("Reset Gel Crop", rows)
            return

        def fn(p):
            p.crop = None
            self._sync(p)
        self.edit("Reset Crop", fn)

    def fit_crop_to_lanes(self) -> None:
        def fn(p):
            p.crop = ops.suggest_crop(p, self.image_w, self.image_h)
            self._sync(p)
        self.edit("Fit Crop to Lanes", fn)

    def set_style(self, name: str, fn: Callable) -> None:
        self.edit(name, lambda p: fn(p.style))

    def set_bands_dark(self, on: bool) -> None:
        k = self.active_strip
        self.edit("Band Polarity",
                  lambda p: setattr(p.display if k is None else p.strips[k - 1].display, "bands_dark", on))

    # ------------------------------------------------------------------------------------------------ labels

    def quick_labels_typed(self) -> None:
        """Typing in Quick labels: the lanes follow every keystroke, and each pause (or leaving the field) is one
        undo step. What's typed is the whole truth, row titles included."""
        self.typing_quick = True

        def fn(p):
            ops.apply_quick_labels(p, self.quick_labels, keep_titles=False)
            p.style.text_sizes = {k: v for k, v in p.style.text_sizes.items()
                                  if not k.startswith(("lane.", "group.", "rowname."))}
        self.live(fn)
        self.last_error = None   # warnings wait for a pause: half-typed braces aren't mistakes
        self._quick_pause.start()

    def finish_quick_labels(self, normalize: bool = True) -> None:
        self._quick_pause.stop()
        if self.typing_quick:
            self.typing_quick = False
            self.end_gesture("Set Lane Labels")
            probe = self.project.copy()
            w = ops.apply_quick_labels(probe, self.quick_labels, keep_titles=False).warnings
            self.last_error = w[0] if w else None
        if normalize:
            self.quick_labels = ql.shorthand(self.project)
        self.changed.emit()

    def apply_quick_labels(self) -> None:
        result = {}

        def fn(p):
            result["r"] = ops.apply_quick_labels(p, self.quick_labels)
            p.style.text_sizes = {k: v for k, v in p.style.text_sizes.items()
                                  if not k.startswith(("lane.", "group.", "rowname."))}
        self.edit("Set Lane Labels", fn)
        w = result["r"].warnings if "r" in result else []
        self.last_error = w[0] if w else None
        self.quick_labels = ql.shorthand(self.project)
        self.changed.emit()

    def text_for(self, role: Role) -> str:
        p = self.project
        k = role.kind
        if k == "title":
            return p.title or ""
        if k == "rowName":
            return (p.rows[role.a].name or "") if role.a < len(p.rows) else ""
        if k == "laneLabel":
            r = p.rows[role.a] if role.a < len(p.rows) else None
            return r.labels[role.b - 1] if r and role.b <= len(r.labels) else ""
        if k == "groupLabel":
            r = p.rows[role.a] if role.a < len(p.rows) else None
            return r.groups[role.b].text if r and role.b < len(r.groups) else ""
        if k == "ladderLabel":
            b = p.ladder.bands[role.a] if p.ladder and role.a < len(p.ladder.bands) else None
            return f"{b.size:g}" if b and b.size is not None else ""
        if k == "ladderUnit":
            return p.ladder.unit if p.ladder else "kDa"
        if k == "annotation":
            return p.annotations[role.a].text if role.a < len(p.annotations) else ""
        return ""

    def set_text(self, role: Role, value: str) -> None:
        def fn(p):
            k = role.kind
            if k == "title":
                p.title = value
            elif k == "rowName" and role.a < len(p.rows):
                p.rows[role.a].name = value or None
            elif k == "laneLabel" and role.a < len(p.rows):
                r = p.rows[role.a]
                if len(r.labels) < role.b:
                    r.labels += [""] * (role.b - len(r.labels))
                r.labels[role.b - 1] = value
            elif k == "groupLabel" and role.a < len(p.rows) and role.b < len(p.rows[role.a].groups):
                p.rows[role.a].groups[role.b].text = value
            elif k == "ladderLabel" and p.ladder and role.a < len(p.ladder.bands):
                try:
                    p.ladder.bands[role.a].size = float(value.replace(",", "."))
                except ValueError:
                    pass
            elif k == "ladderUnit" and p.ladder:
                p.ladder.unit = value
            elif k == "annotation" and role.a < len(p.annotations):
                p.annotations[role.a].text = value
        self.edit("Edit Label", fn)

    def set_lane_label(self, lane: int, value: str) -> None:
        def fn(p):
            r = next((r for r in p.rows if r.type == "lanes"), None)
            if r is None:
                r = LabelRow("lanes")
                p.rows.insert(0, r)
            if len(r.labels) < lane:
                r.labels += [""] * (lane - len(r.labels))
            r.labels[lane - 1] = value
        self.edit("Lane Label", fn)

    def add_row(self, kind: str) -> None:
        def fn(p):
            if kind == "lanes":
                if not any(r.type == "lanes" for r in p.rows):
                    p.rows.insert(0, LabelRow("lanes", labels=[""] * p.lane_count))
            else:
                n = max(p.lane_count, 1)
                p.rows.append(LabelRow("groups", groups=[LabelGroup("", [1, n])]))
        self.edit("Add Row", fn)

    def delete_row(self, r: int) -> None:
        def fn(p):
            if r < len(p.rows):
                del p.rows[r]
                p.style.text_sizes = {k: v for k, v in p.style.text_sizes.items()
                                      if not k.startswith(("lane.", "group.", "rowname."))}
        self.edit("Delete Row", fn)

    def set_row_name(self, r: int, name: str) -> None:
        def fn(p):
            if r < len(p.rows):
                p.rows[r].name = name or None
        self.edit("Row Title", fn)

    def add_group(self, r: int) -> None:
        def fn(p):
            if r >= len(p.rows):
                return
            last = max((g.last for g in p.rows[r].groups), default=0)
            n = max(p.lane_count, last + 1)
            first = min(last + 1, n)
            p.rows[r].groups.append(LabelGroup("", [first, first]))
        self.edit("Add Group", fn)

    def update_group(self, r: int, g: int, text: Optional[str] = None, first: Optional[int] = None,
                     last: Optional[int] = None) -> None:
        def fn(p):
            if r >= len(p.rows) or g >= len(p.rows[r].groups):
                return
            grp = p.rows[r].groups[g]
            if text is not None:
                grp.text = text
            a, b = grp.first, grp.last
            if first is not None:
                a = first
            if last is not None:
                b = last
            a, b = max(1, min(a, b)), max(1, max(a, b))
            grp.lanes = list(range(a, b + 1))
        self.edit("Edit Group", fn)

    def delete_group(self, r: int, g: int) -> None:
        def fn(p):
            if r < len(p.rows) and g < len(p.rows[r].groups):
                del p.rows[r].groups[g]
        self.edit("Delete Group", fn)

    def set_underline(self, r: int, on: bool) -> None:
        def fn(p):
            if r < len(p.rows):
                p.rows[r].underline = on
        self.edit("Underline", fn)

    def set_row_angle(self, row: int, degrees: float) -> None:
        """Stands the group labels of row row at an angle, any, brought into 0 ..< 360; the underline stays flat."""
        self.edit("Group Label Angle", lambda p: ops.set_row_angle(p, row, degrees))

    def set_label_angle(self, degrees: float) -> None:
        """Stands the lane labels at an angle, 0 (level) to 90 (straight up), for the whole figure."""
        self.edit("Label Angle", lambda p: ops.set_label_angle(p, degrees))

    def set_title(self, t: str) -> None:
        self.edit("Title", lambda p: setattr(p, "title", t or None))

    # sizes
    def set_kind_size(self, v: float, kind: str) -> None:
        self.edit("Text Size", lambda p: p.style.set_size_for_kind(v, kind))

    def set_label_size(self, v: float, role: Role) -> None:
        self.edit("Label Size", lambda p: p.style.set_size_for_label(v, role))

    def scale_all_text(self, delta: float) -> None:
        self.edit("Bigger Text" if delta > 0 else "Smaller Text", lambda p: p.style.scale_all(delta))

    def bump_text(self, delta: float) -> None:
        """The selected label, or all text when none is selected."""
        if self.selection and self.selection[0] == "text":
            role = self.selection[1]
            self.set_label_size(self.project.style.size_for(role) + delta, role)
        else:
            self.scale_all_text(delta)

    # ------------------------------------------------------------------------------------------------ reuse

    def scheme_text(self, positions: bool = False) -> str:
        return LabelScheme.of(self.project, positions).dumps()

    def paste_scheme(self, text: str, positions: bool) -> bool:
        try:
            s = LabelScheme.loads(text)
        except ValueError:
            return False
        if not positions:
            s.lanes = s.crop = None
            if s.ladder:
                s.ladder.bands, s.ladder.unit_y, s.ladder.unit_strip = [], None, None
        self.edit("Paste Labels and Positions" if positions else "Paste Labels",
                  lambda p: s.apply(p, self.image_w, self.image_h))
        self.selection = None   # the labels, ticks and names are other ones now
        self.quick_labels = ql.shorthand(self.project)
        return True

    def package_for_new_gel(self, path: Path) -> GelPackage:
        """The next gel's image, with this project's labels, titles, names and ladder."""
        pkg = GelPackage.create_from(path)
        src = SourceImage(pkg.image_data)
        LabelScheme.of(self.project, False).apply(pkg.project, src.width, src.height)
        return pkg

    # ------------------------------------------------------------------------------------------------ export

    @property
    def native_dpi(self) -> int:
        return int(sround(render.native_dpi(self.layout))) if self.layout else 0

    @property
    def resampled_export_dpi(self) -> Optional[float]:
        return render.resample_dpi(self.project.style.export_dpi, self.layout) if self.layout else None

    def request_export_dpi(self, dpi: Optional[float]) -> None:
        if dpi is None or self.layout is None or render.resample_dpi(dpi, self.layout) is None:
            self.set_export_dpi(None)
        elif any(stacked.keeps_original(self.project)) and self.resampled_export_dpi != dpi:
            self.ask_export_dpi.emit(dpi)
        else:
            self.set_export_dpi(dpi)

    def set_export_dpi(self, dpi: Optional[float]) -> None:
        self.edit("Native Resolution" if dpi is None else "Export Resolution",
                  lambda p: setattr(p.style, "export_dpi", dpi))

    def set_export_file_names(self, on: bool) -> None:
        """Whether exported files name each gel's image file in their notes and metadata (undoable)."""
        self.edit("File Names in Exports", lambda p: setattr(p, "export_file_names", on))

    def export_info(self, resampled: Optional[float] = None) -> render.ExportInfo:
        """The provenance note of the figure as it exports. Raises ImageError while a gel's image can't be read."""
        self.settle()
        why = self.unreadable_gel
        if why:
            raise ImageError(why)
        gels = [(w.source.sha256, w.source.scale, (w.width, w.height)) for w in self.strip_workings]
        srcs = [self.source] + [w.source if w else None for w in self.strip_workings]
        return render.export_info(self.project, self.source.sha256 if self.source else None, resampled,
                                  render.native_dpi(self.layout) if (resampled and self.layout) else None,
                                  self.source.scale if self.source else None, gels, (self.image_w, self.image_h),
                                  stacked.converted_storage(self.project, srcs),
                                  self.changed_warnings(self.project.export_file_names),
                                  stacked.unconverted_gels(self.project, srcs), stacked.copied_gels(self.project, srcs))

    @property
    def export_problem(self) -> Optional[str]:
        """Why the figure can't be exported now: a gel's image that can't be read, or Strict with gels that can't be
        stacked untouched. None when it can."""
        if self.unreadable_gel:
            return self.unreadable_gel
        if self.strict_problem:
            return (f"The gels that keep their original pixels must be stored the same way, but {self.strict_problem}. "
                    "Turn off Keep original pixels for a gel to export.")
        return None

    def export_bytes(self, fmt: str) -> bytes:
        """The whole figure, every gel included. Raises ImageError while a gel's image can't be read, and ValueError when
        Strict can't stack the gels untouched."""
        self.finish_quick_labels(normalize=False)
        self.settle()   # exports wait for the exact pixels of an angle that is only being previewed
        if self.unreadable_gel:
            raise ImageError(self.unreadable_gel)
        if self.export_problem:
            raise ValueError(self.export_problem)
        return stacked.StackedFigure(self.project, self.working, self.strip_workings).export(fmt)

    def _digest(self, data: bytes) -> str:
        """The SHA-256 of an image's bytes: known from its decoded copy, else worked out once (they never change)."""
        if self.source is not None and self.source.data is data:
            return self.source.sha256
        for c in self._strip_cache.values():
            if c["source"].data is data:
                return c["source"].sha256
        hit = self._digests.get(id(data))
        if hit is None or hit[0] is not data:
            hit = self._digests[id(data)] = (data, hashlib.sha256(data).hexdigest())
        return hit[1]

    def _intact(self, data: Optional[bytes], recorded: Optional[str]) -> Optional[bool]:
        """Whether an image still matches the fingerprint taken when it was added (None if none was recorded)."""
        if recorded is None:
            return None
        return data is not None and self._digest(data) == recorded

    def image_intact(self) -> Optional[bool]:
        return self._intact(self.image_data, self.project.image_sha256) if self.has_image else None

    def changed_warnings(self, names: bool = True) -> list[str]:
        """One line per gel whose image no longer matches the SHA-256 taken when it was added (render.changed_warnings):
        what the app says before it exports or copies a figure, and (without the file names when the project leaves them
        out) what the figure's note starts with."""
        if not self.has_image:
            return []
        data = [self.image_data] + [self.strip_images.get(s.image) for s in self.project.strips]
        return render.changed_warnings(self.project, [self._digest(d) if d is not None else None for d in data], names)

    def gels_intact(self) -> list[tuple[str, Optional[bool]]]:
        """Every gel against the fingerprint taken when it was added: (name, intact or None if none was recorded)."""
        if not self.has_image:
            return []
        p = self.project
        out = [(self.gel_name(None), self._intact(self.image_data, p.image_sha256))]
        out += [(self.gel_name(k + 1), self._intact(self.strip_images.get(s.image), s.image_sha256))
                for k, s in enumerate(p.strips)]
        live = {id(self.image_data), *(id(d) for d in self.strip_images.values())}
        self._digests = {k: v for k, v in self._digests.items() if k in live}
        return out

    def adopt_images(self, paths: list[Path]) -> list[str]:
        """The first image starts the project; any others are stacked under it as more gels, in order. Returns what
        couldn't be added (see add_gels)."""
        if not paths:
            return []
        self.adopt_image(paths[0])
        failed = self.add_gels(paths[1:])
        if len(paths) > 1:
            self.choose_gel(None)   # lanes first, on the gel that has them
            self.choose_tab("labels")
        return failed


class _ImageStep(QUndoCommand):
    """Choosing the image: undo goes back to the empty window."""

    def __init__(self, ws: Workspace, before: GelProject, old_data, project: GelProject, data: bytes):
        super().__init__("Choose Image")
        self.ws, self.before, self.old_data, self.after, self.data = ws, before, old_data, project, data
        self._done = False

    def redo(self):
        self.ws.image_data = self.data
        self.ws.source = None
        self.ws._image_key = None
        self.ws.quick_labels = ql.shorthand(self.after)
        self.ws._set_project(self.after, replay=self._done)
        self._done = True
        self.ws.view_changed.emit()

    def undo(self):
        self.ws.image_data = self.old_data
        self.ws.source = None
        self.ws._image_key = None
        self.ws._set_project(self.before, replay=True)
        self.ws.view_changed.emit()
