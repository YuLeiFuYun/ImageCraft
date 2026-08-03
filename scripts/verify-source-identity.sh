#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM
python3 Tools/Identity/capture_source_identity.py \
    --output "$TMPDIR_ROOT/first.json"
python3 Tools/Identity/capture_source_identity.py \
    --output "$TMPDIR_ROOT/second.json" \
    --compare "$TMPDIR_ROOT/first.json"
cmp "$TMPDIR_ROOT/first.json" "$TMPDIR_ROOT/second.json"
mkdir -p .build
cp "$TMPDIR_ROOT/second.json" .build/source-identity.json
printf 'ImageCraft source identity is stable.\n'
