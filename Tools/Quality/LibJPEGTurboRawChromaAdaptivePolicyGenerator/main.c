#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jpeglib.h>

#define WIDTH 64
#define HEIGHT 64
#define CHROMA_HEIGHT (HEIGHT / 2)
#define MAX_CHROMA_WIDTH WIDTH

static int supported_signal(const char *signal) {
  return strcmp(signal, "quadratic") == 0 ||
         strcmp(signal, "kink") == 0 ||
         strcmp(signal, "step-off24") == 0 ||
         strcmp(signal, "step-small") == 0 ||
         strcmp(signal, "ramp-step") == 0 ||
         strcmp(signal, "impulse31") == 0;
}

static unsigned char source_cb_code(const char *signal, int row) {
  if (strcmp(signal, "quadratic") == 0)
    return (unsigned char)(80 + (80 * row * row + 1984) / 3969);
  if (strcmp(signal, "kink") == 0)
    return (unsigned char)(row < 32 ? 64 + row : 96 + 3 * (row - 32));
  if (strcmp(signal, "step-off24") == 0)
    return (unsigned char)(row < 24 ? 80 : 176);
  if (strcmp(signal, "step-small") == 0)
    return (unsigned char)(row < 32 ? 112 : 120);
  if (strcmp(signal, "ramp-step") == 0)
    return (unsigned char)(64 + 2 * row + (row >= 32 ? 24 : 0));
  return (unsigned char)(128 + (row == 31 ? 32 : 0));
}

static unsigned char subsampled_cb_code(const char *signal, int row) {
  int first = source_cb_code(signal, row * 2);
  int second = source_cb_code(signal, row * 2 + 1);
  return (unsigned char)((first + second) / 2);
}

int main(int argc, char **argv) {
  if (argc < 4 || argc > 5) {
    fprintf(stderr,
            "usage: %s <440|420> output.jpg <progressive|baseline> "
            "[quadratic|kink|step-off24|step-small|ramp-step|impulse31]\n",
            argv[0]);
    return 2;
  }
  const char *coding_mode = argv[3];
  const char *signal = argc == 5 ? argv[4] : "quadratic";
  if (!supported_signal(signal)) {
    fprintf(stderr, "unsupported signal: %s\n", signal);
    return 2;
  }
  int progressive;
  if (strcmp(coding_mode, "progressive") == 0) {
    progressive = 1;
  } else if (strcmp(coding_mode, "baseline") == 0) {
    progressive = 0;
  } else {
    fprintf(stderr, "unsupported coding mode: %s\n", coding_mode);
    return 2;
  }

  int y_h;
  int y_v = 2;
  int chroma_width;
  if (strcmp(argv[1], "440") == 0) {
    y_h = 1;
    chroma_width = WIDTH;
  } else if (strcmp(argv[1], "420") == 0) {
    y_h = 2;
    chroma_width = WIDTH / 2;
  } else {
    fprintf(stderr, "unsupported sampling mode: %s\n", argv[1]);
    return 2;
  }

  FILE *out = fopen(argv[2], "wb");
  if (out == NULL) return 3;

  struct jpeg_compress_struct cinfo;
  struct jpeg_error_mgr jerr;
  cinfo.err = jpeg_std_error(&jerr);
  jpeg_create_compress(&cinfo);
  jpeg_stdio_dest(&cinfo, out);
  cinfo.image_width = WIDTH;
  cinfo.image_height = HEIGHT;
  cinfo.input_components = 3;
  cinfo.in_color_space = JCS_YCbCr;
  jpeg_set_defaults(&cinfo);
  cinfo.raw_data_in = TRUE;
  cinfo.comp_info[0].h_samp_factor = y_h;
  cinfo.comp_info[0].v_samp_factor = y_v;
  cinfo.comp_info[1].h_samp_factor = 1;
  cinfo.comp_info[1].v_samp_factor = 1;
  cinfo.comp_info[2].h_samp_factor = 1;
  cinfo.comp_info[2].v_samp_factor = 1;
  jpeg_set_quality(&cinfo, 100, TRUE);
  if (progressive) jpeg_simple_progression(&cinfo);
  cinfo.optimize_coding = TRUE;
  jpeg_start_compress(&cinfo, TRUE);

  unsigned char y[HEIGHT][WIDTH];
  unsigned char cb[CHROMA_HEIGHT][MAX_CHROMA_WIDTH];
  unsigned char cr[CHROMA_HEIGHT][MAX_CHROMA_WIDTH];
  for (int row = 0; row < HEIGHT; row++)
    memset(y[row], 128, WIDTH);
  for (int row = 0; row < CHROMA_HEIGHT; row++) {
    memset(cb[row], subsampled_cb_code(signal, row), (size_t)chroma_width);
    memset(cr[row], 128, (size_t)chroma_width);
  }

  JSAMPROW y_rows[16];
  JSAMPROW cb_rows[8];
  JSAMPROW cr_rows[8];
  JSAMPARRAY image[3] = {y_rows, cb_rows, cr_rows};
  for (int imcu = 0; imcu < HEIGHT / 16; imcu++) {
    for (int row = 0; row < 16; row++)
      y_rows[row] = y[imcu * 16 + row];
    for (int row = 0; row < 8; row++) {
      cb_rows[row] = cb[imcu * 8 + row];
      cr_rows[row] = cr[imcu * 8 + row];
    }
    if (jpeg_write_raw_data(&cinfo, image, 16) != 16) {
      fprintf(stderr, "raw compressor rejected an iMCU row\n");
      jpeg_destroy_compress(&cinfo);
      fclose(out);
      return 4;
    }
  }

  jpeg_finish_compress(&cinfo);
  jpeg_destroy_compress(&cinfo);
  if (fclose(out) != 0) return 5;

  printf("{\"schemaVersion\":3,\"sampling\":\"%s\",\"signal\":\"%s\","
         "\"codingMode\":\"%s\",\"width\":%d,\"height\":%d,"
         "\"chromaWidth\":%d,\"chromaHeight\":%d,"
         "\"lumaCode\":128,\"crCode\":128,\"sourceCbRows\":[",
         argv[1], signal, coding_mode, WIDTH, HEIGHT, chroma_width, CHROMA_HEIGHT);
  for (int row = 0; row < HEIGHT; row++) {
    if (row != 0) printf(",");
    printf("%u", source_cb_code(signal, row));
  }
  printf("],\"subsampledCbRows\":[");
  for (int row = 0; row < CHROMA_HEIGHT; row++) {
    if (row != 0) printf(",");
    printf("%u", subsampled_cb_code(signal, row));
  }
  printf("]}\n");
  return 0;
}
