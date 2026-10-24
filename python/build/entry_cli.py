"""PyInstaller entry point of the console program: the command-line tool, same commands as GelScribe.bat render and so on."""
import sys

from gelscribe.cli import main

sys.exit(main(sys.argv[1:]))
