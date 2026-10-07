import os
import sys
from pathlib import Path

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

#: the example gel the Mac tests use (mac/TestData/gel.png), kept out of the repository; tests that need it skip
FIXTURE = Path(__file__).resolve().parents[2] / "mac" / "TestData" / "gel.png"


@pytest.fixture(scope="session", autouse=True)
def private_settings(tmp_path_factory):
    """Tests never touch your own preferences or saved ladders."""
    from PySide6.QtCore import QSettings
    from gelscribe.core import ladders
    d = tmp_path_factory.mktemp("settings")
    QSettings.setPath(QSettings.Format.IniFormat, QSettings.Scope.UserScope, str(d))
    old = ladders.user_path
    ladders.user_path = lambda: d / "ladders.json"
    yield d
    ladders.user_path = old
