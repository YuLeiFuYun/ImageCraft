#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

CONFORMANCE_ROOT = Path(__file__).resolve().parents[2]
if str(CONFORMANCE_ROOT) not in sys.path:
    sys.path.insert(0, str(CONFORMANCE_ROOT))

from _support import (
    command_output,
    digest,
    run_swift_tests,
    source_digest,
    source_identity,
    swift_string,
    xctest_summary,
)

KIT_ROOT = Path(__file__).resolve().parent
ROOT = KIT_ROOT.parents[2]
MANIFEST = KIT_ROOT / "manifest.json"
HARNESS = KIT_ROOT / "Harness/ImagePackedRGB8ConformanceTests.swift"
README = KIT_ROOT / "README.md"
FIXTURE_ROOT = KIT_ROOT / "Fixtures"
FIXTURE_MANIFEST = FIXTURE_ROOT / "manifest.json"
OBSERVATION_SCHEMA = KIT_ROOT / "observation-schema.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/conformance/image-packed-rgb8-v1/report.json"
DEFAULT_WORK = ROOT / ".artifacts/conformance/image-packed-rgb8-v1/work"
KIT_ID = "IMAGECRAFT-PACKED-RGB8-CONFORMANCE-V1"
PROFILE_ID = "IMAGECRAFT-BOUNDED-BASELINE-JPEG-PACKED-RGB8-V1"
FIXTURE_SET_ID = "IMAGECRAFT-PACKED-RGB8-FIXTURES-V1"
EXPECTED_OBLIGATION_IDS = [f"IMAGECRAFT-PACKED-RGB8-CT-{index:03d}" for index in range(1, 7)]


def normalized_identity(value: str) -> str:
    return value.lower().replace("_", "-")


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def package_manifest(
    backend_path: Path,
    backend_package_name: str,
    backend_product: str,
    contract: dict[str, str],
) -> str:
    dependencies = [
        f'.package(name: "ImageCraft", path: {swift_string(str(ROOT))})'
    ]
    if backend_path != ROOT:
        dependencies.append(
            f'.package(name: {swift_string(backend_package_name)}, path: {swift_string(str(backend_path))})'
        )
    dependencies_text = ",\n        ".join(dependencies)
    return f'''// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ImagePackedRGB8ConformanceRun",
    platforms: [.macOS(.v12)],
    dependencies: [
        {dependencies_text},
    ],
    targets: [
        .testTarget(
            name: "ImagePackedRGB8ConformanceTests",
            dependencies: [
                .product(
                    name: {swift_string(contract["product"])},
                    package: {swift_string(contract["packageIdentity"])}
                ),
                .product(
                    name: {swift_string(backend_product)},
                    package: {swift_string(backend_package_name)}
                ),
            ],
            resources: [.copy("Fixtures")]
        )
    ]
)
'''


def validate_fixture_manifest(document: object) -> dict[str, object]:
    if not isinstance(document, dict):
        raise ValueError("fixture manifest must be an object")
    if document.get("schemaVersion") != 1 or document.get("fixtureSetID") != FIXTURE_SET_ID:
        raise ValueError("fixture manifest identity drifted")
    fixtures = document.get("fixtures")
    if not isinstance(fixtures, list) or len(fixtures) != 4:
        raise ValueError("v1 requires exactly four fixed baseline JFIF fixtures")
    expected = [
        {
            "id": "baseline-jfif-grayscale-19x11",
            "sampling": "grayscale",
            "file": "reference-baseline-jfif-grayscale-19x11.jpg",
            "expectedRGB8File": "reference-baseline-jfif-grayscale-19x11.rgb",
            "format": "jpeg",
            "width": 19,
            "height": 11,
            "sourceByteCount": 543,
            "expectedRGB8ByteCount": 627,
            "exactOperationByteCharge": 836,
            "sha256": "f9f74e388a7dcd740c878c895a3e00b917f8739f3d86f71798742dfe9176f0c7",
            "expectedRGB8SHA256": "466b5f63a65b4311ce2dfa93e660e4d4a5a71cebfc835388d2006c3489172949",
            "oracle": "libjpeg-turbo djpeg 3.2.0, RGB PPM payload",
        },
        {
            "id": "baseline-jfif-444-23x13",
            "sampling": "4:4:4",
            "file": "reference-baseline-jfif-444-23x13.jpg",
            "expectedRGB8File": "reference-baseline-jfif-444-23x13.rgb",
            "format": "jpeg",
            "width": 23,
            "height": 13,
            "sourceByteCount": 613,
            "expectedRGB8ByteCount": 897,
            "exactOperationByteCharge": 1601,
            "sha256": "ccdb8b4b5058c8529bd570f7267f0dcfa038f3556ba6156241f37a9865490719",
            "expectedRGB8SHA256": "f3b0edfdac3b5eedc3b5f27e79644baf3c449ed3968720429fb34ea0df899a14",
            "oracle": "libjpeg-turbo djpeg 3.2.0, RGB PPM payload",
        },
        {
            "id": "baseline-jfif-422-23x13",
            "sampling": "4:2:2",
            "file": "reference-baseline-jfif-422-23x13.jpg",
            "expectedRGB8File": "reference-baseline-jfif-422-23x13.rgb",
            "format": "jpeg",
            "width": 23,
            "height": 13,
            "sourceByteCount": 552,
            "expectedRGB8ByteCount": 897,
            "exactOperationByteCharge": 3073,
            "sha256": "6e0901315f1ea40df35139af4df40a456a6a9bb6a0423a7d92fe190c92b19e3f",
            "expectedRGB8SHA256": "56608f195b45873b2157f4dc6505798ab4c080dd297a35f5b0214151ab54ee1e",
            "oracle": "libjpeg-turbo djpeg 3.2.0, RGB PPM payload",
        },
        {
            "id": "baseline-jfif-420-23x13",
            "sampling": "4:2:0",
            "file": "reference-baseline-jfif-420-23x13.jpg",
            "expectedRGB8File": "reference-baseline-jfif-420-23x13.rgb",
            "format": "jpeg",
            "width": 23,
            "height": 13,
            "sourceByteCount": 856,
            "expectedRGB8ByteCount": 897,
            "exactOperationByteCharge": 3777,
            "sha256": "218392f142ad2f1bcf5280ecc1f82ded3152ecfa65fdcde23a6ff2c07f405585",
            "expectedRGB8SHA256": "c7807abef8ee1d20dcdaa4953e0767518aab1485578dca5a9ae7c0bb3d146861",
            "oracle": "libjpeg-turbo djpeg 3.2.0 (build 20260630), RGB PPM payload",
        },
    ]
    if fixtures != expected:
        raise ValueError("fixed packed-RGB8 fixture matrix metadata drifted")
    for item in expected:
        fixture = FIXTURE_ROOT / item["file"]
        if not fixture.is_file() or fixture.stat().st_size != item["sourceByteCount"] or digest(fixture) != item["sha256"]:
            raise ValueError(f"fixed packed-RGB8 JPEG fixture bytes drifted: {item['id']}")
        expected_rgb = FIXTURE_ROOT / item["expectedRGB8File"]
        if (
            not expected_rgb.is_file()
            or expected_rgb.stat().st_size != item["expectedRGB8ByteCount"]
            or digest(expected_rgb) != item["expectedRGB8SHA256"]
        ):
            raise ValueError(f"fixed packed-RGB8 oracle bytes drifted: {item['id']}")
    return document


def validate_observation_schema(document: object) -> dict[str, object]:
    if not isinstance(document, dict):
        raise ValueError("observation schema must be an object")
    properties = document.get("properties")
    required = document.get("required")
    if not isinstance(properties, dict) or not isinstance(required, list):
        raise ValueError("observation schema must define properties and required fields")
    if document.get("$id") != "https://imagecraft.invalid/conformance/image-packed-rgb8/v1/observation-schema.json":
        raise ValueError("observation schema $id drifted")
    if properties.get("schemaVersion", {}).get("const") != 1:
        raise ValueError("observation schema version drifted")
    if properties.get("kitID", {}).get("const") != KIT_ID:
        raise ValueError("observation schema kitID drifted")
    if properties.get("profileID", {}).get("const") != PROFILE_ID:
        raise ValueError("observation schema profileID drifted")
    if properties.get("expectedTestCount", {}).get("const") != 6:
        raise ValueError("observation schema test count drifted")
    if properties.get("releaseQualified", {}).get("const") is not False:
        raise ValueError("observation schema must remain non-release-qualified")
    obligations_schema = properties.get("obligations")
    items_schema = obligations_schema.get("items") if isinstance(obligations_schema, dict) else None
    item_properties = items_schema.get("properties") if isinstance(items_schema, dict) else None
    expected_obligation_pattern = r"^IMAGECRAFT-PACKED-RGB8-CT-00[1-6]$"
    if not isinstance(item_properties, dict) or item_properties.get("id", {}).get("pattern") != expected_obligation_pattern:
        raise ValueError("observation schema obligation ID pattern drifted")
    for field in (
        "manifestSha256",
        "fixtureManifestSha256",
        "observationSchemaSha256",
        "harnessSha256",
        "factorySha256",
        "backendSourceSha256",
        "imageCraftSourceIdentitySHA256",
        "imageCraftSourceIdentityFileCount",
        "imageCraftSourceIdentityID",
        "obligations",
    ):
        if field not in required:
            raise ValueError(f"observation schema missing required field: {field}")
    return document


def validate_manifest(document: object) -> dict[str, object]:
    if not isinstance(document, dict):
        raise ValueError("manifest must be an object")
    if document.get("schemaVersion") != 1 or document.get("kitID") != KIT_ID:
        raise ValueError("manifest identity drifted")
    if document.get("contractVersion") != 1 or document.get("profileID") != PROFILE_ID:
        raise ValueError("manifest contract/profile drifted")
    obligations = document.get("obligations")
    if not isinstance(obligations, list) or not obligations:
        raise ValueError("manifest obligations are required")
    actual_ids = [item.get("id") if isinstance(item, dict) else None for item in obligations]
    if actual_ids != EXPECTED_OBLIGATION_IDS:
        raise ValueError(f"obligation sequence drifted: {actual_ids}")
    harness_source = HARNESS.read_text()
    for item in obligations:
        if not isinstance(item, dict):
            raise ValueError("obligation must be an object")
        if not isinstance(item.get("summary"), str) or len(item["summary"].strip()) < 24:
            raise ValueError(f"{item.get('id')}: summary is missing")
        if not isinstance(item.get("testName"), str) or item["testName"] not in harness_source:
            raise ValueError(f"{item.get('id')}: testName is missing from harness")
    dependencies = document.get("componentDependencies")
    contract = dependencies.get("imageCraftContract") if isinstance(dependencies, dict) else None
    expected_contract = {
        "packageIdentity": "ImageCraft",
        "product": "ImageCraftCore",
        "binding": "current-source-tree",
    }
    if contract != expected_contract:
        raise ValueError("ImageCraft contract must bind the current source tree")
    factory = document.get("factoryContract")
    if not isinstance(factory, dict) or factory.get("symbol") != "PackedDecoderUnderTest":
        raise ValueError("packed decoder factory symbol drifted")
    if factory.get("method") != (
        "make(maximumOperationByteCharge: Int) throws -> any ImagePackedRGB8Decoding"
    ):
        raise ValueError("packed decoder factory method drifted")
    fixtures = document.get("fixtures")
    if not isinstance(fixtures, dict) or fixtures.get("manifest") != "Fixtures/manifest.json":
        raise ValueError("fixture manifest path drifted")
    if fixtures.get("fixtureSetID") != FIXTURE_SET_ID:
        raise ValueError("fixture set identity drifted")
    rules = document.get("rules")
    expected_rules = {
        "profileRequiresBoundedResourceAuthority": True,
        "encodedSourceRemainsCallerOwned": True,
        "referenceFixtureSetDoesNotProveGeneralJPEGSupport": True,
        "releaseQualified": False,
        "unsupportedOrSkippedFailsClosed": True,
    }
    if not isinstance(rules, dict) or any(rules.get(k) is not v for k, v in expected_rules.items()):
        raise ValueError("manifest fail-closed rules drifted")
    if "caller-owned encoded-source coexistence" not in README.read_text():
        raise ValueError("README must preserve caller-owned encoded-source boundary")
    return document


def validate_backend_package(backend_path: Path, backend_package_name: str) -> None:
    if not (backend_path / "Package.swift").is_file():
        raise ValueError("backend package path is invalid")
    same_identity = normalized_identity(backend_package_name) == normalized_identity("ImageCraft")
    if backend_path == ROOT and not same_identity:
        raise ValueError("current ImageCraft source tree must use package identity ImageCraft")
    if backend_path != ROOT and same_identity:
        raise ValueError("an external backend package cannot reuse ImageCraft package identity")


def validate_report(document: dict[str, object], schema: dict[str, object]) -> None:
    required = schema["required"]
    missing = [field for field in required if field not in document]
    if missing:
        raise ValueError(f"generated observation is missing required fields: {missing}")
    if document.get("schemaVersion") != 1 or document.get("kitID") != KIT_ID:
        raise ValueError("generated observation identity drifted")
    if document.get("profileID") != PROFILE_ID or document.get("expectedTestCount") != 6:
        raise ValueError("generated observation profile/test count drifted")
    if document.get("releaseQualified") is not False:
        raise ValueError("generated observation must remain non-release-qualified")
    for field in (
        "manifestSha256",
        "fixtureManifestSha256",
        "observationSchemaSha256",
        "harnessSha256",
        "factorySha256",
        "backendSourceSha256",
        "imageCraftSourceIdentitySHA256",
    ):
        value = document.get(field)
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
            raise ValueError(f"generated observation has invalid SHA-256 field: {field}")
    if document.get("imageCraftSourceIdentityID") != "IMAGECRAFT-SOURCE-IDENTITY-V2":
        raise ValueError("generated observation has unexpected ImageCraft source identity ID")
    if not isinstance(document.get("imageCraftSourceIdentityFileCount"), int):
        raise ValueError("generated observation has invalid ImageCraft source identity file count")
    obligations = document.get("obligations")
    if not isinstance(obligations, list):
        raise ValueError("generated observation obligations are invalid")
    actual_ids = [item.get("id") if isinstance(item, dict) else None for item in obligations]
    if actual_ids != EXPECTED_OBLIGATION_IDS:
        raise ValueError(f"generated observation obligation IDs drifted: {actual_ids}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run ImageCraft bounded baseline-JPEG ImagePackedRGB8 conformance v1.")
    parser.add_argument("--backend-package-path", required=True)
    parser.add_argument(
        "--backend-package-name",
        help="SwiftPM package identity; defaults to the backend package path basename",
    )
    parser.add_argument("--backend-product", required=True)
    parser.add_argument("--factory-source", required=True)
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    parser.add_argument("--work-directory", default=str(DEFAULT_WORK))
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()

    output_path = Path(args.output).resolve()
    work = Path(args.work_directory).resolve()
    backend_path = Path(args.backend_package_path).resolve()
    backend_package_name = args.backend_package_name or backend_path.name
    factory = Path(args.factory_source).resolve()
    log_path = output_path.with_suffix(".log")

    try:
        manifest = validate_manifest(json.loads(MANIFEST.read_text()))
        fixture_manifest = validate_fixture_manifest(json.loads(FIXTURE_MANIFEST.read_text()))
        observation_schema = validate_observation_schema(json.loads(OBSERVATION_SCHEMA.read_text()))
        contract = manifest["componentDependencies"]["imageCraftContract"]
        validate_backend_package(backend_path, backend_package_name)
        if not factory.is_file() or "PackedDecoderUnderTest" not in factory.read_text():
            raise ValueError("factory source must define PackedDecoderUnderTest")
        if args.timeout <= 0 or args.timeout > 3_600:
            raise ValueError("timeout must be in 1...3600 seconds")

        env = os.environ.copy()
        env["DEVELOPER_DIR"] = command_output([str(ROOT / "scripts/select-xcode.sh")], ROOT, env)
        identity_sha256, identity_file_count, identity_id = source_identity(ROOT, env)

        shutil.rmtree(work, ignore_errors=True)
        tests = work / "Tests/ImagePackedRGB8ConformanceTests"
        tests.mkdir(parents=True)
        (work / "Package.swift").write_text(
            package_manifest(backend_path, backend_package_name, args.backend_product, contract)
        )
        shutil.copy2(HARNESS, tests / HARNESS.name)
        shutil.copy2(factory, tests / "PackedDecoderUnderTest.swift")
        shutil.copytree(FIXTURE_ROOT, tests / "Fixtures")

        return_code, test_output, elapsed, timed_out = run_swift_tests(
            ["xcrun", "swift", "test", "--package-path", str(work)],
            ROOT,
            env,
            args.timeout,
        )
        output_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text(test_output)

        identity_after_sha256, identity_after_file_count, identity_after_id = source_identity(ROOT, env)
        if (
            identity_after_sha256 != identity_sha256
            or identity_after_file_count != identity_file_count
            or identity_after_id != identity_id
        ):
            raise ValueError("ImageCraft source identity changed during conformance run")

        obligations = manifest["obligations"]
        observed = {
            item["id"]: (
                "Test Case '-[ImagePackedRGB8ConformanceTests.ImagePackedRGB8ConformanceTests "
                f"{item['testName']}]'"
            ) in test_output
            for item in obligations
        }
        unique_test_names = {item["testName"] for item in obligations}
        executed_test_count, failure_count = xctest_summary(test_output)
        skipped = " test skipped" in test_output or " tests skipped" in test_output
        passed = (
            return_code == 0
            and all(observed.values())
            and executed_test_count == len(unique_test_names)
            and failure_count == 0
            and not skipped
        )
        report: dict[str, object] = {
            "schemaVersion": 1,
            "kitID": manifest["kitID"],
            "profileID": manifest["profileID"],
            "contractVersion": manifest["contractVersion"],
            "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "status": "passed" if passed else "failed",
            "returnCode": return_code,
            "timedOut": timed_out,
            "elapsedSeconds": round(elapsed, 3),
            "executedTestCount": executed_test_count,
            "expectedTestCount": len(unique_test_names),
            "failureCount": failure_count,
            "backendPackageName": backend_package_name,
            "backendProduct": args.backend_product,
            "manifestSha256": digest(MANIFEST),
            "fixtureManifestSha256": digest(FIXTURE_MANIFEST),
            "observationSchemaSha256": digest(OBSERVATION_SCHEMA),
            "harnessSha256": digest(HARNESS),
            "factorySha256": digest(factory),
            "backendSourceSha256": source_digest(backend_path),
            "imageCraftSourceIdentitySHA256": identity_sha256,
            "imageCraftSourceIdentityFileCount": identity_file_count,
            "imageCraftSourceIdentityID": identity_id,
            "componentDependencies": manifest["componentDependencies"],
            "fixtureSetID": fixture_manifest["fixtureSetID"],
            "swiftVersion": command_output(["xcrun", "swift", "--version"], ROOT, env),
            "xcodeVersion": command_output(["xcodebuild", "-version"], ROOT, env),
            "log": display_path(log_path),
            "logSha256": digest(log_path),
            "obligations": [
                {
                    "id": item["id"],
                    "testName": item["testName"],
                    "observed": observed[item["id"]],
                }
                for item in obligations
            ],
            "skippedTestsObserved": skipped,
            "releaseQualified": False,
        }
        validate_report(report, observation_schema)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "ImageCraft ImagePackedRGB8 conformance: "
            f"status={report['status']} obligations={sum(observed.values())}/{len(observed)} "
            f"elapsed={elapsed:.1f}s report={display_path(output_path)}"
        )
        if not passed:
            print("\n".join(test_output.splitlines()[-160:]), file=sys.stderr)
        return 0 if passed else 1
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"ImageCraft ImagePackedRGB8 conformance failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
