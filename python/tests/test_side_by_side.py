"""Gels side by side (radioactive gels, each scanned on its own): the same cases as the Mac app's SideBySide tests, on made-up gels,
and the window's side of it."""
import json
from pathlib import Path

import numpy as np
import pytest
from PySide6.QtCore import QPoint, Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication

QApplication.instance() or QApplication([])   # before anything draws, so the window tests can share it

from test_app import click, close, drag, settle, show, win   # noqa: F401 (fixtures)
from test_app import app, gel   # noqa: F401 (fixtures)
from test_cli import project as read_project
from test_cli import run
from test_gels import piece_png

from gelscribe.app.main import Controller
from gelscribe.core import ops
from gelscribe.core import strips as stacked
from gelscribe.core.image import SourceImage, WorkingImage
from gelscribe.core.layout import layout
from gelscribe.core.model import GelProject, LabelRow, Ladder, LadderBand
from gelscribe.core.package import GelPackage


def two_gels() -> GelPackage:
    """Gel 1 (400 x 200) with 3 lanes, gel 2 (300 x 240) with 2 lanes, side by side."""
    pkg = GelPackage.create(piece_png(400, 200, [70, 200, 330], [50, 150]), "a.png")
    pkg.add_strip(piece_png(300, 240, [80, 220], [70, 190]), "b.png")
    pkg.project.arrangement = "side_by_side"
    ops.set_dividers(pkg.project, [135, 265], 400, 200)
    ops.set_dividers(pkg.project, [150], 300, 240, 1)
    return pkg


def figure(pkg):
    main = WorkingImage(SourceImage(pkg.image_data), pkg.project)
    strips = [WorkingImage(SourceImage(pkg.strip_data(k + 1)), pkg.project.strip_project(k + 1)) for k in range(len(pkg.project.strips))]
    return stacked.StackedFigure(pkg.project, main, strips)


def test_json_round_trip_and_default():
    pkg = two_gels()
    text = pkg.project.dumps()
    assert json.loads(text)["arrangement"] == "side_by_side" and "lanes" in json.loads(text)["strips"][0]
    back = GelProject.loads(text)
    assert back.arrangement == "side_by_side" and len(back.strips[0].lanes.centers) == 2 and back == pkg.project
    stacked_p = pkg.project.copy()
    stacked_p.arrangement = "top_to_bottom"
    assert "arrangement" not in stacked_p.dumps()
    assert GelProject.loads('{"image": "a.png", "arrangement": "sideways"}').arrangement == "top_to_bottom"


def test_lanes_are_numbered_across_and_one_label_row_runs():
    pkg = two_gels()
    p = pkg.project
    assert p.lane_count == 5 and p.lane_slot(4) == (1, 1) and p.continuous_lane(1, 2) == 5 and p.lane_slot(6) is None
    assert list(p.lane_numbers(None)) == [1, 2, 3] and list(p.lane_numbers(1)) == [4, 5]
    p.rows = [LabelRow("lanes", labels=["1", "2", "3", "4", "5"])]
    f = figure(pkg)
    fig = layout(p, 400, 200, f.stack)
    lane_texts = [t for t in fig.texts if t.role.kind == "laneLabel"]
    xs = [t.origin[0] for t in lane_texts]
    assert len(xs) == 5 and xs == sorted(xs)
    assert len({t.origin[1] for t in lane_texts}) == 1   # one row


def test_crop_spans_and_the_separator_is_vertical():
    pkg = two_gels()
    pkg.project.strips[0].shift = 30   # gel 2's row 30 sits at the lanes gel's row 0
    f = figure(pkg)
    s = f.stack
    sep = s.separator
    assert s.side_by_side and [q.strip for q in s.pieces] == [None, 1]
    assert s.pieces[1].left == 400 + sep and s.crop.x0 == 0 and s.crop.x1 == 700 + sep
    assert s.crop.y0 == -30 and s.crop.y1 == 210   # gel 2's first row is 30 above row 0, its last (240) at 210
    img = f.gel
    assert img.shape[1] == 700 + sep and img.shape[0] == 240
    assert (img[:, 400] == 0).all()   # the line is vertical, the figure's whole height, black
    assert (img[0:30, 10] == 255).all()   # gaps are white: above the lanes gel (its rows start 30 down)
    assert (img[230:, 10] == 255).all()


def test_vertical_ladder_fit_and_tops_fallback():
    pkg = two_gels()
    # the lanes gel's ticks at 50/150 (sizes 100/50); gel 2's at 70/190 -> scale 1.2, shift 10
    pkg.project.ladder = Ladder(lane=1, bands=[LadderBand(50, 100), LadderBand(150, 50),
                                               LadderBand(70, 100, strip=1), LadderBand(190, 50, strip=1)])
    p = pkg.project.copy()
    p.strips[0].strict = False
    note = ops.align_vertically(p, 1, (0, 200), 240)
    assert abs(p.strips[0].scale - 1.2) < 1e-9 and abs(p.strips[0].shift - 10) < 1e-9
    assert note == "Lined up on 2 ladder bands, within 0.0 px; stretched 20.0%."
    q = pkg.project.copy()
    q.strips[0].strict = True   # gel 2 keeps original pixels: whole-pixel shift, no stretch
    ops.align_vertically(q, 1, (0, 200), 240)
    assert q.strips[0].scale == 1 and q.strips[0].shift == 30
    # no matching ladder bands: tops line up, the gel sized to the lanes gel's kept height
    r = pkg.project.copy()
    r.ladder.bands = [b for b in r.ladder.bands if b.strip is None]
    r.strips[0].top = 25
    r.strips[0].strict = False
    n = ops.align_vertically(r, 1, (0, 200), 240)
    assert abs(r.strips[0].scale - 215 / 200) < 1e-9 and abs(r.strips[0].shift - 25) < 1e-9
    assert n == "No matching ladder bands; sized to the same height as Gel 1 and tops lined up."
    # keeping original pixels: scale 1, and the note says how far apart the heights are
    r.strips[0].strict = True
    m = ops.align_vertically(r, 1, (0, 200), 240)
    assert r.strips[0].scale == 1 and r.strips[0].shift == 25
    assert m == ("No matching ladder bands; tops lined up. Gel 2 is 215 px tall and Gel 1 200 px (7% different). "
                 "Turn off Keep original pixels for Gel 2 to size it to the same height.")
    r.strips[0].top = None   # nothing to say about the heights when they are the same
    r.strips[0].bottom = 200
    assert ops.align_vertically(r, 1, (0, 200), 240) == "No matching ladder bands on both gels; tops lined up. Place ladder ticks on both to line them up by size."


def test_a_sized_gel_keeps_its_proportions_and_its_lanes_go_with_it():
    pkg = two_gels()
    pkg.project.strips[0].strict = False
    pkg.project.strips[0].scale = 2   # gel 2's pixels are twice the lanes gel's: it is drawn half as wide and half as tall
    f = figure(pkg)
    a, b = f.stack.pieces
    assert b.right - b.left == 150 and b.bottom - b.top == 120
    at = b.to_figure(150, 120)
    assert at[0] == b.left + 75 and np.allclose(b.to_piece(*at), (150, 120))
    centers, _ = pkg.project.figure_lanes(f.stack)
    assert len(centers) == 5 and centers[3] == b.left + 37.5 and centers[4] == b.left + 112.5 and a.right == 400
    assert f.gel.shape[0] == 200 and f.gel.shape[1] == 400 + f.stack.separator + 150   # resampled, still a gel


def test_ladder_labels_come_from_the_leftmost_gel_with_ticks():
    pkg = two_gels()
    pkg.project.ladder = Ladder(lane=1, bands=[LadderBand(70, 100, strip=1), LadderBand(190, 50, strip=1)])
    p = pkg.project
    assert p.is_ladder_label_gel(1) and not p.is_ladder_label_gel(None)
    count = lambda: len([t for t in layout(p, 400, 200, figure(pkg).stack).texts if t.role.kind == "ladderLabel"])
    assert count() == 2
    p.ladder.bands.append(LadderBand(60, 100))   # now the leftmost gel has ticks: only its labels show
    assert count() == 1


def test_provenance_wording():
    pkg = two_gels()
    pkg.project.strips[0].shift = 12
    d = figure(pkg).info().description
    assert "2 separately scanned gels, left to right, with a black line between each:" in d
    assert "shifted 12 px vertically" in d and "the reference for vertical placement" in d
    pkg.project.arrangement = "top_to_bottom"
    assert "top to bottom" in figure(pkg).info().description


def test_switching_keeps_each_gels_data_and_starts_the_placement_over():
    p = two_gels().project
    p.strips[0].shift, p.strips[0].scale = 9.0, 1.5
    p.arrangement = "side_by_side"
    before = p.copy()
    ops.set_arrangement(p, "top_to_bottom")
    assert p.strips[0].lanes == before.strips[0].lanes and p.lanes == before.lanes and p.lane_count == 3
    assert p.strips[0].shift == 0 and p.strips[0].scale == 1
    ops.set_arrangement(p, "side_by_side")
    before.strips[0].shift, before.strips[0].scale = 0.0, 1.0
    assert p == before and p.lane_count == 5


def test_top_to_bottom_is_untouched():
    pkg = two_gels()
    pkg.project.arrangement = "top_to_bottom"
    s = figure(pkg).stack
    assert not s.side_by_side and s.crop.x0 >= 0 and s.pieces[1].top > s.pieces[0].bottom


def test_a_gels_scale_is_uniform_and_the_sides_are_not_scaled_apart():
    p = two_gels().project
    p.strips[0].strict = False
    p.strips[0].scale = 150.0
    p.sanitize()
    assert p.strips[0].scale == 100   # side by side a gel may be sized 0.01 to 100 times
    p.arrangement = "top_to_bottom"
    p.sanitize()
    assert p.strips[0].scale == 2


# ---------------------------------------------------------------------------------------------------- the command line


def test_cli_arrangement_own_lanes_and_vertical_align(tmp_path, capsys):
    a, b = tmp_path / "a.png", tmp_path / "b.png"
    a.write_bytes(piece_png(400, 200, [70, 200, 330], [50, 150]))
    b.write_bytes(piece_png(300, 240, [80, 220], [70, 190]))
    code, out, _ = run(capsys, "new", a)
    folder = Path(out.strip())
    assert code == 0 and run(capsys, "edit", folder, "--add-gel", b)[0] == 0
    code, _, err = run(capsys, "edit", folder, "--arrangement", "sideways")
    assert code != 0
    assert "--arrangement wants top-to-bottom or side-by-side" in err
    code, _, err = run(capsys, "edit", folder, "--arrangement", "side-by-side", "--dividers", "135,265")
    assert code == 0 and "gel 2: No matching ladder bands; sized to the same height as Gel 1 and tops lined up." in err
    code, out, err = run(capsys, "edit", folder, "--gel", 2, "--dividers", "150", "--align", "auto", "--strict", "off")
    assert code == 0 and "sized to the same height as Gel 1 and tops lined up." in err and "(vertical)." in err
    j = json.loads((folder / "project.json").read_text())
    assert j["arrangement"] == "side_by_side"
    assert len(j["strips"][0]["lanes"]["centers"]) == 2 and len(j["lanes"]["centers"]) == 3 and out.startswith("5 lanes")
    code, _, err = run(capsys, "edit", folder, "--shift", 3)
    assert code == 1 and "has the lanes the other gels are placed against" in err
    code, _, err = run(capsys, "edit", folder, "--gel", 2, "--scale", 500)
    assert code == 1 and "(side by side 0.01 to 100)" in err
    assert run(capsys, "render", folder, "-o", tmp_path / "out", "--formats", "png")[0] == 0
    assert run(capsys, "edit", folder, "--arrangement", "top-to-bottom")[0] == 0
    assert "arrangement" not in json.loads((folder / "project.json").read_text())
    assert read_project(folder).strips[0].lanes is not None   # kept in the file, unused


def test_cli_sizes_a_gel_added_side_by_side(tmp_path, capsys):
    a, b = tmp_path / "a.png", tmp_path / "b.png"
    a.write_bytes(piece_png(400, 200, [70, 200, 330], [50, 150]))
    b.write_bytes(piece_png(300, 240, [80, 220], [70, 190]))
    folder = Path(run(capsys, "new", a)[1].strip())
    assert run(capsys, "edit", folder, "--arrangement", "side-by-side")[0] == 0
    code, _, err = run(capsys, "edit", folder, "--add-gel", b)
    assert code == 0 and "gel 2: No matching ladder bands; sized to the same height as Gel 1 and tops lined up." in err
    assert abs(read_project(folder).strips[0].scale - 1.2) < 1e-9


# ---------------------------------------------------------------------------------------------------- the window


@pytest.fixture
def side(app, tmp_path):
    ctl = Controller(app)
    w = show(ctl, two_gels())
    w.ws.set_tool("select")
    settle()
    yield w
    close(w)


def test_the_arrangement_switch_is_undoable_and_sizes_the_gels(app, tmp_path):
    pkg = two_gels()
    pkg.project.arrangement = "top_to_bottom"
    w = show(Controller(app), pkg)
    ws = w.ws
    ws.set_arrangement("side_by_side")
    settle()
    assert ws.project.is_side_by_side and ws.stack.side_by_side
    assert ws.align_note and "sized to the same height as Gel 1" in ws.align_note   # gel 2 doesn't keep its pixels: sized
    ws.undo.undo()
    settle()
    assert ws.project.arrangement == "top_to_bottom" and not ws.stack.side_by_side
    close(w)


def test_the_lane_tool_is_off_in_the_figure_and_works_in_each_gels_own_view(side):
    ws = side.ws
    ws.set_tool("lanes")
    assert ws.tool == "select" and ws.tool_note and "each gel's own view" in ws.tool_note
    ws.show_gel(1)
    ws.set_tool("lanes")
    assert ws.tool == "lanes" and ws.lane_gel == 1
    n = len(ws.project.strips[0].lanes.dividers)
    main = len(ws.project.lanes.dividers)
    # a click between lanes on gel 2's own view adds a divider to gel 2, not to the gel with the lanes
    p = side.canvas.to_view(100, 120)
    click(side, QPoint(round(p.x()), round(p.y())))
    assert len(ws.project.strips[0].lanes.dividers) == n + 1 and len(ws.project.lanes.dividers) == main
    assert ws.project.lane_count == 6 and list(ws.project.lane_numbers(1)) == [4, 5, 6]
    ws.show_figure()
    assert ws.tool == "select"   # the figure has no dividers to set


def test_each_gel_shows_its_own_dividers_numbered_across_and_the_labels_use_the_same_numbers(side):
    ws = side.ws
    pix = side.grab()
    assert not pix.isNull()   # the figure paints (every gel's dividers and the lane numbers across all of them)
    ws.show_gel(None)
    ws.set_tool("lanes")
    assert ws.tool == "lanes" and ws.lane_gel is None
    ws.quick_labels = "A|B|C|D|E"
    ws.apply_quick_labels()
    lane_row = next(r for r in ws.project.rows if r.type == "lanes")
    assert lane_row.labels == ["A", "B", "C", "D", "E"]   # Quick labels address the five continuous lanes


def test_dragging_a_gel_moves_it_up_or_down_and_the_arrows_nudge_it(side):
    ws = side.ws
    ws.choose_gel(1)
    ws.project.strips[0].strict = True
    q = ws.stack.piece(1)
    mid = side.canvas.px_view((q.left + q.right) / 2, (q.top + q.bottom) / 2)
    a = QPoint(round(mid.x()), round(mid.y()))
    before = ws.project.strips[0].shift
    drag(side, a, QPoint(a.x(), a.y() + 12))
    assert ws.project.strips[0].shift != before   # a drag changes the gel's vertical placement
    assert ws.project.strips[0].shift == round(ws.project.strips[0].shift)
    after = ws.project.strips[0].shift
    ws.selection = None
    QTest.keyClick(side.canvas, Qt.Key.Key_Up)
    settle()
    assert ws.project.strips[0].shift == after + 1   # a positive shift moves the gel up
    QTest.keyClick(side.canvas, Qt.Key.Key_Down, Qt.KeyboardModifier.ShiftModifier)
    settle()
    assert ws.project.strips[0].shift == after - 9
    ws.choose_gel(None)
    s = ws.project.strips[0].shift
    ws.set_shift(5)   # the gel with the lanes is what the others are placed against: it stays put
    assert ws.project.main_shift == 0 and ws.project.strips[0].shift == s


def test_stretch_sizes_a_gel_about_its_top_and_keeps_it_there(side):
    ws = side.ws
    ws.choose_gel(1)
    ws.project.strips[0].strict = False
    ws.set_scale(1.5)
    settle()
    q = ws.stack.piece(1)
    top = ws.project.strips[0].used_rows(240)[0]
    assert abs(ws.project.strips[0].scale - 1.5) < 1e-9
    before = q.top
    ws.set_scale(2.0)
    settle()
    assert abs(ws.stack.piece(1).top - before) < 1e-9   # the gel's top stays where it was
    assert abs(ws.stack.piece(1).source_top - top) < 1e-9
    ws.choose_gel(None)
    assert ws.gel_shift(None) == 0   # (no sideways shift for the lanes gel side by side)


def test_the_gels_section_offers_the_arrangement_and_vertical_fields(side):
    ins = side.inspector
    ws = side.ws
    ws.choose_gel(1)
    settle()
    from gelscribe.app.inspector import GelsSection
    sec = ins.findChild(GelsSection)
    sec.refresh()
    assert sec.shift_label.text() == "Shift up/down" and sec.back.text() == "↑"
    assert sec.arrangement.buttons["side_by_side"].isChecked()
    sec.arrangement.chosen.emit("top_to_bottom")
    settle()
    assert not ws.project.is_side_by_side
    sec.refresh()
    assert sec.shift_label.text() == "Shift" and sec.back.text() == "←"


def test_a_gel_added_side_by_side_is_sized_and_lined_up_at_once(app, tmp_path):
    pkg = two_gels()
    w = show(Controller(app), pkg)
    ws = w.ws
    path = tmp_path / "c.png"
    path.write_bytes(piece_png(500, 400, [100, 250, 400], [100, 300]))
    assert not ws.add_gels([path])
    k = len(ws.project.strips)
    assert ws.active_strip == k and ws.align_note == "No matching ladder bands; sized to the same height as Gel 1 and tops lined up."
    assert abs(ws.project.strips[k - 1].scale - 2.0) < 1e-9   # 400 rows against the lanes gel's 200
    close(w)
