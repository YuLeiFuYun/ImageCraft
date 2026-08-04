#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
BREW=${IMAGECRAFT_BREW:-$(command -v brew || true)}
: "${BREW:?Homebrew is required to reproduce the progressive photo corpus}"
JPEG_PREFIX=$($BREW --prefix jpeg-turbo)
CJPEG=${IMAGECRAFT_CJPEG:-"$JPEG_PREFIX/bin/cjpeg"}
DJPEG=${IMAGECRAFT_DJPEG:-"$JPEG_PREFIX/bin/djpeg"}
[ -x "$CJPEG" ] || { echo 'libjpeg-turbo cjpeg is required' >&2; exit 1; }
[ -x "$DJPEG" ] || { echo 'libjpeg-turbo djpeg is required' >&2; exit 1; }
SPEC=Evidence/Fixtures/ProgressiveJPEGRealPhoto/v1
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM
GENERATED="$TMPDIR_ROOT/v1"
Tools/Corpus/generate_progressive_photo_corpus.py \
    --spec-root "$SPEC" \
    --output "$GENERATED" \
    --cjpeg "$CJPEG" \
    --djpeg "$DJPEG"
Tools/Corpus/verify_progressive_photo_corpus.py "$GENERATED/manifest.json"
diff -rq "$GENERATED" "$SPEC"
