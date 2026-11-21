#!/usr/bin/env python3
"""Static validation for the Mathematical Discovery Noctalia plugin.

Run from anywhere:

    python3 tests/validate.py

The checks are deliberately offline and dependency-free. They cover the manifest,
translations, curated dataset, module paths, state protocol and declarative-UI
constructors/props. Runtime behaviour is covered by tests/runtime_suite.lua.
"""

from __future__ import annotations

import json
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ERRORS: list[str] = []
CHECKS = 0


def check(condition: bool, message: str) -> None:
    global CHECKS
    CHECKS += 1
    if not condition:
        ERRORS.append(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


# --- Manifest ----------------------------------------------------------------

manifest_path = ROOT / "plugin.toml"
manifest = tomllib.loads(read(manifest_path))

for key in ("id", "name", "version", "plugin_api", "author", "license", "description"):
    check(key in manifest, f"plugin.toml: missing {key}")

check(manifest.get("id") == "akim/math-discovery", "plugin.toml: unexpected id")
check(3 <= int(manifest.get("plugin_api", 0)) <= 57, "plugin.toml: plugin_api outside 3..57")

entry_kinds = {"service", "desktop_widget", "panel", "widget", "shortcut",
               "launcher_provider", "bar_widget"}
seen_entry_ids: set[str] = set()
for kind in sorted(entry_kinds & manifest.keys()):
    entries = manifest[kind]
    check(isinstance(entries, list) and len(entries) > 0, f"plugin.toml: empty {kind}")
    for entry in entries:
        eid = entry.get("id", "")
        check(bool(eid), f"plugin.toml: {kind} without id")
        check(eid not in seen_entry_ids, f"plugin.toml: duplicate entry id {eid}")
        seen_entry_ids.add(eid)
        path = entry.get("entry", "")
        check(bool(path), f"plugin.toml: {kind} {eid} without entry")
        check((ROOT / path).is_file(), f"plugin.toml: missing entry file {path}")

for required_kind, required_id in (("service", "discovery"),
                                   ("desktop_widget", "fact"),
                                   ("panel", "reader")):
    ids = [e.get("id") for e in manifest.get(required_kind, [])]
    check(required_id in ids, f"plugin.toml: missing [[{required_kind}]] {required_id}")

settings = manifest.get("setting", [])
setting_keys = {s.get("key") for s in settings}
check(len(settings) >= 8, "plugin.toml: expected at least eight settings")
check("rotation_minutes" in setting_keys, "plugin.toml: rotation_minutes setting missing")
for setting in settings:
    key = setting.get("key", "")
    for field in ("label_key", "description_key"):
        check(field in setting, f"plugin.toml: setting {key} missing {field}")
    if setting.get("type") == "select":
        for option in setting.get("options", []):
            check("label_key" in option,
                  f"plugin.toml: select option {option.get('value')} missing label_key")
    when = setting.get("visible_when")
    if when:
        check(when.get("key") in setting_keys,
              f"plugin.toml: visible_when references unknown setting {when.get('key')}")

check("xdg-utils" in manifest.get("dependencies", []),
      "plugin.toml: xdg-utils dependency missing (Source buttons need xdg-open)")

# --- Translations ------------------------------------------------------------

translations = json.loads(read(ROOT / "translations" / "en.json"))
required_keys: set[str] = set()
for setting in settings:
    for field in ("label_key", "description_key"):
        if field in setting:
            required_keys.add(setting[field])
    for option in setting.get("options", []):
        if "label_key" in option:
            required_keys.add(option["label_key"])
for key in sorted(required_keys):
    check(key in translations, f"translations/en.json: missing {key}")

# --- Curated dataset ---------------------------------------------------------

REQUIRED_FIELDS = {
    "id", "title", "subject", "kind", "difficulty", "statement", "latex",
    "short", "long", "proof", "consequence", "prerequisites", "source",
    "wiki", "retrieved",
}
KINDS = {"theorem", "identity", "insight", "counterexample", "curiosity",
         "definition", "connection", "algorithm"}
LEVELS = {"curiosity", "first_year", "intermediate", "advanced"}
facts: list[dict] = []
dataset_files = sorted((ROOT / "data").glob("*.json"))
check(len(dataset_files) >= 6, "data/: expected at least six subject files")
for path in dataset_files:
    data = json.loads(read(path))
    check(isinstance(data, list) and len(data) > 0, f"{path.name}: not a non-empty array")
    for index, fact in enumerate(data):
        label = f"{path.name}#{index + 1}"
        check(set(fact) == REQUIRED_FIELDS,
              f"{label}: field mismatch {set(fact) ^ REQUIRED_FIELDS}")
        check(re.fullmatch(r"[a-z][a-z0-9-]*", fact.get("id", "")),
              f"{label}: invalid id {fact.get('id')}")
        check(fact.get("difficulty") in LEVELS, f"{label}: bad difficulty")
        check(fact.get("kind") in KINDS, f"{label}: bad kind")
        for field in ("title", "statement", "latex", "short", "long", "proof",
                      "consequence", "wiki", "retrieved"):
            check(isinstance(fact.get(field), str) and fact[field].strip(),
                  f"{label}: empty {field}")
        check(1 <= len(fact.get("prerequisites", [])) <= 6,
              f"{label}: prerequisites must contain 1..6 items")
        check(isinstance(fact.get("source"), dict) and fact["source"].get("name"),
              f"{label}: missing source name")
        if "url" in fact.get("source", {}):
            check(str(fact["source"]["url"]).startswith(("http://", "https://")),
                  f"{label}: source URL must be http(s)")
        check(fact.get("retrieved") == "2026-11-21", f"{label}: unexpected retrieved date")

facts = [f for path in dataset_files for f in json.loads(read(path))]
check(len(facts) >= 100, f"dataset: only {len(facts)} facts (need >= 100)")
ids = [f["id"] for f in facts]
titles = [f["title"] for f in facts]
check(len(ids) == len(set(ids)), "dataset: duplicate ids")
check(len(titles) == len(set(titles)), "dataset: duplicate titles")
subjects = {f["subject"] for f in facts}
check(len(subjects) >= 8, f"dataset: only {len(subjects)} subjects")
for level in LEVELS:
    check(any(f["difficulty"] == level for f in facts),
          f"dataset: no facts at difficulty {level}")

# --- Luau source -------------------------------------------------------------

luau_files = sorted(ROOT.glob("*.luau")) + sorted((ROOT / "lib").glob("*.luau"))
sources = {path: read(path) for path in luau_files}

require_re = re.compile(r"""require\(["']([^"']+)["']\)""")
for path, text in sources.items():
    for module in require_re.findall(text):
        target = Path(module)
        if not target.suffix:
            target = target.with_suffix(".luau")
        resolved = (path.parent / target).resolve()
        check(resolved.is_file(), f"{path.name}: require target missing: {module}")

state_keys: dict[str, set[str]] = {}
for path, text in sources.items():
    for name, value in re.findall(r'local\s+(\w*(?:KEY|ID))\s*=\s*"([^"]+)"', text):
        state_keys.setdefault(name, set()).add(value)
for name, values in state_keys.items():
    check(len(values) == 1, f"state key {name} is inconsistent: {sorted(values)}")

for path, text in sources.items():
    for banned in ("loadstring(", "dofile("):
        check(banned not in text, f"{path.name}: remote/unbuffered code API {banned} used")

UI_CONSTRUCTORS = {
    "column", "row", "scroll", "dragSource", "dropZone", "box", "label",
    "fillLabel", "markdown", "glyph", "image", "pixelStream", "colorPicker",
    "separator", "spacer", "progress", "button", "graph", "input", "select",
    "slider", "toggle",
}
UI_PROPS = {
    "key", "width", "height", "flexGrow", "opacity", "visible", "gap", "padding",
    "paddingH", "paddingV", "align", "justify", "fill", "radius", "border",
    "borderWidth", "minWidth", "minHeight", "onClick", "onHover", "tooltip",
    "text", "fontSize", "color", "fontWeight", "fontFamily", "baseline",
    "maxWidth", "maxLines", "textAlign", "shadow", "thickness", "spacing",
    "orientation", "progress", "track", "textColor", "value", "variant",
    "contentAlign", "controlSize", "selected", "onRightClick", "onChange",
    "onSubmit", "onScroll", "stickToBottom", "scrollToBottomRev", "revealKey",
    "placeholder", "inputType", "options", "onValueChanged", "softness",
    "clip", "name", "size",
}
NOCTALIA_MEMBERS = {
    "log", "runAsync", "runStream", "runInTerminal", "commandExists",
    "focusedOutputName", "outputs", "isDarkMode", "getColor", "getSetting",
    "appIconPath", "setWallpaperEnabled", "setWallpaper", "wallpaperDirectory",
    "wallpaperPath", "setWallpaperMask", "togglePanel", "openSettings",
    "openColorPicker", "notify", "notifyError", "openPath", "revealPath",
    "copyToClipboard", "clipboardText", "getenv", "expandPath", "formatTime",
    "timeFormat", "dateFormat", "isValidTimezone", "nowMs", "setUpdateInterval",
    "readFile", "readFileAsync", "writeFile", "mkdirAll", "removeFile",
    "renameFile", "fileExists", "fileInfo", "listDir", "pluginDir",
    "pluginDataDir", "loadFont", "tr", "trp", "http", "httpStream", "download",
    "fuzzyScore", "getConfig", "state", "json", "string", "sound", "idle",
    "layer", "umbriel", "compositor", "osd",
}

for path, text in sources.items():
    for name in re.findall(r"\bui\.([A-Za-z_]\w*)\s*\(", text):
        check(name in UI_CONSTRUCTORS, f"{path.name}: unknown ui constructor ui.{name}")
    # Props are simple `key = value` pairs inside ui.* call tables. This is a
    # conservative scan: it only reports identifiers that are definitely props.
    for prop in re.findall(r"(?m)^\s*([A-Za-z_]\w*)\s*=", text):
        if prop in {"local", "return", "function", "end", "if", "for", "while"}:
            continue
        if prop in UI_PROPS or prop in NOCTALIA_MEMBERS:
            continue
        # Local variables/table fields outside UI tables are legitimate; only
        # flag names that look like known-but-misspelled UI transform props.
        if prop.lower().replace("_", "") in {"translatey", "translatex", "transform", "margin"}:
            check(False, f"{path.name}: unsupported layout prop {prop}")
    for member in re.findall(r"\bnoctalia\.([A-Za-z_]\w*)", text):
        check(member in NOCTALIA_MEMBERS,
              f"{path.name}: unknown noctalia member noctalia.{member}")

# Every named onClick handler must exist in the same entry file.
for path in (ROOT / "desktop.luau", ROOT / "reader.luau"):
    text = read(path)
    handlers = set(re.findall(r'onClick\s*=\s*"([^"]+)"', text))
    for handler in handlers:
        check(re.search(rf"function\s+{re.escape(handler)}\s*\(", text) is not None,
              f"{path.name}: onClick '{handler}' has no global function")

service = read(ROOT / "discovery.luau")
commands = set(re.findall(r"^\s{2}(\w+)\s*=", service, re.M))
for action in ("next", "prev", "favorite", "refresh"):
    check(action in commands, f"discovery.luau: COMMANDS.{action} missing")
for action in re.findall(r'sendCommand\("([^"]+)"\)',
                         read(ROOT / "desktop.luau") + read(ROOT / "reader.luau")):
    check(action in commands, f"UI sends unknown command {action}")

adapter_source = read(ROOT / "lib" / "sources.luau")
for endpoint in ("en.wikipedia.org/w/api.php", "quantamagazine.org/feed/",
                 "api.stackexchange.com/2.3/search/advanced"):
    check(endpoint in adapter_source, f"lib/sources.luau: missing endpoint {endpoint}")

# --- Summary -----------------------------------------------------------------

if ERRORS:
    print(f"FAILED {len(ERRORS)} of {CHECKS} checks:")
    for error in ERRORS:
        print(f"  - {error}")
    sys.exit(1)

print(f"OK: {CHECKS} static checks passed")
print(f"     {len(facts)} facts across {len(dataset_files)} files, "
      f"{len(subjects)} subjects, {len(luau_files)} Luau modules/entries")
