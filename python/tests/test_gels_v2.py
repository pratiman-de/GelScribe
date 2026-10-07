"""Several gels, version 2: the line between gels (black or white), Keep original pixels for each gel on its own, and the
switcher with the view of one gel."""
import io
import json
from pathlib import Path

import numpy as np
import pytest
import tifffile
from PIL import Image

from PySide6.QtCore import QPoint, Qt
from PySide6.QtTest import QTest

from test_app import LANES, NO, app, at, click, close, drag, gel, place_lanes, popup, settle, show, win   # noqa: F401 (fixtures)
from test_gels import MAIN_LANES, cut_blot, piece_png, stack, working

from gelscribe.core import ops, render
from gelscribe.core import strips as stacked
from gelscribe.core.model import GelProject
from gelscribe.core.package import GelPackage


def figure(pkg):
    """The figure's gel and the stack it was composed on."""
    w = working(pkg)
    g = stack(pkg, w)
    return stacked.figure_image(w[0], w[1], pkg.project, g), g


def line_rows(gel, g):
    a = int(round(g.piece(None).bottom - g.crop.y0))
    return gel[a:a + g.separator]


def tiff16(width, height, fn) -> bytes:
    yy, xx = np.mgrid[0:height, 0:width]
    buf = io.BytesIO()
    tifffile.imwrite(buf, fn(xx, yy).astype(np.uint16), photometric="minisblack")
    return buf.getvalue()


# ---------------------------------------------------------------------------------------------------- 1. the line


def test_the_line_between_gels_is_the_darkest_or_the_brightest_value():
    pkg = cut_blot(shift=37)
    p = pkg.project
    p.strips[0].shift = 37
    assert p.separator == "black" and "separator" not in json.loads(p.dumps())
    for sep, want in (("black", 0), ("white", 255)):
        p.separator = sep
        gel, g = figure(pkg)
        rows = line_rows(gel, g)
        assert len(rows) == g.separator and (rows == want).all()
        assert (gel[:5] == figure(pkg)[0][:5]).all()   # the gels themselves don't change with it
    assert json.loads(p.dumps())["separator"] == "white" and GelProject.loads(p.dumps()).separator == "white"
    w = working(pkg)
    views = [w[0].view_image(p)] + [x.view_image(p.strip_project(1)) for x in w[1]]
    assert (line_rows(stacked.view_image(views, stack(pkg, w)), g) == 255).all()   # and on the screen
    # in 16-bit storage the brightest value is 65535
    wide = lambda f: tiff16(300, 120, f)   # noqa: E731
    deep = GelPackage.create(wide(lambda x, y: 20000 + x * 3), "a.tif")
    deep.add_strip(wide(lambda x, y: 30000 + y * 5), "b.tif", strict=True)
    deep.project.strict = True
    for sep, want in (("black", 0), ("white", 65535)):
        deep.project.separator = sep
        gel, g = figure(deep)
        assert gel.dtype == np.uint16 and (line_rows(gel, g) == want).all()


def test_the_line_can_be_any_color_a_gray_figure_takes_its_luminance_and_it_has_a_thickness():
    from gelscribe.core.model import parse_separator, separator_gray, separator_rgb
    assert [parse_separator(t) for t in ("white", " BLACK ", "#FF3300", "f30", "#f30", "ff3300", "#000000", "#FFFFFF")] == \
        ["white", "black", "#ff3300", "#ff3300", "#ff3300", "#ff3300", "black", "white"]
    assert [parse_separator(t) for t in ("", "#12", "#12345", "gray", "#gg0000", None, 5)] == [None] * 7
    assert separator_rgb("#ff3300") == (255, 51, 0) and separator_gray("white") == 255 and separator_gray("black") == 0
    assert separator_gray("#ff3300") == round(0.2126 * 255 + 0.7152 * 51)   # Rec. 709 luminance, rounded
    pkg = cut_blot(shift=37)
    p = pkg.project
    p.strips[0].shift, p.separator = 37, "#ff3300"
    assert json.loads(p.dumps())["separator"] == "#ff3300" and GelProject.loads(p.dumps()) == p
    gel, g = figure(pkg)   # gray (8-bit): its luminance
    assert (line_rows(gel, g) == separator_gray("#ff3300")).all()
    rgb = io.BytesIO()
    Image.fromarray(np.full((120, 700, 3), 190, np.uint8)).save(rgb, format="PNG")
    pkg.add_strip(rgb.getvalue(), "rgb.png", strict=True)   # a color gel that keeps its pixels: an RGB figure, the color exactly
    p.strict, p.strips[0].strict, p.strips[1].shift = False, False, 0
    p.separator = "#ff3300"
    w = working(pkg)
    g = stack(pkg, w)
    out = stacked.figure_image(w[0], w[1], p, g)
    assert out.shape[2] == 3 and out.dtype == np.uint8
    first = int(round(g.piece(None).bottom - g.crop.y0))
    assert (out[first:first + g.separator] == (255, 51, 0)).all()
    deep = GelPackage.create(tiff16(300, 120, lambda x, y: 20000 + x), "a.tif")   # 16-bit gray: the luminance times 257
    deep.add_strip(tiff16(300, 120, lambda x, y: 30000 + y), "b.tif", strict=True)
    deep.project.strict, deep.project.separator = True, "#ff3300"
    gel, g = figure(deep)
    assert (line_rows(gel, g) == separator_gray("#ff3300") * 257).all()
    # the thickness: its own, or (not set) the figure's line width, which it follows
    q = cut_blot().project
    assert q.separator_width is None and q.effective_separator_width == q.style.line_width_pt
    rows = stack(cut_blot(), working(cut_blot())).separator
    q.separator_width = 4
    wide = stacked.StackGeometry(q, 620, 160, [(700, 220)])
    assert wide.separator > rows and json.loads(q.dumps())["separator_width"] == 4
    q.separator_width = 40
    assert q.effective_separator_width == 10   # 0.25 to 10 pt
    assert GelProject.from_json({**json.loads(q.dumps()), "separator_width": 0.01}).separator_width == 0.25
    q.separator_width = None
    q.style.line_width_pt = 2
    assert q.effective_separator_width == 2 and "separator_width" not in json.loads(q.dumps())


def test_the_provenance_names_the_line():
    pkg = cut_blot()
    p = pkg.project
    assert "with a black line between each" in render.export_info(p, "aaa", strips=[("bbb", None)]).description
    p.separator = "white"
    assert "with a white line between each" in render.export_info(p, "aaa", strips=[("bbb", None)]).description
    p.separator = "#ff3300"
    assert "with a #ff3300 line between each" in render.export_info(p, "aaa", strips=[("bbb", None)]).description
    assert GelProject.from_json({**json.loads(p.dumps()), "separator": "grey"}).separator == "black"   # not refused (finding 6)


def test_the_window_sets_the_line_and_undo_takes_it_back(win, tmp_path):
    ws = win.ws
    second = tmp_path / "second.png"
    second.write_bytes(piece_png(620, 160, MAIN_LANES, [90]))
    assert not ws.add_gels([second])
    ws.set_separator("white")
    g = ws.stack
    row = int(round(g.piece(None).bottom - g.crop.y0))
    assert ws.project.separator == "white" and ws.display_cropped().pixelColor(3, row).red() == 255
    assert win.inspector.panels["figure"].gels.line.buttons["white"].isChecked()
    ws.undo.undo()
    assert ws.project.separator == "black" and ws.display_cropped().pixelColor(3, row).red() == 0


# ---------------------------------------------------------------------------------------------------- 2. each gel on its own


def test_each_gel_has_its_own_keep_original_pixels_in_the_project_file():
    pkg = cut_blot()
    p = pkg.project
    assert p.strict and p.strips[0].strict is False   # a new gel starts with it off, so Auto-align can stretch it
    assert json.loads(p.dumps())["strips"][0]["strict"] is False and GelProject.loads(p.dumps()) == p
    assert [p.is_strict(None), p.is_strict(1)] == [True, False]
    p.strips[0].strict = None   # no value of its own: the same as the lanes gel
    assert "strict" not in json.loads(p.dumps())["strips"][0] and p.is_strict(1)
    p.strict = False
    assert not p.is_strict(1) and not p.strip_project(1).strict and p.effective_alignment(1) == (0.0, 1.0)
    old = json.loads(p.dumps())   # a project from before: strips have no value of their own
    old["strict"] = True
    assert GelProject.from_json(old).strips[0].strict is None and GelProject.from_json(old).is_strict(1)
    with pytest.raises(ValueError, match="strips\\[0\\].strict"):
        old["strips"][0]["strict"] = "yes"
        GelProject.from_json(old)
    p = cut_blot().project
    p.strips[0].shift, p.strips[0].scale = 12.6, 1.02
    assert p.effective_alignment(1) == (12.6, 1.02)
    p.strips[0].strict = True   # while it keeps its pixels: whole pixels, no stretch
    assert p.effective_alignment(1) == (13.0, 1.0)
    ops.set_strict(p, False, 620, 160, [(700, 220)], strip=1)   # setting one gel's own value leaves the lanes gel's alone
    assert p.strict and p.strips[0].strict is False
    ops.set_strict(p, False, 620, 160)
    assert not p.strict and p.strips[0].strict is False


def test_a_mixed_export_keeps_the_kept_gels_exact_and_stretches_the_others():
    pkg = cut_blot(shift=37, scale=1.02)
    p = pkg.project
    p.strips[0].shift, p.strips[0].scale = 37.0, 1.02
    p.strips[0].display.white = 0.5   # applied to this gel's exported pixels, since it doesn't keep them
    p.display.white = 0.5             # and only on screen for the lanes gel, which does
    w = working(pkg)
    c = p.effective_crop(620, 160)
    gel, g = figure(pkg)
    rows = int(c.y1 - c.y0)
    assert np.array_equal(gel[:rows], w[0].source.pixels[int(c.y0):int(c.y1), int(c.x0):int(c.x1)])
    s = g.piece(1)
    below = gel[int(s.top - g.crop.y0):int(s.bottom - g.crop.y0)]
    x0 = int(c.x0 + 37)
    plain = w[1][0].source.pixels[:below.shape[0], x0:x0 + int(c.width)]
    assert not np.array_equal(below, plain) and below.max() == 255 and plain.max() < 255   # stretched, range applied
    # the other way round: the lanes gel is adjusted, the stacked gel's own pixels go in untouched
    p.strict, p.strips[0].strict = False, True
    p.strips[0].shift = 37.0
    w = working(pkg)
    gel, g = figure(pkg)
    s = g.piece(1)
    top = int(s.top - g.crop.y0)
    assert np.array_equal(gel[top:top + int(s.bottom - s.top), :int(c.width)],
                          w[1][0].source.pixels[:int(s.bottom - s.top), x0:x0 + int(c.width)])
    assert gel[:rows].max() == 255 and w[0].source.pixels[int(c.y0):int(c.y1)].max() < 255
    # in 16 bit: the lanes gel's values untouched, the 8-bit gel converted to that storage (by 257)
    deep = GelPackage.create(tiff16(300, 120, lambda x, y: 20000 + x * 3 + y), "a.tif")
    deep.add_strip(piece_png(300, 100, [100, 200], [50]), "b.png")
    deep.project.strict = True
    w = working(deep)
    fig = stacked.StackedFigure(deep.project, w[0], w[1])
    assert fig.strict_problem is None
    gel, g = fig.gel, fig.stack
    s = g.piece(1)
    assert gel.dtype == np.uint16 and np.array_equal(gel[:120], w[0].source.pixels)
    below = gel[int(s.top - g.crop.y0):int(s.bottom - g.crop.y0)]
    assert (below % 257 == 0).all() and below.max() > 255
    note = fig.info().description
    assert "2. b.png" in note.split("1. a.tif")[1] and "converted to 16-bit gray" in note.split("2. b.png")[1]
    assert "original pixels" not in note.split("2. b.png")[1]
    fig.export("png")   # and it exports


def test_only_the_gels_that_keep_their_pixels_have_to_be_stored_alike():
    pkg = cut_blot()
    rgb = io.BytesIO()
    Image.fromarray(np.full((220, 700, 3), 200, np.uint8)).save(rgb, format="PNG")
    pkg.add_strip(rgb.getvalue(), "rgb.png")   # a new gel doesn't keep its pixels
    p = pkg.project

    def problem():
        w = working(pkg)
        return stacked.StackedFigure(p, w[0], w[1]).strict_problem
    assert problem() is None
    p.strips[1].strict = True
    assert problem() == "gel 3 is 8-bit RGB, the gel with the lanes 8-bit gray"
    p.strict = False   # now the lanes gel isn't one of them: the gels that keep their pixels are compared with each other
    p.strips[0].strict = True
    assert problem() == "gel 3 is 8-bit RGB, gel 2 8-bit gray"
    p.strips[0].strict = False
    assert problem() is None   # one gel on its own has nothing to match
    w = working(pkg)   # and all of them off: 8-bit gray, as the non-strict export always was
    p.strips[1].strict = False
    gel = stacked.figure_image(w[0], w[1], p, stack(pkg, w))
    assert gel.dtype == np.uint8 and gel.ndim == 2


def test_auto_align_follows_each_gels_own_setting_and_says_when_stretching_would_fit_better():
    pkg = cut_blot(shift=37, scale=1.1)
    p = pkg.project
    gel = working(pkg)[1][0]
    r, note = stacked.align_gel(p, 1, gel)   # a new gel may stretch
    assert abs(r.alignment.scale - 1.1) < 0.01 and note is None
    p.strips[0].strict = True
    gel = working(pkg)[1][0]
    r, note = stacked.align_gel(p, 1, gel)   # one that keeps its pixels shifts by whole pixels only
    a = r.alignment
    assert a.scale == 1 and a.shift == round(a.shift) and a.worst > a.pitch / 4
    assert note.startswith("Gel 2's lanes are 10.") and "farther apart, so they're up to" in note
    assert note.endswith("Turn off Keep original pixels for Gel 2 to stretch it.")
    assert stacked.stretch_note(2, a, None) is None and stacked.stretch_note(2, stacked.Alignment(0, 1, 2, 70), a) is None
    closer = stacked.Alignment(0, 0.95, 0, 70)
    assert "5.0% closer together" in stacked.stretch_note(2, stacked.Alignment(0, 1, 30, 70), closer)


def second_gel(tmp_path, scale=1.02, shift=10) -> Path:
    """A second gel's file: the test gel's eight lanes, a little wider apart and further right."""
    path = tmp_path / "second.png"
    path.write_bytes(piece_png(700, 220, [scale * c + shift for c in LANES], [90]))
    return path


def test_every_gel_has_its_own_switch_in_the_original_image_section(win, tmp_path):
    ws = win.ws
    fp = win.inspector.panels["figure"]
    place_lanes(win)
    ws.set_tab("figure")
    settle()
    assert fp.strict.isVisibleTo(fp) and not fp.keep_rows.isVisibleTo(fp)   # one gel: the one switch
    assert not ws.add_gels([second_gel(tmp_path)])   # added, chosen, and lined up with a stretch: it starts with the switch off
    settle()
    assert ws.active_strip == 1 and ws.project.strips[0].strict is False and ws.project.strict
    assert abs(ws.project.strips[0].scale - 1.02) < 0.006
    assert not fp.strict.isVisibleTo(fp) and fp.keep_rows.isVisibleTo(fp)   # several: a row for each, lanes gel tagged
    rows = fp.keep_rows.rows
    assert [r["k"] for r in rows] == [None, 1] and [r["switch"].isChecked() for r in rows] == [True, False]
    assert rows[0]["card"].findChild(type(rows[0]["lock"]), "") is not None and not rows[0]["card"].isHidden()
    assert fp.gels.stretch.isEnabled() and not fp.gels.strict_note.isVisibleTo(fp)
    rows[1]["switch"].setChecked(True)   # Gel 2's own switch: the lanes gel's isn't touched
    settle()
    assert ws.project.strips[0].strict is True and ws.project.strict and ws.pixels_kept == "all"
    assert not fp.gels.stretch.isEnabled() and fp.gels.strict_note.isVisibleTo(fp)   # the hint where Stretch is
    ws.auto_align()   # by its own setting now: whole pixels, and it says why a stretch would fit better
    a = ws.project.strips[0]
    assert a.scale == 1 and a.shift == round(a.shift) and "allows a shift only" in ws.align_note
    rows[0]["switch"].setChecked(False)   # the lanes gel's own, while Gel 2 stays chosen
    settle()
    assert not ws.project.strict and ws.project.strips[0].strict is True and ws.active_strip == 1
    assert ws.pixels_kept == "some"
    ws.undo.undo()
    ws.undo.undo()   # the lanes gel's switch, then the alignment
    assert ws.project.strict and ws.project.strips[0].strict is True
    ws.undo.undo()
    assert ws.project.strips[0].strict is False
    ws.set_strict(True, strip=None)   # and it exports either way
    assert ws.project.strict and ws.export_problem is None


# ---------------------------------------------------------------------------------------------------- 3. columns of a gel's own


def test_a_stacked_gel_follows_the_lanes_gels_crop_unless_it_has_columns_of_its_own():
    from gelscribe.core.model import GelStrip, PixelRect
    pkg = cut_blot(shift=37)
    p = pkg.project
    p.crop = PixelRect(100, 10, 500, 150)
    p.strips[0].shift = 37
    assert "left" not in json.loads(p.dumps())["strips"][0]
    g = stack(pkg, working(pkg))
    q = g.piece(1)   # no columns: the lanes gel's crop through the alignment, and the figure doesn't widen
    assert (q.left, q.right, q.source_left, q.source_right) == (100, 500, 137, 537)
    assert (g.crop.x0, g.crop.x1) == (100, 500) and p.kept_columns(1, 700, 620, 160) == (137, 537)
    p.strips[0].left, p.strips[0].right = 0, 700   # its own: the figure runs from the leftmost to the rightmost column kept
    d = json.loads(p.dumps())["strips"][0]
    assert (d["left"], d["right"]) == (0, 700) and GelProject.loads(p.dumps()) == p
    w = working(pkg)
    g = stack(pkg, w)
    q = g.piece(1)
    assert (q.left, q.right) == (-37, 663) and (g.crop.x0, g.crop.x1) == (-37, 663)
    gel = stacked.figure_image(w[0], w[1], p, g)
    assert gel.shape[1] == 700
    main_rows = gel[:int(g.piece(None).bottom - g.crop.y0)]
    assert (main_rows[:, :137] == 255).all() and (main_rows[:, 537:] == 255).all()   # where no gel has pixels: blank white
    assert np.array_equal(main_rows[:, 137:537], w[0].source.pixels[10:150, 100:500])   # the lanes gel's own values
    top = int(q.top - g.crop.y0)
    assert np.array_equal(gel[top:top + int(q.bottom - q.top)], w[1][0].source.pixels[:int(q.bottom - q.top)])
    # edges that can't be used are followed instead, and the file's own numbers are put right on load
    assert GelStrip("x.png", left=300, right=200).columns(700, PixelRect(100, 0, 500, 100), 37, 1) == (137, 537, True, True)
    bad = GelProject.from_json({**json.loads(p.dumps()), "strips": [{**d, "left": 300, "right": 200}]})
    assert bad.strips[0].left is None and bad.strips[0].right is None
    only_left = GelStrip("x.png", left=50).columns(700, PixelRect(100, 0, 500, 100), 37, 1)
    assert only_left == (50, 537, False, True)   # one set, the other followed
    far = GelStrip("x.png", left=600).columns(700, PixelRect(100, 0, 500, 100), 37, 1)
    assert far == (600, 700, False, False)   # the followed edge ended before the set one: the image's own edge
    assert ops.set_strip_crop(p, 1, 10, 20, 300, 200, 700, 220) and (p.strips[0].left, p.strips[0].top) == (10, 20)
    assert not ops.set_strip_crop(p, 1, 300, 20, 10, 200, 700, 220) and p.strips[0].left == 10   # nothing left: unchanged
    ops.turn(p, 1, 2, 700, 220)   # a half turn carries the crop across; a quarter turn starts it over
    assert (p.strips[0].left, p.strips[0].right, p.strips[0].top, p.strips[0].bottom) == (400, 690, 20, 200)
    ops.turn(p, 1, 1, 700, 220)
    assert p.strips[0].left is None and p.strips[0].top is None


# ---------------------------------------------------------------------------------------------------- 4. the gel with the lanes moves


def test_the_gel_with_the_lanes_moves_by_main_shift_and_no_other_gel_does():
    pkg = cut_blot(shift=37)
    p = pkg.project
    p.strips[0].shift = 37
    assert p.effective_main_shift == 0 and "main_shift" not in json.loads(p.dumps())
    before = stack(pkg, working(pkg)).piece(1)
    p.main_shift = 8
    assert json.loads(p.dumps())["main_shift"] == 8 and GelProject.loads(p.dumps()) == p
    assert p.effective_alignment(1) == (37, 1.0) and p.lane_alignment(1) == (29, 1.0)   # its own shift is a place in the figure
    q = stack(pkg, working(pkg)).piece(1)
    assert (q.shift, before.shift) == (29, 37)   # the lanes through where gel 1 sits
    assert ops.lane_x(p, 1, 1) == MAIN_LANES[0] + 29 and p.shift_to_store(29, 1.02) == 29 + 1.02 * 8
    ops.align_strip(p, 1, 29, 1.0)   # a fit to the lanes is stored as a place in the figure
    assert p.strips[0].shift == 37
    ops.place_gel(p, None, 7.6)
    assert p.main_shift == 8 and p.strips[0].shift == 37   # whole pixels, and no other gel moved
    ops.place_gel(p, 1, 12.345)
    assert p.strips[0].shift == 12.35   # hundredths for a gel that may be stretched ...
    p.strips[0].strict = True
    ops.place_gel(p, 1, 12.6)
    assert p.strips[0].shift == 13   # ... whole pixels for one that keeps its pixels
    ops.turn(p, None, 2, 620, 160)   # a half turn keeps where it sat, a quarter turn starts over
    assert p.main_shift == 8
    ops.turn(p, None, 1, 620, 160)
    assert p.main_shift == 0
    assert GelProject.from_json({**json.loads(p.dumps()), "main_shift": 5e9}).main_shift == 1_000_000
    # the picture: gel 2 is where gel 1 left room for it, gel 1's own pixels untouched
    q = cut_blot(shift=37).project
    pkg = cut_blot(shift=37)
    pkg.project.strips[0].shift = 37
    base = figure(pkg)[0]
    pkg.project.main_shift = 6
    moved, g = figure(pkg)
    rows = int(g.piece(None).bottom - g.crop.y0)
    assert np.array_equal(moved[:rows], base[:rows])
    assert np.array_equal(moved[rows + g.separator:, 6:], base[rows + g.separator:, :-6])   # gel 2 slid right by 6


# ---------------------------------------------------------------------------------------------------- 5. group labels at an angle


def test_group_labels_stand_at_an_angle_over_the_middle_of_their_span_and_the_underline_stays_flat():
    from test_label_angle import labelled
    from gelscribe.core.layout import layout, metrics
    p = labelled(0)
    gi = next(i for i, r in enumerate(p.rows) if r.type == "groups")
    li = next(i for i, r in enumerate(p.rows) if r.type == "lanes")
    assert not ops.set_row_angle(p, li, 45) and not ops.set_row_angle(p, 99, 45) and not ops.set_row_angle(p, gi, float("nan"))
    flat = layout(p, 500, 300)
    assert ops.set_row_angle(p, gi, 450)   # any angle, brought into 0 ..< 360
    assert p.rows[gi].rotation == 90 and json.loads(p.dumps())["rows"][gi]["rotation"] == 90
    assert "rotation" not in json.loads(p.dumps())["rows"][li] and GelProject.loads(p.dumps()) == p
    lay = layout(p, 500, 300)
    groups = [t for t in lay.texts if t.role.kind == "groupLabel"]
    assert groups and all(t.rotation == 90 for t in groups) and all(t.rotation == 0 for t in flat.texts)
    for t, g in zip(groups, p.rows[gi].groups):   # the middle line is over the middle of the lanes the group spans
        span = (lay.point(p.lanes.centers[g.first - 1], 0)[0] + lay.point(p.lanes.centers[g.last - 1], 0)[0]) / 2
        assert abs(t.origin[0] - metrics(t.font).cap_height / 2 - span) < 1e-9
    assert [x.points for x in lay.lines] == [x.points for x in flat.lines]   # the underlines are where they were, and flat
    gap = lay.gel_rect.y   # the lowest point of a group label is where horizontal text would end: above the underline
    low = max(t.bounds.max_y for t in groups)
    flat_low = max(t.bounds.max_y for t in flat.texts if t.role.kind == "groupLabel")
    assert abs(low - flat_low) < 1e-6 and gap > low
    ops.set_label_angle(p, 30)   # the lane labels keep the figure's one angle, apart from the groups'
    assert p.rows[gi].rotation == 90 and p.label_angle == 30


# ---------------------------------------------------------------------------------------------------- 6. the switcher and the gel view


@pytest.fixture
def two(win, tmp_path):
    """The window with its lanes placed and a second gel added (chosen, lined up under the lanes), on the Select tool."""
    place_lanes(win)
    assert not win.ws.add_gels([second_gel(tmp_path)])
    win.ws.set_tool("select")
    win.ws.choose_gel(None)
    settle()
    return win


def figure_pt(w, strip, x=None, row=0.5) -> QPoint:
    """Where gel `strip`'s piece of the figure is on the canvas at column x of the gel with the lanes, row 0 to 1 down the piece."""
    ws = w.ws
    q = ws.stack.piece(strip)
    p = w.canvas.px_view(ws.crop.x0 + ws.crop.width * 0.8 if x is None else x, q.top + (q.bottom - q.top) * row)
    return QPoint(round(p.x()), round(p.y()))


def gel_pt(w, x, y) -> QPoint:
    """Where pixel (x, y) of the gel on view is on the canvas."""
    p = w.canvas.to_view(x, y)
    return QPoint(round(p.x()), round(p.y()))


def test_the_switcher_chooses_and_shows_gels(two):
    w, ws = two, two.ws
    zooms = []
    ws.zoom_request.connect(zooms.append)
    assert w.switcher.isVisibleTo(w) and [b.text() for b, _ in w.switcher.buttons] == ["Figure", "Gel 1  LANES", "Gel 2"]
    lit = lambda: [b.isChecked() for b, _ in w.switcher.buttons]   # noqa: E731
    assert not ws.shows_gel and not ws.views_other_gel and lit() == [True, False, False]   # starts on the figure
    ws.show_gel(1)   # the switcher's Gel 2: chosen, shown on its own, zoomed to fit
    settle()
    assert ws.shows_gel and ws.views_other_gel and ws.active_strip == 1 and zooms[-1] == "fit" and lit() == [False, False, True]
    assert w.canvas.full_view and w.canvas.content_size() == tuple(float(v) for v in ws.active_size)
    ws.choose_gel(None)   # a click in the Gels list moves a gel view that is showing
    assert ws.shows_gel and not ws.views_other_gel and ws.active_strip is None and zooms[-1] == "fit"
    assert ws.shown_layout is not ws.layout and not ws.shown_stack.has_strips and ws.stack.has_strips   # the lanes gel: a figure of its own
    assert not w.canvas.full_view and len(ws.gel_layers()) == 1
    ws.show_figure()
    assert not ws.shows_gel and ws.active_strip is None and zooms[-1] == "fit" and ws.shown_layout is ws.layout
    n = len(zooms)
    ws.choose_gel(1)   # on the figure, a click in the list only chooses
    assert not ws.shows_gel and ws.active_strip == 1 and len(zooms) == n and lit() == [True, False, False]
    w.switcher.buttons[1][0].click()   # the buttons do the same
    settle()
    assert ws.shows_gel and ws.active_strip is None and lit() == [False, True, False]
    w.switcher.buttons[0][0].click()
    assert not ws.shows_gel
    # the Gels list: a click chooses, a double-click opens that gel on its own
    gels = w.inspector.panels["figure"].gels.list
    item = gels.item(1)
    gels.itemClicked.emit(item)
    assert ws.active_strip == 1 and not ws.shows_gel
    gels.itemDoubleClicked.emit(item)
    assert ws.shows_gel and ws.active_strip == 1
    # one gel left: no switcher, no gel view, and it doesn't come back with the gel
    ws.remove_active_gel()
    settle()
    assert not ws.shows_gel and not w.switcher.isVisibleTo(w)
    ws.undo.undo()
    settle()
    assert len(ws.project.strips) == 1 and not ws.shows_gel and w.switcher.isVisibleTo(w)


def test_the_lane_divider_tool_is_only_for_the_gel_with_the_lanes(two):
    ws = two.ws
    ws.set_tool("lanes")
    ws.show_gel(None)
    assert ws.tool == "lanes"   # the lanes gel's own view works as for a single gel
    ws.show_gel(1)
    assert ws.tool == "select"   # another gel: the tool moves off the dividers
    ws.set_tool("lanes")
    assert ws.tool == "select" and ws.tool_note == "Lane dividers are set on Gel 1, the gel with the lanes."
    assert two.hint_label.text() == ws.tool_note
    ws.set_tool("ladder")
    assert ws.tool == "ladder" and ws.tool_note is None
    ws.show_figure()
    ws.set_tool("lanes")
    assert ws.tool == "lanes"
    # the lanes gel on its own takes dividers like a single gel
    ws.show_gel(None)
    n = len(ws.project.dividers if hasattr(ws.project, "dividers") else ws.project.lanes.dividers)
    click(two, at(two, 100, 100))
    assert len(ws.project.lanes.dividers) == n + 1


def test_in_the_figure_only_the_select_tool_chooses_the_gel_under_the_click(two):
    w, ws = two, two.ws
    ws.set_tool("select")
    click(w, figure_pt(w, 1))
    assert ws.active_strip == 1 and not ws.shows_gel   # Select: chosen, and still the figure
    click(w, figure_pt(w, None))
    assert ws.active_strip is None
    # the other tools act on the gel under the click (a tick or name belongs to it) and never change the chosen gel
    ws.set_tool("ladder")
    ticks = len(ws.project.ladder.bands) if ws.project.ladder else 0
    click(w, figure_pt(w, 1, row=0.45))
    assert ws.active_strip is None and len(ws.project.ladder.bands) == ticks + 1 and ws.project.ladder.bands[-1].strip == 1
    (popup() or w).close()
    ws.set_tool("names")
    names = len(ws.project.annotations)
    click(w, figure_pt(w, 1, row=0.7))
    assert ws.active_strip is None and len(ws.project.annotations) == names + 1 and ws.project.annotations[-1].strip == 1
    (popup() or w.canvas).close() if popup() else None
    ws.set_tool("lanes")
    click(w, figure_pt(w, 1, x=40, row=0.3))
    assert ws.active_strip is None
    # double-clicking a gel in the figure (Select) opens its view
    ws.set_tool("select")
    QTest.mouseDClick(w.canvas, Qt.MouseButton.LeftButton, NO, figure_pt(w, None))
    settle()
    assert ws.shows_gel and ws.active_strip is None
    ws.show_figure()
    QTest.mouseDClick(w.canvas, Qt.MouseButton.LeftButton, NO, figure_pt(w, 1))
    settle()
    assert ws.shows_gel and ws.active_strip == 1


def test_a_gel_on_view_takes_ticks_and_names_on_its_own_pixels(two):
    w, ws = two, two.ws
    ws.show_gel(1)
    ws.snapping = False
    gw, gh = ws.active_size
    others = [b.y for b in (ws.project.ladder.bands if ws.project.ladder else []) if b.strip is None]
    ws.set_tool("ladder")
    click(w, gel_pt(w, 400, 120))
    added = [b for b in ws.project.ladder.bands if b.strip == 1]
    assert len(added) == 1 and abs(added[0].y - 120) <= 1 and [b.y for b in ws.project.ladder.bands if b.strip is None] == others
    (popup() or w.canvas).close()
    settle()
    # picked up with the Select tool, and moved along the gel's rows
    ws.set_tool("select")
    lane = ops.lane_x(ws.project, ws.project.ladder.lane, 1)
    i = ws.project.ladder.bands.index(added[0])
    click(w, gel_pt(w, lane, 120))
    assert ws.selection == ("tick", i)
    (popup() or w.canvas).close()
    drag(w, gel_pt(w, lane, 120), gel_pt(w, lane, 150))
    assert abs(next(b for b in ws.project.ladder.bands if b.strip == 1).y - 150) <= 1
    ws.set_tool("names")
    names = len([a for a in ws.project.annotations if a.strip == 1])
    click(w, gel_pt(w, 300, 60))
    assert len([a for a in ws.project.annotations if a.strip == 1]) == names + 1
    (popup() or w.canvas).close()
    # the ticks and names of the gel on view are drawn on it (the whole gel, its kept part outlined)
    w.canvas.grab()
    assert ws.active_strip_rect.width <= gw and ws.active_strip_rect.height == gh


def test_a_stacked_gel_has_all_four_edges_and_corners_to_crop_and_esc_puts_them_back(two):
    w, ws = two, two.ws
    ws.choose_gel(1)
    ws.set_tool("crop")   # chosen in the figure
    settle()
    gw, gh = ws.active_size
    rect = ws.active_strip_rect   # a new gel follows the lanes gel's crop through the alignment
    assert (rect.x0, rect.y0, rect.y1) == (10, 0, gh) and abs(rect.x1 - (1.02 * 600 + 10)) <= 1
    s = lambda: ws.project.strips[0]   # noqa: E731
    box = lambda: (s().left, s().top, s().right, s().bottom)   # noqa: E731
    top_mid = gel_pt(w, (rect.x0 + rect.x1) / 2, 0)
    drag(w, top_mid, QPoint(top_mid.x(), top_mid.y() + 30))   # only the top edge: it keeps following the lanes gel's columns
    assert s().top is not None and 20 <= s().top <= 40 and s().left is None and s().right is None
    right_mid = gel_pt(w, rect.x1, 100)
    drag(w, right_mid, QPoint(right_mid.x() - 60, right_mid.y()))   # a side edge: the gel has columns of its own now
    assert s().left == rect.x0 and s().right is not None and s().right < rect.x1 - 20
    corner = gel_pt(w, s().left, s().top)
    was = (s().left, s().top)
    drag(w, corner, QPoint(corner.x() + 40, corner.y() + 20))   # a corner moves two edges
    assert s().left > was[0] + 10 and s().top > was[1] + 5
    q = ws.stack.piece(1)
    assert (q.source_left, q.source_right, q.source_top) == (s().left, s().right, s().top)   # the figure takes what the gel keeps
    QTest.keyClick(w.canvas, Qt.Key.Key_Return)   # Return keeps the crop
    assert ws.tool == "select" and box()[0] is not None
    kept = box()
    ws.set_tool("crop")
    corner = gel_pt(w, s().left, s().top)
    drag(w, corner, QPoint(corner.x() + 30, corner.y() + 30))
    assert box() != kept
    QTest.keyClick(w.canvas, Qt.Key.Key_Escape)   # Esc puts back what the tool began with, and leaves
    assert ws.tool == "select" and box() == kept
    ws.set_tool("crop")
    ws.reset_crop()   # Reset takes all four back to the whole gel
    assert box() == (None, None, None, None)
    ws.choose_gel(None)   # the lanes gel: Esc leaves the tool and its crop stays
    ws.set_tool("crop")
    lw, lh = ws.active_size
    drag(w, gel_pt(w, 0, 0), gel_pt(w, 40, 30))
    crop = ws.project.crop
    assert crop is not None
    QTest.keyClick(w.canvas, Qt.Key.Key_Escape)
    assert ws.tool == "select" and ws.project.crop == crop


def test_dragging_a_gel_sideways_and_the_gel_with_the_lanes_moves_by_the_pointers_distance_and_nothing_else(two):
    w, ws = two, two.ws
    ws.set_tool("select")
    c = w.canvas
    ws.edit("columns", lambda p: ops.set_strip_crop(p, 1, 0, 0, 700, 220, 700, 220))   # gel 2 keeps up to the edge: the figure widens
    x = ws.crop.x0 + ws.crop.width * 0.5
    # a stacked gel: it moves, gel 1 stays
    before, scale = ws.project.strips[0].shift, ws.project.effective_alignment(1)[1]
    per_px = 1 / (c.scale() * ws.layout.pt_per_px)
    a = figure_pt(w, 1, x=x)
    drag(w, a, QPoint(a.x() - 40, a.y()))
    assert abs(ws.project.strips[0].shift - (before + scale * 40 * per_px)) < 0.011 + 0.5 * scale   # to the left: its shift grows
    assert ws.active_strip == 1 and ws.project.effective_main_shift == 0   # the click chose it
    moved = ws.project.strips[0].shift
    ws.nudge_active_gel(1)   # arrows and the Shift field move it as before
    assert abs(ws.project.strips[0].shift - (moved - scale)) < 0.011
    ws.set_shift(12.34)
    assert ws.project.strips[0].shift == 12.34
    # the gel with the lanes: it moves, no other gel does, and the view keeps what didn't move where it was on the screen
    ws.set_shift(0)
    ws.choose_gel(None)
    gel2 = ws.project.strips[0].shift
    column = 300.0
    piece = lambda: ws.stack.piece(1)   # noqa: E731
    def gel2_view():
        return c.px_view(piece().to_figure(column, 0)[0], piece().top + 5)
    start, was = figure_pt(w, None, x=x), gel2_view()
    held = QPoint(start.x() + 60, start.y())
    QTest.mousePress(c, Qt.MouseButton.LeftButton, NO, start)
    QTest.mouseMove(c, held)
    settle()
    per_px = 1 / (c.scale() * ws.layout.pt_per_px)
    assert abs(ws.project.effective_main_shift + 60 * per_px) <= 1.5   # held 60 points to the right: gel 1 moved right by that many pixels
    assert ws.project.strips[0].shift == gel2   # no other gel moved
    now = c.px_view(x, ws.stack.piece(None).top + 5)
    assert abs(now.x() - held.x()) < 2.5   # it's under the pointer ...
    assert abs(gel2_view().x() - was.x()) < 2.5   # ... and gel 2 is where it was on the screen
    QTest.mouseRelease(c, Qt.MouseButton.LeftButton, NO, held)
    settle()
    assert ws.project.effective_main_shift < 0 and ws.project.strips[0].shift == gel2 and ws.active_strip is None
    ws.undo.undo()   # one undo step takes the whole drag back
    assert ws.project.effective_main_shift == 0


def test_the_arrows_and_the_shift_field_move_the_gel_with_the_lanes_too_and_auto_align_follows_it(two):
    w, ws = two, two.ws
    ws.choose_gel(None)
    ws.set_tab("figure")
    settle()
    gel2 = ws.project.strips[0].shift
    QTest.keyClick(w.canvas, Qt.Key.Key_Right)   # → with nothing selected: a pixel to the right, so a shift of -1
    assert ws.project.main_shift == -1 and ws.active_shift == -1
    QTest.keyClick(w.canvas, Qt.Key.Key_Left, Qt.KeyboardModifier.ShiftModifier)
    assert ws.project.main_shift == 9
    ws.set_shift(7.6)   # whole pixels
    assert ws.project.main_shift == 8 and ws.active_shift == 8
    gels = w.inspector.panels["figure"].gels
    assert gels.shift.value() == 8 and not gels.stretch.isEnabled() and not gels.auto.isVisibleTo(gels)
    gels.shift.setValue(3)
    gels.shift.editingFinished.emit()
    assert ws.project.main_shift == 3
    scale = ws.project.strips[0].scale
    ws.set_scale(1.05)   # stretch is for the stacked gels
    assert ws.project.strips[0].scale == scale and ws.project.strips[0].shift == gel2
    # auto-align lines gel 2 up with the lanes where gel 1 now sits: 25 more figure pixels of shift
    ws.choose_gel(1)
    ws.edit("zero", lambda p: setattr(p, "main_shift", 0))
    ws.auto_align()
    lined = ws.project.strips[0].shift
    ws.edit("move gel 1", lambda p: setattr(p, "main_shift", 25))
    ws.auto_align()
    assert abs(ws.project.strips[0].shift - (lined + ws.project.strips[0].scale * 25)) < 0.3


def test_the_inspector_sets_the_lines_color_and_thickness_and_a_group_rows_angle(two):
    w, ws = two, two.ws
    ws.set_tab("figure")
    settle()
    g = w.inspector.panels["figure"].gels
    assert g.line.buttons["black"].isChecked() and g.hex.text() == "#000000" and not g.match.isEnabled()
    g.line.buttons["white"].click()
    assert ws.project.separator == "white" and g.hex.text() == "#ffffff" and g.line.buttons["white"].isChecked()
    g.hex.setText("f30")   # any color by its hex: 3 or 6 digits, with or without the #
    g.hex.editingFinished.emit()
    settle()
    assert ws.project.separator == "#ff3300" and g.hex.text() == "#ff3300"
    assert not g.line.buttons["black"].isChecked() and not g.line.buttons["white"].isChecked()   # neither lit for another color
    g.hex.setText("nope")   # not a color: it goes back to what it was
    g.hex.editingFinished.emit()
    assert ws.project.separator == "#ff3300" and g.hex.text() == "#ff3300"
    ws.undo.undo()
    assert ws.project.separator == "white"
    lines = ws.project.style.line_width_pt
    assert g.thick.value() == lines
    g.thick.setValue(4)   # its own thickness; the figure's rows change with it
    assert ws.project.separator_width == 4 and g.match.isEnabled()
    g.thick.setValue(10)
    g.thick.setValue(0.25)
    assert ws.project.separator_width == 0.25
    ws.set_separator_width(float("nan"))   # not a number: nothing changes
    assert ws.project.separator_width == 0.25
    g.match.click()   # Match lines: follows the Lines width again
    assert ws.project.separator_width is None and g.thick.value() == lines and not g.match.isEnabled()
    ws.edit("Line Width", lambda p: setattr(p.style, "line_width_pt", 2))
    settle()
    assert ws.project.effective_separator_width == 2 and g.thick.value() == 2
    # group labels: an angle for each row of group labels, the lane labels keep the figure's own
    ws.apply_quick_labels() if False else ws.edit("labels", lambda p: ops.apply_quick_labels(p, "µM: |0{A|B}|5{C|D}"))
    ws.set_tab("labels")
    settle()
    lp = w.inspector.panels["labels"]
    row = next(i for i, r in enumerate(ws.project.rows) if r.type == "groups")
    (_, _, _, angle) = next(x[1] for x in lp._row_widgets if x[0] == row)
    spin, steps = angle
    spin.setValue(30)
    spin.editingFinished.emit()
    assert ws.project.rows[row].rotation == 30 and steps.buttons["45"].isChecked() is False
    steps.buttons["90"].click()
    settle()
    assert ws.project.rows[row].rotation == 90 and next(x[1] for x in lp._row_widgets if x[0] == row)[3][1].buttons["90"].isChecked()
    assert ws.project.label_angle == 0


def test_the_canvas_paints_each_gel_over_its_own_columns_and_the_line_in_its_color(two):
    w, ws = two, two.ws
    c = w.canvas
    ws.set_tool("select")
    ws.edit("crop", lambda p: ops.set_strip_crop(p, 1, 200, 0, 400, 220, 700, 220))   # gel 2 keeps only 200 columns, in the middle
    ws.set_separator("#ff3300")
    w.resize(1440, 920)
    settle()
    img = c.grab().toImage()
    g = ws.stack
    q = ws.stack.piece(1)
    row = (q.top + q.bottom) / 2
    inside, left_of, right_of = (c.px_view(x, row) for x in ((q.left + q.right) / 2, q.left - 15, q.right + 15))
    px = lambda pt: img.pixelColor(round(pt.x()), round(pt.y())).getRgb()[:3]   # noqa: E731
    assert px(left_of) == (255, 255, 255) and px(right_of) == (255, 255, 255)   # where the gel has no columns: blank white
    assert px(inside)[0] < 250   # and the gel itself where it has them
    gray = round(0.2126 * 255 + 0.7152 * 51)   # the gel is gray: the line takes the brightness of its color
    line = c.px_view((q.left + q.right) / 2, (ws.stack.piece(None).bottom + q.top) / 2)
    assert abs(px(line)[0] - gray) <= 3 and px(line)[0] == px(line)[1] == px(line)[2]
    assert g.crop.x0 <= q.left and g.crop.x1 >= q.right


def test_a_figure_with_columns_a_color_line_and_a_moved_gel_exports_in_every_format():
    from gelscribe.core.layout import ensure_gui
    ensure_gui()
    pkg = cut_blot(shift=37, scale=1.02)
    p = pkg.project
    p.strips[0].shift, p.strips[0].scale = 37.0, 1.02
    ops.set_strip_crop(p, 1, 5, 20, 690, 200, 700, 220)
    p.separator, p.separator_width, p.main_shift = "#3366cc", 2.0, 10
    w = working(pkg)
    fig = stacked.StackedFigure(p, w[0], w[1])
    for fmt in ("pdf", "png", "tiff", "svg"):
        assert len(fig.export(fmt)) > 1000
    note = fig.info().description
    assert "with a #3366cc line between each" in note and "shifted 10 px" in note.split("1. top.png")[1].split("2. bottom.png")[0]
    assert "columns 5–690, rows 20–200" in note.split("2. bottom.png")[1] and "stretched (scaled 1.0200×)" in note
    got = Image.open(io.BytesIO(fig.export("png")))
    assert got.size[0] >= fig.layout.gel_rect.w / fig.layout.pt_per_px - 1   # the figure is as wide as the gels' columns
