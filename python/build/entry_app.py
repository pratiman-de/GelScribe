"""PyInstaller entry point of GelScribe.exe: the same as python -m gelscribe (the app, or a command if one comes first)."""
import runpy

runpy.run_module("gelscribe", run_name="__main__", alter_sys=True)
