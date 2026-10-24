"""Colour images stay in colour: rotation, display range and stretch go to each channel, in the figure, in stacks, on screen."""
import io

import numpy as np
import pytest
from PIL import Image

from PySide6.QtWidgets import QApplication

QApplication.instance() or QApplication([])   # before anything draws, so this file also passes when run alone

from test_app import app, close, settle, show, win   # noqa: E402,F401 (fixtures)
from test_gels import cut_blot, piece_png, stack, working

from gelscribe.app.main import Controller
from gelscribe.core import strips as stacked
from gelscribe.core.image import HEIC_MESSAGE, ImageError, SourceImage, WorkingImage
from gelscribe.core.model import DisplaySettings, GelProject
from gelscribe.core.package import GelPackage


def colour_png(width=300, height=200, bits=8) -> bytes:
    """Red rises left to right, green top to bottom, blue is flat: distinct channels everywhere."""
    yy, xx = np.mgrid[0:height, 0:width]
    a = np.stack([xx * 255 // (width - 1), yy * 255 // (height - 1), np.full((height, width), 90)], axis=-1).astype(np.uint8)
    buf = io.BytesIO()
    Image.fromarray(a).save(buf, format="PNG")
    return buf.getvalue()


def adjusted(p: GelProject) -> GelProject:
    p.strict = False
    p.rotate_deg = 3.0
    p.display = DisplaySettings(black=0.1, white=0.8, gamma=1.3)
    return p


def test_adjusted_rgb_gel_stays_colour():
    pkg = GelPackage.create(colour_png(), "c.png")
    p = adjusted(pkg.project)
    w = WorkingImage(SourceImage(pkg.image_data), p)
    gel = w.figure_image(p)
    assert gel.dtype == np.uint8 and gel.shape == (200, 300, 3)
    mid = gel[100, 100:200]
    assert not np.array_equal(mid[:, 0], mid[:, 1]) and not np.array_equal(mid[:, 1], mid[:, 2])
    # the channels are mapped the way the gray path maps its one: a gray RGB image gives three equal channels
    g = np.repeat(np.array(Image.open(io.BytesIO(piece_png(120, 80, [30], [40]))))[..., None], 3, axis=2)
    buf = io.BytesIO()
    Image.fromarray(g).save(buf, format="PNG")
    pg = adjusted(GelPackage.create(buf.getvalue(), "g.png").project)
    out = WorkingImage(SourceImage(buf.getvalue()), pg).figure_image(pg)
    assert (out[..., 0] == out[..., 1]).all() and (out[..., 1] == out[..., 2]).all()
    # and the screen shows it in colour too
    v = w.view_image(p)
    assert v.ndim == 3 and np.array_equal(v, w.figure_image(p))
    p.strict = True   # Keep original pixels: the figure is the original, the screen colour with the display range
    assert np.array_equal(w.figure_image(p), w.source.pixels)
    v = w.view_image(p)
    assert v.ndim == 3 and not np.array_equal(v[..., 0], v[..., 1])
    p.display = DisplaySettings()
    assert np.array_equal(w.view_image(p), w.source.pixels)
    assert w.view_image(p, enhance=True).ndim == 3


def test_gray_gel_is_unchanged():
    pkg = GelPackage.create(piece_png(200, 100, [50, 120], [50]), "g.png")
    p = adjusted(pkg.project)
    w = WorkingImage(SourceImage(pkg.image_data), p)
    assert w.figure_image(p).ndim == 2 and w.view_image(p).ndim == 2


def test_colour_gel_in_a_stack_makes_the_composite_colour():
    pkg = cut_blot()   # gray gels
    pkg.add_strip(colour_png(700, 220), "c.png")
    p = pkg.project
    p.strict = False
    for s in p.strips:
        s.strict = False
    p.strips[1].display = DisplaySettings(black=0.1, white=0.8)
    p.strips[1].rotate_deg = 2.0
    w = working(pkg)
    g = stack(pkg, w)
    fig = stacked.figure_image(w[0], w[1], p, g)
    assert fig.dtype == np.uint8 and fig.ndim == 3
    q = g.piece(2)
    below = fig[int(q.top - g.crop.y0):int(q.bottom - g.crop.y0)]
    assert not np.array_equal(below[..., 0], below[..., 1]) and not np.array_equal(below[..., 1], below[..., 2])
    top = fig[:100]   # gray gels as red = green = blue
    assert (top[..., 0] == top[..., 1]).all() and (top[..., 1] == top[..., 2]).all()
    views = [x.view_image(pp) for x, pp in zip([w[0]] + w[1], [p] + [p.strip_project(k + 1) for k in range(2)])]
    v = stacked.view_image(views, g)
    assert v.ndim == 3
    note = stacked.StackedFigure(p, w[0], w[1]).info().description
    assert note.count("converted to 8-bit RGB") == 2
    assert fig.shape == stacked.StackedFigure(p, w[0], w[1]).gel.shape
    # an 8-bit RGB gel that was adjusted says nothing extra
    only = stacked.converted_storage(p, [x.source for x in [w[0]] + w[1]])
    assert only == "8-bit RGB" and stacked.unconverted_gels(p, [x.source for x in [w[0]] + w[1]]) == [2]
    assert "c.png" in note.split("3. ")[1] and "converted" not in note.split("3. ")[1]


def test_single_colour_gel_note_says_converted_only_when_it_was_not_8_bit_rgb():
    from gelscribe.core import render
    p = GelPackage.create(colour_png(), "c.png").project
    p.strict = False
    assert stacked.converted_storage(p, [SourceImage(colour_png())]) is None
    assert "converted" not in render.export_info(p, None, storage=None).description
    assert "converted to 8-bit RGB" in render.export_info(p, None, storage="8-bit RGB").description


def test_screen_shows_the_colour_stack(app, tmp_path):
    path = tmp_path / "c.png"
    path.write_bytes(colour_png(600, 420))
    w = show(Controller(app), GelPackage.create_from(path))
    try:
        ws = w.ws
        ws.add_gel(colour_png(600, 300), "d.png")
        settle()
        assert ws.view_array.ndim == 3
        img = ws.display_cropped()
        assert img is not None and not img.isGrayscale()
    finally:
        close(w)


def test_heic_is_refused_with_the_python_message():
    data = b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic" + b"\x00" * 64
    with pytest.raises(ImageError) as e:
        SourceImage(data)
    assert str(e.value) == "HEIC images aren't supported in the Python version. Export the image as PNG or TIFF and open that."
    assert HEIC_MESSAGE == str(e.value)


def test_mixed_stack_kept_16_bit_gray_with_a_colour_gel_is_16_bit_rgb():
    import tifffile
    from gelscribe.core import ops
    from test_gels import MAIN_LANES
    yy, xx = np.mgrid[0:160, 0:620]
    raw = ((xx * 90 + yy * 17) % 60000 + 100).astype(np.uint16)
    buf = io.BytesIO()
    tifffile.imwrite(buf, raw, photometric="minisblack")
    pkg = GelPackage.create(buf.getvalue(), "a.tif")
    ops.set_dividers(pkg.project, [(a + b) / 2 for a, b in zip(MAIN_LANES, MAIN_LANES[1:])], 620, 160)
    pkg.add_strip(colour_png(620, 200), "c.png")
    p = pkg.project
    p.strict = True
    p.strips[0].strict = False
    p.strips[0].display = DisplaySettings(black=0.1, white=0.8)
    w = working(pkg)
    g = stack(pkg, w)
    fig = stacked.figure_image(w[0], w[1], p, g)
    assert fig.dtype == np.uint16 and fig.ndim == 3
    assert np.array_equal(fig[:160, :, 0], raw) and np.array_equal(fig[:160, :, 1], raw) and np.array_equal(fig[:160, :, 2], raw)
    q = g.piece(1)
    below = fig[int(q.top - g.crop.y0):int(q.bottom - g.crop.y0)]
    assert (below % 257 == 0).all() and not np.array_equal(below[..., 0], below[..., 1])
    note = stacked.StackedFigure(p, w[0], w[1]).info().description
    assert "original values, copied to all three channels" in note.split("1. ")[1].split("2. ")[0]
    assert "converted to 16-bit RGB (values times 257)" in note.split("2. ")[1]


def test_display_change_reuses_the_cached_levels_and_matches_the_float_path():
    from gelscribe.core.image import render_gray
    pkg = GelPackage.create(colour_png(), "c.png")
    p = adjusted(pkg.project)
    w = WorkingImage(SourceImage(pkg.image_data), p)
    a = w.view_image(p)
    lv = w.levels(color=True)
    p.display = DisplaySettings(black=0.2, white=0.7, gamma=0.8, invert=True)
    b = w.view_image(p)
    assert w.levels(color=True) is lv and not np.array_equal(a, b)
    assert np.array_equal(b, render_gray(w._processed(color=True), p.display))


def test_the_copied_to_all_three_channels_note_sits_where_the_mac_app_puts_it():
    """The mixed figure's per-gel list is word for word the Mac app's: the "original values, copied …" phrase comes right after
    "as above (its lanes are the figure's)" or "original pixels", before the turn, the columns and the rest."""
    from test_gels import piece_png
    gray = GelPackage.create(piece_png(240, 160, [60, 120], [80]), "g.png")
    gray.add_strip(colour_png(240, 160), "c.png")
    p = gray.project
    p.turn = 1   # strict, gray, turned; the colour gel below is processed
    w = working(gray)
    note = stacked.StackedFigure(p, w[0], w[1]).info().description
    assert "1. g.png, as above (its lanes are the figure's), original values, copied to all three channels, turned 90°, columns " in note
    assert "original values, copied to all three channels" not in note.split("2. ")[1]
    colour = GelPackage.create(colour_png(240, 160), "c.png")
    colour.add_strip(piece_png(240, 160, [60, 120], [80]), "g.png")
    q = colour.project
    q.strict = False
    q.strips[0].strict = True
    q.strips[0].turn = 1
    w = working(colour)
    note = stacked.StackedFigure(q, w[0], w[1]).info().description
    assert ", original pixels, original values, copied to all three channels, turned 90°, columns " in note.split("2. ")[1]
