"""Several gels in one figure (gelscribe/core/strips.py): the same cases as the Mac app's tests, on made-up gels."""
import io
import json

import numpy as np
import pytest
from PIL import Image

from gelscribe.core import ops, render
from gelscribe.core import strips as stacked
from gelscribe.core.image import SourceImage, WorkingImage
from gelscribe.core.layout import layout
from gelscribe.core.model import BandAnnotation, GelProject, PixelRect
from gelscribe.core.package import GelPackage, ProjectError

MAIN_LANES = [60 + 70 * i for i in range(8)]


def piece_png(width, height, lanes, band_rows, value=None) -> bytes:
    """An 8-bit gray PNG of a made-up blot piece: dark lanes (bands at band_rows) on a light background."""
    yy, xx = np.mgrid[0:height, 0:width]
    v = np.full((height, width), 230.0) if value is None else value(xx, yy).astype(float)
    for c in lanes:
        across = np.exp(-((xx - c) / 10) ** 2 / 2) * (np.abs(xx - c) < 26)   # rounded across, like a real lane
        for r in band_rows:
            v -= 170 * across * np.exp(-((yy - r) / 4) ** 2 / 2)
    buf = io.BytesIO()
    Image.fromarray(np.clip(np.floor(v + 0.5), 0, 255).astype(np.uint8)).save(buf, format="PNG")
    return buf.getvalue()


def cut_blot(shift=37.0, scale=1.0) -> GelPackage:
    """A main piece and a second gel whose lanes sit shift px further right and scale times as far apart."""
    top = piece_png(620, 160, MAIN_LANES, [60, 110], lambda x, y: 200 + (x * 7 + y * 3) % 40)
    bottom = piece_png(700, 220, [scale * c + shift for c in MAIN_LANES], [90], lambda x, y: 190 + (x * 5 + y * 11) % 50)
    pkg = GelPackage.create(top, "top.png")
    ops.set_dividers(pkg.project, [(a + b) / 2 for a, b in zip(MAIN_LANES, MAIN_LANES[1:])], 620, 160)
    pkg.add_strip(bottom, "bottom.png")
    return pkg


def working(pkg):
    p = pkg.project
    main = WorkingImage(SourceImage(pkg.image_data), p)
    return main, [WorkingImage(SourceImage(pkg.strip_data(k + 1)), p.strip_project(k + 1)) for k in range(len(p.strips))]


def stack(pkg, w):
    return stacked.StackGeometry(pkg.project, w[0].width, w[0].height, [(s.width, s.height) for s in w[1]])


def test_quarter_turns_only_move_pixels():
    s = SourceImage(piece_png(50, 30, [10, 30], [12], lambda x, y: (x * 3 + y * 5) % 200))
    t = s.turned(1)
    assert t.pixels.shape == (50, 30)
    for x, y in [(0, 0), (49, 0), (7, 21), (49, 29)]:
        assert t.pixels[x, 30 - 1 - y] == s.pixels[y, x]   # clockwise: (x, y) → (h − 1 − y, x), as on the Mac
    assert np.array_equal(s.turned(1).turned(1).turned(1).turned(1).pixels, s.pixels)
    p = GelProject(image="x.png")
    p.turn = 2
    assert np.array_equal(WorkingImage(s, p).source.pixels, s.pixels[::-1, ::-1])
    assert s.turned(2).sha256 == s.sha256   # the file is the same file


def test_projects_with_gels_round_trip_and_old_ones_still_read():
    pkg = cut_blot()
    p = pkg.project
    p.turn, p.main_position = 2, 1
    p.strips[0].top, p.strips[0].bottom, p.strips[0].shift, p.strips[0].scale = 10, 200, 12.5, 1.02
    ops.add_tick(p, 90, 40, lane=1, gel_center_x=310, strip=1)
    p.annotations.append(BandAnnotation(90, "Protein Y", strip=1))
    d = json.loads(p.dumps())
    assert d["turn"] == 2 and d["main_position"] == 1 and d["strips"][0]["image"] == "bottom.png"
    assert d["ladder"]["bands"][0]["strip"] == 1 and d["annotations"][0]["strip"] == 1
    assert GelProject.loads(p.dumps()) == p
    old = json.loads(p.dumps())
    for k in ("turn", "strips", "main_position"):
        del old[k]
    q = GelProject.from_json(old)
    assert q.strips == [] and q.turn == 0 and q.stack_order == [None]


def test_a_mac_project_with_gels_reads_and_writes_the_same_keys():
    mac = {"image": "top.png", "strict": False, "fill_padding": True, "rotate_deg": -1.3, "fill_mode": "background",
           "display": {"black": 0, "white": 0.682, "gamma": 1, "invert": False, "bands_dark": True},
           "lanes": {"dividers": [], "outer_lanes": True, "centers": [], "width": 100}, "rows": [],
           "annotations": [{"y": 97, "text": "Loading control", "marker": "arrow", "side": "right", "strip": 1}],
           "style": {}, "ladder": {"lane": 1, "unit": "kDa", "side": "left",
                                   "bands": [{"y": 92, "size": 140}, {"y": 47, "size": 40, "strip": 1}]},
           "strips": [{"image": "bottom-piece.png", "image_sha256": "50e9", "rotate_deg": 0,
                       "display": {"black": 0, "white": 0.878, "gamma": 1, "invert": False, "bands_dark": True},
                       "top": 35, "bottom": 337, "shift": -54.83, "scale": 1.025}]}
    p = GelProject.from_json(mac)
    assert p.strips[0].shift == -54.83 and p.strips[0].bottom == 337 and p.ladder.bands[1].strip == 1
    back = json.loads(p.dumps())
    assert back["strips"][0] == {**mac["strips"][0]}
    assert back["annotations"][0]["strip"] == 1 and "main_position" not in back and "turn" not in back


def test_packages_keep_every_image_byte_for_byte(tmp_path):
    pkg = cut_blot()
    folder = tmp_path / "cut.gelscribe"
    pkg.write(folder)
    back = GelPackage.read(folder)
    assert back.strip_images == pkg.strip_images and back.strip_intact(1) is True
    assert (folder / "bottom.png").read_bytes() == pkg.strip_images["bottom.png"]
    # the same name again gets a name of its own
    k = back.add_strip(pkg.strip_images["bottom.png"], "bottom.png")
    assert back.project.strips[k - 1].image == "bottom_1.png"
    # a leftover file under a gel's name is never taken for that gel
    (folder / "bottom_1.png").write_bytes(b"something else")
    with pytest.raises(ProjectError):
        back.write(folder)


def test_the_stack_maps_pieces_both_ways():
    pkg = cut_blot()
    w = working(pkg)
    g = stack(pkg, w)
    c = pkg.project.effective_crop(620, 160)
    assert [q.strip for q in g.pieces] == [None, 1]
    main, s = g.piece(None), g.piece(1)
    assert (main.top, main.bottom) == (c.y0, c.y1) and s.top == c.y1 + g.separator
    x, y = s.to_figure(*s.to_piece(123.0, s.top + 17))
    assert abs(x - 123) < 1e-9 and abs(y - (s.top + 17)) < 1e-9
    assert g.piece_at_figure_y(c.y1 + 0.5).strip in (None, 1)   # in the separator: the nearer one
    assert g.figure_y(1, 90) == s.top + 90 and g.figure_y(None, 400) is None
    assert g.crop.y1 == s.bottom


def test_auto_align_finds_the_shift_and_the_stretch():
    pkg = cut_blot(shift=37, scale=1.02)
    w = working(pkg)
    r = stacked.suggest_alignment(pkg.project.lanes.centers, w[1][0], True)
    assert r is not None and abs(r.shift - 37) < 3 and abs(r.scale - 1.02) < 0.006 and r.worst < 3
    strict = stacked.suggest_alignment(pkg.project.lanes.centers, w[1][0], True, allow_scale=False)
    assert strict.scale == 1 and strict.shift == round(strict.shift)


def test_strict_stacks_keep_both_originals():
    pkg = cut_blot(shift=37)
    p = pkg.project
    p.strips[0].shift = 37
    w = working(pkg)
    g = stack(pkg, w)
    gel = stacked.figure_image(w[0], w[1], p, g)
    c = p.effective_crop(620, 160)
    main_rows = int(c.y1 - c.y0)
    assert np.array_equal(gel[:main_rows], w[0].source.pixels[int(c.y0):int(c.y1), int(c.x0):int(c.x1)])
    assert (gel[main_rows:main_rows + g.separator] == 0).all()
    s = g.piece(1)
    top = int(s.top - g.crop.y0)
    x0 = int(c.x0 + 37)
    want = w[1][0].source.pixels[0:int(s.bottom - s.top), x0:x0 + int(c.width)]
    assert np.array_equal(gel[top:top + want.shape[0], :want.shape[1]], want)


def test_strict_refuses_mixed_pixel_formats():
    gray = np.zeros((20, 40), np.uint8)
    rgb = np.zeros((20, 40, 3), np.uint8)
    assert "RGB" in stacked.strict_mismatch(gray, rgb)
    assert stacked.strict_mismatch(gray, gray) is None
    assert stacked.strict_problem(gray, [gray, rgb], lambda k: f"Gel {k + 1}") == \
        "Gel 3 is 8-bit RGB, the gel with the lanes 8-bit gray"


def test_ticks_and_names_go_in_their_gel():
    pkg = cut_blot()
    p = pkg.project
    ops.add_tick(p, 60, None, lane=1, gel_center_x=310)
    ops.add_tick(p, 110, None, lane=1, gel_center_x=310)
    ops.add_tick(p, 90, None, lane=1, gel_center_x=310, strip=1)
    p.assign_ladder([140, 80, 40])   # top to bottom through the stack
    assert [b.size for b in p.ladder.bands] == [140, 80, 40]
    assert ops.suggested_size(p, 150, None, strip=1) is None
    p.ladder.sizes = [140, 80, 40, 30]
    assert ops.suggested_size(p, 150, None, strip=1) == 30 and ops.suggested_size(p, 20, None, strip=1) == 40
    p.annotations.append(BandAnnotation(90, "Protein Y", marker="tick", strip=1))
    w = working(pkg)
    g = stack(pkg, w)
    lay = layout(p, w[0].width, w[0].height, g)
    s = g.piece(1)
    top, bottom = lay.point(0, s.top)[1], lay.point(0, s.bottom)[1]
    forty = next(t for t in lay.texts if t.string == "40")
    name = next(t for t in lay.texts if t.string == "Protein Y")
    assert top < forty.bounds.mid_y < bottom and top < name.bounds.mid_y < bottom
    # without the stack, another gel's marks stay out rather than landing in the wrong place
    alone = layout(p, w[0].width, w[0].height)
    assert not any(t.string in ("Protein Y", "40") for t in alone.texts)


def test_provenance_lists_every_gel():
    pkg = cut_blot()
    p = pkg.project
    p.strips[0].turn, p.strips[0].shift = 2, 12
    info = render.export_info(p, "aaa", strips=[("bbb", None)]).description
    assert "2. bottom.png sha256 bbb" in info and "turned 180°" in info and "shifted 12 px" in info
    assert "2 separately scanned gels, top to bottom" in info and "1. top.png, as above" in info
    p.main_position = 1   # in the order they're stacked
    below = render.export_info(p, "aaa", strips=[("bbb", None)]).description
    assert "1. bottom.png sha256 bbb" in below and "2. top.png, as above" in below
    p.turn = 1   # a mixed figure's headline has no turn or crop (finding 2): the gel's own entry says it
    assert "as above (its lanes are the figure's), turned 90°" in render.export_info(p, "aaa").description
    p.strips[0].strict = True   # with every gel kept, the headline does
    assert "turned 90°, full frame" in render.export_info(p, "aaa").description


def test_half_turns_carry_marks_and_quarter_turns_drop_them():
    pkg = cut_blot()
    p = pkg.project
    p.strips[0].top, p.strips[0].bottom = 20, 200
    ops.add_tick(p, 30, 40, lane=1, gel_center_x=310, strip=1)
    p.annotations.append(BandAnnotation(50, "C", strip=1))
    ops.turn(p, 1, 2, 700, 220)
    assert p.strips[0].turn == 2 and (p.strips[0].top, p.strips[0].bottom) == (20, 200)
    assert p.ladder.bands[0].y == 220 - 1 - 30 and p.annotations[0].y == 220 - 1 - 50
    ops.turn(p, 1, 1, 700, 220)
    assert p.strips[0].turn == 3 and not p.ladder.bands and p.strips[0].top is None
    main = cut_blot().project
    dividers = [d.x_top for d in main.lanes.dividers]
    ops.turn(main, None, 2, 620, 160)
    ops.turn(main, None, 2, 620, 160)
    assert [d.x_top for d in main.lanes.dividers] == dividers and main.turn == 0


def test_removing_a_gel_renumbers_the_rest():
    pkg = cut_blot()
    pkg.add_strip(pkg.strip_data(1), "third.png")
    p = pkg.project
    ops.add_tick(p, 30, 40, lane=1, gel_center_x=310, strip=1)
    ops.add_tick(p, 50, 30, lane=1, gel_center_x=310, strip=2)
    p.annotations.append(BandAnnotation(50, "C", strip=2))
    ops.remove_strip(p, 1)
    assert [s.image for s in p.strips] == ["third.png"]
    assert [b.strip for b in p.ladder.bands] == [1] and [a.strip for a in p.annotations] == [1]


def test_names_stay_where_they_were_put_unless_there_are_several_gels():
    single = cut_blot().project
    single.strips = []
    single.crop = PixelRect(0, 40, 620, 130)
    one = stacked.StackGeometry(single, 620, 160, [])
    assert one.name_y(None, 20) == 20 and one.figure_y(None, 20) is None
    single.annotations = [BandAnnotation(20, "Above", marker="tick")]
    assert any(t.string == "Above" for t in layout(single, 620, 160, one).texts)
    pkg = cut_blot()
    g = stack(pkg, working(pkg))
    assert g.name_y(None, 20) == 20 and g.name_y(None, 200) is None
    assert g.name_y(1, 90) is not None and g.name_y(2, 90) is None


def test_the_gel_with_the_lanes_can_sit_below_another():
    pkg = cut_blot()
    p = pkg.project
    p.main_position = 1   # the other gel on top
    ops.add_tick(p, 90, 40, lane=1, gel_center_x=310, strip=1)
    ops.add_tick(p, 60, 80, lane=1, gel_center_x=310)
    w = working(pkg)
    g = stack(pkg, w)
    c = p.effective_crop(620, 160)
    assert [q.strip for q in g.pieces] == [1, None]
    main, top = g.piece(None), g.piece(1)
    assert (main.top, main.bottom) == (c.y0, c.y1)   # it keeps its own rows; the other stacks upward
    assert top.bottom == c.y0 - g.separator and g.crop.y0 == top.top and g.crop.y1 == c.y1
    assert p.stack_key(1, 90) < p.stack_key(None, 60)
    gel = stacked.figure_image(w[0], w[1], p, g)
    assert gel.shape[0] == int(round(g.crop.height))
    lay = layout(p, 620, 160, g)
    forty = next(t for t in lay.texts if t.string == "40")
    eighty = next(t for t in lay.texts if t.string == "80")
    assert forty.bounds.mid_y < eighty.bounds.mid_y


def test_moving_a_gel_takes_its_ticks_and_names():
    pkg = cut_blot()
    pkg.add_strip(pkg.strip_data(1), "third.png")
    p = pkg.project
    ops.add_tick(p, 30, None, lane=1, gel_center_x=310, strip=1)
    ops.add_tick(p, 50, None, lane=1, gel_center_x=310, strip=2)
    ops.add_tick(p, 70, None, lane=1, gel_center_x=310)
    p.annotations.append(BandAnnotation(50, "C", strip=2))
    assert p.stack_order == [None, 1, 2]
    ops.move_gel(p, 2, 0)   # third.png to the top
    assert p.stack_order == [1, None, 2] and p.main_slot == 1
    assert [s.image for s in p.strips] == ["third.png", "bottom.png"]
    by_y = {b.y: b.strip for b in p.ladder.bands}
    assert by_y == {50: 1, 30: 2, 70: None} and [a.strip for a in p.annotations] == [1]
    p.assign_ladder([100, 50, 20])   # sizes go top to bottom through the new order
    sizes = {b.strip: b.size for b in p.ladder.bands}
    assert sizes == {1: 100, None: 50, 2: 20} and p.ladder_warnings == []
    back = GelProject.loads(p.dumps())
    assert back.main_position == 1 and back.stack_order == [1, None, 2]
    before = p.copy()
    ops.reorder(p, [0, 0, 1])
    assert p == before


def test_removing_a_gel_above_the_lanes_keeps_the_order():
    pkg = cut_blot()
    pkg.add_strip(pkg.strip_data(1), "third.png")
    p = pkg.project
    p.main_position = 2   # bottom.png, third.png, then the gel with the lanes
    ops.remove_strip(p, 1)
    assert [s.image for s in p.strips] == ["third.png"] and p.stack_order == [1, None]


def test_the_whole_figure_exports_in_every_format():
    from gelscribe.core.layout import ensure_gui
    ensure_gui()
    pkg = cut_blot()
    w = working(pkg)
    fig = stacked.StackedFigure(pkg.project, w[0], w[1])
    for fmt in ("pdf", "png", "tiff", "svg"):
        assert len(fig.export(fmt)) > 1000
    pkg.project.strict = True
    rgb = io.BytesIO()
    Image.fromarray(np.full((220, 700, 3), 200, np.uint8)).save(rgb, format="PNG")
    pkg.add_strip(rgb.getvalue(), "rgb.png", strict=True)
    w = working(pkg)
    fig = stacked.StackedFigure(pkg.project, w[0], w[1])
    assert fig.strict_problem == "gel 3 is 8-bit RGB, the gel with the lanes 8-bit gray"
    with pytest.raises(ValueError):
        fig.export("png")
