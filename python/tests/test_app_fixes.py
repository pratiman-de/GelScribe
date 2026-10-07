"""The window after the audit: save failures, stacked gels, marks that stay in their gel, unreadable images, speed.
Made-up gels only, off-screen, like test_app."""
import time

import numpy as np
import pytest
from PIL import Image
from PySide6.QtCore import QEvent, Qt
from PySide6.QtGui import QKeyEvent
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QLineEdit, QMessageBox

from gelscribe.app.main import Controller
from gelscribe.core import ops
from gelscribe.core.image import ImageError
from gelscribe.core.model import PixelRect, Role
from gelscribe.core.package import GelPackage
from gelscribe.app.editors import TextEditor
from test_app import LANES, app, at, click, close, gel, place_lanes, popup, settle, show, win   # noqa: F401 (fixtures)
from test_gels import cut_blot, piece_png


@pytest.fixture
def boxes(monkeypatch):
    """Message boxes recorded instead of shown: what each said."""
    said = []
    monkeypatch.setattr(QMessageBox, "warning", staticmethod(lambda parent, title, text, *a, **k: said.append(text)))
    return said


@pytest.fixture
def cut(app):
    """A window on the two-gel project from test_gels: top.png (the lanes) with bottom.png under it."""
    w = show(Controller(app), cut_blot())
    w.ws.set_tool("select")
    settle()
    yield w
    close(w)


def open_project(app, folder):
    """The project folder opened the way File › Open does it."""
    ctl = Controller(app)
    ctl.open_path(folder)
    w = ctl.windows[-1]
    w.resize(1440, 920)
    w.activateWindow()
    QTest.qWaitForWindowActive(w, 2000)
    settle()
    return w


def png_file(path, width=700, height=220, lanes=LANES, rows=(90,)):
    path.write_bytes(piece_png(width, height, lanes, list(rows)))
    return path


# ---------------------------------------------------------------------------------------------------- saving


def test_a_failed_save_keeps_the_window_and_its_changes(win, tmp_path, monkeypatch, boxes):
    ws = win.ws
    folder = tmp_path / "P.gelscribe"
    ws.save_to(folder)
    (folder / ws.project.image).write_bytes(b"another image under the same name")   # write() will refuse this
    ws.set_title("Edited")
    monkeypatch.setattr(QMessageBox, "exec", lambda box: QMessageBox.StandardButton.Save)
    assert not win.close()   # not closed
    assert win.isVisible() and ws.dirty and win in win.ctl.windows
    assert len(boxes) == 1 and "Could not save" in boxes[0] and "different image" in boxes[0]
    assert not win.save() and len(boxes) == 2   # the same from Save, and from Save As
    (folder / ws.project.image).write_bytes(ws.image_data)   # put right: now it saves and closes
    assert win.close() and GelPackage.read(folder).project.title == "Edited"


def test_default_file_names_leave_out_line_breaks_and_characters_a_disk_cant_hold():
    from gelscribe.app.window import file_stem
    assert file_stem("Anti-p53\nactin / GAPDH: 2?") == "Anti-p53 actin - GAPDH- 2-"
    assert file_stem("") == "figure" and file_stem("  ..") == "figure"


# ---------------------------------------------------------------------------------------------------- brightness & contrast


def test_min_and_max_of_a_stacked_gel_use_its_own_range(cut):
    ws = cut.ws
    ws.choose_gel(1)
    ws.change_contrast(lambda d: d.set_range(10, 200, ws.value_scale))
    ws.undo.setClean()
    ws.set_tab("figure")
    settle()
    fig = cut.inspector.panels["figure"]
    main_before = ws.project.display.range_in(ws.working.source.scale)
    steps = ws.undo.count()
    fig._set_min(30, False)
    assert ws.project.strips[0].display.range_in(ws.value_scale) == (pytest.approx(30), pytest.approx(200))
    fig._set_max(150, False)
    assert ws.project.strips[0].display.range_in(ws.value_scale) == (pytest.approx(30), pytest.approx(150))
    assert ws.project.display.range_in(ws.working.source.scale) == main_before   # the gel with the lanes is untouched
    assert ws.undo.count() == steps + 2
    # clicking into a field and out again is not an edit
    steps = ws.undo.count()
    for row in (fig.min_row, fig.max_row):
        row["field"].setFocus()
        row["field"].editingFinished.emit()
    assert ws.undo.count() == steps
    fig.min_row["field"].setValue(40)
    fig.min_row["field"].editingFinished.emit()
    assert ws.undo.count() == steps + 1 and ws.project.strips[0].display.range_in(ws.value_scale)[0] == pytest.approx(40)


def test_the_scale_under_the_minimum_and_maximum_sliders_holds_still_while_one_is_dragged(win):
    ws = win.ws
    ws.set_tab("figure")
    settle()
    fig = win.inspector.panels["figure"]
    lo, hi = fig.min_row["axis"]
    s = fig.min_row["slider"]
    s.setSliderDown(True)
    s.setValue(0)   # dragged to the far end of the scale
    assert fig.min_row["axis"] == (lo, hi) and fig.max_row["axis"] == (lo, hi)
    ws.change_contrast(lambda d: d.set_range(ws.value_scale.value(0) - 40, ws.value_scale.value(1), ws.value_scale), live=True)
    assert fig.min_row["axis"] == (lo, hi)   # the range went below the data's own, and the scale didn't move
    s.setSliderDown(False)
    ws.end_contrast_change()
    settle()
    assert fig.min_row["axis"][0] < lo   # it widens again once the handle is let go


# ---------------------------------------------------------------------------------------------------- rows


def test_dragging_gel_rows_goes_through_the_core_and_a_drag_with_no_rows_keeps_the_old_ones(cut):
    ws = cut.ws
    ws.choose_gel(1)
    s = ws.project.strips[0]
    ws.live_strip_rows(20, 100)
    assert (s.top, s.bottom) == (20, 100) and (ws.project.strips[0].top, ws.project.strips[0].bottom) == (20, 100)
    ws.live_strip_rows(-50, 5000)   # clamped to the gel
    assert (ws.project.strips[0].top, ws.project.strips[0].bottom) == (0, 220)
    ws.live_strip_rows(30, 90)
    for beyond in ((300, 400), (-80, -10), (50, 50)):   # nothing of the gel left
        ws.live_strip_rows(*beyond)
        assert (ws.project.strips[0].top, ws.project.strips[0].bottom) == (30, 90)
    ws.live_strip_rows(60, 62)   # at least 8 rows
    assert ws.project.strips[0].bottom - ws.project.strips[0].top >= 8
    ws.end_gesture("Gel Rows")
    ws.undo.undo()
    assert ws.project.strips[0].top is None and ws.project.strips[0].bottom is None


# ---------------------------------------------------------------------------------------------------- marks stay in their gel


def test_ticks_and_names_stay_inside_their_gel_when_placed_snapped_and_dragged(cut):
    ws = cut.ws
    ws.project.crop = None
    main_rows = ws.project.figure_rows(None, ws.image_w, ws.image_h)
    assert main_rows == (0, 160)
    # a tick dragged toward the gel below stops at the end of its own gel, snapping or not
    i = ws.add_tick(310, 60)
    for free in (False, True):
        fy = ws.stack.piece(1).top + 3   # a figure row inside gel 2
        ws.drag_tick(i, 310, fy, free)
        assert ws.project.ladder.bands[i].y <= 160
    ws.drag_tick(i, 310, -40, True)
    assert ws.project.ladder.bands[i].y == 0
    ws.end_gesture("Move Ladder Tick")
    # a click in the separator nearer gel 1 can't make a mark outside it
    sep = (ws.stack.piece(None).bottom + ws.stack.piece(1).top) / 2
    strip, y, fy = ws.snap_in_figure(310, sep - 0.2, True)
    assert strip is None and 0 <= y <= 160 and fy == y
    n = ws.add_name(500)
    assert ws.project.annotations[n].y == 160
    ws.add_tick(310, -7)
    assert min(b.y for b in ws.project.ladder.bands) == 0
    # a gel trimmed to some rows: a click near its top edge snaps no higher than the first row
    ws.choose_gel(1)
    ws.live_strip_rows(56, 200)
    ws.end_gesture("Gel Rows")
    q = ws.stack.piece(1)
    strip, y, _ = ws.snap_in_figure(310, q.top + 2, False)
    assert strip == 1 and 56 <= y <= 200
    ws.set_tool("ladder")
    k = ws.add_tick(310, 3, strip=1)
    assert ws.project.ladder.bands[k].y == 56 and ws.project.ladder.bands[k].strip == 1


def test_the_tick_editors_suggestion_ranks_a_tick_within_its_own_gel(cut, monkeypatch):
    from gelscribe.app import window as window_module
    ws = cut.ws
    ws.set_ladder_sizes("100 80 60 40 30 20")
    for y in (20, 60):   # two ticks on the lanes gel, then three on gel 2
        ws.add_tick(310, y)
    for y in (30, 60, 90):
        ws.add_tick(310, y, strip=1)
    i = next(n for n, b in enumerate(ws.project.ladder.bands) if b.strip == 1 and b.y == 90)
    assert ws.suggested_size(90 - 0.001) == 60   # without the gel it would rank as a tick of the lanes gel
    opened = []

    class Fake:
        def __init__(self, parent, size, guess, suggestion, *rest):
            opened.append(suggestion)

        def show_beside(self, *args):
            pass
    monkeypatch.setattr(window_module, "TickEditor", Fake)
    cut.show_tick_editor(i, cut.canvas.rect().center())
    assert opened == [30]   # the fifth tick from the top of the whole stack


# ---------------------------------------------------------------------------------------------------- image names and removal


def test_a_gel_added_to_a_saved_project_never_takes_the_name_of_a_file_in_its_folder(app, tmp_path, boxes):
    folder = tmp_path / "cut.gelscribe"
    cut_blot().write(folder)
    w = open_project(app, folder)
    ws = w.ws
    ws.choose_gel(1)
    ws.remove_active_gel()
    assert ws.project.strips == [] and (folder / "bottom.png").exists()   # its copy is still in the folder
    other = piece_png(700, 220, LANES, [30])
    k = ws.add_gel(other, "bottom.png")   # a different image under the same name
    assert ws.project.strips[k - 1].image == "bottom_1.png"
    k = ws.add_gel(other, "BOTTOM_1.PNG")   # and one that differs only in capitals
    assert ws.project.strips[k - 1].image == "BOTTOM_1_1.PNG"
    assert w.save() and not boxes
    back = GelPackage.read(folder)
    assert [s.image for s in back.project.strips] == ["bottom_1.png", "BOTTOM_1_1.PNG"] and back.strip_images == ws.strip_images
    # a gel taken out leaves its copy in the folder until the next save, which removes exactly that copy
    assert (folder / "BOTTOM_1_1.PNG").exists()
    (folder / "notes.txt").write_text("mine")
    (folder / "bottom.png").write_bytes(b"not the image this gel had")   # a leftover with the old name: never touched
    ws.choose_gel(2)
    ws.remove_active_gel()
    assert (folder / "BOTTOM_1_1.PNG").exists()
    assert w.save() and not (folder / "BOTTOM_1_1.PNG").exists() and (folder / "bottom_1.png").exists()
    assert (folder / "notes.txt").read_text() == "mine" and (folder / "bottom.png").read_bytes() == b"not the image this gel had"
    assert not (tmp_path / "BOTTOM_1_1.PNG").exists()   # an original elsewhere is never part of it
    ws.undo.undo()   # the gel is back, with its image, and the next save writes the copy again
    assert w.save() and (folder / "BOTTOM_1_1.PNG").read_bytes() == other
    # taking a gel out keeps the image another gel is stored under, and undo brings both back together
    ws.choose_gel(2)
    ws.remove_active_gel()
    assert list(ws.strip_images) == ["bottom_1.png"]
    ws.undo.undo()
    assert sorted(ws.strip_images) == ["BOTTOM_1_1.PNG", "bottom_1.png"] and len(ws.project.strips) == 2
    close(w)


def test_a_failed_add_says_which_file_and_why_and_adds_nothing(win, tmp_path, boxes, monkeypatch):
    import tifffile
    from PySide6.QtWidgets import QFileDialog
    ws = win.ws
    floaty = tmp_path / "float.tif"
    tifffile.imwrite(floaty, np.random.default_rng(1).random((40, 60)).astype(np.float32))
    text = tmp_path / "notes.txt"
    text.write_text("not an image")
    good = png_file(tmp_path / "good.png")
    monkeypatch.setattr(QFileDialog, "getOpenFileNames", staticmethod(lambda *a, **k: ([str(floaty), str(text), str(good)], "")))
    win.add_gel_dialog()
    assert [s.image for s in ws.project.strips] == ["good.png"]   # the one that could be read is added
    assert len(boxes) == 1 and "float.tif could not be added" in boxes[0] and "notes.txt could not be added" in boxes[0]
    assert ("This image has 32-bit floating-point values, which GelScribe doesn't support. Export it from your scanner's "
            "software as a 16-bit TIFF and open that.") in boxes[0]
    # opening one says the same
    win.ctl.open_path(floaty)
    assert len(boxes) == 2 and "float.tif could not be opened" in boxes[1] and "32-bit floating-point" in boxes[1]
    assert len(win.ctl.windows) == 1


# ---------------------------------------------------------------------------------------------------- unreadable gels


def three_gels(tmp_path):
    """A project of three gels written to disk, the second one's image then damaged."""
    folder = tmp_path / "three.gelscribe"
    pkg = cut_blot()
    pkg.add_strip(piece_png(640, 120, LANES, [50]), "third.png")
    pkg.write(folder)
    data = (folder / "bottom.png").read_bytes()
    (folder / "bottom.png").write_bytes(data[:len(data) // 3])   # a truncated copy
    return folder


def test_a_gel_whose_image_cannot_be_read_is_said_so_and_never_exported_or_swapped(app, tmp_path, boxes):
    from PySide6.QtWidgets import QFileDialog
    folder = three_gels(tmp_path)
    w = open_project(app, folder)
    ws = w.ws
    third = GelPackage.read(folder).strip_data(2)
    message = "Gel 2's image (bottom.png) can't be read."
    assert ws.unreadable_gel == message and w.problem_label.text() == message and not w.problem_label.isHidden()
    assert ws.strip_sizes[0] is None and ws.strip_sizes[1] == (640, 120)   # aligned: the third gel kept its own place
    assert [q.strip for q in ws.stack.pieces] == [None, 2] and ws.strip_working(2).source.data == third
    for fmt in ("pdf", "png", "tiff", "svg"):
        with pytest.raises(ImageError, match="Gel 2's image"):
            ws.export_bytes(fmt)
    out = tmp_path / "out.png"
    QFileDialog.getSaveFileName = staticmethod(lambda *a, **k: (str(out), ""))
    w.export("png")
    w.copy_figure()
    assert not out.exists() and len(boxes) == 2 and all(message in b for b in boxes)
    assert "Export failed" in boxes[0] and "Copy failed" in boxes[1]
    # it can be chosen but not turned, rotated or lined up, and nothing about it shows another gel's size
    ws.choose_gel(1)
    steps = ws.undo.count()
    ws.turn_active(1)
    ws.set_rotation(3)
    ws.live_strip_rows(10, 50)
    ws.auto_align()
    assert ws.active_size == (0, 0) and ws.undo.count() == steps and ws.align_note == message
    ws.set_tab("export")
    settle()
    assert message in w.inspector.panels["export"].prov.text()
    ws.set_tab("figure")
    settle()
    gels = w.inspector.panels["figure"].gels
    assert message in gels.problem.text() and not gels.problem.isHidden() and gels.file.text() == "bottom.png"
    assert "can't be read" in w.inspector.panels["figure"].crop_caption.text()
    # the file is left as it was when saved, and the figure comes back once the image does
    ws.set_title("T")
    assert w.save() and (folder / "bottom.png").stat().st_size < 5000
    close(w)


def test_a_project_whose_main_image_cannot_be_read_opens_with_the_message(app, tmp_path, boxes):
    folder = tmp_path / "broken.gelscribe"
    cut_blot().write(folder)
    (folder / "top.png").write_bytes(b"\x89PNG not really")
    w = open_project(app, folder)
    ws = w.ws
    assert ws.unreadable_gel == "Gel 1's image (top.png) can't be read." and ws.working is None and ws.layout is None
    assert w.problem_label.text() == ws.unreadable_gel
    with pytest.raises(ImageError, match="Gel 1's image"):
        ws.export_bytes("png")
    for tab in ("labels", "ladder", "names", "figure", "export"):   # every panel copes with it
        ws.set_tab(tab)
        settle()
    close(w)


# ---------------------------------------------------------------------------------------------------- loading


def test_rows_and_marks_that_do_not_fit_their_gel_are_put_right_when_a_project_opens(app, tmp_path):
    pkg = cut_blot()
    pkg.project.strips[0].top, pkg.project.strips[0].bottom = 50, 9999   # taller than the gel (220 rows)
    ops.add_tick(pkg.project, 5000, 40, lane=1, gel_center_x=310, strip=1)
    folder = tmp_path / "wrong.gelscribe"
    pkg.write(folder)
    w = open_project(app, folder)
    p = w.ws.project
    assert (p.strips[0].top, p.strips[0].bottom) == (None, None)   # the whole gel
    assert p.ladder.bands[0].y == 220
    assert not w.ws.dirty and w.ws.stack.piece(1).bottom - w.ws.stack.piece(1).top == 220
    close(w)


@pytest.mark.parametrize("text", ["[]", "not json", '{"image": "top.png", "display": 5}', '{"image": "../x.png"}',
                                  '{"image": "top.png", "crop": [1, 2]}', '{"image": "top.png", "strips": [5]}'])
def test_a_damaged_project_file_gives_a_message_not_a_traceback(app, tmp_path, boxes, text):
    folder = tmp_path / "bad.gelscribe"
    cut_blot().write(folder)
    (folder / "project.json").write_text(text, encoding="utf-8")
    ctl = Controller(app)
    ctl.open_path(folder)
    assert not ctl.windows and len(boxes) == 1 and "bad.gelscribe could not be opened" in boxes[0] and "Not a GelScribe project" in boxes[0]


# ---------------------------------------------------------------------------------------------------- the chosen gel, the selection


def test_undo_and_redo_of_moving_a_gel_keep_the_same_gel_chosen(app, tmp_path):
    pkg = cut_blot()
    pkg.add_strip(piece_png(640, 120, LANES, [50]), "third.png")
    w = show(Controller(app), pkg)
    ws = w.ws

    def chosen():
        return ws.project.strips[ws.active_strip - 1].image if ws.active_strip else None
    ws.choose_gel(2)
    assert chosen() == "third.png"
    ws.move_gel(2, 0)   # third.png to the top
    assert chosen() == "third.png" and ws.project.position_of(ws.active_strip) == 0
    ws.undo.undo()
    assert chosen() == "third.png" and ws.project.position_of(ws.active_strip) == 2
    ws.undo.redo()
    assert chosen() == "third.png" and ws.project.position_of(ws.active_strip) == 0
    ws.choose_gel(None)   # the gel with the lanes stays chosen too
    ws.undo.undo()
    assert ws.active_strip is None
    close(w)


def test_a_selection_never_points_at_another_tick_or_name_after_a_removal_a_sort_or_an_undo(cut):
    ws = cut.ws
    for y in (20, 60, 100):
        ws.add_tick(310, y)
    ws.add_tick(310, 50, strip=1)
    ws.add_name(30, "A")
    ws.add_name(90, "B", strip=1)
    ws.selection = ("tick", 3)   # gel 2's tick
    ws.selection = ("name", 1)
    ws.choose_gel(1)
    ws.remove_active_gel()
    assert ws.selection is None and len(ws.project.ladder.bands) == 3 and [a.text for a in ws.project.annotations] == ["A"]
    ws.undo.undo()
    assert ws.selection is None
    # dragging a tick past another: the selection follows the tick, not the number
    ws.selection = ("tick", 0)
    sel_y = ws.project.ladder.bands[0].y
    ws.move_tick(0, 130)
    i = ws.end_tick_drag(0)
    assert ws.project.ladder.bands[i].y == 130 and i == 2 and sel_y == 20
    # a divider the same way
    ws.drag_divider(0, ws.project.lanes.dividers[0], "move", 500, 100)
    j = ws.end_divider_drag(0)
    assert j == len(ws.project.lanes.dividers) - 1
    # Assign Top-Down puts the ticks in order again, so its selection goes; undo and redo drop it too
    ws.selection = ("tick", 1)
    ws.assign_top_down()
    assert ws.selection is None
    ws.selection = ("name", 0)
    ws.undo.undo()
    assert ws.selection is None
    ws.selection = ("tick", 0)
    ws.undo.redo()
    assert ws.selection is None


def test_deleting_a_name_keeps_every_other_names_own_size(cut):
    ws = cut.ws
    for n, y in enumerate((20, 40, 60, 80)):
        ws.add_name(y, f"N{n}")
        ws.set_label_size(8 + n, Role("annotation", n))
    ws.delete_name(1)
    assert [a.text for a in ws.project.annotations] == ["N0", "N2", "N3"]
    assert ws.project.style.text_sizes == {"name.0": 8, "name.1": 10, "name.2": 11}
    ws.choose_gel(1)
    ws.add_name(30, "On gel 2", strip=1)
    ws.set_label_size(14, Role("annotation", 3))
    ws.remove_active_gel()
    assert ws.project.style.text_sizes == {"name.0": 8, "name.1": 10, "name.2": 11}


def test_starting_with_several_images_leaves_the_inspector_on_the_gel_with_the_lanes(app, tmp_path):
    paths = [png_file(tmp_path / f"g{n}.png", 640, 160 + 20 * n) for n in range(3)]
    w = show(Controller(app))
    w.adopt_images(paths)
    settle()
    ws = w.ws
    assert [s.image for s in ws.project.strips] == ["g1.png", "g2.png"]
    assert ws.active_strip is None and (ws.tool, ws.inspector_tab) == ("lanes", "labels") and ws.align_note is None
    ws.choose_tab("figure")
    settle()
    gels = w.inspector.panels["figure"].gels
    assert gels.list.currentRow() == 0 and not gels.remove.isVisible() and "Place the lane dividers" not in gels.note.text()
    close(w)


def test_dropping_several_files_on_a_window_with_an_image_opens_each_one(win, tmp_path):
    a, b = png_file(tmp_path / "a.png"), png_file(tmp_path / "b.png")
    opened = []
    win.ctl.open_path = lambda path: opened.append(path.name)
    win.adopt_images([a, b])
    assert opened == ["a.png", "b.png"]


# ---------------------------------------------------------------------------------------------------- auto-align


def test_auto_align_refuses_with_the_reason_and_leaves_the_gel_where_it_is(cut, tmp_path):
    ws = cut.ws
    blank = tmp_path / "blank.png"
    Image.fromarray(np.full((200, 700), 230, np.uint8)).save(blank)
    assert not ws.add_gels([blank])
    k = ws.active_strip
    assert ws.project.strips[k - 1].shift == 0 and ws.align_note == "Couldn't find Gel 3's lanes. Line it up by hand."
    ws.choose_gel(1)
    ws.auto_align_all()
    assert "Couldn't find Gel 3's lanes. Line it up by hand." in ws.align_note
    ws.set_strict(False)
    ws.choose_gel(None)
    ws.project.lanes.dividers.clear()
    ws.project.lanes.centers.clear()
    ws.choose_gel(1)
    ws.auto_align()
    assert ws.align_note == "Place the lane dividers on Gel 1 first."


# ---------------------------------------------------------------------------------------------------- older problems


def test_the_custom_fill_slider_applies_while_dragged_and_is_one_undo_step(win):
    ws = win.ws
    ws.set_strict(False)
    ws.set_fill("custom")
    ws.set_tab("figure")
    settle()
    fig = win.inspector.panels["figure"]
    assert fig.fill_value.isVisible() and ws.project.fill_value == 0.9
    steps = ws.undo.count()
    s = fig.fill_value.slider
    s.setSliderDown(True)
    for v in (60, 40, 25):
        s.setValue(v)
        assert ws.project.fill_value == pytest.approx(v / 100)   # live
    s.setSliderDown(False)
    settle()
    assert ws.undo.count() == steps + 1 and ws.project.fill_value == pytest.approx(0.25)
    assert fig.fill_value.value_label.text() == "0.25" and s.value() == 25   # and it stays where it was left
    ws.undo.undo()
    assert ws.project.fill_value == 0.9


def test_place_for_the_unit_label_waits_for_the_click_and_the_label_belongs_to_the_gel_clicked(cut):
    ws = cut.ws
    ws.add_tick(310, 60)   # a ladder with something to label
    ws.set_tool("ladder")
    ws.set_tab("ladder")
    settle()
    cut.inspector.panels["ladder"]._place()
    assert ws.placing_unit and ws.tool == "select"   # it used to be reset by the change of tool
    q = ws.stack.piece(1)
    fy = q.top + 100   # 100 rows into gel 2
    click(cut, at(cut, 310, fy))
    lad = ws.project.ladder
    assert (lad.unit_strip, lad.unit_y) == (1, 100) and not ws.placing_unit
    # the label goes with its gel when the gels are moved, and drops back to automatic when the gel is removed
    ws.move_gel(1, 0)
    assert (ws.project.ladder.unit_strip, ws.project.ladder.unit_y) == (1, 100)
    assert ws.layout.texts and any(t.role.kind == "ladderUnit" for t in ws.layout.texts)
    # dragging it over the lanes gel hands it to that gel, inside its rows
    ws.move_unit(ws.stack.piece(None).top + 5)
    assert (ws.project.ladder.unit_strip, ws.project.ladder.unit_y) == (None, 5)
    ws.move_unit(ws.stack.piece(1).top + 20)
    ws.end_gesture("Move Unit Label")
    ws.choose_gel(1)
    ws.remove_active_gel()
    assert (ws.project.ladder.unit_strip, ws.project.ladder.unit_y) == (None, None)


def test_a_unit_label_placed_on_another_gel_does_not_come_across_with_pasted_labels(cut, win):
    cut.ws.add_tick(310, 60)
    cut.ws.set_unit_y(cut.ws.stack.piece(1).top + 30)
    assert cut.ws.project.ladder.unit_strip == 1
    cut.copy_labels()
    win.ws.add_tick(LANES[0], 100)
    for positions in (False, True):
        win.paste_labels(positions)
        lad = win.ws.project.ladder
        assert lad.unit_y is None and lad.unit_strip is None   # no label hanging on a gel the other project hasn't got
    win.ws.set_unit_y(150)   # this project's own placement stays when labels are pasted over it
    win.paste_labels(False)
    assert (win.ws.project.ladder.unit_y, win.ws.project.ladder.unit_strip) == (150, None)


def test_a_key_that_types_a_character_with_altgr_goes_to_the_field_and_not_to_the_shortcut(win):
    import sys
    from gelscribe.app import keys
    mods = Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.AltModifier
    assert keys.AltGrGuard().active == (sys.platform == "win32")   # only where AltGr is reported as Ctrl+Alt
    guard = keys.AltGrGuard(always=True)
    QApplication.instance().installEventFilter(guard)
    try:
        field = QLineEdit()

        def override(widget, key, text, modifiers=mods):
            e = QKeyEvent(QEvent.Type.ShortcutOverride, key, modifiers, text)
            e.ignore()
            QApplication.sendEvent(widget, e)
            return e.isAccepted()
        assert override(field, Qt.Key.Key_V, "@")   # AltGr+V on a Czech keyboard
        assert override(field, Qt.Key.Key_C, "&")
        assert not override(field, Qt.Key.Key_V, "")   # a real Ctrl+Alt+V has no character: the shortcut still runs
        assert not override(field, Qt.Key.Key_V, "\x16")
        assert not override(win.canvas, Qt.Key.Key_V, "@")   # not a text field
        win.ws.set_tab("labels")
        settle()
        assert override(win.inspector.panels["labels"].quick, Qt.Key.Key_V, "@")   # a text box
        assert override(win.inspector.panels["labels"].angle.lineEdit(), Qt.Key.Key_V, "@")   # a spin box types in a QLineEdit
    finally:
        QApplication.instance().removeEventFilter(guard)


# ---------------------------------------------------------------------------------------------------- own ladder


def test_the_own_ladder_checkbox_belongs_to_the_chosen_gel_and_is_undoable(cut):
    ws = cut.ws
    ws.set_ladder_sizes("100 80 60 40")
    for y in (20, 60):
        ws.add_tick(310, y)
    for y in (30, 70):
        ws.add_tick(310, y, strip=1)
    ws.assign_top_down()
    sizes = lambda: [(b.strip, b.size) for b in ws.project.ladder.bands]   # noqa: E731
    assert sizes() == [(None, 100), (None, 80), (1, 60), (1, 40)]
    ws.set_tab("figure")
    ws.choose_gel(None)
    settle()
    own = cut.inspector.panels["figure"].gels.own
    assert own.isVisible() and not own.isEnabled() and not own.isChecked()   # the top gel always starts its ladder
    assert "start again from the top instead of carrying on from the gel above" in cut.inspector.panels["figure"].gels.own_caption.text()
    ws.choose_gel(1)
    settle()
    assert own.isEnabled() and not own.isChecked()
    steps = ws.undo.count()
    own.click()
    assert ws.project.strips[0].own_ladder and ws.undo.count() == steps + 1
    assert sizes() == [(None, 100), (None, 80), (1, 100), (1, 80)]   # re-assigned: gel 2 starts again from the top
    assert own.isChecked()
    ws.undo.undo()
    assert not ws.project.strips[0].own_ladder and sizes() == [(None, 100), (None, 80), (1, 60), (1, 40)]
    assert not own.isChecked()
    ws.undo.redo()
    assert own.isChecked()
    ws.move_gel(0, 1)   # the gel with the lanes below it now: that one is the top
    settle()
    ws.choose_gel(1)
    settle()
    assert not own.isEnabled() and own.isChecked()   # still stored, but the top gel starts a ladder anyway
    ws.choose_gel(None)
    settle()
    assert own.isEnabled() and not own.isChecked()
    own.click()
    assert ws.project.own_ladder


# ---------------------------------------------------------------------------------------------------- provenance, speed


def test_the_provenance_note_gives_the_rows_and_crop_actually_used(cut):
    ws = cut.ws
    ws.project.strips[0].top, ws.project.strips[0].bottom = 10.6, 5000   # as a damaged or hand-edited file could have them
    ws.project.crop = PixelRect(-5, -5, 9999, 9999)
    text = ws.export_info().description
    assert "columns 0–620, rows 0–160" in text and "rows 11–220" in text   # a mixed figure's headline has no crop (finding 2)


def test_a_refresh_does_not_hash_the_images_again_or_look_at_the_recent_projects(cut, monkeypatch):
    from gelscribe.app import workspace
    ws = cut.ws
    ws.set_tab("export")
    settle()
    real_sha256 = workspace.hashlib.sha256
    monkeypatch.setattr(workspace.hashlib, "sha256", lambda *a, **k: pytest.fail("hashed an image"))
    looked = []
    real = cut.ctl.recent
    monkeypatch.setattr(cut.ctl, "recent", lambda: looked.append(1) or real())
    for _ in range(5):
        ws.changed.emit()
    assert not looked   # Open Recent is built when its menu opens, not on every change
    cut.recent_menu.aboutToShow.emit()
    assert len(looked) == 1
    assert dict(ws.gels_intact()) == {"Gel 1": True, "Gel 2": True}   # fingerprints come from the images already read
    monkeypatch.setattr(workspace.hashlib, "sha256", real_sha256)
    ws.strip_images[ws.project.strips[0].image] = b"changed"   # an image that no longer matches its fingerprint
    assert ws.gels_intact()[1] == ("Gel 2", False)


def test_the_canvas_paints_the_stack_from_each_gels_own_picture(cut, tmp_path):
    ws = cut.ws
    layers = ws.gel_layers()
    assert [q.strip for q, _ in layers] == [None, 1] and all(img is not None for _, img in layers)
    # the same as the composed picture would show: each gel's rows at its place, a black line between them
    composed = ws.display_cropped()
    grab = cut.canvas.grab().toImage()
    assert grab.width() > 0 and composed.width() == 620
    # moving a gel sideways paints it again without composing anything
    calls = []
    from gelscribe.core import strips as stacked
    original = stacked.view_image
    stacked.view_image = lambda *a, **k: calls.append(1) or original(*a, **k)
    try:
        s0 = ws.project.strips[0].shift
        for k in range(4):
            ws.live_strip_shift(1, s0 + k + 1)
            cut.canvas.repaint()
        ws.end_gesture("Line Up Gel")
    finally:
        stacked.view_image = original
    assert not calls and ws.project.strips[0].shift == s0 + 4


def test_dragging_a_gel_is_quick_on_big_scans(app, tmp_path):
    """The stack isn't composed again on every move: a big pair of 16-bit scans moves in well under the 0.2 s it took."""
    import tifffile
    H, W = 1800, 2800
    yy, xx = np.mgrid[0:H, 0:W]
    img = np.full((H, W), 52000.0)
    for i in range(10):
        img -= 30000 * np.exp(-((xx - (300 + 250 * i)) / 60.0) ** 2 / 2) * np.exp(-((yy - 700) / 20.0) ** 2 / 2)
    one, two = tmp_path / "one.tif", tmp_path / "two.tif"
    tifffile.imwrite(one, img.astype(np.uint16))
    tifffile.imwrite(two, np.roll(img, 31, axis=1).astype(np.uint16))
    pkg = GelPackage.create_from(one)
    pkg.project.strict = False
    ops.set_dividers(pkg.project, [425 + 250 * i for i in range(9)], W, H)
    w = show(Controller(app), pkg)
    ws = w.ws
    ws.add_gels([two])
    ws.set_tool("select")
    ws.set_tab("figure")
    settle()
    s0 = ws.project.strips[0].shift
    times = []
    for k in range(6):
        t = time.perf_counter()
        ws.live_strip_shift(1, s0 + 0.37 * (k + 1))
        w.canvas.repaint()
        times.append(time.perf_counter() - t)
    ws.end_gesture("Line Up Gel")
    assert sorted(times)[len(times) // 2] < 0.06, times   # it was about 0.13 s a move at this size
    close(w)


# ---------------------------------------------------------------------------------------------------- lane label angle


def test_the_lane_label_angle_has_a_field_and_three_buttons_and_every_change_undoes(win):
    ws = win.ws
    place_lanes(win)
    ws.set_tab("labels")
    settle()
    panel = win.inspector.panels["labels"]
    assert not panel.angle.isEnabled() and not panel.angle_steps.isEnabled()   # no lane labels to stand at an angle yet
    ws.quick_labels = "Ladder|0{L|P}|50{L|P}|100{L}"
    ws.apply_quick_labels()
    settle()
    assert panel.angle.isEnabled() and panel.angle.value() == 0 and panel.angle_steps.buttons["0"].isChecked()
    steps = ws.undo.count()
    panel.angle_steps.buttons["45"].click()
    assert ws.project.label_angle == 45 and ws.undo.count() == steps + 1 and ws.undo.undoText() == "Label Angle"
    assert panel.angle.value() == 45 and panel.angle.text() == "45°" and panel.angle_steps.buttons["45"].isChecked()
    assert not panel.angle_steps.buttons["0"].isChecked()
    panel.angle_steps.buttons["45"].click()   # the same again: nothing to undo, and it stays lit
    assert ws.undo.count() == steps + 1 and panel.angle_steps.buttons["45"].isChecked()
    panel.angle.setFocus()
    panel.angle.lineEdit().selectAll()
    QTest.keyClicks(panel.angle, "30.5")
    QTest.keyClick(panel.angle, Qt.Key.Key_Return)
    assert ws.project.label_angle == 30.5 and ws.undo.count() == steps + 2
    assert not any(b.isChecked() for b in panel.angle_steps.buttons.values())   # none of the three
    panel.angle.lineEdit().selectAll()
    QTest.keyClicks(panel.angle, "120")   # any angle
    QTest.keyClick(panel.angle, Qt.Key.Key_Return)
    assert ws.project.label_angle == 120
    panel.angle.clearFocus()
    ws.set_label_angle(450)   # more than a full turn comes back round
    settle()
    assert ws.project.label_angle == 90 and panel.angle_steps.buttons["90"].isChecked()
    for row in (r for r in ws.project.rows if r.type == "groups"):
        assert row.rotation == 0   # only lane labels turn
    assert [r.rotation for r in ws.project.rows if r.type == "lanes"] == [90]
    ws.quick_labels = "Ladder|0{L|P}|50{L|P}|100{L|P}"   # typing the labels again keeps the angle
    ws.apply_quick_labels()
    assert ws.project.label_angle == 90
    for _ in range(3):   # the labels, 90, 12
        ws.undo.undo()
    assert ws.project.label_angle == 30.5
    ws.undo.undo()
    ws.undo.undo()
    assert ws.project.label_angle == 0


def test_clicking_a_lane_label_at_an_angle_opens_it_where_its_rotated_box_is(win):
    ws = win.ws
    place_lanes(win)
    ws.set_lane_label(4, "Sample")
    ws.set_label_angle(45)
    ws.set_tool("select")
    settle()
    t = next(t for t in ws.layout.texts if t.role.kind == "laneLabel")
    assert t.rotation == 45
    corners = t.box
    cx, cy = sum(c[0] for c in corners) / 4, sum(c[1] for c in corners) / 4
    c = win.canvas
    assert win.canvas.hit_text(c.to_view(cx, cy)) is t
    click(win, c.to_view(cx, cy).toPoint())
    assert isinstance(popup(), TextEditor) and ws.selection == ("text", t.role)
    popup().close()
    ws.selection = None
    # the corner of the box around it where there is no text isn't the label: it's nothing
    b = t.bounds
    for x, y in ((b.x + 1, b.y + 1), (b.max_x - 1, b.max_y - 1)):
        assert not t.contains(x, y) and win.canvas.hit_text(c.to_view(x, y)) is None
        click(win, c.to_view(x, y).toPoint())
        assert popup() is None and ws.selection is None
    # and the label's own ends are inside it
    (x0, y0), (x1, y1) = corners[0], corners[2]
    for fx in (0.1, 0.9):
        assert win.canvas.hit_text(c.to_view(x0 + (x1 - x0) * fx, y0 + (y1 - y0) * fx)) is t


def test_copy_figure_and_export_say_why_strict_cannot_stack_the_gels(win, tmp_path, boxes):
    import tifffile
    ws = win.ws
    deep = tmp_path / "deep.tif"
    tifffile.imwrite(deep, (np.arange(200 * 700).reshape(200, 700) % 60000).astype(np.uint16))
    assert not ws.add_gels([deep])
    assert ws.export_problem is None   # a new gel doesn't keep its original pixels, so it needn't be stored the same way
    ws.set_strict(True)   # the chosen gel, Gel 2
    why = ("The gels that keep their original pixels must be stored the same way, but Gel 2 is 16-bit gray, the gel with the "
           "lanes 8-bit gray. Turn off Keep original pixels for a gel to export.")
    assert ws.export_problem == why
    win.copy_figure()
    win.export("png")
    assert [b.split("\n\n")[0] for b in boxes] == ["Copy failed.", "Export failed."] and all(why in b for b in boxes)
    ws.set_strict(False)
    assert ws.export_problem is None
    win.copy_figure()
    assert len(boxes) == 2 and QApplication.clipboard().mimeData().hasImage()
