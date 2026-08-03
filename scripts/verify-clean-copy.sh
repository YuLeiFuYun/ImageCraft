#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM
EXPECTED="$TMPDIR_ROOT/expected-source-identity.json"
COPY="$TMPDIR_ROOT/ImageCraft"
python3 Tools/Identity/capture_source_identity.py --output "$EXPECTED"
python3 Tools/Identity/materialize_clean_copy.py \
    --source-root "$ROOT" \
    --identity "$EXPECTED" \
    --destination "$COPY"
(
    cd "$COPY"
    DEVELOPER_DIR="$DEVELOPER_DIR" scripts/verify.sh
)
python3 "$COPY/Tools/Identity/capture_source_identity.py" \
    --output "$TMPDIR_ROOT/copied-source-identity.json" \
    --compare "$EXPECTED"
printf 'ImageCraft clean-copy verification passed.\n'
