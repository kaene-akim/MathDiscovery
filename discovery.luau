--!nonstrict
-- Mathematical Discovery — headless [[service]] entry.
--
-- Owns the curated library, the visit timeline, favourites, the reference cache
-- and the hourly rotation. UI entries never read files or the network: they
-- watch the single JSON blob published to noctalia.state("mathdiscovery.view")
-- and send commands to "mathdiscovery.cmd" as "<seq>|<action>|<payload>".
--
-- IPC: noctalia msg plugin akim/math-discovery:discovery all <next|prev|
--      favorite|refresh|status>

local model      = require("./lib/model.luau")
local store      = require("./lib/store.luau")
local selection  = require("./lib/selection.luau")
local sources    = require("./lib/sources.luau")

local VIEW_KEY = "mathdiscovery.view"
local CMD_KEY  = "mathdiscovery.cmd"

local TIMELINE_LIMIT = 200
local TICK_MS = 30 * 1000
local FIRST_SOURCE_DELAY_MS = 20 * 1000
local MANUAL_FETCH_GUARD_MS = 5 * 60 * 1000

local config = {}
local facts = {}
local factById = {}
local persisted = {}
local sourceState = {}

local currentId = nil
local lastShownAtMs = 0
local revision = 0
local lastCommandSeq = 0
local lastMinuteBucket = -1
local nextSourceCheckMs = 0
local lastFetchStartMs = 0
local fetching = false
local loadErrors = {}

-- --- Configuration ---------------------------------------------------------

local function readConfig()
  local minutes = tonumber(noctalia.getConfig("rotation_minutes")) or 60
  config.rotationMs = math.max(5, minutes) * 60 * 1000

  config.difficulty = noctalia.getConfig("difficulty") or "any"

  config.topics = {}
  local topics = noctalia.getConfig("topics")
  if type(topics) == "table" then
    for _, topic in ipairs(topics) do
      if type(topic) == "string" and topic ~= "" then
        config.topics[#config.topics + 1] = topic
      end
    end
  end

  config.showExplanation = noctalia.getConfig("show_explanation") ~= false
  config.enableSources = noctalia.getConfig("enable_sources") ~= false
  config.catchUpOnStart = noctalia.getConfig("catch_up_on_start") ~= false

  local hours = tonumber(noctalia.getConfig("source_cadence_hours")) or 24
  config.cadenceMs = math.max(6, hours) * 60 * 60 * 1000
end

-- --- Persistence helpers ---------------------------------------------------

local function isFavorite(id)
  for _, favorite in ipairs(persisted.favorites or {}) do
    if favorite == id then return true end
  end
  return false
end

local function persist()
  persisted.lastShownAtMs = lastShownAtMs
  persisted.timeline = persisted.timeline or {}
  persisted.cursor = persisted.cursor or 1
  persisted.favorites = persisted.favorites or {}
  store.saveState(persisted)
end

local function repairTimeline()
  persisted.timeline = type(persisted.timeline) == "table" and persisted.timeline or {}
  local clean = {}
  for _, id in ipairs(persisted.timeline) do
    if type(id) == "string" and factById[id] then
      -- Drop duplicate visits; the timeline must have unique entries for the
      -- cursor arithmetic in next/prev to stay correct.
      local duplicate = false
      for _, existing in ipairs(clean) do
        if existing == id then duplicate = true break end
      end
      if not duplicate then clean[#clean + 1] = id end
    end
  end
  local overflow = #clean - TIMELINE_LIMIT
  if overflow > 0 then
    for _ = 1, overflow do table.remove(clean, 1) end
  end
  persisted.timeline = clean

  persisted.cursor = math.floor(tonumber(persisted.cursor) or 0)
  if persisted.cursor < 1 then persisted.cursor = 1 end
  if persisted.cursor > #clean then persisted.cursor = math.max(1, #clean) end

  persisted.favorites = type(persisted.favorites) == "table" and persisted.favorites or {}
  local cleanFavorites = {}
  for _, id in ipairs(persisted.favorites) do
    if type(id) == "string" and factById[id] then cleanFavorites[#cleanFavorites + 1] = id end
  end
  persisted.favorites = cleanFavorites

  lastShownAtMs = tonumber(persisted.lastShownAtMs) or 0
  currentId = persisted.timeline[persisted.cursor]
end

-- --- Publishing ------------------------------------------------------------

local function publish()
  local view = {
    status = #facts > 0 and "ready" or "empty",
    revision = revision,
    fact = factById[currentId] or {},
    position = persisted.cursor or 0,
    visited = #(persisted.timeline or {}),
    librarySize = #facts,
    canPrev = (persisted.cursor or 0) > 1,
    favorite = currentId and isFavorite(currentId) or false,
    showExplanation = config.showExplanation,
    fetching = fetching,
    nextAtMs = lastShownAtMs + config.rotationMs,
    nowMs = noctalia.nowMs(),
    reference = nil,
    reading = nil,
    sourceCount = 0,
    loadErrors = loadErrors,
  }

  if currentId then
    view.reference = sources.referenceFor(factById[currentId], sourceState)
    view.reading = sources.latestReading(sourceState)
    view.sourceCount = #sources.allRecords(sourceState)
  end

  local encoded, err = model.encode(view)
  if not encoded then
    noctalia.log("Math Discovery: cannot encode view: " .. tostring(err))
    return
  end
  noctalia.state.set(VIEW_KEY, encoded)
end

-- --- Rotation --------------------------------------------------------------

local function selectNew()
  local picked = selection.pick(facts, {
    timeline = persisted.timeline,
    currentId = currentId,
    difficulty = config.difficulty,
    topics = config.topics,
    nowMs = noctalia.nowMs(),
  })
  if not picked then return false end

  -- Moving forward from a rewound timeline replaces the abandoned future.
  while #persisted.timeline > persisted.cursor do
    table.remove(persisted.timeline)
  end
  persisted.timeline[#persisted.timeline + 1] = picked.id
  while #persisted.timeline > TIMELINE_LIMIT do
    table.remove(persisted.timeline, 1)
  end
  persisted.cursor = #persisted.timeline
  currentId = picked.id
  lastShownAtMs = noctalia.nowMs()
  revision = revision + 1
  persist()
  publish()
  return true
end

local function showAt(cursor)
  persisted.cursor = math.max(1, math.min(cursor, #persisted.timeline))
  currentId = persisted.timeline[persisted.cursor]
  lastShownAtMs = noctalia.nowMs()
  revision = revision + 1
  persist()
  publish()
end

local function nextFact()
  if persisted.cursor < #persisted.timeline then
    showAt(persisted.cursor + 1)
  else
    selectNew()
  end
end

local function previousFact()
  if persisted.cursor > 1 then
    showAt(persisted.cursor - 1)
    return true
  end
  return false
end

local function toggleFavorite()
  if not currentId then return end
  local favorites = persisted.favorites
  for index, id in ipairs(favorites) do
    if id == currentId then
      table.remove(favorites, index)
      persist()
      publish()
      return
    end
  end
  favorites[#favorites + 1] = currentId
  persist()
  publish()
end

-- --- Supplementary sources -------------------------------------------------

local function sourceContext()
  local titles = {}
  local current = factById[currentId]
  if current and current.wiki ~= "" then titles[1] = current.wiki end
  for _, fact in ipairs(facts) do
    if #titles >= 5 then break end
    if fact.wiki ~= "" and fact.subject == (current and current.subject or "")
      and fact.wiki ~= titles[1] then
      titles[#titles + 1] = fact.wiki
    end
  end
  return {
    titles = titles,
    subject = current and current.subject or "mathematics",
    enabled = config.enableSources,
    cadenceMs = config.cadenceMs,
  }
end

local function startFetch(force)
  if fetching then return false end
  if not config.enableSources and not force then return false end
  fetching = true
  lastFetchStartMs = noctalia.nowMs()
  publish()

  local context = sourceContext()
  context.force = force == true

  sources.fetchDue(sourceState, context, function(newState, changed)
    sourceState = newState
    fetching = false
    if changed then store.saveSources(sourceState) end
    nextSourceCheckMs = noctalia.nowMs() + config.cadenceMs
    publish()
  end)
  return true
end

-- --- Commands --------------------------------------------------------------

local COMMANDS = {
  next = nextFact,
  prev = function()
    if not previousFact() then
      noctalia.notify("Mathematical Discovery", "This is the first fact in your history.")
    end
  end,
  favorite = toggleFavorite,
  refresh = function()
    if noctalia.nowMs() - lastFetchStartMs < MANUAL_FETCH_GUARD_MS then
      noctalia.notify("Mathematical Discovery", "Sources were checked recently.")
    elseif not startFetch(true) then
      noctalia.notify("Mathematical Discovery", "A source check is already running.")
    end
  end,
}

-- Ignore a command left over from an earlier service runtime: state is copied
-- across entries, but its lifetime is not the lifetime of this script.
local initialCmd = tostring(noctalia.state.get(CMD_KEY) or "")
lastCommandSeq = tonumber(initialCmd:match("^(%d+)") or "") or 0

noctalia.state.watch(CMD_KEY, function(value)
  local text = tostring(value or "")
  local seq = tonumber(text:match("^(%d+)") or "")
  local action = text:match("^%d+|([^|]+)")
  if not seq or not action then return end
  if seq <= lastCommandSeq then return end -- duplicate click / replayed value
  lastCommandSeq = seq
  local handler = COMMANDS[action]
  if handler then handler() end
end)

-- --- Lifecycle -------------------------------------------------------------

readConfig()

facts, loadErrors = model.loadFacts()
for _, fact in ipairs(facts) do factById[fact.id] = fact end
if #loadErrors > 0 then
  noctalia.log("Math Discovery: " .. #loadErrors .. " dataset problem(s); first: " .. loadErrors[1])
end

persisted = store.loadState()
sourceState = store.loadSources()
repairTimeline()

if not currentId and #facts > 0 then
  selectNew()
elseif config.catchUpOnStart and noctalia.nowMs() - lastShownAtMs >= config.rotationMs then
  selectNew()
else
  lastShownAtMs = math.min(lastShownAtMs, noctalia.nowMs())
  persist()
end

publish()
nextSourceCheckMs = noctalia.nowMs() + FIRST_SOURCE_DELAY_MS
noctalia.setUpdateInterval(TICK_MS)

function onConfigChanged()
  readConfig()
  lastMinuteBucket = -1
  publish()
  if config.enableSources then
    -- A config edit rebuilds UI entries but keeps this service alive.
    nextSourceCheckMs = math.min(nextSourceCheckMs, noctalia.nowMs() + 1000)
  end
end

function update()
  local now = noctalia.nowMs()

  if #facts > 0 and now - lastShownAtMs >= config.rotationMs then
    nextFact()
  end

  if config.enableSources and not fetching and now >= nextSourceCheckMs then
    startFetch(false)
  end

  -- Refresh the "next discovery in N min" line without churning state on every
  -- 30-second tick.
  local bucket = math.floor(now / 60000)
  if bucket ~= lastMinuteBucket then
    lastMinuteBucket = bucket
    publish()
  end
end

function onIpc(event, payload)
  local handler = COMMANDS[event]
  if handler then
    handler()
  elseif event == "status" then
    noctalia.log(string.format(
      "Math Discovery: %d facts, %d visited, current=%s, sources=%d",
      #facts, #persisted.timeline, tostring(currentId), #sources.allRecords(sourceState)))
  elseif event == "open" then
    -- Jump straight to a fact by id (useful for keybinds and testing). An id
    -- outside the timeline is appended so next/prev keep working afterwards.
    local id = tostring(payload or "")
    if factById[id] then
      for index, visited in ipairs(persisted.timeline) do
        if visited == id then
          showAt(index)
          return
        end
      end
      while #persisted.timeline > persisted.cursor do
        table.remove(persisted.timeline)
      end
      persisted.timeline[#persisted.timeline + 1] = id
      while #persisted.timeline > TIMELINE_LIMIT do
        table.remove(persisted.timeline, 1)
      end
      showAt(#persisted.timeline)
    end
  end
end

function onExit(_signal, _reason)
  persist()
end
