"""The update notice: version comparison, parsing, the 24 h throttle, the settings, silence on errors. No network."""
import json
import time

import pytest
from PySide6.QtWidgets import QApplication, QCheckBox, QMenu

from gelscribe import __version__
from gelscribe.core import updates

SAMPLE = json.dumps({"tag_name": "v0.3", "html_url": "https://github.com/pratiman-de/GelScribe/releases/tag/v0.3",
                     "body": "## What's new\n\nFaster export\n\n- one\n- two\n- three\n- four\n- five\n- six"})


def test_version_is_0_1_1():
    assert __version__ == "0.1.1"


def test_version_order():
    order = ["0.1", "0.1.1", "0.1.10", "0.2", "0.10", "1.0"]
    for lo, hi in zip(order, order[1:]):
        assert updates.is_newer(hi, lo) and not updates.is_newer(lo, hi)
    assert updates.is_newer("0.10", "0.9") and updates.is_newer("0.2.1", "0.2")
    assert updates.is_newer("v0.1.1", "0.1") and not updates.is_newer("v0.1.1", "0.1.1")
    assert not updates.is_newer("0.1.0", "0.1") and not updates.is_newer("junk", "0.1")
    assert updates.parse_version("v0.1.1") == (0, 1, 1) and updates.parse_version("") is None


def test_parse_release():
    r = updates.parse_release(SAMPLE)
    assert r.version == "0.3" and r.url.endswith("/tag/v0.3") and "Faster export" in r.notes
    assert updates.parse_release(SAMPLE.encode()) == r
    for bad in ("not json", "{}", '{"tag_name": "nightly", "html_url": "x"}', "[]", b"\xff"):
        assert updates.parse_release(bad) is None


def test_notes_excerpt_is_short():
    out = updates.notes_excerpt(updates.parse_release(SAMPLE).notes).splitlines()
    assert out[0] == "What's new" and len(out) == 6


def test_check_results():
    assert updates.check(lambda v: SAMPLE, "0.1.1").status == "newer"
    assert updates.check(lambda v: SAMPLE, "0.3").status == "current"
    assert updates.check(lambda v: SAMPLE, "0.10").status == "current"

    def offline(v):
        raise OSError("offline")
    assert updates.check(offline, "0.1.1") == updates.Result("error")
    assert updates.check(lambda v: "<html>", "0.1.1").status == "error"


def test_fetch_sends_user_agent(monkeypatch):
    seen = {}

    class Resp:
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self): return b"{}"

    def fake(req, timeout):
        seen.update(url=req.full_url, ua=req.get_header("User-agent"), timeout=timeout, headers=dict(req.header_items()))
        return Resp()
    monkeypatch.setattr(updates.urllib.request, "urlopen", fake)
    updates.fetch_latest("0.1.1")
    assert seen["url"] == updates.LATEST_URL and seen["timeout"] == 10
    assert seen["ua"] == "GelScribe/0.1.1" and list(seen["headers"]) == ["User-agent"]


def test_throttle():
    now = 1_000_000.0
    assert updates.due(True, None, now)
    assert not updates.due(True, now - 3600, now)
    assert not updates.due(True, now - 24 * 3600 + 1, now)
    assert updates.due(True, now - 24 * 3600, now)
    assert updates.due(True, now + 5000, now)   # a clock set back
    assert not updates.due(False, None, now)
    assert updates.due(False, now, now, manual=True)   # Check for Updates… ignores both


# ------------------------------------------------------------------------------------------------ in the app
@pytest.fixture
def ctl():
    from gelscribe.app.main import Controller
    c = Controller(QApplication.instance() or QApplication([]))
    c.settings.remove("updateCheckEnabled")
    c.settings.remove("lastUpdateCheck")
    yield c
    c.settings.remove("updateCheckEnabled")
    c.settings.remove("lastUpdateCheck")
    for w in list(c.windows):
        w.close()


def wait(ctl, cond, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end and not cond():
        QApplication.processEvents()
        time.sleep(0.005)
    QApplication.processEvents()
    return cond()


def test_launch_check_shows_notice_and_stores_time(ctl):
    calls = []
    ctl.updates.checker.fetch = lambda v: calls.append(v) or SAMPLE
    ctl.new_window()
    assert ctl.updates.check()
    assert wait(ctl, lambda: ctl.updates.notice is not None)
    n = ctl.updates.notice
    assert "0.3 is available" in n.findChild(type(n.text)).text()
    assert "You have 0.1.1." in n.text.text() and "Faster export" in n.text.text()
    assert n.isVisible() and not n.isModal() and calls == [__version__]
    assert ctl.updates.last_check() is not None
    assert not ctl.updates.check()   # within 24 h: nothing more
    n.close()


def test_dont_show_again_turns_it_off(ctl):
    ctl.updates.checker.fetch = lambda v: SAMPLE
    ctl.updates.check()
    assert wait(ctl, lambda: ctl.updates.notice is not None)
    ctl.updates.notice.off_button.click()
    assert not ctl.updates.enabled()
    ctl.settings.remove("lastUpdateCheck")
    assert not ctl.updates.check()   # off: no automatic check
    ctl.updates.notice = None
    assert ctl.updates.check(manual=True)   # but the menu command still works
    assert wait(ctl, lambda: ctl.updates.notice is not None)
    ctl.updates.notice.close()


def test_errors_are_silent_and_not_recorded(ctl):
    def boom(v):
        raise OSError("offline")
    ctl.updates.checker.fetch = boom
    assert ctl.updates.check()
    assert wait(ctl, lambda: not ctl.updates.checker.thread.is_alive())
    QApplication.processEvents()
    assert ctl.updates.notice is None and ctl.updates.alert is None and ctl.updates.last_check() is None


def test_manual_check_reports(ctl):
    ctl.updates.checker.fetch = lambda v: json.dumps({"tag_name": "v0.1.1", "html_url": "u"})
    ctl.updates.check(manual=True)
    assert wait(ctl, lambda: ctl.updates.alert is not None)
    assert ctl.updates.alert.text() == "GelScribe 0.1.1 is the latest version."
    ctl.updates.alert.close()
    ctl.updates.alert = None

    def offline(v):
        raise OSError
    ctl.updates.checker.fetch = offline
    ctl.updates.check(manual=True)
    assert wait(ctl, lambda: ctl.updates.alert is not None)
    assert ctl.updates.alert.text() == "Couldn't check for updates. Check your internet connection."
    ctl.updates.alert.close()


def test_download_opens_release_page(ctl, monkeypatch):
    from gelscribe.app import updates as ui
    opened = []
    monkeypatch.setattr(ui.QDesktopServices, "openUrl", lambda u: opened.append(u.toString()))
    n = ui.UpdateNotice(updates.parse_release(SAMPLE), "0.1.1", lambda: None)
    n.show()
    n.download_button.click()
    assert opened == ["https://github.com/pratiman-de/GelScribe/releases/tag/v0.3"]


def test_settings_checkbox_and_help_menu(ctl):
    from gelscribe.app.keys import SettingsDialog
    ctl.new_window()
    d = SettingsDialog()
    box = d.update_check
    assert isinstance(box, QCheckBox) and box.isChecked()
    box.setChecked(False)
    assert not ctl.updates.enabled()
    box.setChecked(True)
    assert ctl.updates.enabled()
    help_menu = next(m for m in ctl.windows[0].menuBar().findChildren(QMenu) if m.title() == "&Help")
    assert "Check for Updates…" in [a.text() for a in help_menu.actions()]


def test_cli_version():
    import subprocess
    import sys
    out = subprocess.run([sys.executable, "-m", "gelscribe", "--version"], capture_output=True, text=True,
                         cwd=str(__import__("pathlib").Path(__file__).resolve().parent.parent))
    assert out.stdout.strip() == "gelscribe 0.1.1"
