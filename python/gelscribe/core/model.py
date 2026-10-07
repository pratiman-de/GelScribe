"""The project model: one labelled gel figure, stored as project.json inside a .gelscribe package.

Reads and writes exactly what the Mac app does (same keys, defaults and omissions), so projects move freely between
the two. Every coordinate (lane centres, band y, crop) is in pixels of the working image: the original after
padding fill and rotation. Rotation keeps the canvas size, so coordinates stay put when the angle changes.

Strict mode (the default) means the figure carries the original pixels: same values, bit depth and colour space,
never resampled. Rotation, levels and padding fill then only affect the screen; cropping is allowed because it only
selects pixels.
"""
from __future__ import annotations

import copy
import json
import math
import re
from dataclasses import dataclass, field
from typing import Callable, NamedTuple, Optional


def sround(x: float) -> float:
    """Swift's `rounded()`: halves away from zero (Python's round() goes to even)."""
    return math.copysign(math.floor(abs(x) + 0.5), x)


# ---------------------------------------------------------------------------------------------------- reading JSON
#
# A project.json that was damaged or edited by hand must give a clear message, never a traceback: every value is
# checked as it's read (null counts as absent, as on the Mac), and what is finite but absurd is put right afterwards
# (GelProject.sanitize), so a later render can't be sent into an endless or enormous job.


def _num(v, what: str, default: Optional[float] = None) -> Optional[float]:
    """A finite number; null or absent gives the default."""
    if v is None:
        return default
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        raise ValueError(f"{what} should be a number")
    try:
        f = float(v)
    except OverflowError:
        raise ValueError(f"{what} is too large") from None
    if not math.isfinite(f):
        raise ValueError(f"{what} should be a finite number")
    return f


def _need_num(v, what: str) -> float:
    if v is None:
        raise ValueError(f"{what} is missing")
    return _num(v, what)


def _int(v, what: str, default: int = 0) -> int:
    if v is None:
        return default
    if isinstance(v, int) and not isinstance(v, bool):
        return v
    if isinstance(v, float) and math.isfinite(v) and v.is_integer():
        return int(v)
    raise ValueError(f"{what} should be a whole number")


def _text(v, what: str, default: str = "") -> str:
    if v is None:
        return default
    if not isinstance(v, str):
        raise ValueError(f"{what} should be text")
    return v


def _opt_text(v, what: str) -> Optional[str]:
    return None if v is None else _text(v, what)


def _flag(v, what: str, default: bool) -> bool:
    if v is None:
        return default
    if not isinstance(v, bool):
        raise ValueError(f"{what} should be true or false")
    return v


def _opt_flag(v, what: str) -> Optional[bool]:
    if v is None:
        return None
    if not isinstance(v, bool):
        raise ValueError(f"{what} should be true or false")
    return v


def _separator(v) -> str:
    """The line between gels from the project file: absent, or anything that isn't black, white or a color, is black."""
    return parse_separator(v) or "black"


def _separator_width(v) -> Optional[float]:
    """The line between gels' own thickness from the project file: anything that isn't a finite number follows the
    figure's lines (None); sanitize brings a number outside its range into it."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    try:
        f = float(v)
    except OverflowError:
        return None
    return f if math.isfinite(f) else None


def _choice(v, what: str, options: tuple, default: str) -> str:
    if v is None:
        return default
    if not isinstance(v, str) or v not in options:
        raise ValueError(f"{what} should be " + " or ".join(f'"{o}"' for o in options))
    return v


def _obj(v, what: str) -> dict:
    """An object, or {} when absent."""
    if v is None:
        return {}
    if not isinstance(v, dict):
        raise ValueError(f"{what} should be an object")
    return v


def _item(v, what: str) -> dict:
    """An object that has to be there (an entry of a list)."""
    if not isinstance(v, dict):
        raise ValueError(f"{what} should be an object")
    return v


def _list(v, what: str) -> list:
    if v is None:
        return []
    if not isinstance(v, list):
        raise ValueError(f"{what} should be a list")
    return v


class Sane:
    """What a project may hold: positions and sizes become whole-pixel counts and page sizes further down the line."""
    #: pixel positions, either way from the top-left corner
    coordinate = 1_000_000.0
    #: ladder sizes (kDa or bp)
    size = 1e12
    #: lane numbers in labels, groups and the ladder
    lanes = 4096
    #: label rows above the gel
    rows = 64


def _is_coordinate(v: float) -> bool:
    return math.isfinite(v) and abs(v) <= Sane.coordinate


def _is_size(v: float) -> bool:
    return math.isfinite(v) and 0 < v <= Sane.size


def _clamp(v: float, lo: float, hi: float, fallback: float) -> float:
    return min(max(v, lo), hi) if math.isfinite(v) else fallback


# ---------------------------------------------------------------------------------------------------- geometry


@dataclass
class PixelRect:
    """[x0, y0, x1, y1] in JSON, half-open."""
    x0: float
    y0: float
    x1: float
    y1: float

    @property
    def width(self) -> float:
        return self.x1 - self.x0

    @property
    def height(self) -> float:
        return self.y1 - self.y0

    def normalized(self, w: int, h: int) -> "PixelRect":
        """Clamped to an image, ordered, at least 8 px each way."""
        x0, x1 = min(self.x0, self.x1), max(self.x0, self.x1)
        y0, y1 = min(self.y0, self.y1), max(self.y0, self.y1)
        x0 = max(0.0, min(x0, w - 8.0))
        y0 = max(0.0, min(y0, h - 8.0))
        x1 = min(float(w), max(x1, x0 + 8))
        y1 = min(float(h), max(y1, y0 + 8))
        return PixelRect(x0, y0, x1, y1)

    def to_json(self):
        return [self.x0, self.y0, self.x1, self.y1]

    @staticmethod
    def from_json(v, what: str = "crop") -> "PixelRect":
        if not isinstance(v, list) or len(v) != 4:
            raise ValueError(f"{what} should be four numbers: x0, y0, x1, y1")
        return PixelRect(*(_need_num(x, f"{what}[{i}]") for i, x in enumerate(v)))


# ---------------------------------------------------------------------------------------------------- display


@dataclass
class ValueScale:
    """How a file's stored values relate to the 0…1 gray GelScribe works in, so brightness & contrast can be shown in
    the file's own numbers (0–65535 for 16-bit, 0–255 for 8-bit), as in ImageJ."""
    max_value: float = 255.0
    #: stored white-is-zero (TIFF photometric 0, ImageJ's inverting LUT): gray = 1 − value / max
    inverted: bool = False

    def value(self, gray: float) -> float:
        return ((1 - gray) if self.inverted else gray) * self.max_value

    def gray(self, value: float) -> float:
        return 1 - value / self.max_value if self.inverted else value / self.max_value

    def format(self, v: float) -> str:
        return str(int(sround(v))) if self.max_value > 1 else f"{v:.3f}"


@dataclass
class DisplaySettings:
    """How pixel values map to gray on screen and (Strict off) in exports. Levels are on the 0…1 scale of the
    source's full range. In Strict mode they change the screen only, like ImageJ's display range before Apply."""
    black: float = 0.0
    white: float = 1.0
    gamma: float = 1.0
    invert: bool = False
    #: bands darker than background (stained gels, inverted fluorescence); used for snapping only
    bands_dark: bool = True

    @property
    def is_identity(self) -> bool:
        return self.black == 0 and self.white == 1 and self.gamma == 1 and not self.invert

    def range_in(self, s: ValueScale) -> tuple[float, float]:
        """The display range in the file's own numbers, as ImageJ shows it."""
        if s.inverted:
            return (1 - self.white) * s.max_value, (1 - self.black) * s.max_value
        return self.black * s.max_value, self.white * s.max_value

    def set_range(self, lo: float, hi: float, s: ValueScale) -> None:
        a, b = s.gray(lo), s.gray(hi)
        self.black = min(a, b)
        self.white = max(max(a, b), self.black + 1 / s.max_value)

    def brightness(self, data: tuple[float, float]) -> float:
        """ImageJ-like brightness, −1…1 across the gel's own values; positive is brighter on screen."""
        dw = max(data[1] - data[0], 1e-9)
        return min(1.0, max(-1.0, ((data[0] + data[1]) / 2 - (self.black + self.white) / 2) / dw))

    def set_brightness(self, b: float, data: tuple[float, float]) -> None:
        dw = max(data[1] - data[0], 1e-9)
        w = self.white - self.black
        c = (data[0] + data[1]) / 2 - b * dw
        self.black, self.white = c - w / 2, c + w / 2

    def contrast(self, data: tuple[float, float]) -> float:
        """−1…1: 0 spans the gel's own values, positive narrows the window (up to 16×)."""
        dw = max(data[1] - data[0], 1e-9)
        w = max(self.white - self.black, 1e-9)
        return min(1.0, max(-1.0, -math.log2(w / dw) / 4))

    def set_contrast(self, k: float, data: tuple[float, float]) -> None:
        dw = max(data[1] - data[0], 1e-9)
        c = (self.black + self.white) / 2
        w = dw * 2 ** (-4 * k)
        self.black, self.white = c - w / 2, c + w / 2

    def sanitize(self) -> None:
        self.black = _clamp(self.black, -10, 10, 0.0)
        self.white = _clamp(self.white, -10, 10, 1.0)
        self.gamma = _clamp(self.gamma, 0.01, 100, 1.0)

    def to_json(self):
        return {"black": self.black, "white": self.white, "gamma": self.gamma, "invert": self.invert,
                "bands_dark": self.bands_dark}

    @staticmethod
    def from_json(d, what: str = "display") -> "DisplaySettings":
        d = _obj(d, what)
        return DisplaySettings(_num(d.get("black"), f"{what}.black", 0.0), _num(d.get("white"), f"{what}.white", 1.0),
                               _num(d.get("gamma"), f"{what}.gamma", 1.0), _flag(d.get("invert"), f"{what}.invert", False),
                               _flag(d.get("bands_dark"), f"{what}.bands_dark", True))


# ---------------------------------------------------------------------------------------------------- lanes


@dataclass
class LaneDivider:
    """A straight line between two lanes, spanning the whole image, stored by its x at the top and bottom rows."""
    x_top: float
    x_bottom: float
    #: where the dot sits (the y the user clicked)
    dot_y: float

    @staticmethod
    def vertical(x: float, dot_y: float) -> "LaneDivider":
        return LaneDivider(x, x, dot_y)

    def x_at(self, y: float, height: float) -> float:
        return self.x_top if height <= 0 else self.x_top + (self.x_bottom - self.x_top) * (y / height)

    def to_json(self):
        return {"x_top": self.x_top, "x_bottom": self.x_bottom, "dot_y": self.dot_y}

    @staticmethod
    def from_json(d, what: str = "divider") -> "LaneDivider":
        d = _item(d, what)
        return LaneDivider(_need_num(d.get("x_top"), f"{what}.x_top"), _need_num(d.get("x_bottom"), f"{what}.x_bottom"),
                           _need_num(d.get("dot_y"), f"{what}.dot_y"))


@dataclass
class Lanes:
    dividers: list[LaneDivider] = field(default_factory=list)
    #: the areas before the first and after the last divider count as lanes
    outer_lanes: bool = True
    #: lane 1 first, at the gel's top edge (derived from the dividers when there are any)
    centers: list[float] = field(default_factory=list)
    width: float = 100.0

    def sanitize(self) -> None:
        self.width = min(self.width, Sane.coordinate) if math.isfinite(self.width) and self.width > 0 else 100.0
        if len(self.centers) > Sane.lanes or not all(_is_coordinate(c) for c in self.centers):
            self.centers = []
        self.dividers = [d for d in self.dividers
                         if _is_coordinate(d.x_top) and _is_coordinate(d.x_bottom) and _is_coordinate(d.dot_y)]
        del self.dividers[Sane.lanes:]

    def to_json(self):
        return {"dividers": [d.to_json() for d in self.dividers], "outer_lanes": self.outer_lanes,
                "centers": list(self.centers), "width": self.width}

    @staticmethod
    def from_json(d, what: str = "lanes") -> "Lanes":
        d = _obj(d, what)
        return Lanes([LaneDivider.from_json(x, f"{what}.dividers[{i}]") for i, x in enumerate(_list(d.get("dividers"), f"{what}.dividers"))],
                     _flag(d.get("outer_lanes"), f"{what}.outer_lanes", True),
                     [_need_num(x, f"{what}.centers[{i}]") for i, x in enumerate(_list(d.get("centers"), f"{what}.centers"))],
                     _num(d.get("width"), f"{what}.width", 100.0))


class Line(NamedTuple):
    x_top: float
    x_bottom: float


@dataclass
class LaneGeometry:
    """Lanes resolved from dividers: boundary lines left to right, including the virtual outer ones."""
    boundaries: list[Line]
    height: float

    @property
    def count(self) -> int:
        return max(0, len(self.boundaries) - 1)

    def x(self, line: Line, y: float) -> float:
        return line.x_top + (line.x_bottom - line.x_top) * (y / max(self.height, 1))

    def center(self, n: int, y: float) -> float:
        """Centre of lane n (1-based) at row y."""
        return (self.x(self.boundaries[n - 1], y) + self.x(self.boundaries[n], y)) / 2

    def lane_at(self, px: float, y: float) -> Optional[int]:
        for n in range(1, self.count + 1):
            if self.x(self.boundaries[n - 1], y) <= px < self.x(self.boundaries[n], y):
                return n
        return None

    @staticmethod
    def resolve(lanes: Lanes, w: float, h: float) -> Optional["LaneGeometry"]:
        lines = sorted((Line(d.x_top, d.x_bottom) for d in lanes.dividers), key=lambda l: l.x_top + l.x_bottom)
        if not lines:
            return None
        b = list(lines)
        if lanes.outer_lanes:
            mids = [(l.x_top + l.x_bottom) / 2 for l in lines]
            gaps = sorted(b2 - a for a, b2 in zip(mids, mids[1:]))
            spacing = gaps[len(gaps) // 2] if gaps else None
            first, last = lines[0], lines[-1]
            dl = spacing if spacing is not None else (first.x_top + first.x_bottom) / 2
            dr = spacing if spacing is not None else w - (last.x_top + last.x_bottom) / 2
            b.insert(0, Line(first.x_top - dl, first.x_bottom - dl))
            b.append(Line(last.x_top + dr, last.x_bottom + dr))
        return LaneGeometry(b, h)


# ---------------------------------------------------------------------------------------------------- labels


@dataclass
class LabelGroup:
    text: str
    #: lanes spanned (1-based); only the first and last matter
    lanes: list[int]

    @property
    def first(self) -> int:
        return min(self.lanes) if self.lanes else 1

    @property
    def last(self) -> int:
        return max(self.lanes) if self.lanes else 1

    def to_json(self):
        return {"text": self.text, "lanes": [int(x) for x in self.lanes]}

    @staticmethod
    def from_json(d, what: str = "group") -> "LabelGroup":
        d = _item(d, what)
        return LabelGroup(_text(d.get("text"), f"{what}.text"),
                          [_int(x, f"{what}.lanes[{i}]") for i, x in enumerate(_list(d.get("lanes"), f"{what}.lanes"))])


@dataclass
class LabelRow:
    #: "lanes" (one label per lane) or "groups" (text centred over a span of lanes, optionally underlined)
    type: str = "lanes"
    #: row title printed at the left, e.g. "µM"
    name: Optional[str] = None
    labels: list[str] = field(default_factory=list)
    groups: list[LabelGroup] = field(default_factory=list)
    #: the angle the row's labels stand at, in degrees: 0 is horizontal, 90 straight up, the text rising to the right from the
    #: lane's centre (a group label's anchor is the centre of its span of lanes). Always in 0 to 360: see clamped_angle. For
    #: a row of lane labels one angle is shared by the figure (ops.set_label_angle); each row of group labels has its own
    #: (ops.set_row_angle) and its underline stays flat. Row titles, band names and ladder sizes stay horizontal.
    rotation: float = 0.0
    underline: bool = True
    bold: bool = False

    @staticmethod
    def clamped_angle(degrees: float) -> float:
        """Any angle, brought into 0 to 360 (a number that isn't one is 0)."""
        if not math.isfinite(degrees):
            return 0.0
        a = degrees % 360.0
        return 0.0 if a >= 360.0 else a

    def sanitize(self) -> None:
        self.rotation = LabelRow.clamped_angle(self.rotation)
        for g in self.groups:
            g.lanes = [min(max(x, 1), Sane.lanes) for x in g.lanes]

    def to_json(self):
        d = {"type": self.type}
        if self.name is not None:
            d["name"] = self.name
        if self.type == "lanes":
            d["labels"] = list(self.labels)
        else:
            d["groups"] = [g.to_json() for g in self.groups]
            d["underline"] = self.underline
        if self.rotation != 0:
            d["rotation"] = self.rotation
        if self.bold:
            d["weight"] = "bold"
        return d

    @staticmethod
    def from_json(d, what: str = "row") -> "LabelRow":
        d = _item(d, what)
        return LabelRow(_choice(d.get("type"), f"{what}.type", ("lanes", "groups"), "lanes"),
                        _opt_text(d.get("name"), f"{what}.name"),
                        [_text(x, f"{what}.labels[{i}]") for i, x in enumerate(_list(d.get("labels"), f"{what}.labels"))],
                        [LabelGroup.from_json(g, f"{what}.groups[{i}]") for i, g in enumerate(_list(d.get("groups"), f"{what}.groups"))],
                        LabelRow.clamped_angle(_num(d.get("rotation"), f"{what}.rotation", 0.0)),
                        _flag(d.get("underline"), f"{what}.underline", True),
                        _opt_text(d.get("weight"), f"{what}.weight") == "bold")


# ---------------------------------------------------------------------------------------------------- ladder


@dataclass
class LadderBand:
    y: float
    #: None = marked but not labelled
    size: Optional[float] = None
    #: not a ladder band (dye front, artifact)
    ignore: bool = False
    #: the size is a guess the user hasn't confirmed
    auto: bool = False
    note: Optional[str] = None
    #: the stacked gel this tick is on (its number in GelProject.strips), with y in that gel's own pixels; None = the
    #: gel with the lanes
    strip: Optional[int] = None

    def sanitized(self, strips: int) -> Optional["LadderBand"]:
        """None when the tick can't be kept: its row isn't a position, or it belongs to a gel the project doesn't have."""
        if not _is_coordinate(self.y) or (self.strip is not None and not 1 <= self.strip <= strips):
            return None
        if self.size is not None and not _is_size(self.size):
            self.size, self.auto = None, False
        return self

    def to_json(self):
        d = {"y": self.y, "size": self.size}   # explicit null, like the Mac app
        if self.ignore:
            d["ignore"] = True
        if self.auto:
            d["auto"] = True
        if self.note is not None:
            d["note"] = self.note
        if self.strip is not None:
            d["strip"] = self.strip
        return d

    @staticmethod
    def from_json(d, what: str = "tick") -> "LadderBand":
        d = _item(d, what)
        strip = d.get("strip")
        return LadderBand(_need_num(d.get("y"), f"{what}.y"), _num(d.get("size"), f"{what}.size"),
                          _flag(d.get("ignore"), f"{what}.ignore", False), _flag(d.get("auto"), f"{what}.auto", False),
                          _opt_text(d.get("note"), f"{what}.note"), None if strip is None else _int(strip, f"{what}.strip"))


@dataclass
class Ladder:
    #: 1-based lane holding the ladder
    lane: int = 1
    name: Optional[str] = None
    unit: str = "kDa"
    side: str = "left"
    #: the size list in use (largest first), editable
    sizes: Optional[list[float]] = None
    #: gel and running buffer the sizes are for
    system: Optional[str] = None
    bands: list[LadderBand] = field(default_factory=list)
    #: gel row the unit label is centred on, in the pixels of the gel unit_strip names; None = above the top of the gel
    unit_y: Optional[float] = None
    #: the gel (its number in GelProject.strips) unit_y is a row of; None = the gel with the lanes. The label goes with
    #: that gel.
    unit_strip: Optional[int] = None

    def assign(self, sizes: list[float], position=None, group: Optional[Callable] = None,
               visible: Optional[Callable] = None) -> None:
        """A guess: gives sizes to the non-skipped bands from the top down, each marked auto. position: where each
        tick's gel sits from the top (GelProject.position_of; use GelProject.assign_ladder for several gels). group:
        which ladder group a tick's gel is in, each group starting again from the top of sizes. visible(strip, y):
        ticks a crop hides are left as they were."""
        pos = position or _one_gel
        self.bands.sort(key=lambda b: (pos(b.strip), b.y))
        used: dict = {}
        for b in self.bands:
            if visible is not None and not visible(b.strip, b.y):
                continue
            if b.ignore:
                b.size, b.auto = None, False
                continue
            g = group(b.strip) if group is not None else 0
            n = used.get(g, 0)
            used[g] = n + 1
            b.size = sizes[n] if n < len(sizes) else None
            b.auto = b.size is not None

    @property
    def warnings(self) -> list[str]:
        """Sizes that don't shrink down the lane, repeated sizes (one gel; GelProject.ladder_warnings for several)."""
        return self.warnings_for(None)

    def warnings_for(self, position, group: Optional[Callable] = None, visible: Optional[Callable] = None) -> list[str]:
        pos = position or _one_gel
        labeled = sorted((b for b in self.bands if not b.ignore and b.size is not None
                          and (visible is None or visible(b.strip, b.y))), key=lambda b: (pos(b.strip), b.y))
        gid = group or (lambda strip: 0)
        w = []
        repeated = False
        for g in sorted({gid(b.strip) for b in labeled}):
            inside = [b for b in labeled if gid(b.strip) == g]
            for a, b in zip(inside, inside[1:]):
                if b.size >= a.size:
                    w.append(f"{format_size(b.size)} sits below {format_size(a.size)}. Sizes should shrink down the lane.")
            sizes = [b.size for b in inside]
            if len(set(sizes)) != len(sizes):
                repeated = True
        if repeated:
            w.append("The same size is on more than one tick.")
        return w

    def sanitize(self, strips: int) -> None:
        self.lane = min(max(self.lane, 1), Sane.lanes)
        if self.sizes is not None:
            self.sizes = [s for s in self.sizes if _is_size(s)]
        self.bands = [b for b in (b.sanitized(strips) for b in self.bands) if b is not None]
        if self.unit_y is not None and not _is_coordinate(self.unit_y):
            self.unit_y = None
        if self.unit_strip is not None and not 1 <= self.unit_strip <= strips:
            self.unit_y = None
        if self.unit_y is None:
            self.unit_strip = None

    def to_json(self):
        d = {"lane": int(self.lane), "unit": self.unit, "side": self.side, "bands": [b.to_json() for b in self.bands]}
        if self.name is not None:
            d["name"] = self.name
        if self.sizes is not None:
            d["sizes"] = list(self.sizes)
        if self.system is not None:
            d["system"] = self.system
        if self.unit_y is not None:
            d["unit_y"] = self.unit_y
            if self.unit_strip is not None:
                d["unit_strip"] = self.unit_strip
        return d

    @staticmethod
    def from_json(d, what: str = "ladder") -> "Ladder":
        d = _item(d, what)
        sizes = d.get("sizes")
        strip = d.get("unit_strip")
        return Ladder(_int(d.get("lane"), f"{what}.lane", 1), _opt_text(d.get("name"), f"{what}.name"),
                      _text(d.get("unit"), f"{what}.unit", "kDa"), _choice(d.get("side"), f"{what}.side", ("left", "right"), "left"),
                      None if sizes is None else [_need_num(x, f"{what}.sizes[{i}]") for i, x in enumerate(_list(sizes, f"{what}.sizes"))],
                      _opt_text(d.get("system"), f"{what}.system"),
                      [LadderBand.from_json(b, f"{what}.bands[{i}]") for i, b in enumerate(_list(d.get("bands"), f"{what}.bands"))],
                      _num(d.get("unit_y"), f"{what}.unit_y"), None if strip is None else _int(strip, f"{what}.unit_strip"))


def _one_gel(strip: Optional[int]) -> int:
    return 0 if strip is None else strip


def format_size(v: float) -> str:
    return str(int(v)) if v == sround(v) else f"{v:g}"


@dataclass
class BandAnnotation:
    """A name at the gel's edge beside a band, e.g. a protein name on the right."""
    y: float
    text: str = ""
    y2: Optional[float] = None
    #: "arrow", "tick", "bracket" or "none" (text only)
    marker: str = "arrow"
    side: str = "right"
    italic: bool = False
    bold: bool = False
    note: Optional[str] = None
    #: the stacked gel this name is on, with y in its own pixels; None = the gel with the lanes
    strip: Optional[int] = None

    def sanitized(self, strips: int) -> Optional["BandAnnotation"]:
        """None when the name can't be kept (see LadderBand.sanitized)."""
        if not _is_coordinate(self.y) or (self.strip is not None and not 1 <= self.strip <= strips):
            return None
        if self.y2 is not None and not _is_coordinate(self.y2):
            self.y2 = None
        return self

    def to_json(self):
        d = {"y": self.y, "text": self.text, "marker": self.marker, "side": self.side}
        if self.y2 is not None:
            d["y2"] = self.y2
        if self.italic:
            d["italic"] = True
        if self.bold:
            d["bold"] = True
        if self.note is not None:
            d["note"] = self.note
        if self.strip is not None:
            d["strip"] = self.strip
        return d

    @staticmethod
    def from_json(d, what: str = "name") -> "BandAnnotation":
        d = _item(d, what)
        strip = d.get("strip")
        return BandAnnotation(_need_num(d.get("y"), f"{what}.y"), _text(d.get("text"), f"{what}.text"),
                              _num(d.get("y2"), f"{what}.y2"),
                              _choice(d.get("marker"), f"{what}.marker", ("arrow", "tick", "bracket", "none"), "arrow"),
                              _choice(d.get("side"), f"{what}.side", ("left", "right"), "right"),
                              _flag(d.get("italic"), f"{what}.italic", False), _flag(d.get("bold"), f"{what}.bold", False),
                              _opt_text(d.get("note"), f"{what}.note"), None if strip is None else _int(strip, f"{what}.strip"))


# ---------------------------------------------------------------------------------------------------- text


class Role(NamedTuple):
    """What a piece of figure text is: title, rowName(r), laneLabel(r, lane), groupLabel(r, g), ladderLabel(band),
    ladderUnit or annotation(i)."""
    kind: str
    a: int = -1
    b: int = -1

    @property
    def size_key(self) -> Optional[str]:
        return {"laneLabel": f"lane.{self.a}.{self.b}", "groupLabel": f"group.{self.a}.{self.b}",
                "rowName": f"rowname.{self.a}", "annotation": f"name.{self.a}"}.get(self.kind)

    @property
    def text_kind(self) -> str:
        return {"title": "title", "rowName": "rowName", "laneLabel": "laneLabel", "groupLabel": "groupLabel",
                "ladderLabel": "ladder", "ladderUnit": "ladder", "annotation": "name"}[self.kind]


TITLE = Role("title")
LADDER_UNIT = Role("ladderUnit")

#: kinds of text, each with its own size, in the order the app lists them
TEXT_KINDS = [("laneLabel", "Lane labels"), ("groupLabel", "Group labels"), ("rowName", "Row titles"),
              ("ladder", "Ladder sizes"), ("name", "Band names"), ("title", "Title")]


#: the keys of FigureStyle.text_sizes any label can have (Role.size_key); a damaged file's other keys are dropped on load
SIZE_KEY = re.compile(r"(?:lane|group)\.[0-9]+\.[0-9]+|(?:rowname|name)\.[0-9]+")


def is_size_key(key: str) -> bool:
    """Whether key is one a single-label size can have: lane.R.L, group.R.G, rowname.R or name.I, each number a whole one
    that fits 64 bits (as on the Mac)."""
    return SIZE_KEY.fullmatch(key) is not None and all(int(n) < 2 ** 63 for n in re.findall("[0-9]+", key))


@dataclass
class FigureStyle:
    font: str = "Arial"
    #: points: lane, group and ladder labels
    size: float = 7.0
    title_size: float = 8.0
    #: printed width of the cropped gel
    gel_width_in: float = 3.2
    tick_len_pt: float = 3.0
    line_width_pt: float = 0.6
    border: bool = True
    row_gap_pt: float = 3.0
    #: fraction of a lane width trimmed from each end of a group underline
    group_line_inset: float = 0.12
    #: minimum ladder-label spacing, in multiples of the font size
    label_sep: float = 1.1
    #: horizontal run of the leader used when a ladder label had to move
    leader_pt: float = 3.0
    #: sizes for single labels, keyed by Role.size_key
    text_sizes: dict = field(default_factory=dict)
    #: PNG/TIFF resolution; None = native (one gel pixel per output pixel)
    export_dpi: Optional[float] = None
    lane_label_size: Optional[float] = None
    group_label_size: Optional[float] = None
    row_name_size: Optional[float] = None
    ladder_label_size: Optional[float] = None
    name_size: Optional[float] = None

    _KIND_FIELD = {"laneLabel": "lane_label_size", "groupLabel": "group_label_size", "rowName": "row_name_size",
                   "ladder": "ladder_label_size", "name": "name_size"}

    def size_for_kind(self, kind: str) -> float:
        if kind == "title":
            return self.title_size
        v = getattr(self, self._KIND_FIELD[kind])
        return self.size if v is None else v

    def set_size_for_kind(self, v: float, kind: str) -> None:
        x = min(max(sround(v * 2) / 2, 3), 48)
        if kind == "title":
            self.title_size = x
        else:
            setattr(self, self._KIND_FIELD[kind], x)

    def scale_all(self, delta: float) -> None:
        """Everything bigger or smaller by delta points, keeping the differences between kinds."""
        for k, _ in TEXT_KINDS:
            self.set_size_for_kind(self.size_for_kind(k) + delta, k)
        for k in list(self.text_sizes):
            self.text_sizes[k] = min(max(self.text_sizes[k] + delta, 3), 48)
        self.size = min(max(self.size + delta, 3), 48)

    def size_for(self, role: Role) -> float:
        k = role.size_key
        if k is not None and k in self.text_sizes:
            return self.text_sizes[k]
        return self.size_for_kind(role.text_kind)

    def set_size_for_label(self, v: float, role: Role) -> None:
        k = role.size_key
        if k is None:
            self.set_size_for_kind(v, role.text_kind)
        else:
            self.text_sizes[k] = min(max(sround(v * 2) / 2, 3), 48)

    def remap_name_sizes(self, old_index: list[Optional[int]]) -> None:
        """After band names were taken out or put in another order: old_index[i] is where the name now at place i used
        to be (None for a new one), so every name keeps its own single-name size."""
        old = {k: v for k, v in self.text_sizes.items() if k.startswith("name.")}
        if not old:
            return
        for k in old:
            del self.text_sizes[k]
        for i, was in enumerate(old_index):
            if was is not None and f"name.{was}" in old:
                self.text_sizes[f"name.{i}"] = old[f"name.{was}"]

    def sanitize(self) -> None:
        d = FigureStyle()
        if not self.font:
            self.font = d.font
        self.size = _clamp(self.size, 1, 200, d.size)
        self.title_size = _clamp(self.title_size, 1, 200, d.title_size)
        self.gel_width_in = _clamp(self.gel_width_in, 0.05, 100, d.gel_width_in)
        self.tick_len_pt = _clamp(self.tick_len_pt, 0, 100, d.tick_len_pt)
        self.line_width_pt = _clamp(self.line_width_pt, 0, 50, d.line_width_pt)
        self.row_gap_pt = _clamp(self.row_gap_pt, 0, 200, d.row_gap_pt)
        self.group_line_inset = _clamp(self.group_line_inset, 0, 1, d.group_line_inset)
        self.label_sep = _clamp(self.label_sep, 0, 20, d.label_sep)
        self.leader_pt = _clamp(self.leader_pt, 0, 100, d.leader_pt)
        for f in self._KIND_FIELD.values():
            v = getattr(self, f)
            if v is not None:
                setattr(self, f, _clamp(v, 1, 200, self.size))
        self.text_sizes = {k: _clamp(v, 1, 200, self.size) for k, v in self.text_sizes.items()
                           if math.isfinite(v) and is_size_key(k)}
        if self.export_dpi is not None and not (math.isfinite(self.export_dpi) and 1 <= self.export_dpi <= 10_000):
            self.export_dpi = None

    def to_json(self):
        d = {"font": self.font, "size": self.size, "title_size": self.title_size, "gel_width_in": self.gel_width_in,
             "tick_len_pt": self.tick_len_pt, "line_width_pt": self.line_width_pt, "border": self.border,
             "row_gap_pt": self.row_gap_pt, "group_line_inset": self.group_line_inset, "label_sep": self.label_sep,
             "leader_pt": self.leader_pt, "text_sizes": dict(self.text_sizes)}
        for k in ("export_dpi", "lane_label_size", "group_label_size", "row_name_size", "ladder_label_size",
                  "name_size"):
            v = getattr(self, k)
            if v is not None:
                d[k] = v
        return d

    @staticmethod
    def from_json(d, what: str = "style") -> "FigureStyle":
        d = _obj(d, what)
        s = FigureStyle()
        for k in ("font", "size", "title_size", "gel_width_in", "tick_len_pt", "line_width_pt", "border",
                  "row_gap_pt", "group_line_inset", "label_sep", "leader_pt", "export_dpi", "lane_label_size",
                  "group_label_size", "row_name_size", "ladder_label_size", "name_size"):
            v = d.get(k)
            if v is None:
                continue
            if k == "font":
                setattr(s, k, _text(v, f"{what}.{k}"))
            elif k == "border":
                setattr(s, k, _flag(v, f"{what}.{k}", True))
            else:
                setattr(s, k, _num(v, f"{what}.{k}"))
        s.text_sizes = {str(k): _need_num(v, f"{what}.text_sizes.{k}") for k, v in _obj(d.get("text_sizes"), f"{what}.text_sizes").items()}
        return s


# ---------------------------------------------------------------------------------------------------- the line between gels


def parse_separator(text) -> Optional[str]:
    """The colour of the line between gels as the project stores it, from "black", "white", "#RRGGBB" (the # is optional) or
    the short "#RGB" (each digit doubled): "black", "white" or "#rrggbb" in lower case. Black and white are also what
    #000000 and #ffffff read as, so a colour is never one of those two. None when it isn't a colour."""
    if not isinstance(text, str):
        return None
    t = text.strip().lower()
    if t in ("black", "white"):
        return t
    digits = t[1:] if t.startswith("#") else t
    if not digits or any(c not in "0123456789abcdef" for c in digits):
        return None
    if len(digits) == 3:
        digits = "".join(c * 2 for c in digits)
    if len(digits) != 6:
        return None
    return {"000000": "black", "ffffff": "white"}.get(digits, "#" + digits)


def separator_rgb(colour: str) -> tuple[int, int, int]:
    """The line's red, green and blue, 0 to 255 (colour: what parse_separator gives)."""
    if colour == "white":
        return 255, 255, 255
    if colour.startswith("#") and len(colour) == 7:
        return int(colour[1:3], 16), int(colour[3:5], 16), int(colour[5:7], 16)
    return 0, 0, 0


def separator_gray(colour: str) -> int:
    """Its gray level in a gray figure, 0 to 255: the luminance of its 8-bit red, green and blue (Rec. 709), rounded. A 16-bit
    gray figure takes this times 257."""
    r, g, b = separator_rgb(colour)
    return int(min(max(sround(0.2126 * r + 0.7152 * g + 0.0722 * b), 0), 255))


# ---------------------------------------------------------------------------------------------------- stacked gels


@dataclass
class GelStrip:
    """Another gel in the figure, scanned on its own: a piece of a membrane cut to probe different antibodies, or the
    same samples run on another gel. It's stacked with the project's image, a line between them so the figure shows
    they were imaged separately. Lanes and lane labels are the project image's; this gel is lined up under them with
    shift (and, when Strict is off, scale). Its ticks and names are in the project's ladder and annotations, marked
    with its number in strips."""
    #: file name of its image inside the package, copied byte-for-byte like the main image
    image: str
    image_sha256: Optional[str] = None
    #: quarter turns clockwise (0…3), for a gel scanned the wrong way round; lossless
    turn: int = 0
    #: straightening, degrees; resamples, so it only applies when Strict is off
    rotate_deg: float = 0.0
    display: DisplaySettings = field(default_factory=DisplaySettings)
    #: its rows that go into the figure, in its own working-image pixels; None = the edge of the image
    top: Optional[float] = None
    bottom: Optional[float] = None
    #: its columns that go into the figure, the same way (None = follow the gel with the lanes' crop through the alignment).
    #: With the rows, the gel's own crop: the figure runs from the leftmost to the rightmost column any gel keeps
    left: Optional[float] = None
    right: Optional[float] = None
    #: lines the lanes up: x in this gel = scale × x in the main image + shift (Strict: whole pixels, no scale)
    shift: float = 0.0
    scale: float = 1.0
    #: its ladder sizes start again from the top of the list instead of carrying on from the gel above
    own_ladder: bool = False
    #: keep original pixels for this gel: None = the same as the gel with the lanes (what projects without a value of
    #: their own mean), True = whole-pixel shifts only and no stretch or rotation, False = it may be stretched and rotated
    strict: Optional[bool] = None

    def used_rows(self, height: int) -> tuple[float, float]:
        """The rows of this gel that go into the figure, as whole pixels with 0 <= top < bottom <= height (the gel's
        height in its turned image). Missing rows mean the edge, and rows that can't be used the whole gel. It's what
        stacking, aligning and the provenance note all use, so they agree."""
        h = float(max(height, 1))
        a = 0.0 if self.top is None else self.top
        b = h if self.bottom is None else self.bottom
        if not (math.isfinite(a) and math.isfinite(b)):
            return 0.0, h
        t = min(max(sround(a), 0.0), h - 1)
        return t, min(max(sround(b), t + 1), h)

    def columns(self, width: int, lane_crop: "PixelRect", shift: float, scale: float) -> tuple[float, float, bool, bool]:
        """Where this gel's kept columns start and end, in its own pixels (its working image, after its turn, is width wide),
        when the gel with the lanes keeps figure columns lane_crop and this gel is lined up by shift and scale:
        (left, right, follows_left, follows_right).

        An edge the gel has set is its own: whole pixels inside the image. An edge it hasn't follows the lanes gel's crop
        edge through the alignment, which is what stacking did before gels had columns of their own: a gel with none shows
        what lines up with the lanes gel's crop, and never makes the figure wider. A followed edge is exact and may lie past
        the image (stacking leaves blank what the gel has no pixels for). Columns that can't be used (not a number, or
        empty) are followed instead."""
        w = float(max(width, 1))
        l = min(max(sround(self.left), 0.0), w - 1) if self.left is not None and math.isfinite(self.left) else None
        r = min(max(sround(self.right), 1.0), w) if self.right is not None and math.isfinite(self.right) else None
        if l is not None and r is not None and not l < r:
            l = r = None
        left = scale * lane_crop.x0 + shift if l is None else l
        right = scale * lane_crop.x1 + shift if r is None else r
        follows_left, follows_right = l is None, r is None
        # one edge set and the other followed can cross: the followed one is then the image's own edge
        if follows_right and l is not None and not right > l:
            right, follows_right = w, False
        if follows_left and r is not None and not left < r:
            left, follows_left = 0.0, False
        return left, right, follows_left, follows_right

    def sanitize(self) -> None:
        self.turn %= 4
        self.rotate_deg = _clamp(self.rotate_deg, -360, 360, 0.0)
        self.display.sanitize()
        self.shift = _clamp(self.shift, -Sane.coordinate, Sane.coordinate, 0.0)
        self.scale = _clamp(self.scale, 0.5, 2, 1.0)
        # rows that aren't 0 <= top < bottom mean the whole gel
        t = 0.0 if self.top is None else self.top
        if self.bottom is not None:
            if not (math.isfinite(t) and math.isfinite(self.bottom) and 0 <= t < self.bottom):
                self.top = self.bottom = None
        elif not (math.isfinite(t) and t >= 0):
            self.top = None
        # and columns that aren't 0 <= left < right the whole width
        c = 0.0 if self.left is None else self.left
        if self.right is not None:
            if not (math.isfinite(c) and math.isfinite(self.right) and 0 <= c < self.right):
                self.left = self.right = None
        elif not (math.isfinite(c) and c >= 0):
            self.left = None

    def to_json(self):
        d = {"image": self.image, "rotate_deg": self.rotate_deg, "display": self.display.to_json(),
             "shift": self.shift, "scale": self.scale}
        if self.image_sha256 is not None:
            d["image_sha256"] = self.image_sha256
        if self.turn != 0:
            d["turn"] = self.turn
        if self.top is not None:
            d["top"] = self.top
        if self.bottom is not None:
            d["bottom"] = self.bottom
        if self.left is not None:
            d["left"] = self.left
        if self.right is not None:
            d["right"] = self.right
        if self.own_ladder:
            d["own_ladder"] = True
        if self.strict is not None:
            d["strict"] = self.strict
        return d

    @staticmethod
    def from_json(d, what: str = "strip") -> "GelStrip":
        d = _item(d, what)
        image = _text(d.get("image"), f"{what}.image")
        if not image:
            raise ValueError(f"{what}.image is missing")
        return GelStrip(image, _opt_text(d.get("image_sha256"), f"{what}.image_sha256"),
                        _int(d.get("turn"), f"{what}.turn", 0) % 4, _num(d.get("rotate_deg"), f"{what}.rotate_deg", 0.0),
                        DisplaySettings.from_json(d.get("display"), f"{what}.display"),
                        _num(d.get("top"), f"{what}.top"), _num(d.get("bottom"), f"{what}.bottom"),
                        _num(d.get("left"), f"{what}.left"), _num(d.get("right"), f"{what}.right"),
                        _num(d.get("shift"), f"{what}.shift", 0.0), _num(d.get("scale"), f"{what}.scale", 1.0),
                        _flag(d.get("own_ladder"), f"{what}.own_ladder", False), _opt_flag(d.get("strict"), f"{what}.strict"))


# ---------------------------------------------------------------------------------------------------- project


@dataclass
class GelProject:
    image: str = ""
    #: SHA-256 (hex) of the original image file, recorded on import
    image_sha256: Optional[str] = None
    strict: bool = True
    title: Optional[str] = None
    crop: Optional[PixelRect] = None
    fill_padding: bool = True
    rotate_deg: float = 0.0
    #: "background" (the gel's measured background), "white" or "custom"
    fill_mode: str = "background"
    #: gray level 0…1 for "custom"
    fill_value: float = 0.9
    #: an older screen-only auto contrast, still honoured
    view_enhance: bool = False
    display: DisplaySettings = field(default_factory=DisplaySettings)
    lanes: Lanes = field(default_factory=Lanes)
    #: label rows listed from the gel upward (index 0 sits directly on the gel)
    rows: list[LabelRow] = field(default_factory=list)
    ladder: Optional[Ladder] = None
    annotations: list[BandAnnotation] = field(default_factory=list)
    style: FigureStyle = field(default_factory=FigureStyle)
    #: quarter turns clockwise (0…3) before anything else, for a scan made the wrong way round; lossless, so Strict
    #: allows it
    turn: int = 0
    #: more gels in the same figure, stacked top to bottom in this order with a line between each (see GelStrip)
    strips: list[GelStrip] = field(default_factory=list)
    #: where this image, the gel whose lanes every gel shares, sits among strips, counted from the top: 0 = above all
    main_position: int = 0
    #: this image's ladder sizes start again from the top of the list instead of carrying on from the gel above (see
    #: ladder_groups). The top gel always starts a group, so this only matters when it isn't the top gel.
    own_ladder: bool = False
    #: where the gel with the lanes sits sideways in the figure, said the way a stacked gel's shift says where it does: the
    #: figure's column x shows this gel's column x + main_shift, so a positive number moves the gel to the left. Its lane
    #: dividers, lane labels, ticks and names go with it, and no other gel moves when it does (their own shift is a place
    #: in the figure too). Whole pixels (effective_main_shift). 0, which is left out of the file, is where the gel was
    #: before it could move.
    main_shift: float = 0.0
    #: the colour of the line between gels: "black" (the darkest value of the figure's gel), "white" (the brightest) or
    #: "#rrggbb" (see parse_separator)
    separator: str = "black"
    #: how thick that line is, in points (SEPARATOR_WIDTHS); None = as thick as the figure's other lines
    #: (style.line_width_pt), following them
    separator_width: Optional[float] = None
    #: whether exported files name each gel's image file in their notes and metadata (False leaves the names out, as they can
    #: identify samples or people; the SHA-256 fingerprints stay either way). Absent in the file means True.
    export_file_names: bool = True

    def copy(self) -> "GelProject":
        return copy.deepcopy(self)

    # -- stacked gels

    SEPARATOR_WIDTHS = (0.25, 10.0)

    @property
    def effective_separator_width(self) -> float:
        """How thick the line between gels is, in points: its own width when it has one, else the figure's line width."""
        w = self.separator_width
        if w is not None and math.isfinite(w):
            return min(max(w, self.SEPARATOR_WIDTHS[0]), self.SEPARATOR_WIDTHS[1])
        return self.style.line_width_pt

    @property
    def effective_main_shift(self) -> float:
        """Where the gel with the lanes sits sideways (see main_shift): whole pixels, and a number that isn't one is 0."""
        v = self.main_shift
        return sround(min(max(v, -Sane.coordinate), Sane.coordinate)) if math.isfinite(v) else 0.0

    @property
    def main_slot(self) -> int:
        """Where the image with the lanes sits in the stack, kept in range."""
        return min(max(self.main_position, 0), len(self.strips))

    @property
    def stack_order(self) -> list[Optional[int]]:
        """The gels top to bottom: None = this image (the one with the lanes), k = strips[k - 1]."""
        order: list[Optional[int]] = [k + 1 for k in range(len(self.strips))]
        order.insert(self.main_slot, None)
        return order

    def position_of(self, strip: Optional[int]) -> int:
        """A gel's place in the stack, from 0 at the top (None = this image)."""
        m = self.main_slot
        if strip is None:
            return m
        return strip - 1 if strip - 1 < m else strip

    def stack_key(self, strip: Optional[int], y: float) -> tuple[int, float]:
        """Sort key for a mark at y in its own gel: top to bottom through the stack."""
        return self.position_of(strip), y

    def is_strict(self, strip: Optional[int] = None) -> bool:
        """Whether gel strip (None = the one with the lanes) keeps its original pixels. The lanes gel's setting is the
        project's own; another gel's is its own, or the lanes gel's when it has none."""
        if strip is None or not 1 <= strip <= len(self.strips) or self.strips[strip - 1].strict is None:
            return self.strict
        return bool(self.strips[strip - 1].strict)

    # -- ladder groups: the gels that share one ladder

    def has_own_ladder(self, strip: Optional[int]) -> bool:
        """Whether gel strip (None = the one with the lanes) is marked as having its own ladder."""
        if strip is None:
            return self.own_ladder
        return 1 <= strip <= len(self.strips) and self.strips[strip - 1].own_ladder

    def _group_by_position(self) -> list[int]:
        """For each place in the stack (from the top), the number of the ladder group it belongs to. The top gel starts
        the first group and every gel with its own ladder starts another; the gels in between carry its sizes on."""
        out, g = [], -1
        for i, s in enumerate(self.stack_order):
            if i == 0 or self.has_own_ladder(s):
                g += 1
            out.append(g)
        return out

    @property
    def ladder_groups(self) -> list[list[Optional[int]]]:
        """The gels top to bottom, split into the groups that share one ladder."""
        groups: list[list[Optional[int]]] = []
        for i, s in enumerate(self.stack_order):
            if i == 0 or self.has_own_ladder(s):
                groups.append([s])
            else:
                groups[-1].append(s)
        return groups

    def ladder_group_of(self, strip: Optional[int]) -> int:
        """The number (from 0) of the ladder group gel strip is in. Ladder sizes run on from gel to gel inside a group
        and start again from the top of the list in the next group."""
        by = self._group_by_position()
        return by[min(self.position_of(strip), len(by) - 1)]

    def is_in_figure(self, strip: Optional[int], y: float) -> bool:
        """Whether a mark at y (in the pixels of gel strip, None = the one with the lanes) is inside the rows that gel
        shows in the figure. A tick or name outside them was hidden by a later crop: it keeps its size but no longer
        takes part in the ladder (assigning sizes, the suggested size, the warnings)."""
        if not math.isfinite(y):
            return False
        if strip is not None:
            if not 1 <= strip <= len(self.strips):
                return False
            s = self.strips[strip - 1]
            top = 0.0 if s.top is None else sround(s.top)
            bottom = math.inf if s.bottom is None else sround(s.bottom)
            return top - 0.5 <= y <= bottom + 0.5
        c = self.crop
        if c is None or not (math.isfinite(c.y0) and math.isfinite(c.y1)):
            return True
        return math.floor(min(c.y0, c.y1)) <= y <= math.ceil(max(c.y0, c.y1))

    def assign_ladder(self, sizes: list[float]) -> None:
        """Ladder sizes from the top down through the gels (a guess, marked auto). Every ladder group starts again from
        the top of sizes, and ticks that a crop hides keep the size they had."""
        if self.ladder is not None:
            self.ladder.assign(sizes, self.position_of, self.ladder_group_of, self.is_in_figure)

    @property
    def ladder_warnings(self) -> list[str]:
        """The ladder's warnings, reading the ticks top to bottom through each ladder group; hidden ticks don't count."""
        if self.ladder is None:
            return []
        return self.ladder.warnings_for(self.position_of, self.ladder_group_of, self.is_in_figure)

    def figure_rows(self, strip: Optional[int], width: int, height: int) -> tuple[float, float]:
        """The rows gel strip shows in the figure, in that gel's own pixels. width x height: that gel's working image.
        A tick or name belongs between them."""
        if strip is not None and 1 <= strip <= len(self.strips):
            return self.strips[strip - 1].used_rows(height)
        c = self.effective_crop(width, height)
        return c.y0, max(c.y0, c.y1)

    def clamp_y(self, y: float, strip: Optional[int], width: int, height: int) -> float:
        """y moved into the rows gel strip shows in the figure (see figure_rows), for placing, dragging, snapping and
        nudging a tick or name. A value that isn't a number goes to the top row."""
        lo, hi = self.figure_rows(strip, width, height)
        return min(max(y if math.isfinite(y) else lo, lo), hi)

    def normalize(self, main_size: Optional[tuple[int, int]] = None, strip_sizes=()) -> None:
        """With the sizes of the gels known (each one's working image, after its quarter turns; strip_sizes[k - 1] is
        gel k's, None = not known): rows that aren't 0 <= top < bottom <= height go back to the whole gel, and a mark
        outside its gel's image moves to the nearest row of it."""
        for k, s in enumerate(self.strips):
            size = strip_sizes[k] if k < len(strip_sizes) else None
            if size is None:
                continue
            h = float(size[1])
            t = 0.0 if s.top is None else s.top
            b = h if s.bottom is None else s.bottom
            if not (0 <= t < b <= h):
                s.top = s.bottom = None
            w = float(size[0])
            l = 0.0 if s.left is None else s.left
            r = w if s.right is None else s.right
            if not (0 <= l < r <= w):
                s.left = s.right = None

        def height(strip: Optional[int]) -> Optional[float]:
            if strip is not None:
                size = strip_sizes[strip - 1] if 1 <= strip <= len(strip_sizes) else None
                return None if size is None else float(size[1])
            return None if main_size is None else float(main_size[1])

        def inside(y: float, strip: Optional[int]) -> float:
            h = height(strip)
            return y if h is None else min(max(y, 0.0), h)

        if self.ladder is not None:
            for b in self.ladder.bands:
                b.y = inside(b.y, b.strip)
            if self.ladder.unit_y is not None:
                self.ladder.unit_y = inside(self.ladder.unit_y, self.ladder.unit_strip)
        for a in self.annotations:
            a.y = inside(a.y, a.strip)
            if a.y2 is not None:
                a.y2 = inside(a.y2, a.strip)

    def strip_project(self, k: int) -> "GelProject":
        """Gel k (its number in strips) as a project of its own, which is what WorkingImage reads: its image, turn,
        rotation and brightness & contrast, with its own Strict setting (is_strict) and this project's fill."""
        s = self.strips[k - 1]
        p = GelProject(image=s.image, image_sha256=s.image_sha256, strict=self.is_strict(k), fill_padding=self.fill_padding,
                       rotate_deg=s.rotate_deg, fill_mode=self.fill_mode, fill_value=self.fill_value,
                       display=copy.deepcopy(s.display))
        p.turn = s.turn
        return p

    def effective_alignment(self, k: int) -> tuple[float, float]:
        """What lines gel k up, after its Strict setting has had its say: whole-pixel shifts and no stretching while it
        keeps original pixels."""
        s = self.strips[k - 1]
        return (sround(s.shift), 1.0) if self.is_strict(k) else (s.shift, s.scale if s.scale > 0 else 1.0)

    def lane_alignment(self, k: int) -> tuple[float, float]:
        """What lines gel k up with the gel with the lanes wherever that sits: x in the gel = scale × x in the lanes gel +
        shift. The gel's shift (effective_alignment) is its place in the figure, and the lanes gel itself sits at
        effective_main_shift, so the two differ by scale × that. Stacking, the lanes' places in a gel's own pixels and
        Auto-align work from this."""
        shift, scale = self.effective_alignment(k)
        return shift - scale * self.effective_main_shift, scale

    def shift_to_store(self, lane_shift: float, scale: float) -> float:
        """The shift to store for a gel so it lines up with the lanes gel by lane_shift (see lane_alignment) wherever that sits."""
        return lane_shift + scale * self.effective_main_shift

    def kept_columns(self, k: int, width: int, main_width: int, main_height: int) -> tuple[float, float]:
        """Gel k's kept columns as whole pixels inside its image (width wide, after its turn), for showing them and for a crop
        to start from: its own where it has set them, else the lanes gel's crop through the alignment (see
        GelStrip.columns). main_width × main_height: the gel with the lanes' working image."""
        w = float(max(width, 1))
        if not 1 <= k <= len(self.strips):
            return 0.0, w
        shift, scale = self.lane_alignment(k)
        left, right, _, _ = self.strips[k - 1].columns(width, self.effective_crop(main_width, main_height), shift, scale)
        if not (math.isfinite(left) and math.isfinite(right)):
            return 0.0, w
        l = min(max(sround(left), 0.0), w - 1)
        return l, min(max(sround(right), l + 1), w)

    @property
    def lane_count(self) -> int:
        return len(self.lanes.centers)

    @property
    def label_angle(self) -> float:
        """The angle the lane labels stand at, in degrees (0 horizontal, 90 straight up, any angle in 0 to 360): the first row
        of lane labels' (0 without one). One setting for the figure; ops.set_label_angle sets it on every row of lane labels."""
        row = next((r for r in self.rows if r.type == "lanes"), None)
        return LabelRow.clamped_angle(row.rotation) if row is not None else 0.0

    @property
    def effective_rotation(self) -> float:
        return 0.0 if self.strict else self.rotate_deg

    @property
    def effective_fill_padding(self) -> bool:
        return False if self.strict else self.fill_padding

    @property
    def effective_display(self) -> DisplaySettings:
        """What applies to exported pixels: nothing in Strict mode."""
        if not self.strict:
            return self.display
        return DisplaySettings(bands_dark=self.display.bands_dark)

    def effective_crop(self, w: int, h: int) -> PixelRect:
        """Whole pixels always, so the gel grid never shifts by a fraction."""
        r = (self.crop or PixelRect(0, 0, w, h)).normalized(w, h)
        return PixelRect(math.floor(r.x0), math.floor(r.y0), math.ceil(r.x1), math.ceil(r.y1)).normalized(w, h)

    def sync_lane_centers(self, w: int, h: int) -> None:
        """Recomputes lanes.centers (at the gel's top edge) and lanes.width from the dividers."""
        g = LaneGeometry.resolve(self.lanes, float(w), float(h))
        if g is None:
            return
        top = self.effective_crop(w, h).y0
        self.lanes.centers = [sround(g.center(i + 1, top) * 10) / 10 for i in range(g.count)]
        widths = sorted(g.x(g.boundaries[i + 1], top) - g.x(g.boundaries[i], top) for i in range(g.count))
        if widths:
            self.lanes.width = sround(widths[len(widths) // 2] * 0.85)

    # -- loading

    def sanitize(self) -> bool:
        """Puts anything finite but absurd back in range, drops marks that name a gel the project doesn't have, and
        makes every stacked gel's rows valid. Done on every load. Returns whether anything changed."""
        before = copy.deepcopy(self)
        self.turn %= 4
        self.rotate_deg = _clamp(self.rotate_deg, -360, 360, 0.0)
        self.main_shift = _clamp(self.main_shift, -Sane.coordinate, Sane.coordinate, 0.0)
        # a line thickness that isn't a number goes back to following the figure's lines, one outside 0.25 to 10 pt into that range
        if self.separator_width is not None:
            self.separator_width = (min(max(self.separator_width, self.SEPARATOR_WIDTHS[0]), self.SEPARATOR_WIDTHS[1])
                                    if math.isfinite(self.separator_width) else None)
        self.fill_value = _clamp(self.fill_value, 0.0, 1.0, 0.9)
        c = self.crop
        if c is not None and not all(_is_coordinate(v) for v in (c.x0, c.y0, c.x1, c.y1)):
            self.crop = None
        self.display.sanitize()
        self.lanes.sanitize()
        del self.rows[Sane.rows:]
        for r in self.rows:
            r.sanitize()
        for s in self.strips:
            s.sanitize()
        n = len(self.strips)
        if self.ladder is not None:
            self.ladder.sanitize(n)
        kept = []
        annotations = []
        for i, a in enumerate(self.annotations):
            if a.sanitized(n) is not None:
                kept.append(i)
                annotations.append(a)
        self.annotations = annotations
        self.style.sanitize()
        if len(kept) != len(before.annotations):
            self.style.remap_name_sizes(kept)   # sizes follow their names
        return self != before

    # -- JSON

    def to_json(self) -> dict:
        d = {"image": self.image, "strict": self.strict, "fill_padding": self.fill_padding,
             "rotate_deg": self.rotate_deg, "fill_mode": self.fill_mode, "display": self.display.to_json(),
             "lanes": self.lanes.to_json(), "rows": [r.to_json() for r in self.rows],
             "annotations": [a.to_json() for a in self.annotations], "style": self.style.to_json()}
        if self.image_sha256 is not None:
            d["image_sha256"] = self.image_sha256
        if self.title is not None:
            d["title"] = self.title
        if self.crop is not None:
            d["crop"] = self.crop.to_json()
        if self.fill_mode == "custom":
            d["fill_value"] = self.fill_value
        if self.view_enhance:
            d["view_enhance"] = True
        if self.ladder is not None:
            d["ladder"] = self.ladder.to_json()
        if self.turn % 4:
            d["turn"] = self.turn % 4
        if self.strips:
            d["strips"] = [s.to_json() for s in self.strips]
        if self.main_slot != 0:
            d["main_position"] = self.main_slot
        if self.own_ladder:
            d["own_ladder"] = True
        if self.main_shift != 0:
            d["main_shift"] = self.main_shift
        if self.separator != "black":
            d["separator"] = self.separator
        if self.separator_width is not None:
            d["separator_width"] = self.separator_width
        if not self.export_file_names:
            d["export_file_names"] = False
        return d

    def dumps(self) -> str:
        return json.dumps(self.to_json(), indent=2, sort_keys=True, ensure_ascii=False)

    @staticmethod
    def from_json(d: dict) -> "GelProject":
        """Raises ValueError, saying which value is wrong, for anything that isn't a project."""
        if not isinstance(d, dict):
            raise ValueError("project.json should hold one object")
        crop = d.get("crop")
        ladder = d.get("ladder")
        p = GelProject(
            image=_text(d.get("image"), "image"), image_sha256=_opt_text(d.get("image_sha256"), "image_sha256"),
            strict=_flag(d.get("strict"), "strict", True), title=_opt_text(d.get("title"), "title"),
            crop=None if crop is None else PixelRect.from_json(crop, "crop"),
            fill_padding=_flag(d.get("fill_padding"), "fill_padding", True), rotate_deg=_num(d.get("rotate_deg"), "rotate_deg", 0.0),
            fill_mode=_choice(d.get("fill_mode"), "fill_mode", ("background", "white", "custom"), "background"),
            fill_value=_num(d.get("fill_value"), "fill_value", 0.9), view_enhance=_flag(d.get("view_enhance"), "view_enhance", False),
            display=DisplaySettings.from_json(d.get("display"), "display"), lanes=Lanes.from_json(d.get("lanes"), "lanes"),
            rows=[LabelRow.from_json(r, f"rows[{i}]") for i, r in enumerate(_list(d.get("rows"), "rows"))],
            ladder=None if ladder is None else Ladder.from_json(ladder, "ladder"),
            annotations=[BandAnnotation.from_json(a, f"annotations[{i}]") for i, a in enumerate(_list(d.get("annotations"), "annotations"))],
            style=FigureStyle.from_json(d.get("style"), "style"), turn=_int(d.get("turn"), "turn", 0) % 4,
            strips=[GelStrip.from_json(s, f"strips[{i}]") for i, s in enumerate(_list(d.get("strips"), "strips"))],
            main_position=_int(d.get("main_position"), "main_position", 0),
            own_ladder=_flag(d.get("own_ladder"), "own_ladder", False),
            main_shift=_num(d.get("main_shift"), "main_shift", 0.0),
            separator=_separator(d.get("separator")), separator_width=_separator_width(d.get("separator_width")),
            export_file_names=_flag(d.get("export_file_names"), "export_file_names", True))
        p.sanitize()   # a damaged or hand-edited file loads with sane numbers instead of crashing a render later
        return p

    @staticmethod
    def loads(text: str) -> "GelProject":
        return GelProject.from_json(json.loads(text))
