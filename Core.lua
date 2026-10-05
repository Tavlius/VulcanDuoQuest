-- DuoQuest: saved settings, startup, and the diagnostics switch.
-- Display-only: it reads your quest log and shows it to your partner. The only
-- thing it ever does in the game is share a quest, and only when you click
-- Share (or press its key binding / type /dq share).
local _, ns = ...
local plain = ns.plain

---------------------------------------------------------------------------
-- Saved settings. Per character on purpose: an unverified beta report says
-- account-wide SavedVariables aren't read back on client 1.60 (see the Duo
-- Addon Ideas doc). Nothing here is worth sharing between characters anyway.
---------------------------------------------------------------------------
ns.DB_VERSION = 2
-- (Clear of the party frames down the left edge, which appear when the window does.)
ns.DEFAULT_POINT = { "TOPLEFT", "TOPLEFT", 260, -220 }
local OLD_DEFAULT = { "TOPLEFT", "TOPLEFT", 40, -200 }  -- 1.1 test builds: on top of the party frames

local DEFAULTS = {
  version = ns.DB_VERSION,
  shown = true,          -- window wanted (it still hides while solo, see hideSolo)
  locked = false,        -- window can't be dragged
  point = ns.DEFAULT_POINT,
  sync = true,           -- talk to your partner's DuoQuest
  warnLeave = true,      -- warn when leaving town / flying / hearthing with fresh quest gaps
  notify = true,         -- chat notes when your partner picks up / finishes quests
  sound = true,          -- a soft sound with the leave warning
  objectives = true,     -- show objective lines for quests you share
  hideSolo = true,       -- hide the window while there's nobody to compare with (not grouped, or a pug)
  focus = nil,           -- partner shown in the window (nil = automatic)
  collapsed = { theyDid = true, iDid = true },  -- [section key] = true
  ignored = {},          -- [questID] = true: never warned or noted about
  knownQuests = {},      -- quest IDs in your log at the last scan (finds quests under collapsed headers)
  seenAt = {},           -- [questID] = time() you picked it up (for "picked up at this hub")
  awayMine = {},         -- [questID] = true: picked up while your partner was elsewhere
  lastPartner = nil,     -- the partner shown automatically last time (kept across reloads)
  hub = nil,             -- where you are (Warn.lua), kept across a /reload or a quick relog
  told = {},             -- [questID] = true: gaps already in a leave warning (Warn.lua)
  partnerSeen = {},      -- [partner key] = { seenAt, near, met, at }: their pickups, kept across reloads (Sync.lua)
  welcomed = false,
  debug = false,
}

local function LoadSavedData()
  -- Saved-data safety (Persist.lua): look at what the client loaded before defaults fill it in.
  if ns.Persist then ns.Persist.CheckLoad(VulcanDuoQuestDB, VulcanDuoQuestCharDB) end
  local db = type(VulcanDuoQuestCharDB) == "table" and VulcanDuoQuestCharDB or {}
  if (db.version or 1) < 2 then
    db.point = nil      -- v1 anchored the window by its center; v2 by its top left
    db.version = ns.DB_VERSION
  end
  local p = db.point
  if type(p) == "table" and p[1] == OLD_DEFAULT[1] and p[2] == OLD_DEFAULT[2] and p[3] == OLD_DEFAULT[3]
      and p[4] == OLD_DEFAULT[4] then
    db.point = nil  -- (never moved from the old default spot: use the new one)
  end
  VulcanDuoQuestCharDB = ns.CopyDefaults(DEFAULTS, db)
  ns.DB = VulcanDuoQuestCharDB
end

ns.On("ADDON_LOADED", function(name)
  if plain(name) ~= ns.name then return end
  LoadSavedData()
  ns.Fire("READY")
end)

ns.On("PLAYER_LOGIN", function()
  ns.DuoCore.Me()  -- cache our name while it's readable (echo filter)
  ns.loginAt = GetTime()
  ns.Fire("LOGIN")
  if ns.DB and not ns.DB.welcomed then
    ns.DB.welcomed = true
    ns.Print("loaded. Group up with a partner who runs DuoQuest too; /dq help lists commands.")
  end
end)

---------------------------------------------------------------------------
-- Diagnostics: /dq debug prints every sync message sent and received.
---------------------------------------------------------------------------
function ns.Debug(kind, text)
  if ns.DB and ns.DB.debug then
    print("|cff888888DuoQuest " .. kind .. "|r " .. (tostring(text):gsub("|", "||")))
  end
end
