#!/usr/bin/env bash
# usage: check-files.sh [--staged | --history]
#
# Fails when a file from the game, or one that looks like it, is in the repository or about to
# enter it. With no option it checks the files git tracks; with --staged, what the next commit
# holds, as the pre-commit hook does; with --history, every file of every commit, as CI does.
#
# A file fails when it lies in one of the git-ignored directories for the game's files, has the
# extension of one of the game's file types or of what the extractors write, starts with the
# signature of an executable, archive, image, sound or document, holds binary data anywhere but
# the compiled shaders, or is over 1 MiB.
set -euo pipefail

mode=${1:-}
case $mode in
    "" | --staged | --history) ;;
    *) echo "usage: $0 [--staged | --history]" >&2; exit 2 ;;
esac
cd "$(git rev-parse --show-toplevel)"

# The only binary files the repository holds: the compiled shaders.
allowed_binary='^src/platform/shaders/[^/]+\.spv$'
game_dirs='^(game|references|tools|ghidra/projects|ghidra/export)/'
game_types='hog|shp|spr|dte|fat|fnt|frc|tga|bik|icd|exe|dll|m3d|asi|ccb|cab|bin|dat|iso|cue|mdf|mds|nrg|img|wav|mp3|ogg|png|jpg|jpeg|gif|bmp|pcx|ppm|obj|pdf|rtf|doc|ini|sav|zip'
max_size=$((1024 * 1024))

failed=0
fail() { # fail <path> <reason>
    printf '  %s: %s\n' "$1" "$2" >&2
    failed=1
}

# Every path to check, one a line.
paths() {
    case $mode in
        "") git ls-files ;;
        --staged) git diff --cached --name-only --diff-filter=ACMR ;;
        --history) git log --all --name-only --format= | sort -u ;;
    esac
}

# Every file's content to check, as "<blob> <size> <path>" lines.
blobs() {
    case $mode in
        "") git ls-files -s | while IFS=$'\t' read -r meta path; do
                set -- $meta
                printf '%s %s\n' "$2" "$path"
            done ;;
        --staged) git diff --cached --name-only --diff-filter=ACMR | while IFS= read -r path; do
                git ls-files -s -- "$path" | while IFS=$'\t' read -r meta _; do
                    set -- $meta
                    printf '%s %s\n' "$2" "$path"
                done
            done ;;
        --history) git rev-list --objects --all ;;
    esac | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' |
        awk '$1 == "blob" { print substr($0, 6) }'
}

while IFS= read -r path; do
    [[ -n $path ]] || continue
    lower=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
    if [[ $path =~ $game_dirs ]]; then
        fail "$path" "lies in a directory kept for the game's files"
    elif [[ $lower =~ \.($game_types)$ ]]; then
        fail "$path" "has the extension of one of the game's files or of what the extractors write"
    fi
done < <(paths)

while read -r blob size path; do
    if ((size > max_size)); then
        fail "$path" "is over 1 MiB"
        continue
    fi
    # Only the first bytes: git stops on a broken pipe, which is no failure here.
    signature=$(set +o pipefail; git cat-file blob "$blob" | head -c 4 | od -An -tx1 | tr -d ' \n')
    case $signature in
        4d5a*) fail "$path" "starts like a Windows executable" ;;
        42494746) fail "$path" "starts like a BIGF archive" ;;
        10fb*) fail "$path" "starts like RefPack-compressed data" ;;
        52494646) fail "$path" "starts like a RIFF file, a sound or a video" ;;
        42494b*) fail "$path" "starts like a Bink video" ;;
        89504e47 | ffd8ff* | 47494638) fail "$path" "starts like an image" ;;
        4f676753 | 494433*) fail "$path" "starts like a sound" ;;
        504b0304 | 4d534346 | d0cf11e0 | 25504446) fail "$path" "starts like an archive or a document" ;;
        *) if ! [[ $path =~ $allowed_binary ]] &&
               (($(git cat-file blob "$blob" | tr -d '\000' | wc -c) != size)); then
               fail "$path" "holds binary data"
           fi ;;
    esac
done < <(blobs)

if ((failed)); then
    echo "These look like the game's files, or work derived from them, which never go in the" >&2
    echo "repository. OpenReliant reads the game's files from the player's own installation." >&2
    exit 1
fi
