#include <lcms2.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint16_t read_be16(const unsigned char *p) {
  return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}

static void write_be16(unsigned char *p, uint16_t value) {
  p[0] = (unsigned char)(value >> 8);
  p[1] = (unsigned char)(value & 0xffu);
}

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: %s profile.icc input.rgba16be output.rgba16be\n", argv[0]);
    return 2;
  }

  FILE *input = fopen(argv[2], "rb");
  if (input == NULL) {
    perror("fopen input");
    return 3;
  }
  if (fseek(input, 0, SEEK_END) != 0) {
    fclose(input);
    return 4;
  }
  const long byte_count_long = ftell(input);
  if (byte_count_long <= 0 || byte_count_long % 8 != 0 || fseek(input, 0, SEEK_SET) != 0) {
    fclose(input);
    return 5;
  }
  const size_t byte_count = (size_t)byte_count_long;
  const size_t pixel_count = byte_count / 8u;
  unsigned char *source = (unsigned char *)malloc(byte_count);
  unsigned char *output = (unsigned char *)malloc(byte_count);
  uint16_t *source_rgb = (uint16_t *)malloc(pixel_count * 3u * sizeof(uint16_t));
  uint16_t *target_rgb = (uint16_t *)malloc(pixel_count * 3u * sizeof(uint16_t));
  if (source == NULL || output == NULL || source_rgb == NULL || target_rgb == NULL) {
    free(target_rgb);
    free(source_rgb);
    free(output);
    free(source);
    fclose(input);
    return 6;
  }
  if (fread(source, 1, byte_count, input) != byte_count) {
    free(target_rgb);
    free(source_rgb);
    free(output);
    free(source);
    fclose(input);
    return 7;
  }
  fclose(input);

  for (size_t pixel = 0; pixel < pixel_count; ++pixel) {
    const size_t source_offset = pixel * 8u;
    source_rgb[pixel * 3u] = read_be16(source + source_offset);
    source_rgb[pixel * 3u + 1u] = read_be16(source + source_offset + 2u);
    source_rgb[pixel * 3u + 2u] = read_be16(source + source_offset + 4u);
  }

  cmsHPROFILE source_profile = cmsOpenProfileFromFile(argv[1], "r");
  cmsHPROFILE target_profile = cmsCreate_sRGBProfile();
  if (source_profile == NULL || target_profile == NULL) {
    if (target_profile != NULL) cmsCloseProfile(target_profile);
    if (source_profile != NULL) cmsCloseProfile(source_profile);
    free(target_rgb);
    free(source_rgb);
    free(output);
    free(source);
    return 8;
  }
  cmsHTRANSFORM transform = cmsCreateTransform(
      source_profile, TYPE_RGB_16, target_profile, TYPE_RGB_16,
      INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_NOOPTIMIZE);
  if (transform == NULL) {
    cmsCloseProfile(target_profile);
    cmsCloseProfile(source_profile);
    free(target_rgb);
    free(source_rgb);
    free(output);
    free(source);
    return 9;
  }
  cmsDoTransform(transform, source_rgb, target_rgb, (cmsUInt32Number)pixel_count);

  const cmsCIEXYZ *target_red =
      (const cmsCIEXYZ *)cmsReadTag(target_profile, cmsSigRedColorantTag);
  const cmsCIEXYZ *target_green =
      (const cmsCIEXYZ *)cmsReadTag(target_profile, cmsSigGreenColorantTag);
  const cmsCIEXYZ *target_blue =
      (const cmsCIEXYZ *)cmsReadTag(target_profile, cmsSigBlueColorantTag);
  if (target_red == NULL || target_green == NULL || target_blue == NULL) {
    cmsDeleteTransform(transform);
    cmsCloseProfile(target_profile);
    cmsCloseProfile(source_profile);
    free(target_rgb);
    free(source_rgb);
    free(output);
    free(source);
    return 11;
  }

  for (size_t pixel = 0; pixel < pixel_count; ++pixel) {
    const size_t offset = pixel * 8u;
    write_be16(output + offset, target_rgb[pixel * 3u]);
    write_be16(output + offset + 2u, target_rgb[pixel * 3u + 1u]);
    write_be16(output + offset + 4u, target_rgb[pixel * 3u + 2u]);
    output[offset + 6u] = source[offset + 6u];
    output[offset + 7u] = source[offset + 7u];
  }

  FILE *destination = fopen(argv[3], "wb");
  if (destination == NULL || fwrite(output, 1, byte_count, destination) != byte_count) {
    if (destination != NULL) fclose(destination);
    cmsDeleteTransform(transform);
    cmsCloseProfile(target_profile);
    cmsCloseProfile(source_profile);
    free(target_rgb);
    free(source_rgb);
    free(output);
    free(source);
    return 10;
  }
  fclose(destination);

  printf(
      "{\"schemaVersion\":1,\"implementation\":\"LittleCMS\","
      "\"encodedVersion\":%u,\"pixelCount\":%zu,\"byteCount\":%zu,"
      "\"intent\":\"relativeColorimetric\",\"optimizationDisabled\":true,"
      "\"targetRGBToD50XYZ\":[[%.17g,%.17g,%.17g],[%.17g,%.17g,%.17g],"
      "[%.17g,%.17g,%.17g]]}\n",
      (unsigned)cmsGetEncodedCMMversion(), pixel_count, byte_count,
      target_red->X, target_green->X, target_blue->X,
      target_red->Y, target_green->Y, target_blue->Y,
      target_red->Z, target_green->Z, target_blue->Z);

  cmsDeleteTransform(transform);
  cmsCloseProfile(target_profile);
  cmsCloseProfile(source_profile);
  free(target_rgb);
  free(source_rgb);
  free(output);
  free(source);
  return 0;
}
