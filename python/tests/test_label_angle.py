"""Lane labels at any angle (spec item 15): geometry, clamping, the setting and the command line."""
import json
import math
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from gelscribe import cli
from gelscribe.core import ops, render
from gelscribe.core.layout import layout, metrics, text_width
from gelscribe.core.model import GelProject, LabelRow
from gelscribe.core.scheme import LabelScheme

ANGLES = (10, 30, 45, 60, 80, 90, 135, 180, 225, 270, 315)
LABELS = "µM: Ladder|0{Wild type gyp|Knockout}|5{WT\\nKO|Treated long label}"   # five lanes; one label of two lines


def labelled(angle: float, labels: str = LABELS) -> GelProject:
    """Five lanes in a 500 × 300 image, a row of lane labels under a row of group labels with a row title."""
    p = GelProject(image="a.png")
    ops.set_dividers(p, [100, 200, 300, 400], 500, 300)
    ops.apply_quick_labels(p, labels)
    assert ops.set_label_angle(p, angle)
    return p


def lane_texts(lay):
    return [t for t in lay.texts if t.role.kind == "laneLabel"]


@pytest.mark.parametrize("angle", ANGLES)
def test_the_row_keeps_the_normal_gap_below_the_group_row_at_every_angle(angle):
    for gap in (3.0, 6.5):
        p = labelled(angle)
        p.style.row_gap_pt = gap
        lay = layout(p, 500, 300)
        top = min(t.bounds.min_y for t in lane_texts(lay))   # the highest corner of any rotated label
        underline = {line.points[0][1] for line in lay.lines}   # the group row's underlines
        assert len(underline) == 1
        assert abs((top - underline.pop()) - (gap + 1.2)) < 1e-6   # the row gap, plus the underline's rise
        group = next(t for t in lay.texts if t.role.kind == "groupLabel")
        assert abs((top - group.bounds.max_y) - (gap + 2.5)) < 1e-6   # and from the group labels' own bottom
        title = next(t for t in lay.texts if t.role.kind == "title" or t.string == "µM")
        assert title.bounds.max_y < top   # nothing of the rows above was left behind
    flat = layout(labelled(0), 500, 300)   # horizontal is as it was: the same gap above the same group row
    flat_top = min(t.bounds.min_y for t in lane_texts(flat))
    assert abs((flat_top - {line.points[0][1] for line in flat.lines}.pop()) - 4.2) < 1e-6


@pytest.mark.parametrize("angle", ANGLES)
def test_the_lowest_point_of_every_label_sits_where_horizontal_descenders_do(angle):
    flat = layout(labelled(0), 500, 300)
    flat_gap = flat.gel_rect.y - max(t.bounds.max_y for t in lane_texts(flat))   # the bottom of the descenders to the gel
    assert abs(flat_gap - 2.0) < 1e-6
    p = labelled(angle)
    p.style.text_sizes = {"lane.0.4": 11.0}   # a label of its own size keeps the same gap too
    lay = layout(p, 500, 300)
    for t in lane_texts(lay):   # the lowest point of each label's lines, the two-line one included
        lowest = t.bounds.max_y
        assert abs((lay.gel_rect.y - lowest) - flat_gap) < 1e-6, t.string
    assert abs(lay.gel_rect.y - max(t.bounds.max_y for t in lane_texts(lay)) - flat_gap) < 1e-6


@pytest.mark.parametrize("angle", (20, 45, 75))
def test_the_right_end_and_the_sides_are_inside_the_figure(angle):
    p = labelled(angle, "µM: Ladder|0{Wild type gyp|Knockout}|5{WT|A very long label at the last lane}")
    lay = layout(p, 500, 300)
    last = lane_texts(lay)[-1]
    assert last.bounds.max_x > lay.gel_rect.max_x + 1   # it does stick out past the gel's right edge ...
    margin = 2.2
    assert lay.size[0] >= last.bounds.max_x + margin - 1e-9   # ... and the figure grew to hold it, with the usual margin
    for t in lay.texts:
        assert t.bounds.min_x >= margin - 1e-9 and t.bounds.min_y >= margin - 1e-9
        assert t.bounds.max_x <= lay.size[0] - margin + 1e-9 and t.bounds.max_y <= lay.size[1] + 1e-9
    ink = render.raster(lay, None)   # drawn without the gel: nothing touches the edge of the file
    assert min(ink[0].min(), ink[-1].min(), ink[:, 0].min(), ink[:, -1].min()) == 255


def test_ninety_degrees_is_centred_on_the_lane_and_the_middle_line_goes_through_the_lane_at_any_angle():
    p = labelled(90, "µM: |0{HHH|HHH}|5{HHH|HHH}")
    p.rows[0].labels = ["", "", "HHH", "", ""]
    lay = layout(p, 500, 300)
    (t,) = lane_texts(lay)
    lane = lay.point(p.lanes.centers[2], 0)[0]
    cap = metrics(t.font).cap_height
    assert abs(t.origin[0] - cap / 2 - lane) < 1e-9   # the middle line (half a cap height from the baseline) is on the lane
    k = 8 / 1   # eight pixels to the point
    ink = render._overlay_gray(lay, k, int(lay.size[0] * k), int(lay.size[1] * k)) < 128
    x0, x1 = int(t.bounds.min_x * k) - 4, int(t.bounds.max_x * k) + 4
    y0, y1 = int(t.bounds.min_y * k), int(t.bounds.max_y * k)
    cols = np.nonzero(ink[y0:y1, x0:x1].any(axis=0))[0] + x0
    assert abs((cols.min() + cols.max() + 1) / 2 / k - lane) < 0.3   # the capitals' ink is centred on the lane, to 0.3 pt
    for angle in (30, 45, 70):   # at an angle the middle line crosses the first letter's bar, over the lane's centre
        p = labelled(angle)
        p.rows[0].labels = ["", "", "HHH", "", ""]
        lay = layout(p, 500, 300)
        (t,) = lane_texts(lay)
        a = math.radians(angle)
        ink = render._overlay_gray(lay, k, int(lay.size[0] * k), int(lay.size[1] * k)) < 128
        half_cap = metrics(t.font).cap_height / 2
        ax, ay = t.origin[0] - half_cap * math.sin(a), t.origin[1] - half_cap * math.cos(a)   # the anchor A = O - (c/2)(sin, cos)
        assert abs(ax - lay.point(p.lanes.centers[2], 0)[0]) < 1e-9
        mid = text_width("H", t.font) / 2   # the first letter's bar is half an advance along the text
        px, py = ax + mid * math.cos(a), ay - mid * math.sin(a)
        ix, iy = int(round(px * k)), int(round(py * k))
        assert ink[iy - 3:iy + 4, ix - 3:ix + 4].any(), angle


def test_the_angle_is_in_the_json_and_clamped_on_load():
    p = labelled(45)
    d = json.loads(p.dumps())
    assert d["rows"][0]["rotation"] == 45 and all("rotation" not in r for r in d["rows"][1:])   # lane labels only
    q = GelProject.loads(p.dumps())
    assert q == p and q.label_angle == 45 and q.rows[0].rotation == 45
    assert "rotation" not in json.dumps(json.loads(labelled(0).dumps())["rows"])   # omitted at 0, as before
    for stored, want in [(120, 120), (-10, 350), (90, 90), (0.5, 0.5), (400, 40), (360, 0)]:
        d["rows"][0]["rotation"] = stored
        assert GelProject.from_json(d).rows[0].rotation == want and GelProject.from_json(d).label_angle == want
    d["rows"][0]["rotation"] = float("nan")
    with pytest.raises(ValueError, match="rotation should be a finite number"):
        GelProject.from_json(d)   # a damaged file says so (the app shows it as a damaged project)
    assert LabelRow.clamped_angle(float("nan")) == 0 and LabelRow.clamped_angle(float("inf")) == 0
    assert GelProject().label_angle == 0   # no lane labels at all
    group_only = GelProject(rows=[LabelRow("groups", rotation=30)])
    assert group_only.label_angle == 0     # a group row's rotation isn't the lane labels' angle
    lay = layout(labelled(45), 500, 300)   # and a layout reads it through the clamp, whatever a program stored
    odd = labelled(45)
    odd.rows[0].rotation = 400
    assert [t.rotation for t in lane_texts(layout(odd, 500, 300))] == [40] * len(lane_texts(lay))


def test_setting_the_angle_for_the_whole_figure():
    p = labelled(0)
    p.rows.append(LabelRow("lanes", labels=["a", "b", "c", "d", "e"]))   # a second row of lane labels
    assert ops.set_label_angle(p, 35) and [r.rotation for r in p.rows if r.type == "lanes"] == [35, 35]
    assert all(r.rotation == 0 for r in p.rows if r.type == "groups") and p.label_angle == 35
    assert ops.set_label_angle(p, 120) and p.label_angle == 120   # any angle
    assert ops.set_label_angle(p, -5) and p.label_angle == 355
    ops.set_label_angle(p, 60)
    for bad in (float("nan"), float("inf"), float("-inf")):
        assert not ops.set_label_angle(p, bad) and p.label_angle == 60   # not a number: nothing changes
    none = GelProject(rows=[LabelRow("groups")])
    assert not ops.set_label_angle(none, 45) and none.rows[0].rotation == 0   # no lane labels: nothing is stored
    assert not ops.set_label_angle(GelProject(), 45)
    ops.apply_quick_labels(p, "µM: Ladder|0{x|y}|5{z|w}")   # retyping the labels keeps the figure's angle
    assert p.label_angle == 60 and [r.rotation for r in p.rows if r.type == "lanes"] == [60]
    q = labelled(0)
    ops.apply_quick_labels(q, "a|b|c|d|e")
    assert q.label_angle == 0
    s = LabelScheme.loads(LabelScheme.of(labelled(30), False).dumps())   # copied labels bring the angle with them
    target = GelProject()
    s.apply(target, 500, 300)
    assert target.label_angle == 30


def test_a_click_on_rotated_text_is_tested_against_its_rotated_box():
    p = labelled(45)
    lay = layout(p, 500, 300)
    t = lane_texts(lay)[1]   # "Wild type gyp"
    corners = t.box
    assert len(corners) == 4
    assert abs(min(x for x, _ in corners) - t.bounds.min_x) < 1e-9 and abs(max(y for _, y in corners) - t.bounds.max_y) < 1e-9
    centre = (sum(x for x, _ in corners) / 4, sum(y for _, y in corners) / 4)
    assert t.contains(*centre)
    assert not t.contains(t.bounds.min_x + 0.5, t.bounds.min_y + 0.5)   # in the axis-aligned bounds, off the text
    assert not t.contains(t.bounds.max_x - 0.5, t.bounds.max_y - 0.5)
    cx, cy = corners[2]   # just inside and just outside a corner: the rotated edge is the edge
    inside = (cx + (centre[0] - cx) * 0.01, cy + (centre[1] - cy) * 0.01)
    outside = (cx - (centre[0] - cx) * 0.01, cy - (centre[1] - cy) * 0.01)
    assert t.contains(*inside) and not t.contains(*outside)
    horizontal = lane_texts(layout(labelled(0), 500, 300))[1]
    assert horizontal.contains(horizontal.bounds.min_x + 0.1, horizontal.bounds.min_y + 0.1)   # unrotated: the bounds
    assert horizontal.contains(horizontal.bounds.min_x - 1, horizontal.bounds.min_y + 3, pad_x=1.5)   # padding widens it


# ---------------------------------------------------------------------------------------------------- the command line


def run(capsys, *args):
    code = cli.main([str(a) for a in args])
    out, err = capsys.readouterr()
    return code, out, err


def project(folder) -> GelProject:
    return GelProject.loads((Path(folder) / "project.json").read_text(encoding="utf-8"))


@pytest.fixture
def folder(tmp_path, capsys):
    img = tmp_path / "gel.png"
    Image.fromarray(np.full((120, 400), 200, np.uint8)).save(img)
    assert run(capsys, "new", img)[0] == 0
    return tmp_path / "gel.gelscribe"


def test_the_command_line_stands_the_lane_labels_at_an_angle(folder, capsys):
    assert "--label-angle DEG" in run(capsys, "help")[1]   # listed in the usage text
    code, _, err = run(capsys, "edit", folder, "--dividers", "100,200,300", "--label-angle", 45, "--labels", "Ladder|a|b|c")
    assert code == 0 and "wasn't stored" not in err   # the labels come first, so the angle finds its row
    assert project(folder).label_angle == 45
    assert run(capsys, "edit", folder, "--labels", "a|b|c|d")[0] == 0   # retyped: the angle stays
    assert project(folder).label_angle == 45
    assert run(capsys, "edit", folder, "--label-angle", "90")[0] == 0 and project(folder).label_angle == 90
    assert run(capsys, "edit", folder, "--label-angle", "0")[0] == 0 and project(folder).label_angle == 0
    assert "rotation" not in (folder / "project.json").read_text()
    before = (folder / "project.json").read_bytes()
    for bad, message in [("nan", "--label-angle wants an angle in degrees"), ("inf", "wants an angle in degrees"),
                         ("steep", "wants an angle in degrees")]:
        code, out, err = run(capsys, "edit", folder, "--label-angle", bad)
        assert code == 1 and message in err and out == "" and "Traceback" not in err, bad
        assert (folder / "project.json").read_bytes() == before
    assert run(capsys, "edit", folder, "--label-angle")[0] == 2   # no value
    # the scheme comes in first and the angle after it, so the angle given wins
    other = folder.parent / "other.gelscribe"
    assert run(capsys, "new", folder.parent / "gel.png", "-o", other)[0] == 0
    assert run(capsys, "edit", folder, "--label-angle", 30)[0] == 0
    assert run(capsys, "edit", other, "--scheme-from", folder)[0] == 0 and project(other).label_angle == 30
    assert run(capsys, "edit", other, "--scheme-from", folder, "--label-angle", 70)[0] == 0 and project(other).label_angle == 70


def test_an_angle_with_no_lane_labels_stores_nothing_and_says_so(folder, capsys):
    code, _, err = run(capsys, "edit", folder, "--label-angle", 45)
    assert code == 0 and "no lane labels yet" in err and project(folder).label_angle == 0
    assert "rotation" not in (folder / "project.json").read_text() and project(folder).rows == []


def test_labels_at_an_angle_render_in_every_format(folder, capsys):
    assert run(capsys, "edit", folder, "--dividers", "100,200,300", "--labels", "µM: Ladder|0{Wild type gyp|Knockout}|5{WT}",
               "--label-angle", 45)[0] == 0
    code, out, err = run(capsys, "render", folder, "--formats", "png,pdf,svg,tiff")
    assert code == 0 and err == "" and len(out.split("\n")) == 5
    svg = Path(out.split("\n")[2]).read_text(encoding="utf-8")
    assert "rotate(-45.000" in svg and ">Wild type gyp<" in svg   # the text stays text, turned
