#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <jpeglib.h>

static int write_u16_le(FILE *file, uint16_t value) {
  unsigned char bytes[2] = {
    (unsigned char)(value & 0xFFu),
    (unsigned char)((value >> 8) & 0xFFu),
  };
  return fwrite(bytes, 1, 2, file) == 2;
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s input.jpg output-block.bin\n", argv[0]);
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
  if (cinfo.image_width != 8 || cinfo.image_height != 8 ||
      cinfo.num_components != 1 || cinfo.data_precision != 8) {
    fprintf(stderr, "probe requires one 8x8 8-bit grayscale component\n");
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 5;
  }
  jpeg_component_info *component = &cinfo.comp_info[0];
  if (component->width_in_blocks != 1 || component->height_in_blocks != 1 ||
      component->quant_tbl_no < 0 || component->quant_tbl_no >= NUM_QUANT_TBLS) {
    fprintf(stderr, "unexpected grayscale block geometry or quant table index\n");
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 6;
  }
  JQUANT_TBL *quant = cinfo.quant_tbl_ptrs[component->quant_tbl_no];
  if (quant == NULL) {
    fprintf(stderr, "missing quantization table\n");
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 7;
  }

  jvirt_barray_ptr *coefficient_arrays = jpeg_read_coefficients(&cinfo);
  if (coefficient_arrays == NULL) {
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 8;
  }
  JBLOCKARRAY rows = (*cinfo.mem->access_virt_barray)(
      (j_common_ptr)&cinfo, coefficient_arrays[0], 0, 1, FALSE);
  if (rows == NULL) {
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 9;
  }
  JCOEFPTR block = rows[0][0];

  FILE *output = fopen(argv[2], "wb");
  if (output == NULL) {
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 10;
  }
  int maximum_abs_coefficient = 0;
  int maximum_abs_dequantized = 0;
  for (int index = 0; index < DCTSIZE2; index++) {
    int coefficient = block[index];
    int absolute_coefficient = coefficient < 0 ? -coefficient : coefficient;
    int dequantized = coefficient * (int)quant->quantval[index];
    int absolute_dequantized = dequantized < 0 ? -dequantized : dequantized;
    if (absolute_coefficient > maximum_abs_coefficient)
      maximum_abs_coefficient = absolute_coefficient;
    if (absolute_dequantized > maximum_abs_dequantized)
      maximum_abs_dequantized = absolute_dequantized;
    if (!write_u16_le(output, (uint16_t)(int16_t)coefficient)) {
      fclose(output);
      jpeg_destroy_decompress(&cinfo);
      fclose(input);
      return 11;
    }
  }
  for (int index = 0; index < DCTSIZE2; index++) {
    if (!write_u16_le(output, (uint16_t)quant->quantval[index])) {
      fclose(output);
      jpeg_destroy_decompress(&cinfo);
      fclose(input);
      return 12;
    }
  }
  if (fclose(output) != 0) {
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 13;
  }

  printf("{\"schemaVersion\":1,\"width\":8,\"height\":8,"
         "\"precision\":8,\"componentCount\":1,\"progressiveMode\":%s,"
         "\"quantizationTableIndex\":%d,\"coefficientCount\":64,"
         "\"maximumAbsoluteCoefficient\":%d,"
         "\"maximumAbsoluteDequantizedCoefficient\":%d}\n",
         cinfo.progressive_mode ? "true" : "false",
         component->quant_tbl_no,
         maximum_abs_coefficient,
         maximum_abs_dequantized);

  jpeg_finish_decompress(&cinfo);
  jpeg_destroy_decompress(&cinfo);
  fclose(input);
  return 0;
}
