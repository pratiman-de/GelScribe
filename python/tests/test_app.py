"""The window, used the way a person would: clicks, drags and typing on a made-up gel, off-screen."""
import io
import xml.etree.ElementTree as ET

import numpy as np
import pikepdf
import pytest
import tifffile
from PIL import Image
from PySide6.QtCore import QPoint, Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QFileDialog, QMessageBox

from gelscribe.app import theme
from gelscribe.app.editors import NameEditor, TextEditor, TickEditor
from gelscribe.app.main import Controller
from gelscribe.core import labels as ql
from gelscribe.core import ops
from gelscribe.core.package import GelPackage

LANES = [60 + 70 * i for i in range(8)]   # lane centres; the ladder runs in lane 1
LADDER_YS = [60, 95, 140, 200, 270, 340]
SAMPLE_Y = 180
NO = Qt.KeyboardModifier.NoModifier


@pytest.fixture(scope="session")
def app():
    a = QApplication.instance() or QApplication([])
    theme.apply(a)
    return a


@pytest.fixture
def gel(tmp_path):
    h, w = 420, 600
    yy, xx = np.mgrid[0:h, 0:w]
    img = np.full((h, w), 235.0)

    def band(cx, cy, amp):
        return amp * np.exp(-((yy - cy) / 4.0) ** 2 / 2) * (np.abs(xx - cx) < 24)
    for y in LADDER_YS:
        img -= band(LANES[0], y, 170)
    for cx in LANES[1:]:
        img -= band(cx, SAMPLE_Y, 190)
    path = tmp_path / "synthetic gel.png"
    Image.fromarray(np.clip(img, 0, 255).round().astype(np.uint8)).save(path)
    return path


def settle(n=3):
    for _ in range(n):
        QApplication.processEvents()


def show(ctl, pkg=None):
    w = ctl.new_window(pkg)
    w.resize(1440, 920)
    w.activateWindow()
    QTest.qWaitForWindowActive(w, 2000)
    settle()
    return w


def close(w):
    """Gone without the save prompt."""
    w.ws.dispose()
    w.ctl.closed(w)
    w.hide()
    w.deleteLater()
    settle()


@pytest.fixture
def win(app, gel):
    w = show(Controller(app), GelPackage.create_from(gel))
    yield w
    close(w)


def at(w, x, y) -> QPoint:
    """Where gel pixel (x, y) is on the canvas."""
    p = w.canvas.px_view(x, y)
    return QPoint(round(p.x()), round(p.y()))


def click(w, pt, mod=NO):
    QTest.mouseClick(w.canvas, Qt.MouseButton.LeftButton, mod, pt)
    settle()


def drag(w, a, b, steps=6):
    c = w.canvas
    QTest.mousePress(c, Qt.MouseButton.LeftButton, NO, a)
    for k in range(1, steps + 1):
        QTest.mouseMove(c, QPoint(a.x() + (b.x() - a.x()) * k // steps, a.y() + (b.y() - a.y()) * k // steps))
    QTest.mouseRelease(c, Qt.MouseButton.LeftButton, NO, b)
    settle()


def popup():
    settle()
    return QApplication.activePopupWidget()


def place_lanes(w):
    w.ws.set_tool("lanes")
    for x in [(a + b) // 2 for a, b in zip(LANES, LANES[1:])]:
        click(w, at(w, x, 300))
    return w.ws.project.lane_count


def lane_labels(p):
    return next((r.labels for r in p.rows if r.type == "lanes"), None)


# ---------------------------------------------------------------------------------------------------- canvas


def test_lane_clicks_drags_and_alt_click(win):
    ws = win.ws
    n0 = ws.undo.count()
    assert place_lanes(win) == 8
    assert ws.undo.count() == n0 + 7   # one step per click
    d = ws.project.lanes.dividers[2]
    x0 = d.x_at(250, ws.image_h)
    steps = ws.undo.count()
    drag(win, at(win, x0, 250), at(win, x0 + 12, 250))
    assert ws.undo.count() == steps + 1   # the whole drag is one step
    assert abs(ws.project.lanes.dividers[2].x_top - (d.x_top + 12)) <= 1
    ws.undo.undo()
    assert ws.project.lanes.dividers[2].x_top == d.x_top
    click(win, at(win, x0, 250), Qt.KeyboardModifier.AltModifier)
    assert len(ws.project.lanes.dividers) == 6 and ws.project.lane_count == 7


def test_ladder_clicks_snap_and_take_the_next_size(win):
    ws = win.ws
    place_lanes(win)
    ws.set_tool("ladder")
    click(win, at(win, LANES[0], LADDER_YS[0] + 3))
    ed = popup()
    assert isinstance(ed, TickEditor)
    b = ws.project.ladder.bands[0]
    assert abs(b.y - LADDER_YS[0]) <= 1   # snapped to the band's centre
    assert b.auto and b.size == ws.ladder_sizes[0]   # a guess from the ladder's list
    divider = win.canvas.mapToGlobal(at(win, (LANES[0] + LANES[1]) // 2, LADDER_YS[1])).x()
    assert ed.geometry().left() > divider   # beside the ladder lane, so the next band down stays clickable
    ed.field.selectAll()
    QTest.keyClicks(ed.field, "250")
    QTest.keyClick(ed.field, Qt.Key.Key_Return)
    assert popup() is None
    b = ws.project.ladder.bands[0]
    assert b.size == 250 and not b.auto
    # the next click, while its editor is open, closes it and places the next tick
    click(win, at(win, LANES[0], LADDER_YS[1] - 2))
    assert isinstance(popup(), TickEditor)
    click(win, at(win, LANES[0], LADDER_YS[2] + 2))
    bands = ws.project.ladder.bands
    assert len(bands) == 3 and [abs(b.y - y) <= 1 for b, y in zip(bands, LADDER_YS)] == [True] * 3
    assert [b.size for b in bands[1:]] == ws.ladder_sizes[1:3]
    popup().close()


def test_band_name_editor_takes_a_two_line_name_and_an_empty_one_deletes(win):
    ws = win.ws
    place_lanes(win)
    ws.set_tool("names")
    click(win, at(win, LANES[3], SAMPLE_Y + 3))
    ed = popup()
    assert isinstance(ed, NameEditor)
    a = ws.project.annotations[0]
    assert abs(a.y - SAMPLE_Y) <= 1 and a.side == "right"
    QTest.keyClicks(ed.field, "Protein")
    QTest.keyClick(ed.field, Qt.Key.Key_Return, Qt.KeyboardModifier.ControlModifier)
    QTest.keyClicks(ed.field, "fragment")
    QTest.keyClick(ed.field, Qt.Key.Key_Return)
    assert popup() is None
    assert ws.project.annotations[0].text == "Protein\nfragment"
    assert ws.recent_names[0] == "Protein\nfragment"
    # click the name again, clear it, Enter: the name goes
    y = win.canvas.px_view(0, ws.project.annotations[0].y).y()
    click(win, QPoint(round(win.canvas.gel_view().right() + 10), round(y)))
    ed = popup()
    assert isinstance(ed, NameEditor)
    ed.field.selectAll()
    QTest.keyClick(ed.field, Qt.Key.Key_Delete)
    QTest.keyClick(ed.field, Qt.Key.Key_Return)
    assert ws.project.annotations == []


def test_clicking_a_label_on_the_figure_edits_it(win):
    ws = win.ws
    ws.set_title("Old title")
    settle()
    t = next(t for t in ws.layout.texts if t.role.kind == "title")
    click(win, win.canvas._text_view(t).center().toPoint())
    ed = popup()
    assert isinstance(ed, TextEditor)
    ed.field.selectAll()
    QTest.keyClicks(ed.field, "New title")
    QTest.keyClick(ed.field, Qt.Key.Key_Return)
    assert ws.project.title == "New title"
    ws.undo.undo()
    assert ws.project.title == "Old title"


def test_crop_drag_is_one_undo_step_and_enter_finishes(win):
    ws = win.ws
    ws.set_tool("crop")
    settle()
    c = ws.crop
    steps = ws.undo.count()
    drag(win, win.canvas.to_view(c.x0, c.y0).toPoint(), win.canvas.to_view(c.x0 + 40, c.y0 + 30).toPoint())
    n = ws.crop
    assert abs(n.x0 - (c.x0 + 40)) <= 1 and abs(n.y0 - (c.y0 + 30)) <= 1 and (n.x1, n.y1) == (c.x1, c.y1)
    assert ws.undo.count() == steps + 1
    win.canvas.setFocus()
    QTest.keyClick(win.canvas, Qt.Key.Key_Return)
    assert ws.tool == "select"


def test_straighten_asks_before_leaving_strict(win):
    ws = win.ws
    assert ws.project.strict
    ws.ask_straighten.disconnect(win.ask_straighten)   # no dialog in a test
    asked = []
    ws.ask_straighten.connect(asked.append)
    ws.set_tool("straighten")
    settle()
    drag(win, win.canvas.to_view(100, 200).toPoint(), win.canvas.to_view(500, 212).toPoint())
    assert ws.project.strict and ws.project.rotate_deg == 0
    assert len(asked) == 1 and asked[0] == pytest.approx(ops.leveling_angle((100, 200), (500, 212)), abs=0.3)
    ws.confirm_straighten(asked[0])
    assert not ws.project.strict and ws.project.rotate_deg == pytest.approx(asked[0], abs=0.005)   # 0.01° steps
    ws.undo.undo()
    assert ws.project.strict and ws.project.rotate_deg == 0


def test_tool_keys_and_delete(win):
    ws = win.ws
    place_lanes(win)
    c = win.canvas
    c.setFocus()
    for key, tool in ((Qt.Key.Key_K, "ladder"), (Qt.Key.Key_N, "names"), (Qt.Key.Key_C, "crop"),
                      (Qt.Key.Key_V, "select"), (Qt.Key.Key_L, "lanes")):
        QTest.keyClick(c, key)
        assert ws.tool == tool
    d = ws.project.lanes.dividers[0]
    click(win, at(win, d.x_at(250, ws.image_h), 250))
    assert ws.selection == ("divider", 0)
    QTest.keyClick(c, Qt.Key.Key_Delete)
    assert len(ws.project.lanes.dividers) == 6


# ---------------------------------------------------------------------------------------------------- inspector


def test_quick_labels_follow_typing_and_undo_in_one_step(win):
    ws = win.ws
    place_lanes(win)
    ws.set_tab("labels")
    settle()
    panel = win.inspector.panels["labels"]
    q = panel.quick
    q.setFocus()
    steps = ws.undo.count()
    QTest.keyClicks(q, "M|0{L|P}|5{L|P}|9{L|P|L}")
    assert lane_labels(ws.project) == ["M", "L", "P", "L", "P", "L", "P", "L"]   # live, while typing
    assert [g.text for g in ws.project.rows[1].groups] == ["0", "5", "9"]
    win.canvas.setFocus()   # leaving the field ends the typing run
    settle()
    assert not ws.typing_quick and ws.undo.count() == steps + 1
    # the other way: a lane label typed in the list shows up in Quick labels
    f = panel._lane_fields[0]
    f.setFocus()
    f.selectAll()
    QTest.keyClicks(f, "Ladder")
    QTest.keyClick(f, Qt.Key.Key_Return)
    settle()
    assert q.toPlainText() == "Ladder|0{L|P}|5{L|P}|9{L|P|L}"
    ws.undo.undo()
    ws.undo.undo()
    settle()
    assert lane_labels(ws.project) is None and q.toPlainText() == ""


def test_contrast_slider_drag_is_one_undo_step_and_screen_only(win):
    ws = win.ws
    ws.set_tab("figure")
    settle()
    s = win.inspector.panels["figure"].bright.slider
    steps = ws.undo.count()
    base = s.value()
    s.setSliderDown(True)
    for v in (base + 10, base + 20, base + 30):
        s.setValue(v)
    s.setSliderDown(False)
    settle()
    assert ws.undo.count() == steps + 1
    assert ws.project.strict and not ws.project.display.is_identity
    gel = ws.working.figure_image(ws.project)
    assert np.array_equal(gel, ws.source.pixels)   # Strict: exports keep the original pixels


@pytest.mark.parametrize("tab", ["labels", "ladder", "names", "figure", "export"])
def test_inspector_panels_fit_its_width(win, tab):
    ws = win.ws
    place_lanes(win)
    ws.quick_labels = "Ladder|0{L|P}|125{L|P}|250{L|P}|500{L}"
    ws.apply_quick_labels()
    ws.add_name(SAMPLE_Y, "A rather long band name")
    ws.set_tab(tab)
    settle()
    viewport = win.inspector.scroll.viewport().width()
    assert win.inspector.holder.width() <= viewport
    assert win.inspector.panels[tab].minimumSizeHint().width() <= viewport


# ---------------------------------------------------------------------------------------------------- files


def test_a_second_gel_lines_up_moves_and_comes_out(win, tmp_path):
    """Add Gel: it stacks under the first, lines up by itself, is chosen by a click, moves and comes out again."""
    place_lanes(win)
    h, w = 300, 640
    yy, xx = np.mgrid[0:h, 0:w]
    img = np.full((h, w), 235.0)
    for cx in LANES:
        img -= 190 * np.exp(-((yy - 120) / 4.0) ** 2 / 2) * (np.abs(xx - (cx + 20)) < 24)
    path = tmp_path / "second.png"
    Image.fromarray(np.clip(img, 0, 255).round().astype(np.uint8)).save(path)
    ws = win.ws
    ws.add_gels([path])
    settle()
    p = ws.project
    assert len(p.strips) == 1 and abs(p.strips[0].shift - 20) <= 1 and ws.active_strip == 1
    assert [q.strip for q in ws.stack.pieces] == [None, 1] and "Lanes line up" in (ws.align_note or "")
    shown = ws.display_cropped()   # what the canvas draws: both gels, at the stack's size
    assert (shown.width(), shown.height()) == (round(ws.stack.crop.width), round(ws.stack.crop.height))
    # a click in the first gel chooses it; the Gels list follows
    ws.set_tool("select")
    click(win, at(win, 330, 200))
    assert ws.active_strip is None
    gels = win.inspector.panels["figure"].gels
    ws.choose_tab("figure")
    settle()
    assert gels.list.count() == 2 and gels.list.currentRow() == 0
    ws.move_gel(0, 1)   # the gel with the lanes to the bottom
    settle()
    assert ws.project.main_position == 1 and [q.strip for q in ws.stack.pieces] == [1, None]
    assert gels.list.item(1).text().endswith("LANES")
    ws.undo.undo()
    assert ws.project.main_position == 0
    assert len(ws.export_bytes("png")) > 1000
    ws.choose_gel(1)
    ws.remove_active_gel()
    assert ws.project.strips == []
    ws.undo.undo()
    assert len(ws.project.strips) == 1 and ws.strip_images


def test_save_writes_a_project_folder_and_save_again_reuses_it(win, tmp_path):
    ws = win.ws
    place_lanes(win)
    ws.set_title("Saved")
    folder = tmp_path / "Saved.gelscribe"
    ws.save_to(folder)
    assert (folder / "project.json").exists() and not ws.dirty
    pkg = GelPackage.read(folder)
    assert pkg.project == ws.project and pkg.image_data == ws.image_data and pkg.image_intact
    ws.set_title("Saved again")
    assert ws.dirty
    assert win.save()   # no dialog: it has a folder
    assert GelPackage.read(folder).project.title == "Saved again" and not ws.dirty


def test_save_as_adds_the_extension(win, tmp_path, monkeypatch):
    monkeypatch.setattr(QFileDialog, "getSaveFileName", staticmethod(lambda *a, **k: (str(tmp_path / "My gel"), "")))
    assert win.save_as()
    assert (tmp_path / "My gel.gelscribe" / "project.json").exists()
    assert win.ws.folder == tmp_path / "My gel.gelscribe" and win.ws.title == "My gel.gelscribe"


def test_opening_a_project_by_folder_or_project_json(app, win, tmp_path):
    place_lanes(win)
    folder = tmp_path / "P.gelscribe"
    win.ws.save_to(folder)
    n = len(win.ctl.windows)
    win.ctl.open_path(folder / "project.json")   # already open: no second window
    assert len(win.ctl.windows) == n
    ctl = Controller(app)
    for target in (folder, folder / "project.json"):
        ctl.open_path(target)
        w = ctl.windows[-1]
        assert w.ws.project == win.ws.project and w.ws.folder == folder
        close(w)


def test_choosing_an_image_in_an_empty_window_and_undo(app, gel):
    w = show(Controller(app))
    assert w.stack.currentWidget() is w.drop
    assert not w.zoom_label.isVisible()   # no image, no zoom (it used to say 42400%)
    w.adopt_image(gel)
    settle()
    assert w.ws.has_image and w.stack.currentWidget() is w.canvas and w.inspector.isVisible()
    assert w.zoom_label.isVisible() and 10 <= int(w.zoom_label.text().rstrip("%")) <= 1000
    w.ws.undo.undo()
    settle()
    assert not w.ws.has_image and w.stack.currentWidget() is w.drop
    close(w)


def test_closing_with_changes_asks(win, monkeypatch):
    win.ws.set_title("Unsaved")
    answers = []

    def answer(button):
        def exec_(box):
            answers.append(box.text())
            return button
        return exec_
    monkeypatch.setattr(QMessageBox, "exec", answer(QMessageBox.StandardButton.Cancel))
    assert not win.close() and win.isVisible()
    monkeypatch.setattr(QMessageBox, "exec", answer(QMessageBox.StandardButton.Discard))
    assert win.close()
    assert len(answers) == 2 and "Save the changes" in answers[0]


@pytest.mark.parametrize("fmt", ["pdf", "png", "tiff", "svg"])
def test_export_menu_writes_valid_files(win, tmp_path, monkeypatch, fmt):
    ws = win.ws
    place_lanes(win)
    ws.quick_labels = "Ladder|0{L|P}|125{L|P}|250{L|P}|500{L}"
    ws.apply_quick_labels()
    out = tmp_path / f"figure.{fmt}"
    monkeypatch.setattr(QFileDialog, "getSaveFileName", staticmethod(lambda *a, **k: (str(out), "")))
    win.export(fmt)
    data = out.read_bytes()
    if fmt == "pdf":
        assert len(pikepdf.open(io.BytesIO(data)).pages) == 1
    elif fmt == "png":
        im = Image.open(io.BytesIO(data))
        im.load()
        assert im.mode == "L" and im.size[0] > 600
    elif fmt == "tiff":
        assert tifffile.imread(io.BytesIO(data)).shape[1] > 600
    else:
        assert ET.fromstring(data).tag.endswith("svg")


def test_copy_labels_then_paste_into_another_gel(win, gel):
    ws = win.ws
    ws.quick_labels = "M|0{L|P}"
    ws.apply_quick_labels()
    ws.set_title("Shared")
    win.copy_labels()
    other = show(win.ctl, GelPackage.create_from(gel))
    other.paste_labels(False)
    assert ql.shorthand(other.ws.project) == "M|0{L|P}" and other.ws.project.title == "Shared"
    close(other)


def test_appearance_switches_every_window_and_is_remembered(win):
    from gelscribe.app import settings, theme
    assert theme.mode == "dark"   # the default

    def backdrop():
        return win.canvas.grab().toImage().pixelColor(2, 2).getRgb()[:3]
    assert backdrop() == (27, 27, 29)
    win.ctl.set_appearance("light")
    try:
        assert theme.mode == "light" and settings().value("appearance") == "light"
        assert backdrop() == (203, 203, 203) and win.appearance_actions["light"].isChecked()
    finally:
        win.ctl.set_appearance("dark")
    assert backdrop() == (27, 27, 29) and settings().value("appearance") == "dark"


def test_tools_and_inspector_tabs_follow_each_other(win):
    ws, tabs = win.ws, win.inspector.tab_buttons
    for tool, tab in (("ladder", "ladder"), ("names", "names"), ("lanes", "labels"), ("crop", "figure"),
                      ("straighten", "figure")):
        win.tool_buttons[tool].click()
        assert (ws.tool, ws.inspector_tab) == (tool, tab)
    win.tool_buttons["select"].click()
    assert (ws.tool, ws.inspector_tab) == ("select", "figure")   # Select keeps the tab
    for tab, tool in (("ladder", "ladder"), ("names", "names"), ("labels", "lanes"), ("figure", "select"),
                      ("export", "select")):
        tabs[tab].click()
        assert (ws.tool, ws.inspector_tab) == (tool, tab)
        assert tabs[tab].isChecked() and win.tool_buttons[tool].isChecked()
    win.tool_buttons["crop"].click()
    tabs["figure"].click()
    assert ws.tool == "crop"   # cropping stays on in its own tab


# ---------------------------------------------------------------------------------------------------- shortcuts

CTRL, SHIFT = Qt.KeyboardModifier.ControlModifier, Qt.KeyboardModifier.ShiftModifier


@pytest.fixture
def keys():
    from gelscribe.app import keys as k
    k.store().reset_all()
    yield k
    k.store().reset_all()


def test_shortcut_changes_reach_the_menus_and_are_saved(win, keys):
    acts = win.key_actions
    assert acts["exportPDF"].shortcut().toString() == "Ctrl+E" and acts["tool:ladder"].shortcut().toString() == "K"
    assert keys.store().set("exportPDF", "Ctrl+Shift+E") is None
    assert acts["exportPDF"].shortcut().toString() == "Ctrl+Shift+E"
    assert keys.store().set("copyFigure", "ctrl+shift+e") == "exportPDF"   # the keys move; PDF has none now
    assert acts["copyFigure"].shortcut().toString() == "Ctrl+Shift+E" and acts["exportPDF"].shortcut().isEmpty()
    assert keys.KeyStore().text("copyFigure") == "Ctrl+Shift+E"   # read back from GelScribe.ini
    keys.store().reset_all()
    assert acts["exportPDF"].shortcut().toString() == "Ctrl+E" and not keys.store().any_changed


def test_tool_keys_work_off_the_canvas_but_not_while_typing(win, keys):
    ws = win.ws
    ws.set_tool("select")
    tab = win.inspector.tab_buttons["export"]
    tab.setFocus()
    QTest.keyClick(tab, Qt.Key.Key_K)
    assert ws.tool == "ladder"
    ws.set_tab("labels")
    settle()
    q = win.inspector.panels["labels"].quick
    q.setFocus()
    QTest.keyClicks(q, "c")
    assert ws.tool == "ladder" and q.toPlainText().endswith("c")
    keys.store().set("tool:crop", "J")
    ws.set_tool("select")
    win.canvas.setFocus()
    QTest.keyClick(win.canvas, Qt.Key.Key_C)
    assert ws.tool == "select"   # C is nobody's now
    QTest.keyClick(win.canvas, Qt.Key.Key_J)
    assert ws.tool == "crop"


def test_text_size_and_zoom_keys_dont_collide(win, keys):
    ws, c = win.ws, win.canvas
    c.setFocus()
    zoom = c.zoom_percent()
    QTest.keyClick(c, Qt.Key.Key_Plus, CTRL | SHIFT)   # Ctrl+Shift+= as Qt reports it on a US keyboard
    assert ws.undo.undoText() == "Bigger Text" and c.zoom_percent() == zoom
    QTest.keyClick(c, Qt.Key.Key_Underscore, CTRL | SHIFT)   # Ctrl+Shift+-
    assert ws.undo.undoText() == "Smaller Text"
    QTest.keyClick(c, Qt.Key.Key_Equal, CTRL)
    assert c.zoom_percent() > zoom and ws.undo.undoText() == "Smaller Text"
    bigger = c.zoom_percent()
    QTest.keyClick(c, Qt.Key.Key_Minus, CTRL)
    assert c.zoom_percent() < bigger


def test_recording_shortcuts_in_settings(win, keys):
    win.ctl.show_settings()
    d = win.ctl._settings_dialog
    QTest.qWaitForWindowActive(d, 2000)   # as when you type in it: the document window's shortcuts are asleep
    rec = d.recorder("exportPDF")
    rec.click()
    assert rec.recording and rec.text() == "Press keys…"
    QTest.keyClick(rec, Qt.Key.Key_P)
    assert rec.recording and "need Ctrl" in d.note_label.text()
    QTest.keyClick(rec, Qt.Key.Key_S, CTRL)
    assert rec.recording and "already Save" in d.note_label.text()
    QTest.keyClick(rec, Qt.Key.Key_P, CTRL | SHIFT)
    assert not rec.recording and keys.store().text("exportPDF") == "Ctrl+Shift+P"
    assert win.key_actions["exportPDF"].shortcut().toString() == "Ctrl+Shift+P"
    tool = d.recorder("tool:names")
    tool.click()
    QTest.keyClick(tool, Qt.Key.Key_M, CTRL)
    assert tool.recording and "single key" in d.note_label.text()
    QTest.keyClick(tool, Qt.Key.Key_M)
    assert keys.store().text("tool:names") == "M" and tool.text() == "M"
    tool.click()
    QTest.keyClick(tool, Qt.Key.Key_Escape)   # cancel: keeps M
    assert not tool.recording and keys.store().text("tool:names") == "M"
    tool.click()
    QTest.keyClick(tool, Qt.Key.Key_Delete)   # clear
    assert keys.store().text("tool:names") == "" and tool.text() == "None"
    assert d.reset_all.isEnabled()
    d.reset_all.click()
    assert not keys.store().any_changed and tool.text() == "N" and not d.reset_all.isEnabled()
    d.close()


def test_a_trackpad_pinch_zooms_once_and_stays_under_the_fingers(win):
    """macOS reports a pinch as a native gesture, and Qt can turn the same event into a pinch gesture too: counting
    both doubled every step, so a pinch raced to thousands of percent and slid away from the fingers."""
    from PySide6.QtCore import QPointF
    from PySide6.QtGui import QNativeGestureEvent, QPointingDevice
    c = win.canvas
    at = QPointF(300, 300)
    dev = QPointingDevice.primaryPointingDevice()

    def send(kind, value):
        QApplication.sendEvent(c, QNativeGestureEvent(kind, dev, 2, at, at, QPointF(c.mapToGlobal(at.toPoint())),
                                                      value, QPointF(0, 0)))
    before, anchor = c.scale(), c.to_model(at)
    send(Qt.NativeGestureType.BeginNativeGesture, 0)
    send(Qt.NativeGestureType.ZoomNativeGesture, 0.10)
    send(Qt.NativeGestureType.EndNativeGesture, 0)
    assert c.scale() / before == pytest.approx(1.10)
    after = c.to_model(at)
    assert abs(after[0] - anchor[0]) < 0.5 and abs(after[1] - anchor[1]) < 0.5
