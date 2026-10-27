#!/usr/bin/env python3
"""Check (default) or regenerate catalog fields from the curated JSON.

Media descriptors and verbatim licensed sources remain in Swift and are retained
unchanged. This does not fetch assets or reinterpret third-party source fields.
"""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "Data/exercise-catalog-extension.json"
SWIFT = ROOT / "Packages/FitnessCore/Sources/FitnessCore/ExpandedExerciseCatalog.swift"


def quoted(value):
    # JSON string escapes are Swift-compatible for this catalog's plain text.
    result = json.dumps(value, ensure_ascii=False)
    if "\\u" in result or "\\(" in result:
        raise ValueError("Unsupported Swift string escape in catalog")
    return result


def render(entries, current):
    ids = [e["id"] for e in entries]
    if len(entries) != 151 or len(set(ids)) != len(ids):
        raise ValueError("Expected 151 unique extension IDs")
    if len({e["name"] for e in entries}) != len(entries):
        raise ValueError("Duplicate extension names")
    start = current.index("    static let exercises: [Exercise] = [")
    end = current.index("    static let legacyMedia:")
    details = current[current.index("    static let details:"):end]
    # Keep all existing related IDs/media expressions, including their credits.
    suffixes = dict(re.findall(r'^        "([^"]+)": ExerciseDetail\(.*?(alternativeIDs: .*),$', details, re.M))
    if set(suffixes) != set(ids):
        raise ValueError("Swift detail IDs differ from JSON IDs")
    lines = ["    static let exercises: [Exercise] = ["]
    for e in entries:
        args = [f"{k}: {quoted(e[k])}" for k in ("id", "name", "englishName")]
        args += [f"kind: .{e['kind']}", f"metric: .{e['metric']}"]
        args += [f"{k}: {quoted(e[k])}" for k in ("equipment", "muscle")]
        args += [f"loadConvention: .{e['loadConvention']}", f"instructions: {quoted(e['instructions'])}"]
        lines.append("        Exercise(" + ", ".join(args) + "),")
    lines += ["    ]", "    static let details: [String: ExerciseDetail] = ["]
    for e in entries:
        args = [f"{k}: {quoted(e[k])}" for k in ("aliases", "secondaryMuscles", "movementPattern", "difficulty", "commonMistakes")]
        lines.append(f"        {quoted(e['id'])}: ExerciseDetail(" + ", ".join(args) + ", " + suffixes[e["id"]] + ",")
    lines += ["    ]", ""]
    return current[:start] + "\n".join(lines) + current[end:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="Regenerate only exercise/detail catalog fields")
    args = parser.parse_args()
    entries = json.loads(DATA.read_text(encoding="utf-8"))
    current = SWIFT.read_text(encoding="utf-8")
    expected = render(entries, current)
    if args.write:
        with SWIFT.open("w", encoding="utf-8", newline="\n") as output:
            output.write(expected)
    elif expected != current:
        raise SystemExit("Catalog drift: run python scripts/sync_expanded_catalog.py --write")
    print(f"Catalog JSON/Swift synchronized: {len(entries)} movements")


if __name__ == "__main__":
    main()
