#!/usr/bin/env python3
"""Expand tools/catalog/*.json records into the plugin's data/*.json library.

The plugin itself only reads data/*.json at runtime, so this script is a
development-time build step. Compact records are defined in FORMAT.md; this
script adds the shared retrieval date, derives the long explanation, and groups
the results into one generated file per domain.

Run from anywhere:

    python3 tools/build_dataset.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "tools" / "catalog"
DATA = ROOT / "data"

RETRIEVED = "2026-11-21"  # tests/validate.py pins the shared retrieval stamp.

DOMAINS = {
    "Mathematics",
    "Applied Mathematics",
    "Algorithms & Data Structures",
    "Computer Science",
    "Artificial Intelligence",
}

KINDS = {
    "theorem", "identity", "insight", "counterexample", "curiosity",
    "definition", "connection", "algorithm",
}

LEVELS = {"curiosity", "first_year", "intermediate", "advanced"}

# Noctalia charges each script callback for CPU time. One JSON array per domain
# is far too large to decode in a single callback, so generated facts are
# written as small numbered chunks that the service can load one per tick.
CHUNK_PREFIX = {
    "Mathematics": "chunk-math-",
    "Applied Mathematics": "chunk-applied-",
    "Algorithms & Data Structures": "chunk-ads-",
    "Computer Science": "chunk-cs-",
    "Artificial Intelligence": "chunk-ai-",
}
# 25 facts per file is small enough that a single interrupted tick drops the
# whole chunk (and is retried), rather than partially loading it.
CHUNK_SIZE = 25

FALLBACK_WIKI = {
    "Mathematics": "Mathematics",
    "Applied Mathematics": "Applied mathematics",
    "Algorithms & Data Structures": "Algorithm",
    "Computer Science": "Computer science",
    "Artificial Intelligence": "Artificial intelligence",
}

ERRORS: list[str] = []


def fail(label: str, message: str) -> None:
    ERRORS.append(f"{label}: {message}")


def existing_facts() -> list[dict]:
    facts: list[dict] = []
    for path in sorted(DATA.glob("*.json")):
        if path.name.startswith("generated-") or path.name.startswith("chunk-"):
            continue
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            fail(path.name, f"invalid JSON: {exc}")
            continue
        if isinstance(value, list):
            facts.extend(item for item in value if isinstance(item, dict))
    return facts


def expand(record: dict, label: str) -> dict | None:
    if not isinstance(record, dict):
        fail(label, "record is not an object")
        return None

    fact_id = str(record.get("id", "")).strip()
    if not re.fullmatch(r"[a-z][a-z0-9-]*", fact_id):
        fail(label, f"invalid id {fact_id!r}")
        return None

    domain = str(record.get("domain", "")).strip()
    if domain not in DOMAINS:
        fail(label, f"invalid domain {domain!r}")
        return None

    kind = str(record.get("kind", "")).strip()
    if kind not in KINDS:
        fail(label, f"invalid kind {kind!r}")
        return None

    difficulty = str(record.get("difficulty", "")).strip()
    if difficulty not in LEVELS:
        fail(label, f"invalid difficulty {difficulty!r}")
        return None

    required_text = ("title", "subject", "statement", "latex", "short", "proof", "consequence")
    for field in required_text:
        value = record.get(field)
        if not isinstance(value, str) or not value.strip():
            fail(label, f"missing or empty {field}")
            return None

    prerequisites = record.get("prerequisites")
    if not isinstance(prerequisites, list) or not 1 <= len(prerequisites) <= 6:
        fail(label, "prerequisites must be a list of 1..6 items")
        return None
    prerequisites = [str(item).strip() for item in prerequisites]
    if any(not item for item in prerequisites):
        fail(label, "empty prerequisite")
        return None

    wiki = str(record.get("wiki", "") or "").strip() or FALLBACK_WIKI[domain]
    short = record["short"].strip()
    detail = str(record.get("detail", "") or "").strip()
    long_text = short + (" " + detail if detail else "")

    source_name = "Wikipedia" if wiki else "Curated library"
    return {
        "id": fact_id,
        "title": record["title"].strip(),
        "subject": record["subject"].strip(),
        "domain": domain,
        "kind": kind,
        "difficulty": difficulty,
        "statement": record["statement"].strip(),
        "latex": record["latex"].strip(),
        "short": short,
        "long": long_text,
        "proof": record["proof"].strip(),
        "consequence": record["consequence"].strip(),
        "prerequisites": prerequisites,
        "source": {"name": source_name},
        "wiki": wiki,
        "retrieved": RETRIEVED,
    }


def main() -> int:
    base_facts = existing_facts()
    seen_ids = {fact["id"] for fact in base_facts}
    seen_titles = {fact["title"] for fact in base_facts}

    by_domain: dict[str, list[dict]] = {domain: [] for domain in DOMAINS}
    catalogs = sorted(CATALOG.glob("*.json"))
    if not catalogs:
        fail("catalog", "no tools/catalog/*.json files found")

    total = 0
    for path in catalogs:
        try:
            records = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            fail(path.name, f"invalid JSON: {exc}")
            continue
        if not isinstance(records, list):
            fail(path.name, "catalog must be a JSON array")
            continue
        for index, record in enumerate(records, 1):
            label = f"{path.name}#{index}"
            fact = expand(record, label)
            if fact is None:
                continue
            if fact["id"] in seen_ids:
                fail(label, f"duplicate id {fact['id']}")
                continue
            if fact["title"] in seen_titles:
                fail(label, f"duplicate title {fact['title']}")
                continue
            seen_ids.add(fact["id"])
            seen_titles.add(fact["title"])
            by_domain[fact["domain"]].append(fact)
            total += 1

    if ERRORS:
        print(f"FAILED with {len(ERRORS)} catalog problem(s):", file=sys.stderr)
        for error in ERRORS[:60]:
            print(f"  - {error}", file=sys.stderr)
        if len(ERRORS) > 60:
            print(f"  ... and {len(ERRORS) - 60} more", file=sys.stderr)
        return 1

    DATA.mkdir(parents=True, exist_ok=True)

    # Remove the old one-file-per-domain outputs. Keeping them would load every
    # generated fact twice and reintroduce the CPU-budget failure.
    for path in DATA.glob("generated-*.json"):
        path.unlink()
    for path in DATA.glob("chunk-*.json"):
        path.unlink()

    for domain, prefix in CHUNK_PREFIX.items():
        facts = by_domain[domain]
        if not facts:
            continue
        facts.sort(key=lambda item: item["id"])
        for offset in range(0, len(facts), CHUNK_SIZE):
            part = facts[offset:offset + CHUNK_SIZE]
            index = offset // CHUNK_SIZE + 1
            name = f"{prefix}{index:03d}.json"
            (DATA / name).write_text(
                json.dumps(part, ensure_ascii=False, separators=(",", ":")) + "\n",
                encoding="utf-8",
            )

    width = max(len(domain) for domain in DOMAINS)
    for domain in sorted(DOMAINS):
        print(f"  {domain:<{width}}  {len(by_domain[domain]):>5}")
    print(f"Generated {total} facts from {len(catalogs)} catalog file(s); "
          f"library total {len(base_facts) + total}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
