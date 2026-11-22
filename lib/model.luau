--!nonstrict
-- Fact schema, validation and the curated dataset loader.
--
-- Displayed mathematical claims come only from the bundled, hand-checked dataset.
-- Network sources (lib/sources.luau) supply clearly-labelled reference metadata,
-- never facts, so an unverified remote claim can never be presented as a fact.

local M = {}

M.DIFFICULTIES = { "curiosity", "first_year", "intermediate", "advanced" }

M.DIFFICULTY_LABELS = {
  curiosity    = "Curiosity",
  first_year   = "First year",
  intermediate = "Intermediate",
  advanced     = "Advanced",
}

M.KINDS = {
  theorem = "Theorem",
  identity = "Identity",
  insight = "Insight",
  counterexample = "Counterexample",
  curiosity = "Curiosity",
  definition = "Concept",
  connection = "Connection",
  algorithm = "Algorithm",
}

-- Broader areas used for filtering and for diversifying the rotation. Facts may
-- declare one explicitly; older entries are classified from their subject.
M.DOMAINS = {
  "Mathematics",
  "Applied Mathematics",
  "Algorithms & Data Structures",
  "Computer Science",
  "Artificial Intelligence",
}

local DOMAIN_BY_SUBJECT = {
  ["Mathematics of Computing"] = "Computer Science",
  ["Computability & Logic"] = "Computer Science",
  ["Complexity Theory"] = "Computer Science",
  ["Cryptography & Security"] = "Computer Science",
  ["Programming Languages"] = "Computer Science",
  ["Distributed Systems"] = "Computer Science",
  ["Information Theory"] = "Computer Science",
  ["Computer Networks"] = "Computer Science",
  ["Computer Architecture"] = "Computer Science",
  ["Data Structures"] = "Algorithms & Data Structures",
  ["Sorting & Searching"] = "Algorithms & Data Structures",
  ["Graph Algorithms"] = "Algorithms & Data Structures",
  ["Algorithm Analysis"] = "Algorithms & Data Structures",
  ["Advanced Data Structures"] = "Algorithms & Data Structures",
  ["Parallel & External Algorithms"] = "Algorithms & Data Structures",
  ["String Algorithms"] = "Algorithms & Data Structures",
  ["Machine Learning"] = "Artificial Intelligence",
  ["Neural Networks"] = "Artificial Intelligence",
  ["Optimization"] = "Artificial Intelligence",
  ["Reinforcement Learning"] = "Artificial Intelligence",
  ["Probabilistic AI"] = "Artificial Intelligence",
  ["Natural Language Processing"] = "Artificial Intelligence",
  ["Computer Vision"] = "Artificial Intelligence",
  ["AI Safety & Interpretability"] = "Artificial Intelligence",
  ["Machine Learning Theory"] = "Artificial Intelligence",
  ["Multimodal AI"] = "Artificial Intelligence",
  ["AI Systems & Evaluation"] = "Artificial Intelligence",
  ["Game Theory"] = "Applied Mathematics",
  ["Mathematical Biology"] = "Applied Mathematics",
  ["Control Theory"] = "Applied Mathematics",
  ["Signal Processing"] = "Applied Mathematics",
  ["Stochastic Calculus"] = "Applied Mathematics",
  ["Mathematical Economics"] = "Applied Mathematics",
  ["Database Systems"] = "Computer Science",
  ["Operating Systems"] = "Computer Science",
  ["Compilers & Runtime Systems"] = "Computer Science",
  ["Software Engineering"] = "Computer Science",
  ["Computer Graphics"] = "Computer Science",
  ["Parallel Computing"] = "Computer Science",
  ["Formal Methods"] = "Computer Science",
  ["Applied Mathematics"] = "Applied Mathematics",
  ["Mathematical Physics"] = "Applied Mathematics",
  ["Differential Equations"] = "Applied Mathematics",
  ["Numerical Analysis"] = "Applied Mathematics",
}

local ALLOWED_DOMAIN = {}
for _, domain in ipairs(M.DOMAINS) do ALLOWED_DOMAIN[domain] = true end

function M.domainFor(declared, subject)
  if type(declared) == "string" and ALLOWED_DOMAIN[declared] then return declared end
  return DOMAIN_BY_SUBJECT[subject] or "Mathematics"
end

local function trim(value)
  return type(value) == "string" and noctalia.string.trim(value) or ""
end

local function stringArray(value)
  local out = {}
  if type(value) ~= "table" then return out end
  for _, item in ipairs(value) do
    if type(item) == "string" and item ~= "" then
      out[#out + 1] = item
    end
  end
  return out
end

local function isHttpUrl(value)
  if type(value) ~= "string" then return false end
  return value:match("^https://") ~= nil or value:match("^http://") ~= nil
end

local ALLOWED_DIFFICULTY = {}
for _, level in ipairs(M.DIFFICULTIES) do ALLOWED_DIFFICULTY[level] = true end

local ALLOWED_KIND = {}
for kind in pairs(M.KINDS) do ALLOWED_KIND[kind] = true end

-- Validate and normalise one raw fact. Returns fact, nil on success;
-- nil, reason on failure. Optional fields get safe defaults so a missing field
-- can never crash a renderer.
function M.normalise(raw, index)
  if type(raw) ~= "table" then return nil, "entry is not a table" end

  local id = trim(raw.id)
  if not id:match("^[a-z][a-z0-9%-]*$") then
    return nil, "invalid id at index " .. tostring(index)
  end

  local title = trim(raw.title)
  local subject = trim(raw.subject)
  local statement = trim(raw.statement)
  local short = trim(raw.short)
  if title == "" or subject == "" or statement == "" or short == "" then
    return nil, id .. ": missing title/subject/statement/short"
  end

  local difficulty = trim(raw.difficulty)
  if not ALLOWED_DIFFICULTY[difficulty] then
    return nil, id .. ": unknown difficulty '" .. difficulty .. "'"
  end

  local kind = trim(raw.kind)
  if kind == "" then kind = "insight" end
  if not ALLOWED_KIND[kind] then
    return nil, id .. ": unknown kind '" .. kind .. "'"
  end

  local source = type(raw.source) == "table" and raw.source or {}
  local sourceName = trim(source.name)
  local sourceUrl = trim(source.url)
  if sourceName == "" then sourceName = "Curated library" end
  if sourceUrl == "" and type(raw.wiki) == "string" and raw.wiki ~= "" then
    -- Wikipedia URLs are derived from a verified article title, not invented.
    sourceUrl = "https://en.wikipedia.org/wiki/"
      .. noctalia.string.urlEncode((raw.wiki:gsub(" ", "_")))
  end
  if sourceUrl ~= "" and not isHttpUrl(sourceUrl) then
    return nil, id .. ": source URL must be http(s)"
  end

  local fact = {
    id            = id,
    title         = title,
    subject       = subject,
    domain        = M.domainFor(raw.domain, subject),
    kind          = kind,
    difficulty    = difficulty,
    level         = M.DIFFICULTY_LABELS[difficulty],
    kindLabel     = M.KINDS[kind],
    statement     = statement,
    latex         = trim(raw.latex),
    short         = short,
    long          = trim(raw.long),
    proof         = trim(raw.proof),
    consequence   = trim(raw.consequence),
    prerequisites = stringArray(raw.prerequisites),
    sourceName    = sourceName,
    sourceUrl     = sourceUrl,
    wiki          = trim(raw.wiki),
    retrieved     = trim(raw.retrieved),
  }

  -- The long view falls back to the short explanation. This keeps the reader
  -- useful even for facts that intentionally ship without an extended write-up.
  if fact.long == "" then fact.long = fact.short end

  return fact, nil
end

function M.decode(text)
  if type(text) ~= "string" then return nil, "not a string" end
  local ok, value, err = pcall(noctalia.json.decode, text)
  if not ok then return nil, tostring(value) end
  if value == nil then return nil, err or "invalid JSON" end
  return value, nil
end

function M.encode(value, pretty)
  local ok, encoded, err = pcall(noctalia.json.encode, value, pretty)
  if not ok or encoded == nil then return nil, tostring(err or value) end
  return encoded, nil
end

-- Load every data/*.json file. Splitting the library by subject keeps the files
-- reviewable and lets new facts be added by dropping in another JSON array.
function M.loadFacts()
  local facts = {}
  local problems = {}
  local seen = {}

  local files, listErr = noctalia.listDir("data")
  if not files then
    return facts, { "cannot list data/: " .. tostring(listErr) }
  end
  table.sort(files)

  for _, name in ipairs(files) do
    if name:match("%.json$") then
      local raw, readErr = noctalia.readFile("data/" .. name)
      if not raw then
        problems[#problems + 1] = name .. ": " .. tostring(readErr)
      else
        local list, decodeErr = M.decode(raw)
        if not list or type(list) ~= "table" then
          problems[#problems + 1] = name .. ": " .. tostring(decodeErr)
        elseif not (#list > 0) and next(list) == nil then
          -- empty array is fine, e.g. an optional extension pack
        else
          for index, item in ipairs(list) do
            local fact, why = M.normalise(item, name .. "#" .. index)
            if not fact then
              problems[#problems + 1] = why
            elseif seen[fact.id] then
              problems[#problems + 1] = fact.id .. ": duplicate id"
            else
              seen[fact.id] = true
              facts[#facts + 1] = fact
            end
          end
        end
      end
    end
  end

  return facts, problems
end

-- Plain-text rendering. Noctalia's declarative UI has no LaTeX renderer, so the
-- dataset stores both a readable Unicode statement (displayed) and the exact
-- LaTeX source (copyable from the reader panel).
function M.oneLine(text, limit)
  text = tostring(text or ""):gsub("%s+", " ")
  text = noctalia.string.trim(text)
  if limit and #text > limit then
    return text:sub(1, limit - 1) .. "…"
  end
  return text
end

return M
