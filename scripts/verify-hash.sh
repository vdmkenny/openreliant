#!/usr/bin/env bash
# usage: verify-hash.sh <md5|sha1|sha256|sha512> <expected-hex> <file>
#
# Fails, and deletes nothing, when the digest of <file> differs from <expected-hex>.
set -euo pipefail

algo=$1 expected=$2 file=$3

# `openssl dgst -r` prints "<hex> *<file>" on every platform we care about.
actual=$(openssl dgst "-$algo" -r "$file" | cut -d' ' -f1)

if [[ "$actual" != "$expected" ]]; then
    printf '%s: %s mismatch\n  expected %s\n  actual   %s\n' "$file" "$algo" "$expected" "$actual" >&2
    exit 1
fi
printf '%s: %s ok\n' "$(basename "$file")" "$algo"
