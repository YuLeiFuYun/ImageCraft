#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=${DEVELOPER_DIR:-$(scripts/select-xcode.sh)}
export DEVELOPER_DIR

PROJECT="$ROOT/DeviceQualification/HDRDeviceProbe/ImageCraftHDRDeviceProbe.xcodeproj"
SCHEME=ImageCraftHDRDeviceProbe
BUNDLE_ID=dev.imagecraft.qualification.hdrdevice
SDR_FIXTURE="$ROOT/Tests/ImageCraftImageIOTests/Resources/Corpus/FormatBreadthV1/heif-rgba.heic"
GAINMAP_FIXTURE="$ROOT/Tests/ImageCraftImageIOTests/Resources/Corpus/FormatBreadthV1/heif-iso-gainmap-sdr-hdr.heic"
RESULT_NAME=imagecraft-hdr-device-result.json
FAILURE_NAME=imagecraft-hdr-device-result.json.failure
OUTPUT_DIR="$ROOT/.artifacts/hdr-device"
MODE=physical
XCODEBUILD_JOBS=${IMAGECRAFT_XCODEBUILD_JOBS:-2}

usage() {
    cat <<'EOF'
Usage: scripts/verify-hdr-ios-device.sh [--compile-only]

Default mode requires exactly one connected physical iPhone and performs signed build,
install, launch, result copy, and host-side qualification validation. --compile-only
builds the checked-in project for generic iOS with code signing disabled; it does not
satisfy the physical-device qualification.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --compile-only)
            MODE=compile-only
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [ ! -f "$PROJECT/project.pbxproj" ]; then
    echo "Checked-in HDR device Xcode project is missing." >&2
    exit 1
fi
if [ ! -f "$SDR_FIXTURE" ] || [ ! -f "$GAINMAP_FIXTURE" ]; then
    echo "HDR qualification fixtures are missing." >&2
    exit 1
fi

python3 - "$SDR_FIXTURE" "$GAINMAP_FIXTURE" <<'PY'
import hashlib
import pathlib
import sys

expected = {
    pathlib.Path(sys.argv[1]): (1221, "ddb7d01c6d793c20570e797308594d9115a14ba5e143790d5886ea810cad0dae"),
    pathlib.Path(sys.argv[2]): (1488, "e5d0836dca09abea8d3ec041be00fa6561fbb811f6fc90b0220d9967c3673eed"),
}
for path, (size, digest) in expected.items():
    data = path.read_bytes()
    if len(data) != size:
        raise SystemExit(f"fixture byte-count drift: {path.name}: {len(data)} != {size}")
    actual = hashlib.sha256(data).hexdigest()
    if actual != digest:
        raise SystemExit(f"fixture SHA-256 drift: {path.name}: {actual} != {digest}")
PY

source_identity() {
    python3 - "$ROOT" <<'PY'
import hashlib
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])

def git(*args):
    return subprocess.run(
        ["git", *args], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True
    ).stdout

head = git("rev-parse", "HEAD").strip()
tracked = [value.decode() for value in git("ls-files", "-z").split(b"\0") if value]
others = [
    value.decode()
    for value in git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0")
    if value
]
digest = hashlib.sha256()
digest.update(head)
digest.update(b"\0")
for relative in sorted(set(tracked + others)):
    path = root / relative
    digest.update(relative.encode())
    digest.update(b"\0")
    if path.is_symlink():
        digest.update(b"L\0")
        digest.update(os.readlink(path).encode())
    elif path.is_file():
        digest.update(b"F\0")
        digest.update(str(path.stat().st_mode & 0o111).encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
    else:
        digest.update(b"MISSING\0")
    digest.update(b"\0")
print(digest.hexdigest())
PY
}

SOURCE_BEFORE=$(source_identity)
TMPDIR_ROOT=$(mktemp -d /private/tmp/imagecraft-hdr-device.XXXXXX)
cleanup() {
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT HUP INT TERM
DERIVED_DATA="$TMPDIR_ROOT/DerivedData"
BUILD_LOG="$TMPDIR_ROOT/build.log"
DEVICE_INVENTORY_JSON=
DEVICE_SELECTION_JSON=
mkdir -p "$DERIVED_DATA" "$OUTPUT_DIR"

sanitize_file() {
    file=$1
    if [ ! -f "$file" ]; then
        return 0
    fi
    printf '%s\n' "$DEVICE_SELECTION_JSON" | python3 /dev/fd/3 "$file" 3<<'PY'
import json
import pathlib
import sys

selection = json.load(sys.stdin)
text = pathlib.Path(sys.argv[1]).read_text(errors="replace")
for value in selection.get("privateValues", []):
    if isinstance(value, str) and value:
        text = text.replace(value, "<redacted-device-value>")
print(text[-20000:])
PY
}

run_private_logged() {
    log=$1
    shift
    output_fifo="$TMPDIR_ROOT/private-command-output.fifo"
    rm -f "$output_fifo"
    mkfifo "$output_fifo"
    (
        printf '%s\n' "$DEVICE_SELECTION_JSON" | python3 /dev/fd/3 "$output_fifo" "$log" 3<<'PY'
import json
import pathlib
import sys

selection = json.load(sys.stdin)
private_values = sorted(
    {value for value in selection.get("privateValues", []) if isinstance(value, str) and value},
    key=len,
    reverse=True,
)
source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
with source.open("r", encoding="utf-8", errors="replace") as input_stream, target.open(
    "w", encoding="utf-8"
) as output_stream:
    for line in input_stream:
        for value in private_values:
            line = line.replace(value, "<redacted-device-value>")
        output_stream.write(line)
PY
    ) &
    redactor_pid=$!
    set +e
    "$@" >"$output_fifo" 2>&1
    command_rc=$?
    wait "$redactor_pid"
    redactor_rc=$?
    set -e
    rm -f "$output_fifo"
    if [ "$redactor_rc" -ne 0 ]; then
        echo "Private-device log redaction failed." >&2
        return 70
    fi
    return "$command_rc"
}

build_generic() {
    if ! xcodebuild \
        -jobs "$XCODEBUILD_JOBS" \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO \
        build >"$BUILD_LOG" 2>&1; then
        tail -n 200 "$BUILD_LOG" >&2
        return 1
    fi
    if ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$BUILD_LOG"; then
        tail -n 200 "$BUILD_LOG" >&2
        echo "Generic iOS build did not report success." >&2
        return 1
    fi
}

if [ "$MODE" = compile-only ]; then
    build_generic
    SOURCE_AFTER=$(source_identity)
    if [ "$SOURCE_BEFORE" != "$SOURCE_AFTER" ]; then
        echo "Source identity changed during compile-only qualification." >&2
        exit 1
    fi
    echo "ImageCraft HDR device probe compile-only gate passed; physical qualification remains unsatisfied."
    exit 0
fi

set +e
DEVICE_INVENTORY_JSON=$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null)
DEVICE_ENUM_RC=$?
set -e
if [ "$DEVICE_ENUM_RC" -ne 0 ]; then
    echo "Could not enumerate CoreDevice devices." >&2
    exit 3
fi

set +e
DEVICE_SELECTION_JSON=$(
    printf '%s' "$DEVICE_INVENTORY_JSON" | python3 /dev/fd/3 3<<'PY'
import json
import sys

data = json.load(sys.stdin)
candidates = []
for device in data.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    properties = device.get("deviceProperties", {})
    connection = device.get("connectionProperties", {})
    if hardware.get("reality") != "physical":
        continue
    product_type = str(hardware.get("productType") or "")
    if not product_type.startswith("iPhone"):
        continue
    connected = (
        properties.get("bootState") in {"booted", "connected"}
        or connection.get("tunnelState") in {"connected", "active"}
        or properties.get("ddiServicesAvailable") is True
    )
    if connected:
        candidates.append(device)
if len(candidates) == 0:
    raise SystemExit(3)
if len(candidates) != 1:
    raise SystemExit(4)
device = candidates[0]
identifier = device.get("identifier")
if not isinstance(identifier, str) or not identifier:
    raise SystemExit(5)
private = [identifier]
for value in [
    device.get("deviceProperties", {}).get("name"),
    device.get("hardwareProperties", {}).get("udid"),
    device.get("hardwareProperties", {}).get("serialNumber"),
    str(device.get("hardwareProperties", {}).get("ecid") or ""),
]:
    if isinstance(value, str) and value:
        private.append(value)
print(json.dumps({"identifier": identifier, "privateValues": private}, separators=(",", ":")))
PY
)
DEVICE_RC=$?
set -e
unset DEVICE_INVENTORY_JSON
case "$DEVICE_RC" in
    0) ;;
    3)
        echo "PHYSICAL_DEVICE_UNAVAILABLE: no connected physical iPhone; qualification not satisfied." >&2
        exit 3
        ;;
    4)
        echo "PHYSICAL_DEVICE_AMBIGUOUS: expected exactly one connected physical iPhone." >&2
        exit 4
        ;;
    *)
        echo "PHYSICAL_DEVICE_SELECTION_FAILED" >&2
        exit "$DEVICE_RC"
        ;;
esac

DEVICE_ID=$(printf '%s\n' "$DEVICE_SELECTION_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["identifier"])')

report_signing_credential_failure_if_present() {
    log=$1
    if grep -Eq \
        'No Account for Team|No profiles for .* were found|requires a provisioning profile' \
        "$log"; then
        echo "SIGNING_CREDENTIALS_UNAVAILABLE: Xcode account/provisioning credentials are unavailable; physical qualification not satisfied." >&2
    fi
}

if [ -n "${IMAGECRAFT_IOS_DEVELOPMENT_TEAM:-}" ]; then
    BUILD_TEAM_ARGUMENT="DEVELOPMENT_TEAM=$IMAGECRAFT_IOS_DEVELOPMENT_TEAM"
    if ! run_private_logged "$BUILD_LOG" xcodebuild \
        -jobs "$XCODEBUILD_JOBS" \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination "platform=iOS,id=$DEVICE_ID" \
        -derivedDataPath "$DERIVED_DATA" \
        -allowProvisioningUpdates \
        "$BUILD_TEAM_ARGUMENT" \
        build; then
        report_signing_credential_failure_if_present "$BUILD_LOG"
        tail -n 200 "$BUILD_LOG" >&2
        exit 5
    fi
else
    if ! run_private_logged "$BUILD_LOG" xcodebuild \
        -jobs "$XCODEBUILD_JOBS" \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination "platform=iOS,id=$DEVICE_ID" \
        -derivedDataPath "$DERIVED_DATA" \
        -allowProvisioningUpdates \
        build; then
        report_signing_credential_failure_if_present "$BUILD_LOG"
        tail -n 200 "$BUILD_LOG" >&2
        exit 5
    fi
fi
if ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$BUILD_LOG"; then
    sanitize_file "$BUILD_LOG" >&2
    echo "Signed device build did not report success." >&2
    exit 5
fi

APP="$DERIVED_DATA/Build/Products/Release-iphoneos/ImageCraftHDRDeviceProbe.app"
if [ ! -d "$APP" ]; then
    echo "Signed device app was not produced." >&2
    exit 5
fi

xcrun devicectl device uninstall app --device "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
INSTALL_LOG="$TMPDIR_ROOT/install.log"
if ! run_private_logged "$INSTALL_LOG" xcrun devicectl device install app --device "$DEVICE_ID" "$APP"; then
    tail -n 200 "$INSTALL_LOG" >&2
    exit 6
fi

copy_from_device() {
    remote=$1
    destination=$2
    xcrun devicectl device copy from \
        --device "$DEVICE_ID" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source "Documents/$remote" \
        --destination "$destination" >/dev/null 2>&1
}

LAUNCH_LOG="$TMPDIR_ROOT/launch.log"
if ! run_private_logged "$LAUNCH_LOG" xcrun devicectl device process launch \
    --device "$DEVICE_ID" \
    --console \
    --terminate-existing \
    "$BUNDLE_ID"; then
    FAILURE_COPY="$TMPDIR_ROOT/$FAILURE_NAME"
    if copy_from_device "$FAILURE_NAME" "$FAILURE_COPY"; then
        if [ -d "$FAILURE_COPY" ]; then
            FOUND=$(find "$FAILURE_COPY" -type f -name "$FAILURE_NAME" -print | head -n 1)
            if [ -n "$FOUND" ]; then
                FAILURE_COPY=$FOUND
            fi
        fi
        sanitize_file "$FAILURE_COPY" >&2
    else
        sanitize_file "$LAUNCH_LOG" >&2
    fi
    exit 7
fi

RESULT_COPY="$TMPDIR_ROOT/$RESULT_NAME"
if ! copy_from_device "$RESULT_NAME" "$RESULT_COPY"; then
    sanitize_file "$LAUNCH_LOG" >&2
    echo "Device result could not be copied." >&2
    exit 8
fi
if [ -d "$RESULT_COPY" ]; then
    FOUND=$(find "$RESULT_COPY" -type f -name "$RESULT_NAME" -print | head -n 1)
    if [ -z "$FOUND" ]; then
        echo "Copied app container did not contain the result file." >&2
        exit 8
    fi
    RESULT_COPY=$FOUND
fi

printf '%s\n' "$DEVICE_SELECTION_JSON" | python3 /dev/fd/3 "$RESULT_COPY" "$OUTPUT_DIR/$RESULT_NAME" 3<<'PY'
import json
import pathlib
import re
import shutil
import sys

source = pathlib.Path(sys.argv[1])
selection = json.load(sys.stdin)
raw = source.read_text()
for private in selection.get("privateValues", []):
    if private and private in raw:
        raise SystemExit("device result contains a private device identifier")
data = json.loads(raw)
if data.get("schemaVersion") != 1 or data.get("status") != "pass":
    raise SystemExit("device qualification result status/schema mismatch")
if data.get("hardwareReality") != "physical" or data.get("platform") != "iOS":
    raise SystemExit("device qualification result is not physical iOS")
if data.get("codecImplementationVersion") != 12 or data.get("highHEIFAdvertised") is not True:
    raise SystemExit("ImageIO codec identity/capability mismatch")
expected = {
    "sdrFixture": (1221, "ddb7d01c6d793c20570e797308594d9115a14ba5e143790d5886ea810cad0dae"),
    "gainMapFixture": (1488, "e5d0836dca09abea8d3ec041be00fa6561fbb811f6fc90b0220d9967c3673eed"),
}
for key, (size, digest) in expected.items():
    value = data.get(key, {})
    if value.get("bytes") != size or value.get("sha256") != digest:
        raise SystemExit(f"fixture identity mismatch: {key}")
direct_fixture = data.get("directHDRFixture", {})
if not isinstance(direct_fixture.get("bytes"), int) or direct_fixture["bytes"] <= 0:
    raise SystemExit("direct HDR fixture byte count invalid")
if not re.fullmatch(r"[0-9a-f]{64}", str(direct_fixture.get("sha256") or "")):
    raise SystemExit("direct HDR fixture SHA-256 invalid")

def require_hdr(value, width, height, label):
    if value.get("width") != width or value.get("height") != height:
        raise SystemExit(f"{label} geometry mismatch")
    if int(value.get("bitsPerComponent", 0)) <= 8:
        raise SystemExit(f"{label} precision collapsed")
    if value.get("isHDRColorSpace") is not True and value.get("usesExtendedRange") is not True:
        raise SystemExit(f"{label} color-space semantic missing")
    if float(value.get("contentHeadroom", 0.0)) <= 1.0:
        raise SystemExit(f"{label} headroom collapsed")

require_hdr(data.get("directHDR", {}), 2, 1, "directHDR")
require_hdr(data.get("directHDRTinyFit", {}), 1, 1, "directHDRTinyFit")
require_hdr(data.get("directHDRTinyFill", {}), 1, 1, "directHDRTinyFill")
gain = data.get("gainMap", {})
if gain.get("defaultAuxiliaryAdmission") != "auxiliaryAttachmentLimitExceeded":
    raise SystemExit("default auxiliary admission did not fail closed")
probe = gain.get("probe", {})
if probe.get("auxiliaryAttachmentCount") != 1 or probe.get("sourceBitsPerComponent") != 8:
    raise SystemExit("gain-map probe contract mismatch")
standard = gain.get("standard", {})
if standard.get("width") != 8 or standard.get("height") != 4:
    raise SystemExit("gain-map standard geometry mismatch")
if standard.get("bitsPerComponent") != 8:
    raise SystemExit("gain-map standard precision mismatch")
if standard.get("isHDRColorSpace") is True or standard.get("usesExtendedRange") is True:
    raise SystemExit("gain-map standard escaped SDR color space")
if float(standard.get("contentHeadroom", 99.0)) > 1.000001:
    raise SystemExit("gain-map standard escaped SDR headroom")
for key, width, height in (("high", 8, 4), ("tinyHigh", 1, 1)):
    outcome = gain.get(key, {})
    classification = outcome.get("classification")
    if classification == "hdr-success":
        require_hdr(outcome.get("raster") or {}, width, height, f"gainMap.{key}")
        if outcome.get("contractError") is not None:
            raise SystemExit(f"gainMap.{key} success unexpectedly has an error")
    elif classification == "fail-closed":
        if outcome.get("raster") is not None:
            raise SystemExit(f"gainMap.{key} fail-closed unexpectedly has pixels")
        if outcome.get("contractError") != "unsupportedCapability.dynamicRange.high":
            raise SystemExit(f"gainMap.{key} fail-closed classification mismatch")
    else:
        raise SystemExit(f"gainMap.{key} invalid classification: {classification}")

target = pathlib.Path(sys.argv[2])
target.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(source, target)
print(
    "validated physical result: "
    f"gainMapHigh={gain['high']['classification']} "
    f"tinyHigh={gain['tinyHigh']['classification']}"
)
PY

SOURCE_AFTER=$(source_identity)
if [ "$SOURCE_BEFORE" != "$SOURCE_AFTER" ]; then
    echo "Source identity changed during physical qualification." >&2
    exit 9
fi

echo "ImageCraft HDR physical-device qualification passed."
