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
HARNESS = KIT_ROOT / "Harness/ImageCodecConformanceTests.swift"
README = KIT_ROOT / "README.md"
FIXTURE_ROOT = KIT_ROOT / "Fixtures"
FIXTURE_MANIFEST = FIXTURE_ROOT / "manifest.json"
OBSERVATION_SCHEMA = KIT_ROOT / "observation-schema.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/conformance/image-codec-v1/report.json"
DEFAULT_WORK = ROOT / ".artifacts/conformance/image-codec-v1/work"
KIT_ID = "IMAGECRAFT-IMAGE-CODEC-CONFORMANCE-V1"
FIXTURE_SET_ID = "IMAGECRAFT-IMAGE-CODEC-FIXTURES-V1"
EXPECTED_OBLIGATION_IDS = [f"IMAGECRAFT-ICT-{index:03d}" for index in range(1, 10)]


def normalized_identity(value: str) -> str:
    return value.lower().replace("_", "-")


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def package_manifest(
    codec_path: Path,
    codec_package_name: str,
    codec_product: str,
    contract: dict[str, str],
) -> str:
    dependencies = [
        f'.package(name: {swift_string("ImageCraft")}, path: {swift_string(str(ROOT))})'
    ]
    if codec_path != ROOT:
        dependencies.append(
            f'.package(name: {swift_string(codec_package_name)}, path: {swift_string(str(codec_path))})'
        )
    dependencies_text = ",\n        ".join(dependencies)
    return f'''// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ImageCodecConformanceRun",
    platforms: [.macOS(.v12)],
    dependencies: [
        {dependencies_text},
    ],
    targets: [
        .testTarget(
            name: "ImageCodecConformanceTests",
            dependencies: [
                .product(
                    name: {swift_string(contract["product"])},
                    package: {swift_string(contract["packageIdentity"])}
                ),
                .product(
                    name: {swift_string(codec_product)},
                    package: {swift_string(codec_package_name)}
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
    if document.get("schemaVersion") != 1:
        raise ValueError("fixture manifest schemaVersion must be 1")
    if document.get("fixtureSetID") != FIXTURE_SET_ID:
        raise ValueError("unexpected fixtureSetID")
    fixtures = document.get("fixtures")
    if not isinstance(fixtures, list) or len(fixtures) != 6:
        raise ValueError(
            "fixture manifest must contain exactly png/jpeg/gif/webp/heif/avif references"
        )
    expected_formats = {"png", "jpeg", "gif", "webp", "heif", "avif"}
    observed_formats: set[str] = set()
    for item in fixtures:
        if not isinstance(item, dict):
            raise ValueError("fixture entry must be an object")
        format_name = item.get("format")
        file_name = item.get("file")
        expected_digest = item.get("sha256")
        if format_name not in expected_formats or format_name in observed_formats:
            raise ValueError(f"invalid or duplicate fixture format: {format_name}")
        if not isinstance(file_name, str) or not file_name:
            raise ValueError(f"{format_name}: fixture file is missing")
        if not isinstance(expected_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_digest):
            raise ValueError(f"{format_name}: fixture digest is invalid")
        if item.get("width") != 2 or item.get("height") != 2:
            raise ValueError(f"{format_name}: v1 fixture geometry must remain 2x2")
        fixture = FIXTURE_ROOT / file_name
        if not fixture.is_file() or digest(fixture) != expected_digest:
            raise ValueError(f"{format_name}: fixture bytes drifted from manifest")
        observed_formats.add(format_name)
    if observed_formats != expected_formats:
        raise ValueError(f"fixture formats drifted: {sorted(observed_formats)}")
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
    if properties.get("releaseQualified", {}).get("const") is not False:
        raise ValueError("observation schema must fail closed on release qualification")
    for field in (
        "manifestSha256",
        "fixtureManifestSha256",
        "observationSchemaSha256",
        "harnessSha256",
        "factorySha256",
        "codecSourceSha256",
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
    if document.get("schemaVersion") != 1:
        raise ValueError("manifest schemaVersion must be 1")
    if document.get("kitID") != KIT_ID:
        raise ValueError("unexpected kitID")
    if document.get("contractVersion") != 1:
        raise ValueError("unexpected contractVersion")
    obligations = document.get("obligations")
    if not isinstance(obligations, list) or not obligations:
        raise ValueError("manifest obligations are required")
    actual_ids = [item.get("id") if isinstance(item, dict) else None for item in obligations]
    if actual_ids != EXPECTED_OBLIGATION_IDS:
        raise ValueError(f"obligation sequence drifted: {actual_ids}")
    capability_summary = str(obligations[1].get("summary", "")).replace(",", "")
    if "6144" not in capability_summary:
        raise ValueError("finite capability count drifted in manifest summary")
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
    if not isinstance(contract, dict):
        raise ValueError("ImageCraft contract dependency is required")
    expected_contract = {
        "packageIdentity": "ImageCraft",
        "product": "ImageCraftCore",
        "binding": "current-source-tree",
    }
    if contract != expected_contract:
        raise ValueError("ImageCraft contract must bind the current source tree")
    fixtures = document.get("fixtures")
    if not isinstance(fixtures, dict) or fixtures.get("manifest") != "Fixtures/manifest.json":
        raise ValueError("fixture manifest path drifted")
    if fixtures.get("fixtureSetID") != FIXTURE_SET_ID:
        raise ValueError("fixture set identity drifted")
    if document.get("observationSchema") != "observation-schema.json":
        raise ValueError("observation schema path drifted")
    rules = document.get("rules")
    required_rules = {
        "componentEvidenceDoesNotReplaceHostCompositionEvidence": True,
        "referenceFixturesDoNotProveHostileCorpusSafety": True,
        "releaseQualified": False,
        "unsupportedOrSkippedFailsClosed": True,
    }
    if not isinstance(rules, dict) or any(
        rules.get(key) is not value for key, value in required_rules.items()
    ):
        raise ValueError("manifest fail-closed rules drifted")
    readme_source = README.read_text()
    if "5,120" not in readme_source:
        raise ValueError("finite capability count drifted in README")
    return document


def validate_report(document: dict[str, object], schema: dict[str, object]) -> None:
    required = schema["required"]
    missing = [field for field in required if field not in document]
    if missing:
        raise ValueError(f"generated observation is missing required fields: {missing}")
    if document.get("schemaVersion") != 1 or document.get("kitID") != KIT_ID:
        raise ValueError("generated observation identity drifted")
    if document.get("expectedTestCount") != 9:
        raise ValueError("generated observation expectedTestCount drifted")
    if document.get("releaseQualified") is not False:
        raise ValueError("generated observation must remain non-release-qualified")
    for field in (
        "manifestSha256",
        "fixtureManifestSha256",
        "observationSchemaSha256",
        "harnessSha256",
        "factorySha256",
        "codecSourceSha256",
    ):
        value = document.get(field)
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
            raise ValueError(f"generated observation has invalid SHA-256 field: {field}")
    source_identity_sha256 = document.get("imageCraftSourceIdentitySHA256")
    if not isinstance(source_identity_sha256, str) or not re.fullmatch(
        r"[0-9a-f]{64}", source_identity_sha256
    ):
        raise ValueError("generated observation has invalid ImageCraft source identity")
    if document.get("imageCraftSourceIdentityID") != "IMAGECRAFT-SOURCE-IDENTITY-V2":
        raise ValueError("generated observation has unexpected ImageCraft source identity ID")
    if not isinstance(document.get("imageCraftSourceIdentityFileCount"), int):
        raise ValueError("generated observation has invalid ImageCraft source identity file count")


def validate_codec_package(codec_path: Path, codec_package_name: str) -> None:
    if not (codec_path / "Package.swift").is_file():
        raise ValueError("codec package path is invalid")
    same_identity = normalized_identity(codec_package_name) == normalized_identity("ImageCraft")
    if codec_path == ROOT and not same_identity:
        raise ValueError("current ImageCraft source tree must use package identity ImageCraft")
    if codec_path != ROOT and same_identity:
        raise ValueError(
            "an external package cannot reuse ImageCraft package identity; run the kit from that checkout instead"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="Run ImageCraft ImageCodec conformance v1.")
    parser.add_argument("--codec-package-path", required=True)
    parser.add_argument(
        "--codec-package-name",
        help="SwiftPM package identity; defaults to the codec package path basename",
    )
    parser.add_argument("--codec-product", required=True)
    parser.add_argument("--factory-source", required=True)
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    parser.add_argument("--work-directory", default=str(DEFAULT_WORK))
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()

    output_path = Path(args.output).resolve()
    work = Path(args.work_directory).resolve()
    codec_path = Path(args.codec_package_path).resolve()
    codec_package_name = args.codec_package_name or codec_path.name
    factory = Path(args.factory_source).resolve()
    log_path = output_path.with_suffix(".log")

    try:
        manifest = validate_manifest(json.loads(MANIFEST.read_text()))
        fixture_manifest = validate_fixture_manifest(json.loads(FIXTURE_MANIFEST.read_text()))
        observation_schema = validate_observation_schema(json.loads(OBSERVATION_SCHEMA.read_text()))
        contract = manifest["componentDependencies"]["imageCraftContract"]
        validate_codec_package(codec_path, codec_package_name)
        if not factory.is_file() or "CodecUnderTest" not in factory.read_text():
            raise ValueError("factory source must define CodecUnderTest")
        if args.timeout <= 0 or args.timeout > 3_600:
            raise ValueError("timeout must be in 1...3600 seconds")

        env = os.environ.copy()
        env["DEVELOPER_DIR"] = command_output(
            [str(ROOT / "scripts/select-xcode.sh")], ROOT, env
        )
        identity_sha256, identity_file_count, identity_id = source_identity(ROOT, env)

        shutil.rmtree(work, ignore_errors=True)
        tests = work / "Tests/ImageCodecConformanceTests"
        tests.mkdir(parents=True)
        (work / "Package.swift").write_text(
            package_manifest(codec_path, codec_package_name, args.codec_product, contract)
        )
        shutil.copy2(HARNESS, tests / HARNESS.name)
        shutil.copy2(factory, tests / "CodecUnderTest.swift")
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
                "Test Case '-[ImageCodecConformanceTests.ImageCodecConformanceTests "
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
            "contractVersion": manifest["contractVersion"],
            "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "status": "passed" if passed else "failed",
            "returnCode": return_code,
            "timedOut": timed_out,
            "elapsedSeconds": round(elapsed, 3),
            "executedTestCount": executed_test_count,
            "expectedTestCount": len(unique_test_names),
            "failureCount": failure_count,
            "codecPackageName": codec_package_name,
            "codecProduct": args.codec_product,
            "manifestSha256": digest(MANIFEST),
            "fixtureManifestSha256": digest(FIXTURE_MANIFEST),
            "observationSchemaSha256": digest(OBSERVATION_SCHEMA),
            "harnessSha256": digest(HARNESS),
            "factorySha256": digest(factory),
            "codecSourceSha256": source_digest(codec_path),
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
            "ImageCraft ImageCodec conformance: "
            f"status={report['status']} obligations={sum(observed.values())}/{len(observed)} "
            f"elapsed={elapsed:.1f}s report={display_path(output_path)}"
        )
        if not passed:
            print("\n".join(test_output.splitlines()[-160:]), file=sys.stderr)
        return 0 if passed else 1
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"ImageCraft ImageCodec conformance failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
