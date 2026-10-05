-- DuoQuest: saved-data safety (Vulcan Suite).
--
-- REMOVE WHEN FIXED. The World of Warcraft: Forever client has been reported to
-- write add-on saved data to disk but not load it back, and then overwrite the
-- good file at the next logout or /reload. Add-ons can't read or write files, so
-- this module does what is possible from inside the game: it spots a failed load
-- and warns instead of quietly starting from defaults.
--
-- DuoQuest keeps everything per character (VulcanDuoQuestCharDB), so a second,
-- account-wide file (VulcanDuoQuestDB) holds just the list of characters that
-- have saved data. A character on that list whose file comes back empty didn't
-- load. (A registered CVar would make a better marker, but on client build 70205
-- registered CVars come back empty after a full restart. If both files fail at
-- once, it looks like a first install and can't be told apart.)
--
-- To retire it: delete this file, its TOC line and the "## SavedVariables:" line.
-- Core.lua and Commands.lua only reach it through `ns.Persist` guards.
local _, ns = ...
local P = {}
ns.Persist = P

local MAX_CHARS = 200  -- characters remembered for the cross-check

-- This character's key, only when the realm is known: a bare name could match a
-- same-named character on another realm.
local function CharKey()
  local name = UnitName and ns.plain(UnitName("player"))
  local realm = GetNormalizedRealmName and ns.plain(GetNormalizedRealmName())
  if type(name) ~= "string" or name == "" or type(realm) ~= "string" or realm == "" then return nil end
  return name .. "-" .. realm
end
P.CharKey = CharKey

-- Called by Core.lua with the raw saved globals, before defaults fill them in.
-- The character check needs this character's realm, which can be unreadable while the
-- game is still loading. Then CheckLoad leaves P.charCheck (the list it loaded) and the
-- check runs again at PLAYER_LOGIN.
local function KeySet(list)
  if type(list) ~= "table" then return nil end
  local out = {}
  for k in pairs(list) do if type(k) == "string" then out[k] = true end end
  return out
end
function P.CheckLoad(rawMarker, rawChar)
  local key = CharKey()
  P.charCheck = type(rawChar) ~= "table" and type(rawMarker) == "table" and KeySet(rawMarker.chars) or nil
  local failed = P.charCheck ~= nil and key ~= nil and P.charCheck[key] == true
  if key then P.charCheck = nil end
  P.failure = failed and { char = true } or nil
  return P.failure
end

-- Written at logout, just before the client saves.
local function WriteMarkers()
  local key = CharKey()
  if not key or type(VulcanDuoQuestCharDB) ~= "table" then return end
  if type(VulcanDuoQuestDB) ~= "table" then VulcanDuoQuestDB = {} end
  local db = VulcanDuoQuestDB
  if type(db.chars) ~= "table" then db.chars = {} end
  db.chars[key] = time()
  local keys = {}
  for k, v in pairs(db.chars) do
    if type(k) ~= "string" or type(v) ~= "number" then db.chars[k] = nil else keys[#keys + 1] = k end
  end
  if #keys > MAX_CHARS then  -- forget the characters not seen for longest
    table.sort(keys, function(a, b) return db.chars[a] < db.chars[b] end)
    for i = 1, #keys - MAX_CHARS do db.chars[keys[i]] = nil end
  end
end
ns.On("PLAYER_LOGOUT", WriteMarkers)

function P.WarningLines()
  return {
    "|cffff4040this character's saved data didn't load.|r This is a known problem with the World of Warcraft: "
      .. "Forever client: add-on data is written to disk but sometimes not loaded back.",
    "Your file on disk is probably still fine, but the game will overwrite it the next time you log out or "
      .. "/reload. It holds this character's DuoQuest settings: window position, ignored quests and partner.",
    "To keep it: before you log out or /reload, Alt-Tab out and copy "
      .. "WTF\\Account\\<your account>\\<realm>\\<character>\\SavedVariables\\VulcanDuoQuest.lua somewhere "
      .. "safe. Exit the game fully, copy it back over the new one, and start again.",
    "Until then DuoQuest works normally with default settings.",
  }
end

function P.ShowWarning()
  if not P.failure then return end
  for _, line in ipairs(P.WarningLines()) do ns.Print(line) end
  if UIErrorsFrame and UIErrorsFrame.AddMessage then
    pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, "DuoQuest: saved data didn't load - see chat", 1, 0.25, 0.25)
  end
end
ns.Listen("READY", P.ShowWarning)

ns.On("PLAYER_LOGIN", function()
  local pending, key = P.charCheck, CharKey()
  P.charCheck = nil
  if not (pending and key and pending[key]) then return end
  P.failure = { char = true }
  P.ShowWarning()
end)

function P.CheckLine()
  if not P.failure then return "saved data: loaded normally" end
  return "saved data: |cffff4040didn't load this session|r (see the chat message from login)"
end
