"""The look, in Qt's Fusion style: dark by default like the Mac app (canvas first), or light. View › Appearance."""
from __future__ import annotations

from PySide6.QtGui import QColor, QPalette
from PySide6.QtWidgets import QApplication, QStyleFactory

ACCENT = "#3d7bf6"

DARK = dict(
    window="#1b1b1d", text="#ececee", dim="#9a9aa0", placeholder="#77777d", disabled="#6b6b70",
    field="#1f1f22", field_border="#3c3c41", panel="#2a2a2d", line="#343438", separator="#3a3a3e",
    menubar="#232326", menu="#2a2a2d", status="#202023", tooltip="#2f2f33", tooltip_border="#45454a",
    button="#38383d", button_hover="#434348", button_pressed="#4d4d53", button_disabled="#2e2e32",
    primary_disabled="#2e3a55", primary_disabled_text="#8a93a8", groove="#48484d", handle="#e8e8ea",
    handle_border="none", card="#26262a", popup="#27272a", popup_border="#3f3f44", tab_selected="#3a3a3f",
    link="#6ea0ff", danger="#ff6a5f", warn="#f0a64a", ok="#4cd964", icon="#e8e8ea",
    canvas=(27, 27, 29), page_shadow=90, hist_well=(0, 0, 0, 64), hist_bars=(255, 255, 255, 115),
    drop_border="#48484d",
)
LIGHT = dict(   # mid-gray canvas, white panels, dark text: the page and panels stand clear of the backdrop
    window="#e9e9ec", text="#1d1d1f", dim="#5c5c63", placeholder="#8e8e94", disabled="#a6a6ab",
    field="#ffffff", field_border="#c6c6cb", panel="#fbfbfc", line="#d0d0d4", separator="#d6d6da",
    menubar="#f6f6f7", menu="#ffffff", status="#f6f6f7", tooltip="#ffffff", tooltip_border="#c6c6cb",
    button="#e6e6ea", button_hover="#dadade", button_pressed="#cfcfd4", button_disabled="#efeff1",
    primary_disabled="#b9cdf7", primary_disabled_text="#ffffff", groove="#c6c6cb", handle="#ffffff",
    handle_border="1px solid #aeaeb4", card="#f0f0f2", popup="#ffffff", popup_border="#c9c9ce",
    tab_selected="#e3e3e7", link="#2563d9", danger="#d93025", warn="#a85f00", ok="#1e8e3e", icon="#2b2b2e",
    canvas=(203, 203, 203), page_shadow=60, hist_well=(0, 0, 0, 18), hist_bars=(0, 0, 0, 120),
    drop_border="#b9b9be",
)
MODES = {"dark": DARK, "light": LIGHT}

mode = "dark"
C = DARK   # the current colors; painted things read them at paint time


def qcolor(name: str) -> QColor:
    v = C[name]
    return QColor(*v) if isinstance(v, tuple) else QColor(v)


def style(c: dict) -> str:
    return f"""
QMainWindow, QDialog {{ background: {c['window']}; }}
QWidget {{ color: {c['text']}; font-size: 13px; }}
QToolTip {{ background: {c['tooltip']}; color: {c['text']}; border: 1px solid {c['tooltip_border']}; padding: 4px; }}
QMenuBar {{ background: {c['menubar']}; }}
QMenuBar::item:selected, QMenu::item:selected {{ background: {ACCENT}; color: white; }}
QMenu {{ background: {c['menu']}; border: 1px solid {c['separator']}; }}
QMenu::separator {{ height: 1px; background: {c['separator']}; margin: 4px 8px; }}
QStatusBar {{ background: {c['status']}; color: {c['dim']}; }}
QScrollArea {{ background: transparent; border: none; }}
QScrollArea > QWidget > QWidget {{ background: transparent; }}
QLineEdit, QPlainTextEdit, QSpinBox, QDoubleSpinBox, QComboBox {{
    background: {c['field']}; border: 1px solid {c['field_border']}; border-radius: 6px; padding: 3px 6px; selection-background-color: {ACCENT};
}}
QLineEdit:focus, QPlainTextEdit:focus, QSpinBox:focus, QDoubleSpinBox:focus, QComboBox:focus {{ border: 1px solid {ACCENT}; }}
QComboBox QAbstractItemView {{ background: {c['menu']}; selection-background-color: {ACCENT}; }}
QPushButton {{ background: {c['button']}; border: none; border-radius: 6px; padding: 4px 10px; }}
QPushButton:hover {{ background: {c['button_hover']}; }}
QPushButton:pressed {{ background: {c['button_pressed']}; }}
QPushButton:checked {{ background: {ACCENT}; color: white; }}
QPushButton:disabled {{ color: {c['disabled']}; background: {c['button_disabled']}; }}
QPushButton[primary="true"] {{ background: {ACCENT}; color: white; font-weight: 600; }}
QPushButton[primary="true"]:hover {{ background: #5189f7; }}
QPushButton[primary="true"]:disabled {{ background: {c['primary_disabled']}; color: {c['primary_disabled_text']}; }}
QPushButton[destructive="true"] {{ background: #d93a30; color: white; font-weight: 600; }}
QPushButton[destructive="true"]:hover {{ background: #e2534a; }}
QPushButton[dialog="true"] {{ min-width: 76px; padding: 6px 16px; }}
QPushButton[dialog="true"][primary="false"] {{ border: 1px solid {c['field_border']}; padding: 5px 15px; }}
QLabel#msgHeading {{ font-size: 15px; font-weight: 700; color: {c['text']}; }}
QLabel#msgDetail {{ color: {c['dim']}; }}
QPushButton[chip="true"] {{ border-radius: 12px; padding: 3px 11px; font-weight: 600; }}
QPushButton[link="true"] {{ background: transparent; color: {c['dim']}; padding: 2px 0; text-align: left; }}
QPushButton[link="true"]:hover {{ color: {c['text']}; }}
QPushButton[danger="true"] {{ background: transparent; color: {c['danger']}; }}
QCheckBox::indicator {{ width: 15px; height: 15px; }}
QSlider::groove:horizontal {{ height: 4px; background: {c['groove']}; border-radius: 2px; }}
QSlider::sub-page:horizontal {{ background: {ACCENT}; border-radius: 2px; }}
QSlider::handle:horizontal {{ background: {c['handle']}; border: {c['handle_border']}; width: 16px; height: 16px; margin: -6px 0; border-radius: 8px; }}
QLabel[section="true"] {{ color: {c['dim']}; font-size: 11px; font-weight: 700; letter-spacing: 1px; }}
QLabel[caption="true"] {{ color: {c['dim']}; font-size: 11px; }}
QLabel[warn="true"] {{ color: {c['warn']}; font-size: 11px; }}
QLabel#prov {{ color: {c['dim']}; font-size: 11px; }}
QLabel#toolname {{ font-weight: 700; color: {c['text']}; padding-left: 8px; }}
QFrame[card="true"] {{ background: {c['card']}; border-radius: 10px; }}
QFrame[card="true"][chosen="true"] {{ border: 1px solid {ACCENT}; }}
QFrame#inspector {{ background: {c['panel']}; border-left: 1px solid {c['line']}; }}
QFrame#palette {{ background: {c['panel']}; border-right: 1px solid {c['line']}; }}
QFrame#popup {{ background: {c['popup']}; border: 1px solid {c['popup_border']}; border-radius: 12px; }}
QFrame#pill {{ background: {c['button']}; border-radius: 14px; }}
QFrame#pill QPushButton {{ background: transparent; border-radius: 11px; padding: 3px 14px; font-weight: 600; }}
QFrame#pill QPushButton:hover:!checked {{ background: {c['button_hover']}; }}
QFrame#pill QPushButton:checked {{ background: {ACCENT}; color: white; }}
QFrame#sep {{ background: {c['separator']}; }}
QFrame#rule {{ background: {c['line']}; }}
QFrame#dropcard {{ background: {c['card']}; border: 2px dashed {c['drop_border']}; border-radius: 26px; }}
QFrame#dropcard[targeted="true"] {{ border: 2px dashed {ACCENT}; }}
QToolButton {{ background: transparent; border: none; border-radius: 8px; padding: 6px; }}
QToolButton:hover {{ background: {c['button']}; }}
QToolButton:checked {{ background: {ACCENT}; }}
QTabBar::tab {{ background: transparent; padding: 6px 12px; border-radius: 7px; color: {c['dim']}; }}
QTabBar::tab:selected {{ background: {c['tab_selected']}; color: {c['text']}; }}
QTabWidget::pane {{ border: 1px solid {c['line']}; border-radius: 8px; top: -1px; }}
QPushButton[recording="true"] {{ color: {ACCENT}; border: 1px solid {ACCENT}; }}
QPushButton[none="true"] {{ color: {c['dim']}; }}
"""


def apply(app: QApplication, new_mode: str | None = None) -> None:
    """Sets the look for every window; call again to switch (windows then refresh what they paint themselves)."""
    global mode, C
    if new_mode in MODES:
        mode = new_mode
    C = MODES[mode]
    app.setStyle(QStyleFactory.create("Fusion"))
    pal = QPalette()
    for role, k in [(QPalette.ColorRole.Window, "window"), (QPalette.ColorRole.WindowText, "text"),
                    (QPalette.ColorRole.Base, "field"), (QPalette.ColorRole.AlternateBase, "card"),
                    (QPalette.ColorRole.Text, "text"), (QPalette.ColorRole.Button, "button"),
                    (QPalette.ColorRole.ButtonText, "text"), (QPalette.ColorRole.ToolTipBase, "tooltip"),
                    (QPalette.ColorRole.ToolTipText, "text"), (QPalette.ColorRole.PlaceholderText, "placeholder"),
                    (QPalette.ColorRole.Link, "link")]:
        pal.setColor(role, qcolor(k))
    pal.setColor(QPalette.ColorRole.Highlight, QColor(ACCENT))
    pal.setColor(QPalette.ColorRole.HighlightedText, QColor("#ffffff"))
    for role in (QPalette.ColorRole.Text, QPalette.ColorRole.ButtonText, QPalette.ColorRole.WindowText):
        pal.setColor(QPalette.ColorGroup.Disabled, role, qcolor("disabled"))
    app.setPalette(pal)
    app.setStyleSheet(style(C))
