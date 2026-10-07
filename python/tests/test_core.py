"""The Mac app's GelKit tests, ported: the two versions follow the same rules."""
import io
import math

import numpy as np
import pytest
import tifffile
from PIL import Image

from conftest import FIXTURE
from gelscribe.core import labels as ql
from gelscribe.core import ops, render
from gelscribe.core.detect import snap_band
from gelscribe.core.image import SourceImage, WorkingImage, padding_mask
from gelscribe.core.ladders import BUILTIN
from gelscribe.core.layout import layout, spread_1d, spread_1d_gaps
from gelscribe.core.model import (BandAnnotation, DisplaySettings, GelProject, LADDER_UNIT, Ladder, LadderBand,
                                  LaneDivider, PixelRect, Role, ValueScale)
from gelscribe.core.package import GelPackage
from gelscribe.core.scheme import LabelScheme

needs_fixture = pytest.mark.skipif(not FIXTURE.exists(), reason="needs mac/TestData/gel.png")


def tiff16(width, height, fn, description=None, photometric="minisblack"):
    a = np.fromfunction(lambda y, x: fn(x, y), (height, width), dtype=np.int64).astype(np.uint16)
    buf = io.BytesIO()
    tifffile.imwrite(buf, a, photometric=photometric, description=description)
    return buf.getvalue(), a


def faint_gel(description=None):
    """Background 1500, a darker band (1000) across rows 95–105, a ramp elsewhere."""
    return tiff16(60, 200, lambda x, y: np.where((y >= 95) & (y <= 105), 1000, 1400 + (x + y) % 100), description)


# ---------------------------------------------------------------------------------------------------- labels


def test_braces_nest_to_three_rows():
    text = "Strain, µM: WT{0{L|P}|125{L|P}}|KO{0{L|P}|125{L|P}}"
    p = GelProject()
    r = ops.apply_quick_labels(p, text)
    assert r.warnings == [] and len(p.rows) == 3
    assert p.rows[0].labels == ["L", "P"] * 4
    assert p.rows[1].name == "µM" and [g.text for g in p.rows[1].groups] == ["0", "125", "0", "125"]
    assert [g.lanes for g in p.rows[1].groups] == [[1, 2], [3, 4], [5, 6], [7, 8]]
    assert p.rows[2].name == "Strain" and [g.lanes for g in p.rows[2].groups] == [[1, 2, 3, 4], [5, 6, 7, 8]]
    assert ql.shorthand(p) == text


def test_a_label_right_over_lanes_sits_in_the_row_right_above_them():
    r = ql.build(ql.parse("A{1{x|y}|2{x|y}}|B{z|w}")[0], 6)
    assert [g.text for g in r.rows[1].groups] == ["1", "2", "B"]
    assert [g.text for g in r.rows[2].groups] == ["A"] and r.rows[2].groups[0].lanes == [1, 2, 3, 4]


def test_blanks_and_single_lane_groups():
    r = ql.build(ql.parse("|0{L|P}|750{P}|1000{}|0L")[0], 6)
    assert r.rows[0].labels == ["", "L", "P", "P", "", "0L"]
    assert [g.lanes for g in r.rows[1].groups] == [[2, 3], [4], [5]]
    assert r.ladder_lane is None


def test_unbalanced_braces_are_repaired_with_a_warning():
    items, w = ql.parse("A{1|2")
    assert items == [ql.Group("A", ["1", "2"])] and len(w) == 1
    items, w = ql.parse("A|B}|C")
    assert ql.lanes_of(items) == ["A", "B", "C"] and len(w) == 1


def test_titles_need_letters_so_ratios_stay_labels():
    assert ql.split_row_name("1:10|1:100")[0] == []
    assert ql.split_row_name("µM: 0{L|P}")[0] == ["µM"]
    assert ql.split_row_name("Strain, µM: x")[0] == ["Strain", "µM"]
    p = GelProject()
    ops.apply_quick_labels(p, "µM: WT{0{L|P}}|KO{0{L|P}}")
    assert p.rows[1].name == "µM" and p.rows[2].name is None


def test_a_known_ladder_lane_shifts_the_groups():
    p = GelProject()
    ops.set_dividers(p, [100, 200, 300, 400], 500, 300)
    p.ladder = Ladder(lane=1)
    ops.apply_quick_labels(p, "0{L|P}|125{L|P}")
    assert p.rows[0].labels == ["", "L", "P", "L", "P"]
    assert [g.lanes for g in p.rows[1].groups] == [[2, 3], [4, 5]]


def test_titles_stay_when_none_are_typed_unless_editing_the_shorthand():
    p = GelProject()
    ops.apply_quick_labels(p, "Strain, µM: WT{0{L|P}}|KO{0{L|P}}")
    q = p.copy()
    ops.apply_quick_labels(p, "WT{0{L|P}|5{L|P}}|KO{0{L|P}}")
    assert p.rows[1].name == "µM" and p.rows[2].name == "Strain"
    ops.apply_quick_labels(q, "WT{0{L|P}|5{L|P}}|KO{0{L|P}}", keep_titles=False)
    assert q.rows[1].name is None and q.rows[2].name is None


def test_ladder_word_and_plain_labels():
    r = ql.build(ql.parse("ladder|0{L|P}|125{L|P}|250{L|P}|500{L|P}|750{L|P}|1000{}")[0], 12)
    assert r.ladder_lane == 1 and len(r.rows) == 2 and r.warnings == []
    assert [g.lanes for g in r.rows[1].groups] == [[2, 3], [4, 5], [6, 7], [8, 9], [10, 11], [12]]
    r = ql.build(["M", "WT", "K12A", "uncut"], 4)
    assert len(r.rows) == 1 and r.ladder_lane == 1


def test_shorthand_round_trips_and_works_before_lanes():
    text = "µM: Ladder|0{L|P}|125{L|P}|250{L|P}|500{L|P}|750{L|P}|1000{}"
    a = GelProject()
    ops.apply_quick_labels(a, text)
    assert len(a.rows) == 2 and len(a.rows[0].labels) == 12
    assert ql.shorthand(a) == text
    ops.set_dividers(a, [i * 150.0 for i in range(1, 12)], 1900, 1000)
    assert a.lane_count == 12
    b = GelProject()
    ops.apply_quick_labels(b, ql.shorthand(a))
    assert b.rows == a.rows


def test_line_breaks_round_trip_through_quick_labels():
    p = GelProject()
    ops.apply_quick_labels(p, "µM: |0{WT\\nKO|P}|125{L|P}")
    assert p.rows[0].labels[:3] == ["", "WT\nKO", "P"]
    text = ql.shorthand(p)
    assert "WT\\nKO" in text and "WT\n" not in text
    q = GelProject()
    ops.apply_quick_labels(q, text)
    assert q.rows == p.rows


# ---------------------------------------------------------------------------------------------------- geometry, ladder


def test_dividers_make_lanes_including_the_edges():
    p = GelProject()
    ops.set_dividers(p, [262, 391, 520, 649, 778, 907, 1036, 1165, 1294, 1423, 1552], 1816, 1312)
    assert p.lane_count == 12
    assert abs(p.lanes.centers[0] - 198) < 3 and abs(p.lanes.centers[11] - 1617) < 3
    p.lanes.outer_lanes = False
    p.sync_lane_centers(1816, 1312)
    assert p.lane_count == 10


def test_tilted_divider_centres_follow_the_crop_top():
    p = GelProject()
    p.lanes.dividers = [LaneDivider(100, 140, 50), LaneDivider(300, 340, 50)]
    p.lanes.outer_lanes = False
    p.crop = PixelRect(0, 500, 400, 1000)
    p.sync_lane_centers(400, 1000)
    assert p.lanes.centers == [220]


def test_top_down_guesses_are_marked_auto():
    l = Ladder(bands=[LadderBand(10), LadderBand(20), LadderBand(30, ignore=True), LadderBand(40)])
    l.assign([250, 130, 100])
    assert [b.size for b in l.bands] == [250, 130, None, 100]
    assert [b.auto for b in l.bands] == [True, True, False, True]
    assert l.warnings == []
    l.bands[1].size = 300
    assert l.warnings


def test_switching_gel_system_relabels_band_for_band():
    pr = next(p for p in BUILTIN if "26617" in p.catalogs)
    assert pr.id == "thermo-pageruler-prestained"
    p = GelProject()
    p.ladder = Ladder(bands=[LadderBand(100.0 * i) for i in range(10)])
    ops.apply_preset(p, pr)
    assert [b.size for b in p.ladder.bands] == [180, 130, 100, 70, 55, 40, 35, 25, 15, 10]
    p.ladder.bands[2].auto = False
    ops.apply_system(p, pr, pr.system("bt-4-12-mops"))
    assert [b.size for b in p.ladder.bands] == [140, 115, 80, 65, 50, 40, 30, 25, 15, 10]
    assert p.ladder.bands[2].auto is False and p.ladder.bands[3].auto is True
    ops.apply_system(p, pr, pr.system("bt-10-mops"))
    assert p.ladder.bands[-1].size is None and p.ladder.system == "NuPAGE Bis-Tris 10%, MOPS"


def test_size_list_parsing():
    assert ops.parse_sizes("250, 130 | 100 70;55 kDa") == [250, 130, 100, 70, 55]


def test_strict_ignores_rotation_and_marks_follow():
    p = GelProject(image="x", strict=False)
    p.ladder = Ladder(bands=[LadderBand(300)])
    p.lanes.centers = [100]
    ops.set_rotation(p, 3, 2000, 1400)
    turned = p.ladder.bands[0].y
    ops.set_strict(p, True, 2000, 1400)
    assert p.effective_rotation == 0 and p.rotate_deg == 3
    assert abs(p.ladder.bands[0].y - 300) <= 1
    ops.set_strict(p, False, 2000, 1400)
    assert abs(p.ladder.bands[0].y - turned) <= 1


def test_leveling_angle_makes_the_line_level():
    a, b = (200.0, 300.0), (1800.0, 355.0)
    d = ops.leveling_angle(a, b)
    assert abs(d - math.degrees(math.atan2(55, 1600))) < 1e-9
    assert abs(ops.leveling_angle(b, a) - d) < 1e-9
    assert ops.leveling_angle((100, 0), (130, 1000)) < 0


def test_naming_scheme_moves_to_another_gel_without_its_positions():
    a = GelProject(image="a.png", strict=False, title="WT")
    ops.set_dividers(a, [100, 200, 300], 400, 300)
    ops.apply_quick_labels(a, "Ladder|0{L|P}|125{L}", group_row_name="µM")
    a.ladder = Ladder(lane=1, name="PageRuler Prestained (26616/26617/26618)", sizes=[140, 115, 80],
                      system="NuPAGE Bis-Tris 4–12%, MES", bands=[LadderBand(50, 140)])
    a.annotations = [BandAnnotation(80, "Protein")]
    a.style.set_size_for_kind(9, "name")
    b = GelProject(image="b.png")
    LabelScheme.loads(LabelScheme.of(a, False).dumps()).apply(b, 800, 600)   # through the clipboard format
    assert b.rows == a.rows and b.title == "WT" and b.annotations[0].text == "Protein"
    assert b.ladder.system == "NuPAGE Bis-Tris 4–12%, MES" and b.ladder.sizes == [140, 115, 80]
    assert b.ladder.bands == [] and b.lanes.dividers == []
    assert b.strict and b.image == "b.png" and b.style.size_for_kind("name") == 9
    c = GelProject(image="c.png")
    LabelScheme.of(a, True).apply(c, 400, 300)
    assert c.lane_count == 4 and len(c.ladder.bands) == 1


# ---------------------------------------------------------------------------------------------------- layout


def test_spread_keeps_order_and_minimum_gap():
    out = spread_1d([0, 1, 20, 21, 21.5, 50], 7.7)
    assert all(b - a >= 7.7 - 1e-9 for a, b in zip(out, out[1:]))
    assert abs(out[0] + out[1] - 1) < 1e-9
    targets = [10, 11, 12, 30, 31, 60]
    assert all(abs(x - y) < 1e-9 for x, y in zip(spread_1d(targets, 7.7), spread_1d_gaps(targets, [7.7] * 6)))


def _unit_project(unit_y):
    p = GelProject(image="g.png")
    p.lanes.centers = [50, 150]
    p.ladder = Ladder(lane=1, bands=[LadderBand(100, 140), LadderBand(300, 50)], unit_y=unit_y)
    return p


def test_placed_unit_sits_on_its_row():
    l = layout(_unit_project(200), 200, 400)
    unit = next(t for t in l.texts if t.role == LADDER_UNIT)
    assert abs(unit.bounds.mid_y - l.point(0, 200)[1]) < 2
    auto = layout(_unit_project(None), 200, 400)
    assert next(t for t in auto.texts if t.role == LADDER_UNIT).bounds.max_y < auto.gel_rect.min_y


def _lanes_project(labels):
    p = GelProject(image="a.png")
    ops.set_dividers(p, [100, 200, 300], 400, 300)
    from gelscribe.core.model import LabelRow
    p.rows = [LabelRow("lanes", labels=labels)]
    return p


def test_a_second_line_makes_the_row_taller():
    one = layout(_lanes_project(["WT", "A", "B", "C"]), 400, 300)
    two = layout(_lanes_project(["WT\nKO", "A", "B", "C"]), 400, 300)
    t1 = next(t for t in one.texts if t.string == "WT")
    t2 = next(t for t in two.texts if t.string == "WT\nKO")
    assert t2.lines == ["WT", "KO"]
    assert abs(t2.bounds.h - t1.bounds.h - t2.line_height) < 0.01
    drop = two.gel_rect.min_y - one.gel_rect.min_y
    assert t2.line_height - 0.01 <= drop <= t2.line_height + two.pt_per_px + 0.01
    assert abs((t2.origin[1] - two.gel_rect.min_y) - (t1.origin[1] - one.gel_rect.min_y)) < 0.01


def test_names_of_several_lines_stay_centred_and_svg_keeps_one_text():
    p = _lanes_project(["", "A", "B", "C"])
    p.annotations = [BandAnnotation(150, "Protein\n(80 kDa)")]
    l = layout(p, 400, 300)
    t = next(t for t in l.texts if t.role == Role("annotation", 0))
    assert abs(t.bounds.mid_y - l.point(0, 150)[1]) < 1.5
    s = render.svg(layout(_lanes_project(["WT\nKO", "A", "B", "C"]), 400, 300), None, render.ExportInfo("", ""))
    assert "<tspan" in s and ">WT</tspan>" in s and ">KO</tspan>" in s


# ---------------------------------------------------------------------------------------------------- images, strict


@needs_fixture
def test_raster_export_carries_original_pixels_exactly():
    data = FIXTURE.read_bytes()
    src = SourceImage(data)
    p = GelProject(image="gel.png", title="WT")
    p.crop = PixelRect(20, 80, 1940, 1290)
    p.lanes.centers = [114, 272, 430, 589, 747, 905, 1063, 1222, 1380, 1538, 1696, 1855]
    p.lanes.width = 130
    from gelscribe.core.model import LabelRow
    p.rows = [LabelRow("lanes", labels=["", "L", "P"] + ["L", "P"] * 4 + [""])]
    p.ladder = Ladder(lane=1, bands=[LadderBand(155, 250), LadderBand(304, 100)])
    p.annotations = [BandAnnotation(244, "Protein")]
    w = WorkingImage(src, p)
    lay = layout(p, w.width, w.height)
    gel = w.figure_image(p)
    original = src.pixels[80:1290, 20:1940]
    info = render.export_info(p, src.sha256)
    k = 1 / lay.pt_per_px
    gx, gy = round(lay.gel_rect.x * k), round(lay.gel_rect.y * k)
    for fmt in ("png", "tiff"):
        out = np.array(Image.open(io.BytesIO(render.raster_data(lay, gel, fmt, info))))
        assert out.dtype == np.uint8
        assert np.array_equal(out[gy:gy + 1210, gx:gx + 1920], original), fmt


def test_sixteen_bit_gray_stays_sixteen_bit_and_exact_in_png_tiff_and_pdf():
    import pikepdf
    data, a = tiff16(240, 160, lambda x, y: (x * 271 + y * 977) % 65536)
    src = SourceImage(data)
    assert src.bits == 16 and np.array_equal(src.pixels, a)
    p = GelProject(image="s.tif")
    w = WorkingImage(src, p)
    lay = layout(p, w.width, w.height)
    gel = w.figure_image(p)
    info = render.export_info(p, src.sha256)
    k = 1 / lay.pt_per_px
    gx, gy = round(lay.gel_rect.x * k), round(lay.gel_rect.y * k)
    tif = tifffile.imread(io.BytesIO(render.raster_data(lay, gel, "tiff", info)))
    assert tif.dtype == np.uint16 and np.array_equal(tif[gy:gy + 160, gx:gx + 240], a)
    png = Image.open(io.BytesIO(render.raster_data(lay, gel, "png", info)))
    assert np.array_equal(np.array(png, dtype=np.uint16)[gy:gy + 160, gx:gx + 240], a)
    with pikepdf.open(io.BytesIO(render.pdf(lay, gel, info))) as doc:
        img = next(iter(doc.pages[0].get_images().values()))
        assert int(img.BitsPerComponent) == 16
        samples = np.frombuffer(img.read_bytes(), dtype=">u2").reshape(160, 240)
        assert np.array_equal(samples, a)
        assert "strict" in str(doc.docinfo["/Subject"])


def test_white_is_zero_files_open_like_imagej_and_export_as_the_mac_app_does():
    desc = "ImageJ=1.54p\nmin=5.0\nmax=503.0\n"
    data, a = tiff16(60, 50, lambda x, y: 5 + (x * 7 + y) % 600, description=desc, photometric="miniswhite")
    pkg = GelPackage.create(data, "g.tif")
    src = SourceImage(data)
    assert src.scale == ValueScale(65535, True) and src.imagej_range == (5, 503)
    lo, hi = pkg.project.display.range_in(src.scale)
    assert abs(lo - 5) < 1e-6 and abs(hi - 503) < 1e-6
    assert np.array_equal(src.pixels, 65535 - a)          # the right way round, as the Mac app reads it
    w = WorkingImage(src, pkg.project)
    assert np.array_equal(w.figure_image(pkg.project), src.pixels)   # Strict: those values, untouched


def test_sixteen_bit_images_open_with_their_own_range_and_eight_bit_unchanged():
    pkg = GelPackage.create(faint_gel()[0], "b.tif")
    lo, hi = pkg.project.display.range_in(ValueScale(65535))
    assert abs(lo - 1000) < 0.5 and abs(hi - 1499) < 0.5 and pkg.project.strict
    buf = io.BytesIO()
    Image.fromarray(np.arange(16, dtype=np.uint8).reshape(4, 4) * 17).save(buf, "PNG")
    assert GelPackage.create(buf.getvalue(), "c.png").project.display.is_identity


def test_display_range_math_and_precision():
    s = ValueScale(65535, True)
    d = DisplaySettings()
    d.set_range(5, 503, s)
    lo, hi = d.range_in(s)
    assert abs(lo - 5) < 1e-6 and abs(hi - 503) < 1e-6
    from gelscribe.core.image import render_gray
    g = (np.arange(256, dtype=np.float32) + 1000) / 65535
    e = DisplaySettings()
    e.set_range(1000, 1255, ValueScale(65535))
    assert len(set(render_gray(g.reshape(1, -1), e).ravel().tolist())) >= 250


def test_strict_exports_ignore_the_display_range_and_say_what_was_done():
    pkg = GelPackage.create(faint_gel()[0], "d.tif")
    src = SourceImage(pkg.image_data)
    w = WorkingImage(src, pkg.project)
    assert np.array_equal(w.figure_image(pkg.project), src.pixels)
    pkg.project.strict = False
    info = render.export_info(pkg.project, None, scale=src.scale)
    assert "display range 1000–1499 of 65535" in info.description


def test_clicks_snap_to_faint_bands():
    src = SourceImage(faint_gel()[0])
    w = WorkingImage(src, GelProject(image="e.tif"))
    y = snap_band(w.darkness(True), 30, 92, 40)
    assert y is not None and abs(y - 100) <= 2


@needs_fixture
def test_clicks_snap_to_ladder_band_centres():
    w = WorkingImage(SourceImage(FIXTURE.read_bytes()), GelProject(image="x"))
    dark = w.darkness(True)
    for y, want in zip([150, 210, 300, 510, 640, 760, 860, 1050, 1210],
                       [155, 206, 304, 515, 640, 765, 857, 1047, 1213]):
        s = snap_band(dark, 114, y, 130)
        assert s is not None and abs(s - want) <= 2, (y, s, want)


@needs_fixture
def test_wedges_found_but_flat_background_is_gel():
    src = SourceImage(FIXTURE.read_bytes())
    mask = padding_mask(src.gray)
    n, total = int(mask.sum()), mask.size
    assert total / 100 < n < total / 20
    assert mask[0, 0] and mask[-1, -1] and not mask[700, 1200]
    w = WorkingImage(src, GelProject(image="x"))
    assert abs(w.background * 255 - 225) < 2


@needs_fixture
def test_marks_stay_on_their_bands_when_the_image_turns():
    src = SourceImage(FIXTURE.read_bytes())
    p = GelProject(image="x", strict=False)
    p.lanes.centers, p.lanes.width = [114], 130
    p.ladder = Ladder(lane=1, bands=[LadderBand(304, 100), LadderBand(857, 25)])
    ops.set_rotation(p, 5, src.width, src.height)
    dark = WorkingImage(src, p).darkness(True)
    t, cx, cy = math.radians(5), (src.width - 1) / 2, (src.height - 1) / 2
    for b in p.ladder.bands:
        orig = 304.0 if b.size == 100 else 857.0
        x = math.cos(t) * (114 - cx) + math.sin(t) * (orig - cy) + cx
        s = snap_band(dark, x, b.y, 130)
        assert s is not None and abs(s - b.y) <= 3


def test_packages_keep_the_image_byte_for_byte(tmp_path):
    data, _ = faint_gel()
    pkg = GelPackage.create(data, "gel.tif")
    folder = tmp_path / "x.gelscribe"
    pkg.write(folder)
    img = folder / pkg.project.image
    before = img.stat().st_mtime_ns
    again = GelPackage.read(folder)
    assert again.image_data == data and again.image_intact is True
    again.project.title = "changed"
    again.write(folder)
    assert img.stat().st_mtime_ns == before
    assert GelPackage.read(folder / "project.json").project.title == "changed"


def test_resampling_redraws_at_the_asked_resolution_and_records_it():
    data, _ = faint_gel()
    src = SourceImage(data)
    p = GelProject(image="r.tif")
    w = WorkingImage(src, p)
    lay = layout(p, w.width, w.height)
    native = render.native_dpi(lay)
    assert render.resample_dpi(None, lay) is None and render.resample_dpi(native, lay) is None
    info = render.export_info(p, src.sha256, resampled_dpi=300, native_dpi=native)
    assert f"resampled to 300 dpi from {int(math.floor(native + 0.5))} dpi" in info.description
    out = Image.open(io.BytesIO(render.raster_data(lay, w.figure_image(p), "png", info, 300)))
    assert out.size == (int(math.floor(lay.size[0] * 300 / 72 + 0.5)), int(math.floor(lay.size[1] * 300 / 72 + 0.5)))
    assert abs(out.info["dpi"][0] - 300) < 0.1
