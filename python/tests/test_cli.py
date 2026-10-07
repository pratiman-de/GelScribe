"""The command-line tool (gelscribe/cli.py) and the launchers that run it, on a made-up gel."""
import json
import os
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

import numpy as np
import pikepdf
import pytest
import tifffile
from PIL import Image

from gelscribe import cli
from gelscribe.core.model import GelProject

ROOT = Path(__file__).resolve().parent.parent
LANES = [60 + 70 * i for i in range(8)]   # lane centres; the ladder runs in lane 1
LADDER_YS = [60, 95, 140, 200, 270, 340]
SAMPLE_Y = 180
LABELS = "µM: |0{L|P}|10{L|P}|25{L|P}|50{P}"
posix_only = pytest.mark.skipif(sys.platform == "win32", reason="the Mac and Linux launcher")


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
    path = tmp_path / "blot.png"
    Image.fromarray(np.clip(img, 0, 255).round().astype(np.uint8)).save(path)
    return path


def run(capsys, *args):
    code = cli.main([str(a) for a in args])
    out, err = capsys.readouterr()
    return code, out, err


def project(path) -> GelProject:
    return GelProject.loads((Path(path) / "project.json").read_text(encoding="utf-8"))


@pytest.fixture
def made(gel, capsys):
    """A project around the gel, with its lanes and labels."""
    code, out, _ = run(capsys, "new", gel)
    assert code == 0
    folder = Path(out.strip())
    assert run(capsys, "edit", folder, "--auto-lanes", 8, "--labels", LABELS)[0] == 0
    return folder


# ---------------------------------------------------------------------------------------------------- basics


def test_help_and_mistakes(capsys):
    code, out, _ = run(capsys, "help")
    assert code == 0 and out.startswith("usage:") and "gelscribe mcp" not in out
    assert run(capsys)[0] == 2
    code, _, err = run(capsys, "frobnicate")
    assert code == 2 and "unknown command frobnicate" in err
    code, _, err = run(capsys, "verify")
    assert code == 2 and "which PROJECT?" in err


def test_new_copies_the_image_byte_for_byte_and_never_replaces_a_project(gel, capsys):
    code, out, _ = run(capsys, "new", gel)
    folder = Path(out.strip())
    assert code == 0 and folder == gel.with_suffix(".gelscribe") and folder.is_absolute()
    assert (folder / "blot.png").read_bytes() == gel.read_bytes()
    p = project(folder)
    assert p.strict and p.title == "blot" and p.image_sha256
    before = (folder / "project.json").read_bytes()
    code, _, err = run(capsys, "new", gel)
    assert code == 1 and "already exists" in err
    assert (folder / "project.json").read_bytes() == before
    code, _, err = run(capsys, "new", gel.parent / "missing.png")
    assert code == 1 and "missing.png" in err


def test_detect_finds_the_lanes_and_the_ladder_bands(gel, capsys):
    for args in (["--lanes", 8], []):
        code, out, _ = run(capsys, "detect", gel, *args)
        d = json.loads(out)
        assert code == 0 and (d["width"], d["height"]) == (600, 420)
        assert len(d["lane_centers"]) == 8
        assert all(abs(c - x) <= 2 for c, x in zip(d["lane_centers"], LANES)), d["lane_centers"]
        assert abs(d["pitch"] - 70) <= 1
        ys = [b["y"] for b in d["lane1_bands"]]
        assert len(ys) == len(LADDER_YS) and all(abs(a - b) <= 1 for a, b in zip(ys, LADDER_YS)), ys
    assert run(capsys, "detect", gel, "--lanes", 1)[0] == 1


def test_presets_list_ids_names_and_gel_systems(capsys):
    code, out, _ = run(capsys, "presets")
    lines = out.splitlines()
    assert code == 0
    assert any(line.startswith("thermo-pageruler-prestained\tPageRuler Prestained (26616/26617/26618)\tkDa\t")
               for line in lines)
    assert "  bt-4-12-mes\tNuPAGE Bis-Tris 4–12%, MES\t140 115 80 70 50 40 30 25 15 10" in lines


# ---------------------------------------------------------------------------------------------------- edit


def test_lanes_labels_ladder_and_a_band_name(made, capsys):
    p = project(made)
    assert p.lane_count == 8 and p.lanes.outer_lanes and len(p.lanes.dividers) == 7
    assert all(abs(c - x) <= 2 for c, x in zip(p.lanes.centers, LANES))
    assert p.rows[0].labels == ["", "L", "P", "L", "P", "L", "P", "P"]
    assert p.rows[1].name == "µM" and [g.text for g in p.rows[1].groups] == ["0", "10", "25", "50"]

    ticks = ",".join(str(y + d) for y, d in zip(LADDER_YS, (-2, 2, 1, -1, 1, -2)))   # a little off; they snap
    code, out, _ = run(capsys, "edit", made, "--ticks", ticks, "--preset", "thermo-pageruler-prestained",
                       "--system", "bt-4-12-mes")
    assert code == 0 and out.strip() == "8 lanes, 6 ticks, 0 names"
    l = project(made).ladder
    assert [b.y for b in l.bands] == LADDER_YS
    assert [b.size for b in l.bands] == [140, 115, 80, 70, 50, 40] and all(b.auto for b in l.bands)
    assert l.system == "NuPAGE Bis-Tris 4–12%, MES" and l.name == "PageRuler Prestained (26616/26617/26618)"

    code, out, _ = run(capsys, "edit", made, "--name", f"RPS6@{SAMPLE_Y}:tick", "--title", "RPS6")
    assert code == 0 and out.strip() == "8 lanes, 6 ticks, 1 name"
    p = project(made)
    assert p.title == "RPS6"
    a = p.annotations[0]
    assert (a.text, a.y, a.marker, a.side) == ("RPS6", SAMPLE_Y, "tick", "right")


def test_a_gel_system_given_before_any_tick_is_kept(made, capsys):
    # the catalog number finds the preset; the system sticks although there's no ladder yet
    assert run(capsys, "edit", made, "--preset", "26617", "--system", "bt-4-12-mops")[0] == 0
    l = project(made).ladder
    assert l.name.startswith("PageRuler Prestained") and l.system == "NuPAGE Bis-Tris 4–12%, MOPS"
    assert l.sizes == [140, 115, 80, 65, 50, 40, 30, 25, 15, 10]
    # ticks added later take their sizes from that list, top down, as guesses
    assert run(capsys, "edit", made, "--ticks", ",".join(map(str, reversed(LADDER_YS))))[0] == 0
    bands = project(made).ladder.bands
    assert [b.size for b in bands] == [140, 115, 80, 65, 50, 40] and all(b.auto for b in bands)
    # and the system can change on its own, keeping each tick's protein
    assert run(capsys, "edit", made, "--system", "mes")[0] == 0
    assert [b.size for b in project(made).ladder.bands] == [140, 115, 80, 70, 50, 40]


def test_a_mistake_changes_nothing(made, capsys):
    before = (made / "project.json").read_bytes()
    for args, code, message in [(["--rotate", 3], 1, "needs --strict off"),
                                (["--crop", "1,2,3"], 1, "--crop wants"),
                                (["--preset", "no such ladder"], 1, "unknown preset"),
                                (["--title", "X", "--preset", "pageruler", "--system", "agarose"], 1, "no gel system"),
                                (["--name", "RPS6"], 1, "TEXT@Y"),
                                (["--strict", "maybe"], 1, "on or off"),
                                (["--frobnicate"], 2, "unknown option"),
                                (["--title"], 2, "needs a value")]:
        got, _, err = run(capsys, "edit", made, *args)
        assert got == code and message in err, (args, err)
        assert (made / "project.json").read_bytes() == before, args


def test_rotating_moves_the_marks_and_strict_puts_them_back(made, capsys):
    run(capsys, "edit", made, "--ticks", ",".join(map(str, LADDER_YS)))
    before = [b.y for b in project(made).ladder.bands]
    assert run(capsys, "edit", made, "--strict", "off", "--rotate", 3)[0] == 0
    p = project(made)
    assert not p.strict and p.rotate_deg == 3 and [b.y for b in p.ladder.bands] != before
    assert run(capsys, "edit", made, "--strict", "on")[0] == 0
    assert all(abs(a - b) <= 1 for a, b in zip((b.y for b in project(made).ladder.bands), before))


def test_crop_fit_and_a_shared_scheme(made, gel, capsys):
    run(capsys, "edit", made, "--ticks", ",".join(map(str, LADDER_YS)), "--preset", "pageruler prestained",
        "--name", "X@180", "--title", "T", "--crop", "fit")
    c = project(made).crop
    assert c is not None and c.x0 <= 25 and c.x1 >= 575 and 340 < c.y1 <= 420
    other = gel.parent / "next.gelscribe"
    run(capsys, "new", gel, "-o", other)
    assert run(capsys, "edit", other, "--scheme-from", made)[0] == 0
    p = project(other)
    assert p.title == "T" and [a.text for a in p.annotations] == ["X"] and p.ladder.bands == []
    assert len(p.rows) == 2 and p.lane_count == 0   # labels come along, lanes don't (no --with-positions)
    assert run(capsys, "edit", other, "--scheme-from", made, "--with-positions")[0] == 0
    assert project(other).lane_count == 8


# ---------------------------------------------------------------------------------------------------- render


def test_render_writes_every_format_next_to_the_project(made, capsys):
    run(capsys, "edit", made, "--ticks", ",".join(map(str, LADDER_YS)), "--preset", "thermo-pageruler-prestained",
        "--system", "bt-4-12-mes")
    code, out, err = run(capsys, "render", made, "--formats", "pdf,png,tiff,svg")
    paths = [Path(line) for line in out.splitlines()]
    assert code == 0 and err == ""
    assert [p.name for p in paths] == ["blot.figure.pdf", "blot.figure.png", "blot.figure.tiff", "blot.figure.svg"]
    assert all(p.parent == made.parent for p in paths)
    png = Image.open(paths[1])
    assert png.size[0] > 600 and round(png.info["dpi"][0]) > 72
    with tifffile.TiffFile(paths[2]) as t:   # a description with a – in it (4–12%) used to stop the TIFF
        assert "apparent sizes for NuPAGE Bis-Tris 4–12%, MES" in t.pages[0].description
    with pikepdf.open(paths[0]) as pdf:
        assert "GelScribe figure." in str(pdf.docinfo["/Subject"])
    assert ET.parse(paths[3]).getroot().tag.endswith("svg")


def test_render_with_a_stem_and_a_resolution(made, capsys):
    stem = made.parent / "out" / "fig"
    stem.parent.mkdir()
    code, out, err = run(capsys, "render", made, "-o", stem, "--formats", "png", "--dpi", 300)
    assert code == 0 and Path(out.strip()) == stem.with_suffix(".png")
    assert round(Image.open(out.strip()).info["dpi"][0]) == 300 and "resampled" in err


def test_render_never_overwrites_the_original_or_writes_into_the_project(made, gel, capsys):
    original = gel.read_bytes()
    code, _, err = run(capsys, "render", made, "-o", gel.with_suffix(""), "--formats", "png")
    assert code == 1 and "original image" in err and gel.read_bytes() == original
    code, _, err = run(capsys, "render", made, "-o", made / "fig", "--formats", "png")
    assert code == 1 and "inside the project" in err
    code, _, err = run(capsys, "render", made, "--formats", "png,jpeg")
    assert code == 1 and "unknown format jpeg" in err and not list(made.parent.glob("*.figure.*"))


def test_gels_stack_line_up_reorder_and_come_out(made, tmp_path, capsys):
    """A second gel of the same lanes, 20 px further right: stacked, lined up, moved, taken out again."""
    h, w = 300, 640
    yy, xx = np.mgrid[0:h, 0:w]
    img = np.full((h, w), 235.0)
    for cx in LANES:
        img -= 190 * np.exp(-((yy - 120) / 4.0) ** 2 / 2) * (np.abs(xx - (cx + 20)) < 24)
    second = tmp_path / "second gel.png"
    Image.fromarray(np.clip(img, 0, 255).round().astype(np.uint8)).save(second)
    code, out, err = run(capsys, "edit", made, "--add-gel", second, "--gel", 2, "--align", "auto", "--ticks", 120,
                         "--name", "Loading control@120")
    assert code == 0 and out.strip().endswith("2 gels") and "gel 2: shift" in err, err
    p = project(made)
    assert [s.image for s in p.strips] == ["second gel.png"] and abs(p.strips[0].shift - 20) <= 1
    assert p.ladder.bands[-1].strip == 1 and p.annotations[-1].strip == 1
    assert (made / "second gel.png").read_bytes() == second.read_bytes()
    # the gel with the lanes isn't lined up with anything, and can't be taken out; it can be moved sideways
    assert run(capsys, "edit", made, "--gel", 1, "--rows", "1,50")[0] == 1
    assert run(capsys, "edit", made, "--gel", 1, "--shift", 3)[0] == 0 and project(made).main_shift == 3
    assert run(capsys, "edit", made, "--shift", 0)[0] == 0 and project(made).main_shift == 0
    assert run(capsys, "edit", made, "--remove-gel", 1)[0] == 1
    assert run(capsys, "edit", made, "--order", "1,1")[0] == 1
    assert run(capsys, "edit", made, "--order", "2,1")[0] == 0
    assert project(made).main_position == 1
    code, out, _ = run(capsys, "render", made, "--formats", "png,pdf")
    assert code == 0
    code, out, _ = run(capsys, "verify", made)
    assert code == 0 and "second gel.png matches" in out
    assert run(capsys, "edit", made, "--remove-gel", 1)[0] == 0   # the second gel, now on top
    p = project(made)
    assert p.strips == [] and p.main_position == 0 and all(b.strip is None for b in p.ladder.bands)
    assert not (made / "second gel.png").exists()


def test_verify_notices_a_changed_image(made, capsys):
    code, out, _ = run(capsys, "verify", made)
    assert code == 0 and out.strip() == "intact: blot.png matches its recorded SHA-256"
    img = made / "blot.png"
    img.write_bytes(img.read_bytes() + b"\0")
    code, _, err = run(capsys, "verify", made)
    assert code == 1 and "CHANGED: blot.png" in err


# ---------------------------------------------------------------------------------------------------- starting it


def child_env(home: Path) -> dict:
    env = dict(os.environ, HOME=str(home), PYTHONDONTWRITEBYTECODE="1", APPDATA=str(home),
               XDG_DATA_HOME=str(home / "share"), XDG_CONFIG_HOME=str(home / "config"))
    for k in ("CONDA_PREFIX", "PYTHONPATH", "QT_QPA_PLATFORM"):
        env.pop(k, None)
    return env


def test_python_m_gelscribe_runs_a_command(gel, tmp_path):
    r = subprocess.run([sys.executable, "-m", "gelscribe", "detect", str(gel), "--lanes", "8"], cwd=str(ROOT),
                       capture_output=True, text=True, env=child_env(tmp_path), timeout=120)
    assert r.returncode == 0 and len(json.loads(r.stdout)["lane_centers"]) == 8


@pytest.fixture
def copy(tmp_path):
    """The GelScribe folder as someone downloads it, without anything a setup left behind."""
    dest = tmp_path / "GelScribe"
    shutil.copytree(ROOT, dest, ignore=shutil.ignore_patterns(".venv", "__pycache__", ".pytest_cache", "python.txt",
                                                             "requirements.used", "GelScribe.lnk", ".DS_Store"))
    return dest


@posix_only
def test_the_launcher_sets_up_then_runs_a_command_where_it_was_typed(copy, gel, tmp_path):
    env = child_env(tmp_path / "home")
    env["PATH"] = str(Path(sys.executable).parent) + os.pathsep + env["PATH"]   # this Python has everything
    work = gel.parent
    r = subprocess.run([str(copy / "GelScribe.sh"), "new", gel.name, "-o", "first.gelscribe"], cwd=str(work),
                       capture_output=True, text=True, env=env, timeout=600)
    assert r.returncode == 0, r.stderr
    assert "Nothing was downloaded" in r.stderr and not (copy / ".venv").exists()
    assert Path(r.stdout.strip()) == (work / "first.gelscribe").resolve()   # a path relative to where it was typed
    assert Path((copy / "python.txt").read_text().strip()).parent == Path(sys.executable).parent
    # set up now: straight to the command, through the Mac's double-click file too and through a link
    link = tmp_path / "bin" / "gelscribe"
    link.parent.mkdir()
    link.symlink_to(copy / "GelScribe.sh")
    for launcher in (copy / "GelScribe.command", link):
        r = subprocess.run([str(launcher), "verify", "first.gelscribe"], cwd=str(work), capture_output=True,
                           text=True, env=env, timeout=120)
        assert r.returncode == 0 and r.stdout.startswith("intact:") and r.stderr == "", r.stderr


@posix_only
def test_the_launcher_starts_the_app_in_the_background_and_reports_a_failed_start(copy, gel, tmp_path):
    env = child_env(tmp_path / "home")
    (copy / "python.txt").write_text(sys.executable + "\n")
    shutil.copyfile(copy / "requirements.txt", copy / "requirements.used")
    env["QT_QPA_PLATFORM"] = "offscreen"
    marker = gel.parent / "for the launcher test.png"
    shutil.copyfile(gel, marker)
    started = time.monotonic()
    r = subprocess.run([str(copy / "GelScribe.sh"), str(marker)], capture_output=True, text=True, env=env,
                       timeout=60)
    assert r.returncode == 0 and time.monotonic() - started < 20, r.stderr
    found = subprocess.run(["pgrep", "-f", str(marker)], capture_output=True, text=True).stdout.split()
    assert found, "the app should still be running"
    for pid in found:
        os.kill(int(pid), 15)

    # a Python without Qt: the app can't start, and the terminal says why
    bare = tmp_path / "bare"
    subprocess.run([sys.executable, "-m", "venv", "--without-pip", str(bare)], check=True)
    (copy / "python.txt").write_text(str(bare / "bin" / "python") + "\n")
    r = subprocess.run([str(copy / "GelScribe.sh")], capture_output=True, text=True, env=env, timeout=60)
    assert r.returncode != 0 and "PySide6" in r.stderr and "didn't start" in r.stderr, r.stderr


# ---------------------------------------------------------------------------------------------------- several gels, version 2


@pytest.fixture
def second(tmp_path):
    """A second gel with the same lanes, 10% wider apart and 20 px further right."""
    h, w = 300, 720
    yy, xx = np.mgrid[0:h, 0:w]
    img = np.full((h, w), 235.0)
    for cx in LANES:
        img -= 190 * np.exp(-((yy - 120) / 4.0) ** 2 / 2) * (np.abs(xx - (1.1 * cx + 20)) < 24)
    path = tmp_path / "second gel.png"
    Image.fromarray(np.clip(img, 0, 255).round().astype(np.uint8)).save(path)
    return path


def test_the_line_between_gels_and_its_thickness_from_the_command_line(made, capsys):
    before = (made / "project.json").read_bytes()
    for args, message in [(["--separator", "grey"], "--separator wants black, white or a color like #ff3300"),
                          (["--separator", "#12"], "--separator wants"),
                          (["--separator-width", "11"], "--separator-width wants points from 0.25 to 10"),
                          (["--separator-width", "x"], "--separator-width wants points"),
                          (["--group-angle", "x"], "--group-angle wants an angle")]:
        code, _, err = run(capsys, "edit", made, *args)
        assert code == 1 and message in err and (made / "project.json").read_bytes() == before, args
    assert run(capsys, "edit", made, "--separator", "White", "--separator-width", "2.5")[0] == 0
    text = (made / "project.json").read_text()
    p = project(made)
    assert p.separator == "white" and p.separator_width == 2.5 and '"separator": "white"' in text
    assert run(capsys, "edit", made, "--separator", "f30")[0] == 0 and project(made).separator == "#ff3300"
    assert run(capsys, "edit", made, "--separator", "#000000")[0] == 0   # black is left out of the file
    assert '"separator"' not in (made / "project.json").read_text() and project(made).separator_width == 2.5
    assert "--separator black|white|#RRGGBB" in run(capsys, "help")[1] and "--separator-width PT" in run(capsys, "help")[1]


def test_gels_start_unstrict_each_has_its_own_strict_and_gel_1_moves(made, second, capsys):
    code, out, err = run(capsys, "edit", made, "--add-gel", second, "--gel", 2, "--align", "auto")
    assert code == 0, err
    p = project(made)
    assert p.strict and p.strips[0].strict is False and abs(p.strips[0].scale - 1.1) < 0.02   # stretched into line
    assert json.loads((made / "project.json").read_text())["strips"][0]["strict"] is False
    # --strict with --gel N is that gel's own; without it, the gel with the lanes'
    assert run(capsys, "edit", made, "--gel", 2, "--strict", "on")[0] == 0
    p = project(made)
    assert p.strips[0].strict is True and p.strict
    code, _, err = run(capsys, "edit", made, "--gel", 2, "--scale", 1.01)
    assert code == 1 and "--scale needs --strict off" in err
    code, _, err = run(capsys, "edit", made, "--gel", 2, "--rotate", 1)
    assert code == 1 and "--rotate needs --strict off" in err
    code, _, err = run(capsys, "edit", made, "--gel", 2, "--align", "auto")   # whole pixels now, and it says why stretching fits better
    assert code == 0 and project(made).strips[0].scale == 1 and "Turn off Keep original pixels for Gel 2 to stretch it." in err
    assert run(capsys, "edit", made, "--strict", "off")[0] == 0
    p = project(made)
    assert not p.strict and p.strips[0].strict is True   # the lanes gel's switch leaves the other as it was
    assert run(capsys, "edit", made, "--strict", "on", "--gel", 1)[0] == 0 and project(made).strict   # gel 1 is the lanes gel here
    # the gel with the lanes sits at its own place; nothing else moves
    gel2 = project(made).strips[0].shift
    assert run(capsys, "edit", made, "--shift", 12.6)[0] == 0
    p = project(made)
    assert p.main_shift == 13 and p.strips[0].shift == gel2 and '"main_shift": 13' in (made / "project.json").read_text()
    assert run(capsys, "edit", made, "--gel", 2, "--shift", 5)[0] == 0 and project(made).strips[0].shift == 5
    code, _, err = run(capsys, "edit", made, "--gel", 1, "--rows", "1,50")
    assert code == 1 and "move it with --shift" in err
    # auto-align lines gel 2 up with the lanes where gel 1 now sits
    assert run(capsys, "edit", made, "--shift", 0)[0] == 0
    assert run(capsys, "edit", made, "--gel", 2, "--strict", "off", "--align", "auto")[0] == 0
    lined = project(made).strips[0].shift
    assert run(capsys, "edit", made, "--shift", 25, "--gel", 2, "--align", "auto")[0] == 0   # (--shift with --gel is gel 2's)
    assert run(capsys, "edit", made, "--shift", 25)[0] == 0
    assert run(capsys, "edit", made, "--gel", 2, "--align", "auto")[0] == 0
    p = project(made)
    assert abs(p.strips[0].shift - (lined + p.strips[0].scale * 25)) < 0.5   # 25 more figure pixels of shift


def test_a_gel_has_its_own_crop_and_group_labels_their_own_angle_from_the_command_line(made, second, capsys):
    assert run(capsys, "edit", made, "--add-gel", second)[0] == 0
    code, _, err = run(capsys, "edit", made, "--gel", 2, "--crop", "fit")
    assert code == 1 and "--crop fit is for the gel with the lanes" in err
    code, _, err = run(capsys, "edit", made, "--gel", 2, "--crop", "300,10,100,50")
    assert code == 1 and "A crop must be X0,Y0,X1,Y1" in err
    assert run(capsys, "edit", made, "--gel", 2, "--crop", "20,30,500,250")[0] == 0
    s = project(made).strips[0]
    assert (s.left, s.top, s.right, s.bottom) == (20, 30, 500, 250)
    assert run(capsys, "edit", made, "--gel", 2, "--crop", "20,30,500,250", "--rows", "40,200")[0] == 0   # --rows still sets the rows
    assert (project(made).strips[0].top, project(made).strips[0].bottom) == (40, 200)
    assert run(capsys, "edit", made, "--crop", "10,10,590,400")[0] == 0   # without --gel: the lanes gel's crop, as before
    p = project(made)
    assert (p.crop.x0, p.crop.x1) == (10, 590) and p.strips[0].left == 20
    code, out, err = run(capsys, "render", made, "--formats", "png")   # and it renders: the figure spans the gels' columns
    assert code == 0, err
    assert Image.open(out.strip()).width >= 580
    # group labels
    assert run(capsys, "edit", made, "--group-angle", 405)[0] == 0   # every row of group labels, any angle, brought into 0 ..< 360
    p = project(made)
    assert [r.rotation for r in p.rows if r.type == "groups"] == [45.0] and [r.rotation for r in p.rows if r.type == "lanes"] == [0.0]
    assert '"rotation": 45' in (made / "project.json").read_text()
    code, out, _ = run(capsys, "new", made.parent / "blot.png", "-o", made.parent / "plain.gelscribe")   # no group labels: it says so
    code, _, err = run(capsys, "edit", out.strip(), "--group-angle", 45)
    assert code == 0 and "there are no group labels yet" in err
    assert "--group-angle DEG" in run(capsys, "help")[1]
