-- DuoQuest: slash commands, key bindings, the addon-menu button, and /dq check.
local _, ns = ...
local DuoCore = ns.DuoCore

---------------------------------------------------------------------------
-- Sharing from a command, binding or button
---------------------------------------------------------------------------
-- questID given: share that one. Otherwise share the next quest your partner
-- needs: the one shared longest ago (never-shared first), so repeated presses
-- walk through the list even as it shrinks. One per press, because the game
-- shows your partner one share at a time.
-- A quest ID typed or shift-clicked into a command ("26180", or a quest link).
-- Only whole numbers in range: tonumber() also takes "nan", "inf", "1e9", "0x1f".
local function QuestArg(arg)
  local s = arg:match("^%d+$") or arg:match("quest:(%d+)")  -- (arguments arrive lowercased: "|hquest:...")
  local id = s and #s <= 9 and tonumber(s)
  return id and id >= 1 and id or nil
end

local sharedAt = {}
function ns.ShareCommand(questID)
  local focus = ns.FocusPartner()
  local rest = 0
  if not questID then
    if not focus then
      ns.Print(#(DuoCore.GroupMembers()) > 0 and "nobody in your group to share with yet (/dq partner <name>)."
        or "you're not in a group.")
      return false
    end
    local view = ns.Compare(focus)
    local list = ns.Shareable(view)
    if view.checking then
      ns.Print("still syncing with " .. focus.name .. ": try again in a moment.")
      return false
    elseif #list == 0 and ns.Offline(focus) and not view.live then
      ns.Print(focus.name .. " is offline: nothing to compare yet.")
      return false
    elseif #list == 0 then
      ns.Print(focus.name .. " isn't missing any quest you can share.")
      return false
    end
    local best
    for _, e in ipairs(list) do
      if not best or (sharedAt[e.id] or 0) < (sharedAt[best.id] or 0) then best = e end
    end
    questID = best.id
    rest = #list - 1
  end
  local rec = ns.mine[questID]
  local link = ns.QuestLink(questID, rec and rec.title or ns.TitleFor(questID), rec and rec.level)
  -- (First: no distance makes these shareable.)
  local blocker = ns.ShareBlocker(rec)
  if blocker == "missing" then
    local theirs = focus and focus.data and focus.data.list[questID]
    ns.Print(theirs and (link .. " is " .. focus.name .. "'s quest, not yours: ask " .. focus.name .. " to share it.")
      or ("can't share " .. link .. ": that quest isn't in your quest log."))
    return false
  elseif blocker == "failed" then
    ns.Print("can't share " .. link .. ": failed quests can't be shared.")
    return false
  elseif blocker == "giver" then
    ns.Print(link .. " can't be shared: " .. (focus and focus.name or "your partner")
      .. " has to get it themselves (usually from the quest giver).")
    return false
  end
  if focus and focus.unit and (ns.InRange(focus.unit) == false or ns.Apart(focus)) then
    if ns.Offline(focus) then
      ns.Print(focus.name .. " is offline: " .. link .. " can't be shared now.")
    else
      ns.Print(focus.name .. (ns.Apart(focus) and " isn't here" or " is too far away") .. " to receive " .. link .. ".")
    end
    return false
  end
  local ok, why = ns.ShareQuest(questID)
  sharedAt[questID] = GetTime()  -- tried: the next press moves on even if this one failed
  if ok then
    ns.Print("asked the game to share " .. link .. " with your group."
      .. (rest > 0 and (" " .. rest .. " more: press again (or /dq share).") or ""))
  else
    ns.Print("can't share " .. link .. ": " .. why .. ".")
  end
  return ok
end

---------------------------------------------------------------------------
-- Settings toggles
---------------------------------------------------------------------------
local TOGGLES = {
  warn = { key = "warnLeave", on = "leave warnings on.", off = "leave warnings off." },
  notify = { key = "notify", on = "pickup/finish notes on.", off = "pickup/finish notes off." },
  sound = { key = "sound", on = "warning sound on.", off = "warning sound off." },
  objectives = { key = "objectives", on = "objective lines shown.", off = "objective lines hidden." },
  solo = { key = "hideSolo", invert = true,
    on = "window shows even when there's nobody to compare with (solo, or a bigger pug or raid).",
    off = "window hides while there's nobody to compare with (solo, or a bigger pug or raid)." },
}

local function Toggle(name, arg)
  local t = TOGGLES[name]
  -- value = the toggle's "on" state; inverted toggles store the opposite.
  local current = ns.DB[t.key]
  if t.invert then current = not current end
  local value
  if arg == "on" then value = true elseif arg == "off" then value = false else value = not current end
  if t.invert then ns.DB[t.key] = not value else ns.DB[t.key] = value end
  local closed = name == "solo" and value and not ns.DB.shown
  ns.Print((value and t.on or t.off) .. (closed and " (It's closed: /dq shows it.)" or ""))
  ns.Refresh(true)
end

---------------------------------------------------------------------------
-- /dq status: every gap in chat (not just the ones from this hub)
---------------------------------------------------------------------------
local function Status()
  local focus = ns.FocusPartner()
  if not focus then
    local n = 0
    for _ in pairs(ns.mine) do n = n + 1 end
    local grouped = #(DuoCore.GroupMembers()) > 0
    ns.Print((grouped and "nobody in your group runs DuoQuest yet" or "not in a group")
      .. (ns.mineReady and (" (" .. n .. (n == 1 and " quest" or " quests") .. " in your log).") or "."))
    return
  end
  local view = ns.Compare(focus)
  if not view.live then
    -- Why not (sync off, offline, syncing, versions...): the window's own reason.
    local line = ns.StatusLine(focus)
    if not line:find("doesn't run DuoQuest") then
      ns.Print(line)
      if not view.unsure then return end  -- (else what the game reports follows)
    elseif not view.unsure then
      ns.Print(focus.name .. " doesn't run DuoQuest" .. (#view.both > 0
        and (": the game says they're on all " .. #view.both .. " of your quests (theirs can't be seen).")
        or " and this client can't see their quests."))
      return
    end
  end
  local old = view.live and (ns.IsStale(focus.data) or (focus.unit and UnitIsConnected
    and ns.plain(UnitIsConnected(focus.unit)) == false))
  local checking = view.live and view.checking
  if old or checking then
    local line = ns.StatusLine(focus):gsub("([^%.])%.(|r)$", "%1%2")  -- ("offline." -> "offline (...)")
    ns.Print(line .. " (" .. (old and "what follows is from their last update" or "")
      .. ((old and checking) and "; " or "")
      .. (checking and "what they've turned in isn't in yet, so your quests they lack aren't listed" or "") .. ")")
  end
  local theyNeed, iNeed = ns.Gaps(view)  -- every gap, wherever it was picked up
  local lines = ns.GapLines(focus, theyNeed, iNeed, view.unsure)  -- (no "and N more")
  local ignored = 0
  for _, list in ipairs({ view.checking and {} or view.theyNeed, view.iNeed }) do
    for _, e in ipairs(list) do
      if ns.IsIgnored(e.id) then ignored = ignored + 1 end
    end
  end
  if lines then
    for _, line in ipairs(lines) do ns.Print(line) end
  elseif view.checking then
    ns.Print("you have all of " .. focus.name .. "'s quests" .. (ignored > 0 and " apart from ones you ignore (/dq ignore list)."
      or "."))
  elseif ignored > 0 then
    ns.Print("no gaps apart from quests you ignore (/dq ignore list).")
  else
    ns.Print("no gaps between you and " .. focus.name .. ".")
  end
  if view.live then
    local readyMe, readyThem = 0, 0
    for _, e in ipairs(view.both) do
      if ns.HasFlag(e.mine.flags, ns.F_COMPLETE) then readyMe = readyMe + 1 end
      if e.theirs and ns.HasFlag(e.theirs.flags, ns.F_COMPLETE) then readyThem = readyThem + 1 end
    end
    if #view.both > 0 then
      ns.Print(string.format("both on %d; ready to turn in: you %d, %s %d.", #view.both, readyMe, focus.name, readyThem))
    end
  end
end

---------------------------------------------------------------------------
-- /dq check: what this client supports (run this first in the beta)
---------------------------------------------------------------------------
local function Has(path)
  local v = _G
  for part in path:gmatch("[^%.]+") do
    if type(v) ~= "table" then return false end
    v = v[part]
  end
  return v ~= nil
end

local function Yes(b) return b and "|cff60ff60yes|r" or "|cffff6060no|r" end

local function Check()
  local build = GetBuildInfo and { GetBuildInfo() } or {}
  ns.Print(string.format("DuoQuest %s, client %s (interface %s):", ns.VERSION, tostring(build[1] or "?"),
    tostring(build[4] or "?")))
  local apis = {
    { "C_QuestLog.GetInfo", "read your quest log" },
    { "C_QuestLog.GetQuestObjectives", "objective progress" },
    { "C_QuestLog.IsPushableQuest", "know which quests can be shared" },
    { "C_QuestLog.IsQuestFlaggedCompleted", "know which quests you've turned in" },
    { "C_QuestLog.IsOnQuest", "keep quests under collapsed headers" },
    { "C_QuestLog.IsUnitOnQuest", "partner quests without DuoQuest on their side" },
    { "C_QuestLog.SetSelectedQuest", "pick the quest to share; your selection is put back" },
    { "C_QuestLog.GetLogIndexForQuestID", "share by quest-log position" },
    { "QuestLogPushQuest", "share a quest" },
    { "C_ChatInfo.SendAddonMessage", "sync with your partner" },
    { "IsResting", "the leaving-town warning" },
    { "UnitDistanceSquared", "know when your partner is close enough to share" },
  }
  for _, a in ipairs(apis) do ns.Print(string.format("  %s %s (%s)", Yes(Has(a[1])), a[1], a[2])) end
  if not Has("C_QuestLog.GetInfo") then
    ns.Print("  " .. (Has("GetQuestLogTitle") and "using the classic quest log functions instead."
      or "|cffff6060no way to read the quest log on this client.|r"))
  end
  -- The assumptions most likely to differ on this client, measured:
  if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then
    local entries, quests = C_QuestLog.GetNumQuestLogEntries()
    local n = 0
    for _ in pairs(ns.mine) do n = n + 1 end
    ns.Print(string.format("  log: %s entries, %s quests by the game's count, %d read by DuoQuest",
      tostring(ns.plain(entries)), tostring(ns.plain(quests)), n))
  end
  local noObj = {}
  for _, rec in pairs(ns.mine) do
    if #rec.objs == 0 then
      noObj[#noObj + 1] = ns.QuestName(rec) .. (ns.HasFlag(rec.flags, ns.F_COMPLETE) and " (complete)" or " (not complete)")
    end
    if #noObj >= 3 then break end
  end
  if #noObj > 0 then ns.Print("  quests without objectives: " .. table.concat(noObj, ", ")) end
  local taxi = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.TaxiNode
  ns.Print(string.format("  flight-master signal: %s; prefix registered: %s; sync %s; queued %d",
    taxi and ("interaction type " .. tostring(taxi)) or "TAXIMAP_OPENED only", Yes(ns.channel.registered),
    ns.DB.sync and "on" or "off", ns.channel:Queued()))
  for key, p in pairs(ns.partners) do
    local count = 0
    for _ in pairs(p.list) do count = count + 1 end
    local peer = ns.channel:Peer(key)
    local unit = DuoCore.UnitFor(key)
    local d = ns.Distance(unit)
    ns.Print(string.format("  partner %s: DuoQuest %s, %d quests, %s, heard %s ago, %d details missing, %s", key,
      tostring(peer and peer.version or "?"), count, p.synced and "synced" or "syncing", ns.Ago(GetTime() - p.heard),
      #ns.MissingDetails(p), d and string.format("%d yards away", d) or "distance unknown"))
  end
  for _, m in ipairs((DuoCore.GroupMembers())) do
    if not ns.partners[m.key] then
      ns.Print("  " .. m.name .. (ns.syncOff[m.key] and ": turned DuoQuest sync off" or ": no DuoQuest messages yet"))
    end
  end
  if ns.Persist then ns.Print("  " .. ns.Persist.CheckLine()) end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function Help()
  ns.Print("commands:")
  ns.Print("  /dq - show/hide the window (/dq show, /dq hide);  /dq status - every gap in chat")
  ns.Print("  /dq share - share the next quest your partner needs (/dq share all lists them;"
    .. " /dq share <quest ID or link>)")
  ns.Print("  /dq partner <name> - pick who to compare with (/dq partner auto to undo)")
  ns.Print("  /dq ignore <quest ID or link> - leave a quest out of warnings, notes and /dq share (or right-click it);"
    .. " /dq ignore list")
  ns.Print("  /dq warn, /dq notify, /dq sound, /dq objectives, /dq solo - toggles (add on/off)")
  ns.Print("  /dq sync - sync on/off;  /dq lock, /dq unlock, /dq resetpos")
  ns.Print("  /dq check - what this client supports;  /dq debug - print sync traffic")
end

local commands = {}
commands[""] = function() ns.ToggleWindow() end
commands.show = function() ns.SetShown(true) end
commands.hide = function() ns.SetShown(false) end
commands.help = Help
commands.status = Status
commands.check = Check
commands.share = function(arg)
  if arg == "all" then
    local focus = ns.FocusPartner()
    if not focus then
      ns.Print(#(DuoCore.GroupMembers()) > 0 and "nobody in your group to share with yet (/dq partner <name>)."
        or "you're not in a group.")
      return
    end
    local view = ns.Compare(focus)
    local list = ns.Shareable(view)
    if view.checking then ns.Print("still syncing with " .. focus.name .. ": try again in a moment.") return end
    if #list == 0 and ns.Offline(focus) and not view.live then
      ns.Print(focus.name .. " is offline: nothing to compare yet.")
      return
    end
    if #list == 0 then ns.Print(focus.name .. " isn't missing any quest you can share.") return end
    local links = {}
    for _, e in ipairs(list) do links[#links + 1] = ns.QuestLink(e.id, e.title, e.level) end
    local why = ns.Offline(focus) and (focus.name .. " is offline")
      or (ns.Apart(focus) and (focus.name .. " isn't here"))
      or (focus.unit and ns.InRange(focus.unit) == false and (focus.name .. " is too far away"))
    ns.Print(focus.name .. (view.unsure and " may not have: " or " doesn't have: ") .. table.concat(links, ", ")
      .. (why and (" (" .. why .. ": share " .. (#list == 1 and "it" or "them") .. " when you're together).")
        or (#list == 1 and ". /dq share sends it." or ". /dq share sends the next one.")))
    return
  end
  local id = QuestArg(arg)  -- (an ID or a shift-clicked link)
  if arg ~= "" and not id then
    ns.Print("usage: /dq share, /dq share all, or /dq share <quest ID or link>.")
    return
  end
  ns.ShareCommand(id)
end
commands.partner = function(arg)
  if arg == "" or arg:lower() == "auto" then
    ns.DB.focus = nil
    ns.Print("comparing with whoever in your group runs DuoQuest.")
  else
    -- Saved as a key: "Mirel" on your realm, "Mirel-OtherRealm" (no spaces or dashes) on another,
    -- whatever the capitals, so it matches whether or not they're grouped yet.
    local wanted = arg
    local name, realm = arg:match("^([^%-]+)%-(.+)$")
    if name then
      local mine = GetNormalizedRealmName and ns.plain(GetNormalizedRealmName())
      realm = realm:gsub("[%s%-]", "")  -- (as the game writes realms in names: no spaces or dashes)
      wanted = (type(mine) == "string" and realm:lower() == mine:lower()) and name or (name .. "-" .. realm)
    end
    for _, m in ipairs((DuoCore.GroupMembers())) do
      if m.key:lower() == wanted:lower() or m.name:lower() == wanted:lower() then wanted = m.key end
    end
    ns.DB.focus = wanted
    ns.Print("comparing with " .. wanted .. (DuoCore.UnitFor(wanted) and "." or " (once they're in your group)."))
  end
  ns.Refresh(true)
end
commands.ignore = function(arg)
  if arg == "list" or arg == "" then
    local ids = {}
    for id in pairs(ns.DB.ignored) do ids[#ids + 1] = id end
    table.sort(ids)
    if #ids == 0 then ns.Print("no ignored quests. Right-click a quest in the window to ignore it.") return end
    local links = {}
    for _, id in ipairs(ids) do links[#links + 1] = ns.QuestLink(id, ns.TitleFor(id)) end
    ns.Print("ignored: " .. table.concat(links, ", ") .. ". /dq ignore <ID> again to undo.")
    return
  end
  local id = QuestArg(arg)
  if not id then ns.Print("usage: /dq ignore <quest ID or link> (shift-click the quest into the command).") return end
  ns.ToggleIgnore(id)
end
commands.sync = function(arg)
  local value
  if arg == "on" then value = true elseif arg == "off" then value = false else value = not ns.DB.sync end
  if value == ns.DB.sync then
    ns.Print("sync is already " .. (value and "on." or "off."))
    return
  end
  ns.DB.sync = value
  ns.SetSync(value)
  ns.Print(value and "sync on." or "sync off: your partner won't see your quests.")
  ns.Refresh(true)
end
commands.lock = function() ns.DB.locked = true ns.Print("window locked.") end
commands.unlock = function() ns.DB.locked = false ns.Print("window unlocked: drag it to move.") end
commands.resetpos = function()
  ns.DB.point = { unpack(ns.DEFAULT_POINT) }
  ns.PlaceFrame()
  ns.Print("window moved back to the default spot.")
end
commands.debug = function(arg)
  if arg == "on" then ns.DB.debug = true elseif arg == "off" then ns.DB.debug = false
  else ns.DB.debug = not ns.DB.debug end
  ns.Print("debug " .. (ns.DB.debug and "on: sync messages are printed." or "off."))
end
for name in pairs(TOGGLES) do
  commands[name] = function(arg) Toggle(name, arg) end
end

function ns.RunCommand(input)
  if not ns.DB then
    ns.Print("still loading, try again in a moment.")
    return
  end
  local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()
  local fn = commands[cmd]
  if fn then
    -- (keywords in any case: "/dq sync ON"; a partner's name stays as typed)
    rest = rest or ""
    fn(cmd == "partner" and rest or rest:lower())
  else
    ns.Print("unknown command '" .. cmd .. "'.")
    Help()
  end
end

SLASH_VULCANDUOQUEST1 = "/duoquest"
SLASH_VULCANDUOQUEST2 = "/dq"
SlashCmdList.VULCANDUOQUEST = ns.RunCommand

-- Addon menu (the compartment by the minimap) and key bindings (Bindings.xml).
function VulcanDuoQuest_OnAddonCompartmentClick()
  if ns.DB then ns.ToggleWindow() end
end
BINDING_HEADER_VULCANDUOQUEST = "Vulcan DuoQuest"
BINDING_NAME_VULCANDUOQUEST_TOGGLE = "Show/hide window"
BINDING_NAME_VULCANDUOQUEST_SHARE = "Share next quest your partner needs"
function VulcanDuoQuest_ToggleWindow()
  if ns.DB then ns.ToggleWindow() end
end
function VulcanDuoQuest_ShareNext()
  if ns.DB then ns.ShareCommand() end
end
