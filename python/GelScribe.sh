#!/bin/sh
# GelScribe on Linux or a Mac. Run ./GelScribe.sh (on a Mac you can double-click GelScribe.command instead).
# The first start picks the Python GelScribe runs from (gelscribe/bootstrap.py): one you already have, if it has
# everything GelScribe needs, or else a small private one made in the .venv folder here. The choice is in python.txt.
# With a command first it's the command-line tool: ./GelScribe.sh render blot.gelscribe, ./GelScribe.sh help.
# Linked into a folder on your PATH it works from anywhere: ln -s "$PWD/GelScribe.sh" ~/.local/bin/gelscribe

# an exported CDPATH makes cd print the folder it enters, which doubles the path in here=$(cd ...)
unset CDPATH

# this script's own folder, following links to it
self=$0
while [ -L "$self" ]; do
    link=$(readlink "$self")
    case $link in
        /*) self=$link ;;
        *) self=$(dirname "$self")/$link ;;
    esac
done
here=$(cd "$(dirname "$self")" && pwd -P) || exit 1

mode=app
case ${1-} in
    new|edit|render|detect|presets|verify|help|-h|--help|--version) mode=cli ;;
esac

say() { printf '%s\n' "$*" >&2; }

# set up already, for these requirements, and that Python is still there
ready() {
    [ -f "$here/python.txt" ] && cmp -s "$here/requirements.txt" "$here/requirements.used" || return 1
    py=$(head -n 1 "$here/python.txt")
    [ -n "$py" ] && [ -x "$py" ]
}

if ! ready; then
    say "Setting up GelScribe. It takes a moment, or a few minutes if Qt has to be downloaded."
    say ""
    # any Python 3.8 or newer can run the setup, which then checks every Python here
    boot=
    for c in python3 python /opt/homebrew/bin/python3 /usr/local/bin/python3 \
             "$HOME/miniconda3/bin/python" "$HOME/anaconda3/bin/python" "$HOME/miniforge3/bin/python" \
             "$HOME/mambaforge/bin/python" "$HOME/opt/anaconda3/bin/python" /opt/miniconda3/bin/python \
             /opt/anaconda3/bin/python; do
        p=$(command -v "$c" 2>/dev/null) || continue
        # Apple's stand-in python3 asks to install the developer tools when they're missing
        if [ "$p" = /usr/bin/python3 ] && [ "$(uname)" = Darwin ] && ! xcode-select -p >/dev/null 2>&1; then
            continue
        fi
        if "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
            boot=$p
            break
        fi
    done
    if [ -z "$boot" ]; then
        if [ "$(uname)" = Darwin ]; then
            say "No Python was found. GelScribe doesn't download Python. Get Python 3.12 from"
            say "https://www.python.org/downloads/macos/ (or with Homebrew: brew install python@3.12), then start"
            say "GelScribe again."
        else
            say "No Python was found. GelScribe doesn't download Python. Install Python 3.11 or newer with its venv"
            say "module (on Debian or Ubuntu: sudo apt install python3 python3-venv), then start GelScribe again."
        fi
        exit 1
    fi
    if ! "$boot" -B "$here/gelscribe/bootstrap.py" >&2 || ! ready; then
        say ""
        say "Setting up didn't finish (the reason is above). If a download failed, check the internet connection."
        say "Then start GelScribe again."
        exit 1
    fi
    say ""
fi

PYTHONPATH="$here${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONPATH
# the app and the commands run in the folder they were typed in: a numpy.py or a PIL folder there can't stand in for a
# library (Python 3.11 and newer leave that folder off the module path)
PYTHONSAFEPATH=1
export PYTHONSAFEPATH
if [ "$mode" = cli ]; then
    exec "$py" -m gelscribe.cli "$@"
fi

# The app runs on its own, so this terminal can be closed. A start that fails within a few seconds is shown here.
log=$(mktemp "${TMPDIR:-/tmp}/gelscribe.XXXXXX") || log=/dev/null
nohup "$py" -m gelscribe "$@" >"$log" 2>&1 &
pid=$!
i=0
while [ $i -lt 8 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.5
    i=$((i + 1))
done
if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid"
    status=$?
    if [ "$status" -ne 0 ]; then
        cat "$log" >&2
        if grep -q xcb "$log" 2>/dev/null; then
            say ""
            say "Qt couldn't open a window. On Debian or Ubuntu, sudo apt install libxcb-cursor0 usually fixes that."
        fi
        say ""
        say "GelScribe didn't start. To set it up again, delete python.txt here and start GelScribe again."
        [ "$log" = /dev/null ] || rm -f "$log"
        exit "$status"
    fi
fi
[ "$log" = /dev/null ] || rm -f "$log"
