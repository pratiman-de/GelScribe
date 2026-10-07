"""gelscribe: GelScribe without a window, the same command-line tool as the Mac app's (without its MCP server).

    python -m gelscribe.cli COMMAND ...
    GelScribe.bat COMMAND ...      on Windows, through the Python GelScribe was set up with
    ./GelScribe.sh COMMAND ...     on a Mac or Linux, the same way

Only the output asked for goes to stdout, so it can be piped; messages and warnings go to stderr. Exit status: 0 done,
1 failed, 2 a usage mistake."""
from __future__ import annotations

import hashlib
import json
import math
import os
import re
import sys
import traceback
from pathlib import Path
from typing import Optional

from . import __version__

COMMANDS = ("new", "edit", "render", "detect", "presets", "verify")
HELP = ("help", "-h", "--help")
FORMATS = ("pdf", "png", "tiff", "tif", "svg")
MARKERS = ("arrow", "tick", "bracket", "none")

USAGE = """\
usage:
  gelscribe new IMAGE [-o OUT.gelscribe]      make a project around an image (original copied byte-for-byte)
  gelscribe render PROJECT [-o STEM] [--formats pdf,png,tiff,svg] [--dpi N|native]   (other than native resamples the gel)
  gelscribe edit PROJECT [--dividers X,X,…] [--auto-lanes N] [--labels "µM: ladder|0{L|P}|50{L|P}|…"]
                [--row-name µM] [--preset ID] [--system GEL] [--ticks Y,Y,…] [--no-snap] [--name TEXT@Y[:arrow|tick|none]]…
                [--title T] [--crop X0,Y0,X1,Y1|fit]   with --gel N: that gel's own crop (columns and rows in its own pixels)
                [--strict on|off]   keep original pixels: for the gel with the lanes, or for gel N with --gel N (each gel has its own;
                                      a gel that doesn't is stretched, rotated and takes its brightness & contrast into exports)
                [--separator black|white|#RRGGBB]   the colour of the line between stacked gels (a gray figure takes its brightness)
                [--separator-width PT]   how thick that line is, 0.25 to 10 points (without it, as thick as the figure's lines)
                [--label-angle DEG]   stand the lane labels at an angle: 0 flat, 90 straight up, any angle to 360; other text stays flat
                [--group-angle DEG]   the same for every row of group labels (the labels over several lanes); underlines stay flat
                [--rotate DEG] [--fill background|white|0-255]   (rotation and fill need --strict off for that gel)
                [--scheme-from PROJECT [--with-positions]]      reuse another gel's labels, names, ladder, type
                [--turn 90|180|270]   (a lossless quarter or half turn, for a scan made the wrong way round)
                [--add-gel IMAGE]…    another gel (or piece of a cut membrane), stacked at the bottom with a line above; it
                                      starts with --strict off, so --align auto can stretch it into line
                [--remove-gel N] [--order N,N,…]   take gel N out; stack the gels in this order (numbers from the top)
                [--shift PX]          where the gel with the lanes sits sideways in the figure (whole pixels; its lane dividers, labels,
                                      ticks and names go with it, and no other gel moves); with --gel N, where gel N sits
                [--gel N [--rows Y0,Y1] [--scale S] [--align auto]]   gel N, counted from the top: its rows, and lining
                                      its lanes up wherever the gel with the lanes sits; --crop, --shift, --ticks, --name, --rotate,
                                      --turn and --strict then apply to it
                [--own-ladder on|off]   the gel's ladder sizes start again from the top of the list instead of carrying
                                      on from the gel above (the gel with the lanes, or gel N with --gel N)
                [--file-names on|off]   whether exported files carry each gel's file name (off: the SHA-256 fingerprints stay)
  gelscribe detect IMAGE [--lanes N]          suggest lanes and ladder bands (JSON)
  gelscribe presets                           list ladder presets
  gelscribe verify PROJECT                    check the images still match their recorded SHA-256

Positions are image pixels from the top-left corner, x to the right and y down (in the rotated image once
--strict is off). render writes STEM.pdf, STEM.png, …; without -o, next to the project as NAME.figure.pdf, ….
"""


class UsageError(Exception):
    pass


class CommandError(Exception):
    pass


def say(text: str) -> None:
    print(text, file=sys.stderr, flush=True)


def warn(text: str) -> None:
    say(f"warning: {text}")


# ---------------------------------------------------------------------------------------------------- arguments


class Args:
    """The Mac tool's way: an option takes the next word as its value, even one starting with - (--rotate -2.5),
    and options can come before or after the file, in any order."""

    def __init__(self, words: list[str]):
        self.words = list(words)

    def option(self, name: str) -> Optional[str]:
        if name not in self.words:
            return None
        i = self.words.index(name)
        if i + 1 >= len(self.words):
            raise UsageError(f"{name} needs a value")
        value = self.words[i + 1]
        del self.words[i:i + 2]
        if name in self.words:
            raise UsageError(f"{name} was given twice")
        return value

    def options(self, name: str) -> list[str]:
        out = []
        while name in self.words:
            i = self.words.index(name)
            if i + 1 >= len(self.words):
                raise UsageError(f"{name} needs a value")
            out.append(self.words[i + 1])
            del self.words[i:i + 2]
        return out

    def flag(self, name: str) -> bool:
        found = name in self.words
        self.words = [w for w in self.words if w != name]
        return found

    def nothing_else(self) -> None:
        if self.words:
            raise UsageError(f"unexpected {self.words[0]}")

    def file(self, what: str) -> str:
        """The one file the command works on, once its options are taken out."""
        for w in self.words:
            if w.startswith("-") and len(w) > 1:
                raise UsageError(f"unknown option {w}")
        if not self.words:
            raise UsageError(f"which {what}?")
        if len(self.words) > 1:
            raise UsageError(f"one {what} at a time (also got {self.words[1]})")
        return self.words[0]


def number(text: str, message: str) -> float:
    try:
        v = float(text)
    except ValueError:
        raise CommandError(message) from None
    if not math.isfinite(v):
        raise CommandError(message)
    return v


def numbers(text: str, message: str) -> list[float]:
    return [number(t, message) for t in text.split(",") if t.strip()]


def whole(text: str, message: str) -> int:
    if not re.fullmatch(r"[+-]?[0-9]+", text.strip()):
        raise CommandError(message)
    return int(text)


def on_off(name: str, text: Optional[str]) -> Optional[bool]:
    """on or off, in any letter case; anything else is a mistake."""
    if text is None:
        return None
    if text.lower() not in ("on", "off"):
        raise CommandError(f"{name} wants on or off")
    return text.lower() == "on"


def num(v: float):
    """A JSON number: 60 rather than 60.0."""
    v = float(v)
    return int(v) if v.is_integer() else v


def plural(n: int, word: str) -> str:
    return f"{n} {word}" + ("" if n == 1 else "s")


def gui() -> None:
    """Text is measured with Qt, which needs a GUI application object (no window is shown). Off-screen on a Mac and
    Linux, so there's no Dock icon and no display is needed; on Windows the usual platform, so text is measured exactly
    as in the app."""
    if sys.platform != "win32":
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    from PySide6.QtGui import QGuiApplication
    global _app
    _app = QGuiApplication.instance() or QGuiApplication(["gelscribe"])


_app = None


def read_project(path: Path):
    from .core.package import GelPackage
    if not path.exists():
        raise CommandError(f"{path}: no such project")
    return GelPackage.read(path)


def project_folder(path: Path) -> Optional[Path]:
    """The .gelscribe folder, or None for a bare JSON config."""
    from .core.package import PROJECT_FILE
    if path.is_dir():
        return path
    return path.parent if path.name == PROJECT_FILE else None


def is_package(path: Path) -> bool:
    """A .gelscribe project (a folder, or the project.json inside one; the extension in any letter case), as opposed to a
    bare JSON config that sits next to its image."""
    from .core.package import EXTENSION
    folder = project_folder(path)
    return folder is not None and (path.is_dir() or folder.suffix.lower() == EXTENSION)


def write_atomically(dest: Path, data: bytes) -> None:
    tmp = dest.with_name(dest.name + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, dest)


# ---------------------------------------------------------------------------------------------------- commands


def cmd_new(a: Args) -> int:
    from .core.package import EXTENSION, GelPackage
    out = a.option("-o")
    image = Path(a.file("IMAGE"))
    pkg = GelPackage.create(image.read_bytes(), image.name)
    dest = Path(out) if out else image.with_suffix(EXTENSION)
    if dest.exists() and (not dest.is_dir() or any(dest.iterdir())):   # an empty folder is fine to fill
        raise CommandError(f"{dest} already exists; delete it or choose another name with -o")
    pkg.write(dest)
    print(os.path.abspath(dest))
    return 0


def cmd_render(a: Args) -> int:
    stem = a.option("-o")
    formats_text = a.option("--formats")
    dpi_text = a.option("--dpi")
    path = Path(a.file("PROJECT"))
    formats = [f.strip().lower() for f in (formats_text or "pdf,png,svg").split(",") if f.strip()]
    unknown = [f for f in formats if f not in FORMATS]
    if unknown:
        raise CommandError(f"unknown format {unknown[0]} (pdf, png, tiff or svg)")
    if not formats:
        raise CommandError("--formats is empty")
    requested = None
    if dpi_text is not None and dpi_text != "native":
        requested = number(dpi_text, "--dpi wants a number or native")
        if not 1 <= requested <= 10_000:
            raise CommandError("--dpi wants a number from 1 to 10000, or native")
    pkg = read_project(path)
    p = pkg.project
    folder = project_folder(path)
    base = stem if stem else str((folder or path).resolve().with_suffix(".figure"))
    targets = [Path(f"{base}.{f}") for f in formats]
    original = {p.image_sha256, hashlib.sha256(pkg.image_data).hexdigest()}
    original |= {hashlib.sha256(d).hexdigest() for d in pkg.strip_images.values()}
    for dest in targets:   # before anything is written
        d = dest.resolve()
        if folder is not None and folder.resolve() in d.parents:
            raise CommandError(f"won't write {dest} inside the project")
        if d.is_dir():
            raise CommandError(f"{dest} is a folder")
        if d.is_file() and hashlib.sha256(d.read_bytes()).hexdigest() in original:
            raise CommandError(f"won't overwrite {dest}: it's the original image")

    gui()
    from .core import render, strips
    from .core.image import SourceImage, WorkingImage
    from .core.model import sround
    src = SourceImage(pkg.image_data)
    fig = strips.StackedFigure(p, WorkingImage(src, p), strips.strip_images(pkg))   # a gel that can't be read stops here
    if fig.strict_problem:
        raise CommandError(f"The gels that keep their original pixels must be stored the same way, but {fig.strict_problem}. "
                           "Turn it off for a gel (edit --strict off --gel N) to export it.")
    for line in fig.changed_warnings():   # the figure still goes ahead; its note starts with these lines too
        say(line)
    lay = fig.layout
    if dpi_text is None:
        requested = p.style.export_dpi
    dpi = render.resample_dpi(requested, lay)
    native = render.native_dpi(lay)
    if dpi is not None and any(f in ("png", "tiff", "tif") for f in formats):
        say(f"PNG/TIFF at {int(dpi)} dpi: the gel is resampled (native is {int(sround(native))} dpi)")
    made = []   # every file is made before the first is written: a figure too large to make leaves nothing behind
    with render.figure_memory():
        gel = fig.gel
        info = fig.info()
        raster_info = fig.info(dpi)
        for f, dest in zip(formats, targets):
            if f == "pdf":
                data = render.pdf(lay, gel, info)
            elif f == "svg":
                data = render.svg(lay, gel, info).encode("utf-8")
            else:
                data = render.raster_data(lay, gel, "png" if f == "png" else "tiff", raster_info, dpi)
            made.append((dest, data))
    for dest, data in made:
        write_atomically(dest, data)
        print(os.path.abspath(dest))
    return 0


def parse_name(text: str) -> tuple[str, float, str]:
    """TEXT@Y[:marker], split at the last @ so a name may contain one."""
    at = text.rfind("@")
    if at < 0:
        raise CommandError("--name wants TEXT@Y")
    rest = [t for t in text[at + 1:].split(":") if t]
    if not rest:
        raise CommandError("--name wants TEXT@Y")
    y = number(rest[0], "--name wants TEXT@Y")
    marker = rest[1] if len(rest) > 1 else "arrow"
    if marker not in MARKERS:
        raise CommandError(f"--name: the marker is arrow, tick, bracket or none, not {marker}")
    return text[:at], y, marker


def no_such_system(preset, key: str) -> CommandError:
    return CommandError(f"{preset.name} has no gel system matching {key}: " + "; ".join(s.name for s in preset.systems))


def cmd_edit(a: Args) -> int:
    dividers = a.option("--dividers")
    auto_lanes = a.option("--auto-lanes")
    labels = a.option("--labels")
    row_name = a.option("--row-name")
    preset_id = a.option("--preset")
    system_key = a.option("--system")
    ticks = a.option("--ticks")
    title = a.option("--title")
    crop = a.option("--crop")
    strict = a.option("--strict")
    scheme_from = a.option("--scheme-from")
    rotate = a.option("--rotate")
    fill = a.option("--fill")
    names = a.options("--name")
    turn_text = a.option("--turn")
    add_gels = a.options("--add-gel")
    remove_text = a.option("--remove-gel")
    order_text = a.option("--order")
    gel_text = a.option("--gel")
    rows_text = a.option("--rows")
    shift_text = a.option("--shift")
    scale_text = a.option("--scale")
    align = a.option("--align")
    own_text = a.option("--own-ladder")
    file_names_text = a.option("--file-names")
    separator = a.option("--separator")
    separator_width_text = a.option("--separator-width")
    group_angle_text = a.option("--group-angle")
    angle_text = a.option("--label-angle")
    with_positions = a.flag("--with-positions")
    snap = not a.flag("--no-snap")
    path = Path(a.file("PROJECT"))
    if with_positions and scheme_from is None:
        raise UsageError("--with-positions goes with --scheme-from")

    from .core import detect, ladders, ops, strips as stacked
    from .core.image import ImageError, SourceImage, WorkingImage
    from .core.model import GelProject, Ladder, PixelRect, Sane, format_size, parse_separator, sround
    from .core.package import is_gelscribe_folder, names_in
    from .core.scheme import LabelScheme

    # every value is checked before anything changes, so a mistake leaves the project as it was
    strict_on = on_off("--strict", strict)
    own_on = on_off("--own-ladder", own_text)
    file_names = on_off("--file-names", file_names_text)
    if separator is not None:
        colour = parse_separator(separator)
        if colour is None:
            raise CommandError("--separator wants black, white or a color like #ff3300")
        separator = colour
    separator_width = None
    if separator_width_text is not None:
        separator_width = number(separator_width_text, "--separator-width wants points from 0.25 to 10, e.g. --separator-width 2")
        if not GelProject.SEPARATOR_WIDTHS[0] <= separator_width <= GelProject.SEPARATOR_WIDTHS[1]:
            raise CommandError("--separator-width wants points from 0.25 to 10, e.g. --separator-width 2")
    group_angle = None
    if group_angle_text is not None:
        group_angle = number(group_angle_text, "--group-angle wants an angle in degrees, e.g. --group-angle 45")
        if not math.isfinite(group_angle):
            raise CommandError("--group-angle wants an angle in degrees, e.g. --group-angle 45")
    label_angle = None
    if angle_text is not None:
        label_angle = number(angle_text, "--label-angle wants an angle in degrees, e.g. --label-angle 45")
        if not math.isfinite(label_angle):
            raise CommandError("--label-angle wants an angle in degrees, e.g. --label-angle 45")
    degrees = None
    if rotate is not None:
        degrees = number(rotate, "--rotate wants degrees, e.g. --rotate -2.4")
        if abs(degrees) > 360:
            raise CommandError("--rotate wants degrees between -360 and 360")
    if fill is not None and fill not in ("background", "white"):
        level = number(fill, "--fill wants background, white or 0-255") if fill else -1
        if not 0 <= level <= 255:
            raise CommandError("--fill wants background, white or 0-255")
    lane_count = None
    if auto_lanes is not None:
        lane_count = whole(auto_lanes, "--auto-lanes wants the number of lanes")
        if not 2 <= lane_count <= Sane.lanes:
            raise CommandError(f"--auto-lanes wants 2 to {Sane.lanes} lanes")
    box = None
    if crop is not None and crop != "fit":
        box = numbers(crop, "--crop wants X0,Y0,X1,Y1 or fit")
        if len(box) != 4:
            raise CommandError("--crop wants X0,Y0,X1,Y1 or fit")
    xs = numbers(dividers, "--dividers wants X,X,…") if dividers is not None else None
    ys = numbers(ticks, "--ticks wants rows like 60,110,170") if ticks is not None else []
    preset = None
    if preset_id is not None:
        preset = ladders.find(preset_id) if preset_id.strip() else None
        if preset is None:
            raise CommandError(f"unknown preset {preset_id}; see `gelscribe presets`")
    system = None
    if preset is not None and system_key is not None:
        system = preset.system(system_key)
        if system is None:
            raise no_such_system(preset, system_key)
    marks = [parse_name(n) for n in names]
    quarter = None
    if turn_text is not None:
        d = whole(turn_text, "--turn wants 90, 180 or 270")
        if d not in (90, 180, 270):
            raise CommandError("--turn wants 90, 180 or 270")
        quarter = d // 90
    remove_n = whole(remove_text, "--remove-gel wants a gel number (1 is the top one)") if remove_text is not None else None
    gel_n = whole(gel_text, "--gel wants a gel number (1 is the top one)") if gel_text is not None else None
    for n, option in ((remove_n, "--remove-gel"), (gel_n, "--gel")):
        if n is not None and n < 1:
            raise CommandError(f"{option} wants a gel number (1 is the top one)")
    order = None
    if order_text is not None:
        order = [whole(t.strip(), "--order wants gel numbers, e.g. 2,1") for t in order_text.split(",") if t.strip()]
    rows = None
    if rows_text is not None:
        rows = numbers(rows_text, "--rows wants Y0,Y1")
        if len(rows) != 2:
            raise CommandError("--rows wants Y0,Y1")
    shift = None
    if shift_text is not None:
        shift = number(shift_text, "--shift wants pixels")
        if abs(shift) > Sane.coordinate:
            raise CommandError("--shift wants pixels")
    stretch = None
    if scale_text is not None:
        stretch = number(scale_text, "--scale wants a number from 0.5 to 2, e.g. 1.02")
        if not 0.5 <= stretch <= 2:
            raise CommandError("--scale wants a number from 0.5 to 2, e.g. 1.02")
    if align is not None:
        if align.lower() != "auto":
            raise CommandError("--align wants auto")
        align = "auto"   # in any letter case
    new_gels = []
    for f in add_gels:
        if not Path(f).is_file():
            raise CommandError(f"{f}: no such image")
        new_gels.append(Path(f))

    pkg = read_project(path)
    p = pkg.project
    if new_gels and not is_package(path):
        raise CommandError("Gels can only be added to a .gelscribe project.")
    other = read_project(Path(scheme_from)) if scheme_from is not None else None
    folder = project_folder(path)
    taken = names_in(folder) if folder is not None else []
    for f in new_gels:   # under names that clash with nothing in the project or its folder, whatever the letter case
        try:
            pkg.add_strip(f.read_bytes(), f.name, taken)
        except ImageError as e:
            raise CommandError(f"{f}: {e}") from None
        taken.append(p.strips[-1].image)

    def gel(n: int):
        """Gel n, counted from the top, as its number in strips; None = the gel with the lanes."""
        order_now = p.stack_order
        if not 1 <= n <= len(order_now):
            raise CommandError(f"there's no gel {n}: the figure has {len(order_now)}")
        return order_now[n - 1]

    removed = None
    if remove_n is not None:
        k = gel(remove_n)
        if k is None:
            raise CommandError(f"gel {remove_n} has the lanes every gel uses, so it can't be taken out")
        removed = pkg.remove_strip(k)   # the name of its copy to delete from the folder, if nothing else uses it
    if order is not None:
        n = len(p.stack_order)
        if len(order) != n or set(order) != set(range(1, n + 1)):
            raise CommandError(f"--order wants each gel number from 1 to {n} once, top first")
        ops.reorder(p, [i - 1 for i in order])
    strip = gel(gel_n) if gel_n is not None else None
    if crop == "fit" and gel_n is not None and strip is not None:
        raise CommandError(f"--crop fit is for the gel with the lanes; give gel {gel_n} its crop as X0,Y0,X1,Y1")
    if rows is not None or stretch is not None or align is not None:
        if gel_n is None:
            raise CommandError("--rows, --scale and --align are for one of the stacked gels: say which with --gel N")
        if strip is None:
            raise CommandError(f"gel {gel_n} has the lanes, so it isn't lined up with anything; crop it with --crop, "
                               "or move it with --shift")
    strict_after = p.is_strict(strip) if strict_on is None else strict_on   # the gel these options are about
    if stretch is not None and strict_after and stretch != 1:
        raise CommandError("--scale needs --strict off (stretching resamples the gel)")
    if degrees is not None and strict_after:
        raise CommandError("--rotate needs --strict off (rotating resamples the gel)")

    # the gels' images, each decoded once; a gel whose image can't be read is None, and fails only what needs its pixels
    sources: dict = {}
    src = SourceImage(pkg.image_data)

    def strip_source(k: int) -> Optional[SourceImage]:
        name = p.strips[k - 1].image
        if name not in sources:
            try:
                data = pkg.strip_data(k)
                sources[name] = SourceImage(data) if data is not None else None
            except ImageError:
                sources[name] = None
        return sources[name]

    def strip_size(k: int) -> Optional[tuple[int, int]]:
        """Gel k's working image size, after its quarter turns (rotation keeps the canvas)."""
        s = strip_source(k)
        if s is None:
            return None
        return (s.width, s.height) if p.strips[k - 1].turn % 2 == 0 else (s.height, s.width)

    def strip_work(k: int) -> WorkingImage:
        s = strip_source(k)
        if s is None:
            raise CommandError(stacked.unreadable_message(p, k))
        return WorkingImage(s, p.strip_project(k))

    def main_size() -> tuple[int, int]:
        """The working image size of the gel with the lanes, after its quarter turns."""
        return (src.width, src.height) if p.turn % 2 == 0 else (src.height, src.width)

    def gel_size(k: Optional[int]) -> tuple[int, int]:
        """The working image size of gel k, which has to be readable (None = the gel with the lanes)."""
        if k is None:
            return main_size()
        size = strip_size(k)
        if size is None:
            raise CommandError(stacked.unreadable_message(p, k))
        return size

    if strip is not None and quarter:   # its own settings, before anything reads its pixels
        ops.turn(p, strip, quarter, *gel_size(strip))
    if strip is None and quarter:
        ops.turn(p, None, quarter, *main_size())
    w0, h0 = main_size()
    sizes = [strip_size(k + 1) for k in range(len(p.strips))]
    p.normalize((w0, h0), sizes)   # rows that can't be used mean the whole gel; marks outside their gel move inside it
    if separator is not None:
        p.separator = separator
    if separator_width is not None:
        p.separator_width = separator_width
    # Strict first: what rotation, scaling and fill may do depends on it, whatever order they were typed in
    if strict_on is not None:
        for k, size in enumerate(sizes, 1):   # every gel must open: its marks follow if its rotation applies or stops
            if size is None:
                raise CommandError(stacked.unreadable_message(p, k))
        ops.set_strict(p, strict_on, w0, h0, sizes, strip)
    if degrees is not None:
        if strip is not None:
            ops.set_strip_rotation(p, strip, degrees, *gel_size(strip))
        else:
            ops.set_rotation(p, degrees, w0, h0)
    if strip is not None:
        s = p.strips[strip - 1]
        if box is not None:   # gel N's own crop: its columns and rows, in its own pixels (--rows below can still set the rows)
            gw, gh = gel_size(strip)
            if not ops.set_strip_crop(p, strip, box[0], box[1], box[2], box[3], gw, gh):
                raise CommandError(ops.crop_message(gw, gh))
        if rows is not None:
            height = gel_size(strip)[1]
            if not ops.set_strip_rows(p, strip, rows[0], rows[1], height):
                raise CommandError(ops.rows_message(height))
        if shift is not None:
            s.shift = shift   # its place in the figure
        if stretch is not None:
            s.scale = stretch
    if shift is not None and strip is None:
        p.main_shift = float(sround(shift))   # the gel with the lanes, whole pixels
    if fill is not None:
        if fill in ("background", "white"):
            p.fill_mode = fill
        else:
            p.fill_mode, p.fill_value = "custom", float(fill) / 255
    if other is not None:
        LabelScheme.of(other.project, with_positions).apply(p, w0, h0)
    if own_on is not None:
        ops.set_own_ladder(p, strip, own_on)
    if file_names is not None:
        p.export_file_names = file_names
    w, h = w0, h0   # rotation keeps the canvas

    def work_image() -> WorkingImage:   # the gel with the lanes as detection sees it, once everything that changes it is set
        if not worked:
            worked.append(WorkingImage(src, p))
        return worked[0]

    worked: list = []
    if box is not None and strip is None:
        r = PixelRect(*box).normalized(w, h)
        if min(box[0], box[2]) >= w or min(box[1], box[3]) >= h or max(box[0], box[2]) <= 0 or max(box[1], box[3]) <= 0:
            raise CommandError(f"--crop is outside the {w}×{h} image")
        p.crop = r
    if xs is not None:
        if any(not 0 <= x <= w for x in xs):
            raise CommandError(f"--dividers wants positions inside the image (0–{w})")
        if xs:
            ops.set_dividers(p, xs, w, h)
        else:
            p.lanes.dividers, p.lanes.centers = [], []
    elif lane_count is not None:
        if len(ops.auto_dividers(p, work_image(), lane_count).centers) < 2:
            warn(f"couldn't find {lane_count} lanes; place them with --dividers")
    if labels is not None:
        for text in ops.apply_quick_labels(p, labels, group_row_name=row_name).warnings:
            warn(text)
    elif row_name is not None:
        groups = [r for r in p.rows if r.type == "groups"]
        if not groups:
            raise CommandError("--row-name needs a row of group labels; type them with --labels")
        groups[0].name = row_name   # the row nearest the lanes, as --labels names it
    if label_angle is not None and not ops.set_label_angle(p, label_angle):   # after --scheme-from and --labels
        warn("there are no lane labels yet, so the angle wasn't stored; type them with --labels")
    if group_angle is not None:
        group_rows = [i for i, r in enumerate(p.rows) if r.type == "groups"]
        for i in group_rows:
            ops.set_row_angle(p, i, group_angle)
        if not group_rows:
            warn("there are no group labels yet, so the angle wasn't stored; type them with --labels")
    # gel N's working image, after its turn and rotation, for lining up, ticks and names
    sw = strip_work(strip) if strip is not None and (align == "auto" or ys) else None
    if align == "auto":
        s = p.strips[strip - 1]
        keep = p.is_strict(strip)
        r, hint = stacked.align_gel(p, strip, sw)
        if r.alignment is None:
            if len(p.lanes.centers) < 2:
                raise CommandError(f"couldn't line gel {gel_n} up: place the lane dividers first, then try again")
            raise CommandError(r.message(gel_n, keep))   # the same words as the Mac's
        ops.align_strip(p, strip, r.alignment.shift, r.alignment.scale)   # the fit is to the lanes wherever gel 1 sits
        say(f"gel {gel_n}: shift {format_size(s.shift)} px, scale {format_size(r.alignment.scale)}; "
            f"the worst lane is {format_size(r.alignment.worst)} px off")
        if hint:
            say(hint)

    def in_gel(y: float, option: str) -> float:
        """The row for a tick or name on the gel --gel names: an error outside its image, and moved to the nearest row the
        figure shows (with a warning) when a crop or its rows leave that out."""
        gw, gh = gel_size(strip)
        n = p.position_of(strip) + 1
        if not 0 <= y <= gh:
            raise CommandError(f"{option}: {num(y)} is outside gel {n} (rows 0–{gh})")
        z = p.clamp_y(y, strip, gw, gh)
        if z != y:
            warn(f"{option}: {num(y)} is outside the rows gel {n} shows; moved to {num(z)}")
        return z

    if ys:
        lane = p.ladder.lane if p.ladder else 1
        centers = p.lanes.centers
        if snap and lane > len(centers):
            warn("no lanes yet, so the ticks weren't snapped to bands")
        c = p.effective_crop(w, h)
        if sw is not None:
            dark = sw.darkness(p.strips[strip - 1].display.bands_dark)
            cx = ops.lane_x(p, lane, strip)
            width = (p.lanes.width if p.lanes.width > 0 else 100) * p.effective_alignment(strip)[1]
        else:
            dark = work_image().darkness(p.display.bands_dark)
            cx = centers[lane - 1] if lane <= len(centers) else None
            width = p.lanes.width if p.lanes.width > 0 else 100
        gw, gh = gel_size(strip)
        for y in sorted(in_gel(y, "--ticks") for y in ys):   # top down, so each takes the next size from the ladder's list
            if snap and cx is not None:
                s = detect.snap_band(dark, cx, y, width)
                y = p.clamp_y(s, strip, gw, gh) if s is not None else y   # a snap never leaves the rows the figure shows
            size = ops.suggested_size(p, y, None, strip) if preset is None else None   # --preset sizes them all below
            ops.add_tick(p, y, size, True, lane, (c.x0 + c.x1) / 2, strip)
    if preset is not None:
        if system is not None:
            if p.ladder is None:
                p.ladder = Ladder()
            p.ladder.system = system.name
        ops.apply_preset(p, preset)
    elif system_key is not None:
        current = ladders.find_by_display_name(p.ladder.name) if p.ladder else None
        if current is None:
            raise CommandError("--system goes with --preset (this project has no ladder preset yet)")
        system = current.system(system_key)
        if system is None:
            raise no_such_system(current, system_key)
        ops.apply_system(p, current, system)
    for text, y, marker in marks:
        ops.add_annotation(p, text, in_gel(y, "--name"), marker, strip=strip)
    if title is not None:
        p.title = title or None
    if crop == "fit":
        p.crop = ops.suggest_crop(p, w, h)
    p.sync_lane_centers(w, h)

    changed = any(v is not None for v in (dividers, auto_lanes, labels, row_name, preset_id, system_key, ticks, title,
                                          crop, strict, scheme_from, rotate, fill, turn_text, remove_text, order_text,
                                          rows_text, shift_text, scale_text, align, own_text, file_names_text, angle_text, separator, separator_width_text,
                                          group_angle_text)) or bool(names) or bool(add_gels)
    if changed:
        if folder is not None:
            pkg.write(folder)
            # the copy GelScribe made of a gel that was taken out (the original file elsewhere is untouched); remove_strip
            # only names it when no other image in the project is stored under that name, in any letter case
            if removed and is_gelscribe_folder(folder):   # in any other folder the images are the user's own
                try:
                    (folder / removed).unlink()
                except OSError:
                    pass
        else:   # a bare JSON config next to its image
            write_atomically(path, (p.dumps() + "\n").encode("utf-8"))
    ladder_ticks = len(p.ladder.bands) if p.ladder else 0
    print(f"{plural(p.lane_count, 'lane')}, {plural(ladder_ticks, 'tick')}, {plural(len(p.annotations), 'name')}"
          + (f", {plural(len(p.strips) + 1, 'gel')}" if p.strips else ""))
    return 0


def cmd_detect(a: Args) -> int:
    from .core import detect
    from .core.image import SourceImage, WorkingImage
    from .core.model import GelProject, Sane
    lanes_text = a.option("--lanes")
    target = a.file("IMAGE")
    count = None
    if lanes_text is not None:
        count = whole(lanes_text, "--lanes wants the number of lanes")
        if not 2 <= count <= Sane.lanes:
            raise CommandError(f"--lanes wants 2 to {Sane.lanes} lanes")
    path = Path(target)
    if not path.exists():
        raise CommandError(f"{path}: no such file")
    data = read_project(path).image_data if project_folder(path) is not None else path.read_bytes()
    src = SourceImage(data)
    work = WorkingImage(src, GelProject(image=path.name))
    dark = work.darkness(True)
    fit = detect.lanes(dark, count)
    found = detect.bands(dark, fit.centers[0], fit.width) if fit.centers else []
    out = {"image": target, "width": work.width, "height": work.height, "pitch": num(fit.pitch),
           "lane_width": num(fit.width), "lane_centers": [num(c) for c in fit.centers],
           "lane1_bands": [{"y": num(b.y), "fwhm": num(b.fwhm), "prominence": num(b.prominence)} for b in found]}
    print(json.dumps(out, indent=2, sort_keys=True, ensure_ascii=False))
    return 0


def cmd_presets(a: Args) -> int:
    from .core import ladders
    from .core.model import format_size
    a.nothing_else()
    for p in ladders.all_presets():
        print(f"{p.id}\t{p.display_name}\t{p.unit}\t{' '.join(format_size(s) for s in p.sizes)}")
        for s in p.systems:
            print(f"  {s.id}\t{s.name}\t{' '.join(format_size(v) for v in s.sizes)}")
    return 0


def cmd_verify(a: Args) -> int:
    from .core import strips as stacked
    from .core.image import ImageError, SourceImage
    pkg = read_project(Path(a.file("PROJECT")))
    p = pkg.project
    checks = [(p.image, pkg.image_intact, pkg.image_data, None)]
    checks += [(s.image, pkg.strip_intact(i + 1), pkg.strip_data(i + 1), i + 1) for i, s in enumerate(p.strips)]
    changed, unreadable = [], None
    for name, intact, data, k in checks:
        if intact is None:
            print(f"no hash recorded for {name}")
        elif intact:
            print(f"intact: {name} matches its recorded SHA-256")
        else:
            changed.append(name)
        try:
            SourceImage(data)
        except ImageError:
            n = p.position_of(k) + 1
            bad = stacked.unreadable_message(p, k) if k is not None else f"Gel {n}'s image ({name}) can't be read."
            if unreadable is None or n < unreadable[0]:
                unreadable = (n, bad)
    if unreadable:
        raise CommandError(unreadable[1])
    if changed:
        raise CommandError(f"CHANGED: {', '.join(changed)} no longer match{'es' if len(changed) == 1 else ''} "
                           "the recorded SHA-256")
    return 0


RUN = {"new": cmd_new, "edit": cmd_edit, "render": cmd_render, "detect": cmd_detect, "presets": cmd_presets,
       "verify": cmd_verify}


def main(argv: Optional[list[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    for stream in (sys.stdout, sys.stderr):   # a name the console can't show comes out escaped, not as a crash
        try:
            stream.reconfigure(errors="backslashreplace")
        except (AttributeError, ValueError):
            pass
    if not argv:
        sys.stderr.write(USAGE)
        return 2
    cmd = argv[0]
    if cmd in HELP:
        sys.stdout.write(USAGE)
        return 0
    if cmd == "--version":
        print(f"gelscribe {__version__}")
        return 0
    if cmd not in RUN:
        sys.stderr.write(f"gelscribe: unknown command {cmd}\n{USAGE}")
        return 2
    from .core.image import ImageError
    from .core.package import ProjectError
    try:
        return RUN[cmd](Args(argv[1:]))
    except UsageError as e:
        sys.stderr.write(f"gelscribe {cmd}: {e}\n{USAGE}")
        return 2
    except (CommandError, ImageError, ProjectError) as e:
        say(f"gelscribe: {e}")
        return 1
    except OSError as e:
        say(f"gelscribe: {e.filename + ': ' if e.filename else ''}{e.strerror or e}")
        return 1
    except KeyboardInterrupt:
        return 130
    except (MemoryError, ValueError, ArithmeticError) as e:   # something the checks above didn't foresee: a line, not a traceback
        if os.environ.get("GELSCRIBE_DEBUG"):
            traceback.print_exc()
        say(f"gelscribe: {type(e).__name__}: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
