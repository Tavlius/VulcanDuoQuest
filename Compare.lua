-- DuoQuest: comparing your quest log with your partner's.
local _, ns = ...
local DuoCore = ns.DuoCore
local HasFlag = ns.HasFlag
ns.FOCUS_WAIT = 30  -- seconds after grouping/login the last partner keeps the window

-- The partner the window and warnings are about:
--   1. the one you picked with /dq partner (while they're in your group)
--   2. otherwise the DuoQuest partner shown automatically before, as long as
--      they're here (kept across reloads, so a bigger group doesn't flip the
--      window to someone else; right after you group up or log in they're
--      kept while their data is on the way)
--   3. otherwise the first DuoQuest partner by name
--   4. otherwise the only other person in your group (game data only)
-- Offline members give way to online ones in 2 and 3 (a main logged off in
-- the party while his alt plays); if only offline partners are left, one of them.
-- Returns { key, name, unit, data = sync record or nil, chosen = picked by you } or nil.
function ns.FocusPartner()
  local members = DuoCore.GroupMembers()
  if #members == 0 then return nil end
  local byKey = {}
  for _, m in ipairs(members) do byKey[m.key] = m end
  local function Focus(key, chosen)
    return { key = key, name = byKey[key].name, unit = byKey[key].unit, data = ns.partners[key], chosen = chosen }
  end
  local want = ns.DB and ns.DB.focus
  if want then
    -- Saved as typed; match it to a group member regardless of case or realm.
    local wantKey = (DuoCore.Key(want) or want):lower()  -- (an older saved "Name-YourRealm" too)
    for key, m in pairs(byKey) do
      if key:lower() == want:lower() or m.name:lower() == want:lower() or key:lower() == wantKey then
        return Focus(key, true)
      end
    end
  end
  -- Offline members (a main logged off in the party while his alt plays)
  -- give way to someone online.
  local function Online(key)
    local unit = byKey[key].unit
    return not (unit and UnitIsConnected and ns.plain(UnitIsConnected(unit)) == false)
  end
  local keys = {}
  for key in pairs(ns.partners) do
    if byKey[key] and Online(key) then keys[#keys + 1] = key end
  end
  table.sort(keys)
  local last = ns.DB and ns.DB.lastPartner
  if last and byKey[last] and (Online(last) or not keys[1])
      and (ns.partners[last] or GetTime() - (ns.groupedAt or -math.huge) < ns.FOCUS_WAIT) then
    return Focus(last)
  end
  if keys[1] then
    -- (Your usual partner is in the group but hasn't synced yet, or is
    -- offline: show this one for now, without forgetting them.)
    if ns.DB and not (last and byKey[last]) then ns.DB.lastPartner = keys[1] end
    return Focus(keys[1])
  end
  for key in pairs(ns.partners) do
    if byKey[key] then return Focus(key) end  -- (only offline ones)
  end
  if #members == 1 then return Focus(members[1].key) end
  return nil
end

local function ByTitle(a, b)
  local ta, tb = ns.QuestName(a), ns.QuestName(b)
  if ta ~= tb then return ta < tb end
  return a.id < b.id
end

-- How the person missing a quest can get it:
--   "share"  the owner can share it        "giver"  can't be shared (the quest giver, an item...)
--   "maybe"  this client can't tell         "failed" the owner's copy failed
local function HowToGet(flags)
  if HasFlag(flags, ns.F_FAILED) then return "failed" end
  if HasFlag(flags, ns.F_SHAREABLE) then return "share" end
  if HasFlag(flags, ns.F_SHARE_UNKNOWN) then return "maybe" end
  return "giver"
end
ns.HowToGet = HowToGet

function ns.IsIgnored(id)
  return ns.DB and ns.DB.ignored[id] == true
end

-- The comparison for one partner. Lists hold { id, title, level, how, mine, theirs, seenAt, away }.
--   theyNeed  in your log, not theirs, not turned in by them
--   iNeed     in their log, not yours, not turned in by you
--   both      in both logs
--   theyDid   in your log, they've already turned it in
--   iDid      in their log, you've already turned it in
-- `live` is false when the partner doesn't run DuoQuest: then theyNeed comes
-- from the game's party data (C_QuestLog.IsUnitOnQuest) and iNeed is unknown.
function ns.Compare(focus)
  local view = { theyNeed = {}, iNeed = {}, both = {}, theyDid = {}, iDid = {}, live = false, unsure = false }
  if not focus then return view end
  local p = focus.data
  if p and (p.synced or p.resync) then
    view.live = true
    -- Until their turned-in list is in, one of yours they "don't have" may be
    -- one they did (a moment after your login or /reload): no warning on that.
    view.checking = not p.doneIn
    for id, mine in pairs(ns.mine) do
      local entry = { id = id, title = mine.title, level = mine.level, mine = mine, how = HowToGet(mine.flags),
        seenAt = ns.seenAt[id] or 0, away = ns.awayMine[id] == true }
      if p.list[id] then
        entry.theirs = p.quests[id] or { id = id, flags = p.list[id], objs = {}, stub = true }  -- (details on the way)
        view.both[#view.both + 1] = entry
      elseif p.done[id] then
        view.theyDid[#view.theyDid + 1] = entry
      else
        view.theyNeed[#view.theyNeed + 1] = entry
      end
    end
    for id, flags in pairs(p.list) do
      if not ns.mine[id] then
        local theirs = p.quests[id]
        local entry = { id = id, title = theirs and theirs.title or nil, level = theirs and theirs.level or 0,
          theirs = theirs, how = HowToGet(flags), seenAt = p.seenAt[id] or 0, away = p.near[id] == false }
        if ns.IsDone(id) then
          view.iDid[#view.iDid + 1] = entry
        else
          view.iNeed[#view.iNeed + 1] = entry
        end
      end
    end
  elseif focus.unit and not (UnitIsConnected and ns.plain(UnitIsConnected(focus.unit)) == false) then
    -- No DuoQuest on their side: the game still says whether they're on each
    -- of *your* quests (not whether they've done it, so these are "maybe").
    -- (Not while they're offline: that would be no answer at all.)
    for id, mine in pairs(ns.mine) do
      local on = ns.UnitOnQuest(focus.unit, id)
      local entry = { id = id, title = mine.title, level = mine.level, mine = mine, how = HowToGet(mine.flags),
        seenAt = ns.seenAt[id] or 0 }
      if on == false then
        view.theyNeed[#view.theyNeed + 1] = entry
        view.unsure = true
      elseif on == true then
        view.both[#view.both + 1] = entry
      end
    end
  end
  for _, list in pairs({ view.theyNeed, view.iNeed, view.both, view.theyDid, view.iDid }) do
    table.sort(list, ByTitle)
  end
  return view
end

-- Gaps worth a leave warning (when `since` is given): not ignored, not warned
-- about before (`told`), and picked up since then, i.e. at this hub, with you
-- both there. With `together` (you're together now) your own pickups since
-- you arrived count even if your partner was elsewhere then: you were here,
-- they got here later. (Theirs made away from you don't: they may have been
-- at another hub.) A gap of unknown age (from before you two synced) counts
-- until it has been warned about once. Without `since`: every gap.
-- (None of yours they lack while their turned-in list is still on its way.)
function ns.Gaps(view, since, told, together)
  local function Keep(list)
    local out = {}
    if list == view.theyNeed and view.checking then return out end
    for _, e in ipairs(list) do
      local age = e.seenAt or 0
      local fresh = not since or ((age >= since or age == 0) and (not e.away or (together and e.mine ~= nil))
        and not (told and told[e.id]))
      if not ns.IsIgnored(e.id) and fresh then out[#out + 1] = e end
    end
    return out
  end
  return Keep(view.theyNeed), Keep(view.iNeed)
end

-- Share targets: your quests they need that can be shared (not ones you
-- ignore, e.g. a class quest they can't take; its own Share button still works).
function ns.Shareable(view)
  local out = {}
  for _, e in ipairs(view.theyNeed) do
    if (e.how == "share" or e.how == "maybe") and not ns.IsIgnored(e.id) then out[#out + 1] = e end
  end
  return out
end

-- Progress as text: "4/10", "45%" for a progress bar, "done".
function ns.ObjText(o)
  if not o then return "-" end
  if o.done then return "|cff60ff60done|r" end
  if o.bar then return o.have .. "%" end
  return o.have .. "/" .. o.need
end

-- A quest's title from whatever knows it: your log, a partner's, the game.
function ns.TitleFor(id)
  if ns.mine[id] then return ns.mine[id].title end
  for _, p in pairs(ns.partners) do
    if p.quests[id] then return p.quests[id].title end
  end
  return ns.QuestName({ id = id })
end

function ns.QuestName(entry)
  if entry.title and entry.title ~= "" then return entry.title end
  local t = C_QuestLog and C_QuestLog.GetTitleForQuestID and ns.plain(C_QuestLog.GetTitleForQuestID(entry.id))
  if type(t) == "string" and t ~= "" then return t end
  return "Quest #" .. entry.id
end
