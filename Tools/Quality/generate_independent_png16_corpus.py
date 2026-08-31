#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
ICC_D50_XYZ = bytes((0x00, 0x00, 0xF6, 0xD6, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0xD3, 0x2D))


def deterministic_icc_profile(color_space: bytes) -> bytes:
    if color_space not in (b"RGB ", b"GRAY"):
        raise ValueError("unsupported deterministic ICC color space")
    # A cprt text tag keeps the profile structurally meaningful while also preventing the whole
    # compressed iCCP chunk from collapsing below libpng's minimum streaming-read envelope.
    text_payload = bytes(32 + ((index * 73 + index * index * 19 + 31) % 95) for index in range(256))
    tag_data = b"text" + bytes(4) + text_payload + b"\x00"
    tag_offset = 144  # 132-byte header + one 12-byte tag-table entry.
    padded_tag_size = (len(tag_data) + 3) & ~3
    profile = bytearray(tag_offset + padded_tag_size)
    profile[0:4] = struct.pack(">I", len(profile))
    profile[8:12] = bytes((2, 0x10, 0, 0))
    profile[12:16] = b"mntr"
    profile[16:20] = color_space
    profile[20:24] = b"XYZ "
    profile[36:40] = b"acsp"
    profile[64:68] = struct.pack(">I", 0)
    profile[68:80] = ICC_D50_XYZ
    profile[80:84] = b"IMGC"
    profile[128:132] = struct.pack(">I", 1)
    profile[132:136] = b"cprt"
    profile[136:140] = struct.pack(">I", tag_offset)
    profile[140:144] = struct.pack(">I", len(tag_data))
    profile[tag_offset : tag_offset + len(tag_data)] = tag_data
    return bytes(profile)


def with_icc_profile_class(profile: bytes, profile_class: bytes) -> bytes:
    if len(profile) < 40 or profile[36:40] != b"acsp":
        raise ValueError("cannot change class on malformed deterministic ICC profile")
    if len(profile_class) != 4:
        raise ValueError("ICC profile class must be exactly four bytes")
    updated = bytearray(profile)
    updated[12:16] = profile_class
    return bytes(updated)


def deterministic_matrix_trc_icc_profile(
    *,
    red_xyz: tuple[int, int, int],
    green_xyz: tuple[int, int, int],
    blue_xyz: tuple[int, int, int],
    parametric_function: int | None = None,
    trc_values: tuple[int, ...] = (),
    curve_type_values: tuple[int, ...] | None = None,
    channel_parametric_curves: tuple[
        tuple[int, tuple[int, ...]],
        tuple[int, tuple[int, ...]],
        tuple[int, tuple[int, ...]],
    ] | None = None,
    channel_curves: tuple[
        tuple[str, int | None, tuple[int, ...]],
        tuple[str, int | None, tuple[int, ...]],
        tuple[str, int | None, tuple[int, ...]],
    ] | None = None,
) -> bytes:
    def s15fixed16(raw: int) -> bytes:
        return struct.pack(">i", raw)

    def xyz_type(x: int, y: int, z: int) -> bytes:
        return b"XYZ " + bytes(4) + s15fixed16(x) + s15fixed16(y) + s15fixed16(z)

    def parametric_curve(function: int, values: tuple[int, ...]) -> bytes:
        expected_count = {0: 1, 1: 3, 2: 4, 3: 5, 4: 7}.get(function)
        if expected_count is None or len(values) != expected_count:
            raise ValueError("unsupported deterministic ICC parametric curve")
        return (
            b"para"
            + bytes(4)
            + struct.pack(">HH", function, 0)
            + b"".join(s15fixed16(value) for value in values)
        )

    def curve_type(values: tuple[int, ...]) -> bytes:
        if any(not 0 <= value <= 0xFFFF for value in values):
            raise ValueError("curveType sample is outside UInt16 range")
        return (
            b"curv"
            + bytes(4)
            + struct.pack(">I", len(values))
            + b"".join(struct.pack(">H", value) for value in values)
        )

    if channel_curves is not None:
        if len(channel_curves) != 3:
            raise ValueError("per-channel ICC profile requires exactly three channel TRCs")
        if (
            channel_parametric_curves is not None
            or parametric_function is not None
            or curve_type_values is not None
            or trc_values
        ):
            raise ValueError("per-channel ICC profile cannot also supply one shared or legacy channel TRC")
        payloads: list[bytes] = []
        for encoding, function, values in channel_curves:
            if encoding == "parametric" and function is not None:
                payloads.append(parametric_curve(function, values))
            elif encoding == "curve" and function is None:
                payloads.append(curve_type(values))
            else:
                raise ValueError("unsupported per-channel ICC TRC encoding")
        trc_payloads = tuple(payloads)
    elif channel_parametric_curves is not None:
        if parametric_function is not None or curve_type_values is not None or trc_values:
            raise ValueError("per-channel ICC profile cannot also supply one shared TRC")
        trc_payloads = tuple(
            parametric_curve(function, values)
            for function, values in channel_parametric_curves
        )
    else:
        if (parametric_function is None) == (curve_type_values is None):
            raise ValueError("deterministic ICC profile requires exactly one TRC encoding")
        if curve_type_values is None:
            assert parametric_function is not None
            shared_trc = parametric_curve(parametric_function, trc_values)
        else:
            if trc_values:
                raise ValueError("curveType profile cannot also supply parametric values")
            shared_trc = curve_type(curve_type_values)
        trc_payloads = (shared_trc, shared_trc, shared_trc)

    header = bytearray(128)
    header[8:12] = struct.pack(">I", 0x02100000)
    header[12:16] = b"mntr"
    header[16:20] = b"RGB "
    header[20:24] = b"XYZ "
    header[24:36] = struct.pack(">6H", 2026, 8, 14, 0, 0, 0)
    header[36:40] = b"acsp"
    header[64:68] = struct.pack(">I", 1)
    header[68:80] = xyz_type(0xF6D6, 0x10000, 0xD32D)[8:20]
    header[80:84] = b"IMGC"

    payloads = {
        "wtpt": xyz_type(0xF6D6, 0x10000, 0xD32D),
        "rXYZ": xyz_type(*red_xyz),
        "gXYZ": xyz_type(*green_xyz),
        "bXYZ": xyz_type(*blue_xyz),
        "rTRC": trc_payloads[0],
        "gTRC": trc_payloads[1],
        "bTRC": trc_payloads[2],
    }
    signatures = ("wtpt", "rXYZ", "gXYZ", "bXYZ", "rTRC", "gTRC", "bTRC")
    table_end = 132 + 12 * len(signatures)
    payload_start = (table_end + 3) & ~3
    body = bytearray(payload_start - table_end)
    payload_locations: dict[object, tuple[int, int]] = {}
    entries: list[tuple[bytes, int, int]] = []
    for signature in signatures:
        payload = payloads[signature]
        location_key: object = (
            ("TRC", payload) if signature.endswith("TRC") else ("TAG", signature)
        )
        location = payload_locations.get(location_key)
        if location is None:
            offset = payload_start + len(body)
            location = (offset, len(payload))
            payload_locations[location_key] = location
            body += payload
            body += bytes((-len(body)) % 4)
        entries.append((signature.encode("ascii"), location[0], location[1]))

    profile = bytearray(header)
    profile += struct.pack(">I", len(entries))
    for signature, offset, size in entries:
        profile += signature + struct.pack(">II", offset, size)
    profile += body
    profile[0:4] = struct.pack(">I", len(profile))
    return bytes(profile)


def deterministic_display_p3_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(33_759, 15_807, -69),
        green_xyz=(19_135, 45_367, 2_745),
        blue_xyz=(10_296, 4_363, 51_385),
        parametric_function=3,
        trc_values=(157_286, 62_119, 3_417, 5_072, 2_651),
    )


def deterministic_srgb_d50_gamma22_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911),
        green_xyz=(25_238, 46_986, 6_362),
        blue_xyz=(9_376, 3_973, 46_788),
        parametric_function=3,
        trc_values=(144_179, 65_536, 0, 0, 0),
    )


def deterministic_white_mismatch_gamma22_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_676, 14_578, 911),
        green_xyz=(25_238, 46_986, 6_362),
        blue_xyz=(9_376, 3_973, 46_788),
        parametric_function=3,
        trc_values=(144_179, 65_536, 0, 0, 0),
    )


def deterministic_srgb_d50_gamma18_type0_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911),
        green_xyz=(25_238, 46_986, 6_362),
        blue_xyz=(9_376, 3_973, 46_788),
        parametric_function=0,
        trc_values=(117_965,),
    )


def deterministic_srgb_d50_gamma22_type0_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911),
        green_xyz=(25_238, 46_986, 6_362),
        blue_xyz=(9_376, 3_973, 46_788),
        parametric_function=0,
        trc_values=(144_179,),
    )


def deterministic_srgb_d50_zero_gamma_type0_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911),
        green_xyz=(25_238, 46_986, 6_362),
        blue_xyz=(9_376, 3_973, 46_788),
        parametric_function=0,
        trc_values=(0,),
    )


def deterministic_srgb_d50_type1_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911),
        green_xyz=(25_238, 46_986, 6_362),
        blue_xyz=(9_376, 3_973, 46_788),
        parametric_function=1,
        trc_values=(65_536, 98_304, -32_768),
    )


def deterministic_srgb_d50_type2_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911),
        green_xyz=(25_238, 46_986, 6_362),
        blue_xyz=(9_376, 3_973, 46_788),
        parametric_function=2,
        trc_values=(65_536, 65_536, -32_768, 32_768),
    )


def deterministic_srgb_d50_type4_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911),
        green_xyz=(25_238, 46_986, 6_362),
        blue_xyz=(9_376, 3_973, 46_788),
        parametric_function=4,
        trc_values=(65_536, 81_920, -32_768, 49_152, 32_768, 16_384, 0),
    )


def deterministic_srgb_d50_curve_gamma18_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911),
        green_xyz=(25_238, 46_986, 6_362),
        blue_xyz=(9_376, 3_973, 46_788),
        curve_type_values=(461,),
    )


def deterministic_srgb_d50_curve_gamma22_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911),
        green_xyz=(25_238, 46_986, 6_362),
        blue_xyz=(9_376, 3_973, 46_788),
        curve_type_values=(563,),
    )


def deterministic_curve_zero_gamma_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911), green_xyz=(25_238, 46_986, 6_362), blue_xyz=(9_376, 3_973, 46_788),
        curve_type_values=(0,),
    )


def deterministic_curve_identity_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911), green_xyz=(25_238, 46_986, 6_362), blue_xyz=(9_376, 3_973, 46_788),
        curve_type_values=(),
    )


def deterministic_curve_sampled_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911), green_xyz=(25_238, 46_986, 6_362), blue_xyz=(9_376, 3_973, 46_788),
        curve_type_values=(0, 4_096, 16_384, 36_863, 0xFFFF),
    )


def deterministic_curve_sampled_1025_matrix_trc_icc_profile() -> bytes:
    denominator = 1_024 * 1_024
    samples = tuple(
        (index * index * 65_535 + denominator // 2) // denominator
        for index in range(1_025)
    )
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911),
        green_xyz=(25_238, 46_986, 6_362),
        blue_xyz=(9_376, 3_973, 46_788),
        curve_type_values=samples,
    )


def deterministic_curve_sampled_1025_count_mismatch_matrix_trc_icc_profile() -> bytes:
    profile = bytearray(deterministic_curve_sampled_1025_matrix_trc_icc_profile())
    curve_offset = profile.find(b"curv")
    if curve_offset < 0:
        raise ValueError("deterministic large sampled profile is missing curveType payload")
    profile[curve_offset + 8 : curve_offset + 12] = struct.pack(">I", 1_026)
    return bytes(profile)


def deterministic_curve_nonnormalized_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911), green_xyz=(25_238, 46_986, 6_362), blue_xyz=(9_376, 3_973, 46_788),
        curve_type_values=(1, 0xFFFF),
    )


def deterministic_curve_nonmonotone_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911), green_xyz=(25_238, 46_986, 6_362), blue_xyz=(9_376, 3_973, 46_788),
        curve_type_values=(0, 40_000, 30_000, 0xFFFF),
    )


def deterministic_type1_nonpositive_a_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911), green_xyz=(25_238, 46_986, 6_362), blue_xyz=(9_376, 3_973, 46_788),
        parametric_function=1, trc_values=(65_536, 0, 0),
    )


def deterministic_type2_nonnormalized_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911), green_xyz=(25_238, 46_986, 6_362), blue_xyz=(9_376, 3_973, 46_788),
        parametric_function=2, trc_values=(65_536, 65_536, -32_768, 16_384),
    )


def deterministic_type4_negative_discontinuity_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911), green_xyz=(25_238, 46_986, 6_362), blue_xyz=(9_376, 3_973, 46_788),
        parametric_function=4, trc_values=(65_536, 98_304, -32_768, 49_152, 32_768, 0, 0),
    )


def deterministic_per_channel_type0_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911),
        green_xyz=(25_238, 46_986, 6_362),
        blue_xyz=(9_376, 3_973, 46_788),
        channel_parametric_curves=(
            (0, (117_965,)),
            (0, (131_072,)),
            (0, (144_179,)),
        ),
    )


def deterministic_per_channel_parametric_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911),
        green_xyz=(25_238, 46_986, 6_362),
        blue_xyz=(9_376, 3_973, 46_788),
        channel_parametric_curves=(
            (1, (65_536, 98_304, -32_768)),
            (3, (144_179, 65_536, 0, 0, 0)),
            (4, (65_536, 81_920, -32_768, 49_152, 32_768, 16_384, 0)),
        ),
    )


def deterministic_per_channel_invalid_parametric_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911),
        green_xyz=(25_238, 46_986, 6_362),
        blue_xyz=(9_376, 3_973, 46_788),
        channel_parametric_curves=(
            (1, (65_536, 98_304, -32_768)),
            (1, (65_536, 0, 0)),
            (4, (65_536, 81_920, -32_768, 49_152, 32_768, 16_384, 0)),
        ),
    )


def deterministic_per_channel_mixed_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911),
        green_xyz=(25_238, 46_986, 6_362),
        blue_xyz=(9_376, 3_973, 46_788),
        channel_curves=(
            ("curve", None, (0, 8_192, 24_576, 49_152, 65_535)),
            ("parametric", 3, (144_179, 65_536, 0, 0, 0)),
            ("curve", None, (461,)),
        ),
    )


def deterministic_per_channel_invalid_mixed_matrix_trc_icc_profile() -> bytes:
    return deterministic_matrix_trc_icc_profile(
        red_xyz=(28_576, 14_578, 911),
        green_xyz=(25_238, 46_986, 6_362),
        blue_xyz=(9_376, 3_973, 46_788),
        channel_curves=(
            ("curve", None, (0, 8_192, 24_576, 49_152, 65_535)),
            ("parametric", 3, (144_179, 65_536, 0, 0, 0)),
            ("curve", None, (0,)),
        ),
    )


def mastering_display_payload(specification: dict[str, object]) -> bytes:
    required_pairs = ("red", "green", "blue", "white")
    values: list[int] = []
    for key in required_pairs:
        pair = specification.get(key)
        if (
            not isinstance(pair, list)
            or len(pair) != 2
            or any(not isinstance(value, int) or not 0 <= value <= 0xFFFF for value in pair)
        ):
            raise ValueError(f"invalid mDCV {key} chromaticity")
        values.extend(int(value) for value in pair)
    maximum = specification.get("maximumLuminanceScaledBy10000")
    minimum = specification.get("minimumLuminanceScaledBy10000")
    if (
        not isinstance(maximum, int)
        or not isinstance(minimum, int)
        or not 0 <= maximum <= 0x7FFF_FFFF
        or not 0 <= minimum <= 0x7FFF_FFFF
    ):
        raise ValueError("mDCV luminance is outside PNG 31-bit integer range")
    return struct.pack(">HHHHHHHHII", *values, maximum, minimum)


def content_light_level_payload(specification: dict[str, object]) -> bytes:
    maximum_content = specification.get("maximumContentLightLevelScaledBy10000")
    maximum_frame_average = specification.get("maximumFrameAverageLightLevelScaledBy10000")
    if (
        not isinstance(maximum_content, int)
        or not isinstance(maximum_frame_average, int)
        or not 0 <= maximum_content <= 0x7FFF_FFFF
        or not 0 <= maximum_frame_average <= 0x7FFF_FFFF
    ):
        raise ValueError("cLLI value is outside PNG 31-bit integer range")
    return struct.pack(">II", maximum_content, maximum_frame_average)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def chunk(kind: bytes, payload: bytes) -> bytes:
    assert len(kind) == 4
    crc = zlib.crc32(kind)
    crc = zlib.crc32(payload, crc) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", crc)


def paeth(left: int, above: int, upper_left: int) -> int:
    p = left + above - upper_left
    pa = abs(p - left)
    pb = abs(p - above)
    pc = abs(p - upper_left)
    if pa <= pb and pa <= pc:
        return left
    if pb <= pc:
        return above
    return upper_left


def filter_row(raw: bytes, previous: bytes, bpp: int, kind: int) -> bytes:
    assert len(raw) == len(previous)
    assert kind in range(5)
    out = bytearray(len(raw))
    for index, value in enumerate(raw):
        left = raw[index - bpp] if index >= bpp else 0
        above = previous[index]
        upper_left = previous[index - bpp] if index >= bpp else 0
        if kind == 0:
            predictor = 0
        elif kind == 1:
            predictor = left
        elif kind == 2:
            predictor = above
        elif kind == 3:
            predictor = (left + above) >> 1
        else:
            predictor = paeth(left, above, upper_left)
        out[index] = (value - predictor) & 0xFF
    return bytes(out)


def source_rgba16be(width: int, height: int, seed: int) -> bytes:
    alpha_cycle = (0, 1, 0x0100, 0x1234, 0x7FFF, 0x8000, 0xBEEF, 0xFFFE, 0xFFFF)
    result = bytearray()
    for y in range(height):
        for x in range(width):
            red = (seed * 257 + x * 8111 + y * 1237 + 0x1234) & 0xFFFF
            green = (seed * 509 + x * 2911 + y * 9191 + 0xABCD) & 0xFFFF
            blue = (seed * 997 + x * 6173 + y * 4021 + 0x00FF) & 0xFFFF
            alpha = alpha_cycle[(x + y * 3 + seed) % len(alpha_cycle)]
            result += struct.pack(">HHHH", red, green, blue, alpha)
    return bytes(result)


def source_rgb16be(width: int, height: int, seed: int) -> bytes:
    rgba = source_rgba16be(width, height, seed)
    result = bytearray()
    for offset in range(0, len(rgba), 8):
        result += rgba[offset : offset + 6]
    return bytes(result)


def source_p3_in_gamut_rgba16be(width: int, height: int, seed: int) -> bytes:
    rgb_cycle = (
        (0, 0, 0),
        (0xFFFF, 0xFFFF, 0xFFFF),
        (32768, 32768, 32768),
        (40000, 30000, 20000),
        (50000, 40000, 30000),
        (32000, 30000, 28000),
        (25000, 27000, 26000),
        (10000, 12000, 11000),
        (56000, 54000, 52000),
        (30000, 40000, 35000),
    )
    alpha_cycle = (0, 1, 0x1234, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF)
    result = bytearray()
    for index in range(width * height):
        red, green, blue = rgb_cycle[(index + seed) % len(rgb_cycle)]
        alpha = alpha_cycle[(index * 3 + seed) % len(alpha_cycle)]
        result += struct.pack(">HHHH", red, green, blue, alpha)
    return bytes(result)


def source_p3_in_gamut_rgb16be(width: int, height: int, seed: int) -> bytes:
    rgba = source_p3_in_gamut_rgba16be(width, height, seed)
    result = bytearray()
    for offset in range(0, len(rgba), 8):
        result += rgba[offset : offset + 6]
    return bytes(result)


def source_real_epson3170_in_gamut_rgba16be(width: int, height: int, seed: int) -> bytes:
    # Rounded UInt16 device samples from ten measured patches in ColorReference Testscan Set 1,
    # extracted by ArgyllCMS scanin from the Epson Perfection 3170 no-color-correction scan.
    # Every sample is independently verified by the capture oracle to remain inside target sRGB gamut.
    rgb_cycle = (
        (9_828, 7_002, 7_479),    # A01
        (30_612, 9_064, 10_217),  # A08
        (34_658, 30_573, 31_366), # A09
        (22_903, 16_873, 16_050), # B05
        (33_057, 10_314, 7_099),  # B08
        (30_823, 25_201, 22_161), # C05
        (25_730, 23_322, 19_899), # D05
        (37_044, 45_358, 32_749), # E18
        (28_424, 40_663, 22_351), # H18
        (17_571, 19_412, 39_433), # J08
    )
    alpha_cycle = (0, 1, 0x1234, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF, 0x3456, 0xABCD, 0x2222)
    result = bytearray()
    for index in range(width * height):
        red, green, blue = rgb_cycle[(index + seed) % len(rgb_cycle)]
        alpha = alpha_cycle[(index * 3 + seed) % len(alpha_cycle)]
        result += struct.pack(">HHHH", red, green, blue, alpha)
    return bytes(result)


def source_real_epson3170_in_gamut_rgb16be(width: int, height: int, seed: int) -> bytes:
    rgba = source_real_epson3170_in_gamut_rgba16be(width, height, seed)
    result = bytearray()
    for offset in range(0, len(rgba), 8):
        result += rgba[offset : offset + 6]
    return bytes(result)


def source_grayscale16be(width: int, height: int, seed: int) -> bytes:
    result = bytearray()
    for y in range(height):
        for x in range(width):
            gray = (seed * 811 + x * 2053 + y * 4093 + 0x1357) & 0xFFFF
            result += struct.pack(">H", gray)
    return bytes(result)


def source_grayscale_alpha16be(width: int, height: int, seed: int) -> bytes:
    alpha_cycle = (0, 1, 0x0100, 0x1234, 0x7FFF, 0x8000, 0xBEEF, 0xFFFE, 0xFFFF)
    gray = source_grayscale16be(width, height, seed)
    result = bytearray()
    pixel = 0
    for offset in range(0, len(gray), 2):
        alpha = alpha_cycle[(pixel * 3 + seed) % len(alpha_cycle)]
        result += gray[offset : offset + 2]
        result += struct.pack(">H", alpha)
        pixel += 1
    return bytes(result)


def reference_samples_u16be(
    stored_source: bytes,
    source_bytes_per_pixel: int,
    significant_bits: list[int],
) -> tuple[bytes, list[bool]]:
    channel_count = source_bytes_per_pixel // 2
    if source_bytes_per_pixel not in (2, 4, 6, 8) or len(significant_bits) != channel_count:
        raise ValueError("significant-bit metadata does not match source channel count")
    if len(stored_source) % source_bytes_per_pixel:
        raise ValueError("stored source is not pixel-aligned")
    reference = bytearray()
    low_order_variation = [False] * channel_count
    for pixel_offset in range(0, len(stored_source), source_bytes_per_pixel):
        for channel in range(channel_count):
            significant = significant_bits[channel]
            if significant <= 0 or significant > 16:
                raise ValueError("significant bits outside 1...16")
            sample_offset = pixel_offset + channel * 2
            stored = int.from_bytes(stored_source[sample_offset : sample_offset + 2], "big")
            shift = 16 - significant
            reference += (stored >> shift).to_bytes(2, "big")
            if shift > 0 and stored & ((1 << shift) - 1):
                low_order_variation[channel] = True
    return bytes(reference), low_order_variation


def source_rgba8(width: int, height: int, seed: int) -> bytes:
    result = bytearray()
    for y in range(height):
        for x in range(width):
            result += bytes(
                (
                    (seed + x * 37 + y * 11) & 0xFF,
                    (seed * 3 + x * 19 + y * 53) & 0xFF,
                    (seed * 7 + x * 71 + y * 23) & 0xFF,
                    (seed * 13 + x * 17 + y * 29) & 0xFF,
                )
            )
    return bytes(result)


def filtered_rows(source: bytes, width: int, height: int, bpp: int, filters: list[int]) -> bytes:
    row_bytes = width * bpp
    assert len(source) == row_bytes * height
    previous = bytes(row_bytes)
    result = bytearray()
    for y in range(height):
        raw = source[y * row_bytes : (y + 1) * row_bytes]
        filter_kind = filters[y % len(filters)]
        result.append(filter_kind)
        result += filter_row(raw, previous, bpp, filter_kind)
        previous = raw
    return bytes(result)


ADAM7_GEOMETRY = (
    (0, 0, 8, 8),
    (4, 0, 8, 8),
    (0, 4, 4, 8),
    (2, 0, 4, 4),
    (0, 2, 2, 4),
    (1, 0, 2, 2),
    (0, 1, 1, 2),
)


def adam7_sample_count(full_count: int, start: int, step: int) -> int:
    if full_count <= start:
        return 0
    return (full_count - start + step - 1) // step


def filtered_adam7_samples(
    source: bytes,
    width: int,
    height: int,
    bpp: int,
    filters: list[int],
) -> bytes:
    if width <= 0 or height <= 0 or bpp <= 0 or len(source) != width * height * bpp:
        raise ValueError("invalid Adam7 source geometry")
    if not filters or any(value not in range(5) for value in filters):
        raise ValueError("invalid Adam7 filter sequence")
    result = bytearray()
    for pass_index, (x_start, y_start, x_step, y_step) in enumerate(ADAM7_GEOMETRY):
        pass_width = adam7_sample_count(width, x_start, x_step)
        pass_height = adam7_sample_count(height, y_start, y_step)
        if pass_width == 0 or pass_height == 0:
            continue
        row_bytes = pass_width * bpp
        previous = bytes(row_bytes)
        for pass_row in range(pass_height):
            y = y_start + pass_row * y_step
            raw = bytearray(row_bytes)
            for pass_column in range(pass_width):
                x = x_start + pass_column * x_step
                source_offset = (y * width + x) * bpp
                row_offset = pass_column * bpp
                raw[row_offset : row_offset + bpp] = source[source_offset : source_offset + bpp]
            filter_kind = filters[(pass_index + pass_row) % len(filters)]
            result.append(filter_kind)
            result += filter_row(bytes(raw), previous, bpp, filter_kind)
            previous = bytes(raw)
    return bytes(result)


def png_from_filtered(
    *,
    width: int,
    height: int,
    bit_depth: int,
    color_type: int,
    filtered: bytes,
    split_idat: int,
    include_srgb: bool,
    interlace: int = 0,
    include_gamma: bool = False,
    significant_bits: bytes | None = None,
    transparency: bytes | None = None,
    icc_profile: bytes | None = None,
    cicp: bytes | None = None,
    mdcv: bytes | None = None,
    clli: bytes | None = None,
) -> bytes:
    if include_srgb and icc_profile is not None:
        raise ValueError("sRGB and iCCP are mutually exclusive")
    if cicp is not None and len(cicp) != 4:
        raise ValueError("cICP payload must contain four bytes")
    if mdcv is not None and len(mdcv) != 24:
        raise ValueError("mDCV payload must contain 24 bytes")
    if clli is not None and len(clli) != 8:
        raise ValueError("cLLI payload must contain eight bytes")
    ihdr = struct.pack(">IIBBBBB", width, height, bit_depth, color_type, 0, 0, interlace)
    result = bytearray(PNG_SIGNATURE)
    result += chunk(b"IHDR", ihdr)
    if cicp is not None:
        result += chunk(b"cICP", cicp)
    if include_srgb:
        result += chunk(b"sRGB", b"\x00")
    elif icc_profile is not None:
        result += chunk(b"iCCP", b"ImageCraft RGB\x00\x00" + zlib.compress(icc_profile, level=6))
    if mdcv is not None:
        result += chunk(b"mDCV", mdcv)
    if clli is not None:
        result += chunk(b"cLLI", clli)
    if include_gamma:
        result += chunk(b"gAMA", struct.pack(">I", 45455))
    if significant_bits is not None:
        result += chunk(b"sBIT", significant_bits)
    if transparency is not None:
        result += chunk(b"tRNS", transparency)
    compressed = zlib.compress(filtered, level=6)
    pieces = min(max(1, split_idat), max(1, len(compressed)))
    for piece in range(pieces):
        lower = len(compressed) * piece // pieces
        upper = len(compressed) * (piece + 1) // pieces
        result += chunk(b"IDAT", compressed[lower:upper])
    result += chunk(b"IEND", b"")
    return bytes(result)


def rgba16_png(
    width: int,
    height: int,
    seed: int,
    filters: list[int],
    split_idat: int,
    *,
    include_srgb: bool = True,
    interlace: int = 0,
    truncate_filtered_tail: int = 0,
    include_gamma: bool = False,
    significant_bits: bytes | None = None,
    transparency: bytes | None = None,
    icc_profile: bytes | None = None,
    cicp: bytes | None = None,
    mdcv: bytes | None = None,
    clli: bytes | None = None,
    source_override: bytes | None = None,
) -> tuple[bytes, bytes]:
    source = source_override if source_override is not None else source_rgba16be(width, height, seed)
    if len(source) != width * height * 8:
        raise ValueError("RGBA16 source override byte count mismatch")
    if interlace == 0:
        filtered = filtered_rows(source, width, height, 8, filters)
    elif interlace == 1:
        filtered = filtered_adam7_samples(source, width, height, 8, filters)
    else:
        raise ValueError("PNG interlace method must be 0 or 1")
    if truncate_filtered_tail:
        if truncate_filtered_tail > len(filtered):
            raise ValueError("filtered tail truncation exceeds payload")
        filtered = filtered[:-truncate_filtered_tail]
    return (
        png_from_filtered(
            width=width,
            height=height,
            bit_depth=16,
            color_type=6,
            filtered=filtered,
            split_idat=split_idat,
            include_srgb=include_srgb,
            interlace=interlace,
            include_gamma=include_gamma,
            significant_bits=significant_bits,
            transparency=transparency,
            icc_profile=icc_profile,
            cicp=cicp,
            mdcv=mdcv,
            clli=clli,
        ),
        source,
    )


def rgb16_png(
    width: int,
    height: int,
    seed: int,
    filters: list[int],
    split_idat: int,
    *,
    include_srgb: bool = True,
    transparent_pixel_index: int | None = None,
    high_byte_near_miss: bool = False,
    transparency_payload_override: bytes | None = None,
    significant_bits: bytes | None = None,
    interlace: int = 0,
    icc_profile: bytes | None = None,
    cicp: bytes | None = None,
    mdcv: bytes | None = None,
    clli: bytes | None = None,
    source_override: bytes | None = None,
) -> tuple[bytes, bytes, tuple[int, int, int] | None]:
    source = bytearray(source_override if source_override is not None else source_rgb16be(width, height, seed))
    if len(source) != width * height * 6:
        raise ValueError("RGB16 source override byte count mismatch")
    pixel_count = width * height
    transparent: tuple[int, int, int] | None = None
    if transparent_pixel_index is not None:
        if transparent_pixel_index < 0 or transparent_pixel_index >= pixel_count:
            raise ValueError("transparentPixelIndex outside source")
        offset = transparent_pixel_index * 6
        transparent = struct.unpack(">HHH", source[offset : offset + 6])
        if high_byte_near_miss:
            if pixel_count < 2:
                raise ValueError("high-byte near miss requires at least two pixels")
            near_index = 1 if transparent_pixel_index != 1 else 0
            near_offset = near_index * 6
            near_red = transparent[0] ^ 0x0001
            source[near_offset : near_offset + 6] = struct.pack(
                ">HHH", near_red, transparent[1], transparent[2]
            )
    if interlace == 0:
        filtered = filtered_rows(bytes(source), width, height, 6, filters)
    elif interlace == 1:
        filtered = filtered_adam7_samples(bytes(source), width, height, 6, filters)
    else:
        raise ValueError("PNG interlace method must be 0 or 1")
    if transparency_payload_override is not None:
        transparency = transparency_payload_override
    elif transparent is not None:
        transparency = struct.pack(">HHH", *transparent)
    else:
        transparency = None
    png = png_from_filtered(
        width=width,
        height=height,
        bit_depth=16,
        color_type=2,
        filtered=filtered,
        split_idat=split_idat,
        include_srgb=include_srgb,
        interlace=interlace,
        significant_bits=significant_bits,
        transparency=transparency,
        icc_profile=icc_profile,
        cicp=cicp,
        mdcv=mdcv,
        clli=clli,
    )
    return png, bytes(source), transparent


def grayscale16_png(
    width: int,
    height: int,
    seed: int,
    filters: list[int],
    split_idat: int,
    *,
    include_srgb: bool = True,
    transparent_pixel_index: int | None = None,
    high_byte_near_miss: bool = False,
    transparency_payload_override: bytes | None = None,
    significant_bits: bytes | None = None,
    interlace: int = 0,
    icc_profile: bytes | None = None,
    cicp: bytes | None = None,
    mdcv: bytes | None = None,
    clli: bytes | None = None,
) -> tuple[bytes, bytes, int | None]:
    source = bytearray(source_grayscale16be(width, height, seed))
    pixel_count = width * height
    transparent: int | None = None
    if transparent_pixel_index is not None:
        if transparent_pixel_index < 0 or transparent_pixel_index >= pixel_count:
            raise ValueError("transparentPixelIndex outside grayscale source")
        offset = transparent_pixel_index * 2
        transparent = int.from_bytes(source[offset : offset + 2], "big")
        if high_byte_near_miss:
            if pixel_count < 2:
                raise ValueError("high-byte near miss requires at least two pixels")
            near_index = 1 if transparent_pixel_index != 1 else 0
            near_offset = near_index * 2
            source[near_offset : near_offset + 2] = (transparent ^ 0x0001).to_bytes(2, "big")
    if interlace == 0:
        filtered = filtered_rows(bytes(source), width, height, 2, filters)
    elif interlace == 1:
        filtered = filtered_adam7_samples(bytes(source), width, height, 2, filters)
    else:
        raise ValueError("PNG interlace method must be 0 or 1")
    if transparency_payload_override is not None:
        transparency = transparency_payload_override
    else:
        transparency = struct.pack(">H", transparent) if transparent is not None else None
    png = png_from_filtered(
        width=width,
        height=height,
        bit_depth=16,
        color_type=0,
        filtered=filtered,
        split_idat=split_idat,
        include_srgb=include_srgb,
        interlace=interlace,
        significant_bits=significant_bits,
        transparency=transparency,
        icc_profile=icc_profile,
        cicp=cicp,
        mdcv=mdcv,
        clli=clli,
    )
    return png, bytes(source), transparent


def grayscale_alpha16_png(
    width: int,
    height: int,
    seed: int,
    filters: list[int],
    split_idat: int,
    *,
    include_srgb: bool = True,
    significant_bits: bytes | None = None,
    transparency_payload_override: bytes | None = None,
    interlace: int = 0,
) -> tuple[bytes, bytes]:
    source = source_grayscale_alpha16be(width, height, seed)
    if interlace == 0:
        filtered = filtered_rows(source, width, height, 4, filters)
    elif interlace == 1:
        filtered = filtered_adam7_samples(source, width, height, 4, filters)
    else:
        raise ValueError("PNG interlace method must be 0 or 1")
    return (
        png_from_filtered(
            width=width,
            height=height,
            bit_depth=16,
            color_type=4,
            filtered=filtered,
            split_idat=split_idat,
            include_srgb=include_srgb,
            interlace=interlace,
            significant_bits=significant_bits,
            transparency=transparency_payload_override,
        ),
        source,
    )


def rgba8_png(width: int, height: int, seed: int) -> bytes:
    source = source_rgba8(width, height, seed)
    filtered = filtered_rows(source, width, height, 4, [0, 1, 2, 3, 4])
    return png_from_filtered(
        width=width,
        height=height,
        bit_depth=8,
        color_type=6,
        filtered=filtered,
        split_idat=2,
        include_srgb=True,
    )


def corrupt_first_idat_crc(png: bytes) -> bytes:
    data = bytearray(png)
    offset = len(PNG_SIGNATURE)
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        kind = bytes(data[offset + 4 : offset + 8])
        end = offset + 12 + length
        if end > len(data):
            raise ValueError("invalid generated PNG")
        if kind == b"IDAT":
            data[end - 1] ^= 0x01
            return bytes(data)
        offset = end
    raise ValueError("generated PNG has no IDAT")


def write_case(output_dir: Path, case_id: str, png: bytes) -> tuple[str, str]:
    filename = f"{case_id}.png"
    (output_dir / filename).write_bytes(png)
    return filename, sha256_bytes(png)


def validated_real_input_lut_profile(
    profile_path: Path,
    fixture_name: str,
    expected_sha256: str,
) -> bytes:
    fixture_path = profile_path.parent / "fixtures" / fixture_name
    profile = fixture_path.read_bytes()
    if sha256_bytes(profile) != expected_sha256:
        raise ValueError(f"real ICC fixture digest drifted: {fixture_name}")
    if (
        len(profile) < 132
        or profile[12:16] != b"scnr"
        or profile[16:20] != b"RGB "
        or profile[20:24] != b"XYZ "
        or profile[36:40] != b"acsp"
    ):
        raise ValueError(f"real ICC fixture escaped RGB/XYZ input class: {fixture_name}")
    tag_count = int.from_bytes(profile[128:132], "big")
    if tag_count <= 0 or 132 + 12 * tag_count > len(profile):
        raise ValueError(f"real ICC fixture has invalid tag table: {fixture_name}")
    tags: dict[bytes, tuple[int, int]] = {}
    for index in range(tag_count):
        entry = 132 + 12 * index
        signature = profile[entry : entry + 4]
        offset = int.from_bytes(profile[entry + 4 : entry + 8], "big")
        size = int.from_bytes(profile[entry + 8 : entry + 12], "big")
        if signature in tags or size <= 0 or offset + size > len(profile):
            raise ValueError(f"real ICC fixture tag table is invalid or ambiguous: {fixture_name}")
        tags[signature] = (offset, size)
    if any(signature in tags for signature in (b"rXYZ", b"gXYZ", b"bXYZ", b"rTRC", b"gTRC", b"bTRC")):
        raise ValueError(f"real ICC LUT fixture unexpectedly contains matrix/TRC tags: {fixture_name}")
    a2b0 = tags.get(b"A2B0")
    if a2b0 is None or profile[a2b0[0] : a2b0[0] + 4] != b"mAB ":
        raise ValueError(f"real ICC fixture is not the expected mAB input LUT profile: {fixture_name}")
    return profile


def validated_real_input_matrix_profile(
    profile_path: Path,
    fixture_name: str,
    expected_sha256: str,
) -> bytes:
    fixture_path = profile_path.parent / "fixtures" / fixture_name
    profile = fixture_path.read_bytes()
    if sha256_bytes(profile) != expected_sha256:
        raise ValueError(f"real ICC fixture digest drifted: {fixture_name}")
    if (
        len(profile) < 132
        or profile[12:16] != b"scnr"
        or profile[16:20] != b"RGB "
        or profile[20:24] != b"XYZ "
        or profile[36:40] != b"acsp"
    ):
        raise ValueError(f"real ICC matrix fixture escaped RGB/XYZ input class: {fixture_name}")
    tag_count = int.from_bytes(profile[128:132], "big")
    if tag_count <= 0 or 132 + 12 * tag_count > len(profile):
        raise ValueError(f"real ICC matrix fixture has invalid tag table: {fixture_name}")
    tags: dict[bytes, tuple[int, int]] = {}
    for index in range(tag_count):
        entry = 132 + 12 * index
        signature = profile[entry : entry + 4]
        offset = int.from_bytes(profile[entry + 4 : entry + 8], "big")
        size = int.from_bytes(profile[entry + 8 : entry + 12], "big")
        if signature in tags or size <= 0 or offset + size > len(profile):
            raise ValueError(f"real ICC matrix fixture tag table is invalid or ambiguous: {fixture_name}")
        if signature[:3] in (b"A2B", b"B2A", b"D2B", b"B2D"):
            raise ValueError(f"real ICC matrix fixture unexpectedly contains LUT/MPE transform: {fixture_name}")
        tags[signature] = (offset, size)
    required = (b"wtpt", b"rXYZ", b"gXYZ", b"bXYZ", b"rTRC", b"gTRC", b"bTRC")
    if any(signature not in tags for signature in required):
        raise ValueError(f"real ICC matrix fixture lacks required matrix/TRC tag: {fixture_name}")

    def xyz_fixed(signature: bytes) -> tuple[int, int, int]:
        offset, size = tags[signature]
        payload = profile[offset : offset + size]
        if size != 20 or payload[:8] != b"XYZ " + bytes(4):
            raise ValueError(f"real ICC matrix fixture has malformed XYZ tag: {fixture_name}")
        return tuple(
            int.from_bytes(payload[index : index + 4], "big", signed=True)
            for index in (8, 12, 16)
        )  # type: ignore[return-value]

    white = xyz_fixed(b"wtpt")
    red = xyz_fixed(b"rXYZ")
    green = xyz_fixed(b"gXYZ")
    blue = xyz_fixed(b"bXYZ")
    d50 = (63_190, 65_536, 54_061)
    if all(abs(white[index] - d50[index]) <= 2 for index in range(3)):
        raise ValueError(f"real input fixture no longer exercises non-D50 media white: {fixture_name}")
    reconstructed = tuple(red[index] + green[index] + blue[index] for index in range(3))
    if all(abs(reconstructed[index] - white[index]) <= 2 for index in range(3)):
        raise ValueError(f"real input fixture no longer separates media white from device code white: {fixture_name}")
    if white[0] < 0 or white[1] <= 0 or white[2] < 0:
        raise ValueError(f"real input fixture has implausible media white: {fixture_name}")

    for signature in (b"rTRC", b"gTRC", b"bTRC"):
        offset, size = tags[signature]
        payload = profile[offset : offset + size]
        if (
            size != 14
            or payload[:8] != b"curv" + bytes(4)
            or int.from_bytes(payload[8:12], "big") != 1
            or int.from_bytes(payload[12:14], "big") <= 0
        ):
            raise ValueError(f"real input fixture escaped qualified single-gamma TRC shape: {fixture_name}")
    return profile


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    profile = json.loads(args.profile.read_text())
    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    success_manifest: list[dict[str, object]] = []
    for specification in profile["successCases"]:
        case_id = specification["id"]
        width = int(specification["width"])
        height = int(specification["height"])
        seed = int(specification["seed"])
        filters = [int(value) for value in specification["filters"]]
        split_idat = int(specification["splitIDAT"])
        source_format = specification.get("sourceFormat", "rgba16")
        interlace = int(specification.get("interlace", 0))
        significant_bits = (
            [int(value) for value in specification["significantBits"]]
            if "significantBits" in specification
            else None
        )
        significant_bits_payload = bytes(significant_bits) if significant_bits is not None else None
        color_authority = specification.get("colorAuthority", "sRGB")
        if color_authority not in ("sRGB", "rgbICC", "cICP"):
            raise ValueError(f"unsupported colorAuthority: {color_authority}")
        if color_authority in ("rgbICC", "cICP") and source_format not in ("rgb16", "rgba16"):
            raise ValueError("RGB ICC/cICP success cases require RGB16/RGBA16 source")
        request_color_policy = specification.get("requestColorPolicy", "preserveSource")
        if request_color_policy not in ("preserveSource", "convertToSRGB"):
            raise ValueError(f"unsupported requestColorPolicy: {request_color_policy}")
        icc_profile_kind = specification.get("iccProfileKind", "structural")
        icc_profile_class = specification.get("iccProfileClass", "mntr")
        if "iccProfileClass" in specification:
            if color_authority != "rgbICC":
                raise ValueError(f"ICC profile class on non-ICC success case: {case_id}")
            if not isinstance(icc_profile_class, str) or icc_profile_class not in ("mntr", "scnr"):
                raise ValueError(f"unsupported qualified ICC profile class: {icc_profile_class}")
            if request_color_policy != "convertToSRGB" or icc_profile_kind == "structural":
                raise ValueError(f"ICC profile-class qualification escaped matrix/TRC conversion slice: {case_id}")
        if color_authority == "rgbICC":
            if icc_profile_kind == "structural":
                icc_profile = deterministic_icc_profile(b"RGB ")
            elif icc_profile_kind == "displayP3MatrixTRC":
                icc_profile = deterministic_display_p3_matrix_trc_icc_profile()
            elif icc_profile_kind == "sRGBD50Gamma22MatrixTRC":
                icc_profile = deterministic_srgb_d50_gamma22_matrix_trc_icc_profile()
            elif icc_profile_kind == "sRGBD50Gamma18Type0MatrixTRC":
                icc_profile = deterministic_srgb_d50_gamma18_type0_matrix_trc_icc_profile()
            elif icc_profile_kind == "sRGBD50Gamma22Type0MatrixTRC":
                icc_profile = deterministic_srgb_d50_gamma22_type0_matrix_trc_icc_profile()
            elif icc_profile_kind == "sRGBD50Type1MatrixTRC":
                icc_profile = deterministic_srgb_d50_type1_matrix_trc_icc_profile()
            elif icc_profile_kind == "sRGBD50Type2MatrixTRC":
                icc_profile = deterministic_srgb_d50_type2_matrix_trc_icc_profile()
            elif icc_profile_kind == "sRGBD50Type4MatrixTRC":
                icc_profile = deterministic_srgb_d50_type4_matrix_trc_icc_profile()
            elif icc_profile_kind == "sRGBD50CurveGamma18TRC":
                icc_profile = deterministic_srgb_d50_curve_gamma18_matrix_trc_icc_profile()
            elif icc_profile_kind == "sRGBD50CurveGamma22TRC":
                icc_profile = deterministic_srgb_d50_curve_gamma22_matrix_trc_icc_profile()
            elif icc_profile_kind == "sRGBD50CurveIdentityTRC":
                icc_profile = deterministic_curve_identity_matrix_trc_icc_profile()
            elif icc_profile_kind == "sRGBD50CurveSampledTRC":
                icc_profile = deterministic_curve_sampled_matrix_trc_icc_profile()
            elif icc_profile_kind == "sRGBD50CurveSampled1025TRC":
                icc_profile = deterministic_curve_sampled_1025_matrix_trc_icc_profile()
            elif icc_profile_kind == "sRGBD50PerChannelType0TRC":
                icc_profile = deterministic_per_channel_type0_matrix_trc_icc_profile()
            elif icc_profile_kind == "sRGBD50PerChannelParametricTRC":
                icc_profile = deterministic_per_channel_parametric_matrix_trc_icc_profile()
            elif icc_profile_kind == "sRGBD50PerChannelMixedTRC":
                icc_profile = deterministic_per_channel_mixed_matrix_trc_icc_profile()
            elif icc_profile_kind == "realEpson3170GammaMatrix":
                fixture_name = "epson3170-set1-gamma-matrix.icc"
                fixture_sha = "05285b6195383d1f81f996a76a82872197904b62bc2b9dfa55158c411d481697"
                icc_profile = validated_real_input_matrix_profile(
                    args.profile,
                    fixture_name,
                    fixture_sha,
                )
                if (
                    specification.get("realICCFixture") != f"fixtures/{fixture_name}"
                    or specification.get("realICCFixtureSHA256") != fixture_sha
                    or specification.get("realICCProfileByteCount") != len(icc_profile)
                ):
                    raise ValueError(f"real ICC success provenance drifted: {case_id}")
            else:
                raise ValueError(f"unsupported ICC profile kind: {icc_profile_kind}")
            if icc_profile_kind == "realEpson3170GammaMatrix":
                if icc_profile_class != "scnr":
                    raise ValueError(f"real ICC input fixture class override is forbidden: {case_id}")
            else:
                icc_profile = with_icc_profile_class(
                    icc_profile,
                    str(icc_profile_class).encode("ascii"),
                )
        else:
            if "iccProfileKind" in specification:
                raise ValueError(f"ICC profile kind on non-ICC success case: {case_id}")
            if "iccProfileClass" in specification:
                raise ValueError(f"ICC profile class on non-ICC success case: {case_id}")
            icc_profile = None
        cicp_values = specification.get("cicp") if color_authority == "cICP" else None
        if color_authority == "cICP":
            if (
                not isinstance(cicp_values, list)
                or len(cicp_values) != 4
                or any(not isinstance(value, int) or not 0 <= value <= 255 for value in cicp_values)
            ):
                raise ValueError(f"invalid cICP success metadata: {case_id}")
        elif "cicp" in specification:
            raise ValueError(f"cICP metadata on non-cICP success case: {case_id}")
        cicp_payload = bytes(cicp_values) if cicp_values is not None else None
        mastering_display = specification.get("masteringDisplayColorVolume")
        content_light_level = specification.get("contentLightLevel")
        if mastering_display is not None and not isinstance(mastering_display, dict):
            raise ValueError(f"invalid masteringDisplayColorVolume: {case_id}")
        if content_light_level is not None and not isinstance(content_light_level, dict):
            raise ValueError(f"invalid contentLightLevel: {case_id}")
        if mastering_display is not None or content_light_level is not None:
            if color_authority != "cICP" or cicp_values != [9, 16, 0, 1]:
                raise ValueError("HDR static metadata success cases require full-range BT.2100 PQ cICP")
        mdcv_payload = (
            mastering_display_payload(mastering_display)
            if isinstance(mastering_display, dict)
            else None
        )
        clli_payload = (
            content_light_level_payload(content_light_level)
            if isinstance(content_light_level, dict)
            else None
        )
        source_pattern = specification.get("sourcePattern")
        source_override: bytes | None = None
        if source_pattern is not None:
            qualified_source_pattern = False
            if source_pattern == "p3InGamut":
                qualified_source_pattern = (
                    (color_authority == "cICP" and cicp_values == [12, 13, 0, 1])
                    or (
                        color_authority == "rgbICC"
                        and icc_profile_kind == "displayP3MatrixTRC"
                    )
                )
            elif source_pattern == "matrixTRCInGamut":
                qualified_source_pattern = (
                    color_authority == "rgbICC"
                    and icc_profile_kind in (
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
                )
            elif source_pattern == "realEpson3170InGamut":
                qualified_source_pattern = (
                    color_authority == "rgbICC"
                    and icc_profile_kind == "realEpson3170GammaMatrix"
                    and icc_profile_class == "scnr"
                )
            else:
                raise ValueError(f"unsupported sourcePattern: {source_pattern}")
            if (
                not qualified_source_pattern
                or request_color_policy != "convertToSRGB"
                or source_format not in ("rgb16", "rgba16")
                or significant_bits is not None
                or mastering_display is not None
                or content_light_level is not None
            ):
                raise ValueError("conversion source pattern does not match its qualified color authority")
            if source_pattern == "realEpson3170InGamut":
                if source_format == "rgba16":
                    source_override = source_real_epson3170_in_gamut_rgba16be(width, height, seed)
                else:
                    source_override = source_real_epson3170_in_gamut_rgb16be(width, height, seed)
            elif source_format == "rgba16":
                source_override = source_p3_in_gamut_rgba16be(width, height, seed)
            else:
                source_override = source_p3_in_gamut_rgb16be(width, height, seed)
        elif request_color_policy != "preserveSource":
            raise ValueError("convertToSRGB success cases require an explicit qualified source pattern")
        include_srgb = color_authority == "sRGB"
        if source_format == "rgba16":
            png, source = rgba16_png(
                width,
                height,
                seed,
                filters,
                split_idat,
                include_srgb=include_srgb,
                interlace=interlace,
                significant_bits=significant_bits_payload,
                icc_profile=icc_profile,
                cicp=cicp_payload,
                mdcv=mdcv_payload,
                clli=clli_payload,
                source_override=source_override,
            )
            transparent = None
            transparent_gray = None
            source_bpp = 8
        elif source_format == "rgb16":
            png, source, transparent = rgb16_png(
                width,
                height,
                seed,
                filters,
                split_idat,
                include_srgb=include_srgb,
                transparent_pixel_index=specification.get("transparentPixelIndex"),
                high_byte_near_miss=bool(specification.get("highByteNearMiss", False)),
                significant_bits=significant_bits_payload,
                interlace=interlace,
                icc_profile=icc_profile,
                cicp=cicp_payload,
                mdcv=mdcv_payload,
                clli=clli_payload,
                source_override=source_override,
            )
            transparent_gray = None
            source_bpp = 6
        elif source_format == "grayscale16":
            png, source, transparent_gray = grayscale16_png(
                width,
                height,
                seed,
                filters,
                split_idat,
                transparent_pixel_index=specification.get("transparentPixelIndex"),
                high_byte_near_miss=bool(specification.get("highByteNearMiss", False)),
                significant_bits=significant_bits_payload,
                interlace=interlace,
            )
            transparent = None
            source_bpp = 2
        elif source_format == "grayscaleAlpha16":
            png, source = grayscale_alpha16_png(
                width,
                height,
                seed,
                filters,
                split_idat,
                significant_bits=significant_bits_payload,
                interlace=interlace,
            )
            transparent = None
            transparent_gray = None
            source_bpp = 4
        else:
            raise ValueError(f"unsupported success sourceFormat: {source_format}")
        png_file, png_sha = write_case(output_dir, case_id, png)
        raw_file = f"{case_id}.{source_format}be"
        (output_dir / raw_file).write_bytes(source)
        icc_profile_file: str | None = None
        icc_profile_sha: str | None = None
        if icc_profile is not None:
            icc_profile_file = f"{case_id}.icc"
            (output_dir / icc_profile_file).write_bytes(icc_profile)
            icc_profile_sha = sha256_bytes(icc_profile)

        reference_file: str | None = None
        reference_sha: str | None = None
        low_order_variation: list[bool] | None = None
        if significant_bits is not None:
            reference, low_order_variation = reference_samples_u16be(
                source,
                source_bpp,
                significant_bits,
            )
            if any(
                significant_bits[channel] < 16 and not low_order_variation[channel]
                for channel in range(len(significant_bits))
            ):
                raise ValueError(f"sBIT case lacks low-order fill variation: {case_id}")
            reference_file = f"{case_id}.reference-u16be"
            (output_dir / reference_file).write_bytes(reference)
            reference_sha = sha256_bytes(reference)

        success_manifest.append(
            {
                **specification,
                "pngFile": png_file,
                "pngSHA256": png_sha,
                "sourceRawBEFile": raw_file,
                "sourceRawBESHA256": sha256_bytes(source),
                "sourceByteCount": len(source),
                "sourceBytesPerPixel": source_bpp,
                "colorAuthority": color_authority,
                "iccProfileFile": icc_profile_file,
                "iccProfileSHA256": icc_profile_sha,
                "iccProfileByteCount": len(icc_profile) if icc_profile is not None else 0,
                "sourceCICP": list(cicp_payload) if cicp_payload is not None else None,
                "transparentRGB16": list(transparent) if transparent is not None else None,
                "transparentGray16": transparent_gray,
                "sourceSignificantBits": significant_bits,
                "referenceSamplesU16BEFile": reference_file,
                "referenceSamplesU16BESHA256": reference_sha,
                "lowOrderVariationByChannel": low_order_variation,
            }
        )

    base_width = 7
    base_height = 5
    base_seed = 131
    valid, _ = rgba16_png(base_width, base_height, base_seed, [0, 1, 2, 3, 4], 3)
    untagged, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2, include_srgb=False
    )
    adam7_untagged_rgb16, _, _ = rgb16_png(
        base_width,
        base_height,
        base_seed,
        [0, 1, 2, 3, 4],
        2,
        include_srgb=False,
        interlace=1,
    )
    adam7_malformed_significant_bits, _ = rgba16_png(
        base_width,
        base_height,
        base_seed,
        [0, 1, 2, 3, 4],
        2,
        interlace=1,
        significant_bits=bytes((12, 17, 14, 15)),
    )
    truncated, _ = rgba16_png(
        base_width,
        base_height,
        base_seed,
        [0, 1, 2, 3, 4],
        1,
        truncate_filtered_tail=1,
    )
    gamma, _ = rgba16_png(
        base_width,
        base_height,
        base_seed,
        [0, 1, 2, 3, 4],
        2,
        include_gamma=True,
    )
    malformed_significant_bits, _ = rgba16_png(
        base_width,
        base_height,
        base_seed,
        [0, 1, 2, 3, 4],
        2,
        significant_bits=bytes((12, 17, 14, 15)),
    )
    malformed_rgb_trns, _, _ = rgb16_png(
        base_width,
        base_height,
        base_seed,
        [0, 1, 2, 3, 4],
        2,
        transparency_payload_override=b"\x00\x01\x00\x02\x00",
    )
    rgba_trns, _ = rgba16_png(
        base_width,
        base_height,
        base_seed,
        [0, 1, 2, 3, 4],
        2,
        transparency=struct.pack(">HHH", 1, 2, 3),
    )
    untagged_grayscale, _, _ = grayscale16_png(
        base_width,
        base_height,
        base_seed,
        [0, 1, 2, 3, 4],
        2,
        include_srgb=False,
    )
    grayscale_alpha_trns, _ = grayscale_alpha16_png(
        base_width,
        base_height,
        base_seed,
        [0, 1, 2, 3, 4],
        2,
        transparency_payload_override=b"\x00\x00",
    )
    malformed_grayscale_trns, _, _ = grayscale16_png(
        base_width,
        base_height,
        base_seed,
        [0, 1, 2, 3, 4],
        2,
        transparency_payload_override=b"\x00",
    )
    rgb_icc_on_grayscale, _, _ = grayscale16_png(
        base_width,
        base_height,
        base_seed,
        [0, 1, 2, 3, 4],
        2,
        include_srgb=False,
        icc_profile=deterministic_icc_profile(b"RGB "),
    )
    gray_icc_on_rgba, _ = rgba16_png(
        base_width,
        base_height,
        base_seed,
        [0, 1, 2, 3, 4],
        2,
        include_srgb=False,
        icc_profile=deterministic_icc_profile(b"GRAY"),
    )
    valid_rgb_icc_rgba, _ = rgba16_png(
        base_width,
        base_height,
        base_seed,
        [0, 1, 2, 3, 4],
        2,
        include_srgb=False,
        icc_profile=deterministic_icc_profile(b"RGB "),
    )
    p3_cicp = bytes((0x0C, 0x0D, 0x00, 0x01))
    narrow_p3_cicp, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False, cicp=bytes((0x0C, 0x0D, 0x00, 0x00))
    )
    invalid_matrix_cicp, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False, cicp=bytes((0x0C, 0x0D, 0x01, 0x01))
    )
    unqualified_cicp, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False, cicp=bytes((0x02, 0x02, 0x00, 0x01))
    )
    cicp_on_grayscale, _, _ = grayscale16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False, cicp=p3_cicp
    )
    p3_out_of_gamut_source = struct.pack(">HHHH", 0xFFFF, 0, 0, 0xFFFF) * (base_width * base_height)
    p3_convert_out_of_gamut, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False, cicp=p3_cicp, source_override=p3_out_of_gamut_source
    )
    p3_icc_convert_out_of_gamut, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False,
        icc_profile=deterministic_display_p3_matrix_trc_icc_profile(),
        source_override=p3_out_of_gamut_source,
    )
    matrix_trc_white_mismatch, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False,
        icc_profile=deterministic_white_mismatch_gamma22_matrix_trc_icc_profile(),
    )
    matrix_trc_type0_zero_gamma, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False,
        icc_profile=deterministic_srgb_d50_zero_gamma_type0_matrix_trc_icc_profile(),
    )
    matrix_trc_type1_nonpositive_a, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False,
        icc_profile=deterministic_type1_nonpositive_a_matrix_trc_icc_profile(),
    )
    matrix_trc_type2_nonnormalized, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False,
        icc_profile=deterministic_type2_nonnormalized_matrix_trc_icc_profile(),
    )
    matrix_trc_type4_negative_discontinuity, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False,
        icc_profile=deterministic_type4_negative_discontinuity_matrix_trc_icc_profile(),
    )
    matrix_trc_curve_zero_gamma, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False,
        icc_profile=deterministic_curve_zero_gamma_matrix_trc_icc_profile(),
    )
    matrix_trc_curve_nonnormalized, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False,
        icc_profile=deterministic_curve_nonnormalized_matrix_trc_icc_profile(),
    )
    matrix_trc_curve_nonmonotone, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False,
        icc_profile=deterministic_curve_nonmonotone_matrix_trc_icc_profile(),
    )
    matrix_trc_curve_sampled_count_mismatch, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False,
        icc_profile=deterministic_curve_sampled_1025_count_mismatch_matrix_trc_icc_profile(),
    )
    matrix_trc_per_channel_invalid_parametric, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False,
        icc_profile=deterministic_per_channel_invalid_parametric_matrix_trc_icc_profile(),
    )
    matrix_trc_per_channel_invalid_mixed, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False,
        icc_profile=deterministic_per_channel_invalid_mixed_matrix_trc_icc_profile(),
    )
    matrix_trc_output_profile_class, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False,
        icc_profile=with_icc_profile_class(
            deterministic_srgb_d50_gamma22_matrix_trc_icc_profile(),
            b"prtr",
        ),
    )
    real_linear_rimm_profile = validated_real_input_lut_profile(
        args.profile,
        "linear_RIMM-RGB_v4.icc",
        "d3c55e43be9f0e0a42ff31ba18545a89435da5c9ed0997dc42b920779850cd9e",
    )
    real_linear_rimm_lut, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False,
        icc_profile=real_linear_rimm_profile,
    )
    real_rimm_excr_profile = validated_real_input_lut_profile(
        args.profile,
        "ISO22028-3_RIMM-RGB-exCR.icc",
        "22f57bb7b27917c207f06303915930bbb9336781635b302584f0ea039c5c2bed",
    )
    real_rimm_excr_lut, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False,
        icc_profile=real_rimm_excr_profile,
    )
    cicp_with_mdcv, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False, cicp=p3_cicp, mdcv=bytes(24)
    )
    cicp_with_clli, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False, cicp=p3_cicp, clli=bytes(8)
    )
    pq_cicp = bytes((0x09, 0x10, 0x00, 0x01))
    high_bit_mdcv = bytearray(24)
    high_bit_mdcv[16] = 0x80
    invalid_high_bit_mdcv, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False, cicp=pq_cicp, mdcv=bytes(high_bit_mdcv)
    )
    high_bit_clli = bytearray(8)
    high_bit_clli[0] = 0x80
    invalid_high_bit_clli, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=False, cicp=pq_cicp, clli=bytes(high_bit_clli)
    )
    mdcv_without_cicp, _ = rgba16_png(
        base_width, base_height, base_seed, [0, 1, 2, 3, 4], 2,
        include_srgb=True, mdcv=bytes(24)
    )
    real_input_lut_fixture_claims = {
        "real-input-lut-linear-rimm": {
            "realICCFixture": "fixtures/linear_RIMM-RGB_v4.icc",
            "realICCFixtureSHA256": "d3c55e43be9f0e0a42ff31ba18545a89435da5c9ed0997dc42b920779850cd9e",
            "realICCProfileByteCount": len(real_linear_rimm_profile),
        },
        "real-input-lut-rimm-excr": {
            "realICCFixture": "fixtures/ISO22028-3_RIMM-RGB-exCR.icc",
            "realICCFixtureSHA256": "22f57bb7b27917c207f06303915930bbb9336781635b302584f0ea039c5c2bed",
            "realICCProfileByteCount": len(real_rimm_excr_profile),
        },
    }
    hostile_payloads = {
        "untagged": untagged,
        "adam7-untagged-rgb16": adam7_untagged_rgb16,
        "truncated-stream": truncated,
        "rgba8-source": rgba8_png(base_width, base_height, base_seed),
        "malformed-rgb16-trns": malformed_rgb_trns,
        "gamma-with-srgb": gamma,
        "corrupt-idat-crc": corrupt_first_idat_crc(valid),
        "operation-budget": valid,
        "malformed-significant-bits": malformed_significant_bits,
        "rgba16-trns": rgba_trns,
        "adam7-malformed-significant-bits": adam7_malformed_significant_bits,
        "untagged-grayscale16": untagged_grayscale,
        "grayscale-alpha-trns": grayscale_alpha_trns,
        "malformed-grayscale-trns": malformed_grayscale_trns,
        "rgb-icc-on-grayscale16": rgb_icc_on_grayscale,
        "gray-icc-on-rgba16": gray_icc_on_rgba,
        "valid-rgb-icc-rgba16": valid_rgb_icc_rgba,
        "narrow-p3-cicp": narrow_p3_cicp,
        "invalid-matrix-cicp": invalid_matrix_cicp,
        "unqualified-cicp": unqualified_cicp,
        "cicp-on-grayscale16": cicp_on_grayscale,
        "p3-convert-out-of-gamut": p3_convert_out_of_gamut,
        "p3-icc-convert-out-of-gamut": p3_icc_convert_out_of_gamut,
        "matrix-trc-white-mismatch": matrix_trc_white_mismatch,
        "matrix-trc-type0-zero-gamma": matrix_trc_type0_zero_gamma,
        "matrix-trc-type1-nonpositive-a": matrix_trc_type1_nonpositive_a,
        "matrix-trc-type2-nonnormalized": matrix_trc_type2_nonnormalized,
        "matrix-trc-type4-negative-discontinuity": matrix_trc_type4_negative_discontinuity,
        "matrix-trc-curve-zero-gamma": matrix_trc_curve_zero_gamma,
        "matrix-trc-curve-nonnormalized": matrix_trc_curve_nonnormalized,
        "matrix-trc-curve-nonmonotone": matrix_trc_curve_nonmonotone,
        "matrix-trc-curve-sampled-count-mismatch": matrix_trc_curve_sampled_count_mismatch,
        "matrix-trc-per-channel-invalid-parametric": matrix_trc_per_channel_invalid_parametric,
        "matrix-trc-per-channel-invalid-mixed": matrix_trc_per_channel_invalid_mixed,
        "matrix-trc-output-profile-class": matrix_trc_output_profile_class,
        "real-input-lut-linear-rimm": real_linear_rimm_lut,
        "real-input-lut-rimm-excr": real_rimm_excr_lut,
        "cicp-with-mdcv": cicp_with_mdcv,
        "cicp-with-clli": cicp_with_clli,
        "invalid-high-bit-mdcv": invalid_high_bit_mdcv,
        "invalid-high-bit-clli": invalid_high_bit_clli,
        "mdcv-without-cicp": mdcv_without_cicp,
    }
    hostile_manifest: list[dict[str, object]] = []
    for specification in profile["hostileCases"]:
        mutation = specification["mutation"]
        real_fixture_claim = real_input_lut_fixture_claims.get(mutation)
        if real_fixture_claim is not None:
            for key, expected in real_fixture_claim.items():
                if specification.get(key) != expected:
                    raise ValueError(f"real ICC hostile provenance drifted for {specification['id']}: {key}")
            maximum_metadata_bytes = specification.get("maximumMetadataBytes")
            if (
                not isinstance(maximum_metadata_bytes, int)
                or maximum_metadata_bytes <= real_fixture_claim["realICCProfileByteCount"]
            ):
                raise ValueError(
                    f"real ICC hostile metadata budget does not reach semantic gate: {specification['id']}"
                )
        png = hostile_payloads[mutation]
        filename, digest = write_case(output_dir, specification["id"], png)
        hostile_manifest.append(
            {
                **specification,
                "width": base_width,
                "height": base_height,
                "pngFile": filename,
                "pngSHA256": digest,
            }
        )

    manifest = {
        "schemaVersion": 1,
        "profileID": profile["profileID"],
        "successCases": success_manifest,
        "hostileCases": hostile_manifest,
    }
    manifest_path = output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(
        f"Generated PNG16 corpus: success={len(success_manifest)} hostile={len(hostile_manifest)} "
        f"manifest={manifest_path}"
    )


if __name__ == "__main__":
    main()
