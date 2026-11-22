# Dataset tooling

The plugin reads `data/*.json` at runtime. The files in this directory are
development-time helpers for growing that library:

1. **Author compact records** in `tools/catalog/*.json`. The schema is in
   `catalog/FORMAT.md`. Each agent/file should use its own `id` prefix so ids
   stay globally unique.
2. **Build** the full fact objects:
   ```sh
   python3 tools/build_dataset.py
   ```
   This writes small `data/chunk-<area>-NNN.json` files (50 facts each) and
   refuses to continue on duplicate ids/titles or malformed records. Small
   chunks matter: Noctalia enforces a CPU budget per script callback, and a
   single large JSON array cannot be decoded in one callback.
3. **Verify wiki titles** (optional, needs network):
   ```sh
   python3 tools/verify_wiki.py --fix
   ```
   Redirects are canonicalised and titles that do not resolve are replaced by a
   safe domain-level article. The plugin itself never needs this step.
4. **Validate and test**:
   ```sh
   python3 tests/validate.py
   lua tests/runtime_suite.lua
   noctalia plugins lint /home/akim/MathDiscovery
   ```

Re-running the builder replaces only `chunk-*.json` (and any legacy
`generated-*.json`); hand-written files in `data/` are left untouched. Keep newly authored records in `tools/catalog/`
so the generated output can always be reproduced.
