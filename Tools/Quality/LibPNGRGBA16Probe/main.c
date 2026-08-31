#include <png.h>

#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  if (argc != 3 && argc != 4) {
    fprintf(stderr, "usage: %s INPUT.png OUTPUT.rgba16be [OUTPUT.icc]\n", argv[0]);
    return 2;
  }

  FILE *input = fopen(argv[1], "rb");
  if (input == NULL) {
    perror("fopen input");
    return 3;
  }
  png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
  if (png == NULL) {
    fclose(input);
    return 4;
  }
  png_infop info = png_create_info_struct(png);
  if (info == NULL) {
    png_destroy_read_struct(&png, NULL, NULL);
    fclose(input);
    return 5;
  }
  if (setjmp(png_jmpbuf(png))) {
    png_destroy_read_struct(&png, &info, NULL);
    fclose(input);
    return 6;
  }

  png_init_io(png, input);
  png_read_info(png, info);
  png_uint_32 width = 0;
  png_uint_32 height = 0;
  int bit_depth = 0;
  int color_type = 0;
  int interlace_type = 0;
  int compression_type = 0;
  int filter_type = 0;
  if (!png_get_IHDR(
          png, info, &width, &height, &bit_depth, &color_type, &interlace_type,
          &compression_type, &filter_type)) {
    fprintf(stderr, "missing IHDR\n");
    png_destroy_read_struct(&png, &info, NULL);
    fclose(input);
    return 7;
  }
  int intent = -1;
  const png_uint_32 has_srgb = png_get_sRGB(png, info, &intent);
  png_charp icc_name = NULL;
  int icc_compression = -1;
  png_bytep icc_profile = NULL;
  png_uint_32 icc_profile_length = 0;
  const int has_iccp = png_get_iCCP(
      png, info, &icc_name, &icc_compression, &icc_profile, &icc_profile_length) != 0;
  png_byte cicp_primaries = 0;
  png_byte cicp_transfer = 0;
  png_byte cicp_matrix = 0;
  png_byte cicp_full_range = 0;
  const int has_cicp = png_get_cICP(
      png, info, &cicp_primaries, &cicp_transfer, &cicp_matrix, &cicp_full_range) != 0;
  png_fixed_point mdcv_white_x = 0;
  png_fixed_point mdcv_white_y = 0;
  png_fixed_point mdcv_red_x = 0;
  png_fixed_point mdcv_red_y = 0;
  png_fixed_point mdcv_green_x = 0;
  png_fixed_point mdcv_green_y = 0;
  png_fixed_point mdcv_blue_x = 0;
  png_fixed_point mdcv_blue_y = 0;
  png_uint_32 mdcv_maximum_luminance = 0;
  png_uint_32 mdcv_minimum_luminance = 0;
  const int has_mdcv = png_get_mDCV_fixed(
      png, info, &mdcv_white_x, &mdcv_white_y, &mdcv_red_x, &mdcv_red_y,
      &mdcv_green_x, &mdcv_green_y, &mdcv_blue_x, &mdcv_blue_y,
      &mdcv_maximum_luminance, &mdcv_minimum_luminance) != 0;
  png_uint_32 maximum_content_light_level = 0;
  png_uint_32 maximum_frame_average_light_level = 0;
  const int has_clli = png_get_cLLI_fixed(
      png, info, &maximum_content_light_level, &maximum_frame_average_light_level) != 0;
  png_color_8p significant_bits = NULL;
  const int has_sbit = png_get_sBIT(png, info, &significant_bits) != 0;
  const int source_is_gray =
      color_type == PNG_COLOR_TYPE_GRAY || color_type == PNG_COLOR_TYPE_GRAY_ALPHA;
  const int source_has_alpha =
      color_type == PNG_COLOR_TYPE_GRAY_ALPHA || color_type == PNG_COLOR_TYPE_RGB_ALPHA;
  const int sbit_gray = has_sbit && source_is_gray ? significant_bits->gray : 0;
  const int sbit_red = has_sbit && !source_is_gray ? significant_bits->red : 0;
  const int sbit_green = has_sbit && !source_is_gray ? significant_bits->green : 0;
  const int sbit_blue = has_sbit && !source_is_gray ? significant_bits->blue : 0;
  /* png_color_8 always has an alpha field. libpng may populate that field with the sample depth even
     when the source has no alpha. Source provenance must be derived from IHDR, not struct shape. */
  const int raw_sbit_alpha_field = has_sbit ? significant_bits->alpha : 0;
  const int sbit_alpha = has_sbit && source_has_alpha ? raw_sbit_alpha_field : 0;
  if (width == 0 || height == 0 || bit_depth != 16 ||
      (color_type != PNG_COLOR_TYPE_GRAY && color_type != PNG_COLOR_TYPE_GRAY_ALPHA &&
       color_type != PNG_COLOR_TYPE_RGB && color_type != PNG_COLOR_TYPE_RGB_ALPHA) ||
      (interlace_type != PNG_INTERLACE_NONE && interlace_type != PNG_INTERLACE_ADAM7) ||
      compression_type != PNG_COMPRESSION_TYPE_BASE || filter_type != PNG_FILTER_TYPE_BASE ||
      ((has_srgb != 0) + has_iccp + has_cicp != 1)) {
    fprintf(stderr, "outside gray/GA/RGB/RGBA16 explicit-color oracle domain\n");
    png_destroy_read_struct(&png, &info, NULL);
    fclose(input);
    return 8;
  }

  const int has_trns = png_get_valid(png, info, PNG_INFO_tRNS) != 0;
  int expanded_trns = 0;
  int added_opaque_alpha = 0;
  if (!source_has_alpha) {
    if (has_trns) {
      png_set_tRNS_to_alpha(png);
      expanded_trns = 1;
    } else {
      png_set_add_alpha(png, 0xFFFFu, PNG_FILLER_AFTER);
      added_opaque_alpha = 1;
    }
  } else if (has_trns) {
    fprintf(stderr, "stored-alpha source unexpectedly carries tRNS\n");
    png_destroy_read_struct(&png, &info, NULL);
    fclose(input);
    return 9;
  }
  if (source_is_gray) {
    png_set_gray_to_rgb(png);
  }

  /* Do not call png_set_swap or png_set_strip_16. The classic read API therefore keeps every
     16-bit output sample in PNG/network byte order. Gray is independently replicated into RGB;
     gray/RGB+tRNS is expanded by libpng, and no-alpha sources receive opaque 16-bit alpha. Adam7
     reconstruction is delegated to libpng and produces full logical rows. */
  const int interlace_passes = png_set_interlace_handling(png);
  png_read_update_info(png, info);
  const png_size_t row_bytes = png_get_rowbytes(png, info);
  const size_t expected_row_bytes = (size_t)width * 8u;
  if (row_bytes != expected_row_bytes || height > SIZE_MAX / expected_row_bytes) {
    fprintf(stderr, "unexpected libpng row layout\n");
    png_destroy_read_struct(&png, &info, NULL);
    fclose(input);
    return 10;
  }
  const size_t byte_count = expected_row_bytes * (size_t)height;
  png_bytep buffer = (png_bytep)malloc(byte_count);
  png_bytep *rows = (png_bytep *)malloc(sizeof(png_bytep) * (size_t)height);
  if (buffer == NULL || rows == NULL) {
    free(rows);
    free(buffer);
    png_destroy_read_struct(&png, &info, NULL);
    fclose(input);
    return 11;
  }
  for (png_uint_32 y = 0; y < height; ++y) {
    rows[y] = buffer + (size_t)y * expected_row_bytes;
  }
  png_read_image(png, rows);
  png_read_end(png, info);
  fclose(input);

  FILE *output = fopen(argv[2], "wb");
  if (output == NULL) {
    perror("fopen output");
    free(rows);
    free(buffer);
    png_destroy_read_struct(&png, &info, NULL);
    return 12;
  }
  if (fwrite(buffer, 1, byte_count, output) != byte_count) {
    perror("fwrite");
    fclose(output);
    free(rows);
    free(buffer);
    png_destroy_read_struct(&png, &info, NULL);
    return 13;
  }
  fclose(output);

  if (argc == 4) {
    FILE *icc_output = fopen(argv[3], "wb");
    if (icc_output == NULL) {
      perror("fopen ICC output");
      free(rows);
      free(buffer);
      png_destroy_read_struct(&png, &info, NULL);
      return 14;
    }
    if (has_iccp &&
        fwrite(icc_profile, 1, (size_t)icc_profile_length, icc_output) != (size_t)icc_profile_length) {
      perror("fwrite ICC");
      fclose(icc_output);
      free(rows);
      free(buffer);
      png_destroy_read_struct(&png, &info, NULL);
      return 15;
    }
    fclose(icc_output);
  }

  printf(
      "{\"schemaVersion\":1,\"implementation\":\"libpng.classic.rgba16\","
      "\"width\":%u,\"height\":%u,\"bitDepth\":%d,\"sourceColorType\":%d,"
      "\"bytesPerRow\":%zu,\"byteCount\":%zu,\"outputByteOrder\":\"bigEndian\","
      "\"alphaAssociation\":\"straight\",\"tRNSExpanded\":%s,"
      "\"opaqueAlphaAdded\":%s,\"hasSBIT\":%s,\"sBITGray\":%d,\"sBITRed\":%d,"
      "\"sBITGreen\":%d,\"sBITBlue\":%d,\"sBITAlpha\":%d,"
      "\"libpngSBITAlphaFieldRaw\":%d,\"sourceInterlaceType\":%d,"
      "\"interlacePasses\":%d,\"sRGBIntent\":%d,\"hasICCP\":%s,"
      "\"iccProfileLength\":%u,\"hasCICP\":%s,\"cicpColorPrimaries\":%u,"
      "\"cicpTransferFunction\":%u,\"cicpMatrixCoefficients\":%u,"
      "\"cicpVideoFullRangeFlag\":%u,\"hasMDCV\":%s,"
      "\"mdcvRedXFixed\":%d,\"mdcvRedYFixed\":%d,"
      "\"mdcvGreenXFixed\":%d,\"mdcvGreenYFixed\":%d,"
      "\"mdcvBlueXFixed\":%d,\"mdcvBlueYFixed\":%d,"
      "\"mdcvWhiteXFixed\":%d,\"mdcvWhiteYFixed\":%d,"
      "\"mdcvMaximumLuminanceScaledBy10000\":%u,"
      "\"mdcvMinimumLuminanceScaledBy10000\":%u,\"hasCLLI\":%s,"
      "\"maximumContentLightLevelScaledBy10000\":%u,"
      "\"maximumFrameAverageLightLevelScaledBy10000\":%u,"
      "\"colorAuthority\":\"%s\"}\n",
      width, height, bit_depth, color_type, expected_row_bytes, byte_count,
      expanded_trns ? "true" : "false", added_opaque_alpha ? "true" : "false",
      has_sbit ? "true" : "false", sbit_gray, sbit_red, sbit_green, sbit_blue, sbit_alpha,
      raw_sbit_alpha_field, interlace_type, interlace_passes, intent,
      has_iccp ? "true" : "false", icc_profile_length, has_cicp ? "true" : "false",
      cicp_primaries, cicp_transfer, cicp_matrix, cicp_full_range,
      has_mdcv ? "true" : "false", mdcv_red_x, mdcv_red_y, mdcv_green_x, mdcv_green_y,
      mdcv_blue_x, mdcv_blue_y, mdcv_white_x, mdcv_white_y,
      mdcv_maximum_luminance, mdcv_minimum_luminance, has_clli ? "true" : "false",
      maximum_content_light_level, maximum_frame_average_light_level,
      has_cicp ? "cICP" : (has_iccp ? "rgbICC" : "sRGB"));

  free(rows);
  free(buffer);
  png_destroy_read_struct(&png, &info, NULL);
  return 0;
}
