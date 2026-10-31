"""Flip: the gel mirrored as shown, after the quarter turns and before the rotation (a membrane turned over in the transfer)."""
import copy
import json
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from test_app import app, close, gel, settle, show, win   # noqa: F401 (fixtures)
from test_cli import made, run   # noqa: F401 (fixtures)
from test_gels import piece_png

from gelscribe.core import ops, render
from gelscribe.core.image import SourceImage, WorkingImage
from gelscribe.core.model import BandAnnotation, GelProject, GelStrip, LaneDivider, LadderBand, PixelRect

W, H = 80, 40


def project(turn=0) -> GelProject:
    p = GelProject(image="a.png", turn=turn)
    p.crop = PixelRect(10, 5, 60, 30)
    p.lanes.dividers = [LaneDivider(20, 24, 10), LaneDivider(40, 40, 10), LaneDivider(60, 62, 10)]
    ops.add_tick(p, 8, 40, lane=1, gel_center_x=30)
    p.annotations.append(BandAnnotation(y=12, y2=15, text="X"))
    return p


def png(w=W, h=H, seed=5) -> bytes:
    import io
    rng = np.random.default_rng(seed)
    img = rng.integers(0, 256, (h, w)).astype(np.uint8)
    img[:, 18:24] = 30   # a few lanes and bands so the picture is not noise only
    img[10:14, :] = 60
    buf = io.BytesIO()
    Image.fromarray(img).save(buf, format="PNG")
    return buf.getvalue()


def test_the_flip_is_in_the_file_only_when_set_and_round_trips():
    p = project()
    p.strips = [GelStrip(image="b.png")]
    assert '"flip"' not in p.dumps()
    p.flip, p.strips[0].flip = "both", "vertical"
    back = GelProject.loads(p.dumps())
    assert back.flip == "both" and back.strips[0].flip == "vertical"
    d = json.loads(p.dumps())
    assert d["flip"] == "both" and d["strips"][0]["flip"] == "vertical"
    assert GelProject.loads('{"image": "a.png", "flip": "sideways"}').flip == "none"


def test_pixels_are_mirrored_exactly_and_the_turn_comes_first():
    src = SourceImage(png())
    for flip, axes in (("horizontal", 1), ("vertical", 0), ("both", (0, 1))):
        assert np.array_equal(src.flipped(flip).pixels, np.flip(src.pixels, axes))
        assert np.array_equal(src.flipped(flip).gray, np.flip(src.gray, axes))
    assert src.flipped("none") is src and src.flipped("horizontal").sha256 == src.sha256
    # Strict: the figure carries the flipped original values; the turn comes first, then the flip, as shown
    p = GelProject(image="a.png", strict=True, flip="horizontal", turn=1)
    work = WorkingImage(src, p)
    turned = src.turned(1)
    assert np.array_equal(work.source.pixels, np.flip(turned.pixels, 1))
    assert not np.array_equal(work.source.pixels, np.rot90(np.flip(src.pixels, 1), -1))
    assert work.width == H and work.height == W
    assert np.array_equal(work.figure_image(p), np.flip(turned.pixels, 1))
    # (and the turned picture the memo holds is still the unflipped one)
    assert np.array_equal(src.turned(1).pixels, turned.pixels) and src.pixels.shape == (H, W)


def test_marks_move_with_the_image():
    p = project()
    ops.flip(p, None, True, W, H)
    assert p.flip == "horizontal"
    assert [d.x_top for d in p.lanes.dividers] == [19, 39, 59] and [d.x_bottom for d in p.lanes.dividers] == [17, 39, 55]
    assert p.crop == PixelRect(20, 5, 70, 30)
    assert [b.y for b in p.ladder.bands] == [8] and p.annotations[0].y == 12   # up and down stay put
    v = project()
    ops.flip(v, None, False, W, H)
    assert v.flip == "vertical"
    assert [b.y for b in v.ladder.bands] == [31] and v.annotations[0].y == 27 and v.annotations[0].y2 == 24
    assert v.crop == PixelRect(10, 10, 60, 35)
    assert [d.x_top for d in v.lanes.dividers] == [24, 40, 62] and [d.x_bottom for d in v.lanes.dividers] == [20, 40, 60]
    ops.flip(v, None, False, W, H)   # twice is no flip, and nothing has moved
    assert v.flip == "none" and [b.y for b in v.ladder.bands] == [8] and v.crop == project().crop
    assert v.lanes.dividers == project().lanes.dividers
    t = project(turn=1)   # after a quarter turn Flip Horizontally still mirrors left-right as shown
    ops.flip(t, None, True, W, H)
    assert t.flip == "horizontal" and [b.y for b in t.ladder.bands] == [8] and [d.x_top for d in t.lanes.dividers] == [19, 39, 59]
    both = project()
    ops.flip(both, None, True, W, H)
    ops.flip(both, None, False, W, H)
    assert both.flip == "both"


def test_a_quarter_turn_swaps_the_flip_axis():
    q = project()
    q.flip = "horizontal"
    ops.turn(q, None, 1, W, H)
    assert q.turn == 1 and q.flip == "vertical"
    ops.turn(q, None, 2, H, W)
    assert q.turn == 3 and q.flip == "vertical"
    ops.turn(q, None, 3, H, W)
    assert q.turn == 2 and q.flip == "horizontal"
    both = project()
    both.flip = "both"
    ops.turn(both, None, 1, W, H)
    assert both.flip == "both"
    s = project()
    s.strips = [GelStrip(image="b.png", flip="horizontal")]
    ops.turn(s, 1, 1, W, H)
    assert s.strips[0].flip == "vertical" and s.flip == "none"


def test_a_strip_flips_its_own_marks_and_rows():
    p = project()
    p.strips = [GelStrip(image="b.png", top=4, bottom=30, left=10, right=50)]
    p.ladder.bands.append(LadderBand(8, 30, strip=1))
    p.annotations.append(BandAnnotation(y=6, text="S", strip=1))
    ops.flip(p, 1, False, 80, 40)
    assert p.strips[0].flip == "vertical" and p.flip == "none"
    assert (p.strips[0].top, p.strips[0].bottom) == (10, 36) and (p.strips[0].left, p.strips[0].right) == (10, 50)
    assert [b.y for b in p.ladder.bands] == [8, 31] and [a.y for a in p.annotations] == [12, 33]   # the other gel's marks stay
    ops.flip(p, 1, True, 80, 40)
    assert p.strips[0].flip == "both" and (p.strips[0].left, p.strips[0].right) == (30, 70)
    assert p.strip_project(1).flip == "both"


def test_the_export_note_says_it():
    p = project(turn=2)
    p.flip = "horizontal"
    assert "turned 180°, flipped horizontally, crop" in render.export_info(p, "aaa").description
    p.flip = "vertical"
    assert "turned 180°, flipped vertically" in render.export_info(p, "aaa").description
    p.flip = "both"
    assert "turned 180°, flipped horizontally and vertically" in render.export_info(p, "aaa").description
    p.strips = [GelStrip(image="b.png", flip="vertical")]
    assert "flipped vertically" in render.export_info(p, "aaa", strips=[("bbb", None)]).description


def area(src, p):
    return WorkingImage(src, p).figure_image(p)


@pytest.mark.parametrize("strict,degrees,tolerance", [(False, 2.4, 3), (False, 0.0, 0), (True, 2.4, 0)])
def test_a_flip_mirrors_the_shown_straightened_and_cropped_gel_in_place(strict, degrees, tolerance):
    src = SourceImage(png())
    p = project()
    p.strict, p.rotate_deg = strict, degrees
    before = area(src, p).astype(int)
    across, down, both = copy.deepcopy(p), copy.deepcopy(p), copy.deepcopy(p)
    ops.flip(across, None, True, W, H)
    ops.flip(down, None, False, W, H)
    ops.flip(both, None, True, W, H)
    ops.flip(both, None, False, W, H)
    want = 0.0 if degrees == 0 else -degrees
    assert across.rotate_deg == want and down.rotate_deg == want and both.rotate_deg == degrees
    a, d, b = (area(src, q).astype(int) for q in (across, down, both))
    assert a.shape == before.shape
    assert np.abs(a - before[:, ::-1]).max() <= tolerance
    assert np.abs(d - before[::-1, :]).max() <= tolerance
    assert np.abs(b - before[::-1, ::-1]).max() <= tolerance
    assert across.crop == PixelRect(20, 5, 70, 30)   # the same region, mirrored about the centre


def test_flipping_twice_restores_the_project_exactly():
    p = project(turn=1)
    p.rotate_deg, p.strict = 2.4, False
    p.strips = [GelStrip(image="b.png", rotate_deg=-1.5, top=4, bottom=30, left=10, right=50)]
    p.ladder.unit_y = 17
    p.ladder.bands.append(LadderBand(8, 30, strip=1))
    p.annotations.append(BandAnnotation(y=6, text="S", strip=1))
    p.sync_lane_centers(80, 40)
    original = p.dumps()
    for strip in (None, 1):
        for left_right in (True, False):
            q = copy.deepcopy(p)
            ops.flip(q, strip, left_right, 80, 40)
            assert q != p
            ops.flip(q, strip, left_right, 80, 40)
            assert q.dumps() == original and q == p


def test_the_command_line_flips_a_gel(made, capsys):
    assert run(capsys, "edit", made, "--flip", "horizontal")[0] == 0
    from test_cli import project as read
    p = read(made)
    assert p.flip == "horizontal"
    before = p.lanes.dividers[0].x_top
    assert run(capsys, "edit", made, "--flip", "both")[0] == 0   # only the vertical mirror is added
    q = read(made)
    assert q.flip == "both" and q.lanes.dividers[0].x_top == before
    assert run(capsys, "edit", made, "--flip", "NONE")[0] == 0
    r = read(made)
    assert r.flip == "none" and '"flip"' not in (Path(made) / "project.json").read_text(encoding="utf-8")
    code, _, err = run(capsys, "edit", made, "--flip", "sideways")
    assert code != 0 and "--flip wants none, horizontal, vertical or both" in err
    assert "--flip none|horizontal|vertical|both" in run(capsys, "help")[1]


def test_flip_is_one_undoable_step(win):
    ws = win.ws
    steps = ws.undo.count()
    before = ws.project.copy()
    assert not ws.is_flipped(True) and not ws.is_flipped(False)
    ws.flip_active(True)
    assert ws.project.flip == "horizontal" and ws.is_flipped(True) and ws.undo.count() == steps + 1
    ws.flip_active(False)
    assert ws.project.flip == "both" and ws.undo.count() == steps + 2
    assert ws.undo.undoText() == "Flip Gel"
    ws.undo.undo()
    ws.undo.undo()
    assert ws.project == before and not ws.is_flipped(True)
    ws.undo.redo()
    assert ws.project.flip == "horizontal"
    # the buttons and the menu items follow
    insp = win.inspector.panels["figure"]
    insp.refresh()
    assert insp.flip_buttons[True].isChecked() and not insp.flip_buttons[False].isChecked()
    win._fill_flips()
    assert win.flip_actions[True].isChecked() and not win.flip_actions[False].isChecked()
    win.flip_actions[False].trigger()
    assert ws.project.flip == "both"
