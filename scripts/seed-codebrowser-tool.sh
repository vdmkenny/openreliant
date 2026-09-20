#!/usr/bin/env bash
# usage: seed-codebrowser-tool.sh <ghidra-home> <ghidra-user-dir>
#
# Ghidra keeps each user's CodeBrowser configuration in <user-dir>/tools/_code_browser.tcd, created
# from a default on first launch. Extension plugins are off until ticked in File > Configure. This
# writes the default configuration with the Ghydra plugin already enabled, so a fresh install
# serves the GhydraMCP HTTP API as soon as a program is opened.
#
# An existing configuration is the user's own and is never overwritten.
set -euo pipefail

ghidra_home=$1 user_dir=$2
tool="$user_dir/tools/_code_browser.tcd"
plugin=eu.starsong.ghidra.GhydraPlugin

if [[ -e "$tool" ]]; then
    if grep -q "$plugin" "$tool"; then
        echo "CodeBrowser already has the Ghydra plugin enabled"
    else
        echo "note: $tool exists without the Ghydra plugin;" >&2
        echo "      enable it in the CodeBrowser under File > Configure > Developer." >&2
    fi
    exit 0
fi

mkdir -p "$(dirname "$tool")"
unzip -p "$ghidra_home/Ghidra/Configurations/Public_Release/lib/Public_Release.jar" \
        defaultTools/CodeBrowser.tool |
    awk -v plugin="$plugin" '
        { print }
        /<PACKAGE NAME="BSim" \/>/ {
            print "        <PACKAGE NAME=\"Developer\">"
            print "            <INCLUDE CLASS=\"" plugin "\" />"
            print "        </PACKAGE>"
            seeded = 1
        }
        END { if (!seeded) exit 1 }
    ' > "$tool" || { rm -f "$tool"; echo "unexpected default CodeBrowser layout" >&2; exit 1; }
echo "seeded $tool"
