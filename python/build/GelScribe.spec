# PyInstaller spec for GelScribe: one folder (dist/GelScribe) holding the windowed app and the command-line tool.
# Built by build-exe.bat on Windows; it also builds on a Mac or Linux (pyinstaller build/GelScribe.spec, from python/;
# the files both programs need are in the folder once).
#   GelScribe.exe        the app, no console window
#   gelscribe-cli.exe    the command-line tool, in a console (the same commands as GelScribe.bat render, help, ...).
#                        Not "gelscribe.exe": Windows file names ignore case, so that would be GelScribe.exe again.
import sys
from pathlib import Path

from PyInstaller.utils.hooks import collect_submodules

ROOT = Path(SPECPATH).resolve().parent            # the python folder
sys.path.insert(0, str(ROOT))
from gelscribe import __version__                  # 0.1.1

WIN = sys.platform == "win32"
NUMBERS = tuple((int(p) if p.isdigit() else 0) for p in (__version__.split(".") + ["0", "0", "0"])[:3]) + (0,)

# A build Python made from Anaconda or Miniconda keeps the DLLs that Python's own modules load (libffi for ctypes,
# which SciPy needs; OpenSSL for the update check; bz2, lzma, expat) in Library\bin, outside the venv, where
# PyInstaller doesn't look, so the app failed with "DLL load failed while importing _ctypes". Take just those DLLs
# along by name. Not the whole folder: it also holds older copies of Windows runtime DLLs, and with those Qt failed
# with "DLL load failed while importing QtCore: The specified procedure could not be found".
extra_binaries = []
if WIN:
    import glob
    base = Path(sys.base_prefix)
    for d in (base / "Library" / "bin", base / "DLLs"):
        for pattern in ("ffi*.dll", "libffi*.dll", "libssl-*.dll", "libcrypto-*.dll", "libbz2*.dll", "liblzma*.dll",
                        "libexpat*.dll"):
            extra_binaries += [(f, ".") for f in glob.glob(str(d / pattern))]

# every file the package reads from disk next to its modules
RES = "gelscribe/app/resources"
datas = [
    (str(ROOT / "gelscribe" / "core" / "ladders.json"), "gelscribe/core"),   # core/ladders.py
    (str(ROOT / "gelscribe" / "app" / "resources" / "icon.ico"), RES),        # app/window.py (the window icon)
    (str(ROOT / "gelscribe" / "app" / "resources" / "icon.png"), RES),
]

hiddenimports = (collect_submodules("gelscribe", filter=lambda n: n != "gelscribe.bootstrap")
                 + collect_submodules("imagecodecs"))   # imagecodecs loads its codecs by name

excludes = [
    "tkinter", "_tkinter", "matplotlib", "pytest", "IPython", "jupyter", "notebook", "pandas", "sympy", "setuptools",
    "pip", "wheel", "test", "lib2to3", "distutils", "curses", "sqlite3", "dask",
    "numba", "torch", "tensorflow", "cv2", "h5py", "zarr", "lxml.html.soupparser",
    "PySide6.QtWebEngineCore", "PySide6.QtWebEngineWidgets", "PySide6.QtWebEngineQuick", "PySide6.QtWebChannel",
    "PySide6.QtWebSockets", "PySide6.QtWebView", "PySide6.Qt3DCore", "PySide6.Qt3DRender", "PySide6.Qt3DInput",
    "PySide6.Qt3DLogic", "PySide6.Qt3DAnimation", "PySide6.Qt3DExtras", "PySide6.QtMultimedia",
    "PySide6.QtMultimediaWidgets", "PySide6.QtQml", "PySide6.QtQuick", "PySide6.QtQuickWidgets",
    "PySide6.QtQuick3D", "PySide6.QtQuickControls2", "PySide6.QtDesigner", "PySide6.QtHelp", "PySide6.QtCharts",
    "PySide6.QtDataVisualization", "PySide6.QtGraphs", "PySide6.QtBluetooth", "PySide6.QtNfc", "PySide6.QtSensors",
    "PySide6.QtSerialPort", "PySide6.QtSerialBus", "PySide6.QtPositioning", "PySide6.QtLocation",
    "PySide6.QtRemoteObjects", "PySide6.QtScxml", "PySide6.QtSql", "PySide6.QtTest", "PySide6.QtTextToSpeech",
    "PySide6.QtSpatialAudio", "PySide6.QtPdfWidgets", "PySide6.QtOpenGL", "PySide6.QtOpenGLWidgets",
    "PySide6.QtNetworkAuth", "PySide6.QtStateMachine", "PySide6.QtConcurrent", "PySide6.QtDBus",
    "PySide6.QtHttpServer", "PySide6.QtAxContainer", "PySide6.QtUiTools", "PySide6.QtXml", "PySide6.QtSvgWidgets",
]
# Qt's own libraries for the same parts, and translations, which GelScribe doesn't use
DROP = ("Qt6WebEngine", "Qt63D", "Qt6Quick", "Qt6Qml", "Qt6Multimedia", "Qt6Designer", "Qt6Charts", "Qt6DataVis",
        "Qt6Graphs", "Qt6Help", "Qt6Sql", "Qt6Test", "Qt6Bluetooth", "Qt6Nfc", "Qt6Sensors", "Qt6SerialPort",
        "Qt6Positioning", "Qt6RemoteObjects", "Qt6Scxml", "Qt6Pdf", "Qt6OpenGL", "Qt6VirtualKeyboard", "Qt6Spatial",
        "Qt6ShaderTools", "Qt6Concurrent", "Qt6Xml")


def trim(entries):
    out = []
    for e in entries:
        name = e[0].replace("\\", "/")
        base = name.rsplit("/", 1)[-1]
        if base.startswith(("lib",)):
            base = base[3:]
        if base.startswith(DROP) or "/translations/" in name or name.startswith("PySide6/translations"):
            continue
        out.append(e)
    return out


def analysis(script):
    return Analysis([str(ROOT / "build" / script)], pathex=[str(ROOT)], binaries=extra_binaries, datas=datas, hiddenimports=hiddenimports,
                    excludes=excludes, noarchive=False)


app_a = analysis("entry_app.py")
cli_a = analysis("entry_cli.py")
for a in (app_a, cli_a):
    # Qt's libraries are all kept: dropping some to save space left the Windows display plugin unable to start
    a.datas = trim(a.datas)

version = None
if WIN:   # the Details tab of GelScribe.exe's Properties
    from PyInstaller.utils.win32.versioninfo import (FixedFileInfo, StringFileInfo, StringStruct, StringTable,
                                                     VarFileInfo, VarStruct, VSVersionInfo)
    dotted = ".".join(str(n) for n in NUMBERS)

    def info(filename, description):
        """The version resource as a text file in the work folder, which is what PyInstaller reads."""
        v = VSVersionInfo(
            ffi=FixedFileInfo(filevers=NUMBERS, prodvers=NUMBERS, mask=0x3F, flags=0x0, OS=0x40004, fileType=0x1,
                              subtype=0x0, date=(0, 0)),
            kids=[StringFileInfo([StringTable("040904B0", [
                StringStruct("CompanyName", ""), StringStruct("FileDescription", description),
                StringStruct("FileVersion", dotted), StringStruct("InternalName", "GelScribe"),
                StringStruct("OriginalFilename", filename), StringStruct("ProductName", "GelScribe"),
                StringStruct("ProductVersion", dotted)])]),
                VarFileInfo([VarStruct("Translation", [0x409, 1200])])])
        path = Path(SPECPATH) / "work" / (filename + ".version.txt")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(str(v), encoding="utf-8")
        return str(path)


icon = str(ROOT / "gelscribe" / "app" / "resources" / "icon.ico") if WIN else None


def program(a, name, windowed):
    return EXE(PYZ(a.pure), a.scripts, [], exclude_binaries=True, name=name, console=not windowed, icon=icon,
               version=info(name + ".exe", "GelScribe" if windowed else "GelScribe command-line tool") if WIN else None,
               upx=False, debug=False, bootloader_ignore_signals=False, strip=False)


app_exe = program(app_a, "GelScribe", True)
cli_exe = program(cli_a, "gelscribe-cli", False)

COLLECT(app_exe, app_a.binaries, app_a.datas,
        cli_exe, cli_a.binaries, cli_a.datas,
        strip=False, upx=False, name="GelScribe")
