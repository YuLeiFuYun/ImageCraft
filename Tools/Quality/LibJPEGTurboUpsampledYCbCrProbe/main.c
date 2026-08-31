#include <stdio.h>
#include <stdlib.h>

#include <jpeglib.h>

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s input.jpg output-cb.raw\n", argv[0]);
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
  cinfo.out_color_space = JCS_YCbCr;
  cinfo.do_fancy_upsampling = TRUE;
  if (!jpeg_start_decompress(&cinfo) || cinfo.output_components != 3) {
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 5;
  }

  size_t row_bytes = (size_t)cinfo.output_width * 3;
  size_t cb_bytes = (size_t)cinfo.output_width * (size_t)cinfo.output_height;
  unsigned char *row = (unsigned char *)malloc(row_bytes == 0 ? 1 : row_bytes);
  unsigned char *cb = (unsigned char *)malloc(cb_bytes == 0 ? 1 : cb_bytes);
  if (row == NULL || cb == NULL) {
    free(row);
    free(cb);
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 6;
  }
  while (cinfo.output_scanline < cinfo.output_height) {
    JDIMENSION output_row = cinfo.output_scanline;
    JSAMPROW row_pointer = row;
    if (jpeg_read_scanlines(&cinfo, &row_pointer, 1) != 1) {
      free(row);
      free(cb);
      jpeg_destroy_decompress(&cinfo);
      fclose(input);
      return 7;
    }
    for (JDIMENSION column = 0; column < cinfo.output_width; column++)
      cb[(size_t)output_row * cinfo.output_width + column] = row[column * 3 + 1];
  }
  if (!jpeg_finish_decompress(&cinfo)) {
    free(row);
    free(cb);
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 8;
  }

  FILE *output = fopen(argv[2], "wb");
  if (output == NULL || (cb_bytes != 0 && fwrite(cb, 1, cb_bytes, output) != cb_bytes)) {
    if (output != NULL) fclose(output);
    free(row);
    free(cb);
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 9;
  }
  if (fclose(output) != 0) {
    free(row);
    free(cb);
    jpeg_destroy_decompress(&cinfo);
    fclose(input);
    return 10;
  }
  printf("{\"schemaVersion\":1,\"width\":%u,\"height\":%u,"
         "\"outputComponents\":3,\"fancyUpsampling\":true}\n",
         cinfo.output_width, cinfo.output_height);
  free(row);
  free(cb);
  jpeg_destroy_decompress(&cinfo);
  fclose(input);
  return 0;
}
