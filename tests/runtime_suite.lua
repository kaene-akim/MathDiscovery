--!nonstrict
-- Offline runtime suite for Mathematical Discovery.
--
-- It supplies a small Noctalia stub, loads the real service and UI entries, and
-- exercises rotation, history, favourites, persistence, source failures and
-- malformed view blobs. Run from the plugin root:
--
--   lua tests/runtime_suite.lua

local selfPath = debug.getinfo(1, "S").source:gsub("^@", "")
local ROOT = selfPath:gsub("/?tests/[^/]+$", "")
if ROOT == "" then ROOT = "." end
local DATA_DIR = "/tmp/opencode/mathdiscovery-runtime-tests"

os.execute("rm -rf '" .. DATA_DIR .. "' && mkdir -p '" .. DATA_DIR .. "'")

package.path = "./?;./?.lua;./?.luau;" .. package.path

-- Noctalia's require() resolves explicit relative .luau paths from the calling
-- file. Standard Lua does not, so reproduce that behaviour for the harness.
local standardRequire = require
function require(name)
  if type(name) ~= "string" or not name:match("%.luau$") then
    return standardRequire(name)
  end
  local caller = debug.getinfo(2, "S").source:gsub("^@", "")
  local directory = caller:match("^(.*)/[^/]+$") or "."
  local relative = name:gsub("^%.%/", "")
  local full = directory .. "/" .. relative
  local cacheKey = "@" .. full
  if package.loaded[cacheKey] ~= nil then return package.loaded[cacheKey] end
  local module = dofile(full)
  package.loaded[cacheKey] = module
  return module
end

local json = dofile(ROOT .. "/tests/json.lua")
local checkCount = 0

local function check(condition, message)
  checkCount = checkCount + 1
  if not condition then error("FAIL: " .. tostring(message), 2) end
end

local function resolve(path)
  if path:sub(1, 1) == "/" then return path end
  if path:sub(1, 1) == "~" then return (os.getenv("HOME") or "") .. path:sub(2) end
  return ROOT .. "/" .. path
end

local function readFile(path)
  local handle = io.open(resolve(path), "rb")
  if not handle then return nil, "no such file" end
  local contents = handle:read("*a")
  handle:close()
  return contents
end

local function writeFile(path, contents)
  local handle = io.open(resolve(path), "wb")
  if not handle then return false, "cannot write" end
  handle:write(contents)
  handle:close()
  return true
end

local clockMs = 1700000000000
local config = {
  rotation_minutes = 5,
  difficulty = "any",
  domain = "any",
  topics = {},
  show_explanation = true,
  animations = false,
  enable_sources = true,
  source_cadence_hours = 6,
  catch_up_on_start = true,
}

local values = {}
local watchers = {}
local logs = {}
local httpMode = "offline"
local httpCalls = {}

local state = {}

function state.get(key)
  return values[key]
end

function state.set(key, value)
  values[key] = value
  for _, callback in ipairs(watchers[key] or {}) do callback(value) end
end

function state.watch(key, callback)
  watchers[key] = watchers[key] or {}
  watchers[key][#watchers[key] + 1] = callback
end

function state.emit(key, value)
  values[key] = value
  for _, callback in ipairs(watchers[key] or {}) do callback(value) end
end

local function urlEncode(text)
  return (tostring(text):gsub("[^%w%-_%.~]", function(char)
    return string.format("%%%02X", char:byte())
  end))
end

local function trim(text)
  return tostring(text):match("^%s*(.-)%s*$")
end

local function fakeHttp(request, callback)
  httpCalls[#httpCalls + 1] = request.url
  if httpMode == "offline" then return false end

  if httpMode == "transport" then
    callback({ ok = false, status = 0, body = "" })
    return true
  end
  if httpMode == "http500" then
    callback({ ok = true, status = 500, body = "server error" })
    return true
  end
  if httpMode == "garbage" then
    callback({ ok = true, status = 200, body = "this is not json" })
    return true
  end

  -- httpMode == "ok": return a small, believable payload per endpoint.
  local view = decodeState("mathdiscovery.view") or {}
  local wiki = (view.fact and view.fact.wiki) or "Mathematics"
  if request.url:find("w/api.php", 1, true) then
    local body = json.encode({
      query = { pages = {
        [tostring(math.floor(clockMs / 1000))] = {
          title = wiki,
          extract = "A concise reference extract for " .. wiki .. ".",
        },
      } },
    })
    callback({ ok = true, status = 200, body = body })
  elseif request.url:find("quantamagazine.org", 1, true) then
    callback({ ok = true, status = 200, body =
      '<?xml version="1.0"?><rss><channel><item><title>A new proof of a theorem about primes</title>'
      .. '<link>https://www.quantamagazine.org/example-article/</link>'
      .. '<description>Mathematicians found a shorter argument.</description></item></channel></rss>' })
  elseif request.url:find("export.arxiv.org", 1, true) then
    callback({ ok = true, status = 200, body =
      '<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><entry>'
      .. '<title>A survey of the cited topic</title>'
      .. '<id>https://arxiv.org/abs/2401.00001</id>'
      .. '<summary>A short preprint abstract used only as a reading link.</summary>'
      .. '</entry></feed>' })
  elseif request.url:find("api.stackexchange.com", 1, true) then
    local body = json.encode({
      items = { {
        title = "Why is this theorem surprising?",
        link = "https://math.stackexchange.com/questions/1234567/example",
        score = 42,
        content_license = "CC BY-SA 4.0",
      } },
    })
    callback({ ok = true, status = 200, body = body })
  else
    callback({ ok = true, status = 404, body = "unknown endpoint" })
  end
  return true
end

decodeState = function(key)
  local raw = values[key]
  if type(raw) ~= "string" then return nil end
  local ok, value = pcall(json.decode, raw)
  if not ok then return nil end
  return value
end

noctalia = {
  log = function(message) logs[#logs + 1] = tostring(message) end,
  notify = function() end,
  notifyError = function() end,
  commandExists = function() return true end,
  runAsync = function() return true end,
  copyToClipboard = function() return true end,
  togglePanel = function() end,
  nowMs = function() return clockMs end,
  setUpdateInterval = function() end,
  getConfig = function(key) return config[key] end,
  pluginDataDir = function() return DATA_DIR end,
  readFile = readFile,
  writeFile = writeFile,
  mkdirAll = function() return true end,
  removeFile = function(_path) return true end,
  renameFile = function(from, to)
    if not writeFile(to, readFile(from)) then return false, "rename failed" end
    os.remove(resolve(from))
    return true
  end,
  listDir = function(path)
    local directory = resolve(path)
    local handle = io.popen("find '" .. directory .. "' -maxdepth 1 -type f -printf '%f\\n'")
    if not handle then return nil, "cannot list" end
    local names = {}
    for line in handle:lines() do names[#names + 1] = line end
    handle:close()
    table.sort(names)
    return names
  end,
  http = fakeHttp,
  json = json,
  string = { trim = trim, urlEncode = urlEncode, urlDecode = function(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
  end },
  state = state,
}

local expectedLibrarySize = 0
do
  for _, name in ipairs(noctalia.listDir("data") or {}) do
    if name:match("%.json$") then
      local raw = readFile("data/" .. name)
      local ok, list = pcall(json.decode, raw)
      if ok and type(list) == "table" then expectedLibrarySize = expectedLibrarySize + #list end
    end
  end
end

local function loadService()
  watchers = {}
  dofile(ROOT .. "/discovery.luau")

  -- The service loads data files across ticks to stay inside Noctalia's
  -- per-callback CPU budget. Drive those ticks before asserting on the view.
  local initial = decodeState("mathdiscovery.view")
  check(type(initial) == "table", "service should publish an initial view")
  if initial.loading then
    local before = initial.librarySize or 0
    update()
    local after = decodeState("mathdiscovery.view")
    check((after.librarySize or 0) >= before, "incremental load must not lose facts")
  end
  local guard = 0
  while decodeState("mathdiscovery.view").loading do
    update()
    guard = guard + 1
    check(guard < 100, "incremental loader did not finish")
  end
  check(decodeState("mathdiscovery.view").loading == false,
    "library should be fully loaded")
end

local function view()
  local value = decodeState("mathdiscovery.view")
  check(type(value) == "table", "view blob must decode to a table")
  return value
end

local function advance(minutes)
  clockMs = clockMs + math.floor(minutes * 60 * 1000)
end

-- --- 1. Initial load --------------------------------------------------------

loadService()
do
  local first = view()
  check(first.status == "ready", "service should start ready")
  check(first.librarySize == expectedLibrarySize,
    "library size mismatch: view=" .. tostring(first.librarySize)
    .. " files=" .. tostring(expectedLibrarySize))
  check(first.librarySize > 1000, "expanded library should contain over a thousand facts")
  check(type(first.domainCounts) == "table", "view should publish domain counts")
  check(first.fact and first.fact.id and first.fact.title and first.fact.domain,
    "first fact must be complete and classified by domain")
  check(first.fact.statement and first.fact.long and first.fact.proof,
    "fact must include statement, explanation and proof")
  check(first.fact.sourceUrl and first.fact.sourceUrl:match("^https://en.wikipedia.org/wiki/"),
    "source URL should be derived from a verified wiki title")
  check(first.revision == 1, "first publication should be revision 1")
end

-- --- 2. Rotation and non-repetition ----------------------------------------

local recentSet = { [view().fact.id] = true }
local recentOrder = { view().fact.id }
local current = view().fact.id
for step = 1, 30 do
  onIpc("next")
  local nextView = view()
  check(nextView.fact.id ~= current, "next must change fact")
  check(not recentSet[nextView.fact.id],
    "fact repeated within the recent window: " .. nextView.fact.id)
  recentSet[nextView.fact.id] = true
  recentOrder[#recentOrder + 1] = nextView.fact.id
  if #recentOrder > 11 then
    recentSet[table.remove(recentOrder, 1)] = nil
  end
  current = nextView.fact.id
  check(nextView.visited >= step + 1, "visited count should grow")
end

local thirdLast, secondLast, last = view().fact.id, nil, nil
onIpc("prev")
secondLast = view().fact.id
onIpc("prev")
last = view().fact.id
check(secondLast ~= thirdLast and last ~= secondLast and last ~= thirdLast,
  "prev must walk the timeline backwards")
onIpc("next")
check(view().fact.id == secondLast, "next after prev must replay history")
onIpc("next")
check(view().fact.id == thirdLast, "next after prev must return to the original fact")

-- --- 3. Favourites and durability ------------------------------------------

do
  local id = view().fact.id
  state.set("mathdiscovery.cmd", tostring(math.floor(clockMs)) .. "1|favorite|")
  check(view().favorite == true, "favourite should be on after toggle")
  local saved = json.decode(readFile(DATA_DIR .. "/state.json"))
  local found = false
  for _, favorite in ipairs(saved.favorites or {}) do
    if favorite == id then found = true end
  end
  check(found, "favourite must be persisted immediately")
  state.set("mathdiscovery.cmd", tostring(math.floor(clockMs) + 1) .. "1|favorite|")
  check(view().favorite == false, "favourite should toggle off")
end

-- --- 4. Timer-driven rotation ----------------------------------------------

do
  local before = view()
  advance(6)
  update()
  local after = view()
  check(after.fact.id ~= before.fact.id, "update() must rotate after the interval")
  check(after.revision > before.revision, "rotation must increment revision")
end

-- --- 5. Catch-up after a long absence --------------------------------------

do
  local before = view().fact.id
  advance(60 * 24)
  onExit(0, "shutdown")
  loadService()
  local after = view()
  check(after.fact.id ~= before, "catch-up should rotate once at startup")
  -- repairTimeline() intentionally removes duplicate visits, so the unique
  -- history can be shorter than the number of manual advances.
  check(after.visited >= 20,
    "history should survive a service restart (visited=" .. tostring(after.visited) .. ")")
  local saved = json.decode(readFile(DATA_DIR .. "/state.json"))
  check(after.visited == #saved.timeline,
    "published visited count should match the persisted timeline")
end

-- --- 5b. Domain preference --------------------------------------------------

do
  config.domain = "artificial_intelligence"
  loadService()
  onIpc("next")
  check(view().fact.domain == "Artificial Intelligence",
    "domain preference should favour AI facts: " .. tostring(view().fact.domain))
  config.domain = "any"
  loadService()
end

-- --- 6. Supplementary sources: success, failure and malformed responses ----

do
  httpMode = "ok"
  httpCalls = {}
  advance(10)
  onIpc("refresh")
  check(view().status == "ready", "source fetch must not disturb the curated view")
  check(view().reference ~= nil, "Wikipedia adapter should supply a matching reference")
  check(view().reference.wikiTitle == view().fact.wiki, "reference must match the current fact")
  check(view().reading ~= nil, "a reading link should be available after a successful check")
  check(#httpCalls == 4, "one refresh should call all four adapters, got " .. tostring(#httpCalls))
  check(tostring(httpCalls[4]):find("export.arxiv.org", 1, true) ~= nil,
    "the fourth adapter should query arXiv metadata")
  check((view().sourceCount or 0) >= 4, "all four adapters should contribute records")

  local before = view().fact.id
  httpMode = "garbage"
  advance(10)
  onIpc("refresh")
  check(view().fact.id == before, "malformed source response must not change the fact")
  check(view().status == "ready", "malformed source response must not break the widget")

  local sourcesFile = readFile(DATA_DIR .. "/sources.json")
  check(type(sourcesFile) == "string", "source cache should be persisted")
  local cached = json.decode(sourcesFile)
  check(type(cached.failures) == "table", "source failures should be tracked")

  httpMode = "offline"
  advance(10)
  onIpc("refresh")
  check(view().status == "ready", "offline mode must keep the widget fully usable")
end

-- --- 7. UI entries: render, malformed view, buttons ------------------------

do
  -- Build a tiny declarative-UI stub that records the last rendered tree.
  local lastTree = nil
  local function nodeFactory(kind)
    return function(props, children)
      return { type = kind, props = props or {}, children = children or {} }
    end
  end
  ui = setmetatable({}, {
    __index = function(_, kind) return nodeFactory(kind) end,
  })
  desktopWidget = {
    render = function(tree) lastTree = tree end,
    setNeedsFrameTick = function() end,
    setVisible = function() end,
  }
  panel = {
    render = function(tree) lastTree = tree end,
    close = function() end,
  }

  -- UI entries share this process's globals; load them after service tests.
  dofile(ROOT .. "/reader.luau")
  dofile(ROOT .. "/desktop.luau")
  check(lastTree ~= nil and lastTree.type == "column", "desktop widget should render a column")
  check(#lastTree.children >= 3, "desktop widget should render name, topic and statement")
  check(lastTree.props.onClick == "onOpenReader",
    "the whole card should open the full reader when clicked")

  local previousTree = lastTree
  state.emit("mathdiscovery.view", "{not valid json")
  check(lastTree == previousTree, "malformed view blob must not trigger a rerender")

  local empty = { status = "empty", revision = 999, animations = false }
  state.emit("mathdiscovery.view", json.encode(empty))
  check(lastTree ~= previousTree, "empty view should rerender with a fallback message")

  -- Stop the service from reacting to the UI command while testing handlers.
  watchers["mathdiscovery.cmd"] = {}
  values["mathdiscovery.cmd"] = nil
  state.emit("mathdiscovery.view", json.encode(view()))
  onNext()
  local command = tostring(values["mathdiscovery.cmd"] or "")
  check(command:find("|next|", 1, true) ~= nil,
    "onNext should send a next command: " .. command)

  onFavorite()
  check(tostring(values["mathdiscovery.cmd"]):find("|favorite|", 1, true),
    "onFavorite should send a favourite command")
  onOpenReference()
  onCopyLatex()
end

print(string.format("OK: %d runtime checks passed", checkCount))
print("     rotation, history, favourites, persistence, catch-up, sources, UI fallbacks")
