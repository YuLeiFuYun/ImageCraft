#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

from capture_libjpeg_progressive_suspension import ROOT

DEFAULT_PROFILE = ROOT / "Evidence/Experiments/IndependentPNG/v2/profile.json"
DEFAULT_REPORT = ROOT / ".artifacts/program/T101/independent-png-v2-report.json"
HISTORICAL_V1 = ROOT / ".artifacts/quality/independent-png-v1/formal-report-adam7.json"


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bounded_value(bound: Any) -> int:
    if not isinstance(bound, dict) or "bounded" not in bound:
        raise ValueError(f"expected bounded resource value, got {bound!r}")
    return int(bound["bounded"])


def validate(profile_path: Path, report_path: Path) -> dict[str, Any]:
    profile_path = profile_path.resolve()
    report_path = report_path.resolve()
    profile = load_json(profile_path)
    report = load_json(report_path)

    schema = int(profile.get("schemaVersion", 0))
    if schema != 2:
        raise ValueError("unexpected IndependentPNG profile schema")
    if profile.get("profileID") != "IMAGECRAFT-INDEPENDENT-PNG-CONFORMANCE-V2":
        raise ValueError("unexpected IndependentPNG profile ID")
    if int(report.get("schemaVersion", 0)) != 2:
        raise ValueError("unexpected IndependentPNG report schema")
    if report.get("evidenceVersion") != "imagecraft-independent-png-conformance-v2":
        raise ValueError("unexpected IndependentPNG evidence version")
    if report.get("status") != "source-bound-conformance":
        raise ValueError("unexpected IndependentPNG report status")
    if not report.get("formalSourceBoundExecution", False):
        raise ValueError("IndependentPNG report is not formal source-bound execution")
    if report.get("productionBackendQualified", True):
        raise ValueError("IndependentPNG evidence incorrectly claims production qualification")
    if report.get("profile", {}).get("sha256") != sha256_file(profile_path):
        raise ValueError("IndependentPNG profile hash drift")
    if report.get("profile", {}).get("profileID") != profile["profileID"]:
        raise ValueError("IndependentPNG report profile ID drift")
    if not report.get("sourceIdentity", {}).get("stableBeforeAfter", False):
        raise ValueError("IndependentPNG source identity changed during capture")

    success_profile = {str(case["id"]): case for case in profile["successCases"]}
    hostile_profile = {str(case["id"]): case for case in profile["hostileCases"]}
    success_report = {str(case["id"]): case for case in report["successCases"]}
    hostile_report = {str(case["id"]): case for case in report["hostileCases"]}
    if set(success_profile) != set(success_report):
        raise ValueError("IndependentPNG success case set drift")
    if set(hostile_profile) != set(hostile_report):
        raise ValueError("IndependentPNG hostile case set drift")
    if len(success_report) != 27 or len(hostile_report) != 24:
        raise ValueError("IndependentPNG v2 cardinality drift")
    generated = report.get("generatedCorpus", {})
    if int(generated.get("successCaseCount", -1)) != 27:
        raise ValueError("IndependentPNG manifest success count drift")
    if int(generated.get("hostileCaseCount", -1)) != 24:
        raise ValueError("IndependentPNG manifest hostile count drift")

    cicp_cases = []
    for case_id, expected in success_profile.items():
        actual = success_report[case_id]
        for key in ("width", "height", "sourceFormat", "filters", "splitIDAT"):
            if actual.get(key) != expected.get(key):
                raise ValueError(f"{case_id}: {key} drift")
        if not actual.get("sourceStraightExact", False):
            raise ValueError(f"{case_id}: straight-source bytes differ from libpng oracle")
        if not actual.get("packedPremultipliedExact", False):
            raise ValueError(f"{case_id}: packed premultiplied bytes differ from oracle")
        if actual.get("straightRGBASHA256") != actual.get("libpng", {}).get("rgbaSHA256"):
            raise ValueError(f"{case_id}: libpng straight RGBA hash drift")
        imagecraft = actual.get("imageCraft", {})
        if imagecraft.get("status") != "success":
            raise ValueError(f"{case_id}: ImageCraft probe did not succeed")
        if int(imagecraft.get("width", -1)) != int(expected["width"]):
            raise ValueError(f"{case_id}: ImageCraft width drift")
        if int(imagecraft.get("height", -1)) != int(expected["height"]):
            raise ValueError(f"{case_id}: ImageCraft height drift")
        if imagecraft.get("outputLayoutAuthority") != "codecOwnedRGBA8":
            raise ValueError(f"{case_id}: ImageCraft lost codec-owned RGBA8 authority")
        if int(imagecraft.get("packedTransferredByteCharge", -1)) != int(
            imagecraft.get("transferredByteChargeUpperBound", -2)
        ):
            raise ValueError(f"{case_id}: transfer byte charge/ledger drift")
        if int(imagecraft.get("operationByteChargeUpperBound", 0)) < int(
            imagecraft.get("packedTransferredByteCharge", 0)
        ):
            raise ValueError(f"{case_id}: operation bound below transferred payload")

        expected_encoding = str(expected.get("expectedColorEncoding", "sRGB"))
        expected_source = str(expected.get("expectedSourceColorProfile", "standardSRGB"))
        if actual.get("expectedColorEncoding", expected_encoding) != expected_encoding:
            raise ValueError(f"{case_id}: report color expectation drift")
        if actual.get("expectedSourceColorProfile", expected_source) != expected_source:
            raise ValueError(f"{case_id}: report source-profile expectation drift")
        if imagecraft.get("packedColorEncoding") != expected_encoding:
            raise ValueError(f"{case_id}: packed color encoding drift")
        if imagecraft.get("packedSourceColorProfile") != expected_source:
            raise ValueError(f"{case_id}: packed source profile drift")
        if expected_encoding == "cICP":
            expected_tuple = expected.get("cicp")
            if expected_tuple != [12, 13, 0, 1]:
                raise ValueError(f"{case_id}: unsupported cICP success tuple in profile")
            expected_report = {
                "colorPrimaries": 12,
                "transferFunction": 13,
                "matrixCoefficients": 0,
                "videoFullRangeFlag": 1,
            }
            if imagecraft.get("packedCICP") != expected_report:
                raise ValueError(f"{case_id}: packed cICP tuple drift")
            if int(imagecraft.get("packedEmbeddedICCByteCount", -1)) != 0:
                raise ValueError(f"{case_id}: cICP success retained ICC payload")
            if int(imagecraft["packedTransferredByteCharge"]) != int(imagecraft["byteCount"]):
                raise ValueError(f"{case_id}: cICP transfer contains unexplained color payload")
            cicp_cases.append(case_id)
        elif imagecraft.get("packedCICP") is not None:
            raise ValueError(f"{case_id}: non-cICP success published a cICP tuple")

    if cicp_cases != ["PNG-XB-027"]:
        raise ValueError(f"unexpected cICP success set: {cicp_cases}")

    for case_id, expected in hostile_profile.items():
        actual = hostile_report[case_id]
        if actual.get("mutation") != expected.get("mutation"):
            raise ValueError(f"{case_id}: hostile mutation drift")
        if not actual.get("failedClosed", False):
            raise ValueError(f"{case_id}: hostile input did not fail closed")
        if not isinstance(actual.get("error"), str) or not actual["error"]:
            raise ValueError(f"{case_id}: hostile failure taxonomy missing")

    h24 = hostile_report["PNG-XB-H24"]
    h25 = hostile_report["PNG-XB-H25"]
    if h24["mutation"] != "pq-cicp-color-authority" or h24["error"] != (
        "PNGIndependentRGBA8Error.unsupportedSourceSemantics"
    ):
        raise ValueError("PQ cICP hostile boundary drift")
    if h25["mutation"] != "sbit-source-precision" or h25["error"] != (
        "PNGIndependentRGBA8Error.unsupportedSourceSemantics"
    ):
        raise ValueError("sBIT hostile boundary drift")

    historical = load_json(HISTORICAL_V1)
    old_success = {str(case["id"]): case for case in historical["successCases"]}
    old_hostile = {str(case["id"]): case for case in historical["hostileCases"]}
    if len(old_success) != 26 or len(old_hostile) != 23:
        raise ValueError("historical IndependentPNG v1 cardinality drift")
    for case_id, old in old_success.items():
        new = success_report.get(case_id)
        if new is None:
            raise ValueError(f"v2 lost v1 success case {case_id}")
        for key in (
            "pngSHA256",
            "straightRGBASHA256",
            "packedRGBASHA256",
            "sourceFormat",
            "width",
            "height",
            "filters",
            "splitIDAT",
            "interlace",
            "sourceStraightExact",
            "packedPremultipliedExact",
        ):
            if new.get(key) != old.get(key):
                raise ValueError(f"v2 changed v1 success fact {case_id}: {key}")
        for key in (
            "byteCount",
            "width",
            "height",
            "operationByteChargeUpperBound",
            "outputLayoutAuthority",
            "packedColorEncoding",
            "packedEmbeddedICCByteCount",
            "packedTransferredByteCharge",
            "status",
            "transferredByteChargeUpperBound",
        ):
            if new["imageCraft"].get(key) != old["imageCraft"].get(key):
                raise ValueError(f"v2 changed v1 ImageCraft fact {case_id}: {key}")

    migrated_v1_hostile = "cicp-color-authority"
    retained_old_hostile = 0
    for old in old_hostile.values():
        if old["mutation"] == migrated_v1_hostile:
            continue
        retained_old_hostile += 1
        matches = [
            case
            for case in hostile_report.values()
            if case["mutation"] == old["mutation"]
        ]
        if len(matches) != 1:
            raise ValueError(f"v2 did not preserve v1 hostile mutation {old['mutation']}")
        new = matches[0]
        if new.get("failedClosed") != old.get("failedClosed"):
            raise ValueError(f"v2 changed v1 hostile closed-state {old['mutation']}")
        if new.get("error") != old.get("error"):
            raise ValueError(f"v2 changed v1 hostile taxonomy {old['mutation']}")
    if retained_old_hostile != 22:
        raise ValueError("unexpected retained v1 hostile cardinality")

    return {
        "successCaseCount": len(success_report),
        "hostileCaseCount": len(hostile_report),
        "cicpSuccessCases": cicp_cases,
        "pqCICPFailedClosed": h24["failedClosed"],
        "sBITFailedClosed": h25["failedClosed"],
        "historicalV1SuccessCasesPreserved": len(old_success),
        "historicalV1HostileCasesPreserved": retained_old_hostile,
        "sourceIdentitySHA256": report["sourceIdentity"]["sourceIdentitySHA256"],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()
    print(json.dumps(validate(args.profile, args.report), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
