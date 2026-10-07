"""The naming scheme of a figure, everything not tied to one image, so it can be reused on the next gel: label rows,
row titles, title, band names, ladder settings and text sizes. With positions, also the image-specific geometry
(lane dividers, crop, tick and name positions), for gels scanned with the same framing. Same JSON as the Mac app's
clipboard format, so labels copy between the two.

A scheme carries only the marks of the gel with the lanes: the ticks and names of stacked gels belong to those gels,
which another project doesn't have. It never carries the export resolution, which belongs to the project it's set in."""
from __future__ import annotations

import copy
import json
from dataclasses import dataclass
from typing import Optional

from .model import (BandAnnotation, FigureStyle, GelProject, LabelRow, Ladder, Lanes, PixelRect)

#: clipboard type, the same as the Mac app's
MIME = "application/x-gelscribe-scheme"
MAC_TYPE = "local.gelscribe.scheme"


def _lanes_gel_only(annotations: list[BandAnnotation], style: FigureStyle, ladder: Optional[Ladder]) -> list[BandAnnotation]:
    """Takes the marks of stacked gels out of a scheme's names, ladder and unit label (in place), and the export
    resolution out of its style; every name left keeps its own single-name size. Returns the names that are left."""
    keep = [i for i, a in enumerate(annotations) if a.strip is None]
    kept = [annotations[i] for i in keep]
    if len(kept) != len(annotations):
        style.remap_name_sizes(keep)
    style.export_dpi = None
    if ladder is not None:
        ladder.bands = [b for b in ladder.bands if b.strip is None]
        if ladder.unit_strip is not None:
            ladder.unit_y = ladder.unit_strip = None
    return kept


@dataclass
class LabelScheme:
    rows: list[LabelRow]
    title: Optional[str]
    annotations: list[BandAnnotation]
    ladder: Optional[Ladder]
    style: FigureStyle
    lanes: Optional[Lanes] = None
    crop: Optional[PixelRect] = None

    @staticmethod
    def of(p: GelProject, positions: bool) -> "LabelScheme":
        ladder = copy.deepcopy(p.ladder)
        if ladder is not None and not positions:
            ladder.bands, ladder.unit_y, ladder.unit_strip = [], None, None   # ticks and a placed unit label belong to one image
        style = copy.deepcopy(p.style)
        annotations = _lanes_gel_only(copy.deepcopy(p.annotations), style, ladder)
        return LabelScheme(copy.deepcopy(p.rows), p.title, annotations, ladder, style,
                           copy.deepcopy(p.lanes) if positions else None, copy.deepcopy(p.crop) if positions else None)

    def apply(self, p: GelProject, w: int, h: int) -> None:
        """Replaces the naming scheme of p. Its image, strict setting, pixel adjustments and export resolution are never
        touched, and nor are the ticks and names it has on its other gels."""
        style = copy.deepcopy(self.style)
        ladder = copy.deepcopy(self.ladder)
        mine = _lanes_gel_only(copy.deepcopy(self.annotations), style, ladder)   # no other project's gel numbers come in
        others = [i for i, a in enumerate(p.annotations) if a.strip is not None]
        old_sizes = {k: v for k, v in p.style.text_sizes.items() if k.startswith("name.")}
        dpi = p.style.export_dpi
        p.rows = copy.deepcopy(self.rows)
        p.title = self.title
        p.annotations = mine + [p.annotations[i] for i in others]
        p.style = style
        p.style.export_dpi = dpi
        for j, i in enumerate(others):   # this project's names on its other gels keep their sizes
            if f"name.{i}" in old_sizes:
                p.style.text_sizes[f"name.{len(mine) + j}"] = old_sizes[f"name.{i}"]
        if ladder is not None:
            own = p.ladder
            if not ladder.bands and own is not None:
                ladder.bands = own.bands       # keep this gel's own ticks
            elif own is not None:
                ladder.bands += [b for b in own.bands if b.strip is not None]   # and its ticks on its other gels
                ladder.bands.sort(key=lambda b: p.stack_key(b.strip, b.y))
            if ladder.unit_y is None and own is not None:
                ladder.unit_y, ladder.unit_strip = own.unit_y, own.unit_strip   # and its own unit placement
            p.ladder = ladder
        if self.lanes is not None:
            p.lanes = copy.deepcopy(self.lanes)
        if self.crop is not None:
            p.crop = self.crop.normalized(w, h)
        p.sync_lane_centers(w, h)

    def dumps(self) -> str:
        d = {"rows": [r.to_json() for r in self.rows], "annotations": [a.to_json() for a in self.annotations],
             "style": self.style.to_json()}
        if self.title is not None:
            d["title"] = self.title
        if self.ladder is not None:
            d["ladder"] = self.ladder.to_json()
        if self.lanes is not None:
            d["lanes"] = self.lanes.to_json()
        if self.crop is not None:
            d["crop"] = self.crop.to_json()
        return json.dumps(d, indent=2, sort_keys=True, ensure_ascii=False)

    @staticmethod
    def loads(text: str) -> "LabelScheme":
        """Raises ValueError for anything that isn't copied GelScribe labels. Marks that name a gel are dropped, and the
        export resolution isn't taken."""
        d = json.loads(text)
        if not isinstance(d, dict) or "rows" not in d or "style" not in d:
            raise ValueError("not copied GelScribe labels")
        ladder = Ladder.from_json(d["ladder"]) if d.get("ladder") is not None else None
        style = FigureStyle.from_json(d.get("style"))
        annotations = [BandAnnotation.from_json(a, f"annotations[{i}]") for i, a in enumerate(d.get("annotations") or [])]
        annotations = _lanes_gel_only(annotations, style, ladder)
        crop, title = d.get("crop"), d.get("title")
        if title is not None and not isinstance(title, str):
            raise ValueError("title should be text")
        return LabelScheme([LabelRow.from_json(r, f"rows[{i}]") for i, r in enumerate(d.get("rows") or [])], title,
                           annotations, ladder, style, Lanes.from_json(d["lanes"]) if d.get("lanes") is not None else None,
                           PixelRect.from_json(crop) if crop is not None else None)
