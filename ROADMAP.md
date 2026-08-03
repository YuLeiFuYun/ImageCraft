# ImageCraft Roadmap

ImageCraft is an actively developed pre-1.0 package. The repository contains only the current public contracts, implementation, tests, retained corpus, and reproducible evidence needed to validate them.

## Current baseline

- Independent SwiftPM products: `ImageCraftCore` and `ImageCraftImageIO`.
- iOS 15+ and macOS 12+.
- Bounded PNG/JPEG/GIF probing and static primary-frame decoding.
- Static PNG and JPEG encoding with explicit color, orientation, alpha, metadata, and output-byte policies.
- Versioned capability, resource, lifecycle, and failure contracts.
- Public API, external-consumer, retained-corpus, independent-oracle, platform, and performance gates.

## Active priorities

1. Extract a reusable codec conformance kit with versioned fixtures and observation schemas.
2. Model prepared-state, framework-private allocation, output ownership transfer, branch coexistence, and cancellation reclaim as a phase-aware resource ledger.
3. Add production-grade incremental/progressive sessions only after bounded lifecycle and cancellation semantics are demonstrated.
4. Add animated-image semantics only with disposal, blend, timing, loop, frame-window, and memory-budget evidence.
5. Qualify HDR, gain-map, auxiliary-image, HEIF/AVIF, and non-`CGImage` outputs on physical devices.
6. Keep ImageIO as the conservative reference backend while admitting additional codecs through the same finite contract and conformance gates.
7. Separate a platform-neutral semantic layer only after a real non-Apple implementation proves the boundary.

## Release policy

- `main` may contain breaking changes before 1.0.
- Every published development tag is immutable.
- Stable claims require clean-clone CI, public API review, current integration gates, and evidence bound to the exact source identity.
- Capability gaps and non-comparable results remain explicit; no global “best codec” claim is permitted.
