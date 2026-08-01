#include <png.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int write_ppm(const char *path, const png_image *image, const uint8_t *pixels) {
  FILE *output = fopen(path, "wb");
  if (output == NULL) {
    perror("fopen");
    return 0;
  }
  if (fprintf(output, "P6\n%u %u\n255\n", image->width, image->height) < 0) {
    fclose(output);
    return 0;
  }
  const size_t size = PNG_IMAGE_SIZE(*image);
  const size_t written = fwrite(pixels, 1, size, output);
  const int closed = fclose(output);
  return written == size && closed == 0;
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    puts(PNG_LIBPNG_VER_STRING);
    return 0;
  }
  if (argc != 3) {
    fprintf(stderr, "usage: %s INPUT.png OUTPUT.ppm\n", argv[0]);
    return 64;
  }

  png_image image;
  memset(&image, 0, sizeof(image));
  image.version = PNG_IMAGE_VERSION;
  if (!png_image_begin_read_from_file(&image, argv[1])) {
    fprintf(stderr, "libpng begin read failed: %s\n", image.message);
    return 1;
  }
  image.format = PNG_FORMAT_RGB;
  const size_t size = PNG_IMAGE_SIZE(image);
  uint8_t *pixels = malloc(size);
  if (pixels == NULL) {
    png_image_free(&image);
    return 1;
  }
  if (!png_image_finish_read(&image, NULL, pixels, 0, NULL)) {
    fprintf(stderr, "libpng finish read failed: %s\n", image.message);
    free(pixels);
    png_image_free(&image);
    return 1;
  }
  const int success = write_ppm(argv[2], &image, pixels);
  free(pixels);
  png_image_free(&image);
  return success ? 0 : 1;
}
