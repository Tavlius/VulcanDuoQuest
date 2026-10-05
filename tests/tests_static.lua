-- Static checks: the .toc, Bindings.xml and README agree with the code.
package.path = assert(os.getenv("DQ_TESTS"), "DQ_TESTS unset: run tests/run.sh") .. "?.lua;" .. package.path
local H = require("harness")
local check = H.check
local DIR = assert(os.getenv("DQ_DIR"), "DQ_DIR unset: run tests/run.sh")

local function read(name)
  local f = assert(io.open(DIR .. name, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local toc = read("VulcanDuoQuest.toc")
local c = H.boot()
c.login()

-- Every file the .toc names exists; every addon .lua is in the .toc.
for file in toc:gmatch("\n([%w_]+%.lua)") do
  check("toc: " .. file .. " exists", io.open(DIR .. file, "r") ~= nil)
end
for _, file in ipairs({ "Util.lua", "DuoCore.lua", "Core.lua", "Quests.lua", "Sync.lua", "Compare.lua", "Warn.lua",
    "UI.lua", "Commands.lua" }) do
  check("toc: lists " .. file, toc:find("\n" .. file:gsub("%.", "%%."), 1) ~= nil)
end
check("toc: DuoCore loads before its users", toc:find("DuoCore.lua", 1, true) < toc:find("Sync.lua", 1, true))

-- Saved variables: per character, and the name the code uses.
check("toc: per-character saved variables", toc:find("## SavedVariablesPerCharacter: VulcanDuoQuestCharDB", 1, true) ~= nil)
-- The one account-wide file is the saved-data safety marker (Persist.lua): a list of characters only.
check("toc: account-wide file is only the safety marker", toc:find("\n## SavedVariables: VulcanDuoQuestDB\n", 1, true) ~= nil)
check("saved variables: the code writes that table", type(c.saved()) == "table")

-- Version: one source of truth, the .toc, where the packager writes the release tag.
local tocVersion = toc:match("## Version:%s*(%S+)")
check("version: the .toc holds the packager token", tocVersion == "@project-version@", tostring(tocVersion))
check("version: from source (token unreplaced) it's dev", c.ns.VERSION == "dev", tostring(c.ns.VERSION))
local other = H.boot({ tocVersion = "9.8.7" })
check("version: taken from the client's .toc read", other.ns.VERSION == "9.8.7", tostring(other.ns.VERSION))
local tagged = H.boot({ tocVersion = "v9.8.7" })
check("version: a packager tag v9.8.7 reads as 9.8.7", tagged.ns.VERSION == "9.8.7", tostring(tagged.ns.VERSION))
local junk = H.boot({ tocVersion = "@project-version@" })
check("version: the raw token is never shown or sent", junk.ns.VERSION == "dev", tostring(junk.ns.VERSION))
local util = read("Util.lua")
check("version: no hard-coded release number to fall back on", not util:find('or "%d+%.%d+'))

-- Addon compartment and key bindings call functions that exist.
local compartment = toc:match("## AddonCompartmentFunc:%s*(%S+)")
check("toc: compartment function defined", compartment and type(_G[compartment]) == "function", compartment)
local bindings = read("Bindings.xml")
local n = 0
for name, body in bindings:gmatch('<Binding name="([%w_]+)"[^>]*>%s*(.-)%s*</Binding>') do
  n = n + 1
  local fn = body:match("^([%w_]+)%(%)$")
  check("binding " .. name .. ": calls a defined function", fn and type(_G[fn]) == "function", body)
  check("binding " .. name .. ": has a label", type(_G["BINDING_NAME_" .. name]) == "string")
end
check("bindings: found", n == 2, n)
for name, attrs in bindings:gmatch('<Binding name="([%w_]+)"([^>]*)>') do
  check("binding " .. name .. ": listed under AddOns", attrs:find('category="ADDONS"') ~= nil)
end
check("bindings: header label", type(_G.BINDING_HEADER_VULCANDUOQUEST) == "string")
c.slash("solo on")
c.tick(2)
_G[compartment]()
check("compartment: toggles the window setting", c.ns.DB.shown == false)
c.slash("solo off")

-- Every /dq command the README mentions exists (an unknown one prints "unknown command").
local readme = read("README.md")
local seen = {}
for cmd in readme:gmatch("`/dq ([%a]+)") do
  if not seen[cmd] then
    seen[cmd] = true
    local before = #c.printed
    c.slash(cmd .. (cmd == "share" and " all" or ""))
    check("README command /dq " .. cmd .. " exists", not c.printedMatch("unknown command", before + 1))
  end
end
check("README: commands found", next(seen) ~= nil)

-- Source rules that tests can't catch at runtime.
for _, file in ipairs({ "Util.lua", "DuoCore.lua", "Core.lua", "Quests.lua", "Sync.lua", "Compare.lua", "Warn.lua",
    "UI.lua", "Commands.lua" }) do
  local src = read(file)
  check(file .. ": spell-cast events only through OnUnit (your own casts)", not src:find('ns%.On%("UNIT_SPELLCAST'))
  check(file .. ": no automation calls", not src:find("CastSpell") and not src:find("UseAction")
    and not src:find("AcceptQuest") and not src:find("CompleteQuest") and not src:find("GetQuestReward"))
end

-- Values the 12.x client may hand back as secrets can't be compared or tested
-- for truth (that throws in the real client, and Lua 5.1 tests can't trap it).
-- So every direct call of these must sit inside plain() or Bool().
local SECRET_APIS = { "IsUnitOnQuest", "IsPushableQuest", "GetSubZoneText", "GetRealZoneText", "UnitOnTaxi",
  "InCombatLockdown", "UnitAffectingCombat", "UnitIsDeadOrGhost", "IsInGroup", "IsInRaid", "IsResting",
  "UnitIsConnected", "GetNumGroupMembers", "UnitIsUnit", "IsQuestFlaggedCompleted", "IsOnQuest",
  "UnitDistanceSquared", "UnitInRange", "GetBestMapForUnit", "InChatMessagingLockdown", "GetLogIndexForQuestID",
  "GetTitleForQuestID", "GetQuestDifficultyLevel", "GetSpellName", "IsComplete", "IsFailed", "ReadyForTurnIn",
  "GetQuestProgressBarPercent", "GetSelectedQuest", "GetQuestInfo", "UnitIsVisible", "IsInInstance" }
for _, file in ipairs({ "Util.lua", "DuoCore.lua", "Core.lua", "Quests.lua", "Sync.lua", "Compare.lua", "Warn.lua",
    "UI.lua", "Commands.lua" }) do
  local lineNo = 0
  for line in (read(file) .. "\n"):gmatch("([^\n]*)\n") do
    lineNo = lineNo + 1
    local code = line:gsub("%-%-.*$", "")
    for _, api in ipairs(SECRET_APIS) do
      local at = 1
      while true do
        local s1, e1 = code:find("[%w_.]*" .. api .. "%(", at)
        if not s1 then break end
        local before = code:sub(1, s1 - 1)
        check(string.format("%s:%d: %s result goes through plain()", file, lineNo, api),
          before:find("plain%(%(?$") or before:find("Bool%($"), line)
        at = e1 + 1
      end
    end
  end
end

-- The same through pcall(API, ...) (or pcall(fn, ...) where fn holds a quest
-- API): each result after "ok" must go through plain() within the next lines.
for _, file in ipairs({ "Util.lua", "DuoCore.lua", "Core.lua", "Quests.lua", "Sync.lua", "Compare.lua", "Warn.lua",
    "UI.lua", "Commands.lua" }) do
  local lines = {}
  for line in (read(file) .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = (line:gsub("%-%-.*$", "")) end
  for i, code in ipairs(lines) do
    local names, first = code:match("local%s+ok[%w_]*%s*,%s*([%w_,%s]+)=%s*pcall%(%s*([^,)]+)")
    if names then
      local secret = file == "Quests.lua" and first:match("^fn")
      for _, api in ipairs(SECRET_APIS) do
        if first:find(api, 1, true) then secret = true end
      end
      if secret then
        local after = table.concat(lines, "\n", i, math.min(#lines, i + 4))
        for name in names:gmatch("[%w_]+") do
          check(string.format("%s:%d: pcall result %s goes through plain()", file, i, name),
            after:find("plain%(" .. name .. "%)") ~= nil, code)
        end
      end
    end
  end
end

os.exit(H.summary("static") and 0 or 1)
