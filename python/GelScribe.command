#!/bin/sh
# GelScribe on a Mac (the Python version, for Macs that can't run the Mac app): double-click to start. The first
# start sets it up in this Terminal window. Everything happens in GelScribe.sh, next to this file.
# A numpy.py or a PIL folder next to where this is run can't stand in for a library: the same safe path as GelScribe.sh.
PYTHONSAFEPATH=1
export PYTHONSAFEPATH
exec "$(dirname "$0")/GelScribe.sh" "$@"
