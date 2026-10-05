-- DuoQuest: reading your own quest log, turning a quest into a sync message and
-- back, and sharing a quest with your group.
local _, ns = ...
local plain = ns.plain

-- Flag bits carried with every quest.
ns.F_COMPLETE = 1       -- objectives done, ready to turn in
ns.F_FAILED = 2
ns.F_SHAREABLE = 4      -- the game says it can be shared
ns.F_SHARE_UNKNOWN = 8  -- this client can't tell whether it can be shared

local MAX_OBJECTIVES = 8
local TITLE_BYTES = 48
local FIRST_SCAN_WAIT = 8  -- seconds to wait for the log to load after login

ns.mine = {}          -- [questID] = quest record { id, title, level, flags, objs, body }
ns.mineReady = false  -- true after the first trustworthy scan
ns.seenAt = {}        -- [questID] = ns.Now() when it appeared (0 = unknown); saved per character
ns.turnedIn = {}      -- [questID] = when QUEST_TURNED_IN fired for it this session
local TURNED_IN_LAG = 60  -- seconds the game's completed flag may lag a turn-in
ns.awayMine = {}      -- [questID] = true: you picked it up while your partner was elsewhere (saved)

local function HasFlag(flags, bit)
  return math.floor((flags or 0) / bit) % 2 == 1
end
ns.HasFlag = HasFlag

local function Bool(v)
  v = plain(v)
  return v == true or v == 1
end

---------------------------------------------------------------------------
-- Reading the log
---------------------------------------------------------------------------
-- "4/10 Kobold Vermin slain", "Kobold Vermin slain: 4/10" or "Progress (45%)"
-- -> the label alone. The numbers travel separately.
function ns.ObjectiveLabel(text)
  text = ns.Clean(text)
  text = text:gsub("^%d+%s*/%s*%d+%s*", ""):gsub("%s*:?%s*%d+%s*/%s*%d+%s*$", "")
  text = text:gsub("^%d+%%%s*", ""):gsub("%s*:?%s*%(?%d+%%%)?$", "")
  return text
end

-- Objectives by quest ID (modern API): works even for quests the log loop
-- can't see (under a collapsed header).
local function ModernObjectives(questID)
  local list = {}
  local raw = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questID)
  if type(raw) ~= "table" then return list end
  for _, o in ipairs(raw) do
    if type(o) == "table" then
      local have, need = plain(o.numFulfilled), plain(o.numRequired)
      local done = Bool(o.finished)
      local bar = plain(o.type) == "progressbar"
      if bar then
        local pct = GetQuestProgressBarPercent and plain(GetQuestProgressBarPercent(questID))
        if type(pct) == "number" then have, need = math.floor(pct), 100 end
      end
      have = type(have) == "number" and math.max(0, math.floor(have)) or (done and 1 or 0)
      need = type(need) == "number" and math.max(0, math.floor(need)) or 1
      list[#list + 1] = { label = ns.ObjectiveLabel(plain(o.text) or ""), have = have, need = need, done = done,
        bar = bar or nil }
      if #list >= MAX_OBJECTIVES then break end
    end
  end
  return list
end

local function ModernFlags(id)
  local flags = 0
  local failed = C_QuestLog.IsFailed and Bool(C_QuestLog.IsFailed(id))
  local complete = not failed and ((C_QuestLog.IsComplete and Bool(C_QuestLog.IsComplete(id)))
    or (C_QuestLog.ReadyForTurnIn and Bool(C_QuestLog.ReadyForTurnIn(id))))
  if complete then flags = flags + ns.F_COMPLETE end
  if failed then flags = flags + ns.F_FAILED end
  if C_QuestLog.IsPushableQuest then
    local pushable = plain(C_QuestLog.IsPushableQuest(id))
    if pushable == true or pushable == 1 then
      flags = flags + ns.F_SHAREABLE
    elseif pushable == nil then
      flags = flags + ns.F_SHARE_UNKNOWN  -- (unreadable: "try sharing it", not "can't")
    end
  else
    flags = flags + ns.F_SHARE_UNKNOWN
  end
  return flags
end

-- Is the quest still in your log, even if the loop didn't show it? nil = can't tell.
local function StillOnQuest(id)
  if C_QuestLog.IsOnQuest then
    local ok, on = pcall(C_QuestLog.IsOnQuest, id)
    if ok and plain(on) ~= nil then return plain(on) == true end
  end
  if C_QuestLog.GetLogIndexForQuestID then
    local ok, index = pcall(C_QuestLog.GetLogIndexForQuestID, id)
    index = ok and plain(index)
    if type(index) == "number" then return index > 0 end
  end
  return nil
end

local function ModernRecord(id, title, level)
  if type(level) ~= "number" and C_QuestLog.GetQuestDifficultyLevel then
    level = plain(C_QuestLog.GetQuestDifficultyLevel(id))
  end
  return { id = id, title = ns.Clean(title or ""), level = type(level) == "number" and level or 0,
    flags = ModernFlags(id), objs = ModernObjectives(id) }
end

-- Bonus objectives, world quests, bounties and hidden trackers: you both get
-- those by being there, so they're never compared. (By ID, for quests the
-- log loop can't see, and for QUEST_ACCEPTED / QUEST_TURNED_IN in Warn.lua.)
function ns.IsTaskQuest(id)
  if not (C_QuestLog and type(id) == "number") then return false end
  for _, fn in ipairs({ C_QuestLog.IsQuestTask, C_QuestLog.IsWorldQuest, C_QuestLog.IsQuestBounty }) do
    local ok, yes = pcall(fn or error, id)
    if ok and plain(yes) == true then return true end
  end
  local index = C_QuestLog.GetLogIndexForQuestID and plain(C_QuestLog.GetLogIndexForQuestID(id))
  local info = type(index) == "number" and C_QuestLog.GetInfo and C_QuestLog.GetInfo(index)
  if type(info) == "table" and (Bool(info.isHidden) or Bool(info.isTask) or Bool(info.isBounty)) then return true end
  return false
end

-- Returns { [id] = record } or nil if the log can't be read right now.
local function ModernScan(extraIDs)
  local out, seen = {}, {}
  local n = plain(C_QuestLog.GetNumQuestLogEntries())
  if type(n) ~= "number" then return nil end
  for i = 1, n do
    local info = C_QuestLog.GetInfo(i)
    local id = type(info) == "table" and plain(info.questID)
    if type(id) == "number" and id > 0 and not Bool(info.isHeader) then
      seen[id] = true  -- (kept or skipped: either way the loop has seen it)
      if not Bool(info.isHidden) and not Bool(info.isTask) and not Bool(info.isBounty) then
        out[id] = ModernRecord(id, plain(info.title), plain(info.level))
      end
    end
  end
  -- Quests under a collapsed header don't show up in the loop. Anything we
  -- knew about (or just accepted) that the game says you're still on stays,
  -- unless it's a task-type quest.
  for id in pairs(extraIDs) do
    if not out[id] and not seen[id] and not ns.IsTaskQuest(id) and StillOnQuest(id) then
      local old = ns.mine[id]
      local title = (C_QuestLog.GetTitleForQuestID and plain(C_QuestLog.GetTitleForQuestID(id)))
        or (old and old.title) or ""
      out[id] = ModernRecord(id, title, old and old.level)
      out[id].byID = true  -- (found outside the log loop)
    end
  end
  return out
end

-- Classic-style API, in case this client only has the old functions. Quests
-- under a collapsed header aren't in the loop; where the client has
-- C_QuestLog.IsOnQuest (classic era does), the ones we knew about are kept,
-- with objectives from C_QuestLog.GetQuestObjectives.
local function ClassicScan(extraIDs)
  local out, seen = {}, {}
  local n = plain((GetNumQuestLogEntries()))
  if type(n) ~= "number" then return nil end
  for i = 1, n do
    local title, level, _, isHeader, _, isComplete, _, id = GetQuestLogTitle(i)
    title, level, isHeader, isComplete, id = plain(title), plain(level), plain(isHeader), plain(isComplete), plain(id)
    if not isHeader and type(id) == "number" and id > 0 then
      seen[id] = true
      local flags = ns.F_SHARE_UNKNOWN
      if isComplete == 1 or isComplete == true then flags = flags + ns.F_COMPLETE end
      if isComplete == -1 then flags = flags + ns.F_FAILED end
      local objs = {}
      local count = GetNumQuestLeaderBoards and plain(GetNumQuestLeaderBoards(i)) or 0
      for j = 1, math.min(type(count) == "number" and count or 0, MAX_OBJECTIVES) do
        local text, _, finished = GetQuestLogLeaderBoard(j, i)
        text, finished = plain(text) or "", Bool(finished)
        local have, need = text:match("(%d+)%s*/%s*(%d+)")
        objs[#objs + 1] = { label = ns.ObjectiveLabel(text), have = tonumber(have) or (finished and 1 or 0),
          need = tonumber(need) or 1, done = finished }
      end
      out[id] = { id = id, title = ns.Clean(title or ""), level = type(level) == "number" and level or 0,
        flags = flags, objs = objs }
    end
  end
  if C_QuestLog and C_QuestLog.IsOnQuest then
    for id in pairs(extraIDs) do
      if not seen[id] and StillOnQuest(id) then
        local old = ns.mine[id]
        local title = old and old.title
        for _, fn in ipairs({ C_QuestLog.GetTitleForQuestID or false, C_QuestLog.GetQuestInfo or false }) do
          local ok, t = pcall(fn or error, id)
          t = ok and plain(t)
          if not title and type(t) == "string" and t ~= "" then title = ns.Clean(t) end
        end
        local objs = C_QuestLog.GetQuestObjectives and ModernObjectives(id) or (old and old.objs) or {}
        local failed = old and HasFlag(old.flags, ns.F_FAILED)
        local complete = #objs > 0
        for _, o in ipairs(objs) do if not o.done then complete = false end end
        if #objs == 0 then complete = old and HasFlag(old.flags, ns.F_COMPLETE) end
        out[id] = { id = id, title = title or "", level = old and old.level or 0, objs = objs, byID = true,
          flags = ns.F_SHARE_UNKNOWN + (failed and ns.F_FAILED or 0) + ((complete and not failed) and ns.F_COMPLETE or 0) }
      end
    end
  end
  return out
end

local extraIDs = {}  -- quest IDs to look for outside the log loop
local viaPartner = {}  -- [questID] = true: looked for only because a partner has it

function ns.ScanLog()
  local ids = {}
  for id in pairs(ns.mine) do ids[id] = true end
  for id in pairs(extraIDs) do ids[id] = true end
  -- Your partners' quests too: one of yours under a header that was already
  -- collapsed before DuoQuest first saw it is found that way.
  wipe(viaPartner)
  for _, p in pairs(ns.partners or {}) do
    for id in pairs(p.list) do
      if not ids[id] then ids[id], viaPartner[id] = true, true end
    end
  end
  if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then return ModernScan(ids) end
  if GetNumQuestLogEntries and GetQuestLogTitle then return ClassicScan(ids) end
  return nil
end

---------------------------------------------------------------------------
-- Wire format for one quest:
--   U|<id36>|<flags>|<level>|<title>|<objective>~<objective>...
--   objective = <kind><have>/<need>:<label>, kind 0/1 = not done/done,
--   2/3 = the same for a progress bar (have/need = percent/100)
-- Labels shrink until the whole message fits in one addon message.
---------------------------------------------------------------------------
local BODY_BYTES = 245  -- plus the protocol prefix ("2|") = 247, under the 255 limit

local function EncodeObjectives(objs, labelBytes)
  local parts = {}
  for i, o in ipairs(objs) do
    parts[i] = string.format("%d%d/%d:%s", (o.done and 1 or 0) + (o.bar and 2 or 0), o.have, o.need,
      labelBytes > 0 and (ns.Truncate(o.label, labelBytes):gsub("%s+$", "")) or "")
  end
  return table.concat(parts, "~")
end

function ns.EncodeQuest(rec)
  local head = string.format("U|%s|%d|%d|%s|", ns.To36(rec.id), rec.flags, math.max(0, math.min(999, rec.level or 0)),
    (ns.Truncate(rec.title, TITLE_BYTES):gsub("%s+$", "")))
  for _, bytes in ipairs({ 60, 40, 28, 18, 10, 0 }) do
    local body = head .. EncodeObjectives(rec.objs, bytes)
    if #body <= BODY_BYTES then return body end
  end
  -- Still too long (many objectives): keep as many as fit, without labels.
  local objs = {}
  for i = 1, #rec.objs do
    objs[i] = rec.objs[i]
    if #(head .. EncodeObjectives(objs, 0)) > BODY_BYTES then
      objs[i] = nil
      break
    end
  end
  return head .. EncodeObjectives(objs, 0)
end

local function Num(s, maxLen)
  if type(s) ~= "string" or not s:match("^%d+$") or #s > (maxLen or 6) then return nil end
  return tonumber(s)
end

-- fields = { id36, flags, level, title, objectives } (as split by DuoCore).
function ns.DecodeQuest(fields)
  local id = ns.From36(fields[1])
  local flags, level = Num(fields[2], 2), Num(fields[3], 3)
  if not id or not flags or flags > 15 or not level or #fields > 5 then return nil end
  local rec = { id = id, flags = flags, level = level, title = fields[4] or "", objs = {} }
  for obj in (fields[5] or ""):gmatch("[^~]+") do
    local kind, have, need, label = obj:match("^([0-3])(%d+)/(%d+):(.*)$")
    if kind and #have <= 6 and #need <= 6 then
      kind = tonumber(kind)
      rec.objs[#rec.objs + 1] = { done = kind % 2 == 1, bar = kind >= 2 or nil, have = tonumber(have),
        need = tonumber(need), label = label }
    end
    if #rec.objs >= MAX_OBJECTIVES then break end
  end
  return rec
end

-- A short checksum of a quest's message, so the minute-by-minute list can
-- tell the partner when their copy of a quest is out of date.
function ns.Hash(body)
  local h = 0
  for i = 1, #body do h = (h * 31 + body:byte(i)) % 1679616 end  -- 36^4
  return ns.To36(h % 46656)  -- up to 3 characters
end

-- One quest in the membership list: "<id36>.<flags>.<hash>".
function ns.ListItem(rec)
  return ns.To36(rec.id) .. "." .. rec.flags .. "." .. ns.Hash(rec.body)
end

function ns.ParseListItem(item)
  local id36, flags, hash = item:match("^([0-9a-z]+)%.(%d%d?)%.([0-9a-z]+)$")
  if hash and #hash > 3 then return nil end
  local id = ns.From36(id36)
  flags = tonumber(flags)
  if not id or not flags or flags > 15 then return nil end
  return id, flags, hash
end

---------------------------------------------------------------------------
-- Scanning: debounced, diffed, and announced as MINE_CHANGED
---------------------------------------------------------------------------
local dirty = true
local logSeen = false    -- a QUEST_LOG_UPDATE arrived since login (the log is loaded)
local lastScan = -math.huge
local SCAN_GAP = 0.5     -- the log fires QUEST_LOG_UPDATE in bursts

function ns.MarkDirty() dirty = true end

-- Returns added, removed, changed (lists of questIDs), or nil if unreadable.
function ns.Rescan()
  local ok, fresh = pcall(ns.ScanLog)
  if not ok then
    ns.ReportError("quest log", fresh)
    return nil
  end
  if not fresh then return nil end
  for _, rec in pairs(fresh) do rec.body = ns.EncodeQuest(rec) end
  local first = not ns.mineReady
  local now = ns.Now()
  local added, removed, changed = {}, {}, {}
  for id, rec in pairs(fresh) do
    local old = ns.mine[id]
    if not old then
      added[#added + 1] = id
      -- Picked up now, or (first scan) whenever we saved it, 0 = unknown.
      -- (Found under a collapsed header through a partner's list: not a pickup.)
      local unknown = first or (viaPartner[id] and rec.byID)
      if not unknown or not ns.seenAt[id] then ns.seenAt[id] = unknown and 0 or now end
      if not unknown then
        -- Was your partner with you? (A quest you took alone isn't one they
        -- missed here, unless they're with you when you leave: Compare.Gaps.)
        local focus = ns.FocusPartner and ns.FocusPartner()
        local okApart, apart = pcall(ns.Apart, focus)  -- (never lose the scan over this)
        ns.awayMine[id] = (okApart and apart) or nil
      end
    elseif old.body ~= rec.body then
      changed[#changed + 1] = id
    end
  end
  for id in pairs(ns.mine) do
    if not fresh[id] then removed[#removed + 1] = id end
  end
  for id in pairs(ns.seenAt) do
    if not fresh[id] then ns.seenAt[id] = nil end
  end
  for id in pairs(ns.awayMine) do
    if not fresh[id] then ns.awayMine[id] = nil end
  end
  ns.mine = fresh
  ns.mineReady = true
  wipe(extraIDs)
  if ns.DB then
    local known = {}
    for id in pairs(fresh) do known[#known + 1] = id end
    table.sort(known)
    ns.DB.knownQuests = known
  end
  if first or #added > 0 or #removed > 0 or #changed > 0 then
    table.sort(added) table.sort(removed) table.sort(changed)
    ns.Fire("MINE_CHANGED", added, removed, changed, first)
  end
  return added, removed, changed
end

ns.Listen("TICK", function()
  if not dirty or GetTime() - lastScan < SCAN_GAP then return end
  -- Right after login the log can read empty until the game has loaded it;
  -- an empty first scan would tell your partner you dropped every quest.
  if not ns.mineReady and (not ns.loginAt or (not logSeen and GetTime() - ns.loginAt < FIRST_SCAN_WAIT)) then
    return
  end
  dirty = false
  lastScan = GetTime()
  if not ns.Rescan() then dirty = true end  -- unreadable right now: try again next tick
end)

ns.Listen("READY", function()
  for _, id in ipairs(ns.DB.knownQuests or {}) do
    if type(id) == "number" then extraIDs[id] = true end
  end
  ns.seenAt = ns.DB.seenAt  -- pickup times survive a reload
  ns.awayMine = ns.DB.awayMine
end)

-- A partner's list naming a quest we haven't looked for yet: look once (it
-- may be ours, under a collapsed header).
local probed = {}
ns.Listen("PARTNER_CHANGED", function(key)
  local p = key and ns.partners[key]
  if not p then return end
  for id in pairs(p.list) do
    if not ns.mine[id] and not probed[id] then
      probed[id] = true
      ns.MarkDirty()
    end
  end
end)

ns.On("QUEST_LOG_UPDATE", function()
  logSeen = true
  ns.MarkDirty()
end)
-- Classic passes (logIndex, questID); the modern client just (questID).
ns.On("QUEST_ACCEPTED", function(a, b)
  local id = plain(b) or plain(a)
  if type(id) == "number" and id > 0 then extraIDs[id] = true end
  ns.MarkDirty()
end)
ns.On("QUEST_TURNED_IN", function(id)
  id = plain(id)
  if type(id) == "number" then ns.turnedIn[id] = GetTime() end
  ns.MarkDirty()
end)
for _, event in ipairs({ "QUEST_REMOVED", "QUEST_WATCH_UPDATE", "PLAYER_ENTERING_WORLD" }) do
  ns.On(event, ns.MarkDirty)
end
ns.On("UNIT_QUEST_LOG_CHANGED", function(unit)
  if plain(unit) == "player" then ns.MarkDirty() end
end)

---------------------------------------------------------------------------
-- Questions about quests that aren't in your log
---------------------------------------------------------------------------
-- Have I already turned this quest in? (nil = can't tell on this client)
function ns.IsDone(questID)
  local fn = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or IsQuestFlaggedCompleted
  -- (Just turned in: the game's flag may lag a moment. Only a moment where
  -- the game can be asked: a repeatable quest is never flagged, and can be
  -- taken again.)
  local at = ns.turnedIn[questID]
  if at and (not fn or GetTime() - at < TURNED_IN_LAG) then return true end
  if not fn then return nil end
  local ok, done = pcall(fn, questID)
  if not ok then return nil end
  return plain(done) == true
end

-- Does the game say this group member is on the quest? Works even when they
-- don't run DuoQuest. nil = can't tell.
function ns.UnitOnQuest(unit, questID)
  if not (unit and C_QuestLog and C_QuestLog.IsUnitOnQuest) then return nil end
  local ok, on = pcall(C_QuestLog.IsUnitOnQuest, unit, questID)
  if not ok then return nil end
  on = plain(on)
  if on == nil then return nil end
  return on == true
end

-- Distance to a group member in yards, or nil if the game won't say (other
-- instance, or a restricted value). UnitInRange is a secret value on the
-- 12.x client, so UnitDistanceSquared comes first.
function ns.Distance(unit)
  if not unit then return nil end
  if UnitDistanceSquared then
    local ok, d2, checked = pcall(UnitDistanceSquared, unit)
    d2, checked = ok and plain(d2), ok and plain(checked)
    if type(d2) == "number" and checked ~= false then return math.sqrt(d2) end
  end
  return nil
end

ns.SHARE_RANGE = 40   -- yards: about the party "in range" distance
ns.NEAR_RANGE = 200   -- yards: the same hub

-- Is this group member close enough to receive a shared quest? nil = can't tell.
function ns.InRange(unit)
  local d = ns.Distance(unit)
  if d then return d <= ns.SHARE_RANGE end
  if unit and UnitInRange then
    local ok, inRange, checked = pcall(UnitInRange, unit)
    if ok then
      inRange, checked = plain(inRange), plain(checked)
      if checked ~= false and inRange ~= nil then return inRange == true end
    end
  end
  return nil
end

-- Your partner isn't with you: not grouped, offline, or known to be far.
function ns.Apart(focus)
  if not (focus and focus.unit) then return true end
  if ns.Offline(focus) then return true end
  return ns.Near(focus.unit) == false
end

function ns.Offline(focus)
  return focus and focus.unit and UnitIsConnected and plain(UnitIsConnected(focus.unit)) == false or false
end

-- Is this group member at the same hub as you? nil = can't tell.
-- Within NEAR_RANGE yards; else (no distances, e.g. in instances) visible to
-- you, or on the same map. A party member whose map the game won't give
-- (while it gives yours, and you're outside) is in another instance: not near.
-- (A secret value, a raid unit, which the map lookup doesn't cover, or you
-- being inside an instance: can't tell.)
function ns.Near(unit)
  local d = ns.Distance(unit)
  if d then return d <= ns.NEAR_RANGE end
  -- (No distances in instances: someone you can see is near, e.g. on another
  -- floor of the same dungeon, which has its own map.)
  if unit and UnitIsVisible and plain(UnitIsVisible(unit)) == true then return true end
  if unit and C_Map and C_Map.GetBestMapForUnit then
    local ok1, theirs = pcall(C_Map.GetBestMapForUnit, unit)
    local ok2, mine = pcall(C_Map.GetBestMapForUnit, "player")
    -- (Really nil, not a secret: even comparing a secret with nil throws.)
    local missing = ok1 and not (issecretvalue and issecretvalue(theirs)) and rawequal(theirs, nil)
    theirs, mine = ok1 and plain(theirs), ok2 and plain(mine)
    if type(theirs) == "number" and type(mine) == "number" then return theirs == mine end
    local inside = IsInInstance and plain((IsInInstance())) == true
    if missing and type(mine) == "number" and unit:find("^party") and not inside then return false end
  end
  return nil
end

---------------------------------------------------------------------------
-- Sharing (only ever from a click, key press or /dq share)
---------------------------------------------------------------------------
-- Why a quest of yours can never be shared (nil: it can). "missing", "failed", "giver".
function ns.ShareBlocker(rec)
  if not rec then return "missing" end
  if HasFlag(rec.flags, ns.F_FAILED) then return "failed" end
  if not HasFlag(rec.flags, ns.F_SHAREABLE) and not HasFlag(rec.flags, ns.F_SHARE_UNKNOWN) then return "giver" end
end

-- Returns true if the share was sent, or false and a reason.
function ns.ShareQuest(questID)
  local rec = ns.mine[questID]
  local blocker = ns.ShareBlocker(rec)
  if blocker == "missing" then return false, "that quest isn't in your quest log" end
  if not (IsInGroup and plain(IsInGroup())) then return false, "you need to be in a group to share" end
  if blocker == "failed" then return false, "failed quests can't be shared" end
  if blocker == "giver" then return false, "it can't be shared: your partner has to get it themselves" end
  if not QuestLogPushQuest then return false, "this client has no quest sharing function" end
  local ok, err
  local index = C_QuestLog and C_QuestLog.GetLogIndexForQuestID and plain(C_QuestLog.GetLogIndexForQuestID(questID))
  if C_QuestLog and C_QuestLog.SetSelectedQuest then
    -- Select it by ID and push it, by log index where there is one (Blizzard's
    -- Share button passes the index; clients whose push takes no argument use
    -- the selection), then put your selection back.
    local previous = C_QuestLog.GetSelectedQuest and plain(C_QuestLog.GetSelectedQuest())
    ok, err = pcall(function()
      C_QuestLog.SetSelectedQuest(questID)
      if type(index) == "number" and index > 0 then
        -- (a client whose push takes no argument and refuses one still has the selection)
        if not pcall(QuestLogPushQuest, index) then QuestLogPushQuest() end
      else
        QuestLogPushQuest()
      end
    end)
    if type(previous) == "number" and previous ~= questID then pcall(C_QuestLog.SetSelectedQuest, previous) end
  elseif type(index) == "number" and index > 0 then
    ok, err = pcall(QuestLogPushQuest, index)
  elseif SelectQuestLogEntry and GetQuestLogIndexByID then
    local logIndex = plain(GetQuestLogIndexByID(questID))
    if type(logIndex) ~= "number" or logIndex <= 0 then return false, "couldn't find it in the quest log" end
    local previous = GetQuestLogSelection and plain(GetQuestLogSelection())
    ok, err = pcall(function()
      SelectQuestLogEntry(logIndex)
      QuestLogPushQuest()
    end)
    if type(previous) == "number" then pcall(SelectQuestLogEntry, previous) end
  else
    return false, "this client has no way to select a quest for sharing"
  end
  if not ok then return false, "the game refused: " .. tostring(err) end
  return true
end
