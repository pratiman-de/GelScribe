"""Windows shortcuts for GelScribe, with the logo and the AppUserModelID the app gives itself. Windows takes a taskbar
button's icon from the Start-menu shortcut with the same ID, so this is what puts the logo there instead of Python's.
GelScribe.bat runs it after setting up: python -m gelscribe.app.shortcuts"""
from __future__ import annotations

import ctypes
import os
import sys
from ctypes import POINTER, Structure, byref, c_int, c_ubyte, c_ulong, c_ushort, c_void_p, c_wchar_p
from pathlib import Path

AUMID = "GelScribe.GelScribe"   # main.run() gives the process the same one

CLSID_SHELL_LINK = "{00021401-0000-0000-C000-000000000046}"
IID_SHELL_LINK_W = "{000214F9-0000-0000-C000-000000000046}"
IID_PROPERTY_STORE = "{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}"
IID_PERSIST_FILE = "{0000010B-0000-0000-C000-000000000046}"
PKEY_APP_USER_MODEL_ID = ("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}", 5)
VT_LPWSTR = 31


class GUID(Structure):
    _fields_ = [("Data1", c_ulong), ("Data2", c_ushort), ("Data3", c_ushort), ("Data4", c_ubyte * 8)]

    @classmethod
    def of(cls, s: str) -> "GUID":
        g = cls()
        ctypes.oledll.ole32.CLSIDFromString(c_wchar_p(s), byref(g))
        return g


class PROPERTYKEY(Structure):
    _fields_ = [("fmtid", GUID), ("pid", c_ulong)]


class PROPVARIANT(Structure):   # enough of it for a string (VT_LPWSTR); full size, as the callee may copy it all
    _fields_ = [("vt", c_ushort), ("reserved", c_ushort * 3), ("pointer", c_void_p), ("pad", c_void_p)]


def _call(obj: c_void_p, index: int, argtypes: tuple, *args):
    """Method `index` of a COM interface, counting IUnknown's three first."""
    vtable = ctypes.cast(obj, POINTER(POINTER(c_void_p))).contents
    return ctypes.WINFUNCTYPE(ctypes.HRESULT, c_void_p, *argtypes)(vtable[index])(obj, *args)


def _query(obj: c_void_p, iid: str) -> c_void_p:
    out = c_void_p()
    _call(obj, 0, (POINTER(GUID), POINTER(c_void_p)), byref(GUID.of(iid)), byref(out))   # QueryInterface
    return out


def make_shortcut(lnk: Path, target: Path, arguments: str, workdir: Path, icon: Path) -> None:
    ole32 = ctypes.oledll.ole32
    ole32.CoInitialize(None)
    link = c_void_p()
    ole32.CoCreateInstance(byref(GUID.of(CLSID_SHELL_LINK)), None, 1, byref(GUID.of(IID_SHELL_LINK_W)), byref(link))
    store = files = None
    try:
        _call(link, 20, (c_wchar_p,), str(target))               # IShellLinkW::SetPath
        _call(link, 11, (c_wchar_p,), arguments)                 # SetArguments
        _call(link, 9, (c_wchar_p,), str(workdir))               # SetWorkingDirectory
        _call(link, 17, (c_wchar_p, c_int), str(icon), 0)        # SetIconLocation
        _call(link, 7, (c_wchar_p,), "Labeled figures from gel and blot scans")   # SetDescription
        store = _query(link, IID_PROPERTY_STORE)
        key = PROPERTYKEY(GUID.of(PKEY_APP_USER_MODEL_ID[0]), PKEY_APP_USER_MODEL_ID[1])
        text = ctypes.create_unicode_buffer(AUMID)
        pv = PROPVARIANT(VT_LPWSTR)
        pv.pointer = ctypes.addressof(text)
        _call(store, 6, (POINTER(PROPERTYKEY), POINTER(PROPVARIANT)), byref(key), byref(pv))   # IPropertyStore::SetValue
        _call(store, 7, ())                                      # Commit
        files = _query(link, IID_PERSIST_FILE)
        lnk.parent.mkdir(parents=True, exist_ok=True)
        _call(files, 6, (c_wchar_p, c_int), str(lnk), 1)         # IPersistFile::Save
    finally:
        for obj in (files, store, link):
            if obj:
                _call(obj, 2, ())                                # Release


def main() -> int:
    """GelScribe.lnk next to GelScribe.bat, and in the Start menu."""
    if sys.platform != "win32":
        return 0
    here = Path(__file__).resolve().parents[2]   # the GelScribe folder
    target = Path(sys.executable).with_name("pythonw.exe")   # run with the Python GelScribe runs from
    icon = here / "gelscribe" / "app" / "resources" / "icon.ico"
    start_menu = Path(os.environ.get("APPDATA", "")) / "Microsoft" / "Windows" / "Start Menu" / "Programs"
    made = 0
    for lnk in (here / "GelScribe.lnk", start_menu / "GelScribe.lnk"):
        try:
            make_shortcut(lnk, target, "-m gelscribe", here, icon)
            made += 1
            print(lnk)
        except OSError as e:
            print(f"Couldn't make {lnk}: {e}", file=sys.stderr)
    return 0 if made else 1


if __name__ == "__main__":
    sys.exit(main())
