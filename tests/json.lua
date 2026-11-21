-- Minimal JSON codec used only by the offline runtime test harness.
-- It is intentionally small and dependency-free; Noctalia supplies the real
-- codec in production. Supports objects, arrays, strings (incl. \\u escapes),
-- numbers, booleans and null.

local M = {}

local function utf8Char(code)
  if code < 0x80 then return string.char(code) end
  if code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
  end
  if code < 0x10000 then
    return string.char(0xE0 + math.floor(code / 0x1000),
      0x80 + math.floor((code % 0x1000) / 0x40), 0x80 + code % 0x40)
  end
  return string.char(0xF0 + math.floor(code / 0x40000),
    0x80 + math.floor((code % 0x40000) / 0x1000),
    0x80 + math.floor((code % 0x1000) / 0x40), 0x80 + code % 0x40)
end

local function skip(text, index)
  while index <= #text and text:sub(index, index):match("%s") do index = index + 1 end
  return index
end

local function fail(text, index, message)
  error(string.format("%s at byte %d near %q", message, index, text:sub(index, index + 24)), 0)
end

local parseValue

local function parseString(text, index)
  if text:sub(index, index) ~= '"' then fail(text, index, "expected string") end
  index = index + 1
  local out = {}
  while index <= #text do
    local char = text:sub(index, index)
    if char == '"' then return table.concat(out), index + 1 end
    if char == "\\" then
      local escape = text:sub(index + 1, index + 1)
      local simple = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
        b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
      if simple[escape] then
        out[#out + 1] = simple[escape]
        index = index + 2
      elseif escape == "u" then
        local hex = text:sub(index + 2, index + 5)
        if not hex:match("^%x%x%x%x$") then fail(text, index, "bad unicode escape") end
        out[#out + 1] = utf8Char(tonumber(hex, 16))
        index = index + 6
      else
        fail(text, index, "bad escape")
      end
    else
      out[#out + 1] = char
      index = index + 1
    end
  end
  fail(text, index, "unterminated string")
end

local function parseObject(text, index)
  local out = {}
  index = skip(text, index + 1)
  if text:sub(index, index) == "}" then return out, index + 1 end
  while true do
    local key
    key, index = parseString(text, index)
    index = skip(text, index)
    if text:sub(index, index) ~= ":" then fail(text, index, "expected ':'") end
    index = skip(text, index + 1)
    out[key], index = parseValue(text, index)
    index = skip(text, index)
    local char = text:sub(index, index)
    if char == "," then
      index = skip(text, index + 1)
    elseif char == "}" then
      return out, index + 1
    else
      fail(text, index, "expected ',' or '}'")
    end
  end
end

local function parseArray(text, index)
  local out = {}
  index = skip(text, index + 1)
  if text:sub(index, index) == "]" then return out, index + 1 end
  while true do
    local value
    value, index = parseValue(text, index)
    out[#out + 1] = value
    index = skip(text, index)
    local char = text:sub(index, index)
    if char == "," then
      index = skip(text, index + 1)
    elseif char == "]" then
      return out, index + 1
    else
      fail(text, index, "expected ',' or ']'")
    end
  end
end

parseValue = function(text, index)
  index = skip(text, index)
  local char = text:sub(index, index)
  if char == "{" then return parseObject(text, index) end
  if char == "[" then return parseArray(text, index) end
  if char == '"' then return parseString(text, index) end
  if text:sub(index, index + 3) == "true" then return true, index + 4 end
  if text:sub(index, index + 4) == "false" then return false, index + 5 end
  if text:sub(index, index + 3) == "null" then return nil, index + 4 end
  local number = text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", index)
  if number then
    local value = tonumber(number)
    if value then return value, index + #number end
  end
  fail(text, index, "unexpected character")
end

function M.decode(text)
  if type(text) ~= "string" then return nil, "not a string" end
  local ok, value, index = pcall(function()
    local parsed, nextIndex = parseValue(text, 1)
    return parsed, nextIndex
  end)
  if not ok then return nil, tostring(value) end
  if skip(text, index) <= #text then return nil, "trailing data" end
  return value, nil
end

local ESCAPES = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encodeString(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
    return ESCAPES[char] or string.format("\\u%04x", char:byte())
  end) .. '"'
end

local function isArray(value)
  return #value > 0 or next(value) == nil
end

local function encodeValue(value, out)
  if value == nil then
    out[#out + 1] = "null"
  elseif type(value) == "string" then
    out[#out + 1] = encodeString(value)
  elseif type(value) == "number" then
    out[#out + 1] = string.format("%.14g", value)
  elseif type(value) == "boolean" then
    out[#out + 1] = value and "true" or "false"
  elseif type(value) == "table" then
    if isArray(value) then
      out[#out + 1] = "["
      for index = 1, #value do
        if index > 1 then out[#out + 1] = "," end
        encodeValue(value[index], out)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for key in pairs(value) do
        if type(key) == "string" then keys[#keys + 1] = key end
      end
      table.sort(keys)
      out[#out + 1] = "{"
      for index, key in ipairs(keys) do
        if index > 1 then out[#out + 1] = "," end
        out[#out + 1] = encodeString(key)
        out[#out + 1] = ":"
        encodeValue(value[key], out)
      end
      out[#out + 1] = "}"
    end
  else
    error("cannot encode " .. type(value))
  end
end

function M.encode(value, _pretty)
  local out = {}
  encodeValue(value, out)
  return table.concat(out)
end

return M
