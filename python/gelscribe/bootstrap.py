"""Setting up GelScribe. GelScribe.bat (Windows), GelScribe.command (Mac) and GelScribe.sh (Linux) run this with
whichever Python they find first.

GelScribe runs from a Python environment you already have, when it has everything GelScribe needs, and nothing is
downloaded. Otherwise it makes a small private one in the .venv folder: it reuses the packages your Python already has,
installs only what's missing and, on Windows, leaves out the parts of Qt GelScribe never uses. Setup never downloads
Python. It only reads your own environments (it runs each Python once to see what it has, without letting it write
files) and pip only ever installs into .venv. The choice is written to python.txt, which the launchers start GelScribe
with.

Standard library only, so any Python 3.8 or newer can run it.
"""
from __future__ import annotations

import errno
import fnmatch
import glob
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent   # the GelScribe folder
SCRIPT = Path(__file__).resolve()
VENV = HERE / ".venv"
REQUIREMENTS = HERE / "requirements.txt"
CHOICE = HERE / "python.txt"   # the Python GelScribe starts with (its pythonw.exe on Windows)
USED = HERE / "requirements.used"   # what it was set up for; the launchers set up again when requirements.txt changes
WINDOWS = sys.platform == "win32"
MAC = sys.platform == "darwin"
PROBE = "GELSCRIBE-PROBE "
#: The Pythons PySide6 (Qt) has wheels for: 6.11, the newest in October 2026, says Requires-Python <3.15. A newer Python
#: is still tried, since Qt catches up some months after each release, but after the others. The messages name these.
QT_PYTHONS = ((3, 11), (3, 14))
WORKING = "{}.{} to {}.{}".format(*QT_PYTHONS[0], *QT_PYTHONS[1])
#: requirement → the module it installs
MODULES = {"pyside6-essentials": "PySide6", "numpy": "numpy", "scipy": "scipy", "pillow": "PIL",
           "tifffile": "tifffile", "imagecodecs": "imagecodecs", "pikepdf": "pikepdf"}
#: Parts of Qt GelScribe never loads: it draws with widgets and QPainter, without QML, OpenGL, a PDF viewer or a
#: database. About 150 of the 211 MB on disk (the wheel is downloaded whole). Removed only from a Qt installed into
#: GelScribe's own .venv.
QT_UNUSED = [
    "opengl32sw.dll", "qml", "translations", "resources", "metatypes", "include", "typesystems", "*.exe",
    "Qt6Qml*", "Qt6Quick*", "Qt6Labs*", "QtQml*", "QtQuick*", "Qt6OpenGL*", "QtOpenGL*", "Qt6Pdf*", "QtPdf*",
    "Qt6Designer*", "QtDesigner*", "Qt6UiTools*", "QtUiTools*", "Qt6Help*", "QtHelp*", "Qt6Sql*", "QtSql*",
    "Qt6Lottie*", "pyside6qml*", "plugins/vectorimageformats",   # Lottie and PySide's QML glue need Qt Quick
    "plugins/qmltooling", "plugins/qmllint", "plugins/designer", "plugins/sqldrivers", "plugins/imageformats/qpdf*",
]


def say(text: str = "") -> None:
    try:
        print(text, flush=True)
    except UnicodeEncodeError:   # a redirected stream that can't show a path (a folder called Łukasz on an English PC)
        print(text.encode("ascii", "replace").decode("ascii"), flush=True)


def version_tuple(v: str) -> tuple:
    return tuple(int(x) for x in re.findall(r"\d+", v)[:4])


def requirements() -> list:
    """(requirement, module, minimum version) from requirements.txt."""
    out = []
    for line in REQUIREMENTS.read_text(encoding="utf-8").splitlines():
        m = re.match(r"\s*([A-Za-z0-9_.-]+)\s*>=\s*([0-9][0-9.]*)", line.split("#")[0])
        if m and m.group(1).lower() in MODULES:
            out.append((m.group(1), MODULES[m.group(1).lower()], version_tuple(m.group(2))))
    return out


def decode(data: bytes) -> str:
    """Output of another program as text, whatever it is: UTF-8, else the system's code page. Never an error."""
    for encoding in ("utf-8", "mbcs" if WINDOWS else "latin-1"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            pass
    return data.decode("utf-8", "replace")


# ---------------------------------------------------------------------------------------------------- the probe


def smoke() -> None:
    """A quick run of what GelScribe needs from each library: TIFF with LZW, PDF, PNG, the band maths, Qt."""
    import io
    import numpy as np
    import pikepdf
    import tifffile
    from PIL import Image
    from scipy import ndimage, signal
    a = (np.arange(64 * 64, dtype=np.uint16) * 13).reshape(64, 64)
    buf = io.BytesIO()
    tifffile.imwrite(buf, a, compression="lzw")
    assert np.array_equal(tifffile.imread(io.BytesIO(buf.getvalue())), a), "TIFF round trip"
    ndimage.gaussian_filter1d(a.astype(float), 2.0)
    signal.find_peaks(a[0].astype(float))
    pdf = pikepdf.new()
    pdf.add_blank_page()
    pdf.save(io.BytesIO())
    Image.fromarray((a >> 8).astype(np.uint8)).save(io.BytesIO(), "PNG")
    sys.path.insert(0, str(HERE))
    from PySide6.QtCore import QBuffer, QByteArray
    from PySide6.QtGui import QIcon, QPainter, QPdfWriter
    from PySide6.QtWidgets import QApplication
    app = QApplication.instance() or QApplication(["gelscribe-check"])
    data = QByteArray()
    out = QBuffer(data)
    out.open(QBuffer.OpenModeFlag.WriteOnly)
    writer = QPdfWriter(out)
    painter = QPainter(writer)
    painter.drawText(20, 20, "GelScribe")
    painter.end()
    assert data.size() > 0, "PDF writer"
    icon = HERE / "gelscribe" / "app" / "resources" / ("icon.ico" if WINDOWS else "icon.png")
    assert not QIcon(str(icon)).pixmap(32, 32).isNull(), "app icon"
    import gelscribe.app.main  # noqa: F401  (every module GelScribe loads)
    del app


def probe() -> dict:
    """Run inside each candidate Python: what it is, and what it lacks for GelScribe."""
    info = {"version": list(sys.version_info[:3]), "prefix": sys.prefix, "missing": [], "problem": None,
            "venv": sys.prefix != getattr(sys, "base_prefix", sys.prefix)}   # a venv has no packages of its own to lend
    try:
        import ssl  # noqa: F401  (pip needs it)
        import venv  # noqa: F401
        info["can_make_env"] = True
    except Exception:
        info["can_make_env"] = False
    if sys.version_info < (3, 11):
        info["problem"] = f"Python {sys.version.split()[0]} is older than 3.11"
        info["missing"] = [r[0] for r in requirements()]
        return info
    for name, module, need in requirements():
        try:
            mod = __import__(module)
            if version_tuple(getattr(mod, "__version__", "0")) < need:
                info["missing"].append(f"{name} (has {mod.__version__})")
        except Exception:
            info["missing"].append(name)
    if not info["missing"]:
        try:
            smoke()
        except Exception as e:
            info["problem"] = f"{type(e).__name__}: {e}"
    return info


def quiet_env() -> dict:
    """The environment for running one of your Pythons: it mustn't write anything into it, not even .pyc files."""
    return dict(os.environ, PYTHONDONTWRITEBYTECODE="1")


def run_probe(python: Path) -> dict | None:
    """What probe() says in that Python, or None if it can't be asked. Whatever that Python prints or does, this
    returns: one odd Python must not stop the setup."""
    env = quiet_env()
    if not WINDOWS:   # no Dock icon for each Python tried, and no display needed (the command-line tool has none)
        env.setdefault("QT_QPA_PLATFORM", "offscreen")
    try:
        r = subprocess.run([str(python), "-B", str(SCRIPT), "--probe"], capture_output=True, timeout=180,
                           cwd=str(HERE), env=env)
    except (OSError, subprocess.SubprocessError):
        return None
    for line in decode(r.stdout).splitlines():
        i = line.find(PROBE)
        if i >= 0:
            try:
                info = json.loads(line[i + len(PROBE):])
            except ValueError:
                return None
            wanted = {"version", "prefix", "missing", "problem", "can_make_env"}
            return info if isinstance(info, dict) and wanted <= set(info) else None
    return None


def usable(info: dict | None) -> bool:
    return bool(info) and not info["missing"] and not info["problem"]


# ---------------------------------------------------------------------------------------------------- finding Python


def interpreter(prefix: Path) -> Path:
    return prefix / "python.exe" if WINDOWS else prefix / "bin" / "python"


def env_python(env: Path) -> Path:
    """A venv keeps python in Scripts (bin), a conda environment at the top."""
    for p in (env / "Scripts" / "python.exe", env / "python.exe", env / "bin" / "python"):
        if p.exists():
            return p
    return interpreter(env)


def is_dir(p: Path) -> bool:
    try:
        return p.is_dir()
    except OSError:   # a folder this account can't look into
        return False


def conda_bases() -> list:
    bases = []
    if os.environ.get("CONDA_EXE"):
        bases.append(Path(os.environ["CONDA_EXE"]).resolve().parents[1])
    homes = [Path.home()]
    if WINDOWS:
        homes += [Path(os.environ[v]) for v in ("LOCALAPPDATA", "ProgramData") if os.environ.get(v)]
    else:
        homes += [Path.home() / "opt", Path("/opt")]   # ~/opt: where Anaconda used to install on a Mac
    for h in homes:
        for name in ("miniconda3", "anaconda3", "miniforge3", "mambaforge"):
            bases.append(h / name)
    if MAC:   # Homebrew's miniforge
        bases += [Path(p) / "Caskroom" / "miniforge" / "base" for p in ("/opt/homebrew", "/usr/local")]
    out = []
    for b in bases:
        if is_dir(b) and b not in out:
            out.append(b)
    return out


def conda_envs() -> list:
    """Every conda environment conda knows of, wherever it is: conda lists them in ~/.conda/environments.txt."""
    listed = Path.home() / ".conda" / "environments.txt"
    try:
        lines = listed.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return []
    return [Path(line.strip()) for line in lines if line.strip()]


def posix_pythons() -> list:
    """Pythons on a Mac or Linux beyond python on PATH: the versioned names, Homebrew, python.org, pyenv and uv."""
    found = [shutil.which(n) for n in ("python3", "python3.13", "python3.12", "python3.11")]
    patterns = ["/opt/homebrew/bin/python3.1[1-9]", "/usr/local/bin/python3.1[1-9]",
                "/Library/Frameworks/Python.framework/Versions/3.1[1-9]/bin/python3",
                str(Path.home() / ".pyenv" / "versions" / "*" / "bin" / "python3"),
                str(Path.home() / ".local" / "share" / "uv" / "python" / "*" / "bin" / "python3")]
    if not MAC:
        patterns.insert(0, "/usr/bin/python3.1[1-9]")
    for pattern in patterns:
        found += sorted(glob.glob(pattern), reverse=True)   # newest first
    # Apple's /usr/bin/python3 is 3.9 and, without the developer tools, asks to install them
    return [p for p in found if p and not (MAC and Path(p) == Path("/usr/bin/python3"))]


def candidates() -> list:
    """Python interpreters on this computer: GelScribe's own .venv, an open conda environment, the one running this,
    python.org's (py on Windows), python on PATH (and on a Mac or Linux, the other usual places), then conda installs
    and all their environments."""
    found = []

    def add(p):
        try:
            if p:
                p = Path(p)
                if p.is_file() and p not in found:
                    found.append(p)
        except OSError:   # a path this account can't look at
            pass
    if VENV.is_dir():
        add(env_python(VENV))
    if os.environ.get("CONDA_PREFIX"):
        add(interpreter(Path(os.environ["CONDA_PREFIX"])))
    add(sys.executable)
    if WINDOWS and shutil.which("py"):
        try:
            out = decode(subprocess.run(["py", "-0p"], capture_output=True, timeout=30).stdout)
            for line in out.splitlines():
                m = re.search(r"([A-Za-z]:\\.*?python\.exe)\s*$", line.strip())
                if m:
                    add(m.group(1))
        except (OSError, subprocess.SubprocessError):
            pass
    add(shutil.which("python"))
    if not WINDOWS:
        for p in posix_pythons():
            add(p)
    for base in conda_bases():
        add(interpreter(base))
        envs = base / "envs"
        if is_dir(envs):
            try:
                for e in sorted(envs.iterdir()):
                    add(interpreter(e))
            except OSError:
                pass
    for e in conda_envs():
        add(interpreter(e))
    return found


# ---------------------------------------------------------------------------------------------------- making .venv


def run(cmd: list, env: dict | None = None) -> None:
    say("> " + " ".join(str(c) for c in cmd))
    subprocess.run([str(c) for c in cmd], check=True, env=env)


def pip_env() -> dict:
    """The environment pip runs in. Your pip settings (an index, a proxy, a certificate) stay, but not the ones that
    would send the install somewhere other than .venv. PIP_USER=1, or user = true in pip.conf or pip.ini, makes pip
    install into the user's site-packages of the Python .venv borrows from, and that Python then imports what was put
    there. An environment variable outranks the config files, so PIP_USER=0 beats both. pip runs in .venv but imports
    its base Python's standard library, so it's also asked not to write .pyc files there (it still compiles what it
    installs into .venv)."""
    env = dict(os.environ, PIP_USER="0", PYTHONDONTWRITEBYTECODE="1")
    for name in ("PIP_TARGET", "PIP_PREFIX", "PIP_ROOT"):   # these also point elsewhere
        env.pop(name, None)
    return env


class PipSettingError(Exception):
    """A pip setting that would send the install somewhere other than .venv."""


def redirecting_settings(python: Path) -> list[str]:
    """What pip's config files (pip.conf or pip.ini) set under [install] or [global] that would put an install
    somewhere other than the environment `python` belongs to: target, prefix or root, as pip lists them ("install.target
    = '/x'"). pip_env can clear the environment variables but not these, so they are read from pip itself."""
    try:
        out = subprocess.run([str(python), "-m", "pip", "config", "list"], capture_output=True, text=True, timeout=120,
                             env=pip_env()).stdout
    except (OSError, subprocess.SubprocessError):
        return []   # nothing to read them from: pip itself will say what's wrong when it installs
    found = []
    for line in out.splitlines():
        name, _, value = line.partition("=")
        section, _, option = name.strip().partition(".")
        if (section in ("install", "global") and option.lstrip("-").replace("_", "-") in ("target", "prefix", "root")
                and value.strip().strip("'\"")):
            found.append(f"{section}.{option} = {value.strip()}")
    return found


def pip_install(python: Path, *args, inside: Path | None = None) -> None:
    """pip install into the environment `python` belongs to, which has to be GelScribe's own: never into yours. Not at all
    while a pip setting would send it somewhere else (PipSettingError)."""
    inside = inside or VENV
    if inside not in Path(os.path.abspath(python)).parents:
        raise ValueError(f"{python} isn't inside {inside}")
    bad = redirecting_settings(python)
    if bad:
        raise PipSettingError(f"pip is set to install somewhere other than GelScribe's .venv folder: {'; '.join(bad)}. "
                              "Setting up stops rather than install there. Take that setting out of your pip.conf or "
                              "pip.ini (pip config debug names the files), then start GelScribe again.")
    run([python, "-m", "pip", "install", "--disable-pip-version-check", "--prefer-binary", *args], env=pip_env())


def qt_inside(env: Path) -> Path | None:
    """PySide6 installed into this environment itself (not one it borrows from another Python)."""
    for site in [env / "Lib" / "site-packages"] + sorted((env / "lib").glob("python3*/site-packages")):
        if (site / "PySide6").is_dir():
            return site / "PySide6"
    return None


def trim(qt: Path, inside: Path = VENV) -> int:
    """Removes the parts of Qt GelScribe never uses. Only ever inside GelScribe's own environment."""
    qt = qt.resolve()
    if inside.resolve() not in qt.parents:
        raise ValueError(f"{qt} isn't inside {inside}")
    freed = 0
    for pattern in QT_UNUSED:
        folder, _, name = pattern.rpartition("/")
        parent = qt / folder if folder else qt
        if not parent.is_dir():
            continue
        for p in list(parent.iterdir()):
            if fnmatch.fnmatch(p.name, name):
                try:
                    if p.is_dir():
                        size = sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
                        shutil.rmtree(p)
                    else:
                        size = p.stat().st_size
                        p.unlink()
                except OSError:   # held open by a virus scanner or OneDrive: it can stay, GelScribe doesn't load it
                    continue
                freed += size
    return freed


def untrimmed() -> bool:
    qt = qt_inside(VENV)
    return bool(qt) and (qt / "opengl32sw.dll").exists()


def make_env(base: Path, reuse: bool) -> Path:
    shutil.rmtree(VENV, ignore_errors=True)
    run([base, "-m", "venv"] + (["--system-site-packages"] if reuse else []) + [VENV], env=quiet_env())
    python = env_python(VENV)
    pip_install(python, "-r", REQUIREMENTS)
    return python


def slim_and_check(python: Path) -> bool:
    """Trims Qt in .venv, then checks GelScribe still works; if not, puts the full Qt back."""
    qt = qt_inside(VENV) if WINDOWS else None
    if qt:
        try:
            freed = trim(qt)
            say(f"Left out {freed / 1e6:.0f} MB of Qt that GelScribe doesn't use.")
        except OSError as e:
            say(f"Couldn't leave out the Qt parts GelScribe doesn't use ({e}). It runs fine with them.")
    if usable(run_probe(python)):
        return True
    if qt:
        say("GelScribe needs more of Qt here than expected: putting it all back.")
        pip_install(python, "--force-reinstall", "--no-deps", "PySide6-Essentials", "shiboken6")
        return usable(run_probe(python))
    return False


# ---------------------------------------------------------------------------------------------------- choosing


def pythonw(python: Path) -> Path:
    w = python.with_name("pythonw.exe")
    return w if w.exists() else python


def choice_text(python: Path) -> str | None:
    """What python.txt says about this Python, or None if it can't say it so GelScribe.bat reads it right. The batch
    file decodes python.txt with the console's code page, which can't be known from here, so on Windows it's plain
    ASCII: a Python inside the GelScribe folder (the private .venv) is written relative to it, so the folder can have
    any name, and any other as it is."""
    target = pythonw(python)
    if not WINDOWS:
        return str(target)
    try:
        text = str(target.relative_to(HERE))
    except ValueError:
        text = str(target)
    return text if text.isascii() else None


def remember(python: Path) -> bool:
    """Writes python.txt so the launchers start GelScribe with this Python. False if it can't say where that is."""
    text = choice_text(python)
    if text is None:
        return False
    CHOICE.write_text(text + "\n", encoding="ascii" if WINDOWS else "utf-8")
    shutil.copyfile(REQUIREMENTS, USED)
    if WINDOWS:
        try:
            subprocess.run([str(python), "-B", "-m", "gelscribe.app.shortcuts"], cwd=str(HERE), capture_output=True,
                           env=quiet_env())
        except OSError:
            pass
    elif not MAC:
        menu_entry()
    return True


def menu_entry() -> None:
    """Linux: GelScribe in the applications menu, with its logo (~/.local/share/applications/gelscribe.desktop).
    It starts GelScribe.sh, like the Start-menu shortcut on Windows."""
    def quoted(path: Path) -> str:   # an Exec argument, escaped as the desktop entry spec asks
        s = str(path).replace("\\", "\\\\\\\\").replace('"', '\\"').replace("`", "\\`").replace("$", "\\$")
        return '"' + s.replace("%", "%%") + '"'
    apps = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / "applications"
    icon = HERE / "gelscribe" / "app" / "resources" / "icon.png"
    text = ("[Desktop Entry]\nType=Application\nName=GelScribe\nComment=Labeled figures from gel and blot scans\n"
            f"Exec={quoted(HERE / 'GelScribe.sh')} %F\nIcon={icon}\nTerminal=false\nCategories=Graphics;Science;\n"
            "StartupWMClass=GelScribe\n")
    try:
        apps.mkdir(parents=True, exist_ok=True)
        (apps / "gelscribe.desktop").write_text(text, encoding="utf-8")
        say(f"Added GelScribe to the applications menu ({apps / 'gelscribe.desktop'}).")
    except OSError:
        pass


def no_python() -> None:
    """Nothing to make GelScribe's environment from. Setup never downloads Python: you install one."""
    if WINDOWS:
        say("No Python 3.11 or newer here can make an environment (looked for python.org's py, python on PATH")
        say("and conda). GelScribe doesn't download Python. Install Python 3.13 from https://www.python.org/downloads/")
        say(f"and tick \"Add python.exe to PATH\" (Python {WORKING} work), then start GelScribe again.")
    elif MAC:
        say("No Python 3.11 or newer here can make an environment (looked on PATH, in Homebrew, python.org's")
        say("installs, pyenv and conda). GelScribe doesn't download Python. Install Python 3.12 from")
        say("https://www.python.org/downloads/macos/ or with Homebrew (brew install python@3.12), then start")
        say("GelScribe again.")
    else:
        say("No Python 3.11 or newer here can make an environment (looked on PATH, in pyenv and in conda).")
        say("GelScribe doesn't download Python. Install Python 3.11 or newer with its venv module, for example")
        say("sudo apt install python3 python3-venv on Debian or Ubuntu, then start GelScribe again.")


def too_new(info: dict) -> bool:
    """Newer than the Pythons Qt has wheels for."""
    return tuple(info["version"][:2]) > QT_PYTHONS[1]


def order_bases(bases: list) -> list:
    """The Pythons to try making .venv from, best first: the ones that already have the most of what's needed, with a
    Python newer than Qt has wheels for after all the others. A venv counts as having nothing, as .venv would borrow
    its base Python's packages, not its own. Two ways to the same Python count once."""
    nothing = len(requirements())
    seen = set()
    unique = []
    for python, info in bases:
        key = (info["prefix"], tuple(info["version"]))
        if key not in seen:
            seen.add(key)
            unique.append((python, info))
    return sorted(unique, key=lambda pi: (too_new(pi[1]), nothing if pi[1].get("venv") else len(pi[1]["missing"])))


def from_base(base: Path, info: dict) -> Path | None:
    """GelScribe's own environment made from this Python, or None if that doesn't work out."""
    say()
    say(f"Making a private environment in the .venv folder from {info['prefix']},")
    say("using what that Python already has and downloading only what's missing...")
    try:
        python = make_env(base, reuse=True)
        if slim_and_check(python):
            return python
        say("Borrowing that Python's packages didn't work: making a separate environment instead...")
        python = make_env(base, reuse=False)
        if slim_and_check(python):
            return python
        say("GelScribe still doesn't start in the new environment.")
    except subprocess.CalledProcessError as e:
        say(f"That didn't work ({e}).")
    return None


def none_worked(bases: list) -> None:
    say()
    say("None of the Pythons here could make GelScribe's environment (the reasons are above).")
    newer = [i["version"][:2] for _p, i in bases if too_new(i)]
    if newer:
        say(f"Python {'.'.join(map(str, max(newer)))} may be too new for Qt (PySide6). Python {WORKING} work: install")
        say("Python 3.13 from https://www.python.org/downloads/ next to it and start GelScribe again. It uses the")
        say("one that works.")


def setup() -> int:
    say("Looking for a Python that already has what GelScribe needs...")
    infos = []
    for python in candidates():
        info = run_probe(python)
        if info is None:
            say(f"  {python}: couldn't be checked")
            continue
        infos.append((python, info))
        if usable(info):
            own = VENV.is_dir() and python == env_python(VENV)
            if own and WINDOWS and untrimmed() and not slim_and_check(python):   # made before trimming existed
                say(f"  {python}: doesn't start after all")
                continue
            if choice_text(python) is None:   # then .venv, which borrows all of it, is made from it below
                say(f"  {python}: has everything, but GelScribe.bat can't be given a path with those characters")
                continue
            say(f"  {python}: has everything")
            remember(python)
            if own:
                say("GelScribe will run from its own environment in the .venv folder.")
            else:
                say(f"GelScribe will run from {info['prefix']}. Nothing was downloaded.")
            return 0
        say(f"  {python}: " + (info["problem"] or "no " + ", ".join(info["missing"])))

    own = env_python(VENV)
    if VENV.is_dir() and own.exists() and any(p == own for p, _ in infos):
        say()   # after an update with new requirements: add them to .venv rather than making it again
        say("Bringing GelScribe's environment in the .venv folder up to date...")
        try:
            pip_install(own, "-r", REQUIREMENTS)
            if slim_and_check(own) and remember(own):
                say("GelScribe will run from its own environment in the .venv folder.")
                return 0
        except subprocess.CalledProcessError:
            pass
        say("That didn't work: making the environment again.")

    bases = [(p, i) for p, i in infos if i["can_make_env"] and tuple(i["version"]) >= (3, 11) and p != own]
    python = None
    # the one with the most already there first; another if that one can't (no wheels for this system, no venv)
    for base, info in order_bases(bases):
        python = from_base(base, info)
        if python is not None:
            break
    if python is None:
        if bases:
            none_worked(bases)
        else:
            no_python()
        return 1
    if not remember(python):
        say("GelScribe's folder name can't be given to GelScribe.bat. Move GelScribe to a folder with a plain name.")
        return 1
    say("GelScribe will run from its own environment in the .venv folder.")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--probe"]:
        print(PROBE + json.dumps(probe()), flush=True)
        sys.exit(0)
    try:
        sys.exit(setup())
    except subprocess.CalledProcessError as e:
        say(f"Setting up stopped: {e}")
        sys.exit(1)
    except PipSettingError as e:
        say(f"Setting up stopped: {e}")
        sys.exit(1)
    except OSError as e:
        say(f"Setting up stopped: {e}")
        if isinstance(e, PermissionError) or e.errno == errno.EROFS:
            say("GelScribe's folder has to be one you can write to. Move it to a folder such as Documents (not inside")
            say("a zip or in Program Files) and start GelScribe again.")
        sys.exit(1)
