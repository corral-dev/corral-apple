#!/usr/bin/env python3
"""Fail when SwiftUI-visible copy keys are missing from Localizable.xcstrings.

Why this exists: SwiftUI `Text("some.key")` with no matching xcstrings entry
does NOT fail the build -- the raw key renders on device. That is exactly how
9 `session.actions.*` keys shipped untranslated (raw `session.actions.copy` /
`session.actions.handoff` visible in the top-right menu).

Run (no Xcode / simulator needed):
    python3 scripts/check_localizations.py

Checks: every localization key referenced from Swift source must exist in
Localizable.xcstrings with non-empty `en` and `zh-Hans` values.
Exit 0 = covered, exit 1 = missing entries (listed with file:line).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
# Every Apple client target shares one string catalog.
DEFAULT_SOURCES = [REPO / "iOS", REPO / "Shared", REPO / "macOS"]
DEFAULT_XCSTRINGS = REPO / "Shared" / "Resources" / "Localizable.xcstrings"

# First string argument of view constructors that resolve via LocalizedStringKey.
CTOR_PATTERN = re.compile(
    r"(?:\bText|\bLabel|\bButton|\bMenu|\bSection|\bToggle|\bPicker"
    r"|\bnavigationTitle|\bconfirmationDialog|\bContentUnavailableView"
    r"|\bTextField|\bLabeledContent|\bTab|\bCommandMenu|\balert)"
    r"\(\s*\"((?:[^\"\\]|\\.)+?)\"",
)
# String(localized: "key" ...) incl. String.LocalizationValue("key").
LOCALIZED_PATTERN = re.compile(
    r"String\s*\(\s*localized:\s*(?:String\.LocalizationValue\s*\(\s*)?"
    r"\"((?:[^\"\\]|\\.)+?)\"",
)
# Switch bodies returning LocalizedStringKey, e.g. `case .running: "sessions.x"`.
# The case label must be an enum case (starts with `.`); string-labelled cases
# (`case "kimi": "bubble.left..."`) return SF Symbols, not copy keys. One line
# only: `if case .failed(let e) = x {` must not run on to a later `systemImage:`.
CASE_PATTERN = re.compile(
    r"case\s+\.[^:\n]*:\s*\"([a-z][a-z0-9_]*(\.[a-z0-9_]+)+)\"",
)
# `return (..., "sessions.x")` tuples carrying a LocalizedStringKey.
RETURN_TUPLE_PATTERN = re.compile(
    r"return\s*\([^)]*\"([a-z][a-z0-9_]*(\.[a-z0-9_]+)+)\"",
)

# Dotted shape a copy key must have (`Text(", ")`, `Text("A")` are literals).
KEY_SHAPE = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$")

# `Text("hosts.x.default_value \(name)")` / `String(localized: "a.b \(x)")`:
# the xcstrings key is either the base or `base + " %lld"/" %@"`.
INTERPOLATION = re.compile(r"\s*\\\(")


def base_key(raw: str) -> str:
    return INTERPOLATION.split(raw, maxsplit=1)[0]


def extract_keys(swift_file: Path) -> list[tuple[str, int]]:
    found: list[tuple[str, int]] = []
    try:
        text = swift_file.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"warning: cannot read {swift_file}: {exc}", file=sys.stderr)
        return found
    # Strip // line comments so commented-out code can't demand keys.
    lines = [
        (i + 1, line.split("//", 1)[0])
        for i, line in enumerate(text.splitlines())
    ]
    joined = "\n".join(line for _, line in lines)
    for pattern in (
        CTOR_PATTERN,
        LOCALIZED_PATTERN,
        CASE_PATTERN,
        RETURN_TUPLE_PATTERN,
    ):
        for match in pattern.finditer(joined):
            raw = match.group(1)
            key = base_key(raw)
            if not KEY_SHAPE.match(key):
                continue
            lineno = joined.count("\n", 0, match.start(1)) + 1
            found.append((key, lineno))
    return [(k, ln) for k, ln in found]


def lang_value(loc: dict) -> str:
    unit = loc.get("stringUnit", {}).get("value", "")
    if unit.strip():
        return unit
    # Pluralized entries keep values under variations instead of stringUnit.
    parts: list[str] = []

    def collect(node: object) -> None:
        if isinstance(node, dict):
            for k, v in node.items():
                if k == "stringUnit" and isinstance(v, dict):
                    val = v.get("value", "")
                    if isinstance(val, str) and val.strip():
                        parts.append(val)
                else:
                    collect(v)

    collect(loc.get("variations", {}))
    return " / ".join(parts)


def load_catalog(path: Path) -> dict[str, dict[str, str]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    catalog: dict[str, dict[str, str]] = {}
    for key, entry in data.get("strings", {}).items():
        locs = entry.get("localizations", {})
        catalog[key] = {
            lang: lang_value(locs.get(lang, {})) for lang in ("en", "zh-Hans")
        }
    return catalog


def catalog_has(catalog: dict[str, dict[str, str]], key: str) -> bool:
    if key in catalog:
        return True
    # `String(localized: "a.b \(x)")` compiles to keys like `a.b %lld`.
    return any(k == key or k.startswith(key + " ") for k in catalog)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", action="append", default=None)
    parser.add_argument("--xcstrings", default=str(DEFAULT_XCSTRINGS))
    args = parser.parse_args()

    roots = [Path(p) for p in args.sources] if args.sources else DEFAULT_SOURCES
    catalog = load_catalog(Path(args.xcstrings))

    problems: list[str] = []
    checked = 0
    swift_files = sorted(f for root in roots if root.exists() for f in root.rglob("*.swift"))
    for swift_file in swift_files:
        if ".derivedData" in swift_file.parts:
            continue
        for key, lineno in extract_keys(swift_file):
            checked += 1
            entry = None
            if key in catalog:
                entry = catalog[key]
            else:
                hit = next(
                    (k for k in catalog if k.startswith(key + " ")), None
                )
                if hit is not None:
                    entry = catalog[hit]
            rel = swift_file.relative_to(REPO)
            if entry is None:
                problems.append(f"missing key {key}  (used at {rel}:{lineno})")
            elif not entry["en"].strip() or not entry["zh-Hans"].strip():
                problems.append(
                    f"empty translation {key}  (used at {rel}:{lineno})"
                )

    if problems:
        print(f"checked {checked} key usages, {len(problems)} problem(s):")
        for problem in sorted(set(problems)):
            print(f"  {problem}")
        print("Add the keys (en + zh-Hans) to Shared/Resources/Localizable.xcstrings.")
        return 1
    print(f"checked {checked} key usages -- all present (en + zh-Hans).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
