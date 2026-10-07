"""Quick labels: the bench notation for lane labels, one entry per lane separated by |, and { } to put lanes under a
label: "µM: Ladder|0{L|P}|50{L|P}|200{}". Layers nest to any depth: "WT{0{L|P}|50{L|P}}|KO{…}".
A line break inside a label is written \\n, since a real new line separates entries."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional, Union

from .model import GelProject, LabelGroup, LabelRow

#: tokens that mean "this lane is the ladder" (case-insensitive)
LADDER_TOKENS = {"ladder", "marker", "m", "mw", "std", "standard", "lad", "size marker"}


@dataclass
class Group:
    """A label over the lanes (and labels) in items."""
    text: str
    items: list


Item = Union[str, Group]   # a str is one lane


def unescape(s: str) -> str:
    return s.replace("\\n", "\n")


def escape(s: str) -> str:
    return s.replace("\n", "\\n")


def parse(text: str) -> tuple[list, list[str]]:
    """|, tab or newline separate entries; X{…} puts the entries inside under X, and X{} is X over one blank lane.
    Surrounding whitespace is trimmed; empty entries are blank lanes. Braces left open are closed at the end, and
    stray closing ones dropped, each with a warning."""
    if not text.strip():
        return [], []
    chars = list(text)
    pos = 0
    warnings: list[str] = []

    def lst(depth: int) -> list:
        nonlocal pos
        items: list = []
        label = ""
        children: Optional[list] = None

        def flush():
            nonlocal label, children
            t = unescape(label.strip())
            items.append(t if children is None else Group(t, children))
            label = ""
            children = None

        while pos < len(chars):
            c = chars[pos]
            pos += 1
            if c in "|\t\n\r":
                flush()
            elif c == "{":
                inner = lst(depth + 1)
                if children is None:
                    children = inner
                else:
                    children += inner
                    warnings.append(f"“{label.strip()}” has two {{ }}; their lanes were joined.")
            elif c == "}":
                if depth == 0:
                    warnings.append("An extra } was ignored.")
                    continue
                flush()
                return items
            else:
                label += c
        if depth > 0:
            warnings.append("A { was never closed; it was closed at the end.")
        flush()
        return items

    return lst(0), warnings


def lanes_of(items: list) -> list[str]:
    out: list[str] = []
    for it in items:
        if isinstance(it, Group):
            out += lanes_of(it.items)
        else:
            out.append(it)
    return out


def lane_count(text: str) -> int:
    """Lanes a shorthand line describes (0 when it holds nothing but blanks)."""
    items, _ = parse(split_row_name(text)[1])
    labels = lanes_of(items)
    any_group = any(isinstance(i, Group) for i in items)
    return 0 if all(l == "" for l in labels) and not any_group else len(labels)


@dataclass
class Result:
    #: rows from the gel upward: the lane labels, then one group row per layer
    rows: list[LabelRow]
    ladder_lane: Optional[int]
    per_lane: list[str]
    warnings: list[str] = field(default_factory=list)


def build(items: list, lane_count: int, known_ladder_lane: Optional[int] = None,
          row_names: Optional[list[str]] = None) -> Result:
    """Maps the entries onto lane_count lanes and builds the rows: the lane labels, then a group row per layer of
    { }, nearest the lanes first. A ladder word marks the ladder lane; with one entry fewer than lanes and a known
    ladder lane, the entries fill the other lanes. row_names title the group rows, listed from the top; they go to
    the rows nearest the lanes."""
    warnings: list[str] = []
    leaves: list[str] = []
    spans: list[list] = []   # [text, first, last, layer], 0-based leaf indices

    def walk(items: list) -> int:
        height = 0
        for it in items:
            if isinstance(it, Group):
                start = len(leaves)
                h = walk(it.items) + 1
                if len(leaves) > start:
                    spans.append([it.text, start, len(leaves) - 1, h])
                height = max(height, h)
            else:
                leaves.append(it)
        return height

    layers = walk(items)
    ladder_lane = next((i + 1 for i, s in enumerate(leaves) if s.lower() in LADDER_TOKENS), None)
    per_lane = list(leaves)
    if (len(leaves) == lane_count - 1 and ladder_lane is None and known_ladder_lane is not None
            and 1 <= known_ladder_lane <= lane_count):
        k = known_ladder_lane
        per_lane.insert(k - 1, "")
        ladder_lane = k
        for s in spans:
            if s[1] >= k - 1:
                s[1] += 1
            if s[2] >= k - 1:
                s[2] += 1
    if lane_count == 0:
        pass   # no lanes yet: keep every label; each appears as soon as its lane exists
    elif len(per_lane) > lane_count:
        warnings.append(f"{len(per_lane)} labels for {lane_count} lanes; extra labels dropped: "
                        + "|".join(per_lane[lane_count:]))
        per_lane = per_lane[:lane_count]
        spans = [[s[0], s[1], min(s[2], lane_count - 1), s[3]] for s in spans if s[1] < lane_count]
    elif len(per_lane) < lane_count:
        warnings.append(f"{len(per_lane)} labels for {lane_count} lanes; the rest are blank.")
        per_lane += [""] * (lane_count - len(per_lane))

    rows = [LabelRow("lanes", labels=per_lane)]
    for layer in range(1, layers + 1):
        groups = [LabelGroup(s[0], list(range(s[1] + 1, s[2] + 2)))
                  for s in sorted((s for s in spans if s[3] == layer), key=lambda s: s[1])]
        rows.append(LabelRow("groups", groups=groups))
    for k, name in enumerate(reversed(row_names or [])):
        if k < layers:
            rows[1 + k].name = name or None
    return Result(rows, ladder_lane, per_lane, warnings)


def split_row_name(text: str) -> tuple[list[str], str]:
    """"µM: Ladder|0{L|P}" → (["µM"], "Ladder|0{L|P}"). Several layers take titles from the top, comma-separated:
    "Strain, µM: …". A title needs a letter or symbol, so "1:10|1:100" stays a pair of lane labels."""
    colon = text.find(":")
    if colon < 0:
        return [], text
    head = text[:colon]
    if len(head) > 40 or any(c in "|{}\t\n" for c in head):
        return [], text
    names = [unescape(n.strip()) for n in head.split(",")]
    if not any(names) or not all(n == "" or any(not c.isnumeric() and c != "." for c in n) for n in names):
        return [], text
    return names, text[colon + 1:].strip()


def shorthand(p: GelProject) -> str:
    """The project's labels in the same notation, row titles first. Round-trips through parse and build."""
    lane_row = next((r for r in p.rows if r.type == "lanes"), None)
    group_rows = [r for r in p.rows if r.type == "groups"]   # from the gel upward
    lasts = [g.last for r in group_rows for g in r.groups]
    n = max(p.lane_count, len(lane_row.labels) if lane_row else 0, max(lasts) if lasts else 0)
    if n <= 0 or (lane_row is None and not group_rows):
        return ""

    def label(lane: int) -> str:
        if lane_row is not None and lane <= len(lane_row.labels):
            return escape(lane_row.labels[lane - 1])
        return ""

    def entries(lo: int, hi: int, layer: int) -> list[str]:
        if layer == 0:
            return [label(l) for l in range(lo, hi + 1)]
        out: list[str] = []
        lane = lo
        while lane <= hi:
            g = next((g for g in group_rows[layer - 1].groups if g.first <= lane <= g.last), None)
            if g is not None:
                end = min(g.last, hi)
                out.append(escape(g.text) + "{" + "|".join(entries(lane, end, layer - 1)) + "}")
                lane = end + 1
            else:
                out += entries(lane, lane, layer - 1)
                lane += 1
        return out

    items = entries(1, n, len(group_rows))
    while items and items[-1] == "":
        items.pop()
    body = "|".join(items)
    names = [escape(r.name or "") for r in reversed(group_rows)]   # from the top
    while names and names[0] == "":
        names.pop(0)
    return body if not names else ", ".join(names) + ": " + body
