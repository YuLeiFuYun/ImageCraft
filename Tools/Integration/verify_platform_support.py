#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def normalized_platforms(values: list[dict], version_key: str) -> list[dict]:
    return sorted(
        [
            {
                "name": value["name"],
                "minimumVersion": value[version_key],
            }
            for value in values
        ],
        key=lambda value: value["name"],
    )


def product_map(description: dict) -> dict[str, dict]:
    return {product["name"]: product for product in description["products"]}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def verify_root(contract: dict, description: dict) -> None:
    require(description["name"] == contract["packageName"], "package name drift")
    require(
        description["tools_version"] == contract["swiftToolsVersion"],
        "Swift tools version drift",
    )
    require(
        normalized_platforms(description["platforms"], "version")
        == normalized_platforms(contract["supportedPlatforms"], "minimumVersion"),
        "supported platform drift",
    )
    if contract["rootDependenciesMustBeEmpty"]:
        require(description["dependencies"] == [], "root package gained a dependency")

    products = product_map(description)
    expected_names = {
        value["name"] for value in contract["publicLibraryProducts"]
    } | {value["name"] for value in contract["evidenceProducts"]}
    require(set(products) == expected_names, "root product set drift")

    for expected in contract["publicLibraryProducts"]:
        actual = products[expected["name"]]
        require("library" in actual["type"], f"{expected['name']} is no longer a library")
        require(actual["targets"] == expected["targets"], f"{expected['name']} target drift")

    for expected in contract["evidenceProducts"]:
        actual = products[expected["name"]]
        require(expected["type"] in actual["type"], f"{expected['name']} type drift")
        require(actual["targets"] == expected["targets"], f"{expected['name']} target drift")


def verify_consumer(contract: dict, description: dict) -> None:
    fixture = contract["consumerFixture"]
    require(description["name"] == fixture["name"], "consumer fixture name drift")
    require(
        description["tools_version"] == contract["swiftToolsVersion"],
        "consumer Swift tools version drift",
    )
    require(
        normalized_platforms(description["platforms"], "version")
        == normalized_platforms(fixture["platforms"], "minimumVersion"),
        "consumer fixture platform drift",
    )
    require(len(description["dependencies"]) == 1, "consumer fixture dependency drift")
    dependency = description["dependencies"][0]
    require(dependency["identity"] == contract["packageName"].lower(), "consumer dependency identity drift")
    require(dependency["type"] == "fileSystem", "consumer fixture must use a local package dependency")
    target = next(
        value for value in description["targets"] if value["name"] == fixture["name"]
    )
    require(
        sorted(target["product_dependencies"])
        == sorted(fixture["requiredProducts"]),
        "consumer fixture product dependency drift",
    )


def verify_gate_files(contract: dict, root: Path) -> None:
    paths = [contract["releaseEntrypoint"], *contract["releaseGates"]]
    for relative in paths:
        path = root / relative
        require(path.is_file(), f"missing release gate: {relative}")
        require(path.stat().st_mode & 0o111 != 0, f"release gate is not executable: {relative}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--root-description", type=Path, required=True)
    parser.add_argument("--consumer-description", type=Path, required=True)
    parser.add_argument("--repository-root", type=Path, required=True)
    args = parser.parse_args()

    contract = load(args.contract)
    require(contract["schemaVersion"] == 1, "unsupported integration-contract schema")
    verify_root(contract, load(args.root_description))
    verify_consumer(contract, load(args.consumer_description))
    verify_gate_files(contract, args.repository_root)


if __name__ == "__main__":
    main()
