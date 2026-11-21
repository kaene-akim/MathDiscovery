--!nonstrict
-- Pluggable supplementary source adapters.
--
-- Design rules:
--   * Only the curated local library produces displayed facts.
--   * Network adapters fetch small, openly-licensed metadata (article extracts,
--     RSS titles/links, API question titles) and are labelled with source name,
--     link and retrieval time. No article bodies, no code, no scraping of pages.
--   * One request per source per cadence, with exponential backoff on failure.
--   * Adding a source means adding one adapter to M.adapters; the fetch loop,
--     caching and UI rendering are source-agnostic.

local model = require("./model.luau")

local M = {}

local USER_AGENT = "NoctaliaMathDiscovery/1.0 (plugin; reference metadata only)"

local ENTITIES = {
  amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
  nbsp = " ", mdash = "—", ndash = "–", lsquo = "‘", rsquo = "’",
  ldquo = "“", rdquo = "”", hellip = "…", copy = "©",
}

local function utf8Char(code)
  if code < 0 or code > 0x10FFFF then return "" end
  if code < 0x80 then return string.char(code) end
  if code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40),
      0x80 + (code % 0x40))
  end
  if code < 0x10000 then
    return string.char(0xE0 + math.floor(code / 0x1000),
      0x80 + math.floor((code % 0x1000) / 0x40),
      0x80 + (code % 0x40))
  end
  return string.char(0xF0 + math.floor(code / 0x40000),
    0x80 + math.floor((code % 0x40000) / 0x1000),
    0x80 + math.floor((code % 0x1000) / 0x40),
    0x80 + (code % 0x40))
end

local function unescape(text)
  text = text:gsub("&#x(%x+);", function(hex)
    local code = tonumber(hex, 16)
    return code and utf8Char(code) or ("&#x" .. hex .. ";")
  end)
  text = text:gsub("&#(%d+);", function(dec)
    local code = tonumber(dec)
    return code and utf8Char(code) or ("&#" .. dec .. ";")
  end)
  text = text:gsub("&([%a]+);", function(name) return ENTITIES[name] or ("&" .. name .. ";") end)
  return text
end

local function stripTags(text)
  text = text:gsub("<!%[CDATA%[(.-)%]%]>", "%1")
  text = text:gsub("<[^>]+>", " ")
  return model.oneLine(unescape(text))
end

local function httpText(url, headers, done)
  local request = {
    url = url,
    method = "GET",
    follow_redirects = true,
    headers = headers or {
      "Accept: */*",
      "User-Agent: " .. USER_AGENT,
    },
  }
  local accepted = noctalia.http(request, function(response)
    -- response.ok means the transport worked; the HTTP status is separate.
    if not response or not response.ok then
      done(nil, "transport failure: " .. tostring(response and response.status or "no response"))
      return
    end
    local status = tonumber(response.status) or 0
    if status < 200 or status > 299 then
      done(nil, "HTTP " .. tostring(status))
      return
    end
    if type(response.body) ~= "string" then
      done(nil, "empty response body")
      return
    end
    done(response.body, nil)
  end)
  if not accepted then done(nil, "request rejected (offline mode?)") end
end

local function httpJson(url, done, headers)
  httpText(url, headers, function(body, err)
    if not body then done(nil, err) return end
    local value, decodeErr = model.decode(body)
    if not value then done(nil, decodeErr) return end
    done(value, nil)
  end)
end

local function record(sourceId, sourceName, title, url, excerpt, kind, wikiTitle, retrievedAtMs)
  return {
    sourceId = sourceId,
    sourceName = sourceName,
    title = model.oneLine(title, 160),
    url = url,
    excerpt = model.oneLine(excerpt, 260),
    kind = kind,
    wikiTitle = wikiTitle or "",
    retrievedAtMs = retrievedAtMs or noctalia.nowMs(),
  }
end

-- --- Adapters --------------------------------------------------------------

local wikipedia = {
  id = "wikipedia",
  name = "Wikipedia",
  network = true,
  fetch = function(ctx, done)
    local titles = {}
    for _, title in ipairs(ctx.titles or {}) do
      if title ~= "" and #titles < 6 then titles[#titles + 1] = title end
    end
    if #titles == 0 then done({}, nil) return end

    local url = "https://en.wikipedia.org/w/api.php?action=query&format=json"
      .. "&redirects=1&prop=extracts&exintro=1&explaintext=1&exsentences=2"
      .. "&titles=" .. noctalia.string.urlEncode(table.concat(titles, "|"))

    httpJson(url, function(data, err)
      if not data then done(nil, err) return end
      local pages = data.query and data.query.pages
      if type(pages) ~= "table" then done(nil, "no pages in response") return end
      local out = {}
      local now = noctalia.nowMs()
      for _, page in pairs(pages) do
        if type(page) == "table" and page.title and type(page.extract) == "string"
          and page.extract ~= "" and not page.missing then
          local articleUrl = "https://en.wikipedia.org/wiki/"
            .. noctalia.string.urlEncode((page.title:gsub(" ", "_")))
          out[#out + 1] = record("wikipedia", "Wikipedia", page.title, articleUrl,
            page.extract, "reference", page.title, now)
        end
      end
      done(out, nil)
    end, {
      "Accept: application/json",
      "User-Agent: " .. USER_AGENT,
    })
  end,
}

local QUANTA_KEYWORDS = {
  "math", "number", "prime", "geometry", "proof", "theorem", "topolog",
  "symmetr", "graph", "comput", "algorithm", "infinity", "dimension",
  "chaos", "network", "quantum", "escher", "entropy", "code", "space",
}

local quanta = {
  id = "quanta",
  name = "Quanta Magazine",
  network = true,
  fetch = function(_ctx, done)
    httpText("https://www.quantamagazine.org/feed/", function(body, err)
      if not body then done(nil, err) return end
      local out = {}
      local fallback = {}
      local now = noctalia.nowMs()
      for item in body:gmatch("<item>(.-)</item>") do
        local title = stripTags(item:match("<title>(.-)</title>") or "")
        local link = stripTags(item:match("<link>(.-)</link>") or "")
        local description = stripTags(item:match("<description>(.-)</description>") or "")
        if title ~= "" and link:match("^https://") then
          local entry = record("quanta", "Quanta Magazine", title, link,
            description, "reading", nil, now)
          if #fallback < 2 then fallback[#fallback + 1] = entry end
          local lower = title:lower()
          for _, word in ipairs(QUANTA_KEYWORDS) do
            if lower:find(word, 1, true) then
              out[#out + 1] = entry
              break
            end
          end
        end
        if #out >= 5 then break end
      end
      if #out == 0 then out = fallback end
      done(out, nil)
    end)
  end,
}

local stackexchange = {
  id = "stackexchange",
  name = "Math Stack Exchange",
  network = true,
  fetch = function(ctx, done)
    local subject = ctx.subject or "mathematics"
    local url = "https://api.stackexchange.com/2.3/search/advanced?order=desc"
      .. "&sort=votes&pagesize=3&site=math&q=" .. noctalia.string.urlEncode(subject)
    httpJson(url, function(data, err)
      if not data then done(nil, err) return end
      if type(data.items) ~= "table" then done(nil, "no items in response") return end
      local out = {}
      local now = noctalia.nowMs()
      for _, item in ipairs(data.items) do
        if type(item) == "table" and type(item.link) == "string"
          and item.link:match("^https://") and type(item.title) == "string" then
          out[#out + 1] = record("stackexchange", "Math Stack Exchange",
            item.title, item.link, tostring(item.score or 0) .. " votes · "
            .. tostring(item.content_license or "CC BY-SA"), "discussion", nil, now)
        end
      end
      done(out, nil)
    end, {
      "Accept: application/json",
      "User-Agent: " .. USER_AGENT,
    })
  end,
}

M.adapters = { wikipedia, quanta, stackexchange }

-- --- Orchestration ---------------------------------------------------------

-- Fetch all due adapters sequentially. Returns a fresh state table; never
-- mutates the persisted snapshot in place, so a failed batch cannot corrupt it.
function M.fetchDue(sourceState, ctx, callback)
  local state = {
    lastFetch = {},
    failures = {},
    records = {},
  }
  for key, value in pairs(sourceState or {}) do
    if type(value) == "table" then
      state[key] = {}
      for k, v in pairs(value) do state[key][k] = v end
    else
      state[key] = value
    end
  end

  local now = noctalia.nowMs()
  local cadence = ctx.cadenceMs or (24 * 60 * 60 * 1000)
  local due = {}
  if ctx.enabled or ctx.force then
    for _, adapter in ipairs(M.adapters) do
      if ctx.force then
        due[#due + 1] = adapter
      else
        local last = tonumber(state.lastFetch[adapter.id]) or 0
        local failures = math.min(tonumber(state.failures[adapter.id]) or 0, 3)
        local backoff = cadence * (2 ^ failures)
        if now - last >= backoff then due[#due + 1] = adapter end
      end
    end
  end

  local changed = false

  local function step(index)
    if index > #due then
      callback(state, changed)
      return
    end
    local adapter = due[index]
    local ok, callResult = pcall(adapter.fetch, ctx, function(records, err)
      state.lastFetch[adapter.id] = noctalia.nowMs()
      if err or not records then
        state.failures[adapter.id] = (tonumber(state.failures[adapter.id]) or 0) + 1
        noctalia.log("Math Discovery: " .. adapter.id .. " source check failed: " .. tostring(err))
      else
        state.failures[adapter.id] = 0
        if #records > 0 then
          state.records[adapter.id] = records
          changed = true
        end
      end
      step(index + 1)
    end)
    if not ok then
      state.failures[adapter.id] = (tonumber(state.failures[adapter.id]) or 0) + 1
      noctalia.log("Math Discovery: " .. adapter.id .. " adapter error: " .. tostring(callResult))
      step(index + 1)
    end
  end

  step(1)
end

-- All cached records as one flat, newest-first array.
function M.allRecords(sourceState)
  local out = {}
  for _, adapter in ipairs(M.adapters) do
    for _, item in ipairs((sourceState or {}).records and sourceState.records[adapter.id] or {}) do
      out[#out + 1] = item
    end
  end
  table.sort(out, function(a, b) return (a.retrievedAtMs or 0) > (b.retrievedAtMs or 0) end)
  return out
end

-- A Wikipedia extract for exactly this fact's article, when it was fetched.
function M.referenceFor(fact, sourceState)
  if not fact or fact.wiki == "" then return nil end
  for _, item in ipairs(M.allRecords(sourceState)) do
    if item.kind == "reference" and item.wikiTitle
      and item.wikiTitle:lower() == fact.wiki:lower() then
      return item
    end
  end
  return nil
end

-- One general reading/discussion link for the compact card.
function M.latestReading(sourceState)
  for _, item in ipairs(M.allRecords(sourceState)) do
    if item.kind == "reading" or item.kind == "discussion" then return item end
  end
  return nil
end

return M
