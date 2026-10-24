"""PyInstaller entry point of GelScribe.exe: the same as python -m gelscribe (the app, or a command if one comes first)."""
import os
import runpy

# Qt settings left in the environment by another Qt install (conda sets QT_PLUGIN_PATH, for one) would send this app
# to that install's plugins, and it then fails with "no Qt platform plugin could be initialized". It has its own.
for name in ("QT_PLUGIN_PATH", "QT_QPA_PLATFORM_PLUGIN_PATH", "QT_QPA_PLATFORM"):
    os.environ.pop(name, None)

runpy.run_module("gelscribe", run_name="__main__", alter_sys=True)
