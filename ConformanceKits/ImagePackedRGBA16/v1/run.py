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
HARNESS = KIT_ROOT / "Harness/ImagePackedRGBA16ConformanceTests.swift"
README = KIT_ROOT / "README.md"
FIXTURE_ROOT = KIT_ROOT / "Fixtures"
FIXTURE_MANIFEST = FIXTURE_ROOT / "manifest.json"
OBSERVATION_SCHEMA = KIT_ROOT / "observation-schema.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/conformance/image-packed-rgba16-v1/report.json"
DEFAULT_WORK = ROOT / ".artifacts/conformance/image-packed-rgba16-v1/work"
KIT_ID = "IMAGECRAFT-PACKED-RGBA16-CONFORMANCE-V1"
PROFILE_ID = "IMAGECRAFT-BOUNDED-PNG-PACKED-RGBA16-V1"
FIXTURE_SET_ID = "IMAGECRAFT-PACKED-RGBA16-FIXTURES-V1"
EXPECTED_OBLIGATION_IDS = [f"IMAGECRAFT-PACKED16-CT-{index:03d}" for index in range(1, 9)]


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
    name: "ImagePackedRGBA16ConformanceRun",
    platforms: [.macOS(.v12)],
    dependencies: [
        {dependencies_text},
    ],
    targets: [
        .testTarget(
            name: "ImagePackedRGBA16ConformanceTests",
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
    expected = [
        {
            "id": "srgb-rgba16-2x1",
            "file": "reference-srgb-rgba16-2x1.png",
            "format": "png",
            "width": 2,
            "height": 1,
            "sha256": "17a31fd97401e4f3de40d2ad77232e9642a672645aec267855256e21e23274d2",
            "expectedRGBA16LEHex": "34127856bc9af0deffff010000803412",
        },
        {
            "id": "hostile-untagged-rgba16-2x1",
            "file": "hostile-untagged-rgba16-2x1.png",
            "format": "png",
            "width": 2,
            "height": 1,
            "sha256": "207f96a9a83d33bd5916d86476dd7f2caf335d234e9107e0bebfc1bf3caf9f09",
            "expectedDisposition": "unsupported-source-semantics",
        },
        {
            "id": "hostile-sbit-rgba16-2x1",
            "file": "hostile-sbit-rgba16-2x1.png",
            "format": "png",
            "width": 2,
            "height": 1,
            "sha256": "9c7c8c4ad1b5f3a0f3152ef00c61b8e34911f232b8ad3e0d559c2c20a44abd98",
            "expectedDisposition": "unsupported-source-semantics",
        },
    ]
    if fixtures != expected:
        raise ValueError("fixed packed-RGBA16 fixture metadata drifted")
    for item in expected:
        fixture = FIXTURE_ROOT / item["file"]
        if not fixture.is_file() or digest(fixture) != item["sha256"]:
            raise ValueError(f"fixed packed-RGBA16 fixture bytes drifted: {item['file']}")
    return document


def validate_observation_schema(document: object) -> dict[str, object]:
    if not isinstance(document, dict):
        raise ValueError("observation schema must be an object")
    properties = document.get("properties")
    required = document.get("required")
    if not isinstance(properties, dict) or not isinstance(required, list):
        raise ValueError("observation schema must define properties and required fields")
    if properties.get("schemaVersion", {}).get("const") != 1:
        raise ValueError("observation schema version drifted")
    if properties.get("kitID", {}).get("const") != KIT_ID:
        raise ValueError("observation schema kitID drifted")
    if properties.get("profileID", {}).get("const") != PROFILE_ID:
        raise ValueError("observation schema profileID drifted")
    if properties.get("expectedTestCount", {}).get("const") != 8:
        raise ValueError("observation schema test count drifted")
    if properties.get("releaseQualified", {}).get("const") is not False:
        raise ValueError("observation schema must remain non-release-qualified")
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
        "make(maximumOperationByteCharge: Int) throws -> any ImagePackedRGBA16Decoding"
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
        "referenceFixtureDoesNotProveBroadPNGSupport": True,
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
    if document.get("profileID") != PROFILE_ID or document.get("expectedTestCount") != 8:
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


def main() -> int:
    parser = argparse.ArgumentParser(description="Run ImageCraft bounded ImagePackedRGBA16 conformance v1.")
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
        tests = work / "Tests/ImagePackedRGBA16ConformanceTests"
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

        obligations = manifest["obligations"]
        observed = {
            item["id"]: (
                "Test Case '-[ImagePackedRGBA16ConformanceTests.ImagePackedRGBA16ConformanceTests "
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
            "ImageCraft ImagePackedRGBA16 conformance: "
            f"status={report['status']} obligations={sum(observed.values())}/{len(observed)} "
            f"elapsed={elapsed:.1f}s report={display_path(output_path)}"
        )
        if not passed:
            print("\n".join(test_output.splitlines()[-160:]), file=sys.stderr)
        return 0 if passed else 1
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"ImageCraft ImagePackedRGBA16 conformance failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
