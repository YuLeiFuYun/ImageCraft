# ImageCraft physical iOS HDR qualification

This probe answers one bounded runtime question: on a connected **physical iPhone**, does the frozen ISO gain-map HEIC fixture remain fail-closed for `.high`, or does ImageCraft produce genuine HDR pixels that satisfy its postconditions?

It does **not** enable gain-map HDR. Simulator results, generic iOS builds, and an unavailable device never authorize a capability change.

## Frozen inputs and controls

- SDR HEIF: `Tests/ImageCraftImageIOTests/Resources/Corpus/FormatBreadthV1/heif-rgba.heic`, 1221 bytes, SHA-256 `ddb7d01c6d793c20570e797308594d9115a14ba5e143790d5886ea810cad0dae`.
- ISO gain-map HEIC: `Tests/ImageCraftImageIOTests/Resources/Corpus/FormatBreadthV1/heif-iso-gainmap-sdr-hdr.heic`, 1488 bytes, SHA-256 `e5d0836dca09abea8d3ec041be00fa6561fbb811f6fc90b0220d9967c3673eed`.
- Direct-HDR positive control: generated on the physical device as a 16-bit PQ HEIC, round-tripped through ImageIO, then decoded through `ImageIOImageDecoder`.

The probe requires ImageCraft ImageIO implementation version 12 and advertised HEIF `.high` capability. Direct HDR must remain >8 bpc, HDR/extended-range, and `contentHeadroom > 1` at 2x1 and at 1x1 for both fit and fill. The default gain-map probe (`maximumAuxiliaryAttachments == 0`) must fail with `auxiliaryAttachmentLimitExceeded`; with an explicit limit of 1, the probe must report exactly one auxiliary attachment and an 8-bpc source. A `.standard` gain-map request must stay 8-bpc SDR with headroom <= 1.

For the gain-map `.high` and 1x1 `.high` requests, only two outcomes qualify:

1. `fail-closed`: exactly `unsupportedCapability(.dynamicRange(.high))`, with no pixels returned.
2. `hdr-success`: >8 bpc plus HDR/extended-range color space plus `contentHeadroom > 1`.

A successful decode that is still SDR is a qualification failure, not a successful fallback.

## Running

`scripts/verify-hdr-ios-device.sh --compile-only` builds the checked-in project for generic iOS with signing disabled. It validates the harness build only and deliberately does not satisfy the physical-device gate.

`scripts/verify-hdr-ios-device.sh` requires exactly one connected physical iPhone. It performs an automatic-signing device build, installs and launches the app, copies the JSON result from the app data container, revalidates all invariants on the host, checks that no device-private identifier is present in the result, and confirms that the repository source identity did not change. If no physical iPhone is connected, it exits with code 3 and prints `PHYSICAL_DEVICE_UNAVAILABLE`.

If automatic signing needs an explicit team, set `IMAGECRAFT_IOS_DEVELOPMENT_TEAM` in the local environment. The value is passed only to `xcodebuild` and is not written to the project or result.

Successful physical output is written under the ignored `.artifacts/hdr-device/` directory. The report intentionally contains only coarse runtime facts (`physical`, `iOS`, OS version) and no UDID, serial number, ECID, hostname, or CoreDevice identifier.

## Project regeneration

The runtime gate does **not** invoke XcodeGen. `ImageCraftHDRDeviceProbe.xcodeproj` is checked in so qualification requires only Xcode/xcodebuild and CoreDevice. `project.yml` is regeneration-only source material.

The checked-in project was generated with XcodeGen 2.46.0:

```sh
cd DeviceQualification/HDRDeviceProbe
xcodegen generate --spec project.yml
```

After regeneration, review the project diff, rebuild with `--compile-only`, and do not accept a generated project that adds a signing team, absolute user path, or additional package/resource dependency.
