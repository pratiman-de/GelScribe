"""Fixes from the 2026-10-06 review (findings numbered as in review-2026-10-06.md), one compact test each.
Made-up gels only (the pieces from test_gels), off-screen."""
import io
import json
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from gelscribe.core import ops, render
from gelscribe.core.image import ImageError, SourceImage, WorkingImage
from gelscribe.core.model import GelProject
from gelscribe.core.package import GelPackage, ProjectError
from test_app import app, close, settle   # noqa: F401 (app is a fixture)
from test_app_fixes import boxes, open_project   # noqa: F401 (fixtures)
from test_audit_fixes import cut, project, run   # noqa: F401 (cut is a fixture)
from test_gels import MAIN_LANES, cut_blot, piece_png


# ---------------------------------------------------------------------------------------------------- 1: plain folders


def test_1_saving_in_a_plain_folder_never_deletes_an_image(app, tmp_path):
    plain = tmp_path / "plain"   # a project.json of its own, with the user's own images beside it
    cut_blot().write(plain)
    w = open_project(app, plain / "project.json")
    w.ws.choose_gel(1)
    w.ws.remove_active_gel()
    assert w.save() and GelPackage.read(plain).project.strips == []
    assert (plain / "bottom.png").is_file() and (plain / "top.png").is_file()   # still there: they're the user's own
    close(w)
    # in a .gelscribe package the copy of the gel that was taken out still goes, whatever the letter case of the extension
    pkg = tmp_path / "cut.GelScribe"
    cut_blot().write(pkg)
    w = open_project(app, pkg)
    w.ws.choose_gel(1)
    w.ws.remove_active_gel()
    assert w.save() and not (pkg / "bottom.png").exists() and (pkg / "top.png").is_file()
    close(w)


def test_1_the_cli_deletes_nothing_in_a_plain_folder_named_by_its_folder(tmp_path, capsys):
    plain = tmp_path / "plain"
    cut_blot().write(plain)
    assert run(capsys, "edit", plain, "--remove-gel", 2)[0] == 0   # the folder itself, not its project.json
    assert project(plain).strips == [] and (plain / "bottom.png").is_file()


# ---------------------------------------------------------------------------------------------------- 2: mixed headline

MIXED = "Gel pixels: mixed. Some gels keep their original values and some were changed; see each gel below."


def test_2_the_headline_says_mixed_when_only_some_gels_keep_their_pixels():
    p = cut_blot().project
    head = lambda **kw: render.export_info(p, None, **kw).description   # noqa: E731
    p.strict, p.strips[0].strict = True, False
    assert head().startswith(f"GelScribe figure. {MIXED} 2 separately scanned gels")
    assert head(resampled_dpi=600, native_dpi=300).startswith(f"GelScribe figure. {MIXED} Resampled to 600 dpi from 300 dpi; ")
    p.strict, p.strips[0].strict = False, True   # the other way round is just as mixed
    assert head().startswith(f"GelScribe figure. {MIXED}")
    p.strips[0].strict = True   # every gel keeps its pixels, or none does: the headline stays as it was
    p.strict = True
    assert head().startswith("GelScribe figure. Gel pixels: original values, bit depth and color space, not resampled (strict); ")
    p.strict, p.strips[0].strict = False, False
    assert head().startswith("GelScribe figure. Gel pixels: adjusted (") and "mixed" not in head()
    assert head(resampled_dpi=600).startswith("GelScribe figure. Gel pixels: resampled to 600 dpi after adjustments (")


# ---------------------------------------------------------------------------------------------------- 3: a changed image

CHANGED = "Warning: Gel 2's image (bottom.png) has changed since it was added; its SHA-256 no longer matches."


def changed_copy(tmp_path) -> Path:
    folder = tmp_path / "cut.gelscribe"
    cut_blot().write(folder)
    (folder / "bottom.png").write_bytes(piece_png(350, 110, [c / 2 + 18 for c in MAIN_LANES], [45]))   # a downscaled copy
    return folder


def test_3_a_changed_image_still_exports_with_the_warning_in_the_note_and_on_stderr(tmp_path, capsys):
    folder = changed_copy(tmp_path)
    code, out, err = run(capsys, "render", folder, "--formats", "png")
    assert code == 0 and err.splitlines() == [CHANGED] and out.strip().endswith(".png")
    text = Image.open(tmp_path / "cut.figure.png").text["Description"]
    assert text.startswith(CHANGED + "\nGelScribe figure. ")
    assert run(capsys, "render", cut_folder(tmp_path), "--formats", "png")[2] == ""   # untouched copies: nothing to say


def cut_folder(tmp_path) -> Path:
    folder = tmp_path / "intact.gelscribe"
    cut_blot().write(folder)
    return folder


def test_3_the_app_asks_before_exporting_or_copying_a_changed_gel(app, tmp_path, monkeypatch):
    from PySide6.QtWidgets import QFileDialog, QMessageBox
    w = open_project(app, changed_copy(tmp_path))
    assert w.ws.changed_warnings() == [CHANGED] and w.ws.export_info().description.startswith(CHANGED + "\nGelScribe figure.")
    seen, out = [], tmp_path / "figure.png"
    monkeypatch.setattr(QFileDialog, "getSaveFileName", staticmethod(lambda *a, **k: (str(out), "")))

    def answer(label):
        def exec_(box):
            seen.append((box.text(), box.informativeText(), sorted(b.text().replace("&", "") for b in box.buttons())))
            next(b for b in box.buttons() if b.text().replace("&", "") == label).click()
            return 0
        return exec_
    monkeypatch.setattr(QMessageBox, "exec", answer("Cancel"))
    w.export("png")
    w.copy_figure()
    assert not out.exists() and len(seen) == 2
    assert seen[0] == ("A gel's image has changed", CHANGED, ["Cancel", "Export Anyway"])
    monkeypatch.setattr(QMessageBox, "exec", answer("Export Anyway"))
    w.export("png")
    assert out.is_file() and len(seen) == 3
    close(w)


# ---------------------------------------------------------------------------------------------------- 4: text size keys


def test_4_malformed_text_size_keys_are_dropped_on_load():
    d = json.loads(cut_blot().project.dumps())
    d["style"]["text_sizes"] = {"": 9, ".": 9, "..": 9, "lane": 9, "lane.1": 9, "lane.a.b": 9, "name.": 9, "x.0": 9,
                                "name.99999999999999999999": 9, "lane.0.1.2": 9, "name.-1": 9, "name.٣": 9,
                                "name.0": 8, "lane.0.1": 6, "group.1.0": 7, "rowname.0": 10}
    p = GelProject.loads(json.dumps(d))
    assert p.style.text_sizes == {"name.0": 8, "lane.0.1": 6, "group.1.0": 7, "rowname.0": 10}
    p.style.scale_all(1)   # and nothing trips over what's left
    p.style.remap_name_sizes([0])
    assert GelProject.loads(p.dumps()).style.text_sizes == p.style.text_sizes


# ---------------------------------------------------------------------------------------------------- 5: group row angles


def test_5_retyping_quick_labels_keeps_each_group_rows_angle(cut, capsys):
    labels = "WT{0{L|P}|50{L|P}}|KO{0{L|P}|50{L|P}}"
    assert run(capsys, "edit", cut, "--labels", labels, "--label-angle", 30)[0] == 0
    assert run(capsys, "edit", cut, "--group-angle", 45)[0] == 0
    p = project(cut)
    assert [r.rotation for r in p.rows if r.type == "groups"] == [45.0, 45.0] and p.label_angle == 30
    assert run(capsys, "edit", cut, "--labels", labels)[0] == 0   # the same labels again, as typing in the app does
    p = project(cut)
    assert [r.rotation for r in p.rows if r.type == "groups"] == [45.0, 45.0] and p.label_angle == 30
    q = GelProject.loads(p.dumps())   # different angles per row stay with their place among the group rows
    g = [i for i, r in enumerate(q.rows) if r.type == "groups"]
    ops.set_row_angle(q, g[0], 10)
    ops.set_row_angle(q, g[1], 20)
    ops.apply_quick_labels(q, labels)
    assert [r.rotation for r in q.rows if r.type == "groups"] == [10.0, 20.0]


# ---------------------------------------------------------------------------------------------------- 6: separator on load


@pytest.mark.parametrize("separator, width, colour, thickness", [
    ("#GGG", "thick", "black", None), (7, [1], "black", None), (True, True, "black", None), ("", None, "black", None),
    ("#f30", 3, "#ff3300", 3.0), ("WHITE", 0.01, "white", 0.25), (None, 99, "black", 10.0), ("#12", float("inf"), "black", None)])
def test_6_a_bad_separator_loads_as_black_and_a_bad_width_follows_the_lines(tmp_path, separator, width, colour, thickness):
    d = json.loads(cut_blot().project.dumps())
    d["separator"], d["separator_width"] = separator, width
    folder = tmp_path / "bad.gelscribe"
    cut_blot().write(folder)
    (folder / "project.json").write_text(json.dumps(d))
    p = GelPackage.read(folder).project   # opens, with no error
    assert (p.separator, p.separator_width) == (colour, thickness)
    assert p.effective_separator_width == (thickness if thickness is not None else p.style.line_width_pt)


# ---------------------------------------------------------------------------------------------------- 7: 32-bit integers

INT32_MESSAGE = ("This image has 32-bit integer values, which GelScribe doesn't support. Export it from your scanner's "
                 "software as a 16-bit TIFF and open that.")


def _tiff_bytes(array) -> bytes:
    import tifffile
    buf = io.BytesIO()
    tifffile.imwrite(buf, array, photometric="minisblack")
    return buf.getvalue()


@pytest.mark.parametrize("dtype", [np.uint32, np.int32])
def test_7_32_bit_integer_images_are_refused_like_float_ones(tmp_path, capsys, dtype):
    values = (np.arange(60 * 40).reshape(40, 60) * 90).astype(dtype)   # past 65535: it used to be clipped to white
    data = _tiff_bytes(values)
    with pytest.raises(ImageError) as e:
        SourceImage(data)
    assert str(e.value) == INT32_MESSAGE
    f = tmp_path / "i.tif"
    f.write_bytes(data)
    code, _, err = run(capsys, "new", f)
    assert code == 1 and INT32_MESSAGE in err and not (tmp_path / "i.gelscribe").exists()
    assert SourceImage(_tiff_bytes(values.astype(np.uint16))).bits == 16   # 16-bit and 8-bit are still fine
    assert SourceImage(_tiff_bytes(values.astype(np.uint8))).bits == 8
    with pytest.raises(ImageError, match="64-bit integer values"):
        SourceImage(_tiff_bytes(values.astype(np.int64)))


# ---------------------------------------------------------------------------------------------------- 9: too large

TOO_LARGE = "The figure is too large to make. Crop the gels or lower the export resolution."


def test_9_a_figure_too_large_to_make_is_an_error_never_blank_space(cut, tmp_path, capsys, monkeypatch):
    from PySide6.QtGui import QImage
    render.check_raster_size(100_000, 5_000)   # at the limits (as on the Mac): fine
    for size in [(100_001, 10), (10, 100_001), (30_000, 20_000), (0, 10)]:
        with pytest.raises(ImageError, match="too large to make"):
            render.check_raster_size(*size)
    # the command line: 10000 dpi is far past the limit; nothing is written, not even the PDF listed first
    code, out, err = run(capsys, "render", cut, "--formats", "pdf,png", "--dpi", 10000)
    assert code == 1 and out == "" and err.strip().endswith(f"gelscribe: {TOO_LARGE}")
    assert not list(tmp_path.glob("*.figure.*"))
    # a stack that can't be composed, and a gel too big for a drawing surface: refused, not exported as white space
    pkg = GelPackage.read(cut)
    from gelscribe.core import strips as stacked
    fig = stacked.StackedFigure(pkg.project, WorkingImage(SourceImage(pkg.image_data), pkg.project), stacked.strip_images(pkg))
    assert fig.gel is not None
    monkeypatch.setattr(render, "MAX_PIXELS", 1000)
    with pytest.raises(ImageError) as e:
        fig.export("png")
    assert str(e.value) == TOO_LARGE
    monkeypatch.undo()
    monkeypatch.setattr(render, "qimage", lambda a: QImage())   # what Qt gives for a gel it has no memory for
    with pytest.raises(ImageError) as e:
        fig.export("pdf")
    assert str(e.value) == TOO_LARGE
    monkeypatch.undo()
    monkeypatch.setattr(render, "raster", lambda *a: (_ for _ in ()).throw(MemoryError()))   # and no memory at all
    with pytest.raises(ImageError) as e:
        fig.export("tiff")
    assert str(e.value) == TOO_LARGE


def test_9_the_app_says_so_instead_of_exporting(app, tmp_path, boxes, monkeypatch):
    from PySide6.QtWidgets import QFileDialog
    folder = tmp_path / "cut.gelscribe"
    cut_blot().write(folder)
    w = open_project(app, folder)
    w.ws.set_export_dpi(10000)
    out = tmp_path / "figure.png"
    monkeypatch.setattr(QFileDialog, "getSaveFileName", staticmethod(lambda *a, **k: (str(out), "")))
    w.export("png")
    assert boxes == [f"Export failed.\n\n{TOO_LARGE}"] and not out.exists()
    close(w)


# ---------------------------------------------------------------------------------------------------- 16: exact names


def test_16_an_image_named_with_other_capitals_is_missing_even_on_a_disk_that_ignores_case(tmp_path):
    folder = tmp_path / "cut.gelscribe"
    cut_blot().write(folder)
    assert GelPackage.read(folder).project.image == "top.png"
    d = json.loads((folder / "project.json").read_text())
    d["image"] = "TOP.png"   # on a Mac or PC disk this opens top.png; a project must name its images exactly
    (folder / "project.json").write_text(json.dumps(d))
    with pytest.raises(ProjectError, match=r"image TOP\.png is missing from it \(the folder has top\.png"):
        GelPackage.read(folder)
    d["image"], d["strips"][0]["image"] = "top.png", "Bottom.PNG"
    (folder / "project.json").write_text(json.dumps(d))
    with pytest.raises(ProjectError, match=r"gel image Bottom\.PNG is missing from it \(the folder has bottom\.png"):
        GelPackage.read(folder)
    with pytest.raises(ProjectError, match="Bottom.PNG is missing"):   # a project.json next to its images, too
        GelPackage.read(folder / "project.json")
    d["strips"][0]["image"] = "bottom.png"
    (folder / "project.json").write_text(json.dumps(d))
    assert GelPackage.read(folder).project.strips[0].image == "bottom.png"


# ---------------------------------------------------------------------------------------------------- 18: safe path in the launchers


@pytest.mark.skipif(sys.platform == "win32", reason="shell scripts")
@pytest.mark.parametrize("launcher", ["GelScribe.sh", "GelScribe.command"])
def test_18_the_launchers_keep_the_folder_they_run_in_off_the_module_path(tmp_path, launcher, monkeypatch):
    root = Path(__file__).resolve().parent.parent
    here = tmp_path / "GelScribe"
    here.mkdir()
    for name in ("GelScribe.sh", "GelScribe.command", "requirements.txt"):
        shutil.copy(root / name, here / name)
    shutil.copy(root / "requirements.txt", here / "requirements.used")   # "set up already"
    stub = here / "fakepython"
    stub.write_text('#!/bin/sh\necho "safe=$PYTHONSAFEPATH args=$*"\n')
    stub.chmod(0o755)
    (here / "python.txt").write_text(str(stub) + "\n")
    monkeypatch.delenv("PYTHONSAFEPATH", raising=False)
    r = subprocess.run([str(here / launcher), "render", "x.gelscribe"], cwd=str(tmp_path), capture_output=True, text=True,
                       timeout=60)
    assert r.returncode == 0 and r.stdout.strip() == "safe=1 args=-m gelscribe.cli render x.gelscribe", r.stderr


# ---------------------------------------------------------------------------------------------------- 21: the Mac's wording


@pytest.mark.parametrize("args, said", [
    (["--shift", "99999999999"], "gelscribe: --shift wants pixels\n"),
    (["--shift", "1e308"], "gelscribe: --shift wants pixels\n"),
    (["--ticks", "x"], "gelscribe: --ticks wants rows like 60,110,170\n"),
    (["--ticks", "60,nan"], "gelscribe: --ticks wants rows like 60,110,170\n"),
    (["--align", "manual"], "gelscribe: --align wants auto\n"),
    (["--dividers", "20,40,60,80,100", "--gel", "2", "--strict", "off", "--align", "auto"],
     "gelscribe: Gel 2's lanes don't line up with the lanes gel's. Line it up by hand.\n"),
    (["--dividers", "20,40,60,80,100", "--gel", "2", "--strict", "on", "--align", "auto"],
     "gelscribe: Gel 2's lanes don't line up with the lanes gel's. Line it up by hand or turn off Keep original pixels "
     "for Gel 2 to let it stretch.\n")])
def test_21_refusals_use_the_macs_words(cut, capsys, args, said):
    code, out, err = run(capsys, "edit", cut, *args)
    assert (code, out, err) == (1, "", said)


def test_21_counts_are_pluralized_and_align_takes_any_letter_case(cut, capsys):
    code, out, _ = run(capsys, "edit", cut, "--labels", "A", "--ticks", "60", "--name", "X@70")
    assert code == 0 and out.strip().startswith("8 lanes, 1 tick, 1 name, 2 gels")   # a one-lane label doesn't change the lanes
    code, out, _ = run(capsys, "edit", cut, "--ticks", "60,110", "--name", "Y@80")
    assert out.strip() == "8 lanes, 3 ticks, 2 names, 2 gels"
    assert run(capsys, "edit", cut, "--gel", "2", "--align", "AUTO")[0] == 0
    p = GelPackage.read(cut).project
    assert run(capsys, "edit", cut, "--auto-lanes", "2")[1].strip().startswith("2 lanes, 3 ticks")


# ---------------------------------------------------------------------------------------------------- 20: docstrings, one separator


def test_20_no_docstring_still_limits_the_label_angle_to_0_to_90_and_the_separator_is_set_once():
    root = Path(__file__).resolve().parent.parent / "gelscribe"
    for path in root.rglob("*.py"):
        text = path.read_text(encoding="utf-8")
        assert "0 to 90" not in text and "clamped to that range" not in text, path
    assert (root / "cli.py").read_text(encoding="utf-8").count("p.separator = separator\n") == 1


# ---------------------------------------------------------------------------------------------------- 8: stacks that keep nothing


@pytest.mark.parametrize("line, rgb, value", [("black", False, 0), ("white", False, 255), ("#808080", False, 128),
                                              ("#ff3300", True, (255, 51, 0)), ("#808081", True, (128, 128, 129))])
def test_8_a_stack_that_keeps_no_pixels_is_gray_unless_its_line_is_a_colour(line, rgb, value):
    from gelscribe.core import strips as stacked
    pkg = cut_blot()
    p = pkg.project
    p.strict = p.strips[0].strict = False
    p.separator = line
    fig = stacked.StackedFigure(p, WorkingImage(SourceImage(pkg.image_data), p), stacked.strip_images(pkg))
    gel = fig.gel
    assert gel.dtype == np.uint8 and (gel.ndim == 3) == rgb
    row = fig.stack.pieces[0].bottom - fig.stack.crop.y0   # the first line between gels
    assert tuple(np.atleast_1d(gel[int(round(row))][0])) == tuple(np.atleast_1d(value))
    if rgb:   # the gels' own pixels are the same in every channel
        assert (gel[..., 0] == gel[..., 1]).sum() > gel[..., 0].size * 0.9
    note = fig.info().description
    assert note.count(f"converted to 8-bit {'RGB' if rgb else 'gray'}") == 2 and "values times 257" not in note
    assert render.export_info(p, None).description.count("converted to") == 0   # no storage given: nothing is said
    p.strips[0].strict = True   # some keep theirs: the storage is theirs, as before
    p.strict = False
    assert "converted to 8-bit gray" in stacked.StackedFigure(p, WorkingImage(SourceImage(pkg.image_data), p),
                                                              stacked.strip_images(pkg)).info().description


# ---------------------------------------------------------------------------------------------------- 15: palettes


def _palette_png(colours) -> bytes:
    im = Image.new("P", (6, 4))
    im.putdata([i % len(colours) for i in range(24)])
    im.putpalette([v for c in colours for v in c])
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    return buf.getvalue()


def _palette_tiff(colours) -> bytes:
    import tifffile
    cmap = np.zeros((3, 256), np.uint16)
    for i, c in enumerate(colours):
        cmap[:, i] = [v * 257 for v in c]
    buf = io.BytesIO()
    tifffile.imwrite(buf, (np.arange(24) % len(colours)).astype(np.uint8).reshape(4, 6), photometric="palette", colormap=cmap)
    return buf.getvalue()


@pytest.mark.parametrize("make", [_palette_png, _palette_tiff])
def test_15_only_palettes_of_grays_are_read_as_gray(make):
    grays = [(10, 10, 10), (200, 200, 200), (77, 77, 77)]   # not in order of brightness: the pixels take their palette's values
    s = SourceImage(make(grays))
    assert (s.channels, s.bits, s.pixels.dtype, s.pixels.shape) == (1, 8, np.uint8, (4, 6))
    assert s.pixels.ravel()[:6].tolist() == [10, 200, 77, 10, 200, 77]
    for colours in ([(10, 10, 10), (200, 200, 201)], [(10, 10, 10), (200, 100, 50), (1, 2, 3)]):   # one off-gray colour
        s = SourceImage(make(colours))
        assert (s.channels, s.bits, s.pixels.shape) == (3, 8, (4, 6, 3))
        assert s.pixels[0, 1].tolist() == list(colours[1])


# ---------------------------------------------------------------------------------------------------- 10: file names off


def test_10_the_note_can_leave_every_file_name_out_and_keep_the_fingerprints():
    pkg = cut_blot()
    p = pkg.project
    p.title = None
    shas = [("bbb", None, (700, 220))]
    named = render.export_info(p, "aaa", strips=shas, size=(620, 160))
    assert "Source top.png sha256 aaa." in named.description and "2. bottom.png sha256 bbb," in named.description
    assert "1. top.png, as above" in named.description and named.title == "top.png"
    p.export_file_names = False
    bare = render.export_info(p, "aaa", strips=shas, size=(620, 160))
    assert "png" not in bare.description and "Source sha256 aaa." in bare.description   # no file name anywhere
    assert " 1. as above (its lanes are the figure's), columns 0–620" in bare.description
    assert " 2. sha256 bbb, columns 0–" in bare.description and bare.title == "GelScribe figure"
    assert render.export_info(p, "aaa").description.count("sha256") == 1   # a gel with no fingerprint says nothing of one
    assert "export_file_names" not in cut_blot().project.dumps()   # true is what's left out of the file
    d = json.loads(p.dumps())
    assert d["export_file_names"] is False and GelProject.loads(p.dumps()).export_file_names is False
    for bad in ("no", 0, [False]):
        with pytest.raises(ValueError, match="export_file_names should be true or false"):
            GelProject.from_json({**d, "export_file_names": bad})
    # the warning about a changed image names no file in a note without names, but still does in what's said to the user
    p.image_sha256 = "x" * 64
    assert render.changed_warnings(p, ["y" * 64, "bbb"], names=False)[0] == \
        "Warning: Gel 1's image has changed since it was added; its SHA-256 no longer matches."
    assert render.changed_warnings(p, ["y" * 64, "bbb"])[0].startswith("Warning: Gel 1's image (top.png) has changed")


def test_10_the_command_line_switch_and_every_export_format(cut, tmp_path, capsys):
    import pikepdf
    import tifffile
    assert run(capsys, "edit", cut, "--file-names", "maybe")[2].startswith("gelscribe: --file-names wants on or off")
    assert run(capsys, "edit", cut, "--file-names", "off")[0] == 0 and project(cut).export_file_names is False
    assert '"export_file_names": false' in (cut / "project.json").read_text()
    (cut / "bottom.png").write_bytes(piece_png(350, 110, [c / 2 + 18 for c in MAIN_LANES], [45]))   # a changed gel, too
    code, out, err = run(capsys, "render", cut, "--formats", "pdf,png,tiff,svg")
    assert code == 0 and "(bottom.png)" in err   # the user is still told which file
    stem = str(tmp_path / "cut.figure")
    with pikepdf.open(stem + ".pdf") as pdf:
        subject, title = str(pdf.docinfo["/Subject"]), str(pdf.docinfo["/Title"])
    with tifffile.TiffFile(stem + ".tiff") as tf:
        tiff = tf.pages[0].description
    notes = [subject, Image.open(stem + ".png").text["Description"], tiff, Path(stem + ".svg").read_text(encoding="utf-8")]
    for note in notes:
        assert "top.png" not in note and "bottom.png" not in note and "sha256" in note, note
        assert "Warning: Gel 2's image has changed since it was added" in note
    assert title == "top"   # the figure's own title stays
    assert run(capsys, "edit", cut, "--file-names", "ON")[0] == 0 and "export_file_names" not in (cut / "project.json").read_text()


def test_10_the_export_tab_has_the_checkbox_and_it_undoes(app, tmp_path):
    folder = tmp_path / "cut.gelscribe"
    cut_blot().write(folder)
    w = open_project(app, folder)
    ws = w.ws
    ws.choose_tab("export")
    settle()
    panel = w.inspector.panels["export"]
    assert panel.names.text() == "Include file names in exported files" and panel.names.isChecked()
    assert "top.png" in panel.prov.text()
    texts = [lab.text() for lab in panel.findChildren(type(panel.prov))]
    assert "File names can identify samples or people. The SHA-256 fingerprints stay either way." in texts
    panel.names.click()   # off
    settle()
    assert ws.project.export_file_names is False and "top.png" not in panel.prov.text() and "sha256" in panel.prov.text()
    assert not panel.names.isChecked() and ws.undo.undoText() == "File Names in Exports"
    ws.undo.undo()
    settle()
    assert ws.project.export_file_names and panel.names.isChecked() and "top.png" in panel.prov.text()
    close(w)


# ---------------------------------------------------------------------------------------------------- 12: an unreadable gel


def test_12_edits_that_do_not_need_a_gels_pixels_work_when_its_image_cant_be_read(cut, tmp_path, capsys):
    assert run(capsys, "edit", cut, "--gel", 2, "--ticks", 30, "--name", "Z@30", "--labels", "A|B|C|D|E|F|G|H")[0] == 0
    (cut / "bottom.png").write_bytes(b"not an image")
    cant = "gelscribe: Gel 2's image (bottom.png) can't be read.\n"
    good = [["--title", "Hi"], ["--labels", "A|B|C"], ["--label-angle", 30], ["--separator", "white"], ["--separator-width", 2],
            ["--file-names", "off"], ["--own-ladder", "on"], ["--dividers", "100,200,300"], ["--turn", 180],
            ["--crop", "1,1,100,100"], ["--order", "2,1"], ["--gel", 2, "--shift", 5], ["--gel", 2, "--scale", 1.02]]
    bad = [["--gel", 2, "--align", "auto"], ["--gel", 2, "--rows", "1,50"], ["--gel", 2, "--turn", 90],
           ["--gel", 2, "--crop", "1,1,50,50"], ["--gel", 2, "--ticks", 40], ["--gel", 2, "--name", "Q@40"],
           ["--gel", 2, "--rotate", 2, "--strict", "off"], ["--strict", "off"], ["--gel", 2, "--strict", "on"],
           ["--gel", 1, "--strict", "off"]]   # Strict moves the marks of every gel whose rotation it changes: all must open
    for n, args in enumerate(good + bad):
        copy = tmp_path / f"copy{n}.gelscribe"
        shutil.copytree(cut, copy)
        before = (copy / "project.json").read_bytes()
        code, _, err = run(capsys, "edit", copy, *args)
        if args in good:
            assert code == 0 and "can't be read" not in err, (args, err)
            assert (copy / "project.json").read_bytes() != before, args
            assert len(project(copy).strips) == 1 and len(project(copy).annotations) == 1   # the damaged gel's marks stay
        else:
            assert (code, err) == (1, cant), args
            assert (copy / "project.json").read_bytes() == before, args
    copy = tmp_path / "removed.gelscribe"
    shutil.copytree(cut, copy)
    assert run(capsys, "edit", copy, "--remove-gel", 2)[0] == 0 and project(copy).strips == []
    assert run(capsys, "render", cut, "--formats", "png")[1:] == ("", cant)   # there's no figure without a gel


def test_2_a_mixed_note_gives_the_lanes_gels_own_adjustments_when_it_doesnt_keep_its_pixels():
    p = cut_blot().project
    p.strict, p.strips[0].strict = False, True   # the lanes gel is adjusted, the other kept
    p.turn, p.rotate_deg, p.display.gamma = 1, 2.5, 1.5
    p.display.invert = True
    info = render.export_info(p, "aaa", strips=[("bbb", None)]).description
    assert info.startswith(f"GelScribe figure. {MIXED} ") and "adjusted (" not in info
    assert (" 1. top.png, as above (its lanes are the figure's), turned 90°, rotation 2.5°, levels 0.0–1.0, gamma 1.5, "
            "inverted;") in info   # then its columns and rows, as for any gel (there are no sizes here)
    p.strict, p.turn = True, 0   # kept after all (and straight): nothing of the kind is said of it
    p.strips[0].strict = False
    assert " 1. top.png, as above (its lanes are the figure's);" in render.export_info(p, "aaa").description
