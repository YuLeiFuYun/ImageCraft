#include <setjmp.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jpeglib.h>
#include <jerror.h>

#define SOURCE_BUFFER_CAPACITY (128 * 1024)
#define MAX_PRE_REALIZE_ALLOCATION_EVENTS 128

typedef struct {
  struct jpeg_error_mgr pub;
  jmp_buf jump;
  char message[JMSG_LENGTH_MAX];
  int warning_count;
} probe_error_mgr;

typedef struct {
  struct jpeg_source_mgr pub;
  const JOCTET *input;
  size_t total_size;
  size_t visible_size;
  size_t loaded_end_offset;
  size_t buffer_file_offset;
  size_t pending_skip;
  size_t refill_count;
  size_t suspension_count;
  size_t maximum_buffered_bytes;
  JOCTET buffer[SOURCE_BUFFER_CAPACITY];
} suspending_source_mgr;

typedef struct {
  int scan_number;
  size_t visible_bytes;
  size_t consumed_bytes;
} scan_event;

typedef struct {
  int component_id;
  int horizontal_sampling_factor;
  int vertical_sampling_factor;
  JDIMENSION width_in_blocks;
  JDIMENSION height_in_blocks;
  JDIMENSION padded_width_in_blocks;
  JDIMENSION padded_height_in_blocks;
  size_t coefficient_payload_bytes;
} coefficient_component;

typedef struct {
  JBLOCKARRAY mem_buffer;
  JDIMENSION rows_in_array;
  JDIMENSION blocksperrow;
  JDIMENSION maxaccess;
  JDIMENSION rows_in_mem;
  JDIMENSION rowsperchunk;
  JDIMENSION cur_start_row;
  JDIMENSION first_undef_row;
  boolean pre_zero;
  boolean dirty;
  boolean b_s_open;
  jvirt_barray_ptr next;
} libjpeg_turbo_320_virtual_barray_prefix;

typedef struct {
  JDIMENSION rows_in_array;
  JDIMENSION blocks_per_row;
  JDIMENSION maximum_access_rows;
  size_t minimum_heights;
  size_t maximum_space_bytes;
  size_t minheight_space_bytes;
} virtual_coefficient_array_observation;

typedef enum {
  PRE_REALIZE_ALLOC_SMALL = 1,
  PRE_REALIZE_ALLOC_LARGE = 2,
  PRE_REALIZE_ALLOC_SARRAY = 3,
  PRE_REALIZE_ALLOC_BARRAY = 4,
  PRE_REALIZE_REQUEST_VIRT_SARRAY = 5,
  PRE_REALIZE_REQUEST_VIRT_BARRAY = 6
} pre_realize_allocation_kind;

typedef struct {
  pre_realize_allocation_kind kind;
  int pool_id;
  size_t logical_payload_bytes;
  JDIMENSION first_dimension;
  JDIMENSION second_dimension;
  size_t pool_bytes_before;
  size_t pool_bytes_after;
} pre_realize_allocation_event;

/*
 * Source-bound research observation for libjpeg-turbo 3.2.0 jmemmgr.c.
 * The public jpeg_memory_mgr is the first field of my_memory_mgr, followed by
 * two pool lists for each lifetime, the virtual-array lists, then
 * total_space_allocated.  We intentionally copy only the prefix needed to
 * observe that counter.  The formal capture pins libjpeg-turbo 3.2.0 and
 * treats this as a private-ABI observation, never as a public libjpeg API.
 */
typedef struct {
  struct jpeg_memory_mgr pub;
  void *small_list[JPOOL_NUMPOOLS];
  void *large_list[JPOOL_NUMPOOLS];
  void *virt_sarray_list;
  void *virt_barray_list;
  size_t total_space_allocated;
} libjpeg_turbo_320_memory_prefix;

static size_t observed_libjpeg_pool_bytes(j_common_ptr cinfo) {
  const libjpeg_turbo_320_memory_prefix *memory =
      (const libjpeg_turbo_320_memory_prefix *)cinfo->mem;
  return memory->total_space_allocated;
}

static void (*original_realize_virt_arrays)(j_common_ptr) = NULL;
static size_t pool_bytes_before_virtual_array_realization = 0;
static unsigned long long configured_max_memory_bytes_for_report = 0;
static virtual_coefficient_array_observation
    observed_virtual_coefficient_arrays[MAX_COMPONENTS];
static size_t observed_virtual_coefficient_array_count = 0;
static size_t observed_virtual_array_maximum_space_bytes = 0;
static size_t observed_virtual_array_space_per_minheight_bytes = 0;
static size_t observed_virtual_array_maximum_required_minheights = 0;
static int observed_virtual_sarray_present = 0;
static int observed_virtual_geometry_overflow = 0;
static void *(*original_alloc_small)(j_common_ptr, int, size_t) = NULL;
static void *(*original_alloc_large)(j_common_ptr, int, size_t) = NULL;
static JSAMPARRAY (*original_alloc_sarray)(j_common_ptr, int, JDIMENSION,
                                           JDIMENSION) = NULL;
static JBLOCKARRAY (*original_alloc_barray)(j_common_ptr, int, JDIMENSION,
                                            JDIMENSION) = NULL;
static jvirt_sarray_ptr (*original_request_virt_sarray)(
    j_common_ptr, int, boolean, JDIMENSION, JDIMENSION, JDIMENSION) = NULL;
static jvirt_barray_ptr (*original_request_virt_barray)(
    j_common_ptr, int, boolean, JDIMENSION, JDIMENSION, JDIMENSION) = NULL;
static pre_realize_allocation_event
    pre_realize_allocation_events[MAX_PRE_REALIZE_ALLOCATION_EVENTS];
static size_t pre_realize_allocation_event_count = 0;
static int pre_realize_allocation_event_overflow = 0;
static int pre_realize_allocation_trace_active = 0;

static size_t sample_size_for_precision(j_common_ptr cinfo) {
  if (!cinfo->is_decompressor) return 0;
  int precision = ((j_decompress_ptr)cinfo)->data_precision;
  if (precision <= 8) return sizeof(JSAMPLE);
  if (precision <= 12) return sizeof(J12SAMPLE);
  return sizeof(J16SAMPLE);
}

static size_t checked_product_or_zero(size_t left, size_t right) {
  if (left != 0 && right > SIZE_MAX / left) return 0;
  return left * right;
}

static void record_pre_realize_allocation(
    pre_realize_allocation_kind kind,
    int pool_id,
    size_t logical_payload_bytes,
    JDIMENSION first_dimension,
    JDIMENSION second_dimension,
    size_t pool_bytes_before,
    size_t pool_bytes_after) {
  if (!pre_realize_allocation_trace_active) return;
  if (pre_realize_allocation_event_count >= MAX_PRE_REALIZE_ALLOCATION_EVENTS) {
    pre_realize_allocation_event_overflow = 1;
    return;
  }
  pre_realize_allocation_events[pre_realize_allocation_event_count++] =
      (pre_realize_allocation_event){
        kind,
        pool_id,
        logical_payload_bytes,
        first_dimension,
        second_dimension,
        pool_bytes_before,
        pool_bytes_after
      };
}

static const char *pre_realize_allocation_kind_name(
    pre_realize_allocation_kind kind) {
  switch (kind) {
    case PRE_REALIZE_ALLOC_SMALL: return "allocSmall";
    case PRE_REALIZE_ALLOC_LARGE: return "allocLarge";
    case PRE_REALIZE_ALLOC_SARRAY: return "allocSArray";
    case PRE_REALIZE_ALLOC_BARRAY: return "allocBArray";
    case PRE_REALIZE_REQUEST_VIRT_SARRAY: return "requestVirtSArray";
    case PRE_REALIZE_REQUEST_VIRT_BARRAY: return "requestVirtBArray";
  }
  return "unknown";
}

static void *observing_alloc_small(j_common_ptr cinfo, int pool_id,
                                   size_t sizeofobject) {
  size_t before = observed_libjpeg_pool_bytes(cinfo);
  void *result = original_alloc_small(cinfo, pool_id, sizeofobject);
  size_t after = observed_libjpeg_pool_bytes(cinfo);
  record_pre_realize_allocation(PRE_REALIZE_ALLOC_SMALL, pool_id,
                                sizeofobject, 0, 0, before, after);
  return result;
}

static void *observing_alloc_large(j_common_ptr cinfo, int pool_id,
                                   size_t sizeofobject) {
  size_t before = observed_libjpeg_pool_bytes(cinfo);
  void *result = original_alloc_large(cinfo, pool_id, sizeofobject);
  size_t after = observed_libjpeg_pool_bytes(cinfo);
  record_pre_realize_allocation(PRE_REALIZE_ALLOC_LARGE, pool_id,
                                sizeofobject, 0, 0, before, after);
  return result;
}

static JSAMPARRAY observing_alloc_sarray(j_common_ptr cinfo, int pool_id,
                                         JDIMENSION samplesperrow,
                                         JDIMENSION numrows) {
  size_t sample_size = sample_size_for_precision(cinfo);
  size_t sample_count = checked_product_or_zero((size_t)samplesperrow,
                                                (size_t)numrows);
  size_t logical_payload = sample_count == 0
      ? 0
      : checked_product_or_zero(sample_count, sample_size);
  size_t before = observed_libjpeg_pool_bytes(cinfo);
  JSAMPARRAY result = original_alloc_sarray(cinfo, pool_id, samplesperrow, numrows);
  size_t after = observed_libjpeg_pool_bytes(cinfo);
  record_pre_realize_allocation(PRE_REALIZE_ALLOC_SARRAY, pool_id,
                                logical_payload, samplesperrow, numrows,
                                before, after);
  return result;
}

static JBLOCKARRAY observing_alloc_barray(j_common_ptr cinfo, int pool_id,
                                          JDIMENSION blocksperrow,
                                          JDIMENSION numrows) {
  size_t block_count = checked_product_or_zero((size_t)blocksperrow,
                                               (size_t)numrows);
  size_t logical_payload = block_count == 0
      ? 0
      : checked_product_or_zero(block_count, sizeof(JBLOCK));
  size_t before = observed_libjpeg_pool_bytes(cinfo);
  JBLOCKARRAY result = original_alloc_barray(cinfo, pool_id, blocksperrow, numrows);
  size_t after = observed_libjpeg_pool_bytes(cinfo);
  record_pre_realize_allocation(PRE_REALIZE_ALLOC_BARRAY, pool_id,
                                logical_payload, blocksperrow, numrows,
                                before, after);
  return result;
}

static jvirt_sarray_ptr observing_request_virt_sarray(
    j_common_ptr cinfo, int pool_id, boolean pre_zero,
    JDIMENSION samplesperrow, JDIMENSION numrows, JDIMENSION maxaccess) {
  size_t before = observed_libjpeg_pool_bytes(cinfo);
  jvirt_sarray_ptr result = original_request_virt_sarray(
      cinfo, pool_id, pre_zero, samplesperrow, numrows, maxaccess);
  size_t after = observed_libjpeg_pool_bytes(cinfo);
  record_pre_realize_allocation(PRE_REALIZE_REQUEST_VIRT_SARRAY, pool_id, 0,
                                samplesperrow, numrows, before, after);
  return result;
}

static jvirt_barray_ptr observing_request_virt_barray(
    j_common_ptr cinfo, int pool_id, boolean pre_zero,
    JDIMENSION blocksperrow, JDIMENSION numrows, JDIMENSION maxaccess) {
  size_t before = observed_libjpeg_pool_bytes(cinfo);
  jvirt_barray_ptr result = original_request_virt_barray(
      cinfo, pool_id, pre_zero, blocksperrow, numrows, maxaccess);
  size_t after = observed_libjpeg_pool_bytes(cinfo);
  record_pre_realize_allocation(PRE_REALIZE_REQUEST_VIRT_BARRAY, pool_id, 0,
                                blocksperrow, numrows, before, after);
  return result;
}

static void install_pre_realize_allocation_observers(j_common_ptr cinfo) {
  original_alloc_small = cinfo->mem->alloc_small;
  original_alloc_large = cinfo->mem->alloc_large;
  original_alloc_sarray = cinfo->mem->alloc_sarray;
  original_alloc_barray = cinfo->mem->alloc_barray;
  original_request_virt_sarray = cinfo->mem->request_virt_sarray;
  original_request_virt_barray = cinfo->mem->request_virt_barray;
  cinfo->mem->alloc_small = observing_alloc_small;
  cinfo->mem->alloc_large = observing_alloc_large;
  cinfo->mem->alloc_sarray = observing_alloc_sarray;
  cinfo->mem->alloc_barray = observing_alloc_barray;
  cinfo->mem->request_virt_sarray = observing_request_virt_sarray;
  cinfo->mem->request_virt_barray = observing_request_virt_barray;
  pre_realize_allocation_trace_active = 1;
}

static void observing_realize_virt_arrays(j_common_ptr cinfo) {
  pool_bytes_before_virtual_array_realization = observed_libjpeg_pool_bytes(cinfo);
  pre_realize_allocation_trace_active = 0;
  const libjpeg_turbo_320_memory_prefix *memory =
      (const libjpeg_turbo_320_memory_prefix *)cinfo->mem;
  observed_virtual_sarray_present = memory->virt_sarray_list != NULL;
  const libjpeg_turbo_320_virtual_barray_prefix *array =
      (const libjpeg_turbo_320_virtual_barray_prefix *)memory->virt_barray_list;
  while (array != NULL) {
    if (observed_virtual_coefficient_array_count >= MAX_COMPONENTS ||
        array->rows_in_array == 0 || array->blocksperrow == 0 ||
        array->maxaccess == 0 ||
        (size_t)array->blocksperrow > SIZE_MAX / sizeof(JBLOCK)) {
      observed_virtual_geometry_overflow = 1;
      break;
    }
    size_t row_bytes = (size_t)array->blocksperrow * sizeof(JBLOCK);
    if ((size_t)array->rows_in_array > SIZE_MAX / row_bytes ||
        (size_t)array->maxaccess > SIZE_MAX / row_bytes) {
      observed_virtual_geometry_overflow = 1;
      break;
    }
    size_t maximum_space_bytes = (size_t)array->rows_in_array * row_bytes;
    size_t minheight_space_bytes = (size_t)array->maxaccess * row_bytes;
    if (observed_virtual_array_maximum_space_bytes >
            SIZE_MAX - maximum_space_bytes ||
        observed_virtual_array_space_per_minheight_bytes >
            SIZE_MAX - minheight_space_bytes) {
      observed_virtual_geometry_overflow = 1;
      break;
    }
    size_t minimum_heights =
        ((size_t)array->rows_in_array + (size_t)array->maxaccess - 1) /
        (size_t)array->maxaccess;
    observed_virtual_coefficient_arrays[observed_virtual_coefficient_array_count++] =
        (virtual_coefficient_array_observation){
          array->rows_in_array,
          array->blocksperrow,
          array->maxaccess,
          minimum_heights,
          maximum_space_bytes,
          minheight_space_bytes
        };
    observed_virtual_array_maximum_space_bytes += maximum_space_bytes;
    observed_virtual_array_space_per_minheight_bytes += minheight_space_bytes;
    if (minimum_heights > observed_virtual_array_maximum_required_minheights)
      observed_virtual_array_maximum_required_minheights = minimum_heights;
    array = (const libjpeg_turbo_320_virtual_barray_prefix *)array->next;
  }
  original_realize_virt_arrays(cinfo);
}

static void probe_error_exit(j_common_ptr common) {
  probe_error_mgr *error = (probe_error_mgr *)common->err;
  (*common->err->format_message)(common, error->message);
  longjmp(error->jump, 1);
}

static void probe_emit_message(j_common_ptr common, int message_level) {
  probe_error_mgr *error = (probe_error_mgr *)common->err;
  if (message_level < 0) error->warning_count += 1;
}

static void init_source(j_decompress_ptr cinfo) {
  (void)cinfo;
}

static size_t source_offset(const suspending_source_mgr *source) {
  if (source->pub.next_input_byte == NULL) return source->buffer_file_offset;
  return source->buffer_file_offset +
         (size_t)(source->pub.next_input_byte - source->buffer);
}

static boolean fill_input_buffer(j_decompress_ptr cinfo) {
  suspending_source_mgr *source = (suspending_source_mgr *)cinfo->src;
  source->refill_count += 1;
  /* New transport bytes only become visible between libjpeg calls.  If the
   * currently visible prefix is exhausted, return FALSE without touching the
   * public restart pointer/count.  libjpeg deliberately leaves those fields
   * at its rollback boundary while consuming bytes through local copies. */
  if (source->pending_skip > 0 && source->loaded_end_offset < source->visible_size) {
    size_t available = source->visible_size - source->loaded_end_offset;
    size_t step = source->pending_skip < available ? source->pending_skip : available;
    source->loaded_end_offset += step;
    source->pending_skip -= step;
  }
  if (source->pending_skip > 0) {
    source->suspension_count += 1;
    return FALSE;
  }

  size_t available = source->visible_size - source->loaded_end_offset;
  size_t loaded = available < SOURCE_BUFFER_CAPACITY ? available : SOURCE_BUFFER_CAPACITY;
  if (loaded > 0) {
    source->buffer_file_offset = source->loaded_end_offset;
    memcpy(source->buffer,
           source->input + source->loaded_end_offset,
           loaded);
    source->loaded_end_offset += loaded;
    source->pub.next_input_byte = source->buffer;
    source->pub.bytes_in_buffer = loaded;
    if (loaded > source->maximum_buffered_bytes) {
      source->maximum_buffered_bytes = loaded;
    }
    return TRUE;
  }

  source->suspension_count += 1;
  return FALSE;
}

static void skip_input_data(j_decompress_ptr cinfo, long byte_count) {
  suspending_source_mgr *source = (suspending_source_mgr *)cinfo->src;
  if (byte_count <= 0) return;
  size_t requested = (size_t)byte_count;
  if (requested <= source->pub.bytes_in_buffer) {
    source->pub.next_input_byte += requested;
    source->pub.bytes_in_buffer -= requested;
    return;
  }
  requested -= source->pub.bytes_in_buffer;
  source->pub.next_input_byte += source->pub.bytes_in_buffer;
  source->pub.bytes_in_buffer = 0;
  source->pending_skip += requested;
}

static void term_source(j_decompress_ptr cinfo) {
  (void)cinfo;
}

static void install_source(
    j_decompress_ptr cinfo,
    suspending_source_mgr *source,
    const JOCTET *bytes,
    size_t total_size,
    size_t initial_visible_size) {
  memset(source, 0, sizeof(*source));
  source->pub.init_source = init_source;
  source->pub.fill_input_buffer = fill_input_buffer;
  source->pub.skip_input_data = skip_input_data;
  source->pub.resync_to_restart = jpeg_resync_to_restart;
  source->pub.term_source = term_source;
  source->input = bytes;
  source->total_size = total_size;
  source->visible_size = initial_visible_size;
  source->pub.next_input_byte = source->buffer;
  size_t initial_loaded =
      initial_visible_size < SOURCE_BUFFER_CAPACITY ? initial_visible_size : SOURCE_BUFFER_CAPACITY;
  if (initial_loaded > 0) {
    memcpy(source->buffer, bytes, initial_loaded);
  }
  source->loaded_end_offset = initial_loaded;
  source->pub.bytes_in_buffer = initial_loaded;
  source->maximum_buffered_bytes = initial_loaded;
  cinfo->src = (struct jpeg_source_mgr *)source;
}

static int expose_more(suspending_source_mgr *source, size_t chunk_size) {
  if (source->visible_size >= source->total_size) return 0;

  /* jpeg_* returned JPEG_SUSPENDED, so pub.next_input_byte/bytes_in_buffer
   * identify the rollback point.  Preserve that tail before making the next
   * transport chunk visible, then append new bytes behind it. */
  size_t restart_offset = source_offset(source);
  size_t retained = source->pub.bytes_in_buffer;
  if (restart_offset > source->loaded_end_offset ||
      retained > source->loaded_end_offset - restart_offset ||
      retained > SOURCE_BUFFER_CAPACITY) {
    return 0;
  }
  if (retained > 0 && source->pub.next_input_byte != source->buffer) {
    memmove(source->buffer, source->pub.next_input_byte, retained);
  }
  source->buffer_file_offset = restart_offset;
  source->loaded_end_offset = restart_offset + retained;
  source->pub.next_input_byte = source->buffer;
  source->pub.bytes_in_buffer = retained;

  size_t remaining = source->total_size - source->visible_size;
  size_t step = chunk_size < remaining ? chunk_size : remaining;
  source->visible_size += step;

  if (source->pending_skip > 0 && source->loaded_end_offset < source->visible_size) {
    size_t available = source->visible_size - source->loaded_end_offset;
    size_t skipped = source->pending_skip < available ? source->pending_skip : available;
    source->loaded_end_offset += skipped;
    source->pending_skip -= skipped;
  }
  if (source->pending_skip == 0 && retained < SOURCE_BUFFER_CAPACITY &&
      source->loaded_end_offset < source->visible_size) {
    size_t available = source->visible_size - source->loaded_end_offset;
    size_t capacity = SOURCE_BUFFER_CAPACITY - retained;
    size_t appended = available < capacity ? available : capacity;
    memcpy(source->buffer + retained,
           source->input + source->loaded_end_offset,
           appended);
    source->loaded_end_offset += appended;
    source->pub.bytes_in_buffer += appended;
    if (source->pub.bytes_in_buffer > source->maximum_buffered_bytes) {
      source->maximum_buffered_bytes = source->pub.bytes_in_buffer;
    }
  }
  return 1;
}

static unsigned char *read_file(const char *path, size_t *size_out) {
  FILE *file = fopen(path, "rb");
  if (file == NULL) return NULL;
  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    return NULL;
  }
  long end = ftell(file);
  if (end < 0 || fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return NULL;
  }
  size_t size = (size_t)end;
  unsigned char *bytes = (unsigned char *)malloc(size == 0 ? 1 : size);
  if (bytes == NULL) {
    fclose(file);
    return NULL;
  }
  if (size > 0 && fread(bytes, 1, size, file) != size) {
    free(bytes);
    fclose(file);
    return NULL;
  }
  fclose(file);
  *size_out = size;
  return bytes;
}

static int write_file(const char *path, const unsigned char *bytes, size_t size) {
  FILE *file = fopen(path, "wb");
  if (file == NULL) return 0;
  int ok = size == 0 || fwrite(bytes, 1, size, file) == size;
  if (fclose(file) != 0) ok = 0;
  return ok;
}

static JDIMENSION round_up_blocks(JDIMENSION value, int factor) {
  JDIMENSION divisor = (JDIMENSION)factor;
  return ((value + divisor - 1) / divisor) * divisor;
}

static int render_scan(
    j_decompress_ptr cinfo,
    int target_scan,
    unsigned char **bytes_out,
    size_t *size_out) {
  if (!jpeg_start_output(cinfo, target_scan)) return 0;
  size_t row_bytes = (size_t)cinfo->output_width * (size_t)cinfo->output_components;
  size_t total_bytes = row_bytes * (size_t)cinfo->output_height;
  unsigned char *output = (unsigned char *)malloc(total_bytes == 0 ? 1 : total_bytes);
  if (output == NULL) return 0;
  while (cinfo->output_scanline < cinfo->output_height) {
    JSAMPROW row = output + (size_t)cinfo->output_scanline * row_bytes;
    if (jpeg_read_scanlines(cinfo, &row, 1) != 1) {
      free(output);
      return 0;
    }
  }
  if (!jpeg_finish_output(cinfo)) {
    free(output);
    return 0;
  }
  *bytes_out = output;
  *size_out = total_bytes;
  return 1;
}

int main(int argc, char **argv) {
  if (argc < 5 || argc > 7) {
    fprintf(stderr,
            "usage: %s input.jpg chunk-size output-prefix max-scans "
            "[max-memory-bytes] [decode-mode]\n",
            argv[0]);
    return 2;
  }
  char *end = NULL;
  unsigned long long chunk_raw = strtoull(argv[2], &end, 10);
  if (end == argv[2] || *end != '\0' || chunk_raw == 0 || chunk_raw > SIZE_MAX) return 2;
  int max_scans = atoi(argv[4]);
  if (max_scans <= 0) return 2;
  unsigned long long max_memory_raw = 0;
  if (argc == 6) {
    end = NULL;
    max_memory_raw = strtoull(argv[5], &end, 10);
    if (end == argv[5] || *end != '\0' || max_memory_raw > LONG_MAX) return 2;
  }
  if (argc == 7) {
    end = NULL;
    max_memory_raw = strtoull(argv[5], &end, 10);
    if (end == argv[5] || *end != '\0' || max_memory_raw > LONG_MAX) return 2;
  }
  const char *decode_mode = argc == 7 ? argv[6] : "default";
  if (strcmp(decode_mode, "default") != 0 &&
      strcmp(decode_mode, "nearest") != 0 &&
      strcmp(decode_mode, "fast-idct") != 0 &&
      strcmp(decode_mode, "float-idct") != 0 &&
      strcmp(decode_mode, "no-smoothing") != 0 &&
      strcmp(decode_mode, "default-previews") != 0 &&
      strcmp(decode_mode, "fast-nearest") != 0 &&
      strcmp(decode_mode, "float-nearest") != 0) {
    fprintf(stderr, "unsupported decode mode: %s\n", decode_mode);
    return 2;
  }
  configured_max_memory_bytes_for_report = max_memory_raw;
  pool_bytes_before_virtual_array_realization = 0;
  original_realize_virt_arrays = NULL;
  memset(observed_virtual_coefficient_arrays, 0,
         sizeof(observed_virtual_coefficient_arrays));
  observed_virtual_coefficient_array_count = 0;
  observed_virtual_array_maximum_space_bytes = 0;
  observed_virtual_array_space_per_minheight_bytes = 0;
  observed_virtual_array_maximum_required_minheights = 0;
  observed_virtual_sarray_present = 0;
  observed_virtual_geometry_overflow = 0;
  original_alloc_small = NULL;
  original_alloc_large = NULL;
  original_alloc_sarray = NULL;
  original_alloc_barray = NULL;
  original_request_virt_sarray = NULL;
  original_request_virt_barray = NULL;
  memset(pre_realize_allocation_events, 0,
         sizeof(pre_realize_allocation_events));
  pre_realize_allocation_event_count = 0;
  pre_realize_allocation_event_overflow = 0;
  pre_realize_allocation_trace_active = 0;

  size_t input_size = 0;
  unsigned char *input = read_file(argv[1], &input_size);
  if (input == NULL || input_size == 0) {
    free(input);
    return 3;
  }
  size_t chunk_size = (size_t)chunk_raw;

  struct jpeg_decompress_struct cinfo;
  probe_error_mgr error;
  suspending_source_mgr source;
  memset(&cinfo, 0, sizeof(cinfo));
  memset(&error, 0, sizeof(error));
  cinfo.err = jpeg_std_error(&error.pub);
  error.pub.error_exit = probe_error_exit;
  error.pub.emit_message = probe_emit_message;
  if (setjmp(error.jump)) {
    size_t pool_bytes_at_error = cinfo.mem != NULL
      ? observed_libjpeg_pool_bytes((j_common_ptr)&cinfo)
      : 0;
    printf("{\"schemaVersion\":1,\"status\":\"libjpeg-error\","
           "\"configuredMaxMemoryToUseBytes\":%llu,"
           "\"libjpegPoolBytesBeforeVirtualArrayRealization\":%zu,"
           "\"libjpegPoolBytesAtError\":%zu}\n",
           configured_max_memory_bytes_for_report,
           pool_bytes_before_virtual_array_realization,
           pool_bytes_at_error);
    fprintf(stderr, "libjpeg error: %s\n", error.message);
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 4;
  }

  jpeg_create_decompress(&cinfo);
  original_realize_virt_arrays = cinfo.mem->realize_virt_arrays;
  if (original_realize_virt_arrays == NULL) {
    fprintf(stderr, "libjpeg memory manager is missing realize_virt_arrays\n");
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 4;
  }
  cinfo.mem->realize_virt_arrays = observing_realize_virt_arrays;
  size_t pool_bytes_after_create = observed_libjpeg_pool_bytes((j_common_ptr)&cinfo);
  if (pool_bytes_after_create < sizeof(libjpeg_turbo_320_memory_prefix) ||
      pool_bytes_after_create > 4096) {
    fprintf(stderr, "libjpeg-turbo 3.2.0 memory-prefix observation failed\n");
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 4;
  }
  if (max_memory_raw > 0) cinfo.mem->max_memory_to_use = (long)max_memory_raw;
  size_t initial_visible = chunk_size < input_size ? chunk_size : input_size;
  install_source(&cinfo, &source, input, input_size, initial_visible);

  int header_status = JPEG_SUSPENDED;
  while (header_status == JPEG_SUSPENDED) {
    header_status = jpeg_read_header(&cinfo, TRUE);
    if (header_status == JPEG_SUSPENDED && !expose_more(&source, chunk_size)) {
      fprintf(stderr, "input ended while JPEG header remained suspended\n");
      jpeg_destroy_decompress(&cinfo);
      free(input);
      return 5;
    }
  }
  if (header_status != JPEG_HEADER_OK || !cinfo.progressive_mode) {
    fprintf(stderr, "probe requires a progressive JPEG\n");
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 6;
  }
  size_t pool_bytes_after_header = observed_libjpeg_pool_bytes((j_common_ptr)&cinfo);

  cinfo.buffered_image = TRUE;
  cinfo.out_color_space = JCS_RGB;
  if (strcmp(decode_mode, "nearest") == 0) {
    cinfo.do_fancy_upsampling = FALSE;
  } else if (strcmp(decode_mode, "no-smoothing") == 0) {
    cinfo.do_block_smoothing = FALSE;
  } else if (strcmp(decode_mode, "fast-idct") == 0) {
    cinfo.dct_method = JDCT_IFAST;
  } else if (strcmp(decode_mode, "float-idct") == 0) {
    cinfo.dct_method = JDCT_FLOAT;
  } else if (strcmp(decode_mode, "fast-nearest") == 0) {
    cinfo.do_fancy_upsampling = FALSE;
    cinfo.dct_method = JDCT_IFAST;
  } else if (strcmp(decode_mode, "float-nearest") == 0) {
    cinfo.do_fancy_upsampling = FALSE;
    cinfo.dct_method = JDCT_FLOAT;
  }
  install_pre_realize_allocation_observers((j_common_ptr)&cinfo);
  if (!jpeg_start_decompress(&cinfo)) {
    fprintf(stderr, "buffered-image start unexpectedly suspended\n");
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 7;
  }
  size_t pool_bytes_after_start = observed_libjpeg_pool_bytes((j_common_ptr)&cinfo);

  if (cinfo.num_components <= 0 || cinfo.num_components > MAX_COMPONENTS) {
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 8;
  }
  int coefficient_component_count = cinfo.num_components;
  coefficient_component coefficient_components[MAX_COMPONENTS];
  memset(coefficient_components, 0, sizeof(coefficient_components));
  size_t coefficient_payload_bytes = 0;
  for (int component_index = 0; component_index < coefficient_component_count;
       component_index++) {
    jpeg_component_info *component = &cinfo.comp_info[component_index];
    JDIMENSION padded_width =
        round_up_blocks(component->width_in_blocks, component->h_samp_factor);
    JDIMENSION padded_height =
        round_up_blocks(component->height_in_blocks, component->v_samp_factor);
    if (padded_width != 0 &&
        (size_t)padded_height > SIZE_MAX / (size_t)padded_width) {
      jpeg_destroy_decompress(&cinfo);
      free(input);
      return 8;
    }
    size_t block_count = (size_t)padded_width * (size_t)padded_height;
    if (block_count > SIZE_MAX / sizeof(JBLOCK)) {
      jpeg_destroy_decompress(&cinfo);
      free(input);
      return 8;
    }
    size_t component_bytes = block_count * sizeof(JBLOCK);
    if (coefficient_payload_bytes > SIZE_MAX - component_bytes) {
      jpeg_destroy_decompress(&cinfo);
      free(input);
      return 8;
    }
    coefficient_payload_bytes += component_bytes;
    coefficient_components[component_index] = (coefficient_component){
      component->component_id,
      component->h_samp_factor,
      component->v_samp_factor,
      component->width_in_blocks,
      component->height_in_blocks,
      padded_width,
      padded_height,
      component_bytes
    };
  }
  if (pool_bytes_before_virtual_array_realization == 0 ||
      observed_virtual_geometry_overflow || observed_virtual_sarray_present ||
      observed_virtual_coefficient_array_count != (size_t)coefficient_component_count ||
      observed_virtual_array_maximum_space_bytes != coefficient_payload_bytes ||
      observed_virtual_array_space_per_minheight_bytes == 0 ||
      observed_virtual_array_maximum_required_minheights == 0 ||
      pool_bytes_before_virtual_array_realization >
          SIZE_MAX - observed_virtual_array_maximum_space_bytes) {
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 8;
  }
  size_t full_virtual_array_availability_threshold_bytes =
      pool_bytes_before_virtual_array_realization +
      observed_virtual_array_maximum_space_bytes;
  if (pool_bytes_after_start < full_virtual_array_availability_threshold_bytes) {
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 8;
  }

  scan_event *events = (scan_event *)calloc((size_t)max_scans, sizeof(scan_event));
  if (events == NULL) {
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 8;
  }
  int event_count = 0;
  int last_completed_scan = 0;
  int final_scan = 0;
  int reached_eoi = 0;

  while (!reached_eoi) {
    int status = jpeg_consume_input(&cinfo);
    if (status == JPEG_SCAN_COMPLETED) {
      int completed = cinfo.input_scan_number;
      if (completed <= last_completed_scan) completed = last_completed_scan + 1;
      last_completed_scan = completed;
      if (event_count >= max_scans) {
        fprintf(stderr, "scan limit exceeded: %d\n", max_scans);
        free(events);
        jpeg_destroy_decompress(&cinfo);
        free(input);
        return 9;
      }
      events[event_count].scan_number = completed;
      events[event_count].visible_bytes = source.visible_size;
      events[event_count].consumed_bytes = source_offset(&source);
      event_count += 1;
      if (strcmp(decode_mode, "no-smoothing") == 0 ||
          strcmp(decode_mode, "default-previews") == 0) {
        unsigned char *preview_output = NULL;
        size_t preview_size = 0;
        if (!render_scan(&cinfo, completed, &preview_output, &preview_size)) {
          fprintf(stderr, "failed to render completed scan %d\n", completed);
          free(events);
          jpeg_destroy_decompress(&cinfo);
          free(input);
          return 9;
        }
        char preview_path[4096];
        int preview_path_length = snprintf(
          preview_path, sizeof(preview_path), "%s-scan-%03d.rgb", argv[3], completed);
        if (preview_path_length < 0 ||
            (size_t)preview_path_length >= sizeof(preview_path) ||
            !write_file(preview_path, preview_output, preview_size)) {
          fprintf(stderr, "failed to write completed scan %d\n", completed);
          free(preview_output);
          free(events);
          jpeg_destroy_decompress(&cinfo);
          free(input);
          return 9;
        }
        free(preview_output);
      }
    } else if (status == JPEG_REACHED_EOI) {
      reached_eoi = 1;
      final_scan = cinfo.input_scan_number;
      if (final_scan > max_scans) {
        fprintf(stderr, "scan limit exceeded at EOI: %d\n", max_scans);
        free(events);
        jpeg_destroy_decompress(&cinfo);
        free(input);
        return 9;
      }
    } else if (status == JPEG_SUSPENDED) {
      if (!expose_more(&source, chunk_size)) {
        fprintf(stderr, "input ended while decompressor remained suspended\n");
        free(events);
        jpeg_destroy_decompress(&cinfo);
        free(input);
        return 10;
      }
    }
  }
  size_t pool_bytes_after_eoi = observed_libjpeg_pool_bytes((j_common_ptr)&cinfo);

  unsigned char *final_output = NULL;
  size_t final_size = 0;
  if (!render_scan(&cinfo, final_scan, &final_output, &final_size)) {
    fprintf(stderr, "failed to render final buffered-image scan\n");
    free(events);
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 11;
  }
  size_t pool_bytes_after_render = observed_libjpeg_pool_bytes((j_common_ptr)&cinfo);
  if (!jpeg_finish_decompress(&cinfo)) {
    fprintf(stderr, "final buffered-image finish unexpectedly suspended\n");
    free(final_output);
    free(events);
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 11;
  }
  size_t pool_bytes_after_finish = observed_libjpeg_pool_bytes((j_common_ptr)&cinfo);
  size_t maximum_observed_pool_bytes = pool_bytes_after_create;
  const size_t pool_checkpoints[] = {
    pool_bytes_after_header,
    pool_bytes_after_start,
    pool_bytes_after_eoi,
    pool_bytes_after_render,
    pool_bytes_after_finish
  };
  for (size_t checkpoint_index = 0;
       checkpoint_index < sizeof(pool_checkpoints) / sizeof(pool_checkpoints[0]);
       checkpoint_index++) {
    if (pool_checkpoints[checkpoint_index] > maximum_observed_pool_bytes)
      maximum_observed_pool_bytes = pool_checkpoints[checkpoint_index];
  }
  size_t pre_realize_allocation_pool_growth_bytes = 0;
  for (size_t allocation_index = 0;
       allocation_index < pre_realize_allocation_event_count;
       allocation_index++) {
    pre_realize_allocation_event *allocation =
        &pre_realize_allocation_events[allocation_index];
    if (allocation->pool_bytes_after >= allocation->pool_bytes_before) {
      size_t growth = allocation->pool_bytes_after - allocation->pool_bytes_before;
      if (pre_realize_allocation_pool_growth_bytes > SIZE_MAX - growth) {
        fprintf(stderr, "pre-realize allocation pool growth overflow\n");
        free(final_output);
        free(events);
        jpeg_destroy_decompress(&cinfo);
        free(input);
        return 12;
      }
      pre_realize_allocation_pool_growth_bytes += growth;
    }
  }
  char final_path[4096];
  if (snprintf(final_path, sizeof(final_path), "%s-final.rgb", argv[3]) < 0 ||
      !write_file(final_path, final_output, final_size)) {
    free(final_output);
    free(events);
    jpeg_destroy_decompress(&cinfo);
    free(input);
    return 12;
  }

  printf("{\"schemaVersion\":1,\"implementation\":\"libjpeg-turbo.classic.suspending-buffered-image\","
         "\"decodeMode\":\"%s\",\"inputByteCount\":%zu,\"chunkSize\":%zu,\"width\":%u,\"height\":%u,"
         "\"outputComponents\":%d,\"finalScanNumber\":%d,\"scanCompletedEventCount\":%d,"
         "\"finalOutputByteCount\":%zu,\"sourceBufferCapacityBytes\":%d,"
         "\"maximumBufferedSourceBytes\":%zu,\"refillCount\":%zu,"
         "\"suspensionCount\":%zu,\"warningCount\":%d,"
         "\"configuredMaxMemoryToUseBytes\":%lld,"
         "\"coefficientBlockByteCount\":%zu,\"minimumCoefficientArrayPayloadBytes\":%zu,"
         "\"libjpegVirtualArrayMaximumSpaceBytes\":%zu,"
         "\"libjpegVirtualArraySpacePerMinheightBytes\":%zu,"
         "\"libjpegVirtualArrayMaximumRequiredMinheights\":%zu,"
         "\"libjpegPoolBytesBeforeVirtualArrayRealization\":%zu,"
         "\"libjpegFullVirtualArrayAvailabilityThresholdBytes\":%zu,"
         "\"libjpegSharpNoBackingStoreThresholdApplicable\":%s,"
         "\"libjpegObservedVirtualCoefficientArrayCount\":%zu,"
         "\"libjpegObservedVirtualSampleArrayPresent\":%s,"
         "\"libjpegMaxAllocChunkBytes\":%ld,"
         "\"preRealizeAllocationEventCount\":%zu,"
         "\"preRealizeAllocationEventOverflow\":%s,"
         "\"preRealizeAllocationPoolGrowthBytes\":%zu,"
         "\"minimumPersistentDecoderPayloadBytes\":%zu,"
         "\"sourceManagerStateByteCount\":%zu,\"instrumentationEventArrayByteCount\":%zu,"
         "\"libjpegPrivateMemoryABI\":\"libjpeg-turbo-3.2.0.jmemmgr.prefix-v1\","
         "\"libjpegMemoryManagerPrefixByteCount\":%zu,"
         "\"libjpegPoolBytesAfterCreate\":%zu,\"libjpegPoolBytesAfterHeader\":%zu,"
         "\"libjpegPoolBytesAfterStartDecompress\":%zu,\"libjpegPoolBytesAfterEOI\":%zu,"
         "\"libjpegPoolBytesAfterFinalRender\":%zu,\"libjpegPoolBytesAfterFinish\":%zu,"
         "\"maximumObservedLibjpegPoolBytes\":%zu,"
         "\"observedRetainedDecoderLiveBytesAtEOI\":%zu,"
         "\"observedFinalRenderLiveBytes\":%zu,\"coefficientComponents\":[",
         decode_mode, input_size, chunk_size, cinfo.output_width, cinfo.output_height,
         cinfo.output_components, final_scan, event_count, final_size,
         SOURCE_BUFFER_CAPACITY, source.maximum_buffered_bytes,
         source.refill_count, source.suspension_count, error.warning_count,
         (long long)cinfo.mem->max_memory_to_use,
         sizeof(JBLOCK), coefficient_payload_bytes,
         observed_virtual_array_maximum_space_bytes,
         observed_virtual_array_space_per_minheight_bytes,
         observed_virtual_array_maximum_required_minheights,
         pool_bytes_before_virtual_array_realization,
         full_virtual_array_availability_threshold_bytes,
         observed_virtual_array_maximum_required_minheights > 1 ? "true" : "false",
         observed_virtual_coefficient_array_count,
         observed_virtual_sarray_present ? "true" : "false",
         cinfo.mem->max_alloc_chunk,
         pre_realize_allocation_event_count,
         pre_realize_allocation_event_overflow ? "true" : "false",
         pre_realize_allocation_pool_growth_bytes,
         coefficient_payload_bytes + (size_t)SOURCE_BUFFER_CAPACITY,
         sizeof(suspending_source_mgr), (size_t)max_scans * sizeof(scan_event),
         sizeof(libjpeg_turbo_320_memory_prefix),
         pool_bytes_after_create, pool_bytes_after_header,
         pool_bytes_after_start, pool_bytes_after_eoi,
         pool_bytes_after_render, pool_bytes_after_finish,
         maximum_observed_pool_bytes,
         pool_bytes_after_eoi + sizeof(suspending_source_mgr),
         pool_bytes_after_render + sizeof(suspending_source_mgr) + final_size);
  for (int component_index = 0; component_index < coefficient_component_count;
       component_index++) {
    coefficient_component *component = &coefficient_components[component_index];
    if (component_index != 0) printf(",");
    printf("{\"componentID\":%d,\"horizontalSamplingFactor\":%d,"
           "\"verticalSamplingFactor\":%d,\"widthInBlocks\":%u,"
           "\"heightInBlocks\":%u,\"paddedWidthInBlocks\":%u,"
           "\"paddedHeightInBlocks\":%u,\"coefficientPayloadBytes\":%zu}",
           component->component_id, component->horizontal_sampling_factor,
           component->vertical_sampling_factor, component->width_in_blocks,
           component->height_in_blocks, component->padded_width_in_blocks,
           component->padded_height_in_blocks,
           component->coefficient_payload_bytes);
  }
  printf("],\"virtualCoefficientArrays\":[");
  for (size_t array_index = 0;
       array_index < observed_virtual_coefficient_array_count;
       array_index++) {
    virtual_coefficient_array_observation *array =
        &observed_virtual_coefficient_arrays[array_index];
    if (array_index != 0) printf(",");
    printf("{\"rowsInArray\":%u,\"blocksPerRow\":%u,"
           "\"maximumAccessRows\":%u,\"minimumHeights\":%zu,"
           "\"maximumSpaceBytes\":%zu,\"minheightSpaceBytes\":%zu}",
           array->rows_in_array, array->blocks_per_row,
           array->maximum_access_rows, array->minimum_heights,
           array->maximum_space_bytes, array->minheight_space_bytes);
  }
  printf("],\"preRealizeAllocationEvents\":[");
  for (size_t allocation_index = 0;
       allocation_index < pre_realize_allocation_event_count;
       allocation_index++) {
    pre_realize_allocation_event *allocation =
        &pre_realize_allocation_events[allocation_index];
    if (allocation_index != 0) printf(",");
    printf("{\"kind\":\"%s\",\"poolID\":%d,"
           "\"logicalPayloadBytes\":%zu,\"firstDimension\":%u,"
           "\"secondDimension\":%u,\"poolBytesBefore\":%zu,"
           "\"poolBytesAfter\":%zu,\"poolGrowthBytes\":%zu}",
           pre_realize_allocation_kind_name(allocation->kind),
           allocation->pool_id, allocation->logical_payload_bytes,
           allocation->first_dimension, allocation->second_dimension,
           allocation->pool_bytes_before, allocation->pool_bytes_after,
           allocation->pool_bytes_after >= allocation->pool_bytes_before
             ? allocation->pool_bytes_after - allocation->pool_bytes_before
             : 0);
  }
  printf("],\"events\":[");
  for (int index = 0; index < event_count; ++index) {
    if (index != 0) printf(",");
    printf("{\"scanNumber\":%d,\"visibleByteCount\":%zu,\"consumedByteCount\":%zu}",
           events[index].scan_number, events[index].visible_bytes,
           events[index].consumed_bytes);
  }
  printf("]}\n");

  free(final_output);
  free(events);
  jpeg_destroy_decompress(&cinfo);
  free(input);
  return 0;
}
