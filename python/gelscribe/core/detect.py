"""Band snapping, lane and band detection, with SciPy (the Mac app reproduces these same SciPy functions)."""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Optional

import numpy as np
from scipy.ndimage import gaussian_filter, gaussian_filter1d
from scipy.signal import find_peaks, peak_widths

from .model import sround


def _half_max_center(prof: np.ndarray, peaks: np.ndarray, props: dict) -> list[tuple[float, float, float]]:
    """(left, right, centre) of each peak at half its prominence, as scipy.signal.peak_widths gives them."""
    if len(peaks) == 0:
        return []
    _, _, left, right = peak_widths(prof, peaks, rel_height=0.5,
                                    prominence_data=(props["prominences"], props["left_bases"], props["right_bases"]))
    return [(float(l), float(r), (float(l) + float(r)) / 2) for l, r in zip(left, right)]


def snap_band(dark: np.ndarray, x: float, y: float, lane_width: float, window: float = 25) -> Optional[float]:
    """The centre of the band under a click: the nearest peak (half-max midpoint) in the lane around x within
    ±window px of y. None when nothing band-like is there; the caller keeps the raw click."""
    h, w = dark.shape
    half = max(3.0, lane_width * 0.25)
    x0, x1 = max(0, int(x - half)), min(w, int(x + half) + 1)
    pad = int(window) + 40
    y0, y1 = max(0, int(y) - pad), min(h, int(y) + pad + 1)
    if x0 >= x1 or y1 - y0 <= 5:
        return None
    prof = dark[y0:y1, x0:x1].mean(axis=1).astype(np.float64)
    prof = gaussian_filter1d(prof, sigma=2, mode="reflect", truncate=4.0)
    top = float(prof.max())
    if top <= 2:
        return None
    peaks, props = find_peaks(prof, prominence=max(1.5, 0.12 * top), distance=6)
    local = y - y0
    best = None
    for l, r, c in _half_max_center(prof, peaks, props):
        d = 0.0 if l <= local <= r else abs(c - local)
        if d <= window and (best is None or d < best[0]):
            best = (d, c)
    if best is None:
        return None
    return float(math.floor(y0 + best[1] + 0.5))


# ---------------------------------------------------------------------------------------------------- detection


@dataclass
class LaneFit:
    centers: list[float] = field(default_factory=list)
    width: float = 0.0
    pitch: float = 0.0


@dataclass
class DetectedBand:
    #: midpoint of the half-maximum interval, which stays right on saturated, flat-topped bands
    y: float
    fwhm: float
    prominence: float


def lanes(dark: np.ndarray, count: Optional[int] = None) -> LaneFit:
    """An evenly spaced comb (pitch and offset) fitted to the lane profile, as the Mac app fits it.

    The profile is log(1 + the darkest value in each column), so faint lanes weigh nearly as much as saturated ones and
    a strong/weak pattern (load and pellet pairs) doesn't pull the pitch to twice the real spacing. With count the comb
    has exactly that many teeth; without it, the pitch comes from the first autocorrelation peak of the lane mask."""
    h, w = dark.shape
    if w < 3 or h < 1:
        return LaneFit()
    colmax = gaussian_filter(dark.astype(np.float64), sigma=2, mode="reflect", truncate=4.0).max(axis=0)
    prof = gaussian_filter1d(np.log1p(colmax), sigma=3, mode="reflect", truncate=4.0)
    on = colmax > 0.15 * colmax.max()
    xs = np.arange(w, dtype=np.float64)

    if count is not None and count >= 2:
        pitches = np.arange(40.0, (w - 1) / (count - 1), 0.25)
    else:
        m = gaussian_filter1d(on.astype(np.float64), sigma=3, mode="reflect", truncate=4.0)
        m -= m.mean()
        ac = np.correlate(m, m, mode="full")[w - 1:]
        ac /= ac[0] if ac[0] != 0 else 1.0
        lo, hi = min(20, w), max(20, min(w, w // 2))
        peaks, _ = find_peaks(ac[lo:hi], height=0.15, prominence=0.1) if hi > lo else (np.array([], int), {})
        lag = float(peaks[0] + 20) if len(peaks) else w / 4
        pitches = np.arange(0.9 * lag, 1.1 * lag, 0.25)

    best = (-math.inf, 0.0, 0.0)   # score, pitch, offset
    for p in pitches:
        n = count if count is not None else int((w - 1) / p) + 1
        offsets = np.arange(0.0, (w - 1) - (n - 1) * p, 1.0) if count is not None else np.arange(0.0, p, 1.0)
        if n < 2 or offsets.size == 0:
            continue
        k = np.arange(n, dtype=np.float64)
        teeth = offsets[:, None] + p * k[None, :]
        valid = teeth < w - 1           # the comb stops at the image's right edge
        gaps = valid & (k[None, :] > 0)
        n_c, n_g = valid.sum(axis=1), gaps.sum(axis=1)
        sum_c = np.where(valid, np.interp(teeth, xs, prof), 0.0).sum(axis=1)
        sum_g = np.where(gaps, np.interp(teeth - p / 2, xs, prof), 0.0).sum(axis=1)
        ok = (n_c >= 2) & (n_g >= 1)
        if not ok.any():
            continue
        # contrast between lane centres and gaps, normalised so the number of teeth alone can't win
        score = np.where(ok, sum_c / np.maximum(n_c, 1) - sum_g / np.maximum(n_g, 1), -np.inf)
        i = int(np.argmax(score))      # the first of equal maxima, as the Mac app takes it
        if score[i] > best[0]:
            best = (float(score[i]), float(p), float(offsets[i]))
    _, pitch, offset = best
    if pitch <= 0:
        return LaneFit()

    if count is not None:
        teeth = [offset + pitch * i for i in range(count)]
    else:
        teeth = list(np.arange(offset, w - 1, pitch))
        vals = np.interp(teeth, xs, prof)
        med = float(np.median(vals)) if len(vals) else 0.0
        teeth = [t for t, v in zip(teeth, vals) if v > 0.6 * med]

    widths = []
    for c in teeth:
        lo, hi = max(0, int(c - pitch / 2)), min(w, int(c + pitch / 2))
        idx = np.nonzero(on[lo:hi])[0] if lo < hi else []
        if len(idx):
            widths.append(float(idx[-1] - idx[0] + 1))
    width = float(np.median(widths)) if widths else 0.8 * pitch
    return LaneFit([sround(float(t) * 10) / 10 for t in teeth], sround(min(width, 0.9 * pitch)),
                   sround(pitch * 100) / 100)


def lane_profile(dark: np.ndarray, center: float, width: float) -> np.ndarray:
    """The vertical profile of one lane: the mean over its central half, smoothed (sigma 2 px)."""
    h, w = dark.shape
    x0, x1 = max(0, int(center - width * 0.25)), min(w, int(center + width * 0.25) + 1)
    if x0 >= x1:
        return np.zeros(h)
    prof = dark[:, x0:x1].mean(axis=1).astype(np.float64)
    return gaussian_filter1d(prof, sigma=2, mode="reflect", truncate=4.0)


def bands(dark: np.ndarray, center: float, width: float, rel_prominence: float = 0.15) -> list[DetectedBand]:
    """Bands along a lane: peaks at least rel_prominence of the lane's maximum high and 12 px apart."""
    prof = lane_profile(dark, center, width)
    top = float(prof.max()) if prof.size else 0.0
    if top <= 0:
        return []
    peaks, props = find_peaks(prof, prominence=rel_prominence * top, distance=12)
    return [DetectedBand(sround(c), sround((r - l) * 10) / 10, sround(float(pr) * 10) / 10)
            for (l, r, c), pr in zip(_half_max_center(prof, peaks, props), props.get("prominences", []))]
