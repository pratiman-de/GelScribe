"""The update notice: ask GitHub once a day whether a newer release exists. Nothing is downloaded or installed; the
only thing sent is one GET with a User-Agent. Qt-free, and the fetch is injectable so tests need no network."""
from __future__ import annotations

import json
import re
import urllib.request
from dataclasses import dataclass
from typing import Callable, Optional

LATEST_URL = "https://api.github.com/repos/pratiman-de/GelScribe/releases/latest"
TIMEOUT = 10.0
INTERVAL = 24 * 3600.0
NOTE_LINES = 6


@dataclass(frozen=True)
class Release:
    version: str
    url: str
    notes: str


@dataclass(frozen=True)
class Result:
    status: str   # "newer", "current" or "error"
    release: Optional[Release] = None


def parse_version(text: str) -> Optional[tuple]:
    """"v0.10" -> (0, 10); numeric, so 0.10 is newer than 0.9. A suffix such as "-beta" is ignored."""
    parts = []
    for piece in str(text).strip().lstrip("vV").split("."):
        m = re.match(r"\d+", piece)
        if not m:
            break
        parts.append(int(m.group()))
        if m.end() != len(piece):
            break
    return tuple(parts) or None


def _padded(v: tuple, n: int) -> tuple:
    return v + (0,) * (n - len(v))


def is_newer(latest: str, current: str) -> bool:
    a, b = parse_version(latest), parse_version(current)
    if a is None or b is None:
        return False
    n = max(len(a), len(b))
    return _padded(a, n) > _padded(b, n)


def parse_release(data) -> Optional[Release]:
    """tag_name, html_url and body of GitHub's "latest release" JSON (bytes, str or an already parsed dict)."""
    try:
        if isinstance(data, (bytes, str)):
            data = json.loads(data)
        tag = str(data["tag_name"]).strip()
        version = tag[1:] if tag[:1] in "vV" else tag
        url = str(data["html_url"])
        if parse_version(version) is None or not url.startswith("https://"):   # (the Mac app takes only https links too)
            return None
        return Release(version, url, str(data.get("body") or ""))
    except (ValueError, KeyError, TypeError, AttributeError):
        return None


def notes_excerpt(body: str, lines: int = NOTE_LINES) -> str:
    """The first few non-empty lines of the release notes, markdown headings without their #."""
    out = [ln.strip().lstrip("#").strip() for ln in str(body).splitlines()]
    return "\n".join([ln for ln in out if ln][:lines])


def fetch_latest(version: str) -> bytes:
    req = urllib.request.Request(LATEST_URL, headers={"User-Agent": f"GelScribe/{version}"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return r.read()


def check(fetch: Callable[[str], object], current: str) -> Result:
    """Ask for the latest release. Any failure (offline, rate limit, bad JSON) is just "error"."""
    try:
        release = parse_release(fetch(current))
    except Exception:
        return Result("error")
    if release is None:
        return Result("error")
    return Result("newer" if is_newer(release.version, current) else "current", release)


def due(enabled: bool, last: Optional[float], now: float, manual: bool = False) -> bool:
    """The automatic check runs when it is on and 24 hours have passed; Help › Check for Updates… always runs."""
    if manual:
        return True
    if not enabled:
        return False
    return last is None or now - last >= INTERVAL or now < last
