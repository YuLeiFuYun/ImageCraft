#!/usr/bin/env python3
from __future__ import annotations

import collections
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATTERN = re.compile(r"\bfunc\s+[A-Za-z0-9_]*(IMG_ANIM_PT_\d+)\s*\(")


def main() -> int:
    hits: dict[str, list[str]] = collections.defaultdict(list)
    for path in sorted((ROOT / "Tests").rglob("*.swift")):
        text = path.read_text()
        for match in PATTERN.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            hits[match.group(1)].append(f"{path.relative_to(ROOT)}:{line}")
    errors: list[str] = []
    for test_id, locations in sorted(hits.items()):
        if len(locations) != 1:
            errors.append(f"{test_id}: duplicate definitions {locations}")
    numbers = sorted(int(test_id.rsplit("_", 1)[1]) for test_id in hits)
    if numbers:
        expected = list(range(1, numbers[-1] + 1))
        if numbers != expected:
            missing = sorted(set(expected) - set(numbers))
            errors.append(f"animation test IDs must remain contiguous 1...{numbers[-1]}; missing={missing}")
    if errors:
        print("Animation test identity invalid:")
        for error in errors:
            print(f"- {error}")
        return 1
    print(f"Animation test identity: definitions={len(hits)} range=IMG_ANIM_PT_001-{numbers[-1]:03d} errors=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
