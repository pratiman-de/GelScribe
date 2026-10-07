"""Ladder presets: nominal sizes and, for prestained protein markers, apparent sizes per gel and buffer (vendor
migration charts). The built-in list (ladders.json) is the Mac app's own; saved ladders live in the user's
application data folder."""
from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class LadderSystem:
    id: str
    name: str
    #: top to bottom, stopping where bands run off the gel, so index i is always the same protein
    sizes: list[float]


@dataclass
class LadderPreset:
    id: str
    name: str
    vendor: str = ""
    catalog: str = ""
    aliases: list[str] = field(default_factory=list)
    unit: str = "kDa"
    sizes: list[float] = field(default_factory=list)
    systems: list[LadderSystem] = field(default_factory=list)
    reference_bands: list[float] = field(default_factory=list)
    notes: str = ""
    #: the vendor's datasheet or product page
    source: str = ""
    builtin: bool = False

    @property
    def catalogs(self) -> str:
        return "/".join(c for c in [self.catalog] + self.aliases if c)

    @property
    def display_name(self) -> str:
        return f"{self.name} ({self.catalogs})" if self.catalogs else self.name

    def system(self, key: Optional[str]) -> Optional[LadderSystem]:
        if key is None:
            return None
        k = key.lower()
        return (next((s for s in self.systems if s.id == key or s.name == key), None)
                or next((s for s in self.systems if k in s.name.lower()), None))

    def to_json(self):
        return {"id": self.id, "name": self.name, "vendor": self.vendor, "catalog": self.catalog,
                "aliases": self.aliases, "unit": self.unit, "sizes": self.sizes,
                "systems": [{"id": s.id, "name": s.name, "sizes": s.sizes} for s in self.systems],
                "referenceBands": self.reference_bands, "notes": self.notes, "source": self.source,
                "builtin": self.builtin}

    @staticmethod
    def from_json(d, builtin: bool) -> "LadderPreset":
        return LadderPreset(d["id"], d["name"], d.get("vendor", ""), d.get("catalog", ""), list(d.get("aliases", [])),
                            d.get("unit", "kDa"), [float(x) for x in d.get("sizes", [])],
                            [LadderSystem(s["id"], s["name"], [float(x) for x in s["sizes"]])
                             for s in d.get("systems", [])],
                            [float(x) for x in d.get("referenceBands", [])], d.get("notes", ""), d.get("source", ""),
                            builtin)


def _resource(name: str) -> Path:
    base = Path(getattr(sys, "_MEIPASS", Path(__file__).parent))   # PyInstaller unpacks next to the exe
    p = base / name
    return p if p.exists() else Path(__file__).parent / name


def _builtin() -> list[LadderPreset]:
    with open(_resource("ladders.json"), encoding="utf-8") as f:
        return [LadderPreset.from_json(d, True) for d in json.load(f)]


BUILTIN = _builtin()


def user_path() -> Path:
    """%APPDATA%\\GelScribe\\ladders.json on Windows, the Mac app's own file on a Mac."""
    if sys.platform == "win32":
        base = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
    elif sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return base / "GelScribe" / "ladders.json"


def load_user() -> list[LadderPreset]:
    try:
        with open(user_path(), encoding="utf-8") as f:
            return [LadderPreset.from_json(d, False) for d in json.load(f)]
    except (OSError, ValueError, KeyError):
        return []


def save_user(presets: list[LadderPreset]) -> None:
    p = user_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump([x.to_json() for x in presets if not x.builtin], f, indent=2, sort_keys=True, ensure_ascii=False)
    os.replace(tmp, p)


def all_presets() -> list[LadderPreset]:
    return BUILTIN + load_user()


def preset(id: str) -> Optional[LadderPreset]:
    return next((p for p in all_presets() if p.id == id), None)


def find_by_display_name(name: Optional[str]) -> Optional[LadderPreset]:
    if not name:
        return None
    return next((p for p in all_presets() if p.display_name == name), None)


def find(query: str) -> Optional[LadderPreset]:
    """A loose lookup for the command line: an id, a catalog number, or part of a name, ignoring case."""
    q = query.strip().lower()
    presets = all_presets()
    return (next((p for p in presets if p.id == q), None)
            or next((p for p in presets if p.catalog.lower() == q or q in (a.lower() for a in p.aliases)), None)
            or next((p for p in presets if p.name.lower() == q), None)
            or next((p for p in presets if q in p.name.lower() or q in p.display_name.lower()), None))
