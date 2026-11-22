#!/usr/bin/env python3
"""Check every wiki title used by the curated library against Wikipedia.

Optionally normalise redirects and replace titles that do not resolve with a
safe, domain-level fallback:

    python3 tools/verify_wiki.py --fix

The check is dev-only; the plugin never needs the network to display facts.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
API = "https://en.wikipedia.org/w/api.php"
UA = "MathDiscoveryDatasetCheck/1.1 (dev-time title verification)"
BATCH = 50

FALLBACK = {
    "Mathematics": "Mathematics",
    "Applied Mathematics": "Applied mathematics",
    "Algorithms & Data Structures": "Algorithm",
    "Computer Science": "Computer science",
    "Artificial Intelligence": "Artificial intelligence",
}

SUBJECT_DOMAIN = {
    "Mathematics of Computing": "Computer Science",
    "Computability & Logic": "Computer Science",
    "Complexity Theory": "Computer Science",
    "Cryptography & Security": "Computer Science",
    "Programming Languages": "Computer Science",
    "Distributed Systems": "Computer Science",
    "Information Theory": "Computer Science",
    "Computer Networks": "Computer Science",
    "Computer Architecture": "Computer Science",
    "Data Structures": "Algorithms & Data Structures",
    "Sorting & Searching": "Algorithms & Data Structures",
    "Graph Algorithms": "Algorithms & Data Structures",
    "Algorithm Analysis": "Algorithms & Data Structures",
    "Advanced Data Structures": "Algorithms & Data Structures",
    "Parallel & External Algorithms": "Algorithms & Data Structures",
    "String Algorithms": "Algorithms & Data Structures",
    "Machine Learning": "Artificial Intelligence",
    "Neural Networks": "Artificial Intelligence",
    "Optimization": "Artificial Intelligence",
    "Reinforcement Learning": "Artificial Intelligence",
    "Probabilistic AI": "Artificial Intelligence",
    "Natural Language Processing": "Artificial Intelligence",
    "Computer Vision": "Artificial Intelligence",
    "AI Safety & Interpretability": "Artificial Intelligence",
    "Machine Learning Theory": "Artificial Intelligence",
    "Multimodal AI": "Artificial Intelligence",
    "AI Systems & Evaluation": "Artificial Intelligence",
    "Game Theory": "Applied Mathematics",
    "Mathematical Biology": "Applied Mathematics",
    "Control Theory": "Applied Mathematics",
    "Signal Processing": "Applied Mathematics",
    "Stochastic Calculus": "Applied Mathematics",
    "Mathematical Economics": "Applied Mathematics",
    "Database Systems": "Computer Science",
    "Operating Systems": "Computer Science",
    "Compilers & Runtime Systems": "Computer Science",
    "Software Engineering": "Computer Science",
    "Computer Graphics": "Computer Science",
    "Parallel Computing": "Computer Science",
    "Formal Methods": "Computer Science",
    "Applied Mathematics": "Applied Mathematics",
    "Mathematical Physics": "Applied Mathematics",
    "Differential Equations": "Applied Mathematics",
    "Numerical Analysis": "Applied Mathematics",
}


def domain_of(record: dict) -> str:
    return record.get("domain") or SUBJECT_DOMAIN.get(record.get("subject", ""), "Mathematics")


def fallback_for(record: dict) -> str:
    return FALLBACK.get(domain_of(record), "Mathematics")


def query(titles: list[str]) -> tuple[set[str], dict[str, str]]:
    params = {
        "action": "query", "format": "json", "redirects": "1",
        "titles": "|".join(titles),
    }
    url = API + "?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    payload = None
    for attempt in range(6):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
            break
        except urllib.error.HTTPError as exc:
            if exc.code != 429 or attempt == 5:
                raise
            print(f"  rate limited; backing off {5 * (attempt + 1)}s", file=sys.stderr)
            time.sleep(5 * (attempt + 1))
    if payload is None:
        raise RuntimeError("Wikipedia API returned no payload")
    query_data = payload.get("query", {})
    valid = {
        page["title"] for page in query_data.get("pages", {}).values()
        if "missing" not in page
    }
    aliases: dict[str, str] = {}
    for item in query_data.get("normalized", []):
        aliases[item["from"]] = item["to"]
    for item in query_data.get("redirects", []):
        aliases[item["from"]] = item["to"]
    return valid, aliases


def resolve(title: str, aliases: dict[str, str]) -> str:
    seen: set[str] = set()
    while title in aliases and title not in seen:
        seen.add(title)
        title = aliases[title]
    return title


def load_json(path: Path) -> list[dict]:
    value = json.loads(path.read_text(encoding="utf-8"))
    return value if isinstance(value, list) else []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fix", action="store_true", help="normalise or replace bad titles")
    args = parser.parse_args()

    data_paths = sorted((ROOT / "data").glob("*.json"))
    catalog_paths = sorted((ROOT / "tools" / "catalog").glob("*.json"))
    data_records = [(path, load_json(path)) for path in data_paths]
    catalog_records = [(path, load_json(path)) for path in catalog_paths]

    titles = sorted({
        record.get("wiki", "") for _, records in data_records + catalog_records
        for record in records if isinstance(record, dict) and record.get("wiki")
    })
    if not titles:
        print("No wiki titles to check.")
        return 0

    valid: set[str] = set()
    aliases: dict[str, str] = {}
    for start in range(0, len(titles), BATCH):
        batch = titles[start:start + BATCH]
        batch_valid, batch_aliases = query(batch)
        valid |= batch_valid
        aliases.update(batch_aliases)
        if start + BATCH < len(titles):
            time.sleep(3.0)

    canonical = {title: resolve(title, aliases) for title in titles}
    broken = [title for title in titles if canonical[title] not in valid]

    print(f"Checked {len(titles)} unique wiki titles: "
          f"{len(titles) - len(broken)} resolve, {len(broken)} need attention.")
    for title in broken[:40]:
        print(f"  missing: {title}")
    if len(broken) > 40:
        print(f"  ... and {len(broken) - 40} more")

    redirects = [f"{title} -> {canonical[title]}" for title in titles
                 if title not in broken and canonical[title] != title]
    if redirects:
        print(f"{len(redirects)} redirect(s) normalised "
              f"(examples: {', '.join(redirects[:5])})")

    if args.fix:
        changed_data = changed_catalog = 0
        for path, records in data_records:
            dirty = False
            for record in records:
                if not isinstance(record, dict):
                    continue
                title = record.get("wiki", "")
                if not title:
                    continue
                if title in broken:
                    record["wiki"] = fallback_for(record)
                    dirty = True
                elif canonical[title] != title:
                    record["wiki"] = canonical[title]
                    dirty = True
            if dirty:
                path.write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n",
                                encoding="utf-8")
                changed_data += 1
        for path, records in catalog_records:
            dirty = False
            for record in records:
                if not isinstance(record, dict):
                    continue
                title = record.get("wiki", "")
                if not title:
                    continue
                if title in broken:
                    record["wiki"] = fallback_for(record)
                    dirty = True
                elif canonical[title] != title:
                    record["wiki"] = canonical[title]
                    dirty = True
            if dirty:
                path.write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n",
                                encoding="utf-8")
                changed_catalog += 1
        print(f"Fixed {changed_data} data file(s) and {changed_catalog} catalog file(s).")

    return 1 if broken and not args.fix else 0


if __name__ == "__main__":
    raise SystemExit(main())
