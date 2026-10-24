"""python -m gelscribe [files…] starts the app; python -m gelscribe COMMAND … is the command-line tool (cli.py)."""
import sys


def startup_failed(e: BaseException) -> int:
    """GelScribe.bat starts the app with pythonw, which has no console, so a failed start says so in a message box."""
    import traceback
    if sys.stderr:
        sys.stderr.write("".join(traceback.format_exception(e)))
    if sys.platform == "win32":
        import ctypes
        fix = ("Reinstall GelScribe, or report this message." if getattr(sys, "frozen", False)   # the .exe build
               else "To set it up again, delete python.txt in the GelScribe folder and double-click GelScribe.bat.")
        ctypes.windll.user32.MessageBoxW(None, f"GelScribe could not start.\n\n{type(e).__name__}: {e}\n\n{fix}",
                                         "GelScribe", 0x10)
    return 1


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ("new", "edit", "render", "detect", "presets", "verify", "help", "-h",
                                             "--help", "--version"):
        from gelscribe.cli import main   # python -m gelscribe render blot.gelscribe … is the command-line tool
        sys.exit(main(sys.argv[1:]))
    try:
        from gelscribe.app.main import run
    except Exception as e:   # a missing or broken package
        sys.exit(startup_failed(e))
    sys.exit(run())
