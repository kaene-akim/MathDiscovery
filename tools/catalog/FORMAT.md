# Compact catalog format

Each `tools/catalog/*.json` file is a JSON array of compact records. The
`tools/build_dataset.py` script expands them into the full `data/*.json` fact
schema that the plugin loads at runtime.

## Record fields

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Unique lowercase kebab id, prefixed with your author prefix. |
| `title` | yes | Distinctive human-readable title (must not collide with any other fact). |
| `subject` | yes | Subject name shown on the card; keep to your assigned subject list. |
| `domain` | yes | One of the five supported domains. |
| `kind` | yes | `theorem`, `identity`, `insight`, `counterexample`, `curiosity`, `definition`, `connection`, `algorithm`. |
| `difficulty` | yes | `curiosity`, `first_year`, `intermediate`, `advanced`. |
| `statement` | yes | One or two precise sentences; this is the displayed claim. |
| `latex` | yes | Compact LaTeX. In JSON, backslashes must be doubled (`"\\sum"`). |
| `short` | yes | One-sentence intuition. |
| `detail` | no | One to three sentences; appended to `short` to form the reader's `long` text. |
| `proof` | yes | A short proof sketch (1–3 sentences). Open problems start with `Open.`. |
| `consequence` | yes | Why the result matters (1–2 sentences). |
| `prerequisites` | yes | Array of 1–6 short prerequisite phrases. |
| `wiki` | no | Real English Wikipedia article title. Omit to use the domain's fallback article. |
| `retrieved` | no | Omitted: the generator stamps the shared retrieval date. |

Only add results you are confident are correct. Prefer a well-known standard
result over a plausible-sounding but unverifiable one. Titles must be unique
across the whole library; use your author prefix in the `id` and make the
`title` specific enough to stand out.
