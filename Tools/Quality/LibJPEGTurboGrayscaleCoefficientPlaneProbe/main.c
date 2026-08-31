#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <jpeglib.h>

static int write_i16_le(FILE *file, int value) {
  int16_t signed_value = (int16_t)value;
  uint16_t raw = (uint16_t)signed_value;
  unsigned char bytes[2] = {
    (unsigned char)(raw & 0xFFu),
    (unsigned char)((raw >> 8) & 0xFFu),
  };
  return fwrite(bytes, 1, 2, file) == 2;
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s input.jpg output-coefficients.bin\n", argv[0]);
    return 2;
  }
  FILE *input = fopen(argv[1], "rb");
  if (input == NULL) return 3;

  struct jpeg_decompress_struct cinfo;
  struct jpeg_error_mgr jerr;
  cinfo.err = jpeg_std_error(&jerr);
  jpeg_create_decompress(&cinfo);
  jpeg_stdio_src(&cinfo, input);
  if (jpeg_read_header(&cinfo, TRUE) != JPEG_HEADER_OK) {
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 4;
  }
  if (cinfo.num_components != 1 || cinfo.data_precision != 8) {
    fprintf(stderr, "probe requires one 8-bit grayscale component\n");
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 5;
  }
  jpeg_component_info *component = &cinfo.comp_info[0];
  if (component->h_samp_factor != 1 || component->v_samp_factor != 1 ||
      component->width_in_blocks == 0 || component->height_in_blocks == 0) {
    fprintf(stderr, "unexpected grayscale block geometry\n");
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 6;
  }

  jvirt_barray_ptr *arrays = jpeg_read_coefficients(&cinfo);
  if (arrays == NULL) {
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 7;
  }
  FILE *output = fopen(argv[2], "wb");
  if (output == NULL) {
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 8;
  }

  size_t block_count = 0;
  int maximum_absolute_coefficient = 0;
  for (JDIMENSION row = 0; row < component->height_in_blocks; row++) {
    JBLOCKARRAY rows = (*cinfo.mem->access_virt_barray)(
        (j_common_ptr)&cinfo, arrays[0], row, 1, FALSE);
    if (rows == NULL) {
      fclose(output);
      jpeg_destroy_decompress(&cinfo);
      fclose(input);
      return 9;
    }
    for (JDIMENSION column = 0; column < component->width_in_blocks; column++) {
      JCOEFPTR block = rows[0][column];
      for (int index = 0; index < DCTSIZE2; index++) {
        int value = block[index];
        int absolute = value < 0 ? -value : value;
        if (absolute > maximum_absolute_coefficient)
          maximum_absolute_coefficient = absolute;
        if (!write_i16_le(output, value)) {
          fclose(output);
          jpeg_destroy_decompress(&cinfo);
          fclose(input);
          return 10;
        }
      }
      block_count++;
    }
  }
  if (fclose(output) != 0) {
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 11;
  }

  size_t coefficient_count = block_count * DCTSIZE2;
  size_t coefficient_bytes = coefficient_count * sizeof(int16_t);
  printf("{\"schemaVersion\":1,\"width\":%u,\"height\":%u,"
         "\"progressiveMode\":%s,\"widthInBlocks\":%u,\"heightInBlocks\":%u,"
         "\"blockCount\":%zu,\"coefficientCount\":%zu,"
         "\"coefficientByteCount\":%zu,\"maximumAbsoluteCoefficient\":%d}\n",
         cinfo.image_width, cinfo.image_height,
         cinfo.progressive_mode ? "true" : "false",
         component->width_in_blocks, component->height_in_blocks,
         block_count, coefficient_count, coefficient_bytes,
         maximum_absolute_coefficient);

  if (!jpeg_finish_decompress(&cinfo)) {
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 12;
  }
  jpeg_destroy_decompress(&cinfo);
  fclose(input);
  return 0;
}
