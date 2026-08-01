#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

BREW=${IMAGECRAFT_BREW:-$(command -v brew || true)}
: "${BREW:?Homebrew is required to reproduce the retained corpus}"
JPEG_PREFIX=$($BREW --prefix jpeg-turbo)
CJPEG=${IMAGECRAFT_CJPEG:-"$JPEG_PREFIX/bin/cjpeg"}
[ -x "$CJPEG" ] || { echo 'libjpeg-turbo cjpeg is required' >&2; exit 1; }

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM
GENERATED="$TMPDIR_ROOT/v1"
Tools/Corpus/generate_retained_corpus.py \
    --output "$GENERATED" \
    --cjpeg "$CJPEG" \
    --jpeg-prefix "$JPEG_PREFIX"
python3 Tools/Corpus/verify_manifest.py "$GENERATED/manifest.json"
diff -rq "$GENERATED" Tests/ImageCraftImageIOTests/Resources/Corpus/v1
