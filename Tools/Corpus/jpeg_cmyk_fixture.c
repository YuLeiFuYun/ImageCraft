#include <stddef.h>
#include <stdio.h>
#include <jpeglib.h>
#include <stdint.h>
#include <stdlib.h>

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s OUTPUT.jpg\n", argv[0]);
    return 64;
  }

  FILE *output = fopen(argv[1], "wb");
  if (output == NULL) {
    perror("fopen");
    return 1;
  }

  struct jpeg_compress_struct compressor;
  struct jpeg_error_mgr error_manager;
  compressor.err = jpeg_std_error(&error_manager);
  jpeg_create_compress(&compressor);
  jpeg_stdio_dest(&compressor, output);

  compressor.image_width = 11;
  compressor.image_height = 7;
  compressor.input_components = 4;
  compressor.in_color_space = JCS_CMYK;
  jpeg_set_defaults(&compressor);
  jpeg_set_quality(&compressor, 82, TRUE);
  jpeg_start_compress(&compressor, TRUE);

  uint8_t row[11 * 4];
  while (compressor.next_scanline < compressor.image_height) {
    const unsigned y = compressor.next_scanline;
    for (unsigned x = 0; x < compressor.image_width; ++x) {
      row[x * 4 + 0] = (uint8_t)((x * 19 + y * 7) & 0xFF);
      row[x * 4 + 1] = (uint8_t)((x * 3 + y * 31) & 0xFF);
      row[x * 4 + 2] = (uint8_t)((255 - x * 11 - y * 5) & 0xFF);
      row[x * 4 + 3] = (uint8_t)((x * 13 + y * 17) & 0x7F);
    }
    JSAMPROW rows[1] = {row};
    if (jpeg_write_scanlines(&compressor, rows, 1) != 1) {
      jpeg_destroy_compress(&compressor);
      fclose(output);
      return 1;
    }
  }

  jpeg_finish_compress(&compressor);
  jpeg_destroy_compress(&compressor);
  return fclose(output) == 0 ? 0 : 1;
}
