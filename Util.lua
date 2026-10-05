-- DuoQuest: shared helpers (compatibility shims, event dispatcher, encoding, text).
local ADDON_NAME, ns = ...
ns.name = ADDON_NAME
-- One source for the version: the .toc, where the packager writes the release tag
-- ("v1.2.0" is shown and sent as "1.2.0"). Running from source it's still the
-- "@project-version@" token, so it's "dev". (Sync compatibility goes by the
-- protocol number; the version only feeds the "update" notes and /dq check.)
do
  local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  local ok, v = pcall(get or error, ADDON_NAME, "Version")
  ns.VERSION = ok and type(v) == "string" and v:match("^v?(%d+%.%d+[%w%.%-]*)$") or "dev"
end

---------------------------------------------------------------------------
-- Compatibility
---------------------------------------------------------------------------
-- Forever runs Midnight's addon restrictions: some values come back "secret" and
-- throw if compared or printed. plain() turns those into nil so callers just skip.
-- The secret check must come first: even `v == nil` on a secret value throws.
local issecret = issecretvalue or function() return false end
function ns.plain(v)
  if issecret(v) then return nil end
  return v
end

-- Vulcan Suite accent ("ember"), shared by all four add-ons: chat name, titles, borders.
ns.ACCENT = { 0.91, 0.47, 0.17 }
ns.ACCENT_CODE = "|cffe8792b"
local CHAT_TAG = ns.ACCENT_CODE .. "DuoQuest|r: "
function ns.Print(msg)
  print(CHAT_TAG .. tostring(msg))
end

---------------------------------------------------------------------------
-- Internal callbacks (UI, warnings and sync listen to these)
---------------------------------------------------------------------------
local callbacks = {}
function ns.Listen(name, fn)
  callbacks[name] = callbacks[name] or {}
  table.insert(callbacks[name], fn)
end

local errorsShown, errorCount = {}, 0
local function ReportError(where, err)
  err = tostring(err)
  if errorsShown[err] or errorCount >= 5 then return end
  errorsShown[err] = true
  errorCount = errorCount + 1
  ns.Print("error in " .. where .. ": " .. err)
end
ns.ReportError = ReportError

-- One failing listener must not stop the others (a UI bug can't break sync).
function ns.Fire(name, ...)
  for _, fn in ipairs(callbacks[name] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then ReportError(name, err) end
  end
end

---------------------------------------------------------------------------
-- Game event dispatcher (multiple listeners per event, errors reported once)
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}

function ns.On(event, fn)
  if not handlers[event] then
    handlers[event] = {}
    -- Unknown events throw on some builds; skip them quietly.
    pcall(eventFrame.RegisterEvent, eventFrame, event)
  end
  table.insert(handlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
  for _, fn in ipairs(handlers[event] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then ReportError(event, err) end
  end
end)

-- A unit event for one unit only (e.g. your own casts), on its own frame so
-- the client never wakes us for everyone else's. Older clients without
-- RegisterUnitEvent get the plain event; handlers check the unit anyway.
function ns.OnUnit(event, unit, fn)
  local f = CreateFrame("Frame")
  local ok = f.RegisterUnitEvent and pcall(f.RegisterUnitEvent, f, event, unit)
  if not ok then pcall(f.RegisterEvent, f, event) end
  f:SetScript("OnEvent", function(_, _, ...)
    local fine, err = pcall(fn, ...)
    if not fine then ReportError(event, err) end
  end)
end

-- One clock for everything (sync queue, rescans, UI refresh): twice a second.
ns.TICK = 0.5
local tickCount = 0
C_Timer.NewTicker(ns.TICK, function()
  tickCount = tickCount + 1
  ns.tickCount = tickCount
  ns.Fire("TICK", tickCount)
end)

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------
-- Quest IDs go over the wire in base 36 (26180 -> "k78"): shorter messages,
-- fewer of them.
local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
function ns.To36(n)
  n = math.floor(tonumber(n) or 0)
  if n <= 0 then return "0" end
  local out = {}
  while n > 0 do
    local d = n % 36
    table.insert(out, 1, DIGITS:sub(d + 1, d + 1))
    n = math.floor(n / 36)
  end
  return table.concat(out)
end

function ns.From36(s)
  if type(s) ~= "string" or not s:match("^[0-9a-z]+$") or #s > 8 then return nil end
  return tonumber(s, 36)
end

---------------------------------------------------------------------------
-- Text
---------------------------------------------------------------------------
-- Cuts text to at most maxBytes without splitting a UTF-8 character.
function ns.Truncate(text, maxBytes)
  text = tostring(text or "")
  if #text <= maxBytes then return text end
  local out, used = {}, 0
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if used + #ch > maxBytes then break end
    out[#out + 1] = ch
    used = used + #ch
  end
  return table.concat(out)
end

-- Text that goes inside a sync message: no field separators, no escape codes,
-- no control characters, no spaces at the ends.
function ns.Clean(text)
  text = tostring(text or "")
  text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:]*:", ""):gsub("|r", "")  -- (colours, incl. named)
  text = text:gsub("|T.-|t", ""):gsub("|A.-|a", "")  -- (icons and atlas images)
  text = text:gsub("[|~^\r\n%c]", " "):gsub("%s+", " ")
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Clickable quest link for chat, from what we know about a quest.
function ns.QuestLink(questID, title, level)
  title = (title and title ~= "") and title or ("Quest #" .. tostring(questID))
  return string.format("|cffffff00|Hquest:%d:%d|h[%s]|h|r", questID, tonumber(level) or -1, title)
end

-- "a, b and c" (at most `max` names, then "and N more").
function ns.JoinList(items, max)
  max = max or #items
  local shown = {}
  for i = 1, math.min(#items, max) do shown[i] = items[i] end
  local extra = #items - #shown
  if extra > 0 then
    shown[#shown + 1] = extra .. " more"
  end
  if #shown <= 1 then return shown[1] or "" end
  return table.concat(shown, ", ", 1, #shown - 1) .. " and " .. shown[#shown]
end

function ns.Ago(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  if seconds < 60 then return seconds .. "s" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
  return math.floor(seconds / 3600) .. "h"
end

function ns.CopyDefaults(src, dst)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      ns.CopyDefaults(v, dst[k])
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
  return dst
end
