#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jpeglib.h>

typedef struct {
  struct jpeg_error_mgr pub;
  jmp_buf jump;
  char message[JMSG_LENGTH_MAX];
} probe_error_mgr;

static void probe_error_exit(j_common_ptr cinfo) {
  probe_error_mgr *error = (probe_error_mgr *)cinfo->err;
  (*cinfo->err->format_message)(cinfo, error->message);
  longjmp(error->jump, 1);
}

static unsigned char *read_file(const char *path, size_t *size_out) {
  FILE *file = fopen(path, "rb");
  if (file == NULL) return NULL;
  if (fseek(file, 0, SEEK_END) != 0) { fclose(file); return NULL; }
  long raw_size = ftell(file);
  if (raw_size <= 0 || fseek(file, 0, SEEK_SET) != 0) { fclose(file); return NULL; }
  size_t size = (size_t)raw_size;
  unsigned char *bytes = (unsigned char *)malloc(size);
  if (bytes == NULL) { fclose(file); return NULL; }
  if (fread(bytes, 1, size, file) != size || fclose(file) != 0) {
    free(bytes);
    return NULL;
  }
  *size_out = size;
  return bytes;
}

static JDIMENSION round_up_blocks(JDIMENSION value, int factor) {
  JDIMENSION divisor = (JDIMENSION)factor;
  return ((value + divisor - 1) / divisor) * divisor;
}

static int write_int16_le(FILE *file, JCOEF value) {
  uint16_t bits = (uint16_t)(int16_t)value;
  unsigned char bytes[2] = {
    (unsigned char)(bits & 0xffu),
    (unsigned char)((bits >> 8) & 0xffu)
  };
  return fwrite(bytes, 1, 2, file) == 2;
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s input.jpg output.coefficients.bin\n", argv[0]);
    return 2;
  }
  if (sizeof(JCOEF) != 2 || sizeof(JBLOCK) != 128) {
    fprintf(stderr, "probe requires 16-bit JCOEF / 128-byte JBLOCK\n");
    return 3;
  }

  size_t input_size = 0;
  unsigned char *input = read_file(argv[1], &input_size);
  if (input == NULL) return 4;

  struct jpeg_decompress_struct cinfo;
  probe_error_mgr error;
  memset(&cinfo, 0, sizeof(cinfo));
  memset(&error, 0, sizeof(error));
  cinfo.err = jpeg_std_error(&error.pub);
  error.pub.error_exit = probe_error_exit;
  if (setjmp(error.jump)) {
    fprintf(stderr, "libjpeg error: %s\n", error.message);
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 5;
  }

  jpeg_create_decompress(&cinfo);
  jpeg_mem_src(&cinfo, input, (unsigned long)input_size);
  if (jpeg_read_header(&cinfo, TRUE) != JPEG_HEADER_OK ||
      !cinfo.progressive_mode || cinfo.data_precision != 8 ||
      cinfo.num_components != 3) {
    fprintf(stderr, "probe requires 8-bit three-component progressive JPEG\n");
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 6;
  }
  jvirt_barray_ptr *arrays = jpeg_read_coefficients(&cinfo);
  if (arrays == NULL) {
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 7;
  }

  FILE *output = fopen(argv[2], "wb");
  if (output == NULL) {
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 8;
  }
  size_t total_bytes = 0;
  size_t component_bytes[3] = {0, 0, 0};
  JDIMENSION padded_width[3] = {0, 0, 0};
  JDIMENSION padded_height[3] = {0, 0, 0};
  for (int ci = 0; ci < 3; ci++) {
    jpeg_component_info *component = &cinfo.comp_info[ci];
    padded_width[ci] = round_up_blocks(component->width_in_blocks,
                                       component->h_samp_factor);
    padded_height[ci] = round_up_blocks(component->height_in_blocks,
                                        component->v_samp_factor);
    for (JDIMENSION row = 0; row < padded_height[ci]; row++) {
      JBLOCKARRAY rows = (*cinfo.mem->access_virt_barray)(
        (j_common_ptr)&cinfo, arrays[ci], row, 1, FALSE);
      JBLOCKROW blocks = rows[0];
      for (JDIMENSION column = 0; column < padded_width[ci]; column++) {
        for (int coefficient = 0; coefficient < DCTSIZE2; coefficient++) {
          if (!write_int16_le(output, blocks[column][coefficient])) {
            fclose(output);
            jpeg_destroy_decompress(&cinfo);
            free(input);
            return 9;
          }
          component_bytes[ci] += 2;
          total_bytes += 2;
        }
      }
    }
  }
  if (fclose(output) != 0 || !jpeg_finish_decompress(&cinfo)) {
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 10;
  }

  printf("{\"schemaVersion\":1,\"implementation\":\"libjpeg-turbo.jpeg_read_coefficients\","
         "\"progressiveMode\":true,\"width\":%u,\"height\":%u,"
         "\"coefficientByteCount\":%zu,\"components\":[",
         cinfo.image_width, cinfo.image_height, total_bytes);
  for (int ci = 0; ci < 3; ci++) {
    jpeg_component_info *component = &cinfo.comp_info[ci];
    if (ci != 0) printf(",");
    printf("{\"componentIndex\":%d,\"componentID\":%d,"
           "\"horizontalSamplingFactor\":%d,\"verticalSamplingFactor\":%d,"
           "\"widthInBlocks\":%u,\"heightInBlocks\":%u,"
           "\"paddedWidthInBlocks\":%u,\"paddedHeightInBlocks\":%u,"
           "\"coefficientByteCount\":%zu}",
           ci, component->component_id,
           component->h_samp_factor, component->v_samp_factor,
           component->width_in_blocks, component->height_in_blocks,
           padded_width[ci], padded_height[ci], component_bytes[ci]);
  }
  printf("]}\n");

  jpeg_destroy_decompress(&cinfo);
  free(input);
  return 0;
}
