"""Fixes from the audit of the core library and the command line, one focused test each."""
import io
import json
import os
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from gelscribe import cli
from gelscribe.core import ops
from gelscribe.core import strips as stacked
from gelscribe.core.image import ImageError, SourceImage, WorkingImage
from gelscribe.core.model import BandAnnotation, GelProject, GelStrip, Ladder, LadderBand, PixelRect
from gelscribe.core.package import GelPackage, ProjectError
from test_gels import MAIN_LANES, cut_blot, piece_png

PNG = piece_png(620, 160, MAIN_LANES, [60, 110], lambda x, y: 200 + (x * 7 + y * 3) % 40)


def run(capsys, *args):
    code = cli.main([str(a) for a in args])
    out, err = capsys.readouterr()
    return code, out, err


def project(folder) -> GelProject:
    return GelProject.loads((Path(folder) / "project.json").read_text(encoding="utf-8"))


@pytest.fixture
def cut(tmp_path):
    """The two-gel project from test_gels, written to disk: top.png (the lanes) and bottom.png."""
    folder = tmp_path / "cut.gelscribe"
    cut_blot().write(folder)
    return folder


# ---------------------------------------------------------------------------------------------------- image names


def test_image_names_are_unique_ignoring_case_and_clear_of_the_folder():
    pkg = GelPackage.create(PNG, "Blot.png")
    pkg.add_strip(PNG, "blot.png")
    pkg.add_strip(PNG, "BLOT.PNG")
    assert [s.image for s in pkg.project.strips] == ["blot_1.png", "BLOT_2.PNG"]
    k = pkg.add_strip(PNG, "x.png", taken=["X.png"])   # a file already in the folder
    assert pkg.project.strips[k - 1].image == "x_1.png"
    k = pkg.add_strip(PNG, "Project.JSON")
    assert pkg.project.strips[k - 1].image == "gel.png"
    assert GelPackage.create(PNG, "PROJECT.json").project.image == "image.json"


def test_taking_out_a_gel_never_deletes_another_gels_image(tmp_path, capsys):
    (tmp_path / "elsewhere").mkdir()
    main = tmp_path / "Blot.png"
    main.write_bytes(PNG)
    same_scan = tmp_path / "elsewhere" / "blot.png"   # the same scan again, to show another part of it
    same_scan.write_bytes(PNG)
    assert run(capsys, "new", main)[0] == 0
    folder = tmp_path / "Blot.gelscribe"
    assert run(capsys, "edit", folder, "--add-gel", same_scan)[0] == 0
    assert [s.image for s in project(folder).strips] == ["blot_1.png"]
    assert run(capsys, "edit", folder, "--remove-gel", 2)[0] == 0
    assert (folder / "Blot.png").read_bytes() == PNG and not (folder / "blot_1.png").exists()
    assert same_scan.read_bytes() == PNG   # the original outside the project is never touched
    assert run(capsys, "verify", folder)[0] == 0
    # a project from before names were compared ignoring case: two names that differ only in capitals
    pkg = GelPackage.read(folder)
    pkg.project.strips.append(GelStrip("blot.png"))
    pkg.strip_images["blot.png"] = PNG
    with pytest.raises(ProjectError, match="differ only in capital letters"):
        pkg.write(folder)
    assert pkg.remove_strip(1) is None   # nothing to delete: the main image is stored under that name too
    assert "blot.png" not in pkg.strip_images and (folder / "Blot.png").is_file()


def test_a_write_checks_everything_first_and_leaves_no_copies_behind_when_it_fails(tmp_path, monkeypatch):
    pkg = cut_blot()
    pkg.add_strip(pkg.strip_data(1), "c.png")
    folder = tmp_path / "p.gelscribe"
    folder.mkdir()
    (folder / "c.png").write_bytes(b"left over from another gel")
    with pytest.raises(ProjectError, match="different image"):
        pkg.write(folder)
    assert [f.name for f in folder.iterdir()] == ["c.png"]   # top.png and bottom.png weren't copied in first
    (folder / "c.png").unlink()
    folder.rmdir()
    real, calls = os.replace, []

    def flaky(src, dst):   # the disk fails on the second file
        calls.append(dst)
        if len(calls) == 2:
            raise OSError("disk full")
        real(src, dst)

    monkeypatch.setattr(os, "replace", flaky)
    with pytest.raises(OSError):
        pkg.write(folder)
    assert not folder.exists()   # no folder, no half a project
    monkeypatch.undo()
    pkg.write(folder)
    assert sorted(f.name for f in folder.iterdir()) == ["bottom.png", "c.png", "project.json", "top.png"]


def test_new_never_overwrites_anything(tmp_path, capsys):
    img = tmp_path / "gel.png"
    img.write_bytes(PNG)
    assert run(capsys, "new", img)[0] == 0
    before = (tmp_path / "gel.gelscribe" / "project.json").read_bytes()
    code, _, err = run(capsys, "new", img)
    assert code == 1 and "already exists" in err
    (tmp_path / "other").mkdir()
    (tmp_path / "other" / "notes.txt").write_text("mine")
    assert run(capsys, "new", img, "-o", tmp_path / "other")[0] == 1   # a folder with something in it
    assert run(capsys, "new", img, "-o", img)[0] == 1                  # a file
    assert (tmp_path / "gel.gelscribe" / "project.json").read_bytes() == before and img.read_bytes() == PNG
    (tmp_path / "empty").mkdir()
    assert run(capsys, "new", img, "-o", tmp_path / "empty")[0] == 0   # an empty folder is fine to fill


# ---------------------------------------------------------------------------------------------------- damaged files


@pytest.mark.parametrize("text, message", [
    ("[]", "project.json should hold one object"),
    ("not json", "isn't valid JSON"),
    ('{"image": "a.png", "strict": "yes"}', "strict should be true or false"),
    ('{"image": "a.png", "display": 5}', "display should be an object"),
    ('{"image": "a.png", "crop": [1, 2]}', "crop should be four numbers"),
    ('{"image": "a.png", "lanes": {"width": NaN}}', "lanes.width should be a finite number"),
    ('{"image": "a.png", "style": {"gel_width_in": Infinity}}', "style.gel_width_in should be a finite number"),
    ('{"image": "a.png", "ladder": {"bands": [{"size": 5}]}}', "ladder.bands[0].y is missing"),
    ('{"image": "a.png", "strips": [5]}', "strips[0] should be an object"),
    ('{"image": "a.png", "turn": 1.5}', "turn should be a whole number"),
    ('{"image": "a.png", "rows": [{"type": "sideways"}]}', 'rows[0].type should be "lanes" or "groups"'),
    ('{"image": "a.png", "rows": [{"labels": [1]}]}', "rows[0].labels[0] should be text"),
    ('{"image": "../a.png"}', "isn't a plain file name"),
    ('{"image": ""}', "it names no image"),
    ('{"turn": 1}', "it names no image"),
    ('{"image": "a.png", "strips": [{"image": "sub/b.png"}]}', "isn't a plain file name"),
])
def test_a_damaged_project_json_says_what_is_wrong(tmp_path, capsys, text, message):
    folder = tmp_path / "bad.gelscribe"
    folder.mkdir()
    (folder / "a.png").write_bytes(PNG)
    (folder / "project.json").write_text(text, encoding="utf-8")
    for command in ("verify", "render"):
        code, _, err = run(capsys, command, folder)
        assert code == 1 and "Not a GelScribe project" in err and message in err and "Traceback" not in err, err
    with pytest.raises(ProjectError, match="Not a GelScribe project"):
        GelPackage.read(folder / "project.json")


def test_null_counts_as_absent_like_on_the_mac(tmp_path):
    folder = tmp_path / "n.gelscribe"
    folder.mkdir()
    (folder / "a.png").write_bytes(PNG)
    nulls = {"image": "a.png", "display": None, "crop": None, "ladder": None, "style": None, "lanes": None, "rows": None,
             "annotations": None, "strips": None, "title": None, "strict": None, "turn": None}
    (folder / "project.json").write_text(json.dumps(nulls), encoding="utf-8")
    p = GelPackage.read(folder).project
    assert p == GelProject(image="a.png")


def test_absurd_numbers_are_put_right_when_a_project_loads():
    d = {"image": "a.png", "rotate_deg": 1e9, "style": {"gel_width_in": 0, "size": -4, "export_dpi": 1e12},
         "lanes": {"width": -5, "centers": [1e300], "dividers": [{"x_top": 1e30, "x_bottom": 5, "dot_y": 5}]},
         "rows": [{"type": "groups", "groups": [{"text": "x", "lanes": [1, 10 ** 12]}], "rotation": 99999}],
         "strips": [{"image": "b.png", "scale": 40, "shift": -1e12, "display": {"gamma": 0, "white": 1e9}}]}
    p = GelProject.from_json(d)
    assert p.rotate_deg == 360 and p.style.gel_width_in == 0.05 and p.style.size == 1 and p.style.export_dpi is None
    assert p.lanes.width == 100 and p.lanes.centers == [] and p.lanes.dividers == []
    assert p.rows[0].groups[0].lanes == [1, 4096] and p.rows[0].rotation == 279
    s = p.strips[0]
    assert (s.scale, s.shift, s.display.gamma, s.display.white) == (2, -1e6, 0.01, 10)


# ---------------------------------------------------------------------------------------------------- unreadable gels


def test_a_gel_that_cannot_be_read_stops_render_and_verify_and_never_shifts_another(cut, capsys):
    pkg = GelPackage.read(cut)
    pkg.add_strip(pkg.strip_data(1), "third.png")
    pkg.write(cut)
    (cut / "bottom.png").write_bytes(b"not an image any more")   # gel 2 of 3
    for command in ("verify", "render"):
        code, _, err = run(capsys, command, cut)
        assert code == 1 and "Gel 2's image (bottom.png) can't be read." in err, err
    pkg = GelPackage.read(cut)
    with pytest.raises(ImageError, match=r"Gel 2's image \(bottom.png\) can't be read."):
        stacked.strip_images(pkg)
    ws = stacked.strip_images(pkg, tolerant=True)   # index-aligned: the third gel isn't moved into the second's place
    assert ws[0] is None and isinstance(ws[1], WorkingImage)
    main = WorkingImage(SourceImage(pkg.image_data), pkg.project)
    fig = stacked.StackedFigure(pkg.project, main, ws)
    assert fig.unreadable == "Gel 2's image (bottom.png) can't be read."
    assert [q.strip for q in fig.stack.pieces] == [None, 2]
    with pytest.raises(ImageError):
        fig.export("png")
    pkg.project.main_position = 1   # now it's counted from the top of the figure: it sits above the lanes
    assert stacked.StackedFigure(pkg.project, main, ws).unreadable == "Gel 1's image (bottom.png) can't be read."


# ---------------------------------------------------------------------------------------------------- rows


def test_rows_are_clamped_never_empty_and_repaired_on_load():
    p = cut_blot().project
    assert ops.set_strip_rows(p, 1, -5, 1e9, 220) and (p.strips[0].top, p.strips[0].bottom) == (0, 220)
    assert ops.set_strip_rows(p, 1, 20, 100.5, 220) and (p.strips[0].top, p.strips[0].bottom) == (20, 100.5)
    for bad in [(50, 10), (300, 400), (-9, -1), (30, 30), (float("nan"), 5), (1, float("inf"))]:
        assert not ops.set_strip_rows(p, 1, *bad, 220)
        assert (p.strips[0].top, p.strips[0].bottom) == (20, 100.5)   # left as they were
    assert not ops.set_strip_rows(p, 2, 1, 5, 220)
    assert ops.rows_message(220) == "Rows must be top,bottom with top < bottom, inside 0–220."
    # a file with rows that can't be used means the whole gel
    d = p.to_json()
    for top, bottom in [(50, 20), (-3, 40), (7, 7)]:
        d["strips"][0]["top"], d["strips"][0]["bottom"] = top, bottom
        q = GelProject.from_json(d)
        assert (q.strips[0].top, q.strips[0].bottom) == (None, None)
    d["strips"][0]["top"], d["strips"][0]["bottom"] = 5, 9999   # too tall for the gel: known once its size is
    q = GelProject.from_json(d)
    assert q.strips[0].bottom == 9999 and q.strips[0].used_rows(220) == (5, 220)
    q.normalize((620, 160), [(700, 220)])
    assert (q.strips[0].top, q.strips[0].bottom) == (None, None)
    # rows turned into a range never give an empty one
    for top, bottom in [(300, 10), (5000, None), (None, -4), (float("nan"), 3)]:
        s = GelStrip("b.png", top=top, bottom=bottom)
        a, b = s.used_rows(220)
        assert 0 <= a < b <= 220
        p.strips[0] = s
        g = stacked.StackGeometry(p, 620, 160, [(700, 220)])
        assert g.piece(1).bottom > g.piece(1).top


def test_the_command_line_checks_rows_against_the_gel(cut, capsys):
    before = (cut / "project.json").read_bytes()
    code, _, err = run(capsys, "edit", cut, "--gel", 2, "--rows", "50,10")
    assert code == 1 and "Rows must be top,bottom with top < bottom, inside 0–220." in err
    assert (cut / "project.json").read_bytes() == before
    assert run(capsys, "edit", cut, "--gel", 2, "--rows", "10,99999")[0] == 0   # the far end is clamped
    s = project(cut).strips[0]
    assert (s.top, s.bottom) == (10, 220)


# ---------------------------------------------------------------------------------------------------- marks, schemes


def _two_gel_project() -> GelProject:
    p = cut_blot().project
    ops.add_tick(p, 60, 140, lane=1, gel_center_x=310)
    ops.add_tick(p, 110, 80, lane=1, gel_center_x=310)
    ops.add_tick(p, 90, 40, lane=1, gel_center_x=310, strip=1)
    p.annotations += [BandAnnotation(80, "Lanes gel A"), BandAnnotation(90, "Other gel", strip=1),
                      BandAnnotation(100, "Lanes gel B")]
    p.style.text_sizes = {"name.0": 9, "name.1": 10, "name.2": 11, "lane.0.1": 6}
    p.style.export_dpi = 300
    p.ladder.unit_y, p.ladder.unit_strip = 70, 1
    return p


def test_marks_that_name_a_missing_gel_are_dropped_on_load_and_a_reorder_can_not_crash():
    d = _two_gel_project().to_json()
    d["annotations"] += [{"y": 5, "text": "Nowhere", "strip": 3}, {"y": 6, "text": "Zero", "strip": 0}]
    d["ladder"]["bands"] += [{"y": 5, "size": 3, "strip": 4}]
    d["annotations"][0:0] = [{"y": 7, "text": "First, to go", "strip": 9}]   # a dropped name shifts the others up
    d["style"]["text_sizes"] = {"name.1": 9, "name.2": 10, "name.3": 11}
    p = GelProject.from_json(d)
    assert [a.text for a in p.annotations] == ["Lanes gel A", "Other gel", "Lanes gel B"]
    assert p.style.text_sizes == {"name.0": 9, "name.1": 10, "name.2": 11}   # every size stayed with its name
    assert [b.strip for b in p.ladder.bands] == [None, None, 1]
    ops.reorder(p, [1, 0])   # used to raise KeyError for a mark naming a gel that doesn't exist
    assert [a.strip for a in p.annotations] == [None, 1, None]
    # an unsanitized project can't crash it either: such marks are simply dropped
    q = _two_gel_project()
    q.annotations.append(BandAnnotation(5, "Nowhere", strip=7))
    q.ladder.bands.append(LadderBand(5, 3, strip=8))
    ops.reorder(q, [1, 0])
    assert all(a.text != "Nowhere" for a in q.annotations) and all(b.strip in (None, 1) for b in q.ladder.bands)


def test_a_scheme_carries_the_lanes_gels_marks_only_and_never_the_export_resolution():
    from gelscribe.core.scheme import LabelScheme
    p = _two_gel_project()
    s = LabelScheme.of(p, True)
    assert [a.text for a in s.annotations] == ["Lanes gel A", "Lanes gel B"]
    assert [b.strip for b in s.ladder.bands] == [None, None] and s.ladder.unit_y is None and s.ladder.unit_strip is None
    assert s.style.export_dpi is None and s.style.text_sizes == {"name.0": 9, "name.1": 11, "lane.0.1": 6}
    assert p.style.export_dpi == 300 and len(p.annotations) == 3   # the source is untouched
    # pasted text from anywhere (the Mac's too) is cleaned the same way
    text = json.dumps({"rows": [], "style": {"export_dpi": 600, "text_sizes": {"name.1": 12}},
                       "annotations": [{"y": 1, "text": "a"}, {"y": 2, "text": "b", "strip": 2}],
                       "ladder": {"bands": [{"y": 1, "size": 5}, {"y": 2, "size": 4, "strip": 1}], "unit_y": 8, "unit_strip": 1}})
    t = LabelScheme.loads(text)
    assert [a.text for a in t.annotations] == ["a"] and len(t.ladder.bands) == 1
    assert t.style.export_dpi is None and t.style.text_sizes == {} and t.ladder.unit_y is None
    assert "strip" not in t.dumps() and "export_dpi" not in t.dumps()
    # applying it leaves the project's own resolution, and its names and ticks on its other gels, alone
    target = _two_gel_project()
    target.style.export_dpi = 150
    LabelScheme.of(_two_gel_project(), True).apply(target, 620, 160)
    assert target.style.export_dpi == 150
    assert [(a.text, a.strip) for a in target.annotations] == [("Lanes gel A", None), ("Lanes gel B", None), ("Other gel", 1)]
    assert target.style.text_sizes == {"name.0": 9, "name.1": 11, "name.2": 10, "lane.0.1": 6}
    assert sorted((b.strip is not None, b.size) for b in target.ladder.bands) == [(False, 80), (False, 140), (True, 40)]
    assert (target.ladder.unit_y, target.ladder.unit_strip) == (70, 1)


# ---------------------------------------------------------------------------------------------------- hidden ticks


def test_assigning_suggesting_and_warning_leave_out_the_ticks_a_crop_hides():
    p = cut_blot().project
    p.ladder = Ladder(sizes=[140, 80, 40, 30])
    for y in (20, 50, 100, 140):
        ops.add_tick(p, y, None, lane=1, gel_center_x=310)
    p.ladder.bands[0].size = 999   # a tick above the crop, with a size of its own
    p.crop = PixelRect(0, 40, 620, 120)
    assert not p.is_in_figure(None, 20) and p.is_in_figure(None, 50) and not p.is_in_figure(None, 140)
    p.assign_ladder(p.ladder.sizes)
    assert [b.size for b in p.ladder.bands] == [999, 140, 80, None]   # 20 keeps its size; 140 is hidden and gets none
    assert p.ladder_warnings == []                                    # 999 above 140 isn't counted
    assert ops.suggested_size(p, 110, None) == 40                      # ranks only the visible ticks above it
    p.ladder.bands[3].size = 140
    assert p.ladder_warnings == []
    p.crop = None
    assert "The same size is on more than one tick." in p.ladder_warnings
    # the rows of a stacked gel work the same way
    q = cut_blot().project
    q.ladder = Ladder(sizes=[50, 40, 30])
    q.strips[0].top, q.strips[0].bottom = 30, 100
    for y in (10, 60, 90, 150):
        ops.add_tick(q, y, None, lane=1, gel_center_x=310, strip=1)
    q.assign_ladder(q.ladder.sizes)
    assert [b.size for b in q.ladder.bands] == [None, 50, 40, None]
    assert not q.is_in_figure(1, 29) and q.is_in_figure(1, 29.5) and q.is_in_figure(1, 100.5) and not q.is_in_figure(1, 101)
    assert not q.is_in_figure(2, 60) and not q.is_in_figure(None, float("nan"))


def test_per_name_sizes_follow_their_names_when_names_go():
    def names():
        p = cut_blot().project
        p.annotations = [BandAnnotation(10, "a"), BandAnnotation(20, "b", strip=1), BandAnnotation(30, "c"),
                         BandAnnotation(40, "d", strip=1)]
        p.style.text_sizes = {"name.0": 6, "name.1": 7, "name.2": 8, "name.3": 9}
        return p
    p = names()
    ops.remove_strip(p, 1)
    assert [a.text for a in p.annotations] == ["a", "c"] and p.style.text_sizes == {"name.0": 6, "name.1": 8}
    p = names()
    ops.turn(p, 1, 1, 700, 220)   # a quarter turn clears that gel's names
    assert [a.text for a in p.annotations] == ["a", "c"] and p.style.text_sizes == {"name.0": 6, "name.1": 8}
    p = names()
    ops.delete_annotation(p, 0)
    assert [a.text for a in p.annotations] == ["b", "c", "d"] and p.style.text_sizes == {"name.0": 7, "name.1": 8, "name.2": 9}
    ops.delete_annotation(p, 7)   # no such name
    assert len(p.annotations) == 3
    assert ops.remove_annotations(p, lambda a: a.text in "bd") == 2 and p.style.text_sizes == {"name.0": 8}


# ---------------------------------------------------------------------------------------------------- auto-align


DOCS = Path(__file__).resolve().parents[2] / "docs"
needs_docs = pytest.mark.skipif(not (DOCS / "top-piece.png").exists(), reason="needs docs/top-piece.png and bottom-piece.png")


def _gray(a) -> WorkingImage:
    buf = io.BytesIO()
    Image.fromarray(np.clip(np.floor(a + 0.5), 0, 255).astype(np.uint8)).save(buf, format="PNG")
    return WorkingImage(SourceImage(buf.getvalue()), GelProject())


def test_auto_align_refuses_gels_with_no_lanes_and_lanes_that_do_not_fit():
    centers = [float(c) for c in MAIN_LANES]
    real = WorkingImage(SourceImage(piece_png(700, 220, [c + 37 for c in MAIN_LANES], [90])), GelProject())
    r = stacked.find_alignment(centers, real, True)
    assert r.alignment is not None and abs(r.alignment.shift - 37) < 3 and r.problem is None and r.message(2, True) is None
    rng = np.random.default_rng(7)
    for name, g in [("blank", np.full((220, 700), 200.0)), ("flat with noise", 200 + rng.normal(0, 3, (220, 700))),
                    ("noise", rng.integers(0, 256, (220, 700)).astype(float)),
                    ("more noise", rng.integers(0, 256, (160, 620)).astype(float)),
                    ("gradient", np.tile(np.linspace(60, 200, 700), (220, 1)))]:
        for scale in (True, False):
            r = stacked.find_alignment(centers, _gray(g), True, allow_scale=scale)
            assert r.alignment is None and r.problem == stacked.NO_LANES, (name, scale)
            assert stacked.suggest_alignment(centers, _gray(g), True) is None
    # real lanes, but one of them nowhere near where the lanes gel has it
    odd = list(centers)
    odd[3] += 55
    r = stacked.find_alignment(odd, real, True)
    assert r.alignment is None and r.problem == stacked.MISFIT
    assert r.message(2, False) == "Gel 2's lanes don't line up with the lanes gel's. Line it up by hand."
    assert r.message(2, True) == ("Gel 2's lanes don't line up with the lanes gel's. "
                                  "Line it up by hand or turn off Keep original pixels for Gel 2 to let it stretch.")
    assert stacked.AlignResult(None, stacked.NO_LANES).message(3, False) == "Couldn't find Gel 3's lanes. Line it up by hand."
    assert stacked.find_alignment(centers[:1], real, True).problem == stacked.NO_LANES


@needs_docs
def test_the_tutorials_pieces_still_line_up(tmp_path, capsys):
    folder = tmp_path / "Cut blot.gelscribe"
    assert run(capsys, "new", DOCS / "top-piece.png", "-o", folder)[0] == 0
    assert run(capsys, "edit", folder, "--strict", "off", "--rotate", -1.3, "--auto-lanes", 13, "--crop", "119,66,1140,296",
               "--no-snap", "--ticks", "92,128,196,222,284")[0] == 0
    code, _, err = run(capsys, "edit", folder, "--add-gel", DOCS / "bottom-piece.png", "--gel", 2, "--rows", "35,337",
                       "--align", "auto")
    assert code == 0 and "gel 2: shift -54.83 px, scale 1.025; the worst lane is 4.2 px off" in err   # as in the tutorial
    p = project(folder)
    pkg = GelPackage.read(folder)
    gel = WorkingImage(SourceImage(pkg.strip_data(1)), p.strip_project(1))
    whole = stacked.find_alignment(p.lanes.centers, gel, True)   # Auto-align before any rows are chosen
    assert whole.alignment is not None and abs(whole.alignment.scale - 1.025) < 0.005 and whole.alignment.worst < 7
    top = WorkingImage(SourceImage(pkg.image_data), p)
    assert stacked.find_alignment(p.lanes.centers, top, True).alignment is not None   # and the top piece with itself
    # the same gel with its lanes wiped out is refused, in Strict too
    flat = _gray(np.full((gel.height, gel.width), 230.0))
    for strict in (False, True):
        r = stacked.find_alignment(p.lanes.centers, flat, True, allow_scale=not strict)
        assert r.alignment is None and r.problem == stacked.NO_LANES
    code, _, err = run(capsys, "edit", folder, "--gel", 2, "--align", "auto")
    assert code == 0   # still fine through the command line


def test_the_command_line_will_not_line_up_a_gel_without_lanes(cut, capsys, tmp_path):
    pkg = GelPackage.read(cut)
    blank = tmp_path / "blank.png"
    buf = io.BytesIO()
    Image.fromarray(np.full((200, 700), 220, np.uint8)).save(buf, format="PNG")
    blank.write_bytes(buf.getvalue())
    before = (cut / "project.json").read_bytes()
    code, _, err = run(capsys, "edit", cut, "--add-gel", blank, "--gel", 3, "--align", "auto")
    assert code == 1 and "Couldn't find Gel 3's lanes. Line it up by hand." in err and (cut / "project.json").read_bytes() == before
    assert not (cut / "blank.png").exists()   # nothing was copied in either
    assert pkg.project.lane_count == 8


# ---------------------------------------------------------------------------------------------------- the command line


def test_command_line_values_are_checked_and_a_mistake_changes_nothing(cut, capsys):
    before = (cut / "project.json").read_bytes()
    for args, message in [(["--strict", "maybe"], "--strict wants on or off"),
                          (["--strict", "ON", "--rotate", "nan"], "--rotate wants degrees"),
                          (["--rotate", "inf", "--strict", "off"], "--rotate wants degrees"),
                          (["--strict", "off", "--rotate", "400"], "--rotate wants degrees between -360 and 360"),
                          (["--gel", 2, "--scale", "0"], "--scale wants a number from 0.5 to 2"),
                          (["--gel", 2, "--scale", "-1"], "--scale wants a number from 0.5 to 2"),
                          (["--gel", 2, "--shift", "inf"], "--shift wants pixels"),
                          (["--gel", 2, "--rows", "1,nan"], "--rows wants Y0,Y1"),
                          (["--gel", 2, "--rows", "1,2,3"], "--rows wants Y0,Y1"),
                          (["--gel", 0, "--shift", "1"], "--gel wants a gel number"),
                          (["--gel", 9, "--shift", "1"], "there's no gel 9"),
                          (["--remove-gel", 0], "--remove-gel wants a gel number"),
                          (["--auto-lanes", "0"], "--auto-lanes wants 2 to"),
                          (["--auto-lanes", "two"], "--auto-lanes wants the number of lanes"),
                          (["--ticks", "10,nan"], "--ticks wants rows like 60,110,170"),
                          (["--ticks", "9999"], "--ticks: 9999 is outside gel 1 (rows 0–160)"),
                          (["--ticks", "-3"], "--ticks: -3 is outside gel 1"),
                          (["--gel", 2, "--ticks", "300"], "--ticks: 300 is outside gel 2 (rows 0–220)"),
                          (["--name", "X@900"], "--name: 900 is outside gel 1"),
                          (["--dividers", "5,nan"], "--dividers wants X,X"),
                          (["--dividers", "5,99999"], "--dividers wants positions inside the image (0–620)"),
                          (["--crop", "1,2,3,nan"], "--crop wants X0,Y0,X1,Y1 or fit"),
                          (["--crop", "700,10,800,20"], "--crop is outside the 620×160 image"),
                          (["--turn", "45"], "--turn wants 90, 180 or 270"),
                          (["--turn", "-90"], "--turn wants 90, 180 or 270"),
                          (["--fill", "300"], "--fill wants"),
                          (["--own-ladder", "yes"], "--own-ladder wants on or off"),
                          (["--align", "manual"], "--align wants auto"),
                          (["--order", "1,x"], "--order wants gel numbers"),
                          (["--frobnicate", "1"], "unknown option --frobnicate"),
                          (["--title", "A", "--title", "B"], "--title was given twice"),
                          ]:
        code, out, err = run(capsys, "edit", cut, *args)
        assert code in (1, 2) and message in err and out == "" and "Traceback" not in err, (args, err)
        assert (cut / "project.json").read_bytes() == before, args
    assert run(capsys, "render", cut, "--dpi", "0")[0] == 1
    assert run(capsys, "render", cut, "--dpi", "inf")[0] == 1
    assert run(capsys, "render", cut, "--dpi", "1e9")[0] == 1
    assert run(capsys, "detect", cut / "top.png", "--lanes", "1")[0] == 1
    assert not list(cut.parent.glob("*.figure.*"))


def test_option_order_does_not_matter_and_strict_takes_either_case(cut, capsys, tmp_path):
    other = tmp_path / "other.gelscribe"
    import shutil
    shutil.copytree(cut, other)
    assert run(capsys, "edit", cut, "--strict", "OFF", "--gel", 2, "--scale", "1.02")[0] == 0
    assert run(capsys, "edit", other, "--scale", "1.02", "--gel", 2, "--strict", "off")[0] == 0
    a, b = project(cut), project(other)
    assert a.strict and a.strips[0].strict is False and a.strips[0].scale == 1.02 and a == b   # with --gel: that gel's own
    code, _, err = run(capsys, "edit", cut, "--strict", "On", "--gel", 2, "--scale", "1.03")   # Strict is turned on in this
    assert code == 1 and "--scale needs --strict off" in err                                     # command: the order doesn't help
    assert run(capsys, "edit", cut, "--rotate", 2, "--strict", "off")[0] == 0
    assert project(cut).rotate_deg == 2


def test_gels_can_only_be_added_to_a_gelscribe_project_in_any_letter_case(tmp_path, capsys):
    (tmp_path / "cfg").mkdir()
    (tmp_path / "cfg" / "blot.png").write_bytes(PNG)
    config = tmp_path / "cfg" / "config.json"
    config.write_text(GelProject(image="blot.png", title="Config").dumps(), encoding="utf-8")
    second = tmp_path / "second.png"
    second.write_bytes(PNG)
    before = config.read_bytes()
    code, _, err = run(capsys, "edit", config, "--add-gel", second)
    assert code == 1 and "Gels can only be added to a .gelscribe project." in err
    assert config.read_bytes() == before and sorted(f.name for f in config.parent.iterdir()) == ["blot.png", "config.json"]
    plain = tmp_path / "plain"   # a project.json outside a .gelscribe folder is a plain config too
    plain.mkdir()
    (plain / "blot.png").write_bytes(PNG)
    (plain / "project.json").write_text(GelProject(image="blot.png").dumps(), encoding="utf-8")
    assert run(capsys, "edit", plain / "project.json", "--add-gel", second)[0] == 1
    assert run(capsys, "edit", config, "--title", "Edited")[0] == 0   # everything else still works on a config
    assert json.loads(config.read_text())["title"] == "Edited"
    # a .gelscribe project in any letter case takes gels, named by its folder or its project.json
    folder = tmp_path / "Mine.GELSCRIBE"
    assert run(capsys, "new", second, "-o", folder)[0] == 0
    third = tmp_path / "third.png"
    third.write_bytes(PNG)
    assert run(capsys, "edit", folder, "--add-gel", third)[0] == 0
    assert run(capsys, "edit", folder / "project.json", "--add-gel", third)[0] == 0
    assert [s.image for s in project(folder).strips] == ["third.png", "third_1.png"]
    assert run(capsys, "verify", folder)[0] == 0


def test_taking_a_gel_out_of_a_plain_config_deletes_nothing(tmp_path, capsys):
    pkg = cut_blot()
    plain = tmp_path / "plain"   # a project.json of its own, with the user's own images beside it
    pkg.write(plain)
    assert run(capsys, "edit", plain / "project.json", "--remove-gel", 2)[0] == 0
    assert project(plain).strips == [] and (plain / "bottom.png").is_file()   # the file stays: it isn't a GelScribe copy
    folder = tmp_path / "cut.gelscribe"
    pkg.write(folder)
    assert run(capsys, "edit", folder / "project.json", "--remove-gel", 2)[0] == 0
    assert not (folder / "bottom.png").exists() and (folder / "top.png").is_file()   # a .gelscribe project's copy goes


def test_every_format_is_checked_before_anything_is_written(cut, capsys):
    code, _, err = run(capsys, "render", cut, "--formats", "pdf,png,docx")
    assert code == 1 and "unknown format docx" in err and not list(cut.parent.glob("*.figure.*"))


# ---------------------------------------------------------------------------------------------------- own ladder


def _three_gels() -> GelProject:
    """The gel with the lanes on top, then bottom.png and third.png, each with two ticks and the same size list."""
    pkg = cut_blot()
    pkg.add_strip(pkg.strip_data(1), "third.png")
    p = pkg.project
    p.ladder = Ladder(sizes=[140, 80, 50, 40, 30, 20, 15, 10])
    for strip, ys in ((None, (50, 100)), (1, (50, 100)), (2, (50, 100))):
        for y in ys:
            ops.add_tick(p, y, None, lane=1, gel_center_x=310, strip=strip)
    return p


def _sizes(p: GelProject):
    return [(p.position_of(b.strip), b.size) for b in p.ladder.bands]


def test_each_gel_continues_the_ladder_or_has_its_own():
    p = _three_gels()
    p.assign_ladder(p.ladder.sizes)
    assert [s for _, s in _sizes(p)] == [140, 80, 50, 40, 30, 20]   # the default: sizes run on down the stack
    assert p.ladder_groups == [[None, 1, 2]] and p.ladder_warnings == []
    assert ops.suggested_size(p, 120, None, strip=2) == 15          # the next tick on the last gel
    ops.set_own_ladder(p, 2, True)                                  # starts again from the top, and assigns again
    assert p.strips[1].own_ladder and p.ladder_groups == [[None, 1], [2]]
    assert [s for _, s in _sizes(p)] == [140, 80, 50, 40, 140, 80]
    assert ops.suggested_size(p, 120, None, strip=2) == 50 and ops.suggested_size(p, 120, None, strip=1) == 30
    assert p.ladder_group_of(1) == 0 and p.ladder_group_of(2) == 1
    p.ladder.bands[0].size = 20   # 20 above 80 in the first group is a warning
    assert p.ladder_warnings == ["80 sits below 20. Sizes should shrink down the lane."]
    p.ladder.bands[0].size = 140
    assert p.ladder_warnings == []   # 140 on both groups isn't a repeat: they're different ladders
    p.ladder.bands[2].size = 140
    assert p.ladder_warnings == ["140 sits below 80. Sizes should shrink down the lane.", "The same size is on more than one tick."]
    ops.set_own_ladder(p, 2, False)
    assert not p.strips[1].own_ladder and [s for _, s in _sizes(p)] == [140, 80, 50, 40, 30, 20]
    # the gel with the lanes can have one too, wherever it sits; the top gel always starts the first group
    p.main_position = 1   # bottom.png, the lanes gel, third.png
    ops.set_own_ladder(p, None, True)
    assert p.own_ladder and p.ladder_groups == [[1], [None, 2]]
    top_first = p.copy()
    ops.set_own_ladder(top_first, 1, True)   # on the top gel it changes nothing
    assert top_first.ladder_groups == [[1], [None, 2]]
    assert ops.suggested_size(p, 1, None, strip=None) == 140


def test_setting_it_again_or_with_no_ladder_chosen_assigns_nothing():
    p = _three_gels()
    p.ladder.bands[1].size, p.ladder.bands[1].auto = 77, False   # one the user confirmed
    ops.set_own_ladder(p, 2, False)   # already off: nothing changes, nothing is overwritten
    assert p.ladder.bands[1].size == 77
    p.ladder.sizes = None             # no ladder chosen: the flag is set, the sizes are left alone
    ops.set_own_ladder(p, 1, True)
    assert p.strips[0].own_ladder and p.ladder.bands[1].size == 77 and p.ladder.bands[2].size is None
    ops.set_own_ladder(p, 9, True)    # no such gel
    assert [s.own_ladder for s in p.strips] == [True, False]


def test_own_ladder_is_in_the_json_only_when_set_and_goes_with_its_gel():
    p = _three_gels()
    d = p.to_json()
    assert "own_ladder" not in d and all("own_ladder" not in s for s in d["strips"])
    ops.set_own_ladder(p, 1, True)
    ops.set_own_ladder(p, None, True)
    d = json.loads(p.dumps())
    assert d["own_ladder"] is True and d["strips"][0]["own_ladder"] is True and "own_ladder" not in d["strips"][1]
    assert GelProject.loads(p.dumps()) == p
    assert GelProject.from_json({"image": "a.png", "own_ladder": None}).own_ladder is False   # like absent
    ops.move_gel(p, 1, 2)   # bottom.png (with its own ladder) from the middle to the bottom
    assert [(s.image, s.own_ladder) for s in p.strips] == [("third.png", False), ("bottom.png", True)] and p.own_ladder
    assert p.ladder_groups == [[None, 1], [2]]
    ops.remove_strip(p, 2)   # takes the flag away with the gel
    assert [(s.image, s.own_ladder) for s in p.strips] == [("third.png", False)]
    ops.reorder(p, [1, 0])   # the lanes gel keeps its own, wherever it goes
    assert p.own_ladder and p.stack_order == [1, None]


def test_the_command_line_sets_the_own_ladder_of_a_gel(cut, capsys):
    assert run(capsys, "edit", cut, "--ticks", "60,110", "--preset", "thermo-pageruler-prestained", "--system",
               "bt-4-12-mes")[0] == 0
    assert run(capsys, "edit", cut, "--gel", 2, "--ticks", 90, "--no-snap")[0] == 0
    assert [b.size for b in project(cut).ladder.bands] == [140, 115, 80]
    assert run(capsys, "edit", cut, "--gel", 2, "--own-ladder", "ON")[0] == 0
    p = project(cut)
    assert p.strips[0].own_ladder and not p.own_ladder and [b.size for b in p.ladder.bands] == [140, 115, 140]
    assert json.loads((cut / "project.json").read_text())["strips"][0]["own_ladder"] is True
    assert run(capsys, "edit", cut, "--gel", 2, "--ticks", 120, "--no-snap")[0] == 0   # the next tick restarts the count too
    assert [b.size for b in project(cut).ladder.bands] == [140, 115, 140, 115]
    assert run(capsys, "edit", cut, "--gel", 2, "--own-ladder", "off")[0] == 0
    assert [b.size for b in project(cut).ladder.bands] == [140, 115, 80, 70]
    assert run(capsys, "edit", cut, "--order", "2,1", "--own-ladder", "on")[0] == 0   # without --gel: the gel with the lanes
    p = project(cut)
    assert p.own_ladder and p.main_position == 1 and not p.strips[0].own_ladder
    code, out, _ = run(capsys, "help")
    assert "--own-ladder on|off" in out   # listed in the usage text


# ---------------------------------------------------------------------------------------------------- pixel formats


FLOAT_MESSAGE = ("This image has 32-bit floating-point values, which GelScribe doesn't support. Export it from your "
                 "scanner's software as a 16-bit TIFF and open that.")


def _tiff(array, **kw) -> bytes:
    import tifffile
    buf = io.BytesIO()
    tifffile.imwrite(buf, array, photometric="minisblack" if array.ndim == 2 else "rgb", **kw)
    return buf.getvalue()


def test_floating_point_images_are_refused_when_opened_or_added(tmp_path, capsys):
    values = np.linspace(500, 3000, 60 * 40, dtype=np.float32).reshape(40, 60)
    data = _tiff(values, description="ImageJ=1.54p\nmin=0.0\nmax=4000.0\n")
    with pytest.raises(ImageError) as e:
        SourceImage(data)
    assert str(e.value) == FLOAT_MESSAGE
    with pytest.raises(ImageError, match="64-bit floating-point"):
        SourceImage(_tiff(values.astype(np.float64)))
    with pytest.raises(ImageError, match="32-bit floating-point"):
        GelPackage.create(data, "f.tif")
    pkg = cut_blot()
    with pytest.raises(ImageError, match="32-bit floating-point"):
        pkg.add_strip(data, "f.tif")
    assert len(pkg.project.strips) == 1   # nothing was added
    assert SourceImage(_tiff(values.astype(np.uint16))).bits == 16   # integers of the same values are fine
    f = tmp_path / "f.tif"
    f.write_bytes(data)
    code, _, err = run(capsys, "new", f)
    assert code == 1 and FLOAT_MESSAGE in err and not (tmp_path / "f.gelscribe").exists()
    folder = tmp_path / "cut.gelscribe"
    cut_blot().write(folder)
    before = (folder / "project.json").read_bytes()
    code, _, err = run(capsys, "edit", folder, "--add-gel", f)
    assert code == 1 and FLOAT_MESSAGE in err and (folder / "project.json").read_bytes() == before
    assert sorted(x.name for x in folder.iterdir()) == ["bottom.png", "project.json", "top.png"]
    assert run(capsys, "detect", f)[0] == 1


def _raw_png16(arr: np.ndarray, color_type: int) -> bytes:
    """A 16-bit PNG written by hand (Pillow can't write the colour kinds at 16 bits)."""
    import struct
    import zlib
    h, w = arr.shape[:2]
    raw = arr.astype(">u2").reshape(h, -1).tobytes()
    stride = len(raw) // h
    scan = b"".join(b"\x00" + raw[i * stride:(i + 1) * stride] for i in range(h))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 16, color_type, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(scan)) + chunk(b"IEND", b""))


def test_sixteen_bit_colour_pngs_are_read_at_full_depth():
    from gelscribe.core import render
    from gelscribe.core.layout import layout
    rng = np.random.default_rng(5)
    rgb = rng.integers(0, 65536, (40, 60, 3), dtype=np.uint16)
    png = render.encode_png(rgb, 300)   # our own writer's 16-bit RGB
    assert Image.open(io.BytesIO(png)).mode == "RGB"   # Pillow alone would reduce it to 8 bits
    src = SourceImage(png)
    assert src.pixels.dtype == np.uint16 and src.bits == 16 and src.channels == 3
    assert np.array_equal(src.pixels, rgb)   # every value exact
    rgba = rng.integers(0, 65536, (40, 60, 4), dtype=np.uint16)
    assert np.array_equal(SourceImage(_raw_png16(rgba, 6)).pixels, rgba[..., :3])          # the alpha is dropped
    ga = rng.integers(0, 65536, (40, 60, 2), dtype=np.uint16)
    s = SourceImage(_raw_png16(ga, 4))
    assert s.pixels.shape == (40, 60) and s.pixels.dtype == np.uint16 and np.array_equal(s.pixels, ga[..., 0])
    gray = rng.integers(0, 65536, (40, 60), dtype=np.uint16)
    assert np.array_equal(SourceImage(_raw_png16(gray, 0)).pixels, gray)
    # Strict carries those values through to the figure
    p = GelProject(image="c.png")
    w = WorkingImage(src, p)
    assert np.array_equal(w.figure_image(p), rgb)
    lay = layout(p, w.width, w.height)
    out = render.raster(lay, w.figure_image(p))
    k = 1 / lay.pt_per_px
    gx, gy = round(lay.gel_rect.x * k), round(lay.gel_rect.y * k)
    assert out.dtype == np.uint16 and np.array_equal(out[gy:gy + 40, gx:gx + 60], rgb)
    # the 8-bit kinds are unchanged
    buf = io.BytesIO()
    Image.fromarray(rng.integers(0, 256, (10, 12, 4), dtype=np.uint8)).save(buf, format="PNG")
    assert SourceImage(buf.getvalue()).pixels.dtype == np.uint8


def test_strict_stacking_needs_the_same_color_profile():
    profile = b"a color profile" * 20

    def png(icc):
        buf = io.BytesIO()
        Image.fromarray(np.full((20, 30, 3), 200, np.uint8)).save(buf, format="PNG", **({"icc_profile": icc} if icc else {}))
        return buf.getvalue()
    a, same, other, none = (SourceImage(png(x)) for x in (profile, profile, profile + b"x", None))
    assert a.icc_profile == profile and none.icc_profile is None
    assert stacked.strict_problem_for(a, [same], lambda k: f"Gel {k + 1}") is None
    assert stacked.strict_problem_for(none, [none], lambda k: f"Gel {k + 1}") is None
    assert stacked.strict_problem_for(a, [same, other], lambda k: f"Gel {k + 1}") == \
        "Gel 3 has a different color profile from the gel with the lanes"
    assert stacked.strict_problem_for(a, [None, none], lambda k: f"Gel {k + 1}") == \
        "Gel 3 has a different color profile from the gel with the lanes"   # one that couldn't be read is skipped
    assert stacked.strict_mismatch(a.pixels, other.pixels, a.icc_profile, other.icc_profile) == \
        "has a different color profile from the gel with the lanes"
    assert stacked.strict_mismatch(a.pixels, other.pixels) is None   # the pixel formats alone match
    # the whole figure says so, and Strict off still stacks them
    pkg = GelPackage.create(png(profile), "main.png")
    pkg.add_strip(png(profile + b"x"), "second.png", strict=None)   # follows the lanes gel
    main = WorkingImage(SourceImage(pkg.image_data), pkg.project)
    fig = stacked.StackedFigure(pkg.project, main, stacked.strip_images(pkg))
    assert fig.strict_problem == "gel 2 has a different color profile from the gel with the lanes"
    with pytest.raises(ValueError, match="different color profile"):
        fig.export("png")
    assert stacked.figure_image(main, fig.strips, pkg.project, fig.stack) is None
    pkg.project.strict = False
    assert stacked.StackedFigure(pkg.project, main, stacked.strip_images(pkg)).strict_problem is None
    # TIFF files carry the profile in a tag
    t = SourceImage(_tiff(np.zeros((20, 30), np.uint16), extratags=[(34675, 7, len(profile), profile, True)]))
    assert t.icc_profile == profile


# ---------------------------------------------------------------------------------------------------- provenance


def test_the_provenance_note_gives_the_crop_and_rows_actually_used_and_each_gels_gamma_and_invert():
    from gelscribe.core import render
    pkg = cut_blot()
    p = pkg.project
    p.crop = PixelRect(10.2, 5.7, 5000, 5000)   # more than the 620×160 image has
    p.strips[0].top, p.strips[0].bottom = 10.6, 5000   # and more than the 220 rows of the gel
    p.strict = False
    main = WorkingImage(SourceImage(pkg.image_data), p)
    fig = stacked.StackedFigure(p, main, stacked.strip_images(pkg))
    note = fig.info().description
    assert "crop 10,5,620,160" in note and "5000" not in note and "2. bottom.png" in note and "rows 11–220" in note
    # what the figure holds is what the note says
    assert fig.stack.piece(1).source_top == 11 and fig.stack.piece(1).source_bottom == 220
    assert fig.stack.crop.width == 610
    p.strips[0].top = p.strips[0].bottom = None
    assert "rows 0–220" in stacked.StackedFigure(p, main, stacked.strip_images(pkg)).info().description
    # Strict off: the gel's gamma and invert were applied, so they are recorded when they aren't the defaults
    assert "gamma" not in note.split("2. bottom.png")[1] and "inverted" not in note
    p.strips[0].display.gamma, p.strips[0].display.invert = 1.25, True
    note = stacked.StackedFigure(p, main, stacked.strip_images(pkg)).info().description
    assert "2. bottom.png" in note and "gamma 1.25, inverted" in note.split("2. bottom.png")[1]
    p.strict = True   # they change nothing while the gel keeps its original pixels, so they aren't mentioned
    p.strips[0].strict = None   # (it follows the gel with the lanes)
    note = stacked.StackedFigure(p, main, stacked.strip_images(pkg)).info().description
    assert "gamma 1.25" not in note and "inverted" not in note
    # the old call, without sizes, still works and gives the values as stored
    d = render.export_info(p, "aaa", strips=[("bbb", None)]).description
    assert "crop 10,5,5000,5000" in d and "rows 0–end" in d


# ---------------------------------------------------------------------------------------------------- the unit label


def _unit_project() -> GelProject:
    pkg = cut_blot()
    pkg.add_strip(pkg.strip_data(1), "third.png")
    p = pkg.project
    p.ladder = Ladder(sizes=[140, 80, 50])
    for strip, y in ((None, 60), (1, 50), (2, 70)):
        ops.add_tick(p, y, None, lane=1, gel_center_x=310, strip=strip)
    p.assign_ladder(p.ladder.sizes)
    p.ladder.unit_y, p.ladder.unit_strip = 100, 1   # on the second gel's row 100
    return p


def test_the_unit_label_belongs_to_a_gel_and_goes_with_it():
    from gelscribe.core.layout import layout
    p = _unit_project()
    d = json.loads(p.dumps())["ladder"]
    assert d["unit_y"] == 100 and d["unit_strip"] == 1
    q = GelProject.loads(p.dumps())
    assert (q.ladder.unit_y, q.ladder.unit_strip) == (100, 1)
    on_main = _unit_project()
    on_main.ladder.unit_strip = None
    assert "unit_strip" not in json.loads(on_main.dumps())["ladder"]   # omitted for the gel with the lanes
    # it follows its gel when the gels change places, and goes when the gel does
    ops.move_gel(p, 1, 2)   # bottom.png (strip 1) becomes strip 2
    assert (p.ladder.unit_y, p.ladder.unit_strip) == (100, 2) and p.strips[1].image == "bottom.png"
    ops.turn(p, 2, 2, 700, 220)   # a half turn carries it across
    assert (p.ladder.unit_y, p.ladder.unit_strip) == (220 - 1 - 100, 2)
    ops.turn(p, 1, 1, 700, 220)   # a quarter turn of another gel leaves it alone
    assert p.ladder.unit_y == 119
    ops.turn(p, 2, 1, 700, 220)   # a quarter turn of its own gel clears the placement
    assert (p.ladder.unit_y, p.ladder.unit_strip) == (None, None)
    r = _unit_project()
    ops.remove_strip(r, 2)        # another gel going renumbers it
    assert (r.ladder.unit_y, r.ladder.unit_strip) == (100, 1)
    ops.remove_strip(r, 1)        # its own gel going clears it: automatic placement again
    assert (r.ladder.unit_y, r.ladder.unit_strip) == (None, None) and "unit_y" not in json.loads(r.dumps())["ladder"]
    # a unit label on the gel with the lanes isn't touched by what happens to the others
    s = _unit_project()
    s.ladder.unit_y, s.ladder.unit_strip = 40, None
    ops.remove_strip(s, 1)
    ops.turn(s, 1, 1, 700, 220)
    assert (s.ladder.unit_y, s.ladder.unit_strip) == (40, None)
    ops.turn(s, None, 2, 620, 160)
    assert s.ladder.unit_y == 160 - 1 - 40
    # a file naming a gel that isn't there loses the placement
    bad = json.loads(_unit_project().dumps())
    bad["ladder"]["unit_strip"] = 7
    assert GelProject.from_json(bad).ladder.unit_y is None
    # the figure puts the label on that gel's row
    u = _unit_project()
    pkg = cut_blot()
    pkg.add_strip(pkg.strip_data(1), "third.png")
    main = WorkingImage(SourceImage(pkg.image_data), u)
    fig = stacked.StackedFigure(u, main, stacked.strip_images(pkg))
    unit = next(t for t in fig.layout.texts if t.string == "kDa")
    piece = fig.stack.piece(1)
    want = fig.layout.point(0, piece.top + 100 - piece.source_top)[1]
    assert abs(unit.bounds.mid_y - want) < 2
    u.ladder.unit_strip = None   # on the gel with the lanes, row 100 is somewhere else
    other = next(t for t in layout(u, 620, 160, fig.stack).texts if t.string == "kDa")
    assert abs(other.bounds.mid_y - fig.layout.point(0, 100)[1]) < 2 and abs(other.bounds.mid_y - unit.bounds.mid_y) > 20
    u.ladder.unit_y = 100000   # outside every gel's rows: heads the column, as when it isn't placed
    far = next(t for t in layout(u, 620, 160, fig.stack).texts if t.string == "kDa")
    assert far.bounds.max_y < fig.layout.gel_rect.min_y


def test_copying_a_scheme_from_a_project_with_gels_cannot_break_a_later_reorder(tmp_path, capsys):
    pkg = cut_blot()   # three gels, a name on the third and a tick on the second
    pkg.add_strip(pkg.strip_data(1), "third.png")
    p = pkg.project
    p.annotations = [BandAnnotation(50, "Lanes gel name"), BandAnnotation(60, "On the third gel", strip=2)]
    p.style.export_dpi = 300
    ops.add_tick(p, 30, 40, lane=1, gel_center_x=310, strip=2)
    source = tmp_path / "source.gelscribe"
    pkg.write(source)
    target = tmp_path / "target.gelscribe"
    (tmp_path / "t.png").write_bytes(PNG)
    (tmp_path / "x.png").write_bytes(PNG)
    assert run(capsys, "new", tmp_path / "t.png", "-o", target)[0] == 0
    code, _, err = run(capsys, "edit", target, "--scheme-from", source, "--with-positions", "--add-gel", tmp_path / "x.png",
                       "--order", "2,1")   # used to end in KeyError: 2
    assert code == 0 and "Traceback" not in err, err
    q = project(target)
    assert [(a.text, a.strip) for a in q.annotations] == [("Lanes gel name", None)]
    assert all(b.strip is None for b in (q.ladder.bands if q.ladder else []))
    assert q.style.export_dpi is None   # the source's resolution didn't come along


def test_a_stale_file_in_the_folder_does_not_stop_a_gel_being_added(cut, tmp_path, capsys):
    (cut / "b.png").write_bytes(b"left over from a gel that was taken out")
    a, b = tmp_path / "a.png", tmp_path / "b.png"
    a.write_bytes(PNG)
    b.write_bytes(piece_png(300, 100, [50, 120], [40]))
    assert run(capsys, "edit", cut, "--add-gel", a, "--add-gel", b)[0] == 0
    assert [s.image for s in project(cut).strips] == ["bottom.png", "a.png", "b_1.png"]
    assert (cut / "b.png").read_bytes() == b"left over from a gel that was taken out"   # not touched, not mistaken for the gel
    assert (cut / "b_1.png").read_bytes() == b.read_bytes() and run(capsys, "verify", cut)[0] == 0


# ---------------------------------------------------------------------------------------------------- gaps the review found


def test_turn_and_rotate_with_gel_aim_at_that_gel(cut, capsys):
    assert run(capsys, "edit", cut, "--gel", 2, "--rows", "20,200", "--ticks", 50, "--no-snap")[0] == 0
    assert run(capsys, "edit", cut, "--gel", 2, "--turn", 180)[0] == 0
    p = project(cut)
    assert p.strips[0].turn == 2 and p.turn == 0 and (p.strips[0].top, p.strips[0].bottom) == (20, 200)   # 220 - 200, 220 - 20
    assert p.ladder.bands[0].y == 220 - 1 - 50
    assert run(capsys, "edit", cut, "--gel", 2, "--strict", "off", "--rotate", 2)[0] == 0
    p = project(cut)
    assert p.strips[0].rotate_deg == 2 and p.rotate_deg == 0 and p.strict   # the lanes gel isn't straightened
    assert run(capsys, "edit", cut, "--rotate", -1.5)[0] == 1   # it keeps its original pixels: --strict off is for it
    assert run(capsys, "edit", cut, "--rotate", -1.5, "--strict", "off")[0] == 0
    assert project(cut).rotate_deg == -1.5 and project(cut).strips[0].rotate_deg == 2
    assert run(capsys, "edit", cut, "--gel", 2, "--turn", 90)[0] == 0   # a quarter turn clears that gel's rows and ticks
    p = project(cut)
    assert p.strips[0].turn == 3 and p.strips[0].top is None and p.ladder.bands == []
    assert len(p.lanes.dividers) == 7   # and leaves the lanes gel alone
    assert run(capsys, "edit", cut, "--turn", 90)[0] == 0   # without --gel: the lanes gel, whose lanes now run the other way
    assert project(cut).turn == 1 and project(cut).lanes.dividers == []


def test_a_non_strict_stack_places_the_processed_gels_and_stretches_the_others():
    from gelscribe.core.image import render_gray
    pkg = cut_blot(shift=37)
    p = pkg.project
    p.strict = False
    p.strips[0].shift = 37
    p.strips[0].display.gamma = 1.3
    main = WorkingImage(SourceImage(pkg.image_data), p)
    ws = stacked.strip_images(pkg)
    fig = stacked.StackedFigure(p, main, ws)
    gel = fig.gel
    assert gel.dtype == np.uint8 and gel.ndim == 2
    c, q = fig.stack.crop, fig.stack.piece(1)
    top = int(q.top - c.y0)
    want = render_gray(ws[0]._processed(), p.strip_project(1).effective_display)
    rows = int(q.bottom - q.top)
    assert np.array_equal(gel[top:top + rows], want[:rows, 37:37 + gel.shape[1]])   # a whole-pixel shift: the gel's own values
    assert (gel[int(fig.stack.piece(None).bottom - c.y0):top] == 0).all()   # the black line between them
    p.strips[0].scale = 1.02   # stretched: resampled, still one gray image
    p.strips[0].shift = 12.5
    stretched = stacked.StackedFigure(p, main, stacked.strip_images(pkg)).gel
    assert stretched.dtype == np.uint8 and stretched.shape[1] == gel.shape[1] and stretched.min() >= 0
    from gelscribe.core.layout import ensure_gui
    ensure_gui()
    for fmt in ("png", "tiff", "pdf", "svg"):
        assert len(stacked.StackedFigure(p, main, stacked.strip_images(pkg)).export(fmt)) > 1000


def test_cmyk_images_are_refused_with_a_message():
    from gelscribe.core.image import ImageError, SourceImage
    for fmt in ("TIFF", "JPEG"):
        b = io.BytesIO()
        Image.new("CMYK", (40, 30), (0, 0, 0, 128)).save(b, fmt)
        with pytest.raises(ImageError, match="CMYK.*Convert it to RGB"):
            SourceImage(b.getvalue())
