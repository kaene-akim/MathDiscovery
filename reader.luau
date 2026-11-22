--!nonstrict
-- Mathematical Discovery — [[panel]] reader entry.
--
-- The complete, scrollable view of the current fact. The desktop card is the
-- primary interface; this panel is where long equations, full explanations and
-- proof sketches are shown without any truncation. It is opened with the
-- widget's "Read" button or `noctalia msg panel-toggle akim/math-discovery:reader`.

local VIEW_KEY = "mathdiscovery.view"
local CMD_KEY  = "mathdiscovery.cmd"

local view = nil
local clickCounter = 0

local function sendCommand(action)
  clickCounter = (clickCounter + 1) % 10
  local seq = math.floor(noctalia.nowMs()) * 10 + clickCounter
  noctalia.state.set(CMD_KEY, tostring(seq) .. "|" .. action .. "|")
end

function modelDecode(value)
  if type(value) ~= "string" then return nil, "not a string" end
  local ok, decoded, err = pcall(noctalia.json.decode, value)
  if not ok then return nil, tostring(decoded) end
  if type(decoded) ~= "table" then return nil, err or "not a table" end
  return decoded, nil
end

local function section(title, text, color, fontSize)
  if not text or text == "" then return nil end
  return ui.column({ gap = 6 }, {
    ui.label({ text = title, fontSize = 9, fontWeight = "bold", color = "primary" }),
    ui.label({ text = text, fontSize = fontSize or 12.5, color = color or "on_surface/0.82" }),
  })
end

local function openUrl(url)
  if type(url) ~= "string" then return end
  if not url:match("^https://") and not url:match("^http://") then return end
  if not noctalia.commandExists("xdg-open") then
    noctalia.notifyError("Mathematical Discovery", "xdg-open is not available.")
    return
  end
  noctalia.runAsync({ "xdg-open", url })
end

local function render()
  if not view or view.status == "empty" or view.status == "loading" then
    local message = "Loading the fact library…"
    if not view or view.status == "empty" then
      message = "No fact is available yet."
    end
    panel.render(ui.column({ padding = 24, gap = 12 }, {
      ui.label({ text = "MATHEMATICAL DISCOVERY", fontSize = 10,
        fontWeight = "bold", color = "primary" }),
      ui.label({ text = message, fontSize = 13, color = "on_surface/0.7" }),
      ui.button({ text = "Close", onClick = "onClosePanel" }),
    }))
    return
  end

  local fact = view.fact or {}
  local children = {}

  children[#children + 1] = ui.row({ gap = 12, align = "center" }, {
    ui.column({ gap = 3, flexGrow = 1 }, {
      ui.label({ text = "MATHEMATICAL DISCOVERY", fontSize = 9,
        fontWeight = "bold", color = "primary" }),
      ui.label({
        text = string.format("Fact %d of %d visited · %d in library",
          view.position or 0, view.visited or 0, view.librarySize or 0),
        fontSize = 10, color = "on_surface/0.45",
      }),
    }),
    ui.button({ text = "Close", variant = "ghost", controlSize = "sm",
      onClick = "onClosePanel" }),
  })
  children[#children + 1] = ui.separator({ thickness = 1, color = "outline_variant/0.5" })

  children[#children + 1] = ui.column({ gap = 5 }, {
    ui.label({
      text = (fact.domain or "Mathematics"):upper()
        .. "  /  " .. (fact.subject or "Mathematics"):upper()
        .. "  ·  " .. (fact.level or "") .. "  ·  " .. (fact.kindLabel or ""),
      fontSize = 10, fontWeight = "semibold", color = "secondary", maxLines = 2,
    }),
    ui.label({ text = fact.title or "Untitled", fontSize = 21,
      fontWeight = "semibold", color = "on_surface" }),
  })

  children[#children + 1] = ui.row({
    gap = 12, fill = "surface_container_high/0.55", radius = 4,
    padding = 14, align = "stretch",
  }, {
    ui.column({ width = 2, fill = "primary", radius = 1 }, {
      ui.spacer({ flexGrow = 1 }),
    }),
    ui.label({ text = fact.statement or "", fontSize = 15,
      color = "on_surface", flexGrow = 1 }),
  })

  if fact.latex and fact.latex ~= "" then
    children[#children + 1] = ui.column({ gap = 6 }, {
      ui.label({ text = "LATEX SOURCE", fontSize = 9, fontWeight = "bold",
        color = "primary" }),
      ui.label({ text = fact.latex, fontSize = 12, color = "on_surface/0.8" }),
    })
  end

  local explanation = section("EXPLANATION", fact.long, "on_surface/0.85", 13)
  if explanation then children[#children + 1] = explanation end
  local proof = section("PROOF IDEA", fact.proof)
  if proof then children[#children + 1] = proof end
  local consequence = section("WHY IT MATTERS", fact.consequence)
  if consequence then children[#children + 1] = consequence end

  if fact.prerequisites and #fact.prerequisites > 0 then
    children[#children + 1] = ui.column({ gap = 6 }, {
      ui.label({ text = "PREREQUISITES", fontSize = 9, fontWeight = "bold",
        color = "primary" }),
      ui.label({ text = table.concat(fact.prerequisites, "   ·   "),
        fontSize = 12, color = "on_surface/0.7" }),
    })
  end

  children[#children + 1] = ui.separator({ thickness = 1, color = "outline_variant/0.4" })

  local sourceText = "Source: " .. (fact.sourceName or "Curated library")
  if fact.retrieved and fact.retrieved ~= "" then
    sourceText = sourceText .. " · retrieved " .. fact.retrieved
  end
  children[#children + 1] = ui.label({ text = sourceText, fontSize = 10,
    color = "on_surface/0.5" })

  if view.reference then
    children[#children + 1] = ui.column({
      gap = 6, fill = "surface_container/0.6", radius = 4, padding = 12,
    }, {
      ui.label({ text = "REFERENCE NOTE · " .. (view.reference.sourceName or "Wikipedia")
        .. (view.reference.retrievedAtMs and (" · " .. os.date("%Y-%m-%d",
          math.floor(view.reference.retrievedAtMs / 1000))) or ""),
        fontSize = 9, fontWeight = "bold", color = "primary" }),
      ui.label({ text = view.reference.excerpt or "", fontSize = 11,
        color = "on_surface/0.7" }),
      ui.button({ text = view.reference.title or "Open reference",
        variant = "ghost", controlSize = "sm", onClick = "onOpenReference" }),
    })
  end

  if view.reading then
    children[#children + 1] = ui.column({ gap = 4 }, {
      ui.label({ text = "FROM " .. (view.reading.sourceName or "the wider community")
        :upper() .. " · metadata only",
        fontSize = 9, fontWeight = "bold", color = "primary" }),
      ui.button({ text = view.reading.title or "Open article", variant = "ghost",
        controlSize = "sm", onClick = "onOpenReading" }),
    })
  end

  children[#children + 1] = ui.row({ gap = 6, align = "center",
    justify = "space_between" }, {
    ui.button({ text = "←", variant = "ghost", controlSize = "sm",
      onClick = "onPrevPanel", enabled = view.canPrev == true }),
    ui.button({ text = "→", variant = "ghost", controlSize = "sm",
      onClick = "onNextPanel" }),
    ui.button({ text = view.favorite and "★ Saved" or "☆ Save",
      variant = "ghost", controlSize = "sm", onClick = "onFavoritePanel" }),
    ui.button({ text = "Copy LaTeX", variant = "ghost", controlSize = "sm",
      onClick = "onCopyLatex", enabled = (fact.latex or "") ~= "" }),
    ui.button({ text = "Source ↗", variant = "secondary", controlSize = "sm",
      onClick = "onOpenSourcePanel", enabled = (fact.sourceUrl or "") ~= "" }),
  })

  panel.render(ui.scroll({ flexGrow = 1, padding = 20, gap = 14,
    fill = "surface/0.92" }, children))
end

function onOpen(_context)
  local initial = noctalia.state.get(VIEW_KEY)
  if type(initial) == "string" then
    local decoded = modelDecode(initial)
    if decoded then view = decoded end
  end
  render()
end

noctalia.state.watch(VIEW_KEY, function(value)
  local decoded, err = modelDecode(value)
  if not decoded then
    noctalia.log("Math Discovery reader: bad view: " .. tostring(err))
    return
  end
  view = decoded
  render()
end)

function onClosePanel() panel.close() end
function onNextPanel()  sendCommand("next") end
function onPrevPanel()  sendCommand("prev") end
function onFavoritePanel() sendCommand("favorite") end

function onCopyLatex()
  local latex = view and view.fact and view.fact.latex or ""
  if latex == "" then return end
  noctalia.copyToClipboard(latex, "text/plain")
  noctalia.notify("Mathematical Discovery", "LaTeX source copied to clipboard.")
end

function onOpenSourcePanel()
  openUrl(view and view.fact and view.fact.sourceUrl)
end

function onOpenReference()
  openUrl(view and view.reference and view.reference.url)
end

function onOpenReading()
  openUrl(view and view.reading and view.reading.url)
end
