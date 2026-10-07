#!/usr/bin/env python3
"""Makes the three example scans that the tutorials use: example-blot.png, top-piece.png and bottom-piece.png.

Every scan here is invented. They are drawn from scratch with numpy, a fixed random seed and made-up numbers, to look
like 700 nm fluorescence western blots (dark bands on a light membrane, shown as an 8-bit gray image). None of them is
traced from, or measured on, a real scan, and the protein bands sit at made-up sizes.

    python make-examples.py

writes the three PNG files next to this script. It needs numpy and Pillow. The same seed gives the same files every time.

The pictures
  example-blot.png   12 lanes (a ladder and 11 samples), tilted by 2.4 degrees (the bands fall to the right) so the
                     tutorial's Straighten step has something to do. The sample band "Protein X" runs at 45 kDa and
                     grows with the dose, and there are a few weaker bands and the dye front.
  top-piece.png      the top part of a cut membrane, 13 lanes (a ladder and 12 samples), tilted by 1.3 degrees (the
                     bands climb to the right): the ladder from 140 to 50 kDa, and "Protein X" at 100 kDa.
  bottom-piece.png   the bottom part of the same membrane, scanned about 2.5% larger and shifted sideways, so Auto-align
                     has to stretch and move it: the ladder from 40 to 10 kDa, a strong "Loading control" band at
                     30 kDa in every sample lane, and the dye front near the bottom edge.
"""
import math
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
SEED = 20261006

# The PageRuler Prestained ladder as it runs on a NuPAGE Bis-Tris 4-12% gel in MES buffer (the sizes GelScribe lists).
LADDER = [140, 115, 80, 70, 50, 40, 30, 25, 15, 10]
# How strongly each ladder band shows at 700 nm, as an optical density at the band's peak: the blue bands are bright,
# the orange 70 kDa band is dim and the green 10 kDa band is in between.
LADDER_STRENGTH = {140: 1.35, 115: 1.5, 80: 1.6, 70: 0.42, 50: 1.55, 40: 1.5, 30: 1.45, 25: 1.4, 15: 1.2, 10: 0.95}


@dataclass
class Band:
    row: float                # where the band sits at the middle of its lane, down the membrane
    strength: float           # optical density at the peak: the pixel is the background times exp(-strength)
    sigma: float              # vertical spread in pixels
    smear: float = 0.10       # how much of the band trails off below it, as a fraction of its strength
    reach: float = 1.0        # how much wider than the lane the band is
    skew: float = 0.0         # thicker on one side of the lane than the other


@dataclass
class Lane:
    center: float             # across the membrane
    half: float               # half the lane's width
    mobility: float = 1.0     # this lane's bands ran a little farther (above 1) or less far (below 1)
    bow: float = 2.0          # how much this lane's bands curve up at their ends
    tilt: float = 0.0         # how much they lean, in pixels per pixel across
    bands: list = field(default_factory=list)


# ---------------------------------------------------------------------------------------------------- small tools


def smooth_field(rng, shape, cells, amp):
    """A smooth random field: random values on a coarse grid, blown up with bicubic interpolation (mean 0, std amp)."""
    h, w = shape
    grid = rng.normal(size=(cells[0] + 2, cells[1] + 2)).astype(np.float32)
    big = np.asarray(Image.fromarray(grid).resize((w, h), Image.BICUBIC), dtype=np.float32)
    return amp * (big - big.mean()) / big.std()


def blur(a, sigma):
    """A Gaussian blur, one direction at a time."""
    r = max(1, int(math.ceil(3 * sigma)))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2)
    k = (k / k.sum()).astype(np.float32)
    p = np.pad(a, ((r, r), (0, 0)), mode="reflect")
    out = np.zeros_like(a)
    for j, kj in enumerate(k):
        out += kj * p[j:j + a.shape[0]]
    p = np.pad(out, ((0, 0), (r, r)), mode="reflect")
    out = np.zeros_like(a)
    for j, kj in enumerate(k):
        out += kj * p[:, j:j + a.shape[1]]
    return out


def wander(rng, lo, hi, amp, wavelength, jag=0.0):
    """A line that drifts up and down by about amp over lengths of about `wavelength`, with a little jaggedness on top.
    Returns a function of position."""
    t = np.arange(lo, hi, dtype=np.float64)

    def curve(wave, size):
        sigma = wave / 2.5
        pad = int(4 * sigma) + 1
        raw = rng.normal(size=len(t) + 2 * pad)
        k = np.exp(-0.5 * (np.arange(-pad, pad + 1) / sigma) ** 2)
        c = np.convolve(raw, k / k.sum(), mode="same")[pad:pad + len(t)]
        return size * (c - c.mean()) / c.std()

    f = curve(wavelength, amp)
    if jag:
        f = f + curve(3.0, jag)
    return lambda x: np.interp(x, t, f).astype(np.float32)


def smoothstep(x):
    x = np.clip(x, 0, 1)
    return x * x * (3 - 2 * x)


# ---------------------------------------------------------------------------------------------------- the lanes


def physical_lanes(rng, count, pitch, first, half_fraction):
    """The lanes of one membrane: not quite evenly spaced, not quite the same width, each running a little differently.
    Cut pieces of one membrane share these."""
    spacing = pitch * np.clip(1 + 0.012 * rng.normal(size=count - 1), 0.97, 1.03)
    centers = first + np.concatenate([[0.0], np.cumsum(spacing)]) + 1.4 * rng.normal(size=count)
    lanes = [Lane(center=float(c), half=float(half_fraction * pitch * (1 + 0.05 * rng.normal())),
                 mobility=float(1 + 0.0035 * rng.normal()), tilt=float(0.012 * rng.normal())) for c in centers]
    for lane in lanes:
        lane.bow = float(max(0.2, 0.06 * lane.half * (1 + 0.55 * rng.normal())))
    return lanes


def put_ladder(lane, rng, row_of, sizes, sigma):
    for k in sizes:
        lane.bands.append(Band(row_of(k) + 0.8 * rng.normal(), LADDER_STRENGTH[k], sigma * 1.15, smear=0.06))


def pick(rng, lo, hi):
    return float(rng.uniform(lo, hi))


# ---------------------------------------------------------------------------------------------------- drawing a scan


def coordinates(spec):
    """Where each pixel of the scan is on the membrane: (x, y, u, v) with u across the lanes and v down the gel, measured
    from the top of this piece (spec["v0"] is where that is in the whole membrane, for a piece cut from a longer one)."""
    w, h = spec["size"]
    mw, mh = spec["membrane"]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    th = math.radians(spec["angle"])
    c, s = math.cos(th), math.sin(th)
    dx, dy = xx - (w / 2 + spec["offset"][0]), yy - (h / 2 + spec["offset"][1])
    u = (dx * c + dy * s) / spec["scale"] + mw / 2
    v = (-dx * s + dy * c) / spec["scale"] + mh / 2
    return xx, yy, u, v


def outline(rng, spec):
    """The membrane's hand-cut edges, each a line that wanders a little: top, bottom, left and right."""
    mw, mh = spec["membrane"]
    return (wander(rng, -100, int(mw) + 100, spec["edges"][0], 150, 0.8), wander(rng, -100, int(mw) + 100, spec["edges"][1], 220, 0.5),
            wander(rng, -100, int(mh) + 100, spec["edges"][2], 180, 0.5), wander(rng, -100, int(mh) + 100, spec["edges"][3], 180, 0.5))


def distance_inside(u, v, spec, edges):
    """How far each point is inside the membrane's outline (negative outside), with one corner cut off."""
    mw, mh = spec["membrane"]
    top, bottom, left, right = edges
    inside = np.minimum(np.minimum(u - left(v), mw + right(v) - u), np.minimum(v - top(u), mh + bottom(u) - v))
    if spec.get("chop"):
        inside = np.minimum(inside, (u + v - spec["chop"]) / 1.414)
    return inside


def draw(spec, lanes, seed):
    """One scan: the membrane (turned, scaled and moved as the scanner bed saw it) with the lanes' bands, the uneven
    background, a lighter or darker scanner bed around it, dust and noise. Returns an 8-bit gray array.

    spec describes the scan:
      size           the picture's width and height in pixels
      membrane       the membrane's width and height, in membrane pixels
      scale, angle   how much larger the scanner saw it, and how far it was turned (degrees, positive is clockwise on
                     screen); offset moves it sideways and up or down from the middle of the picture
      v0             where this piece starts down the whole membrane (for a piece cut from a longer one)
      wells, run     the row where the lanes start, and how far the longest run goes; smile is how much farther the
                     middle lanes ran than the outer ones at that distance
      edges, chop    how much the top, bottom, left and right edges wander; the size of the corner cut off
      level, outside the membrane's gray level, and how much lighter or darker the bed around it is
      slope, uneven, mottle, rim   the background: a gradient across the picture, blotches, fine mottling, and the
                     slightly different gray along the membrane's edge
      specks, noise  specks of dust, and the strength of the noise"""
    rng = np.random.default_rng(seed)
    w, h = spec["size"]
    scale = spec["scale"]
    xx, yy, u, v = coordinates(spec)
    inside = distance_inside(u, v, spec, outline(rng, spec))
    mask = smoothstep(inside * scale / 1.6 + 0.5)
    rim = np.exp(-(np.maximum(inside, 0) * scale / 2.6) ** 2) * mask

    # the bands, as optical density
    dens = np.zeros((h, w), np.float32)
    for lane in lanes:
        draw_lane(dens, u, v, lane, spec)
    dens *= mask
    low = dens[::3, ::3]
    low = blur(np.ascontiguousarray(low), 3.5)   # a faint glow around strong bands
    dens += 0.045 * np.asarray(Image.fromarray(low).resize((w, h), Image.BICUBIC), dtype=np.float32) * mask

    # the background: light gray on the membrane, a little different off it, uneven everywhere
    level = spec["level"]
    on = level * (1 + spec["slope"][0] * (xx / w - 0.5) + spec["slope"][1] * (yy / h - 0.5))
    on = on + smooth_field(rng, (h, w), (4, 6), spec["uneven"]) + smooth_field(rng, (h, w), (max(3, h // 45), max(3, w // 45)), spec["mottle"])
    off = level + spec["outside"] + smooth_field(rng, (h, w), (3, 5), 0.7 * spec["uneven"])
    background = mask * on + (1 - mask) * off - spec["rim"] * rim
    pixels = 1.5 + (background - 1.5) * np.exp(-dens)

    # dust on the glass
    for _ in range(spec["specks"]):
        cx, cy = rng.uniform(0, w), rng.uniform(0, h)
        sig = rng.uniform(0.7, 2.0)
        amp = rng.choice([-1, 1], p=[0.8, 0.2]) * rng.uniform(8, 32)
        x0, x1, y0, y1 = int(max(cx - 6 * sig, 0)), int(min(cx + 6 * sig + 1, w)), int(max(cy - 6 * sig, 0)), int(min(cy + 6 * sig + 1, h))
        gx, gy = np.meshgrid(np.arange(x0, x1), np.arange(y0, y1))
        pixels[y0:y1, x0:x1] += amp * np.exp(-((gx - cx) ** 2 + (gy - cy) ** 2) / (2 * sig ** 2))

    # a little sensor blur, then the noise: fine grain, a softer grain, and a slight difference from one scan line to the next
    pixels = blur(pixels.astype(np.float32), 0.7)
    noise = rng.normal(0, spec["noise"], (h, w)) + blur(rng.normal(0, 1, (h, w)).astype(np.float32), 1.1) * 3.2 \
        + rng.normal(0, 0.5, (h, 1))
    return np.clip(np.rint(pixels + noise), 0, 255).astype(np.uint8)


def draw_lane(dens, u, v, lane, spec):
    """Adds one lane's bands to the optical density map."""
    c, half = lane.center, lane.half
    edge = 0.14 * half
    near = np.abs(u - c) < half * 1.4 + 6 * edge + 10
    rows, cols = np.nonzero(near.any(axis=1))[0], np.nonzero(near.any(axis=0))[0]
    if rows.size == 0:
        return
    sl = (slice(rows[0], rows[-1] + 1), slice(cols[0], cols[-1] + 1))
    uu, vv = u[sl], v[sl]
    across = (uu - c) / half
    mw = spec["membrane"][0]
    wells = spec["wells"]
    for b in lane.bands:
        reach = half * b.reach
        gx = 0.5 * (np.tanh((uu - (c - reach)) / edge) - np.tanh((uu - (c + reach)) / edge))
        whole = b.row                                    # the band's row in the whole membrane
        run = wells + (whole - wells) * lane.mobility    # this lane ran a bit more or less far
        smile = spec["smile"] * (whole - wells) / spec["run"] * (1 - ((uu - mw / 2) / (mw / 2)) ** 2)
        centre = run - spec["v0"] + smile + lane.tilt * (uu - c) - lane.bow * across ** 2
        dv = vv - centre
        sig = b.sigma * (1 + b.skew * across)
        profile = np.exp(-0.5 * (dv / sig) ** 2)
        below = np.maximum(dv, 0)
        profile += b.smear * (1 - np.exp(-below / (0.6 * sig))) * np.exp(-below / (3.2 * sig))
        dens[sl] += (b.strength * gx * profile).astype(np.float32)


# ---------------------------------------------------------------------------------------------------- the three scans


def example_blot():
    """12 lanes, tilted 2.4 degrees: a ladder, then 11 samples (a lysate and a pellet at each of five doses, and one more
    pellet at the highest). 'Protein X' runs at 45 kDa, between the 50 and 40 kDa ladder bands."""
    rng = np.random.default_rng([SEED, 1])
    per_log, row140 = 640.0, 185.0
    row_of = lambda kda: row140 + per_log * (math.log10(140) - math.log10(kda))
    lanes = physical_lanes(rng, 12, pitch=128, first=100, half_fraction=0.30)
    sigma = 7.0
    dye = row_of(10) + 98
    put_ladder(lanes[0], rng, row_of, LADDER, sigma)
    doses = [0, 0, 10, 10, 25, 25, 50, 50, 100, 100, 200]
    kinds = "LPLPLPLPLPP"
    protein_p = {0: 0.30, 10: 0.62, 25: 1.05, 50: 1.75, 100: 2.55, 200: 3.3}
    protein_l = {0: 0.16, 10: 0.24, 25: 0.44, 50: 0.80, 100: 1.30}
    cleaved_l = {0: 0.08, 10: 0.12, 25: 0.20, 50: 0.32, 100: 0.55}
    for lane, dose, kind in zip(lanes[1:], doses, kinds):
        k = 1 + 0.07 * rng.normal()
        main = (protein_p if kind == "P" else protein_l)[dose] * k
        lane.bands.append(Band(row_of(45) + rng.normal(0, 0.8), main, sigma * (1 + 0.04 * main), smear=0.12, skew=pick(rng, -0.12, 0.12)))
        lane.bands.append(Band(row_of(63) + rng.normal(0, 0.8), pick(rng, 0.30, 0.50), sigma, skew=pick(rng, -0.1, 0.1)))
        lane.bands.append(Band(row_of(33) + rng.normal(0, 0.8), cleaved_l[dose] if kind == "L" else pick(rng, 0.06, 0.14), sigma, smear=0.08))
        lane.bands.append(Band(row_of(21) + rng.normal(0, 0.8), pick(rng, 0.10, 0.22), sigma * 0.9))
        if kind == "P":
            lane.bands.append(Band(row_of(95) + rng.normal(0, 0.8), pick(rng, 0.10, 0.20), sigma * 1.1))
        lane.bands.append(Band(dye + rng.normal(0, 1.0), 1.7 * (1 + 0.06 * rng.normal()), 10.0, smear=0.2, reach=1.08))
    spec = dict(size=(1816, 1312), membrane=(1612, 1092), scale=1.0, angle=2.4, offset=(5, -3), v0=0.0, wells=60.0, run=760.0,
                smile=9.0, edges=(7.0, 3.0, 3.0, 3.0), chop=40, level=212, outside=11, slope=(-0.012, 0.010), uneven=4.0,
                mottle=1.0, rim=3.0, specks=16, noise=1.5)
    return draw(spec, lanes, [SEED, 11])


def cut_membrane(rng):
    """The lanes of the cut membrane, 13 of them, which both pieces share, and where its bands run (the whole membrane's
    rows, measured from its top edge)."""
    per_log, row140 = 430.0, 52.0
    row_of = lambda kda: row140 + per_log * (math.log10(140) - math.log10(kda))
    return physical_lanes(rng, 13, pitch=76, first=62, half_fraction=0.31), row_of


def top_piece():
    """The top of the cut membrane: the ladder from 140 to 50 kDa and 'Protein X' at 100 kDa, tilted the other way from the
    example blot, by 1.3 degrees."""
    rng = np.random.default_rng([SEED, 2])
    lanes, row_of = cut_membrane(np.random.default_rng([SEED, 20]))
    sigma = 4.3
    for lane in lanes:   # this scan's own slight differences
        lane.center += 1.2 * rng.normal()
        lane.mobility += 0.002 * rng.normal()
    put_ladder(lanes[0], rng, row_of, [140, 115, 80, 70, 50], sigma)
    doses = [0, 0, 1, 1, 5, 5, 10, 10, 25, 25, 50, 50]
    plus = {0: 0.55, 1: 0.9, 5: 1.4, 10: 2.0, 25: 2.6, 50: 3.2}
    for i, (lane, dose) in enumerate(zip(lanes[1:], doses)):
        main = plus[dose] if i % 2 else 0.30 + 0.03 * rng.normal()
        lane.bands.append(Band(row_of(100) + rng.normal(0, 0.6), main * (1 + 0.06 * rng.normal()), sigma * (1 + 0.04 * main), smear=0.12, skew=pick(rng, -0.1, 0.1)))
        lane.bands.append(Band(row_of(63) + rng.normal(0, 0.6), pick(rng, 0.30, 0.50), sigma))
        if i % 2:
            lane.bands.append(Band(row_of(128) + rng.normal(0, 0.6), pick(rng, 0.12, 0.25), sigma))
    spec = dict(size=(1260, 344), membrane=(1040, 250), scale=1.0, angle=-1.3, offset=(2, 0), v0=0.0, wells=20.0, run=560.0,
                smile=5.5, edges=(7.0, 1.5, 3.0, 3.0), chop=30, level=163, outside=9, slope=(0.010, -0.012), uneven=3.0,
                mottle=0.8, rim=2.5, specks=7, noise=1.3)
    # the cut at the bottom is straight, just below the 50 kDa band (halfway to 40 kDa)
    spec["membrane"] = (1040, (row_of(50) + row_of(40)) / 2)
    return draw(spec, lanes, [SEED, 12])


def bottom_piece():
    """The bottom of the same membrane: the ladder from 40 to 10 kDa, a strong 'Loading control' at 30 kDa in every sample
    lane and the dye front near the bottom edge. It is scanned 2.5% larger, a little turned and moved sideways."""
    rng = np.random.default_rng([SEED, 3])
    lanes, row_of = cut_membrane(np.random.default_rng([SEED, 20]))
    cut = (row_of(50) + row_of(40)) / 2
    sigma = 4.3
    for lane in lanes:
        lane.center += 1.2 * rng.normal()
        lane.mobility += 0.002 * rng.normal()
    put_ladder(lanes[0], rng, row_of, [40, 30, 25, 15, 10], sigma)
    for lane in lanes[1:]:
        lane.bands.append(Band(row_of(31.5) + rng.normal(0, 0.6), 2.6 * (1 + 0.1 * rng.normal()), sigma * 1.1, smear=0.12, skew=pick(rng, -0.1, 0.1)))
        lane.bands.append(Band(row_of(36) + rng.normal(0, 0.6), pick(rng, 0.10, 0.25), sigma))
        lane.bands.append(Band(row_of(19) + rng.normal(0, 0.6), pick(rng, 0.10, 0.30), sigma))
        lane.bands.append(Band(row_of(10) + 52 + rng.normal(0, 0.8), 1.9 * (1 + 0.06 * rng.normal()), 8.0, smear=0.2, reach=1.08))
    height = row_of(10) + 52 + 34 - cut
    spec = dict(size=(1212, 428), membrane=(1040, height), scale=1.0256, angle=0.15, offset=(-14, 0), v0=cut, wells=20.0, run=560.0,
                smile=5.5, edges=(1.5, 3.0, 3.0, 3.0), chop=0, level=214, outside=-6, slope=(-0.008, 0.012), uneven=3.5,
                mottle=0.9, rim=2.5, specks=7, noise=1.4)
    return draw(spec, lanes, [SEED, 13])


def main():
    """Writes the three scans next to this script."""
    for name, make in [("example-blot.png", example_blot), ("top-piece.png", top_piece), ("bottom-piece.png", bottom_piece)]:
        pixels = make()
        Image.fromarray(pixels).save(HERE / name, optimize=True)
        print(f"wrote {name}: {pixels.shape[1]} x {pixels.shape[0]}, 8-bit gray")


if __name__ == "__main__":
    main()
