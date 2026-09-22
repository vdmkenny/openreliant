#!/usr/bin/env bash
# usage: run.sh <openreliant binary>
#
# Runs controllers.py in a Linux system with /dev/uinput, such as a privileged Docker container
# with the host's /dev mounted (see `make test-controllers`). Installs python3-evdev if needed.
set -euo pipefail
if ! python3 -c "import evdev" 2>/dev/null; then
    apt-get update -qq > /dev/null
    apt-get install -y -qq python3-evdev > /dev/null
fi
exec python3 "$(dirname "$0")/controllers.py" "$1"
