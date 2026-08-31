#include <setjmp.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jpeglib.h>
#include <jerror.h>

#define COMPONENT_COUNT 3

typedef struct {
  struct jpeg_error_mgr pub;
  jmp_buf jump;
  char message[JMSG_LENGTH_MAX];
  int warning_count;
} probe_error_mgr;

static void probe_error_exit(j_common_ptr common) {
  probe_error_mgr *error = (probe_error_mgr *)common->err;
  (*common->err->format_message)(common, error->message);
  longjmp(error->jump, 1);
}

static void probe_emit_message(j_common_ptr common, int message_level) {
  probe_error_mgr *error = (probe_error_mgr *)common->err;
  if (message_level < 0) error->warning_count += 1;
}

static unsigned char *read_file(const char *path, size_t *size_out) {
  FILE *file = fopen(path, "rb");
  if (file == NULL) return NULL;
  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    return NULL;
  }
  long length = ftell(file);
  if (length <= 0 || fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return NULL;
  }
  size_t size = (size_t)length;
  unsigned char *bytes = (unsigned char *)malloc(size);
  if (bytes == NULL) {
    fclose(file);
    return NULL;
  }
  if (fread(bytes, 1, size, file) != size || fclose(file) != 0) {
    free(bytes);
    return NULL;
  }
  *size_out = size;
  return bytes;
}

static int write_tight_plane(const char *path, const unsigned char *plane,
                             size_t stride, size_t width, size_t height) {
  FILE *file = fopen(path, "wb");
  if (file == NULL) return 0;
  for (size_t row = 0; row < height; row++) {
    if (fwrite(plane + row * stride, 1, width, file) != width) {
      fclose(file);
      return 0;
    }
  }
  return fclose(file) == 0;
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s input.jpg output-prefix\n", argv[0]);
    return 2;
  }

  size_t input_size = 0;
  unsigned char *input = read_file(argv[1], &input_size);
  if (input == NULL) return 3;

  struct jpeg_decompress_struct cinfo;
  probe_error_mgr error;
  memset(&cinfo, 0, sizeof(cinfo));
  memset(&error, 0, sizeof(error));
  cinfo.err = jpeg_std_error(&error.pub);
  error.pub.error_exit = probe_error_exit;
  error.pub.emit_message = probe_emit_message;
  if (setjmp(error.jump)) {
    fprintf(stderr, "libjpeg error: %s\n", error.message);
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 4;
  }

  jpeg_create_decompress(&cinfo);
  jpeg_mem_src(&cinfo, input, input_size);
  if (jpeg_read_header(&cinfo, TRUE) != JPEG_HEADER_OK ||
      cinfo.num_components != COMPONENT_COUNT ||
      cinfo.jpeg_color_space != JCS_YCbCr || cinfo.data_precision != 8) {
    fprintf(stderr, "probe requires an 8-bit three-component YCbCr JPEG\n");
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 5;
  }

  cinfo.raw_data_out = TRUE;
  cinfo.dct_method = JDCT_ISLOW;
  if (!jpeg_start_decompress(&cinfo)) {
    fprintf(stderr, "raw-data start unexpectedly suspended\n");
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 6;
  }

  const JDIMENSION lines_per_iMCU =
      (JDIMENSION)(cinfo.max_v_samp_factor * cinfo.min_DCT_v_scaled_size);
  unsigned char *planes[COMPONENT_COUNT] = {NULL, NULL, NULL};
  size_t strides[COMPONENT_COUNT] = {0, 0, 0};
  size_t widths[COMPONENT_COUNT] = {0, 0, 0};
  size_t heights[COMPONENT_COUNT] = {0, 0, 0};
  size_t padded_heights[COMPONENT_COUNT] = {0, 0, 0};

  for (int ci = 0; ci < COMPONENT_COUNT; ci++) {
    jpeg_component_info *component = &cinfo.comp_info[ci];
    size_t stride = (size_t)component->width_in_blocks *
                    (size_t)component->DCT_h_scaled_size;
    size_t rows_per_iMCU = (size_t)component->v_samp_factor *
                           (size_t)component->DCT_v_scaled_size;
    size_t padded_height = (size_t)cinfo.total_iMCU_rows * rows_per_iMCU;
    if (stride == 0 || padded_height == 0 ||
        padded_height > SIZE_MAX / stride) {
      fprintf(stderr, "raw plane geometry overflow\n");
      jpeg_destroy_decompress(&cinfo);
      free(input);
      return 7;
    }
    planes[ci] = (unsigned char *)calloc(padded_height, stride);
    if (planes[ci] == NULL) {
      for (int j = 0; j < ci; j++) free(planes[j]);
      jpeg_destroy_decompress(&cinfo);
      free(input);
      return 7;
    }
    strides[ci] = stride;
    widths[ci] = (size_t)component->downsampled_width;
    heights[ci] = (size_t)component->downsampled_height;
    padded_heights[ci] = padded_height;
    if (widths[ci] == 0 || heights[ci] == 0 || widths[ci] > stride ||
        heights[ci] > padded_height) {
      fprintf(stderr, "raw plane visible geometry is invalid\n");
      for (int j = 0; j <= ci; j++) free(planes[j]);
      jpeg_destroy_decompress(&cinfo);
      free(input);
      return 7;
    }
  }

  size_t iMCU_index = 0;
  while (cinfo.output_scanline < cinfo.output_height) {
    JSAMPROW rows[COMPONENT_COUNT][DCTSIZE * MAX_SAMP_FACTOR];
    JSAMPARRAY image[COMPONENT_COUNT];
    for (int ci = 0; ci < COMPONENT_COUNT; ci++) {
      jpeg_component_info *component = &cinfo.comp_info[ci];
      size_t rows_per_iMCU = (size_t)component->v_samp_factor *
                             (size_t)component->DCT_v_scaled_size;
      size_t base_row = iMCU_index * rows_per_iMCU;
      if (rows_per_iMCU > DCTSIZE * MAX_SAMP_FACTOR ||
          base_row + rows_per_iMCU > padded_heights[ci]) {
        fprintf(stderr, "raw iMCU row geometry is invalid\n");
        for (int j = 0; j < COMPONENT_COUNT; j++) free(planes[j]);
        jpeg_destroy_decompress(&cinfo);
        free(input);
        return 8;
      }
      for (size_t row = 0; row < rows_per_iMCU; row++)
        rows[ci][row] = planes[ci] + (base_row + row) * strides[ci];
      image[ci] = rows[ci];
    }
    JDIMENSION returned = jpeg_read_raw_data(&cinfo, image, lines_per_iMCU);
    if (returned != lines_per_iMCU) {
      fprintf(stderr, "raw read returned an unexpected row count\n");
      for (int j = 0; j < COMPONENT_COUNT; j++) free(planes[j]);
      jpeg_destroy_decompress(&cinfo);
      free(input);
      return 8;
    }
    iMCU_index += 1;
  }

  if (!jpeg_finish_decompress(&cinfo)) {
    fprintf(stderr, "raw finish unexpectedly suspended\n");
    for (int j = 0; j < COMPONENT_COUNT; j++) free(planes[j]);
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 9;
  }

  const char *suffixes[COMPONENT_COUNT] = {"Y.raw", "Cb.raw", "Cr.raw"};
  char path[4096];
  for (int ci = 0; ci < COMPONENT_COUNT; ci++) {
    if (snprintf(path, sizeof(path), "%s-%s", argv[2], suffixes[ci]) < 0 ||
        !write_tight_plane(path, planes[ci], strides[ci], widths[ci], heights[ci])) {
      fprintf(stderr, "failed to write raw component plane\n");
      for (int j = 0; j < COMPONENT_COUNT; j++) free(planes[j]);
      jpeg_destroy_decompress(&cinfo);
      free(input);
      return 10;
    }
  }

  printf("{\"schemaVersion\":1,\"implementation\":\"libjpeg-turbo.classic.raw-data-out\","
         "\"width\":%u,\"height\":%u,\"warningCount\":%d,"
         "\"progressiveMode\":%s,"
         "\"dctMethod\":\"islow\",\"maxHorizontalSamplingFactor\":%d,"
         "\"maxVerticalSamplingFactor\":%d,\"components\":[",
         cinfo.output_width, cinfo.output_height, error.warning_count,
         cinfo.progressive_mode ? "true" : "false",
         cinfo.max_h_samp_factor, cinfo.max_v_samp_factor);
  for (int ci = 0; ci < COMPONENT_COUNT; ci++) {
    jpeg_component_info *component = &cinfo.comp_info[ci];
    if (ci != 0) printf(",");
    printf("{\"componentID\":%d,\"horizontalSamplingFactor\":%d,"
           "\"verticalSamplingFactor\":%d,\"width\":%zu,\"height\":%zu,"
           "\"paddedStride\":%zu,\"paddedHeight\":%zu}",
           component->component_id, component->h_samp_factor,
           component->v_samp_factor, widths[ci], heights[ci], strides[ci],
           padded_heights[ci]);
  }
  printf("]}\n");

  for (int ci = 0; ci < COMPONENT_COUNT; ci++) free(planes[ci]);
  jpeg_destroy_decompress(&cinfo);
  free(input);
  return 0;
}
