#include <png.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s INPUT.png OUTPUT.rgba\n", argv[0]);
    return 2;
  }

  png_image image;
  memset(&image, 0, sizeof(image));
  image.version = PNG_IMAGE_VERSION;
  if (!png_image_begin_read_from_file(&image, argv[1])) {
    fprintf(stderr, "png_image_begin_read_from_file: %s\n", image.message);
    return 3;
  }
  image.format = PNG_FORMAT_RGBA;

  const png_alloc_size_t byte_count = PNG_IMAGE_SIZE(image);
  if (byte_count == 0 || image.width == 0 || image.height == 0) {
    fprintf(stderr, "invalid decoded dimensions\n");
    png_image_free(&image);
    return 4;
  }
  void *buffer = malloc((size_t)byte_count);
  if (buffer == NULL) {
    fprintf(stderr, "allocation failed\n");
    png_image_free(&image);
    return 5;
  }
  if (!png_image_finish_read(&image, NULL, buffer, 0, NULL)) {
    fprintf(stderr, "png_image_finish_read: %s\n", image.message);
    free(buffer);
    png_image_free(&image);
    return 6;
  }

  FILE *output = fopen(argv[2], "wb");
  if (output == NULL) {
    perror("fopen");
    free(buffer);
    png_image_free(&image);
    return 7;
  }
  if (fwrite(buffer, 1, (size_t)byte_count, output) != (size_t)byte_count) {
    perror("fwrite");
    fclose(output);
    free(buffer);
    png_image_free(&image);
    return 8;
  }
  fclose(output);

  printf(
      "{\"schemaVersion\":1,\"implementation\":\"libpng.png_image\","
      "\"width\":%u,\"height\":%u,\"bytesPerRow\":%u,\"byteCount\":%zu,"
      "\"flags\":%u,\"colorspaceNotSRGB\":%s,\"associatedAlpha\":%s,"
      "\"warningOrError\":%u}\n",
      image.width, image.height, image.width * 4u, (size_t)byte_count,
      image.flags,
      (image.flags & PNG_IMAGE_FLAG_COLORSPACE_NOT_sRGB) != 0 ? "true" : "false",
      (image.format & PNG_FORMAT_FLAG_ASSOCIATED_ALPHA) != 0 ? "true" : "false",
      image.warning_or_error);

  free(buffer);
  png_image_free(&image);
  return 0;
}
