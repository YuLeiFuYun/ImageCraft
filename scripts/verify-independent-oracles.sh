#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -z "${DEVELOPER_DIR:-}" ] || [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
    for candidate in \
        /Applications/Xcode.app/Contents/Developer \
        /Applications/Xcode-beta.app/Contents/Developer
    do
        if [ -x "$candidate/usr/bin/xcodebuild" ]; then
            DEVELOPER_DIR=$candidate
            break
        fi
    done
fi
: "${DEVELOPER_DIR:?A full Xcode installation is required}"
export DEVELOPER_DIR

BREW=${IMAGECRAFT_BREW:-$(command -v brew || true)}
: "${BREW:?Homebrew is required for the independent oracle gate}"
CJPEG=${IMAGECRAFT_CJPEG:-$(command -v cjpeg || true)}
DJPEG=${IMAGECRAFT_DJPEG:-$(command -v djpeg || true)}
if [ -z "$CJPEG" ] || [ -z "$DJPEG" ]; then
    JPEG_PREFIX=$($BREW --prefix jpeg-turbo)
    : "${CJPEG:=$JPEG_PREFIX/bin/cjpeg}"
    : "${DJPEG:=$JPEG_PREFIX/bin/djpeg}"
fi
[ -x "$CJPEG" ] || { echo 'libjpeg-turbo cjpeg is required' >&2; exit 1; }
[ -x "$DJPEG" ] || { echo 'libjpeg-turbo djpeg is required' >&2; exit 1; }
PNG_PREFIX=$($BREW --prefix libpng)

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM
mkdir -p "$TMPDIR_ROOT/artifacts" "$TMPDIR_ROOT/turbo" "$TMPDIR_ROOT/decoded"

swift build -c release --product ImageCraftEvidence >/dev/null
BIN_DIR=$(swift build -c release --show-bin-path)
EVIDENCE_BIN="$BIN_DIR/ImageCraftEvidence"
"$EVIDENCE_BIN" --artifacts "$TMPDIR_ROOT/artifacts" > "$TMPDIR_ROOT/evidence.json"

${CC:-cc} -std=c11 -O2 -Wall -Wextra -Werror \
    -I"$PNG_PREFIX/include" \
    Tools/Oracle/png_decode.c \
    -L"$PNG_PREFIX/lib" -lpng16 -lz \
    -o "$TMPDIR_ROOT/png_decode"
"$TMPDIR_ROOT/png_decode" \
    "$TMPDIR_ROOT/artifacts/imageio.png" \
    "$TMPDIR_ROOT/decoded/libpng-imageio.png.ppm"
"$EVIDENCE_BIN" --decode \
    "$TMPDIR_ROOT/artifacts/imageio.png" \
    "$TMPDIR_ROOT/decoded/imageio-imageio.png.ppm"

for quality in 25 50 75 90; do
    quality_fraction=$(printf '0.%02d' "$quality")
    "$CJPEG" \
        -quality "$quality" \
        -sample 2x2,1x1,1x1 \
        -baseline \
        -outfile "$TMPDIR_ROOT/turbo/turbo-q$quality.jpg" \
        "$TMPDIR_ROOT/artifacts/source.ppm"

    "$DJPEG" -rgb \
        -outfile "$TMPDIR_ROOT/decoded/djpeg-imageio-q$quality.ppm" \
        "$TMPDIR_ROOT/artifacts/imageio-q$quality_fraction.jpg"
    "$EVIDENCE_BIN" --decode \
        "$TMPDIR_ROOT/artifacts/imageio-q$quality_fraction.jpg" \
        "$TMPDIR_ROOT/decoded/imageio-imageio-q$quality.ppm"

    "$DJPEG" -rgb \
        -outfile "$TMPDIR_ROOT/decoded/djpeg-turbo-q$quality.ppm" \
        "$TMPDIR_ROOT/turbo/turbo-q$quality.jpg"
    "$EVIDENCE_BIN" --decode \
        "$TMPDIR_ROOT/turbo/turbo-q$quality.jpg" \
        "$TMPDIR_ROOT/decoded/imageio-turbo-q$quality.ppm"
done

JPEG_VERSION=$($CJPEG -version 2>&1 | head -n 1)
PNG_VERSION=$($TMPDIR_ROOT/png_decode --version)
python3 Tools/Oracle/analyze_oracle.py \
    --root "$TMPDIR_ROOT" \
    --evidence "$TMPDIR_ROOT/evidence.json" \
    --jpeg-version "$JPEG_VERSION" \
    --png-version "$PNG_VERSION" \
    > "$TMPDIR_ROOT/report.json"

if [ "$#" -gt 0 ]; then
    cmp "$TMPDIR_ROOT/report.json" "$1"
fi
cat "$TMPDIR_ROOT/report.json"
