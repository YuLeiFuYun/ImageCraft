#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

SCHEMA_VERSION = 1
MODULES = ("ImageCraftCore", "ImageCraftImageIO")
RELATIONSHIP_KINDS = {"conformsTo", "inheritsFrom"}


def declaration(symbol: dict) -> str:
    return "".join(fragment.get("spelling", "") for fragment in symbol.get("declarationFragments", []))


def normalize_module(path: Path, module: str) -> dict:
    graph = json.loads(path.read_text(encoding="utf-8"))
    symbols_by_id = {
        symbol["identifier"]["precise"]: symbol
        for symbol in graph.get("symbols", [])
        if symbol.get("accessLevel") in {"public", "open"}
    }
    symbols = []
    for precise, symbol in symbols_by_id.items():
        symbols.append(
            {
                "declaration": declaration(symbol),
                "kind": symbol["kind"]["identifier"],
                "path": ".".join(symbol.get("pathComponents", [])),
                "preciseIdentifier": precise,
            }
        )
    symbols.sort(key=lambda value: (value["path"], value["kind"], value["declaration"], value["preciseIdentifier"]))

    relationships = []
    for relationship in graph.get("relationships", []):
        if relationship.get("kind") not in RELATIONSHIP_KINDS:
            continue
        source = relationship.get("source")
        if source not in symbols_by_id:
            continue
        source_path = ".".join(symbols_by_id[source].get("pathComponents", []))
        target = relationship.get("targetFallback") or relationship.get("target")
        relationships.append(
            {
                "kind": relationship["kind"],
                "source": source_path,
                "target": target,
            }
        )
    relationships.sort(key=lambda value: (value["source"], value["kind"], value["target"]))
    return {
        "module": module,
        "symbolCount": len(symbols),
        "symbols": symbols,
        "relationships": relationships,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--symbol-graph-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    modules = []
    for module in MODULES:
        path = args.symbol_graph_directory / f"{module}.symbols.json"
        if not path.is_file():
            raise FileNotFoundError(f"missing symbol graph: {path}")
        modules.append(normalize_module(path, module))
    report = {"schemaVersion": SCHEMA_VERSION, "modules": modules}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
