#!/usr/bin/env python3
from __future__ import annotations

import argparse
import binascii
import hashlib
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PROFILE = ROOT / "Evidence/Experiments/IndependentPNG/v1/profile.json"

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
SUGGESTED_TRUECOLOR_PLTE = bytes(
    [0, 0, 0, 255, 255, 255, 190, 80, 30, 32, 160, 224]
)
SUGGESTED_TRUECOLOR_HIST = b"".join(
    struct.pack(">H", value) for value in (1, 257, 4096, 65535)
)
INDEXED256_PALETTE = bytes(
    component
    for index in range(256)
    for component in (index, 255 - index, (index * 37 + 11) & 0xFF)
)
INDEXED256_ALPHA = bytes(
    0 if index % 11 == 0 else 255 if index % 7 == 0 else (index * 53 + 17) & 0xFF
    for index in range(64)
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def chunk(kind: bytes, payload: bytes) -> bytes:
    assert len(kind) == 4
    body = kind + payload
    return struct.pack(">I", len(payload)) + body + struct.pack(">I", binascii.crc32(body) & 0xFFFFFFFF)


def paeth(left: int, above: int, upper_left: int) -> int:
    prediction = left + above - upper_left
    distances = (
        (abs(prediction - left), left),
        (abs(prediction - above), above),
        (abs(prediction - upper_left), upper_left),
    )
    return min(enumerate(distances), key=lambda item: (item[1][0], item[0]))[1][1]


def source_rgba(width: int, height: int) -> bytes:
    output = bytearray()
    for y in range(height):
        for x in range(width):
            red = (x * 37 + y * 19 + 11) & 0xFF
            green = (x * 13 + y * 71 + 53) & 0xFF
            blue = (x * 97 + y * 29 + 101) & 0xFF
            selector = (x + y * 3) % 7
            if selector == 0:
                alpha = 0
            elif selector == 1:
                alpha = 255
            else:
                alpha = (x * 41 + y * 59 + 23) & 0xFF
            output.extend((red, green, blue, alpha))
    return bytes(output)


def source_gray(width: int, height: int, bit_depth: int = 8) -> bytes:
    if bit_depth not in (1, 2, 4, 8):
        raise ValueError("grayscale PNG bit depth must be 1, 2, 4 or 8")
    maximum_sample = (1 << bit_depth) - 1
    output = bytearray()
    for y in range(height):
        for x in range(width):
            output.append((x * 47 + y * 31 + (x * y) * 7 + 13) % (maximum_sample + 1))
    return bytes(output)


def source_gray_alpha(width: int, height: int) -> bytes:
    output = bytearray()
    for y in range(height):
        for x in range(width):
            gray = (x * 47 + y * 31 + (x * y) * 7 + 13) & 0xFF
            selector = (x + y * 3) % 6
            if selector == 0:
                alpha = 0
            elif selector == 1:
                alpha = 255
            else:
                alpha = (x * 41 + y * 59 + 23) & 0xFF
            output.extend((gray, alpha))
    return bytes(output)


def source_indexed8(width: int, height: int, entry_count: int = 256) -> bytes:
    if not 1 <= entry_count <= 256:
        raise ValueError("indexed palette entry count must be in 1...256")
    return bytes(((index * 73 + 19) % entry_count) for index in range(width * height))


def pack_sample_rows(samples: bytes, width: int, height: int, bit_depth: int) -> bytes:
    if bit_depth not in (1, 2, 4, 8):
        raise ValueError("packed PNG bit depth must be 1, 2, 4 or 8")
    if len(samples) != width * height:
        raise ValueError("packed source size does not match dimensions")
    maximum_sample = (1 << bit_depth) - 1
    if any(sample > maximum_sample for sample in samples):
        raise ValueError("packed source sample exceeds bit depth")
    row_bytes = (width * bit_depth + 7) // 8
    packed = bytearray(row_bytes * height)
    for y in range(height):
        for x in range(width):
            sample = samples[y * width + x]
            if bit_depth == 8:
                packed[y * row_bytes + x] = sample
            else:
                bit_offset = x * bit_depth
                byte_offset = y * row_bytes + bit_offset // 8
                shift = 8 - bit_depth - (bit_offset % 8)
                packed[byte_offset] |= sample << shift
    return bytes(packed)


def source_rgb(width: int, height: int) -> bytes:
    output = bytearray()
    for y in range(height):
        for x in range(width):
            output.extend(
                (
                    (x * 37 + y * 19 + 11) & 0xFF,
                    (x * 13 + y * 71 + 53) & 0xFF,
                    (x * 97 + y * 29 + 101) & 0xFF,
                )
            )
    return bytes(output)


def expand_gray_to_rgba(
    straight_gray: bytes,
    bit_depth: int = 8,
    transparent_gray16: int | None = None,
) -> bytes:
    if bit_depth not in (1, 2, 4, 8):
        raise ValueError("grayscale PNG bit depth must be 1, 2, 4 or 8")
    maximum_sample = (1 << bit_depth) - 1
    transparent_sample = (
        transparent_gray16 & maximum_sample if transparent_gray16 is not None else None
    )
    output = bytearray(len(straight_gray) * 4)
    destination_offset = 0
    for gray in straight_gray:
        if gray > maximum_sample:
            raise ValueError("grayscale source sample exceeds bit depth")
        scaled = gray * 255 // maximum_sample
        alpha = 0 if transparent_sample == gray else 255
        output[destination_offset : destination_offset + 4] = bytes((scaled, scaled, scaled, alpha))
        destination_offset += 4
    return bytes(output)


def expand_gray_alpha_to_rgba(straight_gray_alpha: bytes) -> bytes:
    assert len(straight_gray_alpha) % 2 == 0
    output = bytearray((len(straight_gray_alpha) // 2) * 4)
    source_offset = 0
    destination_offset = 0
    while source_offset < len(straight_gray_alpha):
        gray = straight_gray_alpha[source_offset]
        alpha = straight_gray_alpha[source_offset + 1]
        output[destination_offset : destination_offset + 4] = bytes((gray, gray, gray, alpha))
        source_offset += 2
        destination_offset += 4
    return bytes(output)


def expand_indexed8_to_rgba(
    indices: bytes,
    palette: bytes,
    alpha_table: bytes,
) -> bytes:
    assert 3 <= len(palette) <= 256 * 3
    assert len(palette) % 3 == 0
    entry_count = len(palette) // 3
    assert len(alpha_table) <= entry_count
    output = bytearray(len(indices) * 4)
    destination_offset = 0
    for index in indices:
        if index >= entry_count:
            raise ValueError("indexed source references a palette entry that does not exist")
        palette_offset = index * 3
        alpha = alpha_table[index] if index < len(alpha_table) else 255
        output[destination_offset : destination_offset + 4] = bytes(
            (
                palette[palette_offset],
                palette[palette_offset + 1],
                palette[palette_offset + 2],
                alpha,
            )
        )
        destination_offset += 4
    return bytes(output)


def expand_rgb_to_rgba(
    straight_rgb: bytes,
    transparent_rgb16: tuple[int, int, int] | None = None,
) -> bytes:
    assert len(straight_rgb) % 3 == 0
    transparent_rgb8 = (
        tuple(value & 0xFF for value in transparent_rgb16)
        if transparent_rgb16 is not None
        else None
    )
    output = bytearray((len(straight_rgb) // 3) * 4)
    source_offset = 0
    destination_offset = 0
    while source_offset < len(straight_rgb):
        red = straight_rgb[source_offset]
        green = straight_rgb[source_offset + 1]
        blue = straight_rgb[source_offset + 2]
        output[destination_offset : destination_offset + 3] = bytes((red, green, blue))
        output[destination_offset + 3] = (
            0 if transparent_rgb8 == (red, green, blue) else 255
        )
        source_offset += 3
        destination_offset += 4
    return bytes(output)


def premultiply_rgba(straight: bytes) -> bytes:
    assert len(straight) % 4 == 0
    output = bytearray(len(straight))
    for offset in range(0, len(straight), 4):
        alpha = straight[offset + 3]
        if alpha == 0:
            output[offset : offset + 3] = b"\x00\x00\x00"
        elif alpha == 255:
            output[offset : offset + 3] = straight[offset : offset + 3]
        else:
            output[offset] = (straight[offset] * alpha + 127) // 255
            output[offset + 1] = (straight[offset + 1] * alpha + 127) // 255
            output[offset + 2] = (straight[offset + 2] * alpha + 127) // 255
        output[offset + 3] = alpha
    return bytes(output)


def filtered_samples(
    straight: bytes,
    width: int,
    height: int,
    filters: list[int],
    bytes_per_pixel: int,
) -> bytes:
    row_bytes = width * bytes_per_pixel
    assert len(straight) == row_bytes * height
    assert bytes_per_pixel > 0
    assert filters
    output = bytearray()
    for y in range(height):
        filter_kind = filters[y % len(filters)]
        if filter_kind not in range(5):
            raise ValueError(f"invalid filter {filter_kind}")
        output.append(filter_kind)
        row_start = y * row_bytes
        previous_start = (y - 1) * row_bytes
        for column in range(row_bytes):
            value = straight[row_start + column]
            left = (
                straight[row_start + column - bytes_per_pixel]
                if column >= bytes_per_pixel
                else 0
            )
            above = straight[previous_start + column] if y > 0 else 0
            upper_left = (
                straight[previous_start + column - bytes_per_pixel]
                if y > 0 and column >= bytes_per_pixel
                else 0
            )
            if filter_kind == 0:
                predictor = 0
            elif filter_kind == 1:
                predictor = left
            elif filter_kind == 2:
                predictor = above
            elif filter_kind == 3:
                predictor = (left + above) >> 1
            else:
                predictor = paeth(left, above, upper_left)
            output.append((value - predictor) & 0xFF)
    return bytes(output)


def filtered_rgba(straight: bytes, width: int, height: int, filters: list[int]) -> bytes:
    return filtered_samples(straight, width, height, filters, 4)


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
    straight: bytes,
    width: int,
    height: int,
    filters: list[int],
    bytes_per_pixel: int,
) -> bytes:
    assert width > 0 and height > 0
    assert len(straight) == width * height * bytes_per_pixel
    assert bytes_per_pixel > 0
    assert filters
    output = bytearray()
    for pass_index, (x_start, y_start, x_step, y_step) in enumerate(ADAM7_GEOMETRY):
        pass_width = adam7_sample_count(width, x_start, x_step)
        pass_height = adam7_sample_count(height, y_start, y_step)
        if pass_width == 0 or pass_height == 0:
            continue
        row_bytes = pass_width * bytes_per_pixel
        previous = bytes(row_bytes)
        for pass_row in range(pass_height):
            y = y_start + pass_row * y_step
            raw = bytearray(row_bytes)
            for pass_column in range(pass_width):
                x = x_start + pass_column * x_step
                source_offset = (y * width + x) * bytes_per_pixel
                row_offset = pass_column * bytes_per_pixel
                raw[row_offset : row_offset + bytes_per_pixel] = straight[
                    source_offset : source_offset + bytes_per_pixel
                ]
            filter_kind = filters[(pass_index + pass_row) % len(filters)]
            if filter_kind not in range(5):
                raise ValueError(f"invalid filter {filter_kind}")
            output.append(filter_kind)
            for column, value in enumerate(raw):
                left = raw[column - bytes_per_pixel] if column >= bytes_per_pixel else 0
                above = previous[column]
                upper_left = previous[column - bytes_per_pixel] if column >= bytes_per_pixel else 0
                if filter_kind == 0:
                    predictor = 0
                elif filter_kind == 1:
                    predictor = left
                elif filter_kind == 2:
                    predictor = above
                elif filter_kind == 3:
                    predictor = (left + above) >> 1
                else:
                    predictor = paeth(left, above, upper_left)
                output.append((value - predictor) & 0xFF)
            previous = bytes(raw)
    return bytes(output)


def split_bytes(data: bytes, pieces: int) -> list[bytes]:
    if pieces <= 1:
        return [data]
    result: list[bytes] = []
    start = 0
    for index in range(pieces):
        remaining_pieces = pieces - index
        remaining_bytes = len(data) - start
        count = (remaining_bytes + remaining_pieces - 1) // remaining_pieces
        result.append(data[start : start + count])
        start += count
    assert b"".join(result) == data
    return result


def make_rgba_png(
    *,
    width: int,
    height: int,
    straight: bytes,
    filters: list[int],
    split_idat: int = 1,
    include_srgb: bool = True,
    include_gamma: bool = False,
    include_chrm: bool = False,
    interlace: int = 0,
    truncate_filtered_tail: int = 0,
    idat_separator: bytes | None = None,
    idat_separator_type: bytes = b"tEXt",
    extra_critical: bool = False,
    invalid_reserved_ancillary: bool = False,
    srgb_after_idat: bool = False,
    cicp: bytes | None = None,
    sbit: bytes | None = None,
    mdcv: bytes | None = None,
    clli: bytes | None = None,
    icc_profile: bytes | None = None,
    suggested_plte: bytes | None = None,
    histogram: bytes | None = None,
) -> bytes:
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, interlace)
    if include_srgb and srgb_after_idat:
        raise ValueError("sRGB must be placed either before or after IDAT, not both")
    if (include_srgb or srgb_after_idat) and icc_profile is not None:
        raise ValueError("sRGB and iCCP are mutually exclusive in this deterministic corpus")
    if interlace == 0:
        filtered = filtered_rgba(straight, width, height, filters)
    elif interlace == 1:
        filtered = filtered_adam7_samples(straight, width, height, filters, 4)
    else:
        raise ValueError("PNG interlace method must be 0 or 1")
    if truncate_filtered_tail < 0 or truncate_filtered_tail > len(filtered):
        raise ValueError("invalid filtered-tail truncation")
    if truncate_filtered_tail:
        filtered = filtered[:-truncate_filtered_tail]
    compressed = zlib.compress(filtered, level=6)
    result = bytearray(PNG_SIGNATURE)
    result += chunk(b"IHDR", ihdr)
    if include_srgb:
        result += chunk(b"sRGB", b"\x00")
    elif icc_profile is not None:
        result += chunk(b"iCCP", b"ICC Profile\x00\x00" + zlib.compress(icc_profile, level=6))
    if include_gamma:
        result += chunk(b"gAMA", struct.pack(">I", 45455))
    if include_chrm:
        srgb_chromaticities = (31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000)
        result += chunk(b"cHRM", b"".join(struct.pack(">I", value) for value in srgb_chromaticities))
    if cicp is not None:
        if len(cicp) != 4:
            raise ValueError("cICP payload must contain four bytes")
        result += chunk(b"cICP", cicp)
    if sbit is not None:
        if len(sbit) != 4 or any(value < 1 or value > 8 for value in sbit):
            raise ValueError("RGBA8 sBIT payload must contain four values in 1...8")
        result += chunk(b"sBIT", sbit)
    if mdcv is not None:
        if len(mdcv) != 24:
            raise ValueError("mDCV payload must contain 24 bytes")
        result += chunk(b"mDCV", mdcv)
    if clli is not None:
        if len(clli) != 8:
            raise ValueError("cLLI payload must contain eight bytes")
        result += chunk(b"cLLI", clli)
    if suggested_plte is not None:
        if not (3 <= len(suggested_plte) <= 768) or len(suggested_plte) % 3 != 0:
            raise ValueError("truecolor PLTE must contain 1...256 RGB entries")
        result += chunk(b"PLTE", suggested_plte)
    if histogram is not None:
        result += chunk(b"hIST", histogram)
    if extra_critical:
        result += chunk(b"ABCD", b"")
    if invalid_reserved_ancillary:
        result += chunk(b"aaab", b"")
    pieces = split_bytes(compressed, split_idat)
    for index, piece in enumerate(pieces):
        result += chunk(b"IDAT", piece)
        if idat_separator is not None and index + 1 < len(pieces):
            result += chunk(idat_separator_type, idat_separator)
    if srgb_after_idat:
        result += chunk(b"sRGB", b"\x00")
    result += chunk(b"IEND", b"")
    return bytes(result)


def make_rgb_png(
    *,
    width: int,
    height: int,
    straight: bytes,
    filters: list[int],
    split_idat: int = 1,
    include_srgb: bool = True,
    suggested_plte: bytes | None = None,
    histogram: bytes | None = None,
    transparent_rgb16: tuple[int, int, int] | None = None,
) -> bytes:
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    compressed = zlib.compress(
        filtered_samples(straight, width, height, filters, 3),
        level=6,
    )
    result = bytearray(PNG_SIGNATURE)
    result += chunk(b"IHDR", ihdr)
    if include_srgb:
        result += chunk(b"sRGB", b"\x00")
    if suggested_plte is not None:
        if not (3 <= len(suggested_plte) <= 768) or len(suggested_plte) % 3 != 0:
            raise ValueError("truecolor PLTE must contain 1...256 RGB entries")
        result += chunk(b"PLTE", suggested_plte)
    if histogram is not None:
        result += chunk(b"hIST", histogram)
    if transparent_rgb16 is not None:
        if len(transparent_rgb16) != 3 or any(
            value < 0 or value > 0xFFFF for value in transparent_rgb16
        ):
            raise ValueError("truecolor tRNS must contain three UInt16 samples")
        result += chunk(b"tRNS", struct.pack(">HHH", *transparent_rgb16))
    for piece in split_bytes(compressed, split_idat):
        result += chunk(b"IDAT", piece)
    result += chunk(b"IEND", b"")
    return bytes(result)


def make_rgb8_png(width: int, height: int) -> bytes:
    return make_rgb_png(
        width=width,
        height=height,
        straight=source_rgb(width, height),
        filters=[0],
    )


def structurally_bounded_icc_profile(data_color_space: bytes) -> bytes:
    if len(data_color_space) != 4:
        raise ValueError("ICC data color-space signature must contain four bytes")
    profile = bytearray(132)
    profile[0:4] = struct.pack(">I", len(profile))
    profile[16:20] = data_color_space
    profile[36:40] = b"acsp"
    profile[128:132] = struct.pack(">I", 0)
    return bytes(profile)


def valid_bt709_mdcv_payload() -> bytes:
    chromaticities = (32000, 16500, 15000, 30000, 7500, 3000, 15635, 16450)
    payload = bytearray()
    for value in chromaticities:
        payload += struct.pack(">H", value)
    payload += struct.pack(">I", 1_000_000)  # 100 cd/m^2 at divisor 0.0001.
    payload += struct.pack(">I", 1_000)  # 0.1 cd/m^2 at divisor 0.0001.
    return bytes(payload)


def make_gray_alpha_png(
    *,
    width: int,
    height: int,
    straight: bytes,
    filters: list[int],
    split_idat: int = 1,
    include_srgb: bool = True,
) -> bytes:
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 4, 0, 0, 0)
    compressed = zlib.compress(
        filtered_samples(straight, width, height, filters, 2),
        level=6,
    )
    result = bytearray(PNG_SIGNATURE)
    result += chunk(b"IHDR", ihdr)
    if include_srgb:
        result += chunk(b"sRGB", b"\x00")
    for piece in split_bytes(compressed, split_idat):
        result += chunk(b"IDAT", piece)
    result += chunk(b"IEND", b"")
    return bytes(result)


def make_gray_png(
    *,
    width: int,
    height: int,
    straight: bytes,
    filters: list[int],
    split_idat: int = 1,
    include_srgb: bool = True,
    transparent_gray16: int | None = None,
    bit_depth: int = 8,
) -> bytes:
    if bit_depth not in (1, 2, 4, 8):
        raise ValueError("grayscale PNG bit depth must be 1, 2, 4 or 8")
    ihdr = struct.pack(">IIBBBBB", width, height, bit_depth, 0, 0, 0, 0)
    packed = pack_sample_rows(straight, width, height, bit_depth)
    row_bytes = (width * bit_depth + 7) // 8
    compressed = zlib.compress(
        filtered_samples(packed, row_bytes, height, filters, 1),
        level=6,
    )
    result = bytearray(PNG_SIGNATURE)
    result += chunk(b"IHDR", ihdr)
    if include_srgb:
        result += chunk(b"sRGB", b"\x00")
    if transparent_gray16 is not None:
        if transparent_gray16 < 0 or transparent_gray16 > 0xFFFF:
            raise ValueError("grayscale tRNS must contain one UInt16 sample")
        result += chunk(b"tRNS", struct.pack(">H", transparent_gray16))
    for piece in split_bytes(compressed, split_idat):
        result += chunk(b"IDAT", piece)
    result += chunk(b"IEND", b"")
    return bytes(result)


def make_indexed_png(
    *,
    width: int,
    height: int,
    indices: bytes,
    filters: list[int],
    split_idat: int = 1,
    palette: bytes = INDEXED256_PALETTE,
    alpha_table: bytes = INDEXED256_ALPHA,
    bit_depth: int = 8,
) -> bytes:
    if bit_depth not in (1, 2, 4, 8):
        raise ValueError("indexed PNG bit depth must be 1, 2, 4 or 8")
    ihdr = struct.pack(">IIBBBBB", width, height, bit_depth, 3, 0, 0, 0)
    packed = pack_sample_rows(indices, width, height, bit_depth)
    row_bytes = (width * bit_depth + 7) // 8
    compressed = zlib.compress(
        filtered_samples(packed, row_bytes, height, filters, 1),
        level=6,
    )
    result = bytearray(PNG_SIGNATURE)
    result += chunk(b"IHDR", ihdr)
    result += chunk(b"sRGB", b"\x00")
    result += chunk(b"PLTE", palette)
    if alpha_table:
        result += chunk(b"tRNS", alpha_table)
    for piece in split_bytes(compressed, split_idat):
        result += chunk(b"IDAT", piece)
    result += chunk(b"IEND", b"")
    return bytes(result)


def make_indexed8_png(
    width: int,
    height: int,
    *,
    include_out_of_range_index: bool = False,
) -> bytes:
    palette = bytes((0, 0, 0, 190, 80, 30, 255, 255, 255))
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            index = (x + y * 2) % 3
            if include_out_of_range_index and x == width - 1 and y == height - 1:
                index = 3
            raw.append(index)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0)
    return (
        PNG_SIGNATURE
        + chunk(b"IHDR", ihdr)
        + chunk(b"sRGB", b"\x00")
        + chunk(b"PLTE", palette)
        + chunk(b"IDAT", zlib.compress(bytes(raw), level=6))
        + chunk(b"IEND", b"")
    )


def corrupt_first_idat_crc(png: bytes) -> bytes:
    mutable = bytearray(png)
    offset = len(PNG_SIGNATURE)
    while offset + 12 <= len(mutable):
        length = struct.unpack(">I", mutable[offset : offset + 4])[0]
        kind = bytes(mutable[offset + 4 : offset + 8])
        crc_offset = offset + 8 + length
        if kind == b"IDAT":
            mutable[crc_offset + 3] ^= 0x01
            return bytes(mutable)
        offset = crc_offset + 4
    raise ValueError("IDAT not found")


def replace_first_chunk_type(png: bytes, old_type: bytes, new_type: bytes) -> bytes:
    assert len(old_type) == 4 and len(new_type) == 4
    mutable = bytearray(png)
    offset = len(PNG_SIGNATURE)
    while offset + 12 <= len(mutable):
        length = struct.unpack(">I", mutable[offset : offset + 4])[0]
        kind_start = offset + 4
        payload_start = offset + 8
        payload_end = payload_start + length
        chunk_end = payload_end + 4
        if chunk_end > len(mutable):
            raise ValueError("truncated chunk")
        if bytes(mutable[kind_start : kind_start + 4]) == old_type:
            mutable[kind_start : kind_start + 4] = new_type
            body = bytes(mutable[kind_start:payload_end])
            mutable[payload_end:chunk_end] = struct.pack(">I", binascii.crc32(body) & 0xFFFFFFFF)
            return bytes(mutable)
        offset = chunk_end
    raise ValueError(f"chunk {old_type!r} not found")


def write_case(directory: Path, case_id: str, png: bytes) -> dict[str, object]:
    path = directory / f"{case_id}.png"
    path.write_bytes(png)
    return {
        "id": case_id,
        "path": path.name,
        "pngByteCount": len(png),
        "pngSHA256": sha256(png),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    profile = json.loads(args.profile.read_text())
    args.output_dir.mkdir(parents=True, exist_ok=True)

    successes: list[dict[str, object]] = []
    for specification in profile["successCases"]:
        width = int(specification["width"])
        height = int(specification["height"])
        source_format = str(specification.get("sourceFormat", "rgba8"))
        if source_format == "rgba8":
            source_samples = source_rgba(width, height)
            straight = source_samples
            png = make_rgba_png(
                width=width,
                height=height,
                straight=source_samples,
                filters=[int(value) for value in specification["filters"]],
                split_idat=int(specification["splitIDAT"]),
                interlace=int(specification.get("interlace", 0)),
                suggested_plte=(
                    SUGGESTED_TRUECOLOR_PLTE
                    if bool(specification.get("suggestedPLTE", False))
                    else None
                ),
                histogram=(
                    SUGGESTED_TRUECOLOR_HIST
                    if bool(specification.get("suggestedHIST", False))
                    else None
                ),
                include_srgb=bool(specification.get("includeSRGB", True)),
                cicp=(
                    bytes(int(value) for value in specification["cicp"])
                    if specification.get("cicp") is not None
                    else None
                ),
            )
        elif source_format == "grayAlpha8":
            source_samples = source_gray_alpha(width, height)
            straight = expand_gray_alpha_to_rgba(source_samples)
            png = make_gray_alpha_png(
                width=width,
                height=height,
                straight=source_samples,
                filters=[int(value) for value in specification["filters"]],
                split_idat=int(specification["splitIDAT"]),
            )
        elif source_format in ("gray1", "gray2", "gray4", "gray8"):
            grayscale_bit_depth = int(source_format.removeprefix("gray"))
            source_samples = source_gray(width, height, grayscale_bit_depth)
            transparent_gray16_value = specification.get("transparentGray16")
            transparent_gray16 = (
                int(transparent_gray16_value)
                if transparent_gray16_value is not None
                else None
            )
            straight = expand_gray_to_rgba(
                source_samples,
                grayscale_bit_depth,
                transparent_gray16,
            )
            png = make_gray_png(
                width=width,
                height=height,
                straight=source_samples,
                filters=[int(value) for value in specification["filters"]],
                split_idat=int(specification["splitIDAT"]),
                transparent_gray16=transparent_gray16,
                bit_depth=grayscale_bit_depth,
            )
        elif source_format == "indexed8":
            indexed_bit_depth = int(specification.get("indexedBitDepth", 8))
            if indexed_bit_depth not in (1, 2, 4, 8):
                raise ValueError("indexedBitDepth must be 1, 2, 4 or 8")
            palette_entry_count = int(
                specification.get("indexedPaletteEntryCount", 1 << indexed_bit_depth)
            )
            if not 1 <= palette_entry_count <= (1 << indexed_bit_depth):
                raise ValueError("indexedPaletteEntryCount exceeds indexed bit depth")
            alpha_count = int(
                specification.get(
                    "indexedAlphaCount",
                    min(len(INDEXED256_ALPHA), palette_entry_count),
                )
            )
            if not 0 <= alpha_count <= palette_entry_count:
                raise ValueError("indexedAlphaCount must be in 0...indexedPaletteEntryCount")
            palette = INDEXED256_PALETTE[: palette_entry_count * 3]
            alpha_table = INDEXED256_ALPHA[:alpha_count]
            source_samples = source_indexed8(width, height, palette_entry_count)
            straight = expand_indexed8_to_rgba(
                source_samples,
                palette,
                alpha_table,
            )
            png = make_indexed_png(
                width=width,
                height=height,
                indices=source_samples,
                filters=[int(value) for value in specification["filters"]],
                split_idat=int(specification["splitIDAT"]),
                palette=palette,
                alpha_table=alpha_table,
                bit_depth=indexed_bit_depth,
            )
        elif source_format == "rgb8":
            source_samples = source_rgb(width, height)
            transparent_rgb16_value = specification.get("transparentRGB16")
            transparent_rgb16 = (
                tuple(int(value) for value in transparent_rgb16_value)
                if transparent_rgb16_value is not None
                else None
            )
            straight = expand_rgb_to_rgba(source_samples, transparent_rgb16)
            png = make_rgb_png(
                width=width,
                height=height,
                straight=source_samples,
                filters=[int(value) for value in specification["filters"]],
                split_idat=int(specification["splitIDAT"]),
                suggested_plte=(
                    SUGGESTED_TRUECOLOR_PLTE
                    if bool(specification.get("suggestedPLTE", False))
                    else None
                ),
                histogram=(
                    SUGGESTED_TRUECOLOR_HIST
                    if bool(specification.get("suggestedHIST", False))
                    else None
                ),
                transparent_rgb16=transparent_rgb16,
            )
        else:
            raise ValueError(f"unsupported sourceFormat {source_format}")
        premultiplied = premultiply_rgba(straight)
        entry = write_case(args.output_dir, specification["id"], png)
        straight_path = args.output_dir / f"{specification['id']}.straight.rgba"
        packed_path = args.output_dir / f"{specification['id']}.premultiplied.rgba"
        straight_path.write_bytes(straight)
        packed_path.write_bytes(premultiplied)
        entry.update(
            {
                "width": width,
                "height": height,
                "sourceFormat": source_format,
                "filters": specification["filters"],
                "splitIDAT": specification["splitIDAT"],
                "interlace": int(specification.get("interlace", 0)),
                "suggestedPLTE": bool(specification.get("suggestedPLTE", False)),
                "suggestedHIST": bool(specification.get("suggestedHIST", False)),
                "transparentGray16": specification.get("transparentGray16"),
                "transparentRGB16": specification.get("transparentRGB16"),
                "includeSRGB": bool(specification.get("includeSRGB", True)),
                "cicp": specification.get("cicp"),
                "colorPolicy": specification.get("colorPolicy", "preserveSource"),
                "expectedColorEncoding": specification.get("expectedColorEncoding", "sRGB"),
                "expectedSourceColorProfile": specification.get(
                    "expectedSourceColorProfile", "standardSRGB"
                ),
                "requireLibPNGSRGBClassification": specification.get(
                    "requireLibPNGSRGBClassification"
                ),
                "expectedSRGBChunkPresence": specification.get(
                    "expectedSRGBChunkPresence"
                ),
                "grayscaleBitDepth": (
                    int(source_format.removeprefix("gray"))
                    if source_format in ("gray1", "gray2", "gray4", "gray8")
                    else None
                ),
                "indexedBitDepth": (
                    int(specification.get("indexedBitDepth", 8))
                    if source_format == "indexed8"
                    else None
                ),
                "indexedPaletteEntryCount": (
                    int(
                        specification.get(
                            "indexedPaletteEntryCount",
                            1 << int(specification.get("indexedBitDepth", 8)),
                        )
                    )
                    if source_format == "indexed8"
                    else None
                ),
                "indexedAlphaCount": (
                    int(
                        specification.get(
                            "indexedAlphaCount",
                            min(
                                len(INDEXED256_ALPHA),
                                int(
                                    specification.get(
                                        "indexedPaletteEntryCount",
                                        1 << int(specification.get("indexedBitDepth", 8)),
                                    )
                                ),
                            ),
                        )
                    )
                    if source_format == "indexed8"
                    else None
                ),
                "straightRGBAPath": straight_path.name,
                "straightRGBASHA256": sha256(straight),
                "premultipliedRGBAPath": packed_path.name,
                "premultipliedRGBASHA256": sha256(premultiplied),
            }
        )
        successes.append(entry)

    base_width = 19
    base_height = 11
    base_straight = source_rgba(base_width, base_height)
    base = make_rgba_png(
        width=base_width,
        height=base_height,
        straight=base_straight,
        filters=[4, 3, 2, 1, 0],
    )
    hostile_bytes = {
        "corrupt-idat-crc": corrupt_first_idat_crc(base),
        "trailing-byte": base + b"\x00",
        "indexed8-out-of-range-index": make_indexed8_png(
            base_width,
            base_height,
            include_out_of_range_index=True,
        ),
        "indexed2-out-of-range-index": make_indexed_png(
            width=base_width,
            height=base_height,
            indices=bytes([0] * (base_width * base_height - 1) + [3]),
            filters=[4, 2, 0, 3, 1],
            split_idat=2,
            palette=INDEXED256_PALETTE[:9],
            alpha_table=INDEXED256_ALPHA[:3],
            bit_depth=2,
        ),
        "adam7-truncated-stream": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[0, 1, 2, 3, 4],
            interlace=1,
            truncate_filtered_tail=1,
        ),
        "noncontiguous-idat": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[1],
            split_idat=2,
            idat_separator=b"note\x00gap",
        ),
        "noncontiguous-idat-gamma": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[1],
            split_idat=2,
            idat_separator=struct.pack(">I", 45455),
            idat_separator_type=b"gAMA",
        ),
        "gamma-only": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[2],
            include_srgb=False,
            include_gamma=True,
        ),
        "unknown-critical-chunk": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[3],
            extra_critical=True,
        ),
        "operation-budget": base,
        "cicp-color-authority": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[4],
            include_srgb=False,
            cicp=bytes([0x0C, 0x0D, 0x00, 0x01]),
        ),
        "pq-cicp-color-authority": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[4],
            include_srgb=False,
            cicp=bytes([0x09, 0x10, 0x00, 0x01]),
        ),
        "sbit-source-precision": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[2],
            sbit=bytes([6, 6, 6, 8]),
        ),
        "untagged-color-authority": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[0],
            include_srgb=False,
        ),
        "non-rgb-icc-color-authority": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[1],
            include_srgb=False,
            icc_profile=structurally_bounded_icc_profile(b"GRAY"),
        ),
        "cmyk-icc-color-authority": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[2],
            include_srgb=False,
            icc_profile=structurally_bounded_icc_profile(b"CMYK"),
        ),
        "reserved-bit-lowercase": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[2],
            invalid_reserved_ancillary=True,
        ),
        "gamma-with-srgb": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[3],
            include_gamma=True,
        ),
        "chrm-with-srgb": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[4],
            include_chrm=True,
        ),
        "srgb-after-idat": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[0],
            include_srgb=False,
            srgb_after_idat=True,
        ),
        "mdcv-hdr-metadata": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[1],
            cicp=bytes([0x01, 0x0D, 0x00, 0x01]),
            mdcv=valid_bt709_mdcv_payload(),
        ),
        "clli-hdr-metadata": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[2],
            clli=bytes(8),
        ),
        "hist-without-plte": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[0],
            histogram=SUGGESTED_TRUECOLOR_HIST,
        ),
        "hist-length-mismatch": make_rgba_png(
            width=base_width,
            height=base_height,
            straight=base_straight,
            filters=[1],
            suggested_plte=SUGGESTED_TRUECOLOR_PLTE,
            histogram=SUGGESTED_TRUECOLOR_HIST[:-2],
        ),
        "malformed-chunk-type-byte": replace_first_chunk_type(base, b"sRGB", b"sR!B"),
    }
    hostile: list[dict[str, object]] = []
    for specification in profile["hostileCases"]:
        mutation = specification["mutation"]
        png = hostile_bytes[mutation]
        entry = write_case(args.output_dir, specification["id"], png)
        entry.update(
            {
                "mutation": mutation,
                "width": base_width,
                "height": base_height,
                "operationBudgetBytes": specification.get(
                    "operationBudgetBytes", profile["operationBudgetBytes"]
                ),
            }
        )
        hostile.append(entry)

    schema_version = int(profile.get("schemaVersion", 1))
    manifest = {
        "schemaVersion": schema_version,
        "generator": f"imagecraft-independent-png-corpus-v{schema_version}",
        "profileID": profile["profileID"],
        "successCases": successes,
        "hostileCases": hostile,
    }
    manifest_path = args.output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(manifest_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
