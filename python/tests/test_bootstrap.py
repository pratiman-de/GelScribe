"""The setup (gelscribe/bootstrap.py): which Python GelScribe runs from, what it leaves out of Qt, and what it never
touches: your own Pythons and conda, your home folder, your pip settings."""
import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

from gelscribe import bootstrap

ROOT = Path(__file__).resolve().parent.parent
posix_only = pytest.mark.skipif(sys.platform == "win32", reason="uses a shell script or POSIX paths")


@pytest.fixture(autouse=True)
def private_home(tmp_path, monkeypatch):
    """Nothing here may write into your own home folder: the Linux menu entry, the Windows shortcuts, pip's user
    site-packages and settings all follow these, for this process and the ones it starts."""
    home = tmp_path / "home"
    home.mkdir()
    for name, value in (("HOME", home), ("USERPROFILE", home), ("APPDATA", home / "AppData"),
                        ("LOCALAPPDATA", home / "AppData" / "Local"), ("XDG_DATA_HOME", home / "share"),
                        ("XDG_CONFIG_HOME", home / "config")):
        monkeypatch.setenv(name, str(value))
    for name in [k for k in os.environ if k.startswith("PIP_")] + ["CONDA_PREFIX", "CONDA_EXE", "PYTHONPATH",
                                                                    "PYTHONUSERBASE"]:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("PYTHONDONTWRITEBYTECODE", "1")   # the Pythons these tests start (venv, pip): no new .pyc files
    return home


@pytest.fixture
def folder(tmp_path, monkeypatch):
    """A GelScribe folder of its own for setup() to work in."""
    here = tmp_path / "GelScribe"
    here.mkdir()
    shutil.copyfile(ROOT / "requirements.txt", here / "requirements.txt")
    for name, value in (("HERE", here), ("VENV", here / ".venv"), ("REQUIREMENTS", here / "requirements.txt"),
                        ("CHOICE", here / "python.txt"), ("USED", here / "requirements.used")):
        monkeypatch.setattr(bootstrap, name, value)
    return here


def fake_python(path: Path, version: list, log: Path, has_everything: bool = False) -> Path:
    """A stand-in for a Python that has nothing GelScribe needs (or has all of it). It answers the probe as that
    version, and when it's asked to make an environment it writes its name to the log and fails."""
    info = {"version": version, "prefix": str(path), "venv": False, "problem": None, "can_make_env": True,
            "missing": [] if has_everything else [name for name, _module, _need in bootstrap.requirements()]}
    if version < [3, 11]:
        info["problem"] = f"Python {'.'.join(map(str, version))} is older than 3.11"
    path.write_text(f"#!/bin/sh\ncase \"$1\" in\n  -B) echo 'GELSCRIBE-PROBE {json.dumps(info)}' ;;\n"
                    f"  -m) echo '{path.name}' >> '{log}'; exit 1 ;;\nesac\n")
    path.chmod(0o755)
    return path


def fake_conda(bindir: Path, log: Path, monkeypatch) -> None:
    """A conda on PATH that writes down every call, so a test can see it was never run."""
    bindir.mkdir(exist_ok=True)
    conda = bindir / "conda"
    conda.write_text(f"#!/bin/sh\necho \"conda $*\" >> '{log}'\nexit 1\n")
    conda.chmod(0o755)
    monkeypatch.setenv("PATH", str(bindir) + os.pathsep + os.environ["PATH"])
    monkeypatch.setenv("CONDA_EXE", str(conda))


def make_wheel(folder: Path, name: str) -> None:
    """A wheel of a tiny pure-Python package, so pip can install something without a network."""
    dist = f"{name}-1.0.dist-info"
    files = {f"{name}/__init__.py": b"VALUE = 1\n", f"{dist}/METADATA": f"Metadata-Version: 2.1\nName: {name}\n"
             "Version: 1.0\n".encode(), f"{dist}/WHEEL": b"Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\n"
             b"Tag: py3-none-any\n"}
    rows = [f"{path},sha256={base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b'=').decode()},"
            f"{len(data)}" for path, data in files.items()] + [f"{dist}/RECORD,,"]
    files[f"{dist}/RECORD"] = ("\n".join(rows) + "\n").encode()
    with zipfile.ZipFile(folder / f"{name}-1.0-py3-none-any.whl", "w") as z:
        for path, data in files.items():
            z.writestr(path, data)


def test_requirements_name_every_module_with_a_minimum():
    reqs = {name: (module, need) for name, module, need in bootstrap.requirements()}
    assert reqs["PySide6-Essentials"] == ("PySide6", (6, 6))
    assert reqs["numpy"] == ("numpy", (2, 0)) and reqs["Pillow"][0] == "PIL" and reqs["tifffile"][1] == (2024, 1, 30)
    assert len(reqs) == 7


def fake_qt(root: Path) -> Path:
    qt = root / ".venv" / "Lib" / "site-packages" / "PySide6"
    for f in ("Qt6Core.dll", "Qt6Gui.dll", "Qt6Widgets.dll", "QtWidgets.pyd", "Qt6Svg.dll", "pyside6.abi3.dll",
              "opengl32sw.dll", "Qt6Qml.dll", "QtQml.pyd", "QtQml.pyi", "Qt6QuickControls2.dll", "Qt6OpenGL.dll",
              "QtOpenGLWidgets.pyd", "Qt6Pdf.dll", "designer.exe", "Qt6Lottie.dll", "pyside6qml.abi3.dll",
              "qml/QtQuick/Controls/x.dll", "translations/qt_de.qm", "resources/icudtl.dat", "metatypes/a.json",
              "plugins/platforms/qwindows.dll", "plugins/imageformats/qico.dll", "plugins/imageformats/qpdf.dll",
              "plugins/qmltooling/q.dll", "plugins/vectorimageformats/l.dll", "plugins/styles/s.dll"):
        p = qt / f
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x" * 100)
    return qt


def test_trim_leaves_what_gelscribe_loads(tmp_path):
    qt = fake_qt(tmp_path)
    freed = bootstrap.trim(qt, inside=tmp_path / ".venv")
    left = sorted(str(p.relative_to(qt)).replace(os.sep, "/") for p in qt.rglob("*") if p.is_file())
    assert left == ["Qt6Core.dll", "Qt6Gui.dll", "Qt6Svg.dll", "Qt6Widgets.dll", "QtWidgets.pyd",
                    "plugins/imageformats/qico.dll", "plugins/platforms/qwindows.dll", "plugins/styles/s.dll",
                    "pyside6.abi3.dll"]
    assert freed == 100 * 18


def test_trim_never_touches_qt_outside_gelscribes_folder(tmp_path):
    qt = fake_qt(tmp_path / "someone-elses-env")
    with pytest.raises(ValueError):
        bootstrap.trim(qt, inside=tmp_path / ".venv")
    assert (qt / "opengl32sw.dll").exists()


def offscreen_env():
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen")
    env.pop("CONDA_PREFIX", None)
    return env


def test_probe_passes_for_a_python_with_everything(monkeypatch):
    monkeypatch.setenv("QT_QPA_PLATFORM", "offscreen")
    info = bootstrap.run_probe(Path(sys.executable))
    assert bootstrap.usable(info), info
    assert info["can_make_env"]


def test_probe_lists_what_a_bare_python_lacks(tmp_path, monkeypatch):
    monkeypatch.setenv("QT_QPA_PLATFORM", "offscreen")
    subprocess.run([sys.executable, "-m", "venv", "--without-pip", str(tmp_path / "bare")], check=True)
    info = bootstrap.run_probe(bootstrap.env_python(tmp_path / "bare"))
    assert not bootstrap.usable(info)
    assert info["missing"] == [name for name, _m, _v in bootstrap.requirements()]


def test_setup_runs_from_a_python_that_has_everything_and_downloads_nothing(tmp_path, private_home):
    if sys.platform == "win32" and not sys.executable.isascii():
        pytest.skip("python.txt can only name a Python with a plain ASCII path; this one is used through .venv")
    copy = tmp_path / "GelScribe"
    shutil.copytree(ROOT, copy, ignore=shutil.ignore_patterns(".venv", "__pycache__", ".pytest_cache", "python.txt",
                                                             "requirements.used", "GelScribe.lnk"))
    # the temporary home (HOME, APPDATA, XDG_DATA_HOME) is where the Start-menu shortcuts or the Linux menu entry go
    r = subprocess.run([sys.executable, str(copy / "gelscribe" / "bootstrap.py")], capture_output=True, text=True,
                       env=offscreen_env(), timeout=600)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "Nothing was downloaded" in r.stdout and not (copy / ".venv").exists()
    chosen = (copy / "python.txt").read_text().strip()
    assert Path(chosen).parent == Path(sys.executable).parent
    assert (copy / "requirements.used").read_bytes() == (copy / "requirements.txt").read_bytes()
    assert not list(copy.rglob("__pycache__"))   # the probes ran with -B: setup left no bytecode behind
    if sys.platform.startswith("linux"):   # the menu entry went into the temporary home, not into yours
        assert str(copy / "GelScribe.sh") in (private_home / "share" / "applications" / "gelscribe.desktop").read_text()


# ------------------------------------------------------------ never downloads Python


@posix_only
def test_setup_never_runs_conda_or_downloads_a_python(folder, tmp_path, monkeypatch, capsys):
    """Only an old Anaconda (Python 3.9) here, and a conda on PATH that could fetch Python 3.12: setup says so and asks
    you to install Python. conda isn't run, and it makes no .venv."""
    conda = tmp_path / "conda.txt"
    fake_conda(tmp_path / "bin", conda, monkeypatch)
    old = fake_python(tmp_path / "python3.9", [3, 9, 6], tmp_path / "venvs.txt")
    monkeypatch.setattr(bootstrap, "candidates", lambda: [old])
    assert bootstrap.setup() == 1
    assert not conda.exists() and not (folder / ".venv").exists() and not (folder / "python.txt").exists()
    assert "doesn't download Python" in capsys.readouterr().out


@posix_only
def test_when_no_python_can_make_the_environment_conda_still_isnt_run(folder, tmp_path, monkeypatch, capsys):
    conda = tmp_path / "conda.txt"
    fake_conda(tmp_path / "bin", conda, monkeypatch)
    broken = fake_python(tmp_path / "python3.12", [3, 12, 1], tmp_path / "venvs.txt")   # its venv fails
    monkeypatch.setattr(bootstrap, "candidates", lambda: [broken])
    assert bootstrap.setup() == 1
    assert (tmp_path / "venvs.txt").read_text().split() == ["python3.12"] and not conda.exists()
    assert "None of the Pythons here could make" in capsys.readouterr().out


# ------------------------------------------------------------ pip only into .venv


def test_pip_env_keeps_your_pip_settings_except_those_that_redirect_the_install(monkeypatch):
    monkeypatch.delenv("PYTHONDONTWRITEBYTECODE")   # pip_env has to set it itself
    for name, value in (("PIP_USER", "1"), ("PIP_TARGET", "x"), ("PIP_PREFIX", "y"), ("PIP_ROOT", "z"),
                        ("PIP_INDEX_URL", "https://mirror.example/simple"), ("HTTPS_PROXY", "http://proxy:3128")):
        monkeypatch.setenv(name, value)
    env = bootstrap.pip_env()
    assert env["PIP_USER"] == "0" and not {"PIP_TARGET", "PIP_PREFIX", "PIP_ROOT"} & set(env)
    assert env["PYTHONDONTWRITEBYTECODE"] == "1"   # pip imports its base Python's standard library: no .pyc into it
    assert env["PIP_INDEX_URL"] == "https://mirror.example/simple" and env["HTTPS_PROXY"] == "http://proxy:3128"


def test_pip_install_refuses_a_python_that_isnt_gelscribes_own(folder):
    with pytest.raises(ValueError):
        bootstrap.pip_install(Path(sys.executable), "numpy")


@pytest.mark.parametrize("how", ["PIP_USER=1", "user = true in pip.conf"])
def test_pip_installs_only_into_the_venv_even_when_pip_is_set_to_install_for_the_user(tmp_path, monkeypatch, how):
    wheels = tmp_path / "wheels"
    wheels.mkdir()
    for name in ("gsleak", "gsdemo"):
        make_wheel(wheels, name)
    if how == "PIP_USER=1":
        monkeypatch.setenv("PIP_USER", "1")
    else:
        (tmp_path / "pip.conf").write_text("[global]\nuser = true\n")
        monkeypatch.setenv("PIP_CONFIG_FILE", str(tmp_path / "pip.conf"))
    venv = tmp_path / "venv"   # like .venv, it shares its base Python's packages, so the user's site-packages count
    subprocess.run([sys.executable, "-m", "venv", "--system-site-packages", str(venv)], check=True)
    python = bootstrap.env_python(venv)
    paths = subprocess.run([str(python), "-c", "import site, sysconfig; print(site.getusersitepackages()); "
                            "print(sysconfig.get_path('purelib'))"], capture_output=True, text=True, check=True)
    user, own = (Path(p) for p in paths.stdout.splitlines()[:2])
    offline = ["--no-index", "--find-links", str(wheels)]
    # pip as it comes does install for the user with that setting (if not, there's nothing to guard against)
    subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check", *offline, "gsleak"],
                   capture_output=True)
    if not (user / "gsleak").is_dir():
        pytest.skip("this pip doesn't act on that setting here")
    bootstrap.pip_install(python, *offline, "gsdemo", inside=venv)
    assert (own / "gsdemo").is_dir() and not (user / "gsdemo").exists()


# ------------------------------------------------------------ a Python Qt has no wheels for


def test_order_bases_prefers_what_is_already_there_and_puts_a_python_newer_than_qt_last():
    def base(name, version, missing, venv=False):
        return Path(name), {"version": version, "prefix": f"/{name}", "missing": ["x"] * missing, "venv": venv}
    bases = [base("newest", [3, 15, 0], 0), base("few", [3, 13, 5], 5), base("most", [3, 12, 1], 2),
             base("a-venv", [3, 14, 0], 1, venv=True), base("alias", [3, 12, 1], 2)]
    bases[-1][1]["prefix"] = bases[2][1]["prefix"]   # the same Python by another path
    ordered = [p.name for p, _info in bootstrap.order_bases(bases)]
    assert ordered == ["most", "few", "a-venv", "newest"]   # a venv has nothing to lend; the alias counts once


@posix_only
def test_a_python_newer_than_qt_supports_is_tried_last_and_named_when_nothing_works(folder, tmp_path, monkeypatch,
                                                                                    capsys):
    venvs, conda = tmp_path / "venvs.txt", tmp_path / "conda.txt"
    fake_conda(tmp_path / "bin", conda, monkeypatch)
    newest = fake_python(tmp_path / "python3.15", [3, 15, 0], venvs)
    older = fake_python(tmp_path / "python3.13", [3, 13, 5], venvs)
    monkeypatch.setattr(bootstrap, "candidates", lambda: [newest, older])   # the newest one is found first
    assert bootstrap.setup() == 1
    assert venvs.read_text().split() == ["python3.13", "python3.15"] and not conda.exists()
    out = capsys.readouterr().out
    assert "Python 3.15 may be too new for Qt" in out and "3.11 to 3.14 work" in out and "Python 3.13" in out


# ------------------------------------------------------------ python.txt and GelScribe.bat


def windows_choice(monkeypatch, here: Path) -> Path:
    """Acts as Windows for choice_text(): a GelScribe folder here with the private .venv in it."""
    monkeypatch.setattr(bootstrap, "WINDOWS", True)
    monkeypatch.setattr(bootstrap, "HERE", here)
    monkeypatch.setattr(bootstrap, "CHOICE", here / "python.txt")   # fixed when bootstrap loads: a real python.txt here is not this folder's
    scripts = here / ".venv" / "Scripts"
    scripts.mkdir(parents=True)
    for name in ("python.exe", "pythonw.exe"):
        (scripts / name).write_bytes(b"")
    return scripts / "python.exe"


def test_python_txt_is_plain_ascii_on_windows_and_the_private_env_is_relative(tmp_path, monkeypatch):
    # a folder whose name no console code page has in full: ’ is in the ANSI one only, ł in neither (an English PC)
    inside = windows_choice(monkeypatch, tmp_path / "Kevin’s gels ł" / "GelScribe")
    relative = str(Path(".venv") / "Scripts" / "pythonw.exe")
    assert bootstrap.choice_text(inside) == relative
    elsewhere = tmp_path / "Python313"
    elsewhere.mkdir()
    (elsewhere / "python.exe").write_bytes(b"")
    assert bootstrap.choice_text(elsewhere / "python.exe") == str(elsewhere / "python.exe")   # plain ASCII: as it is
    odd = tmp_path / "Łukasz’s Python"
    odd.mkdir()
    (odd / "python.exe").write_bytes(b"")
    assert bootstrap.choice_text(odd / "python.exe") is None   # GelScribe.bat couldn't read that back right
    assert bootstrap.remember(odd / "python.exe") is False and not bootstrap.CHOICE.exists()
    monkeypatch.setattr(bootstrap, "WINDOWS", False)
    assert bootstrap.choice_text(odd / "python.exe") == str(odd / "python.exe")   # Mac and Linux read UTF-8


@posix_only
def test_a_python_whose_path_python_txt_cant_hold_is_still_a_base_for_the_private_env(folder, tmp_path, monkeypatch,
                                                                                      capsys):
    """It has everything, but GelScribe.bat couldn't be given its path: .venv is made from it, borrowing all of it."""
    monkeypatch.setattr(bootstrap, "WINDOWS", True)
    odd = tmp_path / "Łukasz’s Python"
    odd.mkdir()
    python = fake_python(odd / "python.exe", [3, 12, 1], tmp_path / "venvs.txt", has_everything=True)
    monkeypatch.setattr(bootstrap, "candidates", lambda: [python])
    assert bootstrap.setup() == 1   # the stand-in can't make the environment
    assert (tmp_path / "venvs.txt").read_text().split() == ["python.exe"] and not bootstrap.CHOICE.exists()
    assert "has everything, but GelScribe.bat can't be given a path with those characters" in capsys.readouterr().out


def test_the_batch_file_is_plain_ascii_with_windows_line_endings_and_enters_its_folder_with_pushd():
    data = (ROOT / "GelScribe.bat").read_bytes()
    data.decode("ascii")   # cmd reads it with the console's code page
    assert data.count(b"\r\n") == data.count(b"\n")
    text = data.decode("ascii").lower()
    assert 'pushd "%here%"' in text and "cd /d" not in text   # cd can't enter \\server\share
    assert '-b "%here%gelscribe\\bootstrap.py"' in text and "conda create" not in text


@posix_only
def test_the_shell_launcher_finds_its_folder_even_with_cdpath_exported(tmp_path):
    copy = tmp_path / "GelScribe"
    shutil.copytree(ROOT, copy, ignore=shutil.ignore_patterns(".venv", "__pycache__", ".pytest_cache", "python.txt",
                                                             "requirements.used", "GelScribe.lnk"))
    (copy / "python.txt").write_text(sys.executable + "\n")
    shutil.copyfile(copy / "requirements.txt", copy / "requirements.used")
    r = subprocess.run(["sh", "GelScribe/GelScribe.sh", "--version"], cwd=str(tmp_path), capture_output=True,
                       text=True, env=dict(os.environ, CDPATH=".", PYTHONDONTWRITEBYTECODE="1"), timeout=120)
    assert r.returncode == 0 and r.stdout.startswith("gelscribe "), r.stdout + r.stderr


# ------------------------------------------------------------ an odd Python


def test_output_that_isnt_utf8_is_read_without_an_error():
    assert bootstrap.decode("é".encode()) == "é"
    assert bootstrap.decode(b"Jos\xe9").startswith("Jos")   # one Latin-1 byte, as an old Python prints a user's path


@posix_only
def test_one_odd_python_cant_stop_the_probe(tmp_path):
    def python(name: str, body: str) -> Path:
        path = tmp_path / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)
        return path
    answer = bootstrap.PROBE + json.dumps({"version": [3, 12, 0], "prefix": "/x", "missing": [], "problem": None,
                                           "can_make_env": True})
    # a warning with one Latin-1 byte in a user's path, as an old environment prints it
    assert bootstrap.run_probe(python("warns", r"printf 'Warning: C:\\Users\\Jos\351\\site\n' >&2; exit 1")) is None
    assert bootstrap.run_probe(python("noisy", f"printf 'caf\\351\\n'; echo '{answer}'"))["version"] == [3, 12, 0]
    assert bootstrap.run_probe(python("junk", f"echo '{bootstrap.PROBE}{{not json'")) is None
    assert bootstrap.run_probe(python("list", f"echo '{bootstrap.PROBE}[1, 2]'")) is None
    assert bootstrap.run_probe(tmp_path / "not-there") is None


@posix_only
def test_probing_a_python_asks_it_not_to_write_bytecode(tmp_path, monkeypatch):
    monkeypatch.delenv("PYTHONDONTWRITEBYTECODE")   # the probe has to ask for it itself
    seen = tmp_path / "seen.txt"
    spy = tmp_path / "spy"   # records how it was started, then is the Python this test runs with
    spy.write_text(f'#!/bin/sh\necho "$1 $PYTHONDONTWRITEBYTECODE" > "{seen}"\nexec "{sys.executable}" "$@"\n')
    spy.chmod(0o755)
    assert bootstrap.usable(bootstrap.run_probe(spy))
    assert seen.read_text().split() == ["-B", "1"]


def test_trim_carries_on_when_a_file_is_locked(tmp_path, monkeypatch):
    qt = fake_qt(tmp_path)
    unlink = Path.unlink

    def locked(self, *args, **kwargs):   # a virus scanner or OneDrive holds one file
        if self.name == "opengl32sw.dll":
            raise PermissionError("in use")
        return unlink(self, *args, **kwargs)
    monkeypatch.setattr(Path, "unlink", locked)
    freed = bootstrap.trim(qt, inside=tmp_path / ".venv")
    assert (qt / "opengl32sw.dll").exists() and not (qt / "Qt6Qml.dll").exists() and freed == 100 * 17


# ------------------------------------------------------------ your own home folder


@posix_only
def test_the_linux_menu_entry_goes_where_xdg_data_home_says(folder, private_home):
    bootstrap.menu_entry()
    text = (private_home / "share" / "applications" / "gelscribe.desktop").read_text()
    assert f'Exec="{folder / "GelScribe.sh"}" %F' in text


@posix_only
def test_a_folder_that_cant_be_written_to_says_so(tmp_path, private_home):
    if os.geteuid() == 0:
        pytest.skip("root can write anywhere")
    copy = tmp_path / "GelScribe"
    shutil.copytree(ROOT, copy, ignore=shutil.ignore_patterns(".venv", "__pycache__", ".pytest_cache", "python.txt",
                                                             "requirements.used", "GelScribe.lnk"))
    copy.chmod(0o555)   # like a folder inside a zip or in Program Files
    try:
        r = subprocess.run([sys.executable, str(copy / "gelscribe" / "bootstrap.py")], capture_output=True, text=True,
                           env=offscreen_env(), timeout=600)
    finally:
        copy.chmod(0o755)
    assert r.returncode == 1 and "Setting up stopped" in r.stdout and "one you can write to" in r.stdout, r.stdout


@pytest.mark.parametrize("setting", ["[install]\ntarget = TMP/elsewhere", "[global]\nprefix = TMP/elsewhere",
                                     "[install]\nroot = TMP/elsewhere", "[global]\n--target = TMP/elsewhere"])
def test_pip_stops_instead_of_installing_outside_the_venv_when_pip_config_sets_where_to_install(tmp_path, monkeypatch,
                                                                                                setting):
    wheels = tmp_path / "wheels"
    wheels.mkdir()
    make_wheel(wheels, "gsdemo")
    (tmp_path / "pip.conf").write_text(setting.replace("TMP", str(tmp_path)) + "\n")
    monkeypatch.setenv("PIP_CONFIG_FILE", str(tmp_path / "pip.conf"))
    venv = tmp_path / "venv"
    subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)
    python = bootstrap.env_python(venv)
    name = setting.split("\n")[1].split("=")[0].strip().lstrip("-")
    with pytest.raises(bootstrap.PipSettingError, match=name) as e:
        bootstrap.pip_install(python, "--no-index", "--find-links", str(wheels), "gsdemo", inside=venv)
    assert "pip.conf or" in str(e.value) and not (tmp_path / "elsewhere").exists()
    (tmp_path / "pip.conf").write_text("[global]\nindex-url = https://mirror.example/simple\n[install]\nuser = true\n")
    assert bootstrap.redirecting_settings(python) == []   # the settings that stay: a mirror, and user (pip_env sees to it)
