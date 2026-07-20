-- Minimal, dependency-free JSON encode/decode (Lua 5.4). Sufficient for config + save state.
-- Lenient decode: tolerates // line comments. Config defaults are baked in Lua, so a parse
-- failure is non-fatal (the loader falls back to defaults).
local M = {}

--------------------------------------------------------------------- decode
local decode_value

local function skip_ws(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return (j or (i - 1)) + 1
end

local esc = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local function utf8_encode(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
  end
  return string.char(0xE0 + math.floor(cp / 0x1000),
                     0x80 + (math.floor(cp / 0x40) % 0x40),
                     0x80 + (cp % 0x40))
end

local function decode_string(s, i)
  i = i + 1
  local buf = {}
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(buf), i + 1
    elseif c == '\\' then
      local e = s:sub(i + 1, i + 1)
      if e == 'u' then
        local cp = tonumber(s:sub(i + 2, i + 5), 16) or 0x3F
        buf[#buf + 1] = utf8_encode(cp)
        i = i + 6
      else
        buf[#buf + 1] = esc[e] or e
        i = i + 2
      end
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  error("unterminated string")
end

local function decode_number(s, i)
  local a, b = s:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
  local n = tonumber(s:sub(a, b))
  if not n then error("invalid number at " .. i) end
  return n, b + 1
end

local function decode_array(s, i)
  i = skip_ws(s, i + 1)
  local arr, n = {}, 0
  if s:sub(i, i) == ']' then return arr, i + 1 end
  while true do
    local v
    v, i = decode_value(s, i)
    n = n + 1
    arr[n] = v            -- explicit index preserves position across JSON null holes
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == ',' then i = skip_ws(s, i + 1)
    elseif c == ']' then return arr, i + 1
    else error("expected ',' or ']' at " .. i) end
  end
end

local function decode_object(s, i)
  i = skip_ws(s, i + 1)
  local obj = {}
  if s:sub(i, i) == '}' then return obj, i + 1 end
  while true do
    if s:sub(i, i) ~= '"' then error("expected key at " .. i) end
    local key
    key, i = decode_string(s, i)
    i = skip_ws(s, i)
    if s:sub(i, i) ~= ':' then error("expected ':' at " .. i) end
    local v
    v, i = decode_value(s, skip_ws(s, i + 1))
    obj[key] = v
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == ',' then i = skip_ws(s, i + 1)
    elseif c == '}' then return obj, i + 1
    else error("expected ',' or '}' at " .. i) end
  end
end

decode_value = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == '{' then return decode_object(s, i) end
  if c == '[' then return decode_array(s, i) end
  if c == '"' then return decode_string(s, i) end
  if c == 't' and s:sub(i, i + 3) == 'true'  then return true, i + 4 end
  if c == 'f' and s:sub(i, i + 4) == 'false' then return false, i + 5 end
  if c == 'n' and s:sub(i, i + 3) == 'null'  then return nil, i + 4 end
  if c:match("[%-%d]") then return decode_number(s, i) end
  error("unexpected char '" .. c .. "' at " .. i)
end

function M.decode(s)
  assert(type(s) == "string", "json.decode expects a string")
  s = s:gsub("//[^\n\r]*", "")
  local v = decode_value(s, 1)
  return v
end

--------------------------------------------------------------------- encode
local encode_value

local function encode_string(v)
  return '"' .. v:gsub('[%z\1-\31\\"]', function(ch)
    local m = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r',
                ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f' }
    return m[ch] or string.format("\\u%04x", ch:byte())
  end) .. '"'
end

encode_value = function(v, out, indent, depth)
  local t = type(v)
  if t == "nil" then
    out[#out + 1] = "null"
  elseif t == "boolean" then
    out[#out + 1] = tostring(v)
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
    else out[#out + 1] = string.format("%.14g", v) end
  elseif t == "string" then
    out[#out + 1] = encode_string(v)
  elseif t == "table" then
    local n, isArray = 0, true
    for k in pairs(v) do
      n = n + 1
      if type(k) ~= "number" then isArray = false end
    end
    local nl  = indent and "\n" or ""
    local pad = indent and string.rep(indent, depth + 1) or ""
    local end_pad = indent and string.rep(indent, depth) or ""
    if isArray then
      if n == 0 then out[#out + 1] = "[]"; return end
      out[#out + 1] = "[" .. nl
      for idx = 1, #v do
        out[#out + 1] = pad
        encode_value(v[idx], out, indent, depth + 1)
        out[#out + 1] = (idx < #v and "," or "") .. nl
      end
      out[#out + 1] = end_pad .. "]"
    else
      if n == 0 then out[#out + 1] = "{}"; return end
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      out[#out + 1] = "{" .. nl
      for i, k in ipairs(keys) do
        out[#out + 1] = pad .. encode_string(tostring(k)) .. ":" .. (indent and " " or "")
        encode_value(v[k], out, indent, depth + 1)
        out[#out + 1] = (i < #keys and "," or "") .. nl
      end
      out[#out + 1] = end_pad .. "}"
    end
  else
    out[#out + 1] = "null"
  end
end

function M.encode(v, pretty)
  local out = {}
  encode_value(v, out, pretty and "  " or nil, 0)
  return table.concat(out)
end

return M
