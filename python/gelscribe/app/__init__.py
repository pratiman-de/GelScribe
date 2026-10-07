"""The Qt app: windows, canvas, inspector."""
from PySide6.QtCore import QSettings


def settings() -> QSettings:
    """GelScribe's preferences: an .ini file (%APPDATA%\\GelScribe\\GelScribe.ini on Windows), not the registry."""
    return QSettings(QSettings.Format.IniFormat, QSettings.Scope.UserScope, "GelScribe", "GelScribe")
