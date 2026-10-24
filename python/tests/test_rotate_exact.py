"""The rotation is done in bands on every core, colour in one pass; it must give exactly what the one-channel-at-a-time version did."""
import numpy as np
import pytest

from gelscribe.core.image import quantized, render_gray, rotated, rotation_inside
from gelscribe.core.model import DisplaySettings


def reference(img, degrees, fill):
    """The rotation as it was first written: one channel at a time, over the whole picture."""
    if abs(degrees) <= 1e-6:
        return img
    if img.ndim == 3:
        fills = np.broadcast_to(np.asarray(fill, dtype=np.float32), (img.shape[2],))
        return np.stack([reference(img[..., c], degrees, float(fills[c])) for c in range(img.shape[2])], axis=-1)
    h, w = img.shape
    t = np.float32(np.radians(degrees))
    c, s = np.float32(np.cos(t)), np.float32(np.sin(t))
    cx, cy = np.float32((w - 1) / 2), np.float32((h - 1) / 2)
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    dx, dy = xs - cx, ys - cy
    sx = c * dx - s * dy + cx
    sy = s * dx + c * dy + cy
    x0, y0 = np.floor(sx).astype(np.int64), np.floor(sy).astype(np.int64)
    ok = (x0 >= 0) & (y0 >= 0) & (x0 < w - 1) & (y0 < h - 1)
    out = np.full(img.shape, fill, dtype=np.float32)
    x0o, y0o = x0[ok], y0[ok]
    fx, fy = sx[ok] - x0o, sy[ok] - y0o
    top = img[y0o, x0o] * (1 - fx) + img[y0o, x0o + 1] * fx
    bot = img[y0o + 1, x0o] * (1 - fx) + img[y0o + 1, x0o + 1] * fx
    out[ok] = top * (1 - fy) + bot * fy
    return out


@pytest.mark.parametrize("shape", [(300, 420), (700, 650, 3), (5, 9), (900, 400, 3)])
@pytest.mark.parametrize("degrees", [0.7, -2.4, 17.0, -45.0])
def test_bands_give_the_reference_pixels(shape, degrees):
    rng = np.random.default_rng(5)
    img = rng.random(shape).astype(np.float32)
    fill = 0.37 if len(shape) == 2 else np.array([0.2, 0.5, 0.9], np.float32)
    assert np.array_equal(rotated(img, degrees, fill), reference(img, degrees, fill))
    inside = rotation_inside(shape[0], shape[1], degrees)
    probe = reference(np.zeros(shape[:2], np.float32), degrees, -1.0)
    assert np.array_equal(~inside, probe < -0.5)


@pytest.mark.parametrize("shape", [(300, 420), (700, 650, 3)])
def test_levels_made_band_by_band_are_the_quantized_reference(shape):
    rng = np.random.default_rng(8)
    img = rng.random(shape).astype(np.float32)
    got = rotated(img, -3.3, 0.61, levels=True)
    assert got.dtype == np.uint16 and np.array_equal(got, quantized(reference(img, -3.3, 0.61)))
    assert np.array_equal(rotated(img, 0.0, 0.5, levels=True), quantized(img))


def test_a_big_picture_renders_the_same_in_bands():
    rng = np.random.default_rng(2)
    lv = rng.integers(0, 65536, (1100, 1100, 3)).astype(np.uint16)   # over the size that is split over the cores
    d = DisplaySettings(black=0.1, white=0.9, gamma=1.2, invert=True)
    from gelscribe.core.image import lookup_table
    assert np.array_equal(render_gray(lv, d), np.take(lookup_table(d), lv))
