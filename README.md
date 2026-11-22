# Mathematical Discovery

A real Noctalia plugin that places a polished, theme-aware discovery desklet on your desktop and reveals one carefully curated result at a time. The library now spans pure and applied mathematics, **algorithms and data structures (ADS)**, computer science and **artificial intelligence**. It rotates hourly by default, keeps a durable history, and works fully offline.

- **Plugin id:** `akim/math-discovery`
- **Version:** `1.1.0`
- **Plugin API:** `52` (Noctalia ≥ 5.5.0)
- **License:** MIT
- **Curated facts:** 2,266 across five areas and 60 subjects
- **Runtime dependency:** `xdg-utils` (only for opening source/reading links)

---

## What you get

### Native desktop widget (`desktop.luau`)

The main surface is a real `[[desktop_widget]]`, not a browser popup. It deliberately draws only three things:

1. the result name,
2. the topic, prefixed by a short area tag (`Math`, `Applied`, `ADS`, `CS`, `AI`),
3. the statement as plain readable text.

There are no glyphs, rules, counters, buttons, source lines or short explanations on the card. **Clicking anywhere on the card opens the full reader panel**, which carries the complete explanation, proof sketch, consequences, LaTeX and source metadata.

The card uses bundled **Noto Serif** for consistent rendering, with live Noctalia color roles for the active desktop palette. It renders the title, topic and statement at fixed sizes, with the statement capped at four lines. Text stays at full contrast when facts change; the clipped card cannot spill text beyond its bounds, and the reader panel holds the full statement. **Card transparency** is a real 0–100% slider (default 20%) that changes only the background fill.

Geometry belongs to Noctalia's desktop-widget editor. Dragging a corner scales the tile as a whole rather than reflowing its text, so keep it near its configured size for sharp typography; the editor's edit mode must be exited before geometry is adjusted through Noctalia config IPC. Clicking the card opens the full reader panel.

### Full reader panel (`reader.luau`)

A 560×620 floating panel carries the unabridged view: area, subject, level, kind, statement, exact LaTeX source, long explanation, proof idea, consequence, prerequisites, source and clearly-labelled supplementary reference metadata. It adds **Copy LaTeX**, favourite, source, previous and next controls. Open it by clicking the desklet or:

```sh
noctalia msg panel-toggle akim/math-discovery:reader
```

### Headless service (`discovery.luau`)

The service owns the dataset, timer, selection, history, favourites and source cache. UI entries never read files or the network; they only render a single JSON view blob and send commands back through state.

---

## Areas and content

Facts carry a `domain` as well as a `subject`, so preferences and rotation work at both levels.

| Area | Examples |
|---|---|
| Mathematics | algebra, analysis, number theory, combinatorics, geometry, topology, logic |
| Applied Mathematics | differential equations, numerical analysis, mathematical physics |
| Algorithms & Data Structures | sorting, graph algorithms, advanced data structures, string algorithms, amortised analysis |
| Computer Science | computability, complexity, cryptography, programming languages, distributed systems, networks |
| Artificial Intelligence | machine learning, neural networks, optimisation, reinforcement learning, probabilistic AI, NLP, computer vision |

A soft area preference favours one area without ever hiding the rest of the library. Selection also avoids recently seen areas, subjects and kinds, so a stream of ADS or AI facts never crowds out mathematics.

---

## Architecture

```text
plugin.toml
├── discovery.luau        [[service]]        dataset, rotation, cache, persistence
├── desktop.luau          [[desktop_widget]] primary native card
├── reader.luau           [[panel]]          scrollable full reader
├── lib/
│   ├── model.luau        fact schema, domain classification, JSON helpers, loader
│   ├── store.luau        durable state in noctalia.pluginDataDir()
│   ├── selection.luau    non-repeating, diversified selection (area/subject/kind/level)
│   └── sources.luau      Wikipedia / Quanta / Stack Exchange / arXiv adapters
├── data/*.json           curated subject files plus generated per-area files
├── tools/                offline dataset builder and wiki-title verifier
├── translations/en.json  settings labels and descriptions
└── tests/                offline static and runtime suites
```

### State protocol

The service publishes one encoded JSON blob to `mathdiscovery.view`. UI entries watch that key. Commands use `mathdiscovery.cmd` with the format:

```text
<monotonic-sequence>|<action>|<payload>
```

Actions are `next`, `prev`, `favorite` and `refresh`. The sequence is wall-clock milliseconds times ten plus a local counter, so stale or replayed commands are ignored. The service also accepts direct IPC events:

```sh
noctalia msg plugin akim/math-discovery:discovery all next
noctalia msg plugin akim/math-discovery:discovery all prev
noctalia msg plugin akim/math-discovery:discovery all favorite
noctalia msg plugin akim/math-discovery:discovery all refresh
noctalia msg plugin akim/math-discovery:discovery all status
noctalia msg plugin akim/math-discovery:discovery all open analysis-001
```

---

## Rotation and history

- The service ticks every **30 seconds** and rotates when `now - lastShownAtMs ≥ rotation_minutes × 60 000`.
- Default interval is **60 minutes**; settings allow 5–1440 minutes.
- With `catch_up_on_start = true`, a long absence causes exactly one rotation at startup rather than a burst.
- Selection penalises the last 12 facts, avoids recently seen subjects, areas and kinds, varies difficulty, and applies soft area/topic/difficulty preferences. A stable time-bucketed hash breaks ties, so selection is varied across sessions without needing a random seed that vanishes on restart.
- A timeline with a cursor powers **next** and **prev**. Moving forward from a rewound position truncates the abandoned future, so history stays coherent.
- The timeline keeps at most **200 unique** visits. On load, duplicate visits and ids unknown to the current dataset are removed.
- Favourites, the timeline, cursor and last-shown timestamp are written to `state.json` in `noctalia.pluginDataDir()` using a temp-file-plus-rename write. The source cache lives in `sources.json` beside it.

Network fetching is deliberately decoupled from rotation: the first check is delayed 20 seconds after service start, later checks honour the configured cadence, and **hourly rotation never fetches anything**.

---

## Sources and content policy

### Curated dataset only

Every displayed claim comes from the bundled, hand-reviewed JSON library. Network adapters supply **reference/further-reading metadata only**; they never inject facts into the widget. No article bodies are copied, no remote code is loaded, and no URLs are invented.

Source URLs are derived from Wikipedia article titles in each fact's `wiki` field. `tools/verify_wiki.py --fix` checks those titles against the MediaWiki API, normalises redirects and replaces unresolved titles with a safe area-level article.

### Supplementary adapters (`lib/sources.luau`)

| Source | Endpoint | What is fetched |
|---|---|---|
| Wikipedia | `https://en.wikipedia.org/w/api.php` | Two-sentence plaintext intro for up to six relevant article titles; used only as a labelled reference note. |
| Quanta Magazine | `https://www.quantamagazine.org/feed/` | RSS item titles, links and descriptions; used only as a labelled “further reading” link. |
| Math Stack Exchange | `https://api.stackexchange.com/2.3/search/advanced` | Question title, link, score and content licence for the current subject; labelled metadata only. |
| arXiv | `https://export.arxiv.org/api/query` | Three recent preprint titles, links and short abstract excerpts for the current area; labelled metadata only. |

Defaults:

- `enable_sources = true`,
- `source_cadence_hours = 24` (minimum six hours),
- one request per source per cadence,
- exponential backoff on failure, capped at three doublings,
- offline mode, transport errors, HTTP errors and malformed JSON all degrade to the fully usable offline library.

Adding a source means adding one adapter to `M.adapters`; fetching, caching and rendering are source-agnostic.

---

## Settings

| Key | Default | Meaning |
|---|---|---|
| `rotation_minutes` | `60` | Minutes between facts (5–1440). |
| `difficulty` | `any` | Preferred level; other facts are merely deprioritised, never hidden. |
| `domain` | `any` | Preferred area, from mathematics to AI; other areas are merely deprioritised. |
| `topics` | `[]` | Preferred subject names; empty means all subjects. |
| `show_explanation` | `true` | Show the short explanation on the desklet. |
| `card_transparency` | `20` | Card background transparency in percent (0–100, step 1). Only the fill fades; text stays opaque. |
| `enable_sources` | `true` | Allow metadata checks. |
| `source_cadence_hours` | `24` | Minimum hours between source checks. |
| `catch_up_on_start` | `true` | Rotate once at startup if the interval elapsed while Noctalia was off. |

Settings labels live in `translations/en.json`.

---

## Installation / local testing

### Install as a local plugin

```sh
mkdir -p ~/.local/share/noctalia/plugins
cp -r /home/akim/MathDiscovery ~/.local/share/noctalia/plugins/math-discovery
```

Noctalia discovers `~/.local/share/noctalia/plugins/<plugin>/` as a local source. Then either:

- open **Settings → Plugins** and enable **Mathematical Discovery**, or
- add a path source and enable it:

```sh
noctalia msg plugins source add math-dev path ~/.local/share/noctalia/plugins
noctalia msg plugins enable akim/math-discovery
```

Finally, add the `akim/math-discovery:fact` entry from the desktop-widget editor and position/resize it there.

### Checks you can run from this directory

```sh
noctalia plugins lint /home/akim/MathDiscovery
luac -p discovery.luau desktop.luau reader.luau lib/*.luau
python3 tests/validate.py
lua tests/runtime_suite.lua
```

`tests/validate.py` checks the manifest, translations, dataset schema/uniqueness, area coverage, `require()` paths, state-key consistency, command protocol, adapter endpoints and declarative-UI constructors. `tests/runtime_suite.lua` supplies a Noctalia stub and loads the real entries to exercise rotation, history, favourites, persistence, restart catch-up, area preference, source success/failure/offline behaviour and malformed view blobs.

### Adding many facts

Facts are authored compactly and expanded by a build step; see `tools/README.md` and `tools/catalog/FORMAT.md`:

```sh
# 1. add records to tools/catalog/<area>.json
python3 tools/build_dataset.py       # writes data/generated-*.json
python3 tools/verify_wiki.py --fix   # optional, needs network
python3 tests/validate.py
lua tests/runtime_suite.lua
```

The builder refuses duplicate ids/titles and stamps a shared retrieval date, so the library can grow to very large sizes without hand-editing every output file. Hand-written files in `data/` are never overwritten.

---

## Limitations

- Noctalia’s declarative UI has no LaTeX renderer. Each fact therefore stores a readable Unicode `statement` for display and an exact `latex` string that can be copied from the reader.
- Desktop widgets cannot take keyboard focus; all desklet controls are pointer buttons. The reader panel is the scrollable, keyboard-accessible long-form surface.
- Desklet geometry is host-owned. This plugin supplies an adaptive tree rather than a hard-coded pixel box.
- Supplementary sources are metadata-only and may be unavailable offline or rate-limited. They never affect the correctness of displayed facts.
- Wikipedia article titles can move. `tools/verify_wiki.py` is a dev-time check; the runtime loader does not require network access.
- History deduplicates repeated facts on load, so the unique visit count can be lower than the number of times **Next** was pressed.
- `noctalia config validate` reports “unknown section” warnings for a manifest because it validates the shell config schema; `noctalia plugins lint` is the authoritative plugin check.

---

## Library at a glance

| Area | Generated facts |
|---|---:|
| Mathematics | 510 |
| Applied Mathematics | 273 |
| Algorithms & Data Structures | 350 |
| Computer Science | 487 |
| Artificial Intelligence | 534 |

The original 112 hand-written facts remain in their subject files; their area is derived from the subject at load time. The other 2,154 facts are generated from eight compact catalog files in `tools/catalog/` and can be reproduced with `python3 tools/build_dataset.py`.

Kinds: 677 theorems, 505 concepts, 461 algorithms, 342 insights, 125 identities, 58 connections, 58 counterexamples and 40 curiosities.

---

## Test report

Performed in this build environment on **2026-11-22**:

| Test | Result |
|---|---|
| `noctalia plugins lint /home/akim/MathDiscovery` | **0 errors, 0 warnings**. |
| `luac -p` on all 7 shipped `.luau` files | **Passed**. |
| `python3 tests/validate.py` | **38,705 static checks passed**; 2,266 facts, 13 files, 60 subjects. |
| `lua tests/runtime_suite.lua` | **188 runtime checks passed** across rotation, history, favourites, persistence, catch-up, area preference, all four metadata adapters and UI fallbacks. |
| Wikipedia MediaWiki API title check | **1,468/1,468 unique titles resolve**; 7 bad titles replaced and 15 redirects canonicalised before the final build. |
| Source endpoint reachability | Wikipedia, Quanta, Stack Exchange and arXiv endpoints exercised through the stubbed HTTP transport; success, HTTP errors, garbage JSON and offline rejection all preserve the curated view. |
| Visual compositor check | Not available headlessly; the declarative tree was smoke-tested through a stub and remains a manual step after installation. |
