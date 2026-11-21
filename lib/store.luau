--!nonstrict
-- Durable key/value files in Noctalia's per-plugin data directory.
--
-- noctalia.state is in-memory only and disappears on shell restart, so history,
-- favourites and the source cache are written here. Writes go through a temp
-- file + rename so a crash cannot leave a half-written JSON document.

local model = require("./model.luau")

local M = {}

local STATE_FILE = "state.json"
local SOURCES_FILE = "sources.json"

local dirCache = nil

function M.dir()
  if dirCache then return dirCache end
  local dir, err = noctalia.pluginDataDir()
  if not dir then
    noctalia.log("Math Discovery: cannot open data directory: " .. tostring(err))
    return nil
  end
  dirCache = dir
  return dir
end

function M.path(name)
  local dir = M.dir()
  if not dir then return nil end
  return dir .. "/" .. name
end

function M.load(name, fallback)
  local path = M.path(name)
  if not path then return fallback end
  local raw = noctalia.readFile(path)
  if not raw then return fallback end
  local value, err = model.decode(raw)
  if not value or type(value) ~= "table" then
    noctalia.log("Math Discovery: ignoring malformed " .. name .. ": " .. tostring(err))
    return fallback
  end
  return value
end

function M.save(name, value)
  local path = M.path(name)
  if not path then return false end
  local encoded, err = model.encode(value)
  if not encoded then
    noctalia.log("Math Discovery: cannot encode " .. name .. ": " .. tostring(err))
    return false
  end
  local tmp = path .. ".tmp"
  local ok, writeErr = noctalia.writeFile(tmp, encoded)
  if not ok then
    noctalia.log("Math Discovery: cannot write " .. name .. ": " .. tostring(writeErr))
    return false
  end
  local renamed, renameErr = noctalia.renameFile(tmp, path)
  if not renamed then
    noctalia.log("Math Discovery: cannot commit " .. name .. ": " .. tostring(renameErr))
    return false
  end
  return true
end

function M.loadState()  return M.load(STATE_FILE,  {}) end
function M.saveState(v) return M.save(STATE_FILE,  v) end
function M.loadSources() return M.load(SOURCES_FILE, {}) end
function M.saveSources(v) return M.save(SOURCES_FILE, v) end

return M
