#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import os
from fractions import Fraction
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PROFILE = ROOT / "Evidence/Experiments/IndependentPNG16/v1/profile.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/quality/independent-png16-v1/formal-report.json"
EVIDENCE_VERSION = "imagecraft-independent-png16-conformance-v1"


class CaptureError(RuntimeError):
    pass


def run(
    argv: list[str],
    *,
    env: dict[str, str] | None = None,
    cwd: Path = ROOT,
    timeout: int = 900,
    allow_failure: bool = False,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        argv,
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0 and not allow_failure:
        raise CaptureError(
            f"command failed ({completed.returncode}): {' '.join(argv)}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return completed


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def capture_source_identity(path: Path) -> dict[str, Any]:
    run(
        [
            sys.executable,
            str(ROOT / "Tools/Identity/capture_source_identity.py"),
            "--output",
            str(path),
        ]
    )
    return json.loads(path.read_text())


def parse_json_stdout(completed: subprocess.CompletedProcess[str], label: str) -> dict[str, Any]:
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise CaptureError(f"invalid JSON from {label}: {completed.stdout!r}") from error


def canonical_le_from_rgba16be(source: bytes) -> bytes:
    if len(source) % 8:
        raise CaptureError("RGBA16 oracle byte count is not pixel-aligned")
    output = bytearray(len(source))
    for offset in range(0, len(source), 2):
        output[offset] = source[offset + 1]
        output[offset + 1] = source[offset]
    return bytes(output)


# W3C CSS Color 4 publishes these as separate exact-rational Display-P3->XYZ and
# XYZ->linear-sRGB matrices. Keeping the two multiplications separate makes this oracle
# structurally independent from ImageCraft's algebraically combined difference-form matrix.
_DISPLAY_P3_TO_XYZ = (
    (Fraction(608_311, 1_250_200), Fraction(189_793, 714_400), Fraction(198_249, 1_000_160)),
    (Fraction(35_783, 156_275), Fraction(247_089, 357_200), Fraction(198_249, 2_500_400)),
    (Fraction(0), Fraction(32_229, 714_400), Fraction(5_220_557, 5_000_800)),
)
_XYZ_TO_LINEAR_SRGB = (
    (Fraction(12_831, 3_959), Fraction(-329, 214), Fraction(-1_974, 3_959)),
    (Fraction(-851_781, 878_810), Fraction(1_648_619, 878_810), Fraction(36_519, 878_810)),
    (Fraction(705, 12_673), Fraction(-2_585, 12_673), Fraction(705, 667)),
)


def _matvec3(matrix: tuple[tuple[Fraction, Fraction, Fraction], ...], values: tuple[float, float, float]) -> tuple[float, float, float]:
    return tuple(
        sum(float(coefficient) * value for coefficient, value in zip(row, values, strict=True))
        for row in matrix
    )  # type: ignore[return-value]


def _srgb_decode_u16(sample: int) -> float:
    encoded = sample / 65_535.0
    if encoded <= 0.04045:
        return encoded / 12.92
    return ((encoded + 0.055) / 1.055) ** 2.4


def _srgb_encode_u16(linear: float) -> int:
    if not math.isfinite(linear) or linear < 0.0 or linear > 1.0:
        raise CaptureError("Display-P3 conversion oracle left the qualified sRGB gamut")
    if linear <= 0.0031308:
        encoded = 12.92 * linear
    else:
        encoded = 1.055 * (linear ** (1.0 / 2.4)) - 0.055
    quantized = math.floor(encoded * 65_535.0 + 0.5)
    if not 0 <= quantized <= 0xFFFF:
        raise CaptureError("Display-P3 conversion oracle quantization overflow")
    return quantized


def display_p3_rgba16be_to_srgb_rgba16be(source: bytes) -> bytes:
    if len(source) % 8:
        raise CaptureError("Display-P3 RGBA16 oracle byte count is not pixel-aligned")
    output = bytearray(len(source))
    for offset in range(0, len(source), 8):
        encoded = tuple(
            int.from_bytes(source[offset + channel : offset + channel + 2], "big")
            for channel in (0, 2, 4)
        )
        linear_p3 = tuple(_srgb_decode_u16(sample) for sample in encoded)
        xyz = _matvec3(_DISPLAY_P3_TO_XYZ, linear_p3)  # type: ignore[arg-type]
        linear_srgb = _matvec3(_XYZ_TO_LINEAR_SRGB, xyz)
        converted = tuple(_srgb_encode_u16(component) for component in linear_srgb)
        for channel, sample in enumerate(converted):
            target = offset + channel * 2
            output[target : target + 2] = sample.to_bytes(2, "big")
        output[offset + 6 : offset + 8] = source[offset + 6 : offset + 8]
    return bytes(output)


_ICC_SRGB_D50_RGB_TO_XYZ = (
    (0.436030342570117, 0.385101860087134, 0.143067806654203),
    (0.222438466210245, 0.716942745571917, 0.060618777416563),
    (0.013897440074263, 0.097076381494207, 0.713926257896652),
)
_ICC_MATRIX_FIXED_BOUNDARY_TOLERANCE = 8.0 / 65_536.0


def _invert3x3(matrix: tuple[tuple[float, float, float], ...]) -> tuple[tuple[float, float, float], ...]:
    a, b, c = matrix
    determinant = (
        a[0] * (b[1] * c[2] - b[2] * c[1])
        - a[1] * (b[0] * c[2] - b[2] * c[0])
        + a[2] * (b[0] * c[1] - b[1] * c[0])
    )
    if not math.isfinite(determinant) or abs(determinant) < 1e-15:
        raise CaptureError("ICC matrix is singular")
    return (
        ((b[1] * c[2] - b[2] * c[1]) / determinant, (a[2] * c[1] - a[1] * c[2]) / determinant, (a[1] * b[2] - a[2] * b[1]) / determinant),
        ((b[2] * c[0] - b[0] * c[2]) / determinant, (a[0] * c[2] - a[2] * c[0]) / determinant, (a[2] * b[0] - a[0] * b[2]) / determinant),
        ((b[0] * c[1] - b[1] * c[0]) / determinant, (a[1] * c[0] - a[0] * c[1]) / determinant, (a[0] * b[1] - a[1] * b[0]) / determinant),
    )


def _float_matvec3(matrix: tuple[tuple[float, float, float], ...], values: tuple[float, float, float]) -> tuple[float, float, float]:
    return tuple(sum(row[index] * values[index] for index in range(3)) for row in matrix)  # type: ignore[return-value]


def _normalize_icc_fixed_curve(
    fixed_entry: tuple[str, int | None, tuple[int, ...]],
) -> tuple[str, int | None, tuple[float, ...]]:
    curve_kind, function_type, fixed_curve = fixed_entry
    if curve_kind == "curveIdentity":
        return curve_kind, None, ()
    if curve_kind == "curveGamma":
        (gamma_raw,) = fixed_curve
        return curve_kind, None, (gamma_raw / 256.0,)
    if curve_kind == "curveSampled":
        return curve_kind, None, tuple(value / 65_535.0 for value in fixed_curve)

    curve = tuple(value / 65_536.0 for value in fixed_curve)
    tolerance = _ICC_MATRIX_FIXED_BOUNDARY_TOLERANCE
    qualified = False
    if function_type == 0:
        (gamma,) = curve
        qualified = math.isfinite(gamma) and gamma > 0
    elif function_type == 1:
        gamma, a, b = curve
        threshold = -b / a if a != 0 else math.nan
        end = (a + b) ** gamma if gamma > 0 and a + b >= 0 else math.nan
        qualified = gamma > 0 and a > 0 and 0 <= threshold <= 1 and math.isfinite(end) and abs(end - 1) <= tolerance
    elif function_type == 2:
        gamma, a, b, c = curve
        threshold = -b / a if a != 0 else math.nan
        end = (a + b) ** gamma + c if gamma > 0 and a + b >= 0 else math.nan
        qualified = gamma > 0 and a > 0 and 0 <= c <= 1 and 0 <= threshold <= 1 and math.isfinite(end) and abs(end - 1) <= tolerance
    elif function_type == 3:
        gamma, a, b, c, d = curve
        base_boundary = a * d + b
        base_one = a + b
        if gamma > 0 and a > 0 and c >= 0 and 0 <= d <= 1 and base_boundary >= 0 and base_one >= 0:
            lower_boundary = c * d
            upper_boundary = base_boundary ** gamma
            start = b ** gamma if d == 0 else 0.0
            end = base_one ** gamma
            qualified = all(math.isfinite(value) for value in (lower_boundary, upper_boundary, start, end)) and abs(lower_boundary - upper_boundary) <= tolerance and abs(start) <= tolerance and abs(end - 1) <= tolerance
    elif function_type == 4:
        gamma, a, b, c, d, e, f = curve
        base_boundary = a * d + b
        base_one = a + b
        if gamma > 0 and a > 0 and c >= 0 and 0 <= d <= 1 and base_boundary >= 0 and base_one >= 0:
            lower_boundary = c * d + f
            upper_boundary = base_boundary ** gamma + e
            start = b ** gamma + e if d == 0 else f
            end = base_one ** gamma + e
            qualified = all(math.isfinite(value) for value in (lower_boundary, upper_boundary, start, end)) and abs(lower_boundary - upper_boundary) <= tolerance and abs(start) <= tolerance and abs(end - 1) <= tolerance
    if not qualified:
        raise CaptureError("ICC parametric TRC escaped the normalized monotone matrix/TRC slice")
    return curve_kind, function_type, curve


def _icc_matrix_trcs(
    profile: bytes,
) -> tuple[
    tuple[tuple[float, float, float], ...],
    tuple[
        tuple[str, int | None, tuple[float, ...]],
        tuple[str, int | None, tuple[float, ...]],
        tuple[str, int | None, tuple[float, ...]],
    ],
]:
    if (
        len(profile) < 132
        or profile[12:16] not in (b"mntr", b"scnr")
        or profile[16:20] != b"RGB "
        or profile[20:24] != b"XYZ "
        or profile[36:40] != b"acsp"
    ):
        raise CaptureError("ICC conversion profile escaped qualified forward-device matrix/TRC slice")
    tag_count = int.from_bytes(profile[128:132], "big")
    if tag_count < 6 or 132 + tag_count * 12 > len(profile):
        raise CaptureError("ICC tag table is invalid")
    tags: dict[bytes, bytes] = {}
    for index in range(tag_count):
        entry = 132 + index * 12
        signature = profile[entry : entry + 4]
        offset = int.from_bytes(profile[entry + 4 : entry + 8], "big")
        size = int.from_bytes(profile[entry + 8 : entry + 12], "big")
        if signature in tags or size <= 0 or offset % 4 or offset + size > len(profile):
            raise CaptureError("ICC tag entry is invalid or ambiguous")
        if signature[:3] in (b"A2B", b"B2A", b"D2B", b"B2D"):
            raise CaptureError("ICC LUT/MPE transform is outside matrix/TRC slice")
        tags[signature] = profile[offset : offset + size]

    fixed_xyz: list[tuple[int, int, int]] = []
    for signature in (b"rXYZ", b"gXYZ", b"bXYZ"):
        payload = tags.get(signature)
        if payload is None or len(payload) != 20 or payload[:4] != b"XYZ " or payload[4:8] != bytes(4):
            raise CaptureError("ICC XYZ colorant tag is invalid")
        fixed_xyz.append(tuple(int.from_bytes(payload[offset : offset + 4], "big", signed=True) for offset in (8, 12, 16)))  # type: ignore[arg-type]
    source_matrix = tuple(
        tuple(fixed_xyz[column][row] / 65_536.0 for column in range(3))
        for row in range(3)
    )

    fixed_curves: list[tuple[str, int | None, tuple[int, ...]]] = []
    for signature in (b"rTRC", b"gTRC", b"bTRC"):
        payload = tags.get(signature)
        if payload is None or len(payload) < 12 or payload[4:8] != bytes(4):
            raise CaptureError("ICC TRC is invalid")
        if payload[:4] == b"curv":
            count = int.from_bytes(payload[8:12], "big")
            expected_size = 12 + 2 * count
            if len(payload) != expected_size:
                raise CaptureError("ICC curveType payload size does not match its entry count")
            if count == 0:
                fixed_curves.append(("curveIdentity", None, ()))
                continue
            values = tuple(
                int.from_bytes(payload[offset : offset + 2], "big")
                for offset in range(12, expected_size, 2)
            )
            if count == 1:
                gamma_raw = values[0]
                if gamma_raw <= 0:
                    raise CaptureError("ICC curveType gamma is not positive")
                fixed_curves.append(("curveGamma", None, (gamma_raw,)))
                continue
            if values[0] != 0 or values[-1] != 0xFFFF:
                raise CaptureError("ICC sampled curveType is not normalized to [0,1]")
            if any(current < previous for previous, current in zip(values, values[1:])):
                raise CaptureError("ICC sampled curveType is not weakly nondecreasing")
            fixed_curves.append(("curveSampled", None, values))
            continue
        if payload[:4] != b"para" or payload[10:12] != bytes(2):
            raise CaptureError("ICC TRC type is outside the qualified matrix/TRC slice")
        function_type = int.from_bytes(payload[8:10], "big")
        parameter_counts = {0: 1, 1: 3, 2: 4, 3: 5, 4: 7}
        parameter_count = parameter_counts.get(function_type)
        if parameter_count is None or len(payload) != 12 + 4 * parameter_count:
            raise CaptureError("ICC parametric TRC function or size is outside the qualified slice")
        fixed = tuple(
            int.from_bytes(payload[offset : offset + 4], "big", signed=True)
            for offset in range(12, 12 + 4 * parameter_count, 4)
        )
        fixed_curves.append(("parametric", function_type, fixed))
    normalized_curves = tuple(_normalize_icc_fixed_curve(entry) for entry in fixed_curves)
    if len(normalized_curves) != 3:
        raise CaptureError("ICC conversion did not produce three channel TRCs")
    return source_matrix, normalized_curves  # type: ignore[return-value]


def _icc_matrix_trc(
    profile: bytes,
) -> tuple[
    tuple[tuple[float, float, float], ...],
    tuple[str, int | None, tuple[float, ...]],
]:
    source_matrix, curves = _icc_matrix_trcs(profile)
    if curves[1:] != curves[:1] * 2:
        raise CaptureError("ICC caller requires one shared RGB TRC")
    return source_matrix, curves[0]


def icc_matrix_trc_rgba16be_to_srgb_rgba16be(
    profile: bytes,
    source: bytes,
    *,
    target_rgb_to_d50_xyz: tuple[tuple[float, float, float], ...] = _ICC_SRGB_D50_RGB_TO_XYZ,
) -> bytes:
    if len(source) % 8:
        raise CaptureError("ICC RGBA16 oracle byte count is not pixel-aligned")
    source_matrix, curves = _icc_matrix_trcs(profile)
    target_inverse = _invert3x3(target_rgb_to_d50_xyz)

    def decode(
        sample: int,
        curve: tuple[str, int | None, tuple[float, ...]],
    ) -> float:
        curve_kind, function_type, parameters = curve
        encoded = sample / 65_535.0
        if curve_kind == "curveIdentity":
            decoded = encoded
        elif curve_kind == "curveGamma":
            (gamma,) = parameters
            decoded = encoded ** gamma
        elif curve_kind == "curveSampled":
            position = encoded * (len(parameters) - 1)
            lower_index = min(len(parameters) - 2, math.floor(position))
            fraction = position - lower_index
            decoded = parameters[lower_index] + (
                parameters[lower_index + 1] - parameters[lower_index]
            ) * fraction
        elif function_type == 0:
            (gamma,) = parameters
            decoded = encoded ** gamma
        elif function_type == 1:
            gamma, a, b = parameters
            threshold = -b / a
            decoded = (a * encoded + b) ** gamma if encoded >= threshold else 0.0
        elif function_type == 2:
            gamma, a, b, c = parameters
            threshold = -b / a
            decoded = (a * encoded + b) ** gamma + c if encoded >= threshold else c
        elif function_type == 3:
            gamma, a, b, c, d = parameters
            decoded = (a * encoded + b) ** gamma if encoded >= d else c * encoded
        elif function_type == 4:
            gamma, a, b, c, d, e, f = parameters
            decoded = (a * encoded + b) ** gamma + e if encoded >= d else c * encoded + f
        else:
            raise CaptureError("ICC conversion oracle reached an unqualified parametric function")
        if not math.isfinite(decoded) or decoded < -_ICC_MATRIX_FIXED_BOUNDARY_TOLERANCE or decoded > 1.0 + _ICC_MATRIX_FIXED_BOUNDARY_TOLERANCE:
            raise CaptureError("ICC source TRC requires clipping outside the qualified no-clipping slice")
        return min(1.0, max(0.0, decoded))

    def encode(linear: float) -> int:
        if not math.isfinite(linear) or linear < -_ICC_MATRIX_FIXED_BOUNDARY_TOLERANCE or linear > 1.0 + _ICC_MATRIX_FIXED_BOUNDARY_TOLERANCE:
            raise CaptureError("ICC conversion oracle left qualified sRGB gamut")
        bounded = min(1.0, max(0.0, linear))
        encoded = 12.92 * bounded if bounded <= 0.0031308 else 1.055 * (bounded ** (1.0 / 2.4)) - 0.055
        return math.floor(encoded * 65_535.0 + 0.5)

    output = bytearray(len(source))
    for offset in range(0, len(source), 8):
        encoded_source = tuple(int.from_bytes(source[offset + channel : offset + channel + 2], "big") for channel in (0, 2, 4))
        linear_source = tuple(
            decode(sample, curve)
            for sample, curve in zip(encoded_source, curves)
        )
        xyz = _float_matvec3(source_matrix, linear_source)  # type: ignore[arg-type]
        target = _float_matvec3(target_inverse, xyz)
        converted = tuple(encode(component) for component in target)
        for channel, sample in enumerate(converted):
            target_offset = offset + channel * 2
            output[target_offset : target_offset + 2] = sample.to_bytes(2, "big")
        output[offset + 6 : offset + 8] = source[offset + 6 : offset + 8]
    return bytes(output)


def rgba16be_max_rgb_code_difference(lhs: bytes, rhs: bytes) -> int:
    if len(lhs) != len(rhs) or len(lhs) % 8:
        raise CaptureError("RGBA16 differential inputs are not aligned")
    maximum = 0
    for offset in range(0, len(lhs), 8):
        for channel in (0, 2, 4):
            left = int.from_bytes(lhs[offset + channel : offset + channel + 2], "big")
            right = int.from_bytes(rhs[offset + channel : offset + channel + 2], "big")
            maximum = max(maximum, abs(left - right))
        if lhs[offset + 6 : offset + 8] != rhs[offset + 6 : offset + 8]:
            raise CaptureError("LittleCMS changed alpha")
    return maximum


def recovered_reference_samples_u16be(
    source: bytes,
    source_bytes_per_pixel: int,
    significant_bits: list[int],
) -> bytes:
    channel_count = source_bytes_per_pixel // 2
    if source_bytes_per_pixel not in (2, 4, 6, 8) or len(significant_bits) != channel_count:
        raise CaptureError("sBIT metadata does not match stored source layout")
    if len(source) % source_bytes_per_pixel:
        raise CaptureError("stored source is not pixel-aligned for sBIT recovery")
    output = bytearray()
    for pixel_offset in range(0, len(source), source_bytes_per_pixel):
        for channel in range(channel_count):
            significant = significant_bits[channel]
            if not 1 <= significant <= 16:
                raise CaptureError("sBIT value outside 1...16")
            sample_offset = pixel_offset + channel * 2
            stored = int.from_bytes(source[sample_offset : sample_offset + 2], "big")
            output += (stored >> (16 - significant)).to_bytes(2, "big")
    return bytes(output)


def expected_rgba16be_from_stored_source(case: dict[str, Any], source: bytes) -> bytes:
    width = int(case["width"])
    height = int(case["height"])
    source_format = case.get("sourceFormat", "rgba16")
    pixel_count = width * height
    if source_format == "rgba16":
        expected = pixel_count * 8
        if len(source) != expected:
            raise CaptureError(f"RGBA16 stored source byte count mismatch: {case['id']}")
        return source

    output = bytearray(pixel_count * 8)
    source_offset = 0
    output_offset = 0
    if source_format == "rgb16":
        expected = pixel_count * 6
        if len(source) != expected:
            raise CaptureError(f"RGB16 stored source byte count mismatch: {case['id']}")
        transparent_raw = case.get("transparentRGB16")
        transparent: tuple[int, int, int] | None
        if transparent_raw is None:
            transparent = None
        else:
            if (
                not isinstance(transparent_raw, list)
                or len(transparent_raw) != 3
                or any(not isinstance(value, int) or value < 0 or value > 0xFFFF for value in transparent_raw)
            ):
                raise CaptureError(f"invalid RGB16 transparency oracle: {case['id']}")
            transparent = (transparent_raw[0], transparent_raw[1], transparent_raw[2])
        while source_offset < len(source):
            red = int.from_bytes(source[source_offset : source_offset + 2], "big")
            green = int.from_bytes(source[source_offset + 2 : source_offset + 4], "big")
            blue = int.from_bytes(source[source_offset + 4 : source_offset + 6], "big")
            alpha = 0 if transparent == (red, green, blue) else 0xFFFF
            output[output_offset : output_offset + 8] = (
                red.to_bytes(2, "big")
                + green.to_bytes(2, "big")
                + blue.to_bytes(2, "big")
                + alpha.to_bytes(2, "big")
            )
            source_offset += 6
            output_offset += 8
        return bytes(output)

    if source_format == "grayscale16":
        expected = pixel_count * 2
        if len(source) != expected:
            raise CaptureError(f"grayscale16 stored source byte count mismatch: {case['id']}")
        transparent_raw = case.get("transparentGray16")
        if transparent_raw is not None and (
            not isinstance(transparent_raw, int) or transparent_raw < 0 or transparent_raw > 0xFFFF
        ):
            raise CaptureError(f"invalid grayscale16 transparency oracle: {case['id']}")
        while source_offset < len(source):
            gray = int.from_bytes(source[source_offset : source_offset + 2], "big")
            alpha = 0 if transparent_raw == gray else 0xFFFF
            gray_bytes = gray.to_bytes(2, "big")
            output[output_offset : output_offset + 8] = (
                gray_bytes + gray_bytes + gray_bytes + alpha.to_bytes(2, "big")
            )
            source_offset += 2
            output_offset += 8
        return bytes(output)

    if source_format == "grayscaleAlpha16":
        expected = pixel_count * 4
        if len(source) != expected:
            raise CaptureError(f"grayscale+alpha16 stored source byte count mismatch: {case['id']}")
        while source_offset < len(source):
            gray = int.from_bytes(source[source_offset : source_offset + 2], "big")
            alpha = int.from_bytes(source[source_offset + 2 : source_offset + 4], "big")
            gray_bytes = gray.to_bytes(2, "big")
            output[output_offset : output_offset + 8] = (
                gray_bytes + gray_bytes + gray_bytes + alpha.to_bytes(2, "big")
            )
            source_offset += 4
            output_offset += 8
        return bytes(output)

    raise CaptureError(f"unsupported PNG16 sourceFormat in manifest: {source_format!r}")


def swift_flags(developer_dir: str) -> tuple[str, list[str]]:
    env = dict(os.environ)
    env["DEVELOPER_DIR"] = developer_dir
    swiftc = str(Path(developer_dir) / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc")
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env).stdout.strip()
    architecture = platform.machine()
    target = f"{architecture}-apple-macos12.0"
    common = [
        "-O",
        "-sdk",
        sdk,
        "-target",
        target,
        "-package-name",
        "ImageCraft",
        "-enable-upcoming-feature",
        "InferIsolatedConformances",
        "-enable-upcoming-feature",
        "NonisolatedNonsendingByDefault",
    ]
    return swiftc, common


def build_swift_probe(build: Path, developer_dir: str) -> Path:
    env = dict(os.environ)
    env["DEVELOPER_DIR"] = developer_dir
    swiftc, common = swift_flags(developer_dir)
    core_sources = sorted(str(path) for path in (ROOT / "Sources/ImageCraftCore").glob("*.swift"))
    imageio_sources = sorted(str(path) for path in (ROOT / "Sources/ImageCraftImageIO").glob("*.swift"))
    core_module = build / "ImageCraftCore.swiftmodule"
    imageio_module = build / "ImageCraftImageIO.swiftmodule"
    core_library = build / "libImageCraftCore.dylib"
    imageio_library = build / "libImageCraftImageIO.dylib"
    run(
        [
            swiftc,
            *common,
            "-parse-as-library",
            "-module-name",
            "ImageCraftCore",
            "-emit-module",
            "-emit-module-path",
            str(core_module),
            "-emit-library",
            "-o",
            str(core_library),
            *core_sources,
        ],
        env=env,
    )
    run(
        [
            swiftc,
            *common,
            "-parse-as-library",
            "-module-name",
            "ImageCraftImageIO",
            "-I",
            str(build),
            "-L",
            str(build),
            "-lImageCraftCore",
            "-emit-module",
            "-emit-module-path",
            str(imageio_module),
            "-emit-library",
            "-o",
            str(imageio_library),
            *imageio_sources,
        ],
        env=env,
    )
    probe = build / "ImageCraftIndependentPNG16Probe"
    run(
        [
            swiftc,
            *common,
            "-I",
            str(build),
            "-L",
            str(build),
            "-lImageCraftCore",
            "-lImageCraftImageIO",
            "-Xlinker",
            "-rpath",
            "-Xlinker",
            str(build),
            str(ROOT / "Tools/Quality/IndependentPNG16Probe/main.swift"),
            "-o",
            str(probe),
        ],
        env=env,
    )
    return probe


def build_libpng_probe(build: Path) -> tuple[Path, str]:
    version = run(["libpng-config", "--version"]).stdout.strip()
    cflags = shlex.split(run(["libpng-config", "--cflags"]).stdout.strip())
    ldflags = shlex.split(run(["libpng-config", "--ldflags"]).stdout.strip())
    binary = build / "libpng-rgba16-probe"
    run(
        [
            "cc",
            "-O2",
            "-Wall",
            "-Wextra",
            *cflags,
            str(ROOT / "Tools/Quality/LibPNGRGBA16Probe/main.c"),
            *ldflags,
            "-o",
            str(binary),
        ]
    )
    return binary, version


def build_littlecms_probe(build: Path) -> tuple[Path, str]:
    brew = shutil.which("brew")
    if brew is not None:
        prefix = Path(run([brew, "--prefix", "little-cms2"]).stdout.strip())
    else:
        prefix = Path("/opt/homebrew")
    header = prefix / "include/lcms2.h"
    library_dir = prefix / "lib"
    if not header.is_file() or not library_dir.is_dir():
        raise CaptureError("LittleCMS development headers/library are required for ICC conversion evidence")
    binary = build / "lcms-rgba16-to-srgb-probe"
    run(
        [
            "cc",
            "-O2",
            "-Wall",
            "-Wextra",
            f"-I{prefix / 'include'}",
            str(ROOT / "Tools/Quality/LittleCMSRGBA16ToSRGBProbe/main.c"),
            f"-L{library_dir}",
            "-llcms2",
            f"-Wl,-rpath,{library_dir}",
            "-o",
            str(binary),
        ]
    )
    transicc = prefix / "bin/transicc"
    version = "unknown"
    if transicc.is_file():
        completed = run([str(transicc), "-v"], allow_failure=True)
        version = (completed.stdout + completed.stderr).strip().splitlines()[0] if (completed.stdout + completed.stderr).strip() else "unknown"
    return binary, version


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile.resolve()
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    try:
        profile_path.relative_to(ROOT)
    except ValueError as error:
        raise CaptureError("conformance profile must be inside the ImageCraft source tree") from error
    profile = json.loads(profile_path.read_text())
    if profile.get("schemaVersion") != 1:
        raise CaptureError("invalid PNG16 conformance profile schema")
    if not isinstance(profile.get("successCases"), list) or not profile["successCases"]:
        raise CaptureError("PNG16 profile must define success cases")
    if not isinstance(profile.get("hostileCases"), list) or not profile["hostileCases"]:
        raise CaptureError("PNG16 profile must define hostile cases")
    operation_budget = profile.get("operationBudgetBytes")
    if not isinstance(operation_budget, int) or operation_budget <= 0:
        raise CaptureError("PNG16 profile operationBudgetBytes must be positive")
    ids = [case.get("id") for case in profile["successCases"] + profile["hostileCases"]]
    if any(not isinstance(case_id, str) or not case_id for case_id in ids) or len(ids) != len(set(ids)):
        raise CaptureError("PNG16 case IDs must be non-empty and globally unique")

    with tempfile.TemporaryDirectory(prefix="imagecraft-independent-png16-") as temp_dir:
        temp = Path(temp_dir)
        build = temp / "build"
        corpus = temp / "corpus"
        outputs = temp / "outputs"
        build.mkdir()
        corpus.mkdir()
        outputs.mkdir()

        before = capture_source_identity(temp / "source-before.json")
        developer_dir = run([str(ROOT / "scripts/select-xcode.sh")]).stdout.strip()
        env = dict(os.environ)
        env["DEVELOPER_DIR"] = developer_dir
        run([sys.executable, str(ROOT / "scripts/check-swift-toolchain.py")], env=env)
        run(
            ["swift", "test", "--scratch-path", str(temp / "swiftpm"), "--jobs", "1"],
            env=env,
        )
        swift_probe = build_swift_probe(build, developer_dir)
        libpng_probe, libpng_version = build_libpng_probe(build)
        littlecms_probe, littlecms_version = build_littlecms_probe(build)
        run(
            [
                sys.executable,
                str(ROOT / "Tools/Quality/generate_independent_png16_corpus.py"),
                "--profile",
                str(profile_path),
                "--output-dir",
                str(corpus),
            ]
        )
        manifest_path = corpus / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        if manifest.get("profileID") != profile.get("profileID"):
            raise CaptureError("PNG16 generated corpus profile drifted")

        success_results: list[dict[str, Any]] = []
        for case in manifest["successCases"]:
            case_id = case["id"]
            width = int(case["width"])
            height = int(case["height"])
            png_path = corpus / case["pngFile"]
            source_path = corpus / case["sourceRawBEFile"]
            source = source_path.read_bytes()
            source_bpp = int(case["sourceBytesPerPixel"])
            expected_source_byte_count = width * height * source_bpp
            expected_byte_count = width * height * 8
            if len(source) != expected_source_byte_count:
                raise CaptureError(f"PNG16 stored source byte count mismatch: {case_id}")
            if sha256_bytes(source) != case["sourceRawBESHA256"]:
                raise CaptureError(f"PNG16 stored source oracle digest drifted: {case_id}")
            expected_rgba_be = expected_rgba16be_from_stored_source(case, source)
            if len(expected_rgba_be) != expected_byte_count:
                raise CaptureError(f"PNG16 expanded RGBA16 byte count mismatch: {case_id}")

            color_authority = case.get("colorAuthority", "sRGB")
            if color_authority not in ("sRGB", "rgbICC", "cICP"):
                raise CaptureError(f"unsupported PNG16 color authority: {case_id}")
            expected_icc = b""
            if color_authority == "rgbICC":
                icc_file = case.get("iccProfileFile")
                icc_sha = case.get("iccProfileSHA256")
                icc_count = case.get("iccProfileByteCount")
                if not isinstance(icc_file, str) or not isinstance(icc_sha, str) or not isinstance(icc_count, int):
                    raise CaptureError(f"missing generated ICC oracle: {case_id}")
                expected_icc = (corpus / icc_file).read_bytes()
                if len(expected_icc) != icc_count or sha256_bytes(expected_icc) != icc_sha:
                    raise CaptureError(f"generated ICC oracle drifted: {case_id}")
                expected_profile_class = case.get("iccProfileClass", "mntr")
                if expected_profile_class not in ("mntr", "scnr"):
                    raise CaptureError(f"unqualified ICC profile class in success corpus: {case_id}")
                if len(expected_icc) < 16 or expected_icc[12:16] != expected_profile_class.encode("ascii"):
                    raise CaptureError(f"generated ICC profile class drifted: {case_id}")
            elif (
                case.get("iccProfileFile") is not None
                or case.get("iccProfileSHA256") is not None
                or case.get("iccProfileByteCount") not in (0, None)
                or case.get("iccProfileClass") is not None
            ):
                raise CaptureError(f"unexpected ICC oracle for non-ICC case: {case_id}")

            expected_cicp_raw = case.get("sourceCICP")
            if color_authority == "cICP":
                if (
                    not isinstance(expected_cicp_raw, list)
                    or len(expected_cicp_raw) != 4
                    or any(not isinstance(value, int) or not 0 <= value <= 255 for value in expected_cicp_raw)
                ):
                    raise CaptureError(f"missing generated cICP oracle: {case_id}")
                expected_cicp = {
                    "colorPrimaries": expected_cicp_raw[0],
                    "transferFunction": expected_cicp_raw[1],
                    "matrixCoefficients": expected_cicp_raw[2],
                    "videoFullRangeFlag": expected_cicp_raw[3],
                }
            else:
                if expected_cicp_raw is not None:
                    raise CaptureError(f"unexpected cICP oracle for non-cICP case: {case_id}")
                expected_cicp = None

            mastering_raw = case.get("masteringDisplayColorVolume")
            content_light_raw = case.get("contentLightLevel")
            expected_mastering: dict[str, int] | None = None
            expected_content_light: dict[str, int] | None = None
            if mastering_raw is not None:
                if not isinstance(mastering_raw, dict):
                    raise CaptureError(f"invalid generated mDCV metadata: {case_id}")
                pairs: dict[str, tuple[int, int]] = {}
                for key in ("red", "green", "blue", "white"):
                    pair = mastering_raw.get(key)
                    if (
                        not isinstance(pair, list)
                        or len(pair) != 2
                        or any(not isinstance(value, int) or not 0 <= value <= 0xFFFF for value in pair)
                    ):
                        raise CaptureError(f"invalid generated mDCV {key}: {case_id}")
                    pairs[key] = (int(pair[0]), int(pair[1]))
                maximum = mastering_raw.get("maximumLuminanceScaledBy10000")
                minimum = mastering_raw.get("minimumLuminanceScaledBy10000")
                if (
                    not isinstance(maximum, int)
                    or not isinstance(minimum, int)
                    or not 0 <= maximum <= 0x7FFF_FFFF
                    or not 0 <= minimum <= 0x7FFF_FFFF
                ):
                    raise CaptureError(f"invalid generated mDCV luminance: {case_id}")
                expected_mastering = {
                    "redX": pairs["red"][0],
                    "redY": pairs["red"][1],
                    "greenX": pairs["green"][0],
                    "greenY": pairs["green"][1],
                    "blueX": pairs["blue"][0],
                    "blueY": pairs["blue"][1],
                    "whiteX": pairs["white"][0],
                    "whiteY": pairs["white"][1],
                    "maximumLuminanceScaledBy10000": maximum,
                    "minimumLuminanceScaledBy10000": minimum,
                }
            if content_light_raw is not None:
                if not isinstance(content_light_raw, dict):
                    raise CaptureError(f"invalid generated cLLI metadata: {case_id}")
                maximum_content = content_light_raw.get("maximumContentLightLevelScaledBy10000")
                maximum_frame_average = content_light_raw.get(
                    "maximumFrameAverageLightLevelScaledBy10000"
                )
                if (
                    not isinstance(maximum_content, int)
                    or not isinstance(maximum_frame_average, int)
                    or not 0 <= maximum_content <= 0x7FFF_FFFF
                    or not 0 <= maximum_frame_average <= 0x7FFF_FFFF
                ):
                    raise CaptureError(f"invalid generated cLLI values: {case_id}")
                expected_content_light = {
                    "maximumContentLightLevelScaledBy10000": maximum_content,
                    "maximumFrameAverageLightLevelScaledBy10000": maximum_frame_average,
                }
            if expected_mastering is not None or expected_content_light is not None:
                if color_authority != "cICP" or expected_cicp_raw != [9, 16, 0, 1]:
                    raise CaptureError(f"HDR static metadata outside PQ cICP success slice: {case_id}")
                expected_hdr_static_metadata: dict[str, Any] | None = {
                    "masteringDisplayColorVolume": expected_mastering,
                    "contentLightLevel": expected_content_light,
                }
            else:
                expected_hdr_static_metadata = None

            request_color_policy = case.get("requestColorPolicy", "preserveSource")
            if request_color_policy not in ("preserveSource", "convertToSRGB"):
                raise CaptureError(f"invalid success color policy: {case_id}")
            maximum_metadata_bytes = case.get("maximumMetadataBytes", 1_024)
            if not isinstance(maximum_metadata_bytes, int) or maximum_metadata_bytes <= 0:
                raise CaptureError(f"invalid success metadata limit: {case_id}")
            is_color_conversion = request_color_policy == "convertToSRGB"
            is_cicp_p3_conversion = False
            is_icc_matrix_trc_conversion = False
            icc_per_channel_type0 = False
            icc_per_channel_parametric = False
            icc_per_channel_curve_gamma = False
            icc_per_channel_mixed_encoding = False
            icc_large_sampled_cardinality = False
            icc_real_input_measured_profile = False
            icc_large_sampled_node_count: int | None = None
            icc_per_channel_curve_kinds: list[str] | None = None
            icc_per_channel_parametric_function_types: list[int] | None = None
            icc_transfer_curve_kind: str | None = None
            icc_parametric_function_type: int | None = None
            if is_color_conversion:
                common_conversion_valid = (
                    case.get("sourceFormat") in ("rgb16", "rgba16")
                    and case.get("sourceSignificantBits") is None
                    and expected_hdr_static_metadata is None
                )
                is_cicp_p3_conversion = (
                    color_authority == "cICP"
                    and expected_cicp_raw == [12, 13, 0, 1]
                    and case.get("sourcePattern") == "p3InGamut"
                )
                icc_profile_kind = case.get("iccProfileKind")
                source_pattern = case.get("sourcePattern")
                is_icc_matrix_trc_conversion = (
                    color_authority == "rgbICC"
                    and (
                        (icc_profile_kind == "displayP3MatrixTRC" and source_pattern == "p3InGamut")
                        or (
                            icc_profile_kind in (
                                "sRGBD50Gamma22MatrixTRC",
                                "sRGBD50Gamma18Type0MatrixTRC",
                                "sRGBD50Gamma22Type0MatrixTRC",
                                "sRGBD50Type1MatrixTRC",
                                "sRGBD50Type2MatrixTRC",
                                "sRGBD50Type4MatrixTRC",
                                "sRGBD50CurveGamma18TRC",
                                "sRGBD50CurveGamma22TRC",
                                "sRGBD50CurveIdentityTRC",
                                "sRGBD50CurveSampledTRC",
                                "sRGBD50CurveSampled1025TRC",
                                "sRGBD50PerChannelType0TRC",
                                "sRGBD50PerChannelParametricTRC",
                                "sRGBD50PerChannelMixedTRC",
                            )
                            and source_pattern == "matrixTRCInGamut"
                        )
                        or (
                            icc_profile_kind == "realEpson3170GammaMatrix"
                            and source_pattern == "realEpson3170InGamut"
                            and case.get("iccProfileClass") == "scnr"
                        )
                    )
                )
                if not common_conversion_valid or not (is_cicp_p3_conversion or is_icc_matrix_trc_conversion):
                    raise CaptureError(f"conversion success escaped the qualified slice: {case_id}")
                if is_cicp_p3_conversion:
                    expected_candidate_rgba_be = display_p3_rgba16be_to_srgb_rgba16be(expected_rgba_be)
                else:
                    icc_real_input_measured_profile = icc_profile_kind == "realEpson3170GammaMatrix"
                    icc_large_sampled_cardinality = icc_profile_kind == "sRGBD50CurveSampled1025TRC"
                    _, parsed_curves = _icc_matrix_trcs(expected_icc)
                    nonshared_channel_curves = parsed_curves[1:] != parsed_curves[:1] * 2
                    if icc_large_sampled_cardinality:
                        if parsed_curves[0][0] != "curveSampled" or parsed_curves[1:] != parsed_curves[:1] * 2:
                            raise CaptureError(f"large sampled ICC profile did not retain one shared sampled TRC: {case_id}")
                        icc_large_sampled_node_count = len(parsed_curves[0][2])
                    if nonshared_channel_curves:
                        curve_kinds = [curve_kind for curve_kind, _, _ in parsed_curves]
                        function_types = [
                            function_type
                            for _, function_type, _ in parsed_curves
                            if function_type is not None
                        ]
                        icc_per_channel_curve_kinds = curve_kinds
                        if all(curve_kind == "parametric" for curve_kind in curve_kinds):
                            if len(function_types) != 3:
                                raise CaptureError(f"per-channel ICC parametric function types are incomplete: {case_id}")
                            icc_per_channel_parametric = True
                            icc_per_channel_parametric_function_types = function_types
                            icc_per_channel_type0 = function_types == [0, 0, 0]
                            icc_transfer_curve_kind = "parametric"
                            icc_parametric_function_type = 0 if icc_per_channel_type0 else None
                        elif all(curve_kind == "curveGamma" for curve_kind in curve_kinds):
                            icc_per_channel_curve_gamma = True
                        else:
                            icc_per_channel_mixed_encoding = True
                    else:
                        icc_transfer_curve_kind = parsed_curves[0][0]
                        icc_parametric_function_type = parsed_curves[0][1]
                    expected_candidate_rgba_be = icc_matrix_trc_rgba16be_to_srgb_rgba16be(
                        expected_icc,
                        expected_rgba_be,
                    )
            else:
                expected_candidate_rgba_be = expected_rgba_be

            expected_metadata_limit = 4_096 if icc_large_sampled_cardinality else 1_024
            if maximum_metadata_bytes != expected_metadata_limit:
                raise CaptureError(
                    f"success metadata limit escaped qualified profile: {case_id} "
                    f"expected={expected_metadata_limit} actual={maximum_metadata_bytes}"
                )

            significant_bits_raw = case.get("sourceSignificantBits")
            reference_recovery_exact = True
            low_order_variation_verified = True
            if significant_bits_raw is not None:
                if (
                    not isinstance(significant_bits_raw, list)
                    or len(significant_bits_raw) != source_bpp // 2
                    or any(not isinstance(value, int) or not 1 <= value <= 16 for value in significant_bits_raw)
                ):
                    raise CaptureError(f"invalid generated sBIT metadata: {case_id}")
                reference_file = case.get("referenceSamplesU16BEFile")
                reference_sha = case.get("referenceSamplesU16BESHA256")
                low_order_variation = case.get("lowOrderVariationByChannel")
                if (
                    not isinstance(reference_file, str)
                    or not isinstance(reference_sha, str)
                    or not isinstance(low_order_variation, list)
                    or len(low_order_variation) != len(significant_bits_raw)
                ):
                    raise CaptureError(f"missing sBIT reference evidence: {case_id}")
                reference = (corpus / reference_file).read_bytes()
                if sha256_bytes(reference) != reference_sha:
                    raise CaptureError(f"sBIT reference digest drifted: {case_id}")
                recovered = recovered_reference_samples_u16be(
                    source,
                    source_bpp,
                    significant_bits_raw,
                )
                reference_recovery_exact = recovered == reference
                if not reference_recovery_exact:
                    raise CaptureError(f"sBIT reference recovery mismatch: {case_id}")
                low_order_variation_verified = all(
                    significant_bits_raw[channel] == 16 or low_order_variation[channel] is True
                    for channel in range(len(significant_bits_raw))
                )
                if not low_order_variation_verified:
                    raise CaptureError(f"sBIT low-order variation evidence missing: {case_id}")
            else:
                if case.get("referenceSamplesU16BEFile") is not None:
                    raise CaptureError(f"unexpected sBIT reference for non-sBIT case: {case_id}")

            libpng_output = outputs / f"{case_id}.libpng.rgba16be"
            libpng_icc_output = outputs / f"{case_id}.libpng.icc"
            libpng_completed = run(
                [str(libpng_probe), str(png_path), str(libpng_output), str(libpng_icc_output)]
            )
            libpng_report = parse_json_stdout(libpng_completed, f"libpng {case_id}")
            libpng_bytes = libpng_output.read_bytes()
            libpng_icc = libpng_icc_output.read_bytes()
            if libpng_bytes != expected_rgba_be:
                raise CaptureError(f"libpng external RGBA16 oracle mismatch: {case_id}")
            if libpng_icc != expected_icc:
                raise CaptureError(f"libpng external ICC oracle mismatch: {case_id}")
            source_format = case.get("sourceFormat", "rgba16")
            expected_interlace = int(case.get("interlace", 0))
            color_type_by_format = {
                "grayscale16": 0,
                "rgb16": 2,
                "grayscaleAlpha16": 4,
                "rgba16": 6,
            }
            if source_format not in color_type_by_format:
                raise CaptureError(f"unsupported PNG16 source format: {source_format}")
            expected_color_type = color_type_by_format[source_format]
            source_has_alpha = source_format in ("grayscaleAlpha16", "rgba16")
            expected_trns_expansion = (
                source_format == "rgb16" and case.get("transparentRGB16") is not None
            ) or (
                source_format == "grayscale16" and case.get("transparentGray16") is not None
            )
            expected_opaque_alpha = not source_has_alpha and not expected_trns_expansion
            expected_has_sbit = significant_bits_raw is not None
            expected_sbit_gray = (
                significant_bits_raw[0]
                if significant_bits_raw is not None
                and source_format in ("grayscale16", "grayscaleAlpha16")
                else 0
            )
            expected_sbit_red = (
                significant_bits_raw[0]
                if significant_bits_raw is not None and source_format in ("rgb16", "rgba16")
                else 0
            )
            expected_sbit_green = (
                significant_bits_raw[1]
                if significant_bits_raw is not None and source_format in ("rgb16", "rgba16")
                else 0
            )
            expected_sbit_blue = (
                significant_bits_raw[2]
                if significant_bits_raw is not None and source_format in ("rgb16", "rgba16")
                else 0
            )
            expected_sbit_alpha = 0
            if significant_bits_raw is not None:
                if source_format == "grayscaleAlpha16":
                    expected_sbit_alpha = significant_bits_raw[1]
                elif source_format == "rgba16":
                    expected_sbit_alpha = significant_bits_raw[3]
            expected_has_iccp = color_authority == "rgbICC"
            expected_icc_length = len(expected_icc)
            expected_has_cicp = color_authority == "cICP"
            expected_cicp_fields = expected_cicp_raw if expected_cicp_raw is not None else [0, 0, 0, 0]
            expected_srgb_intent = 0 if color_authority == "sRGB" else -1
            expected_has_mdcv = expected_mastering is not None
            expected_has_clli = expected_content_light is not None
            expected_mdcv = expected_mastering or {
                "redX": 0,
                "redY": 0,
                "greenX": 0,
                "greenY": 0,
                "blueX": 0,
                "blueY": 0,
                "whiteX": 0,
                "whiteY": 0,
                "maximumLuminanceScaledBy10000": 0,
                "minimumLuminanceScaledBy10000": 0,
            }
            expected_clli = expected_content_light or {
                "maximumContentLightLevelScaledBy10000": 0,
                "maximumFrameAverageLightLevelScaledBy10000": 0,
            }
            if (
                libpng_report.get("outputByteOrder") != "bigEndian"
                or libpng_report.get("alphaAssociation") != "straight"
                or libpng_report.get("sourceColorType") != expected_color_type
                or libpng_report.get("sourceInterlaceType") != expected_interlace
                or libpng_report.get("interlacePasses") != (7 if expected_interlace == 1 else 1)
                or libpng_report.get("tRNSExpanded") is not expected_trns_expansion
                or libpng_report.get("opaqueAlphaAdded") is not expected_opaque_alpha
                or libpng_report.get("hasSBIT") is not expected_has_sbit
                or libpng_report.get("sBITGray") != expected_sbit_gray
                or libpng_report.get("sBITRed") != expected_sbit_red
                or libpng_report.get("sBITGreen") != expected_sbit_green
                or libpng_report.get("sBITBlue") != expected_sbit_blue
                or libpng_report.get("sBITAlpha") != expected_sbit_alpha
                or libpng_report.get("hasICCP") is not expected_has_iccp
                or libpng_report.get("iccProfileLength") != expected_icc_length
                or libpng_report.get("hasCICP") is not expected_has_cicp
                or libpng_report.get("cicpColorPrimaries") != expected_cicp_fields[0]
                or libpng_report.get("cicpTransferFunction") != expected_cicp_fields[1]
                or libpng_report.get("cicpMatrixCoefficients") != expected_cicp_fields[2]
                or libpng_report.get("cicpVideoFullRangeFlag") != expected_cicp_fields[3]
                or libpng_report.get("hasMDCV") is not expected_has_mdcv
                or libpng_report.get("mdcvRedXFixed") != expected_mdcv["redX"] * 2
                or libpng_report.get("mdcvRedYFixed") != expected_mdcv["redY"] * 2
                or libpng_report.get("mdcvGreenXFixed") != expected_mdcv["greenX"] * 2
                or libpng_report.get("mdcvGreenYFixed") != expected_mdcv["greenY"] * 2
                or libpng_report.get("mdcvBlueXFixed") != expected_mdcv["blueX"] * 2
                or libpng_report.get("mdcvBlueYFixed") != expected_mdcv["blueY"] * 2
                or libpng_report.get("mdcvWhiteXFixed") != expected_mdcv["whiteX"] * 2
                or libpng_report.get("mdcvWhiteYFixed") != expected_mdcv["whiteY"] * 2
                or libpng_report.get("mdcvMaximumLuminanceScaledBy10000")
                != expected_mdcv["maximumLuminanceScaledBy10000"]
                or libpng_report.get("mdcvMinimumLuminanceScaledBy10000")
                != expected_mdcv["minimumLuminanceScaledBy10000"]
                or libpng_report.get("hasCLLI") is not expected_has_clli
                or libpng_report.get("maximumContentLightLevelScaledBy10000")
                != expected_clli["maximumContentLightLevelScaledBy10000"]
                or libpng_report.get("maximumFrameAverageLightLevelScaledBy10000")
                != expected_clli["maximumFrameAverageLightLevelScaledBy10000"]
                or libpng_report.get("colorAuthority") != color_authority
                or libpng_report.get("sRGBIntent") != expected_srgb_intent
            ):
                raise CaptureError(f"libpng RGBA16 oracle contract drifted: {case_id}")

            littlecms_report: dict[str, Any] | None = None
            littlecms_maximum_code_difference = 0
            littlecms_target_matrix_counterfactual_maximum_code_difference: int | None = None
            littlecms_requires_one_code = not (
                (icc_per_channel_parametric and not icc_per_channel_type0)
                or icc_per_channel_mixed_encoding
                or icc_large_sampled_cardinality
                or icc_real_input_measured_profile
            )
            if is_icc_matrix_trc_conversion:
                littlecms_input = outputs / f"{case_id}.source-expanded.rgba16be"
                littlecms_output = outputs / f"{case_id}.littlecms.srgb.rgba16be"
                littlecms_input.write_bytes(expected_rgba_be)
                littlecms_completed = run(
                    [
                        str(littlecms_probe),
                        str(corpus / case["iccProfileFile"]),
                        str(littlecms_input),
                        str(littlecms_output),
                    ]
                )
                littlecms_report = parse_json_stdout(
                    littlecms_completed,
                    f"LittleCMS {case_id}",
                )
                littlecms_bytes = littlecms_output.read_bytes()
                littlecms_maximum_code_difference = rgba16be_max_rgb_code_difference(
                    littlecms_bytes,
                    expected_candidate_rgba_be,
                )
                if littlecms_requires_one_code and littlecms_maximum_code_difference > 1:
                    raise CaptureError(
                        f"LittleCMS ICC conversion diverged by more than one UInt16 code: {case_id}"
                    )
                if icc_real_input_measured_profile:
                    target_matrix_raw = littlecms_report.get("targetRGBToD50XYZ")
                    if not isinstance(target_matrix_raw, list) or len(target_matrix_raw) != 3:
                        raise CaptureError(f"LittleCMS target sRGB matrix is malformed: {case_id}")
                    target_matrix_rows: list[tuple[float, float, float]] = []
                    for row in target_matrix_raw:
                        if not isinstance(row, list) or len(row) != 3:
                            raise CaptureError(f"LittleCMS target sRGB matrix row is malformed: {case_id}")
                        values = tuple(float(value) for value in row)
                        if not all(math.isfinite(value) for value in values):
                            raise CaptureError(f"LittleCMS target sRGB matrix is non-finite: {case_id}")
                        target_matrix_rows.append(values)
                    target_matrix = tuple(target_matrix_rows)
                    target_matrix_counterfactual = icc_matrix_trc_rgba16be_to_srgb_rgba16be(
                        expected_icc,
                        expected_rgba_be,
                        target_rgb_to_d50_xyz=target_matrix,
                    )
                    littlecms_target_matrix_counterfactual_maximum_code_difference = (
                        rgba16be_max_rgb_code_difference(
                            littlecms_bytes,
                            target_matrix_counterfactual,
                        )
                    )
                    if littlecms_target_matrix_counterfactual_maximum_code_difference > 1:
                        raise CaptureError(
                            "real input-class LittleCMS delta did not collapse under its own "
                            f"target sRGB matrix: {case_id}"
                        )

            imagecraft_output = outputs / f"{case_id}.imagecraft.rgba16le"
            imagecraft_argv = [
                str(swift_probe),
                str(png_path),
                str(width),
                str(height),
                str(operation_budget),
                str(imagecraft_output),
            ]
            if request_color_policy != "preserveSource" or maximum_metadata_bytes != 1_024:
                imagecraft_argv.append(request_color_policy)
            if maximum_metadata_bytes != 1_024:
                imagecraft_argv.append(str(maximum_metadata_bytes))
            imagecraft_completed = run(imagecraft_argv)
            imagecraft_report = parse_json_stdout(imagecraft_completed, f"ImageCraft {case_id}")
            if imagecraft_report.get("maximumMetadataBytes") != maximum_metadata_bytes:
                raise CaptureError(f"ImageCraft metadata-limit report drifted: {case_id}")
            candidate = imagecraft_output.read_bytes()
            canonical = canonical_le_from_rgba16be(expected_candidate_rgba_be)
            if candidate != canonical:
                raise CaptureError(f"ImageCraft canonical RGBA16LE mismatch: {case_id}")
            candidate_embedded_icc = b"" if is_icc_matrix_trc_conversion else expected_icc
            expected_transfer_byte_count = expected_byte_count + len(candidate_embedded_icc)
            if is_color_conversion:
                expected_packed_color_encoding = "sRGB"
                expected_source_color_profile = "embeddedICC" if is_icc_matrix_trc_conversion else "unknown"
                expected_output_cicp = None
            elif color_authority == "rgbICC":
                expected_packed_color_encoding = "embeddedICC"
                expected_source_color_profile = "embeddedICC"
                expected_output_cicp = None
            elif color_authority == "cICP":
                expected_packed_color_encoding = "cICP"
                expected_source_color_profile = "unknown"
                expected_output_cicp = expected_cicp
            else:
                expected_packed_color_encoding = "sRGB"
                expected_source_color_profile = "standardSRGB"
                expected_output_cicp = None
            expected_embedded_icc_base64 = (
                base64.b64encode(candidate_embedded_icc).decode("ascii")
                if candidate_embedded_icc
                else None
            )
            expected_contract = {
                "status": "success",
                "byteCount": expected_byte_count,
                "bytesPerRow": width * 8,
                "sampleStorage": "uint16",
                "channelLayout": "rgba",
                "alphaAssociation": "straight",
                "multibyteByteOrder": "littleEndian",
                "packedColorEncoding": expected_packed_color_encoding,
                "sourceColorProfile": expected_source_color_profile,
                "embeddedICCBase64": expected_embedded_icc_base64,
                "embeddedICCByteCount": len(candidate_embedded_icc),
                "cicp": expected_output_cicp,
                "hdrStaticMetadata": expected_hdr_static_metadata,
                "outputLayoutAuthority": "codecOwnedStraightRGBA16LE",
                "transferredByteChargeUpperBound": expected_transfer_byte_count,
                "packedTransferredByteCharge": expected_transfer_byte_count,
            }
            for key, expected in expected_contract.items():
                if imagecraft_report.get(key) != expected:
                    raise CaptureError(
                        f"ImageCraft PNG16 contract drifted for {case_id}: "
                        f"{key}={imagecraft_report.get(key)!r} expected={expected!r}"
                    )
            expected_imagecraft_sbit: dict[str, Any] | None
            if significant_bits_raw is None:
                expected_imagecraft_sbit = None
            elif source_format == "grayscale16":
                expected_imagecraft_sbit = {
                    "sampleBitDepth": 16,
                    "sourceChannelModel": "grayscale",
                    "gray": significant_bits_raw[0],
                    "red": None,
                    "green": None,
                    "blue": None,
                    "alpha": None,
                    "sourceHasStoredAlpha": False,
                }
            elif source_format == "grayscaleAlpha16":
                expected_imagecraft_sbit = {
                    "sampleBitDepth": 16,
                    "sourceChannelModel": "grayscaleAlpha",
                    "gray": significant_bits_raw[0],
                    "red": None,
                    "green": None,
                    "blue": None,
                    "alpha": significant_bits_raw[1],
                    "sourceHasStoredAlpha": True,
                }
            elif source_format == "rgb16":
                expected_imagecraft_sbit = {
                    "sampleBitDepth": 16,
                    "sourceChannelModel": "rgb",
                    "gray": None,
                    "red": significant_bits_raw[0],
                    "green": significant_bits_raw[1],
                    "blue": significant_bits_raw[2],
                    "alpha": None,
                    "sourceHasStoredAlpha": False,
                }
            else:
                expected_imagecraft_sbit = {
                    "sampleBitDepth": 16,
                    "sourceChannelModel": "rgba",
                    "gray": None,
                    "red": significant_bits_raw[0],
                    "green": significant_bits_raw[1],
                    "blue": significant_bits_raw[2],
                    "alpha": significant_bits_raw[3],
                    "sourceHasStoredAlpha": True,
                }
            significant_bits_metadata_exact = (
                imagecraft_report.get("sourceSignificantBits") == expected_imagecraft_sbit
            )
            if not significant_bits_metadata_exact:
                raise CaptureError(f"ImageCraft sBIT metadata drifted: {case_id}")
            operation = imagecraft_report.get("operationByteChargeUpperBound")
            minimum_operation_payload = expected_byte_count + 2 * width * source_bpp + len(expected_icc)
            if (
                not isinstance(operation, int)
                or operation < minimum_operation_payload
                or operation > operation_budget
            ):
                raise CaptureError(f"ImageCraft PNG16 operation bound invalid: {case_id}")
            icc_profile_exact = (
                libpng_icc == expected_icc
                and imagecraft_report.get("embeddedICCByteCount") == len(candidate_embedded_icc)
                and imagecraft_report.get("embeddedICCBase64") == expected_embedded_icc_base64
            )
            cicp_exact = (
                libpng_report.get("hasCICP") is expected_has_cicp
                and imagecraft_report.get("cicp") == expected_output_cicp
            )
            color_conversion_exact = not is_color_conversion or candidate == canonical
            cicp_p3_conversion_exact = not is_cicp_p3_conversion or candidate == canonical
            hdr_static_metadata_exact = (
                imagecraft_report.get("hdrStaticMetadata") == expected_hdr_static_metadata
            )

            near_miss_verified = False
            if case.get("highByteNearMiss"):
                transparent_index = case.get("transparentPixelIndex")
                if not isinstance(transparent_index, int) or width * height < 2:
                    raise CaptureError(f"malformed high-byte near-miss case: {case_id}")
                near_index = 1 if transparent_index != 1 else 0
                if source_format == "rgb16":
                    transparent_raw = case.get("transparentRGB16")
                    if not isinstance(transparent_raw, list) or len(transparent_raw) != 3:
                        raise CaptureError(f"malformed RGB16 near-miss case: {case_id}")
                    near_offset = near_index * 6
                    near = tuple(
                        int.from_bytes(source[near_offset + channel : near_offset + channel + 2], "big")
                        for channel in (0, 2, 4)
                    )
                    transparent_tuple = tuple(int(value) for value in transparent_raw)
                    if near == transparent_tuple or any(
                        (near[index] >> 8) != (transparent_tuple[index] >> 8) for index in range(3)
                    ):
                        raise CaptureError(f"RGB16 high-byte near-miss source oracle drifted: {case_id}")
                elif source_format == "grayscale16":
                    transparent_gray = case.get("transparentGray16")
                    if not isinstance(transparent_gray, int):
                        raise CaptureError(f"malformed grayscale16 near-miss case: {case_id}")
                    near_offset = near_index * 2
                    near_gray = int.from_bytes(source[near_offset : near_offset + 2], "big")
                    if near_gray == transparent_gray or (near_gray >> 8) != (transparent_gray >> 8):
                        raise CaptureError(f"grayscale16 high-byte near-miss source oracle drifted: {case_id}")
                else:
                    raise CaptureError(f"near-miss case has unsupported source format: {case_id}")
                near_alpha_offset = near_index * 8 + 6
                if expected_rgba_be[near_alpha_offset : near_alpha_offset + 2] != b"\xff\xff":
                    raise CaptureError(f"high-byte near miss became transparent: {case_id}")
                near_miss_verified = True

            success_results.append(
                {
                    **case,
                    "storedSourceDigestExact": sha256_bytes(source) == case["sourceRawBESHA256"],
                    "externalRGBA16BigEndianExact": libpng_bytes == expected_rgba_be,
                    "canonicalLittleEndianExact": candidate == canonical,
                    "iccProfileExact": icc_profile_exact,
                    "iccProfileSHA256": sha256_bytes(expected_icc) if expected_icc else None,
                    "iccProfileClass": case.get("iccProfileClass", "mntr") if expected_icc else None,
                    "cicpExact": cicp_exact,
                    "colorConversionExact": color_conversion_exact,
                    "displayP3ToSRGBConversionExact": cicp_p3_conversion_exact,
                    "iccMatrixTRCConversionExact": not is_icc_matrix_trc_conversion or candidate == canonical,
                    "iccTransferCurveKind": icc_transfer_curve_kind,
                    "iccParametricFunctionType": icc_parametric_function_type,
                    "iccPerChannelType0": icc_per_channel_type0,
                    "iccPerChannelParametric": icc_per_channel_parametric,
                    "iccPerChannelCurveGamma": icc_per_channel_curve_gamma,
                    "iccPerChannelMixedEncoding": icc_per_channel_mixed_encoding,
                    "iccLargeSampledCardinality": icc_large_sampled_cardinality,
                    "iccRealInputMeasuredProfile": icc_real_input_measured_profile,
                    "iccLargeSampledNodeCount": icc_large_sampled_node_count,
                    "iccProfileByteCount": len(expected_icc) if expected_icc else 0,
                    "resolvedMaximumMetadataBytes": maximum_metadata_bytes,
                    "iccPerChannelCurveKinds": icc_per_channel_curve_kinds,
                    "iccPerChannelParametricFunctionTypes": icc_per_channel_parametric_function_types,
                    "littleCMSObservationAvailable": not is_icc_matrix_trc_conversion or littlecms_report is not None,
                    "littleCMSRequiresOneCode": not is_icc_matrix_trc_conversion or littlecms_requires_one_code,
                    "littleCMSWithinOneCode": not is_icc_matrix_trc_conversion or littlecms_maximum_code_difference <= 1,
                    "littleCMSMaximumRGBCodeDifference": littlecms_maximum_code_difference,
                    "littleCMSTargetMatrixCounterfactualMaximumRGBCodeDifference": (
                        littlecms_target_matrix_counterfactual_maximum_code_difference
                    ),
                    "littleCMS": littlecms_report,
                    "hdrStaticMetadataExact": hdr_static_metadata_exact,
                    "significantBitsMetadataExact": significant_bits_metadata_exact,
                    "referenceSamplesRecoveredExact": reference_recovery_exact,
                    "lowOrderVariationVerified": low_order_variation_verified,
                    "highByteNearMissVerified": near_miss_verified,
                    "sourceRawBESHA256": sha256_bytes(source),
                    "externalRGBA16BESHA256": sha256_bytes(expected_rgba_be),
                    "canonicalRGBA16LESHA256": sha256_bytes(canonical),
                    "minimumModeledOperationPayloadBytes": minimum_operation_payload,
                    "pngSHA256": sha256_file(png_path),
                    "libpng": libpng_report,
                    "imageCraft": imagecraft_report,
                }
            )

        profile_class_parity_pairs = [
            ("PNG16-XB-054", "PNG16-XB-090"),
            ("PNG16-XB-055", "PNG16-XB-091"),
            ("PNG16-XB-056", "PNG16-XB-092"),
        ]
        success_by_id = {result["id"]: result for result in success_results}
        profile_class_parity: list[dict[str, Any]] = []
        for monitor_id, input_id in profile_class_parity_pairs:
            monitor = success_by_id.get(monitor_id)
            input_profile = success_by_id.get(input_id)
            if monitor is None or input_profile is None:
                raise CaptureError(f"ICC profile-class parity case missing: {monitor_id}/{input_id}")
            same_source = monitor["sourceRawBESHA256"] == input_profile["sourceRawBESHA256"]
            same_pixels = monitor["canonicalRGBA16LESHA256"] == input_profile["canonicalRGBA16LESHA256"]
            same_operation_bound = (
                monitor["imageCraft"].get("operationByteChargeUpperBound")
                == input_profile["imageCraft"].get("operationByteChargeUpperBound")
            )
            same_transfer_bound = (
                monitor["imageCraft"].get("transferredByteChargeUpperBound")
                == input_profile["imageCraft"].get("transferredByteChargeUpperBound")
            )
            if not (same_source and same_pixels and same_operation_bound and same_transfer_bound):
                raise CaptureError(f"ICC profile-class parity drifted: {monitor_id}/{input_id}")
            profile_class_parity.append(
                {
                    "monitorCaseID": monitor_id,
                    "inputCaseID": input_id,
                    "sameStoredSource": same_source,
                    "sameCanonicalPixels": same_pixels,
                    "sameOperationBound": same_operation_bound,
                    "sameTransferredBound": same_transfer_bound,
                }
            )

        hostile_results: list[dict[str, Any]] = []
        for case in manifest["hostileCases"]:
            case_id = case["id"]
            png_path = corpus / case["pngFile"]
            budget = 1 if case["mutation"] == "operation-budget" else operation_budget
            output = outputs / f"{case_id}.should-not-exist"
            hostile_argv = [
                str(swift_probe),
                str(png_path),
                str(case["width"]),
                str(case["height"]),
                str(budget),
                str(output),
            ]
            request_color_policy = case.get("requestColorPolicy")
            maximum_metadata_bytes = case.get("maximumMetadataBytes", 1_024)
            if not isinstance(maximum_metadata_bytes, int) or maximum_metadata_bytes <= 0:
                raise CaptureError(f"invalid hostile metadata limit: {case_id}")
            if request_color_policy is not None:
                if request_color_policy not in ("preserveSource", "convertToSRGB"):
                    raise CaptureError(f"invalid hostile color policy: {case_id}")
                hostile_argv.append(request_color_policy)
            elif maximum_metadata_bytes != 1_024:
                hostile_argv.append("preserveSource")
            if maximum_metadata_bytes != 1_024:
                hostile_argv.append(str(maximum_metadata_bytes))
            completed = run(hostile_argv, allow_failure=True)
            if completed.returncode == 0:
                raise CaptureError(f"hostile PNG16 case unexpectedly succeeded: {case_id}")
            report = parse_json_stdout(completed, f"ImageCraft hostile {case_id}")
            if report.get("status") != "error" or not isinstance(report.get("error"), str):
                raise CaptureError(f"hostile PNG16 error report malformed: {case_id}")
            if (
                case.get("mutation") == "matrix-trc-curve-sampled-count-mismatch"
                and report["error"] != "PNGIndependentRGBA16Error.unsupportedSourceSemantics"
            ):
                raise CaptureError(f"large sampled count mismatch failed at the wrong gate: {case_id}")
            if (
                case.get("mutation") == "matrix-trc-output-profile-class"
                and report["error"] != "PNGIndependentRGBA16Error.unsupportedSourceSemantics"
            ):
                raise CaptureError(f"output-class ICC profile failed at the wrong gate: {case_id}")
            if (
                case.get("mutation") in ("real-input-lut-linear-rimm", "real-input-lut-rimm-excr")
                and report["error"] != "PNGIndependentRGBA16Error.unsupportedSourceSemantics"
            ):
                raise CaptureError(f"real input-class LUT profile failed at the wrong gate: {case_id}")
            if output.exists():
                raise CaptureError(f"hostile PNG16 case published output: {case_id}")
            hostile_results.append(
                {
                    **case,
                    "failedClosed": True,
                    "error": report["error"],
                    "resolvedMaximumMetadataBytes": maximum_metadata_bytes,
                    "pngSHA256": sha256_file(png_path),
                }
            )

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        after_hash = after.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after_hash:
            raise CaptureError("ImageCraft source identity changed during PNG16 formal capture")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": EVIDENCE_VERSION,
            "status": "source-bound-conformance",
            "formalSourceBoundExecution": True,
            "productionBackendQualified": False,
            "profile": {
                "profileID": profile["profileID"],
                "path": str(profile_path.relative_to(ROOT)),
                "sha256": sha256_file(profile_path),
            },
            "sourceIdentity": {
                "sourceIdentitySHA256": before_hash,
                "fileCount": before.get("fileCount"),
                "stableBeforeAfter": True,
            },
            "oracles": {
                "libpngVersion": libpng_version,
                "littleCMSVersion": littlecms_version,
                "pythonVersion": platform.python_version(),
                "libpngRGBA16OutputByteOrder": "bigEndian",
                "imageCraftCanonicalByteOrder": "littleEndian",
            },
            "binaries": {
                "builtInsideCapture": True,
                "imageCraftProbeSHA256": sha256_file(swift_probe),
                "libpngProbeSHA256": sha256_file(libpng_probe),
                "littleCMSProbeSHA256": sha256_file(littlecms_probe),
            },
            "generatedCorpus": {
                "successCaseCount": len(success_results),
                "hostileCaseCount": len(hostile_results),
                "manifestSHA256": sha256_file(manifest_path),
            },
            "operationBudgetBytes": operation_budget,
            "claimBoundary": profile["claimBoundary"],
            "successCases": success_results,
            "iccProfileClassParity": profile_class_parity,
            "hostileCases": hostile_results,
            "summary": {
                "successCasesExact": len(success_results),
                "hostileCasesFailedClosed": len(hostile_results),
                "storedSourceDigestContractPassed": all(
                    item["storedSourceDigestExact"] for item in success_results
                ),
                "externalRGBA16ContractPassed": all(
                    item["externalRGBA16BigEndianExact"] for item in success_results
                ),
                "canonicalRepresentationContractPassed": all(
                    item["canonicalLittleEndianExact"] for item in success_results
                ),
                "iccProfileContractPassed": all(item["iccProfileExact"] for item in success_results),
                "iccInputClassSuccessCases": sum(
                    item.get("iccProfileClass") == "scnr" for item in success_results
                ),
                "iccSyntheticInputClassSuccessCases": sum(
                    item.get("iccProfileClass") == "scnr"
                    and not item["iccRealInputMeasuredProfile"]
                    for item in success_results
                ),
                "iccRealInputMeasuredSuccessCases": sum(
                    item["iccRealInputMeasuredProfile"] for item in success_results
                ),
                "iccInputClassLittleCMSMaximumRGBCodeDifference": max(
                    (
                        item["littleCMSMaximumRGBCodeDifference"]
                        for item in success_results
                        if item.get("iccProfileClass") == "scnr"
                    ),
                    default=0,
                ),
                "iccRealInputMeasuredLittleCMSMaximumRGBCodeDifference": max(
                    (
                        item["littleCMSMaximumRGBCodeDifference"]
                        for item in success_results
                        if item["iccRealInputMeasuredProfile"]
                    ),
                    default=0,
                ),
                "iccRealInputMeasuredLittleCMSTargetMatrixCounterfactualMaximumRGBCodeDifference": max(
                    (
                        item["littleCMSTargetMatrixCounterfactualMaximumRGBCodeDifference"]
                        for item in success_results
                        if item["iccRealInputMeasuredProfile"]
                        and item["littleCMSTargetMatrixCounterfactualMaximumRGBCodeDifference"] is not None
                    ),
                    default=0,
                ),
                "iccRealInputMeasuredContractPassed": (
                    sum(item["iccRealInputMeasuredProfile"] for item in success_results) == 2
                    and sum(
                        item["iccRealInputMeasuredProfile"] and item.get("interlace", 0) == 1
                        for item in success_results
                    ) == 1
                    and all(
                        not item["iccRealInputMeasuredProfile"]
                        or (
                            item.get("iccProfileClass") == "scnr"
                            and item.get("iccProfileKind") == "realEpson3170GammaMatrix"
                            and item.get("sourcePattern") == "realEpson3170InGamut"
                            and item.get("realICCFixture")
                            == "fixtures/epson3170-set1-gamma-matrix.icc"
                            and item.get("realICCFixtureSHA256")
                            == "05285b6195383d1f81f996a76a82872197904b62bc2b9dfa55158c411d481697"
                            and item.get("realICCProfileByteCount") == 724
                            and item["iccProfileExact"]
                            and item["iccMatrixTRCConversionExact"]
                            and item["canonicalLittleEndianExact"]
                            and item["littleCMSObservationAvailable"]
                            and item["littleCMSRequiresOneCode"] is False
                            and item["littleCMSTargetMatrixCounterfactualMaximumRGBCodeDifference"]
                            is not None
                            and item["littleCMSTargetMatrixCounterfactualMaximumRGBCodeDifference"] <= 1
                            and item["iccPerChannelCurveGamma"]
                            and item["iccPerChannelCurveKinds"]
                            == ["curveGamma", "curveGamma", "curveGamma"]
                        )
                        for item in success_results
                    )
                ),
                "iccProfileClassParityPairCount": len(profile_class_parity),
                "iccOutputClassHostileCases": sum(
                    item.get("mutation") == "matrix-trc-output-profile-class"
                    for item in hostile_results
                ),
                "iccRealInputLUTHostileCases": sum(
                    item.get("mutation") in ("real-input-lut-linear-rimm", "real-input-lut-rimm-excr")
                    for item in hostile_results
                ),
                "iccRealInputLUTContractPassed": (
                    sum(
                        item.get("mutation") in ("real-input-lut-linear-rimm", "real-input-lut-rimm-excr")
                        for item in hostile_results
                    ) == 2
                    and all(
                        item.get("mutation") not in ("real-input-lut-linear-rimm", "real-input-lut-rimm-excr")
                        or (
                            item["failedClosed"]
                            and item["error"]
                            == "PNGIndependentRGBA16Error.unsupportedSourceSemantics"
                            and isinstance(item.get("realICCFixtureSHA256"), str)
                            and isinstance(item.get("realICCProfileByteCount"), int)
                            and item["resolvedMaximumMetadataBytes"] > item["realICCProfileByteCount"]
                        )
                        for item in hostile_results
                    )
                ),
                "iccProfileClassContractPassed": (
                    sum(
                        item.get("iccProfileClass") == "scnr"
                        and not item["iccRealInputMeasuredProfile"]
                        for item in success_results
                    ) == 3
                    and len(profile_class_parity) == 3
                    and all(
                        item["sameStoredSource"]
                        and item["sameCanonicalPixels"]
                        and item["sameOperationBound"]
                        and item["sameTransferredBound"]
                        for item in profile_class_parity
                    )
                    and all(
                        item.get("iccProfileClass") != "scnr"
                        or item["iccRealInputMeasuredProfile"]
                        or (
                            item["iccProfileExact"]
                            and item["iccMatrixTRCConversionExact"]
                            and item["canonicalLittleEndianExact"]
                            and item["littleCMSObservationAvailable"]
                            and item["littleCMSWithinOneCode"]
                        )
                        for item in success_results
                    )
                    and sum(
                        item.get("mutation") == "matrix-trc-output-profile-class"
                        for item in hostile_results
                    ) == 1
                    and all(
                        item.get("mutation") != "matrix-trc-output-profile-class"
                        or (
                            item["failedClosed"]
                            and item["error"]
                            == "PNGIndependentRGBA16Error.unsupportedSourceSemantics"
                        )
                        for item in hostile_results
                    )
                ),
                "cicpContractPassed": all(item["cicpExact"] for item in success_results),
                "colorConversionContractPassed": all(
                    item["colorConversionExact"] for item in success_results
                ),
                "displayP3ToSRGBConversionContractPassed": all(
                    item["displayP3ToSRGBConversionExact"] for item in success_results
                ),
                "iccMatrixTRCConversionContractPassed": all(
                    item["iccMatrixTRCConversionExact"] for item in success_results
                ),
                "iccPerChannelType0SuccessCases": sum(
                    item["iccPerChannelType0"] for item in success_results
                ),
                "iccPerChannelType0ContractPassed": (
                    sum(item["iccPerChannelType0"] for item in success_results) == 3
                    and all(
                        not item["iccPerChannelType0"]
                        or (
                            item["iccMatrixTRCConversionExact"]
                            and item["littleCMSWithinOneCode"]
                            and item["iccTransferCurveKind"] == "parametric"
                            and item["iccParametricFunctionType"] == 0
                            and item["iccPerChannelParametricFunctionTypes"] == [0, 0, 0]
                        )
                        for item in success_results
                    )
                ),
                "iccPerChannelParametricSuccessCases": sum(
                    item["iccPerChannelParametric"] for item in success_results
                ),
                "iccPerChannelCurveGammaSuccessCases": sum(
                    item["iccPerChannelCurveGamma"] for item in success_results
                ),
                "iccPerChannelCurveGammaContractPassed": (
                    sum(item["iccPerChannelCurveGamma"] for item in success_results) == 2
                    and all(
                        not item["iccPerChannelCurveGamma"]
                        or (
                            item["iccRealInputMeasuredProfile"]
                            and item["iccMatrixTRCConversionExact"]
                            and item["littleCMSObservationAvailable"]
                            and item["iccPerChannelCurveKinds"]
                            == ["curveGamma", "curveGamma", "curveGamma"]
                        )
                        for item in success_results
                    )
                ),
                "iccPerChannelMixedParametricSuccessCases": sum(
                    item["iccPerChannelParametric"] and not item["iccPerChannelType0"]
                    for item in success_results
                ),
                "iccPerChannelParametricContractPassed": (
                    sum(item["iccPerChannelParametric"] for item in success_results) == 6
                    and sum(
                        item["iccPerChannelParametric"] and not item["iccPerChannelType0"]
                        for item in success_results
                    ) == 3
                    and all(
                        not (item["iccPerChannelParametric"] and not item["iccPerChannelType0"])
                        or (
                            item["iccMatrixTRCConversionExact"]
                            and item["littleCMSObservationAvailable"]
                            and item["iccTransferCurveKind"] == "parametric"
                            and item["iccParametricFunctionType"] is None
                            and item["iccPerChannelParametricFunctionTypes"] == [1, 3, 4]
                        )
                        for item in success_results
                    )
                ),
                "iccPerChannelMixedEncodingSuccessCases": sum(
                    item["iccPerChannelMixedEncoding"] for item in success_results
                ),
                "iccPerChannelMixedEncodingContractPassed": (
                    sum(item["iccPerChannelMixedEncoding"] for item in success_results) == 3
                    and all(
                        not item["iccPerChannelMixedEncoding"]
                        or (
                            item["iccMatrixTRCConversionExact"]
                            and item["littleCMSObservationAvailable"]
                            and item["littleCMSRequiresOneCode"] is False
                            and item["iccPerChannelCurveKinds"]
                            == ["curveSampled", "parametric", "curveGamma"]
                            and item["iccTransferCurveKind"] is None
                            and item["iccParametricFunctionType"] is None
                        )
                        for item in success_results
                    )
                ),
                "iccPerChannelMixedEncodingLittleCMSMaximumRGBCodeDifference": max(
                    (
                        item["littleCMSMaximumRGBCodeDifference"]
                        for item in success_results
                        if item["iccPerChannelMixedEncoding"]
                    ),
                    default=0,
                ),
                "iccParametricFunctionTypesQualified": sorted(
                    {
                        item["iccParametricFunctionType"]
                        for item in success_results
                        if item["iccParametricFunctionType"] is not None
                    }
                ),
                "iccParametricFunctionCoverageContractPassed": sorted(
                    {
                        item["iccParametricFunctionType"]
                        for item in success_results
                        if item["iccParametricFunctionType"] is not None
                    }
                ) == [0, 1, 2, 3, 4],
                "iccTransferCurveKindsQualified": sorted(
                    {
                        item["iccTransferCurveKind"]
                        for item in success_results
                        if item["iccTransferCurveKind"] is not None
                    }
                ),
                "iccCurveTypeSingleGammaSuccessCases": sum(
                    item["iccTransferCurveKind"] == "curveGamma"
                    for item in success_results
                ),
                "iccCurveTypeSingleGammaContractPassed": (
                    sum(
                        item["iccTransferCurveKind"] == "curveGamma"
                        for item in success_results
                    ) == 3
                    and all(
                        item["iccTransferCurveKind"] != "curveGamma"
                        or (
                            item["iccMatrixTRCConversionExact"]
                            and item["littleCMSWithinOneCode"]
                            and item["iccParametricFunctionType"] is None
                        )
                        for item in success_results
                    )
                ),
                "iccCurveTypeIdentitySuccessCases": sum(
                    item["iccTransferCurveKind"] == "curveIdentity"
                    for item in success_results
                ),
                "iccCurveTypeIdentityContractPassed": (
                    sum(
                        item["iccTransferCurveKind"] == "curveIdentity"
                        for item in success_results
                    ) == 3
                    and all(
                        item["iccTransferCurveKind"] != "curveIdentity"
                        or (
                            item["iccMatrixTRCConversionExact"]
                            and item["littleCMSWithinOneCode"]
                            and item["iccParametricFunctionType"] is None
                        )
                        for item in success_results
                    )
                ),
                "iccCurveTypeSampledSuccessCases": sum(
                    item["iccTransferCurveKind"] == "curveSampled"
                    for item in success_results
                ),
                "iccCurveTypeSampledContractPassed": (
                    sum(
                        item["iccTransferCurveKind"] == "curveSampled"
                        for item in success_results
                    ) == 6
                    and sum(
                        item["iccTransferCurveKind"] == "curveSampled"
                        and not item["iccLargeSampledCardinality"]
                        for item in success_results
                    ) == 3
                    and all(
                        item["iccTransferCurveKind"] != "curveSampled"
                        or item["iccLargeSampledCardinality"]
                        or (
                            item["iccMatrixTRCConversionExact"]
                            and item["littleCMSWithinOneCode"]
                            and item["iccParametricFunctionType"] is None
                        )
                        for item in success_results
                    )
                ),
                "iccLargeSampledCardinalitySuccessCases": sum(
                    item["iccLargeSampledCardinality"] for item in success_results
                ),
                "iccLargeSampledCardinalityContractPassed": (
                    sum(item["iccLargeSampledCardinality"] for item in success_results) == 3
                    and all(
                        not item["iccLargeSampledCardinality"]
                        or (
                            item["iccMatrixTRCConversionExact"]
                            and item["iccTransferCurveKind"] == "curveSampled"
                            and item["iccParametricFunctionType"] is None
                            and item["iccLargeSampledNodeCount"] == 1_025
                            and item["iccProfileByteCount"] == 2_360
                            and item["resolvedMaximumMetadataBytes"] == 4_096
                            and item["littleCMSObservationAvailable"]
                            and item["littleCMSRequiresOneCode"] is False
                        )
                        for item in success_results
                    )
                ),
                "iccLargeSampledCardinalityLittleCMSMaximumRGBCodeDifference": max(
                    (
                        item["littleCMSMaximumRGBCodeDifference"]
                        for item in success_results
                        if item["iccLargeSampledCardinality"]
                    ),
                    default=0,
                ),
                "iccTransferCurveKindCoverageContractPassed": sorted(
                    {
                        item["iccTransferCurveKind"]
                        for item in success_results
                        if item["iccTransferCurveKind"] is not None
                    }
                ) == ["curveGamma", "curveIdentity", "curveSampled", "parametric"],
                "littleCMSObservationContractPassed": all(
                    item["littleCMSObservationAvailable"] for item in success_results
                ),
                "littleCMSICCConversionContractPassed": all(
                    not item["littleCMSRequiresOneCode"] or item["littleCMSWithinOneCode"]
                    for item in success_results
                ),
                "hdrStaticMetadataContractPassed": all(
                    item["hdrStaticMetadataExact"] for item in success_results
                ),
                "significantBitsMetadataContractPassed": all(
                    item["significantBitsMetadataExact"] for item in success_results
                ),
                "referenceSampleRecoveryContractPassed": all(
                    item["referenceSamplesRecoveredExact"] for item in success_results
                ),
                "lowOrderVariationContractPassed": all(
                    item["lowOrderVariationVerified"] for item in success_results
                ),
                "highByteNearMissContractPassed": all(
                    not item.get("highByteNearMiss") or item["highByteNearMissVerified"]
                    for item in success_results
                ),
                "adam7ContractPassed": all(
                    item.get("interlace", 0) != 1
                    or (
                        item["externalRGBA16BigEndianExact"]
                        and item["canonicalLittleEndianExact"]
                        and item["libpng"].get("sourceInterlaceType") == 1
                        and item["libpng"].get("interlacePasses") == 7
                    )
                    for item in success_results
                ),
                "hostileContractPassed": all(item["failedClosed"] for item in hostile_results),
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        try:
            display_output_path = output_path.relative_to(ROOT)
        except ValueError:
            display_output_path = output_path
        print(
            "Independent PNG16 conformance captured: "
            f"source={before_hash} output={display_output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
