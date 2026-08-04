# Progressive JPEG real-photo corpus

`Evidence/Fixtures/ProgressiveJPEGRealPhoto/v1` is a small, versioned experiment corpus for separating three causes that a single generated fixture cannot distinguish:

1. source-image content;
2. progressive JPEG scan ordering;
3. transport chunk boundaries.

It is evidence infrastructure, not a representative image-quality benchmark.

## Source images

The corpus contains four 1920-pixel Wikimedia Commons derivatives of United States federal-government photographs:

| ID | Content class | Origin |
|---|---|---|
| `people-usda-meeting` | people / indoor | USDA photograph by Brien Aho |
| `landscape-coconino-sunflowers` | natural landscape / foliage | USDA Forest Service photograph by Gary Garner |
| `architecture-usda-snow` | architecture / snow / fine edges | USDA photograph by Christophe Paul |
| `animal-usda-cow-sunset` | animal / silhouette / smooth gradient | USDA photograph |

Each source page identifies the work as public domain and not requiring attribution. `manifest.json` retains the source page, exact downloaded CDN URL, original Wikimedia SHA-1 and dimensions, committed derivative SHA-256, byte count, description, creator, date, and public-domain basis.

The committed source bytes are the reproducibility boundary. Regeneration does not access the network and does not assume that Wikimedia thumbnails remain stable.

## Encoding matrix

Every source is decoded by libjpeg-turbo `djpeg` and re-encoded at quality 75 with 4:2:0 sampling and optimized Huffman tables under three scan scripts:

- `default-successive-v1`: the ten-scan successive-approximation sequence documented as equivalent to `jpeg_simple_progression` for YCbCr;
- `spectral-balanced-v1`: the seven-scan spectral-selection example from libjpeg-turbo `wizard.txt`;
- `luma-frontloaded-v1`: a nine-scan experimental sequence that sends every luma AC band before chroma AC.

The generator decodes every encoded variant again with `djpeg` and requires all three scan scripts for a source to produce the same final PPM bytes. Scan ordering can therefore change progressive availability and file size, but not the final quantized image in this matrix.

## Verification

Static verification checks committed hashes, dimensions, progressive SOF2 structure, scan counts, source/script cross-product completeness, and public-domain declarations:

```sh
python3 Tools/Corpus/verify_progressive_photo_corpus.py \
  Evidence/Fixtures/ProgressiveJPEGRealPhoto/v1/manifest.json
```

Full regeneration requires libjpeg-turbo 3.2.0 and compares the regenerated tree byte-for-byte:

```sh
scripts/verify-progressive-photo-corpus-reproducibility.sh
```

The release-readiness gate runs full regeneration. The normal verification gate performs static verification only.

## Evidence command

`ImageCraftEvidence --progressive-photo-case` decodes one encoded variant at a specified chunk size, then records:

- actual emitted generation count;
- source byte count and encoded-byte fraction for every generation;
- deterministic sRGB RGB8 pixel SHA-256;
- fixed-point absolute-error totals, MSE, PSNR, maximum channel error, and channel-error coverage relative to the final ImageIO decode.

A scan threshold does not guarantee that ImageIO can produce pixels at that exact append. A single chunk can also cross several thresholds. Consequently, generation count is an observed result, not a value inferred from the JPEG scan count.

The complete 4 × 3 × 2 matrix is captured with:

```sh
scripts/capture-progressive-photo-matrix.sh output.json
```

Every case is executed twice and must produce byte-identical JSON.

## Limits

Four public-domain photographs do not represent the distribution of images seen by applications. This corpus does not establish subjective usefulness, recognition accuracy, SSIM, visual masking, HDR/wide-gamut behavior, orientation behavior, mobile-device timing, network-to-presentation latency, or a universally optimal scan script. Pixel error against the final decode is a diagnostic measure, not a perceptual-quality standard.

## Exact scan checkpoints

The companion checkpoint oracle parses every retained JPEG scan and probes ImageIO at exact structural prefixes, independently of the production 1/2/4/8 scheduler. It compares a fresh incremental source with a repeatedly updated source and records deterministic pixel metrics against the final decode. Capture and policy analysis are documented in `docs/PERFORMANCE.md`; the versioned evidence is `Evidence/Experiments/progressive-jpeg-scan-checkpoint-policy-2026-08-04.json`.
