# Resource model

ImageCraft treats resource control as an ownership and lifecycle problem, not as one peak-memory
scalar. A number is eligible for hard admission only when the implementation can explain which
owner holds the bytes, during which phase, and what makes the upper bound conservative.

## Phase ledger

The current package-scoped qualification ledger separates:

1. `retainedBetweenCalls`: codec/backend state that remains alive while no decode call is running;
2. `operationPeak`: the complete codec-owned charge while the next decode operation is running;
3. `transferredOutput`: bytes whose ownership has moved to the caller after publication.

`retainedKnownBytes` is intentionally weaker than a phase bound. It records bytes ImageCraft can
count even when additional private state is opaque. An unknown phase carries a causal reason rather
than substituting a tight-pixel formula or an observed RSS sample.

`bounded(N)` is a provable **admission byte charge** for explicitly governed payloads. It is not a
claim that process RSS is at most `N`: allocator bookkeeping, Swift/CoreFoundation object headers,
VM page rounding, framework code/data and unrelated caches are outside this charge. A phase stays
unknown when the dominant retained/output payload itself is framework-chosen; ImageCraft does not
reverse-engineer wrapper metadata into a false physical-memory theorem.

Branch coexistence is explicit: caller-retained preview/final outputs are added to a new operation
only after ownership transfer. They are not silently charged twice to the codec.

Terminal snapshots require zero codec-owned retained state and zero future operation/output charge.
This makes cancellation/reclaim a falsifiable lifecycle property.

## Current backend classification

| Path | Retained between calls | Operation peak | Transferred output |
| --- | --- | --- | --- |
| Progressive JPEG session | bounded retained `Data` | unknown ImageIO private allocation | unknown Core Graphics output layout |
| libjpeg-turbo progressive suspension research probe (not a package backend) | fixed 128 KiB source work buffer + source-derived row/coefficient geometry model for pinned 3.2.0 arm64 SIMD grayscale/4:4:4/4:2:2/4:2:0; multi-minheight geometries retain the sharp pre-coefficient hinge | 48-case edge matrix + 5 retained held-out cases exactly reconstruct post-header row-array growth and `jpeg_start_decompress` pool from sampling/width + pinned allocator topology; private control-state ABI and production authority remain unqualified | raw RGB research payload only; no public representation contract |
| Static prepared ImageIO | bounded encoded `Data` + separately retained pure-value payloads such as reassembled ICC, under `ImageDecodePreparationLimits` | unknown ImageIO private allocation | unknown Core Graphics output layout |
| Package-only independent static PNG → packed RGBA8 | bounded 0 between calls | bounded under explicit operation authority: caller-owned IDAT ranges are read through a validated cursor; codec-owned payload is one 36 KiB DEFLATE logical-output window + bounded Huffman workspace + two source rows at exact encoded row byte width + final packed RGBA8, with embedded-ICC security phase charged separately | exact codec-owned packed RGBA8 + retained ICC value bytes |
| Package-only independent RGB/RGBA16 PNG → straight RGBA16LE | bounded 0 between calls | bounded for the qualified non-interlaced sRGB slice: same caller-owned IDAT cursor and DEFLATE workspace + two exact source rows (6 Bpp RGB16 or 8 Bpp RGBA16) + final straight RGBA16LE; RGB16 tRNS is a scalar key comparison, not a frame-sized allocation | exact codec-owned straight RGBA16LE |
| Package-only independent progressive JFIF 4:2:0 backend + incremental session | complete-input path retains 0 between calls. Incremental path borrows each caller `Data` only for the call. v4 separates encoded marker extent from parser residency: a length-bearing JPEG marker may encode 65,537 B, but marker headers are consumed immediately, APP/COM payloads stream-skip under declared-length metadata accounting, DQT commits 65 B/table, DHT at most 273 B/table, and JFIF/ICC/Adobe inspect only 14/12/12 B semantic prefixes. The largest qualified entropy transaction is AC-first at 1,642 bits; DC-first and AC-refine are bounded by 162 and 1,085 bits. Worst-case byte stuffing plus a restart marker yields a 414 B transport authority, so before SOF2 transport + 2,460 B normalized table state = 2,874 B initial retained | admission remains phase-aware: `operationPeak = max(initialRetained + state, transport + state + output + 768 B rollback scratch)`. The six-block rollback buffer is operation-only temporary allocation. A maximum-length 65,537 B COM and near-maximum single DQT/DHT segments stream through the 414 B transport; the 132,270 B retained entropy scan reaches but does not exceed 414 B observed occupancy. Metadata overflow is rejected from the marker header before payload residency. Terminal cancel/failure/finish publishes the zero ledger | exact codec-owned raw RGB8 research payload with `.codecOwnedRGB8` transfer authority. Every-scan preview reuses one RGB backing. Entropy requires exact `FF 00` stuffing. Shared JFIF authority now requires a structurally complete JFIF APP0 as the first marker after SOI and accepts Adobe APP14 only when transform=1 agrees with YCbCr; malformed/late JFIF, embedded ICC, Adobe RGB/YCCK conflicts fail closed. This remains package-only: JFIF 4:2:0 only, no public `DecodedImage` adapter, and no physical-RSS/allocator-bookkeeping theorem |
| Owned GIF/APNG playback state | bounded payload/palette/checkpoint admission charge | unknown once Core Graphics rendering is included | unknown Core Graphics output layout |
| Encoded ImageIO animation fallback | unknown retained `CGImageSource` | unknown ImageIO private allocation | unknown Core Graphics output layout |
| Prepared JPEG animation sequence | unknown retained per-frame `CGImageSource` state | unknown ImageIO private allocation | unknown Core Graphics output layout |

Progressive JPEG session failure is terminal once input has been accepted into the session and a non-recoverable semantic/parser/output invariant fails. Fatal SOI/marker errors, baseline capability mismatch, EOI-known trailing bytes, final container/metadata validation failure, downstream prepared-store admission failure, and crossing the package-internal 500-scan CPU-amplification ceiling all release the retained encoded `Data` immediately and publish the terminal zero-session ledger; subsequent append/finish calls are fenced. The same 500-SOS ceiling is applied by the complete JPEG security scanner before ImageIO, so bypassing progressive preview does not remove the protection. The ceiling is a work-amplification policy, not an encoded-byte or memory charge and not a JPEG conformance limit; current versioned retained/evidence JPEGs top out at 10 scans. In contrast, an encoded-byte admission rejection that occurs before the candidate chunk is appended leaves the session retryable with unchanged retained ownership. This distinction prevents both hidden retention after a thrown fatal error and accidental terminalization of a genuinely unaccepted chunk. The session intentionally retains the complete accepted JPEG body until finalization because its public contract can produce final pixels/preparation without a separate caller-owned source; `consumedThrough` therefore records parser progress, not a false claim that the consumed prefix has been discarded.

The independent libjpeg-turbo suspension probe demonstrates a different ownership shape without changing that public contract. Once a transport chunk has been incorporated into libjpeg's coefficient state, the source manager need retain only the library-declared rollback tail plus newly visible bytes inside a fixed 128 KiB work buffer; previously consumed entropy need not be replayed or retained by the decoder state. The dominant retained payload is therefore the progressive coefficient arrays, not the full encoded prefix. For pinned libjpeg-turbo 3.2.0 the probe computes coefficient geometry from public component block/sampling facts, observes private `jmemmgr.total_space_allocated` at lifecycle checkpoints, and intercepts `realize_virt_arrays` only to read the already-created private virtual-barray controls before backing allocation. The capture rejects any unexpected virtual-sarray and cross-checks each barray's rows/blocks against the public JPEG component geometry. On the largest retained 1920×1285 4:2:0 case, coefficient arrays are 7,464,960 B, EOI pool allocation is 7,549,477 B, and the 131,200-byte source-manager state yields 7,680,677 B of observed decoder live bytes before output. Rendering the 7,401,600-byte RGB result while the pool remains live yields 15,082,277 B of observed modeled live payload.

The same probe now separates **virtual-array admission** from **whole-decoder memory**. For the four 1920-wide cases, allocator `maxaccess` requires more than one minheight, so the no-backing-store decision has a sharp source-bound hinge. In the 1920×1285 case, pre-realize pool is 84,009 B and full virtual coefficient space is 7,464,960 B: `max_memory_to_use=7,548,968` fails with `Memory limit exceeded` while the observed pool is still exactly 84,009 B, whereas `7,548,969` completes with byte-identical RGB. The pool immediately after successful start is 7,549,134 B, 165 B above the configured value, proving that this field controls the virtual-array availability decision rather than total pool allocation. The 23×13 fixture is the complementary counterexample: every virtual coefficient array fits inside libjpeg's mandatory one-minheight fallback, so even `max_memory_to_use=1` succeeds and the post-start pool reaches 23,246 B. A universal “threshold-1 must fail” rule is therefore false for small geometry.

A fixed additive overhead is already falsified. Holding 1920×1285 source RGB and encoder settings constant while changing only sampling produces `EOI pool - coefficient payload` of roughly 33.7 KiB grayscale, 65.2 KiB 4:4:4, 53.8 KiB 4:2:2 and 84.5 KiB 4:2:0. The variable term is now mechanistically accounted for in the qualified research domain. The pre-realize trace shows that all pool growth after `jpeg_read_header` and before coefficient realization comes from `alloc_sarray` row storage; source-derived upsampler/main-controller geometry predicts the request shapes, and the pinned allocator's row alignment, large-pool header/alignment cost and chunking predict the exact pool growth. A 12-width × 4-sampling edge matrix is exact for all 48 cases, including the width-4→5 h2v2 context-row branch and 64-byte alignment boundaries. Adding full `JBLOCK` array allocation predicts `jpeg_start_decompress`'s completed pool exactly in the same 48 cases, then a separate 5-case retained-photo/tiny held-out set reproduces the same result with no fitted residual.

The remaining production admission problem has therefore changed. The geometry-dependent row/coefficient term is no longer the unknown; ImageCraft now owns the **source fact** beneath that term. `JPEGFrameSamplingGeometry` parses the qualified SOF0/SOF2 frame once and records coding mode, component sampling, max sampling factors, output-iMCU geometry and internal boundary count without inventing color semantics. `JPEGProgressiveResourceGeometry` consumes that immutable frame geometry and adds the progressive-only coefficient-array and full-scale fancy-row logical payloads. The 48-case generated matrix and 5-case retained held-out validation compare those package values against the pinned libjpeg observation/source model rather than maintaining a second sampling parser in evidence code.

The allocator frontier has moved again. The complete-input independent progressive JFIF 4:2:0 backend still owns one geometry-derived aligned arena for padded coefficients, quantization/progression/Huffman/IDCT control and width-bounded reconstruction rows, with tight RGB8 admitted before payload allocation. The incremental session no longer retains a whole length-bearing marker. v4 consumes the marker prefix/code/length first, charges APP/COM metadata from the declared payload length, and retains only the semantic unit needed to decide or install that marker: 65 B per DQT table, at most 273 B per DHT table, 14 B for JFIF authority, and 12 B for ICC/Adobe identification. Other APP/COM payload is discarded incrementally. Marker fill remains normalized to one unresolved `0xFF`. The marker-format maximum therefore stays 65,537 encoded bytes while marker residency falls to 273 B.

The remaining transport term is entropy, and its bound is derived from the decoder's qualified syntax rather than from current corpus occupancy. Interleaved DC-first is at most six blocks × (16 Huffman bits + 11 magnitude bits) = 162 bits. AC-refine is conservatively bounded by 63 longest Huffman codes + 63 refinement bits + 14 EOBRUN bits = 1,085 bits. AC-first dominates: the bit-maximizing terminal form is 62 newly nonzero coefficients at 16+10 bits each plus one EOBRUN at 16+14 bits = 1,642 bits. Filling all 63 coefficients is four bits smaller. Rounding 1,642 bits to entropy bytes, doubling every byte for worst-case `FF 00` stuffing, then allowing a two-byte restart marker yields **414 B**. This corrected a v3 draft bound of 412 B that had incorrectly treated the EOBRUN suffix as a 10-bit magnitude. v4 transport is therefore `max(273, 414) = 414 B`; transport plus 2,460 B normalized pre-frame table state yields only **2,874 B initial retained**. SOF2 still briefly coexists with the exact new frame state, then pre-frame tables are released before RGB allocation; the 768 B six-block rollback arena remains operation-only scratch.

The falsifiers now pressure every layer of that decomposition. A maximum-length 65,537 B COM streams without whole-marker residency. A single near-maximum DQT marker containing 1,000 repeated 65 B table definitions streams table-by-table and remains byte-identical to complete decode; a corresponding near-maximum single DHT marker streams by its table units. A large valid JFIF APP0 thumbnail is admitted from its 14-byte authority header and its thumbnail bytes stream away. Metadata ceiling-1 on a maximum COM is rejected immediately when its four-byte marker/length header declares the payload, before the payload is accepted into the transport window; the exact metadata boundary streams and decodes. Legal repeated `0xFF` fill longer than two maximum marker segments is reclaimed in ordinary and restart-marker contexts. Conversely, entropy-coded data accepts exactly `FF 00`; non-standard `FF FF ... 00` fails closed. The retained 132,270 B entropy scan completes with maximum observed transport **414 B**, while all 342 restart markers remain split at `0xFF | Dn` in their retained schedule. The single-byte source still crosses every encoded boundary, and all ten previews alias one RGB backing.

This closes the narrow 4:2:0 **session payload/control-state, phase-lifetime, marker-streaming and entropy-transaction** authority; it does not close the production engine. A package-only concurrent qualification adapter maps received/consumed/retain-from semantics, stable/tentative facts, cancellation fences and the separated phase ledger into the existing progressive-session contract without Core Graphics. Source-color authority is also explicit: JFIF must be structurally complete and the first marker after SOI; embedded ICC remains outside the slice; Adobe APP14 is accepted only when transform=1 agrees with JFIF YCbCr. The shared JFIF/Adobe gates also protect baseline 4:2:0/4:4:4 paths. The next resource question is no longer transport residency. It is whether the remaining `StateArena` fixed/control terms and RGB preview/output lifetime can be further decomposed or reused without weakening transactional rollback, alongside the separate public representation/color boundary. Progressive sampling breadth and reconstruction quality remain independent axes. `DecodeLimits.maximumPixelCount`, encoded bytes, coefficient bytes plus a magic constant, or libjpeg's `max_memory_to_use` remain insufficient substitutes for that composition.

Package-only owned-RGBA output qualification establishes a narrower transfer boundary. ImageCraft
allocates a tight RGBA8 backing store, renders the finalized image into that exact stride, and
creates a `CGDataProvider` that directly retains the same backing. Its `transferredOutput` can then
publish a bounded pixel-payload charge. Preserve-source embedded ICC bytes are added to that charge;
if preserve-source color state is itself unclassified, transfer remains unknown with
`frameworkChosenOutputColorState`. ImageIO decode/color-conversion transients remain unknown in
`operationPeak`, so owned output does not imply a whole-operation physical-memory bound.

The owned GIF/APNG rows are deliberately not upgraded to a whole-engine memory claim. Their parser,
replay and checkpoint state is controlled, but final representation still crosses Core Graphics.

### Animation live-window seam

Owned GIF/APNG qualification now exposes a backend-neutral single-operation window estimator rather than
using the public whole-track estimate as a proxy for playback residency. For a requested frame count
within `maximumFrameDecodeWindow`, the estimator separately publishes the decoded-output payload
bound, provider-retained payload bound, and modeled predecode payload peak. The peak composes the
owned replay/decompressor model with every raw full-canvas frame materialized by that range, the
range's target raster payload, and a conservative two-raster renderer transient. It is still not a
hard `operationPeak` theorem: Core Graphics private allocation remains unknown in the phase ledger.

Caller-retained frames are deliberately not hidden inside the codec estimate. A separate coexistence
operation adds the exact caller-owned output charge that remains live while the next window is
decoded, with checked overflow. This makes host eviction/prefetch policy an explicit composition
input instead of assuming that decoding a window also bounds all frames already held by the caller.

A provider now grants only one heavy frame-decode operation slot at a time. Actor reentrancy may
queue additional callers, but they wait before capturing the prepared backing or entering the
concurrent executor, so `maximumFrameDecodeWindow` cannot be multiplied into multiple simultaneous
raw/raster windows inside one provider. Slot transfer is FIFO. Provider cancellation rejects queued
callers without running them; cancellation of an individual queued task releases a granted slot
before executor entry so the next waiter cannot be starved. The queued async-call metadata itself is
not promoted to a byte theorem: Swift task/continuation headers remain outside the payload admission
charge just like other allocator bookkeeping.

Cancellation is tied to the same lifecycle evidence. `cancel()` removes the provider-held prepared
backing immediately, waits for every already-registered frame operation to drain, and only then
returns. The package-only dynamic resource snapshot remains nonterminal while an in-flight operation
can still own the captured backing; after drain it becomes the terminal ledger, proving zero future
codec operation/output charge and zero retained governed backing payload. Deterministic executor-gate
tests cover the interleaving so reclaim is not inferred from timing or object destruction.
Cancellation now has a stronger provider-lifecycle contract: the provider drops its prepared backing
reference as soon as cancellation is observed, fences any later publication, and does not return from
`cancel()` until already-registered frame operations have drained. An in-flight operation may still
hold its captured backing until that operation completes; this is intentional and is accounted as
live operation state rather than retained-between-calls state. Package-only lifecycle diagnostics
make provider backing ownership and active-operation count directly falsifiable under a deterministic
executor gate.

### Backend-neutral packed value seam

`ImagePackedRGBA8` now removes the final framework-chosen row-layout ambiguity from a qualification
output. Its value contract is tight RGBA8, premultiplied alpha, top-to-bottom logical rows, and an
explicit value color encoding (`sRGB` or bounded embedded ICC bytes). The pixel `Data` and retained
ICC payload therefore have exact transfer charges. A 2x2 asymmetric-byte oracle is retained because
a prior Core Graphics materializer accidentally inverted row order while CGImage-to-CGImage tests
still passed; cross-backend value semantics must not be self-validated through the same renderer.

The v1 cross-backend research profile in `Evidence/Experiments/CrossBackendJPEG/v1/profile.json`
separates this exact representation contract from lossy JPEG reconstruction equality. Its real
second implementation input is the clean, pinned `AxiomRasterCodecJPEG.NativeScalar` backend; the
probe is research-only and does not enter either Swift library product. Dimensions, tight stride,
RGBA/opaque-alpha semantics and spatial/channel ordering are hard checks. ImageCraft-vs-Axiom pixel
deltas, each backend's distance from libjpeg-turbo, and each backend's distance from the deterministic
source pattern are observations rather than thresholds. The old T68 max-error/mean-error gate remains
frozen and negative where it was negative; this profile cannot widen it or qualify a production
backend.

### Independent PNG operation-bound seam

`PNGIndependentRGBA8Decoder` is a package-only second implementation for a deliberately bounded PNG
domain: static non-interlaced grayscale 1/2/4/8-bit, grayscale+alpha8, RGB8, RGBA8 and indexed 1/2/4/8-bit
sources plus a separately qualified Adam7 RGBA8 slice, all with full-resolution output, contiguous IDAT,
and an explicit color authority. Indexed PLTE/tRNS, grayscale/RGB tRNS and truecolor suggested PLTE are
qualified within their structural rules. Explicit sRGB is accepted; a structurally validated RGB ICC
value is accepted only for preserve-source on the non-interlaced RGB/RGBA path. Untagged PNG is
uncalibrated/device-dependent and therefore fails closed instead of being relabeled sRGB. Adam7 is
currently admitted only for RGBA8 with explicit sRGB; other interlaced source/color combinations remain
outside the claim. This RGBA8 backend still does not claim 16-bit samples, animation, arbitrary resizing,
or an independent color-management transform; high-depth stored samples use the separate seam below
rather than being collapsed into this representation. `eXIf`, `cICP`, `gAMA`/`cHRM`,
`mDCV`/`cLLI` and other unimplemented semantic inputs fail closed rather than being silently
approximated. The shared PNG scanner follows PNG color-authority precedence (`cICP` above iCCP above
sRGB). The RGBA8 backend still leaves cICP unqualified and therefore rejects the unclassified source
color state rather than falsely inheriting a lower-priority ICC or sRGB label; the separate high-depth
packed seam below now has a structured raw-cICP value contract.

The key resource mechanism is not merely row-wise filtering. The pure RFC1950/RFC1951 decoder now
streams decompressed bytes through one fixed 36 KiB circular logical-output window: eight 4 KiB
slots retain the complete RFC1951 32 KiB lookback and one 4 KiB slot is the current pending delivery
span. Full flushes advance exactly one slot, so no second staging-to-history copy is required and the
pending sink slice remains physically contiguous. PNG unfiltering consumes those slices across
arbitrary delivery boundaries while retaining only previous/current straight rows and writing
directly into the final premultiplied packed value. The complete inflated scanline stream therefore
no longer exists as a frame-sized allocation.

The Adam7 RGBA8 slice preserves the same payload envelope instead of allocating seven pass surfaces.
Its streaming state machine consumes pass rows directly from the same RFC1950 window, resets the
previous-row filter state at every pass boundary, and scatters each premultiplied sample into the final
full-resolution packed buffer. Both row buffers are sized to the full RGBA8 row, which conservatively
dominates every Adam7 pass row. Empty passes carry no row allocation. Consequently the existing
`final RGBA + two source rows + inflater/Huffman workspace` admission charge remains an upper bound
for this slice; interlace broadening is a semantic qualification change, not a hidden memory-model
relaxation.

### High-depth packed value seam

High-depth qualification uses a distinct value contract rather than silently widening the meaning of
`ImagePackedRGBA8`. `ImagePackedPixelFormat` separates sample storage, channel layout, alpha
association and multibyte byte order. The first concrete high-depth value is tight, top-to-bottom
straight RGBA16 with canonical little-endian samples. Keeping alpha straight is part of the exactness
claim: integer premultiplication at partial alpha would destroy source RGB information before
ownership transfer.

`PNGIndependentRGBA16Decoder` qualifies all four standard non-indexed 16-bit PNG source channel
models—grayscale, grayscale+alpha, RGB and RGBA—with explicit sRGB and full-resolution output in both
non-interlaced and Adam7 scan order. PNG filtering is still performed on stored big-endian source
bytes with exact source `bpp`: 2, 4, 6 or 8 respectively. Grayscale expands one stored UInt16 sample
into R/G/B only at final write; grayscale+alpha additionally preserves its stored straight alpha.
Gray and RGB `tRNS` keys are compared in the complete UInt16 stored-sample domain before synthetic
alpha is written. Adam7 uses the same checked seven-pass geometry as the RGBA8 backend, resets
previous-row filter history at every pass boundary, and scatters/expands directly into the final
RGBA16LE surface. The operation charge is final `width * height * 8`, two exact source-row buffers at
`width * {2,4,6,8}`, the same bounded Huffman workspace, and the same 36 KiB streaming logical-output
window. tRNS keys are scalar metadata and add no frame-sized staging. There is no second compressed-body
copy, full inflated surface, CGImage, pass surface, or high-depth premultiplied staging surface.
`codecOwnedStraightRGBA16LE` remains a separate transfer authority from the existing RGBA8 authority.
For preserve-source RGB ICC, admission happens before profile inflate: the pixel-side worst case is the
base high-depth charge plus `maximumMetadataBytes`, while the security side is the bounded RFC1950
maximum-output charge; the admitted peak is their maximum. After materialization the published ledger
uses the actual retained profile byte count, and transferred output is `RGBA16 bytes + ICC bytes`.
The explicit-sRGB path never reserves the unused ICC ceiling, and the compressed iCCP body remains a
borrowed caller-owned range rather than a second codec-owned copy.

The packed pixel payload remains exact for the 16-bit samples stored in the PNG datastream. When
`sBIT` is present, the shared scanner and packed value publish the actual source channel model rather
than projecting every source onto RGB: `.grayscale`, `.grayscaleAlpha`, `.rgb`, or `.rgba`. Accepting
sBIT never rewrites or rescales stored samples. A source without stored alpha keeps alpha significance
absent even if normalization later synthesizes opaque or tRNS-derived output alpha. Original reference
samples remain recoverable by right-shifting each stored sample by `16 - S`; fixed metadata adds no
operation-sized allocation and does not change admission. Adam7 keeps the same payload envelope as the
corresponding same-size non-interlaced source: final 8-Bpp value + two full-width source rows at exact
2/4/6/8 Bpp + the same inflater/Huffman workspace, with no pass surface. Gray/RGB `tRNS` remains a
scalar full-UInt16 comparison before alpha injection, so interlace does not widen its precision domain
or workspace. RGB/RGBA16 also have a preserve-source embedded-RGB-ICC value contract: profile bytes
are retained beside exact samples without a CMS transform. One additional embedded-ICC conversion slice
accepts forward-device RGB/XYZ matrix/TRC profiles whose class is monitor (`mntr`) or input (`scnr`), with a nondegenerate authored source colorant matrix and no LUT/MPE transform. Monitor profiles retain the D50-media-white plus matrix-reconstructs-white gate within s15Fixed16 quantization tolerance; input profiles instead treat `wtpt` as captured-medium metadata and require nonnegative X/Z with positive Y, without requiring device code `[1,1,1]` to reconstruct that medium white. Both classes then require
either one shared qualified RGB TRC—parametric type-0...type-4 whose source-domain mapping is finite, normalized, weakly nondecreasing and requires no source clipping, or `curveType` count=0 identity, count=1 positive u8Fixed8 forward gamma, or count>1 normalized weakly-nondecreasing UInt16 samples—or three independent per-channel TRCs in any combination of those already-qualified curveType/parametric encodings, with every channel independently passing the same finite/normalized/monotone/no-source-clipping validation. Sampled nodes are uniformly spaced across `[0,1]` and evaluated by linear interpolation; the converter retains only the original ICC `Data` plus sample offset/count and reads samples in place, so no decoded-table copy is added to `operationPeak`. Type-0 requires positive gamma; type-1/type-2 add positive affine scale, an in-domain threshold and normalized upper endpoint; type-3/type-4 retain valid breakpoint/power-base plus near-continuity and normalized endpoints, with type-4 preserving e/f offsets. The source matrix/TRC is parsed from the profile itself and the target is the ICC reference sRGB D50 Matrix/TRC space; retained evidence includes Display-P3+sRGB-like type-3, non-P3 sRGB-D50-primaries+gamma2.2 type-3, sRGB-D50 type-0 gamma1.8/gamma2.2, distinct type-1/type-2/type-4 piecewise profiles, curveType identity/gamma1.8/gamma2.2/nonlinear 5-node sampled plus deterministic 1025-node sampled cases, one per-channel type-0 profile with R/G/B gamma approximately 1.8/2.0/2.2, one mixed per-channel parametric profile using type-1/type-3/type-4 simultaneously, and one mixed-encoding profile using sampled curveType/type-3/single-gamma curveType simultaneously so matrix-, channel-, TRC-kind-, curve-, function-number-, cardinality- and table-driven behavior are explicit.
The decoded profile bytes remain live through the pixel phase and therefore stay in `operationPeak`, but
converted output uses `.sRGB` and does not transfer the source profile bytes. The transform is
per-pixel/in-place, preserves alpha, allocates no second frame surface, and admits only fixed-point endpoint
noise within 8/65536; larger target-gamut excursions fail closed rather than being clipped or gamut-mapped. Full-range Display-P3 SDR, BT.2100 PQ and
BT.2100 HLG cICP are now represented as fixed structured authority beside the same exact raw samples;
that metadata adds no retained payload or transfer charge, and lower-priority iCCP is neither inflated
nor retained when cICP is present. `sourceColorProfile` remains `.unknown` because its public coarse enum
cannot encode cICP without lying. Full-range Display-P3 additionally has one RGB/RGBA16
`.convertToSRGB` path: after row/pass decode it converts each pixel through linear light, preserves alpha,
and writes the converted samples directly into the same final 8-Bpp value. It allocates no second frame
surface and therefore does not widen the same-size operation or transfer envelope; because no gamut
mapping is defined, any converted component outside [0,1] fails the whole operation closed. Full-range
BT.2100 PQ may additionally retain exact typed mDCV/cLLI static metadata beside the raw value: mDCV
stores eight UInt16 chromaticity integers plus two 31-bit UInt32 luminance integers, and cLLI stores two
31-bit UInt32 light-level integers. They are fixed-size semantic facts, add no payload/transfer/operation
charge, and do not imply tone mapping. Grayscale/GA cICP, narrow or unqualified tuples, P3/HLG static HDR
metadata, out-of-gamut P3 conversion through either authority, PQ/HLG conversion, preserve-source cICP
CoreGraphics materialization, non-RGB ICC, ICC LUT/MPE transforms, per-channel TRCs containing any individually-unqualified curve, curveType zero-gamma or sampled tables that are non-normalized/non-monotone, or parametric profiles that are non-normalized/non-monotone/discontinuous or require source clipping,
non-D50/white-mismatched monitor profiles, implausible input media white, degenerate matrix profiles, ICC conversion with sBIT/HDR metadata and resizing
remain fail-closed. Per-channel composition adds only each channel's curve parameters or sampled bytes already present in the retained ICC profile; the type0 targeted resource gate proves a 32-byte larger profile raises `operationPeak` by exactly 32 bytes while leaving `transferredOutput` unchanged, while mixed curveType/parametric composition still borrows sampled nodes in place. A separate 5-node versus 1025-node sampled-curve gate fixes profile sizes at 320 versus 2360 bytes and proves `operationPeak` rises by exactly the 2040-byte retained-profile delta while `transferredOutput` remains pixel-only; no decoded sample table or cardinality-dependent staging payload is charged. The 1025-node formal slice explicitly raises the probe's historical `maximumMetadataBytes` budget from 1024 to 4096; the 1024 probe budget rejects the same profile before ICC inflate/transform, while the product `DecodeLimits.coreV1` 4MiB default remains unchanged. Thus this qualification changes neither global metadata admission nor production defaults. The profile-class seam now combines synthetic isolation with real-device evidence. Class-only parity pairs prove identical stored-source pixels and identical operation/transfer bounds, while `prtr` stays fail-closed. Real-profile negative coverage retains two unmodified ICC Profile Library `scnr/RGB/XYZ` scene-referred profiles. Their 25,612-byte and 5,540-byte payloads are admitted with per-case metadata ceilings of 32,768 and 8,192 bytes—strictly above the actual profiles—yet both still fail at the LUT/MPE semantic gate because their forward transforms are `mAB`/A2B rather than matrix/TRC. A separate 724-byte positive `scnr` profile is derived from a real Epson 3170 no-color-correction 48-bit scan and 288 measured IT8 patches using ArgyllCMS `scanin` plus `colprof -ag -nc`; it has per-channel single-gamma `curveType` TRCs, real device colorants and a non-D50 medium white. Because 724 bytes remains below the formal probe's historical 1,024-byte metadata ceiling, adding real input semantics does not widen metadata admission. The profile stays in `operationPeak` only during conversion and transfer remains the same 80-byte pixel payload for each retained 5x2 case; no decoded TRC table or second frame surface is introduced. The external CMS differential is also kept orthogonal to resource admission: the formal LittleCMS probe publishes its virtual-sRGB target matrix, and a source/TRC-invariant counterfactual reduces the retained real-input delta from16 codes to≤1 without changing any ImageCraft allocation or admission rule; the source-bound 17³ mechanism sweep similarly reduces39 to≤1. This separates metadata admission, transform admission, profile-class semantics and target-CMM numerical realization. The next bounded high-depth ICC seam is an unmodified redistributable real matrix/TRC input profile plus broader real-input transform diversity; LUT/MPE and explicit gamut/tone-map policy remain separate general-CMS work rather than source-channel breadth, raw profile, raw cICP signaling or PQ static-metadata retention.

The operation ledger admits the worst case before IDAT or iCCP inflate. For the RGBA8 pixel phase it
charges the final 4-byte-per-pixel packed RGBA payload, two source-row buffers at the exact encoded
row width (`ceil(width * sourceBitsPerPixel / 8)`, including packed indexed 1/2/4-bit rows), 24 KiB
bounded Huffman workspace, and the single 36 KiB streaming lookback/delivery window. PNG filtering
uses the specification's byte-based `bpp`, so sub-byte indexed rows still use filter `bpp = 1` and are
unpacked only after unfiltering. The zlib stream is read directly from validated contiguous IDAT ranges in the
caller-owned encoded PNG, so the backend no longer creates or charges a second compressed-body
`Data`. Embedded ICC inspection borrows the caller-owned compressed iCCP slice and uses bounded
maximum-output inflate; only the decoded value/ceiling and inflater workspace enter the codec-owned
security phase. The ledger takes the conservative maximum of security and pixel phases rather than
summing phases that do not coexist. This is an admission byte model for ImageCraft-owned payloads,
not a physical RSS theorem. A host that budgets total live memory must compose the caller-owned
encoded source separately instead of charging the same source again inside the codec phase.

The shared PNG security scan now publishes immutable `PNGValidatedContainerFacts` while it performs
its existing CRC/bounds traversal. The narrow decoder consumes those facts as the IDAT range/order
and source-semantics authority instead of reparsing the complete container. A fixed-size IHDR
preflight remains intentionally separate so request and operation-budget failures can precede large
metadata work; it is not a second whole-container interpretation pass. The facts state also closes an
IDAT run on every non-IDAT chunk, including recognized ancillary chunks such as `gAMA`, so a later
IDAT is rejected as noncontiguous rather than accidentally accepted through a type-specific branch.
Broadening PNG pixel/color semantics is a separate qualification axis and must not be mixed into the
resource claim.

## Why tight RGBA is not a hard returned-surface bound

`width * height * 4` is useful as a logical RGBA charge, but a returned `CGImage` exposes an actual
`bytesPerRow`, and row allocation may include padding. ImageCraft therefore keeps its historical
tight-RGBA model as a diagnostic/model input and marks the complete transferred-output phase
unknown for framework-created images.

The same rule applies to operation working set: a modeled pixel charge does not become a complete
ImageIO allocation theorem merely because it is larger than another estimate.

## Prepared-state authority

Static ImageIO preparation no longer retains `CGImageSource` across calls. `prepare` validates the
container and ImageIO metadata once, then stores the immutable encoded `Data`, `ImageProbe`, limits,
and pure-value security facts needed to reconstruct the same color/container interpretation.
Decode recreates a short-lived ImageIO source and revalidates framework metadata against those
facts; the container security scan itself is not repeated. Reassembled ICC bytes that exist as a
separate retained `Data` value are charged in addition to the encoded body.

`ImageDecodePreparationLimits` is an instance-level authority independent of each operation's
`DecodeLimits`. Its `coreV1` envelope allows at most 1,024 live tokens and 64 MiB of aggregate known
retained byte charge. Exceeding either dimension fails with `preparedStateBudgetExceeded`; consume
and `discard` synchronously release the corresponding charge. The charge is an admission model for
explicit payload bytes, not a claim that Swift allocator metadata or process RSS equals that value.

Static `prepare` reserves the encoded-body charge and an entry slot before creating any ImageIO
source. The pure container scan can extend that reservation for a separately retained ICC payload;
only then may framework inspection proceed. Successful preparation commits reservation → live
entry atomically. Container failure, ICC-extension rejection, or later inspection failure cancels
the reservation and restores both entry and byte authority. Concurrent qualification fixes this as
an admission invariant: 32 competing prepares against an 8-entry/8-body envelope admit exactly
eight and leave zero reservation/charge after the admitted tokens are consumed.

The old retained-source behavior remains package-only as an A/B qualification control. It is not
the public resource contract and continues to classify `retainedBetweenCalls` as unknown.

### Directional retained-source A/B

The 2026-08-12 high-load host campaign in
`.artifacts/performance/prepared-state-retention-facts-directional` ran four alternating AB/BA
pairs. Each process held 64 preparations of the same deterministic 3072×2048 JPEG, then measured
seven timed 512-fit prepare/decode iterations with exact output SHA-256. The campaign is bound to
source identity `6ded86f48953112b734b8f862981b10728c305b33b1e9f0d16074738be7d3709`.

After retaining pure-value container facts, data-only decode's repeated framework inspection was
about 0.100 ms at the process-median level. The paired data-only/retained total-duration ratio had a
median of 1.0014× and ranged from about 0.982× to 1.008×; the observed 64-token prepared RSS delta
was lower by about 1.16 MiB at the paired median. These are directional mechanism observations, not
stable performance/RSS claims: the host was loaded, the encoded `Data` values shared COW backing,
and RSS includes allocator/framework effects outside the admission charge.

## Frontier implementation inputs

- libjxl's decoder accepts an instance-level `JxlMemoryManager` for library dynamic allocations.
  This is a concrete example of making backend allocation authority host-visible.
- libjxl's incremental input API makes caller buffer ownership and release explicit: input remains
  caller-owned until `JxlDecoderReleaseInput`, reset, or destruction, and unprocessed bytes are
  reported back to the host.
- Skia's incremental decode API uses a caller-provided destination buffer and requires additional
  source data before another continue call. This makes output ownership and drive state explicit.
- Core Graphics exposes `CGImage.bytesPerRow` as the actual bytes allocated per bitmap row; the
  ImageIO thumbnail/image creation APIs do not provide ImageCraft a pre-decode maximum row stride.

These references motivate mechanisms only. ImageCraft does not infer conformance from API shape.
Any new backend must still pass retained-corpus, hostile-input, lifecycle, chunk/metamorphic, output
quality and cross-backend conformance evidence against its exact source identity.

## Next falsifiable gaps

1. Re-run the prepared-state AB/BA campaign on stable simulator and physical-device workloads, with
   distinct encoded bodies as well as shared-COW controls, before making a stable RSS/latency claim.
2. Close `operationPeak` for paths that still depend on opaque frameworks. The narrow independent
   PNG path now demonstrates a fully bounded codec-owned operation phase under explicit admission,
   but ImageIO decode and color-conversion transients remain private. A stronger general backend must
   accept host allocator/workspace authority or otherwise prove its complete operation charge.
3. Pre-register an independently justified lossy-JPEG reconstruction-quality policy before any new
   production second-backend qualification. Backend-to-backend equality is not that policy: retained
   4:2:0 evidence already shows large reconstruction deltas while source-domain fidelity can remain
   comparable.
4. Broaden high depth one semantic authority at a time. The PNG16 path now covers grayscale,
   grayscale+alpha, RGB and RGBA source models in non-interlaced and Adam7 scan order with exact gray/RGB
   tRNS and structured sBIT provenance, all behind one straight-RGBA16LE output contract and exact
   2/4/6/8-Bpp row accounting. Preserve-source RGB ICC and full-range P3/PQ/HLG cICP now have separate
   no-transform external oracles and bounded value contracts. Full-range PQ mDCV/cLLI now add exact
   orthogonal static-HDR integer metadata with no payload-charge widening. PNG channel breadth, raw color
   signaling and PQ static metadata are no longer the immediate gaps. Next qualify rendered ICC/cICP-to-
   target conversion and tone-map behavior without reusing raw-value claims, then decide whether P3/HLG
   static metadata warrants separate semantic slices.
5. Require every future independent backend adapter to publish the same phase ledger and packed-value
   observation. A backend that cannot bound a phase remains usable only under an explicit unknown
   resource policy; a backend that cannot normalize value semantics cannot enter pixel differential
   qualification.
6. The animation window model is now public for host admission after Fovea gained a production
   ImageCraft-backed animation preparer; continue qualifying host cache/pin/global-budget composition. One provider now serializes heavy decode windows, drains/cancels queued callers, and proves
   terminal reclaim. Source-bound Fovea inspection shows its wrap planner may decode two ranges
   sequentially while retaining the first range before the second, exactly the coexistence case modeled
   by the ImageCraft helper; however Fovea's current preparation seam carries only whole-track bounds.
   Keep extending host composition so cache/pin/global-budget
   state without weakening either side. Core Graphics private allocation remains outside the theorem.

No item above is a performance or physical-RSS claim. Physical memory, energy and thermal behavior
remain separate device evidence.
