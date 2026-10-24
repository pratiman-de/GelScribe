"""Changing a gel's angle live: the picture turns at once (the last exact one, turned by the difference, on a small copy) and the exact
full-resolution pixels are made when the change ends. Exports wait for them, and they are the pixels a direct change makes."""
import io

import numpy as np
import pytest
from PIL import Image
from PySide6.QtCore import Qt
from PySide6.QtGui import QImage
from PySide6.QtWidgets import QApplication

QApplication.instance() or QApplication([])   # before anything draws, so the window tests can share it

from test_app import app, close, gel, settle, show, win   # noqa: E402,F401 (fixtures)
from test_gels import piece_png   # noqa: E402

from gelscribe.app.main import Controller   # noqa: E402
from gelscribe.core.package import GelPackage   # noqa: E402


def pixels(ws):
    return np.array(ws.view_array), np.array(ws.working.analysis)


def test_live_angle_previews_at_once_and_the_exact_pixels_follow(win):
    ws = win.ws
    ws.set_strict(False)
    settle()
    base_view = ws.view_array
    before = pixels(ws)
    for a in (0.4, 0.8, 1.2):
        ws.live_rotation(a)
    assert ws.project.rotate_deg == 1.2
    assert ws.pending_rotation() == pytest.approx(1.2)
    assert ws.view_array is base_view   # nothing was resampled yet: the picture shown is the last exact one, turned
    assert ws.preview_image() is not None
    win.canvas.grab()   # painting a pending angle works
    ws.end_rotation()
    assert ws.pending_rotation() != 0   # the exact pixels are being made on another thread; the preview stays up
    win.canvas.grab()
    ws.settle()   # (waits for them)
    assert ws.pending_rotation() == 0 and ws.view_array is not base_view
    after = pixels(ws)
    assert not np.array_equal(after[0], before[0])
    # exactly the pixels a direct change of the angle makes
    from gelscribe.core.image import WorkingImage
    fresh = WorkingImage(ws.source, ws.project)
    assert np.array_equal(after[1], np.array(fresh.analysis))
    assert np.array_equal(ws.view_array, fresh.view_image(ws.project, ws.project.view_enhance))
    ws.undo.undo()   # the whole drag is one step
    assert ws.project.rotate_deg == 0 and ws.pending_rotation() == 0


def test_exports_wait_for_the_exact_pixels_and_equal_a_direct_change(app, gel):
    direct = show(Controller(app), GelPackage.create_from(gel))
    live = show(Controller(app), GelPackage.create_from(gel))
    for w in (direct, live):
        w.ws.set_strict(False)
    direct.ws.set_rotation(1.5)
    live.ws.live_rotation(0.5)
    live.ws.live_rotation(1.5)
    assert live.ws.pending_rotation() == pytest.approx(1.5)   # still only previewed ...
    a = direct.ws.export_bytes("png")
    b = live.ws.export_bytes("png")   # ... until the export asks for the pixels
    assert live.ws.pending_rotation() == 0
    assert np.array_equal(np.array(Image.open(io.BytesIO(a))), np.array(Image.open(io.BytesIO(b))))
    close(direct)
    close(live)


def test_a_pause_makes_the_exact_pixels_and_other_edits_do_too(win):
    ws = win.ws
    ws.set_strict(False)
    ws.live_rotation(2.0)
    assert ws.pending_rotation() == pytest.approx(2.0)
    ws._settle_timer.timeout.emit()   # the angle held still for a moment: the build starts
    ws.settle()
    assert ws.pending_rotation() == 0
    ws.live_rotation(3.0)
    ws.set_fill("white")   # another change of the gel's pixels needs them at once
    assert ws.pending_rotation() == 0 and ws.project.rotate_deg == 3.0


def test_a_gel_that_keeps_its_pixels_is_never_previewed_turned(win):
    ws = win.ws
    assert ws.project.strict
    ws.live_rotation(2.0)
    assert ws.pending_rotation() == 0   # Keep original pixels ignores the angle


def test_a_stacked_gels_angle_previews_too(win, tmp_path):
    ws = win.ws
    ws.set_strict(False)
    assert not ws.add_gels([_second(tmp_path)])
    ws.choose_gel(1)
    ws.set_strict(False)
    settle()
    ws.live_rotation(1.0)
    assert ws.pending_rotation(1) == pytest.approx(1.0) and ws.pending_rotation(None) == 0
    win.canvas.grab()
    ws.end_rotation()
    ws.settle()
    assert ws.pending_rotation(1) == 0
    from gelscribe.core.image import WorkingImage
    fresh = WorkingImage(ws.strip_working(1).source, ws.project.strip_project(1))
    assert np.array_equal(np.array(ws.strip_working(1).analysis), np.array(fresh.analysis))


def _second(tmp_path):
    path = tmp_path / "second.png"
    path.write_bytes(piece_png(300, 200, [60, 130, 200], [80, 150]))
    return path


def _grab(win) -> np.ndarray:
    img = win.canvas.grab().toImage().convertToFormat(QImage.Format.Format_Grayscale8)
    return np.frombuffer(img.constBits(), np.uint8).reshape(img.height(), img.bytesPerLine())[:, :img.width()].astype(float)


def test_the_preview_turns_the_picture_the_way_the_exact_pixels_are_turned(win):
    ws = win.ws
    ws.set_strict(False)
    ws.set_tool("pan")   # no overlays, just the figure
    settle()
    flat = _grab(win)
    ws.live_rotation(4.0)
    preview = _grab(win)
    ws.end_rotation()
    ws.settle()
    exact = _grab(win)
    assert np.abs(preview - exact).mean() < np.abs(flat - exact).mean() / 3   # the preview is much closer to the result than no turn


def test_the_exact_pixels_land_on_their_own_and_a_newer_angle_drops_the_stale_build(win):
    import time
    ws = win.ws
    ws.set_strict(False)
    ws.live_rotation(1.0)
    ws.end_rotation()
    job = ws._job
    assert job is not None
    ws.live_rotation(2.0)   # a newer angle: the stale build is dropped
    assert job.cancel.is_set() and ws._job is None
    ws.end_rotation()
    for _ in range(200):   # the window's event loop brings the pixels in without anyone asking
        settle()
        if ws.pending_rotation() == 0:
            break
        time.sleep(0.02)
    assert ws.pending_rotation() == 0 and ws.working.rotation == 2.0
