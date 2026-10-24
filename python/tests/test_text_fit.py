"""Text that fits: fields are wide enough for their widest real value, and no panel is wider than the inspector, at the
usual scale and at 1.5 (Windows at 150%) with a larger application font. Qt sizes a spin box for the widest number its
range allows, so a huge range (±1e9) once pushed the value out of sight; these fields size for what they show."""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import tifffile

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))   # also when run as a script (the 1.5-scale test)
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_app import app  # noqa: F401 (fixture)

HERE = Path(__file__).resolve()


def gel16(path: Path) -> Path:
    yy, xx = np.mgrid[0:200, 0:300]
    img = (xx * 65535 / 299.0 + 0 * yy).astype(np.uint16)
    img[0, 0], img[0, 1] = 0, 65535
    tifffile.imwrite(path, img, photometric="minisblack")
    return path


def check(app, win) -> list[str]:
    """Everything that is cut off, as sentences (empty when nothing is)."""
    from gelscribe.app.editors import FitDoubleSpinBox, fit_width, text_width
    from PySide6.QtWidgets import QSpinBox

    bad = []
    ws, insp = win.ws, win.inspector
    fp = insp.panels["figure"]

    def holds(name, field, *texts):
        """The box's own size hint holds its widest value (the frame, padding and any buttons come on top)."""
        need = text_width(field, *texts)
        if field.sizeHint().width() < need + 8 or field.minimumSizeHint().width() < need + 8:
            bad.append(f"{name}: hint {field.sizeHint().width()}/{field.minimumSizeHint().width()} < text {need}")

    # a 16-bit image: the Minimum / Maximum fields, with a range that follows the values
    ws.choose_tab("figure")
    ws.view_changed.emit()
    app.processEvents()
    for row, v in ((fp.min_row, "0"), (fp.max_row, "65535")):
        f = row["field"]
        holds("min/max", f, "-65535", "65535", f.text())
        if f.width() < text_width(f, "65535", pad=12):
            bad.append(f"min/max field {f.width()} px cannot show 65535")
    # shift, stretch, thickness, hex, angle with their widest real values
    g = fp.gels
    for name, f, values in (("shift", g.shift, (-12345.67, 99999.5)), ("stretch", g.stretch, (-99.99, 199.99)),
                            ("thick", g.thick, (0.25, 10.0))):
        for v in values:
            f.setValue(v)
            holds(name, f, f.prefix() + f.text() + f.suffix())
    if g.hex.width() < text_width(g.hex, "#ffffff", pad=14):
        bad.append(f"hex field {g.hex.width()} px cannot show #ffffff")
    lab = insp.panels["labels"]
    lab.angle.setValue(-360)
    holds("angle", lab.angle, "-360.5°")
    # a group's From / To boxes hold lane numbers: the digits must clear the buttons, padding and frame (three digits too)
    ws.choose_tab("labels")
    ws.quick_labels = "Ladder|0{L|P}|125{L|P}"
    ws.apply_quick_labels()
    app.processEvents()
    spins = [x for x in lab.findChildren(QSpinBox) if x.isVisibleTo(lab)]
    if not spins:
        bad.append("no group lane boxes to check")
    for x in spins:
        if x.lineEdit().width() < text_width(x, str(x.maximum())) + 2:
            bad.append(f"lane box shows {x.lineEdit().width()} px, needs {text_width(x, str(x.maximum()))}")
    big = QSpinBox()
    big.setMaximum(128)
    fit_width(big, "88", str(big.maximum()), floor=52, chrome=34)
    big.show()
    app.processEvents()
    if big.lineEdit().width() < text_width(big, "128") + 2:
        bad.append(f"a three-digit lane box shows {big.lineEdit().width()} px")
    big.close()
    assert isinstance(g.shift, FitDoubleSpinBox)
    # the ladder tick and unit fields, and the label size field
    ladder = insp.panels["ladder"]
    if ladder.unit.width() < text_width(ladder.unit, "kDa", pad=14):
        bad.append("unit field cannot show kDa")
    for tab in ("labels", "ladder", "names", "figure", "export"):
        ws.choose_tab(tab)
        app.processEvents()
        panel = insp.panels[tab]
        room = insp.scroll.viewport().width()
        if panel.minimumSizeHint().width() > room:
            bad.append(f"{tab} panel needs {panel.minimumSizeHint().width()} px, the inspector shows {room}")
        for k, btn in insp.tab_buttons.items():
            if btn.width() < btn.sizeHint().width():
                bad.append(f"tab {k} is {btn.width()} px, needs {btn.sizeHint().width()}")
    return bad


def run(scale_note: str = "") -> list[str]:
    from PySide6.QtWidgets import QApplication
    from gelscribe.app import theme
    from gelscribe.app.main import Controller
    from gelscribe.core.package import GelPackage
    from test_app import show, close

    app = QApplication.instance() or QApplication([])
    theme.apply(app)
    tmp = Path(tempfile.mkdtemp())
    top = HERE.parents[2] / "docs" / "top-piece.png"
    win = show(Controller(app), GelPackage.create_from(gel16(tmp / "sixteen bit.tif")))
    try:
        if top.exists():
            win.ws.add_gels([top])
        bad = check(app, win)
        win.ws.active_strip = None
        win.ws.view_changed.emit()
        bad += check(app, win)
    finally:
        close(win)
    return bad


def test_fields_fit_their_widest_values(app):
    assert run() == []


def test_fields_fit_at_scale_1_5_with_a_larger_font():
    """Windows at 150%: its own process, because the scale is read when the application starts."""
    env = dict(os.environ, QT_SCALE_FACTOR="1.5", QT_QPA_PLATFORM="offscreen", GS_FIT_FONT_PT="11")
    r = subprocess.run([sys.executable, str(HERE)], env=env, capture_output=True, text=True, timeout=240)
    assert r.returncode == 0 and "FIT-OK" in r.stdout, r.stdout[-1500:] + r.stderr[-1500:]


if __name__ == "__main__":
    from PySide6.QtCore import QSettings
    from PySide6.QtWidgets import QApplication
    tmp = tempfile.mkdtemp()
    QSettings.setPath(QSettings.Format.IniFormat, QSettings.Scope.UserScope, tmp)
    from gelscribe.core import ladders
    ladders.user_path = lambda: Path(tmp) / "ladders.json"
    qa = QApplication([])
    pt = os.environ.get("GS_FIT_FONT_PT")
    if pt:
        f = qa.font()
        f.setPointSizeF(float(pt))
        qa.setFont(f)
    problems = run()
    for p in problems:
        print("CUT OFF:", p)
    print("FIT-OK" if not problems else "FIT-FAIL")
    sys.stdout.flush()
    os._exit(0 if not problems else 1)
