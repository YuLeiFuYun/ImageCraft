#include <stdio.h>
#include <stdlib.h>

#include <jpeglib.h>

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s input.jpg output-ycbcr.raw\n", argv[0]);
    return 2;
  }
  FILE *input = fopen(argv[1], "rb");
  if (input == NULL) return 3;
  FILE *output = fopen(argv[2], "wb");
  if (output == NULL) {
    fclose(input);
    return 4;
  }

  struct jpeg_decompress_struct cinfo;
  struct jpeg_error_mgr jerr;
  cinfo.err = jpeg_std_error(&jerr);
  jpeg_create_decompress(&cinfo);
  jpeg_stdio_src(&cinfo, input);
  if (jpeg_read_header(&cinfo, TRUE) != JPEG_HEADER_OK) {
    jpeg_destroy_decompress(&cinfo);
    fclose(output);
    fclose(input);
    return 5;
  }
  if (cinfo.data_precision != 8 || cinfo.num_components != 3) {
    fprintf(stderr, "probe requires 8-bit three-component JPEG\n");
    jpeg_destroy_decompress(&cinfo);
    fclose(output);
    fclose(input);
    return 6;
  }
  cinfo.out_color_space = JCS_YCbCr;
  cinfo.do_fancy_upsampling = TRUE;
  cinfo.dct_method = JDCT_ISLOW;
  if (!jpeg_start_decompress(&cinfo)) {
    jpeg_destroy_decompress(&cinfo);
    fclose(output);
    fclose(input);
    return 7;
  }
  if (cinfo.output_components != 3 || cinfo.output_width == 0 || cinfo.output_height == 0) {
    fprintf(stderr, "unexpected JCS_YCbCr output geometry\n");
    jpeg_destroy_decompress(&cinfo);
    fclose(output);
    fclose(input);
    return 8;
  }

  size_t row_bytes = (size_t)cinfo.output_width * 3u;
  JSAMPLE *row_storage = (JSAMPLE *)malloc(row_bytes == 0 ? 1 : row_bytes);
  if (row_storage == NULL) {
    jpeg_destroy_decompress(&cinfo);
    fclose(output);
    fclose(input);
    return 9;
  }
  JSAMPROW row = row_storage;
  while (cinfo.output_scanline < cinfo.output_height) {
    if (jpeg_read_scanlines(&cinfo, &row, 1) != 1) {
      free(row_storage);
      jpeg_destroy_decompress(&cinfo);
      fclose(output);
      fclose(input);
      return 10;
    }
    if (fwrite(row_storage, 1, row_bytes, output) != row_bytes) {
      free(row_storage);
      jpeg_destroy_decompress(&cinfo);
      fclose(output);
      fclose(input);
      return 11;
    }
  }
  free(row_storage);
  if (!jpeg_finish_decompress(&cinfo)) {
    jpeg_destroy_decompress(&cinfo);
    fclose(output);
    fclose(input);
    return 12;
  }
  if (fclose(output) != 0) {
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 13;
  }

  printf("{\"schemaVersion\":1,\"width\":%u,\"height\":%u,"
         "\"outputComponents\":3,\"progressiveMode\":%s,"
         "\"fancyUpsampling\":true,\"dctMethod\":\"islow\"}\n",
         cinfo.output_width, cinfo.output_height,
         cinfo.progressive_mode ? "true" : "false");

  jpeg_destroy_decompress(&cinfo);
  fclose(input);
  return 0;
}
