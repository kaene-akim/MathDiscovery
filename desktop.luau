--!nonstrict
-- Mathematical Discovery — the main [[desktop_widget]] entry.
--
-- A compact, theme-aware card. The host owns its geometry and scales the tree
-- with the widget, so keep content naturally wrapping and comfortably short.

local VIEW_KEY = "mathdiscovery.view"
local CMD_KEY  = "mathdiscovery.cmd"
local READER_ID = "akim/math-discovery:reader"

-- Keep the bundled face: without it, this setup can fall back to the shell's
-- monospace font, which makes the card look cramped and degrades when scaled.
local SERIF = "Noto Serif"
if type(noctalia.loadFont) == "function" then
  local family = noctalia.loadFont("fonts/NotoSerif-Regular.ttf")
  if type(family) == "string" and family ~= "" then SERIF = family end
  noctalia.loadFont("fonts/NotoSerif-Bold.ttf")
end

local view = nil
local clickCounter = 0

local function sendCommand(action)
  clickCounter = (clickCounter + 1) % 10
  local seq = math.floor(noctalia.nowMs()) * 10 + clickCounter
  noctalia.state.set(CMD_KEY, tostring(seq) .. "|" .. action .. "|")
end

local function cardFill()
  local transparency = tonumber(noctalia.getConfig("card_transparency")) or 20
  if transparency < 0 then transparency = 0 end
  if transparency > 100 then transparency = 100 end
  return string.format("surface_container/%.2f", 1 - transparency / 100)
end

local function render()
  local rows = {}
  if not view or view.status == "empty" then
    rows[#rows + 1] = ui.label({
      text = (view and view.status == "empty")
        and "No facts were loaded. Check the plugin's data directory."
        or "Preparing the first discovery…",
      fontSize = 17, fontFamily = SERIF, color = "on_surface",
      maxLines = 3,
    })
  else
    local fact = view.fact or {}
    local title = fact.title or ""
    local topic = fact.subject or "Mathematics"
    local statement = fact.statement or ""

    -- 1. Theorem name, when the entry has one.
    if title ~= "" then
      rows[#rows + 1] = ui.label({
        text = title, fontSize = 26, fontWeight = "bold",
        fontFamily = SERIF, color = "on_surface", maxLines = 2,
      })
    end

    -- 2. Topic, picked from the live shell palette.
    rows[#rows + 1] = ui.label({
      text = topic, fontSize = 14, fontWeight = "semibold",
      fontFamily = SERIF, color = "primary", maxLines = 1,
    })

    -- 3. Keep the statement to a few lines so even a short widget stays
    -- balanced; the reader panel contains the complete statement.
    rows[#rows + 1] = ui.label({
      text = statement, fontSize = 18, fontFamily = SERIF,
      color = "on_surface", maxLines = 4,
    })
  end

  -- Theme tokens resolve against the active Noctalia palette, including when
  -- the system switches between light/dark or changes its accent colour.
  desktopWidget.render(ui.column({
    fill = cardFill(), radius = 2,
    border = "outline_variant/0.55",
    borderWidth = 1,
    padding = 12,
    gap = 6,
    clip = true,
    onClick = "onOpenReader",
  }, rows))
end

--- Commands kept for the shared runtime suite -------------------------------

function onNext()
  sendCommand("next")
end

function onPrev()
  sendCommand("prev")
end

function onFavorite()
  sendCommand("favorite")
end

function onOpenReader()
  noctalia.togglePanel(READER_ID)
end

function onOpenSource()
  -- No source button is drawn on the card; kept for API compatibility.
end

--- State subscription ------------------------------------------------------

function modelDecode(value)
  if type(value) ~= "string" then return nil, "not a string" end
  local ok, decoded, err = pcall(noctalia.json.decode, value)
  if not ok then return nil, tostring(decoded) end
  if type(decoded) ~= "table" then return nil, err or "not a table" end
  return decoded, nil
end

noctalia.state.watch(VIEW_KEY, function(value)
  local decoded, err = modelDecode(value)
  if not decoded then
    noctalia.log("Math Discovery widget: bad view: " .. tostring(err))
    return
  end
  view = decoded

  render()
end)

function update()
  noctalia.setUpdateInterval(60 * 1000)
end

local initial = noctalia.state.get(VIEW_KEY)
if type(initial) == "string" then
  local decoded = modelDecode(initial)
  if decoded then
    view = decoded
  end
end
render()
