-- DuoQuest: the quest-sync protocol, on top of the DuoCore channel (which
-- handles the hello/bye handshake, versions, throttling and splitting).
--
-- Messages (protocol 2), besides DuoCore's H and B:
--   L|seq|part|total|items   every quest in my log, "<id36>.<flags>.<hash>" (multi-part)
--   U|id36|flags|level|title|objectives   one quest's details (on any change)
--   D|id36|<done>            a quest left my log (done = 1: turned in)
--   C|seq|part|total|ids     of my partners' quests, the ones I've already turned in
--   N|<who>|id36,...         <who>: please resend these (missing or out of date)
-- Every message is built when it's sent, so it always describes the present.
-- The full list (L) goes out every minute while a partner is around; its
-- per-quest checksums let the partner spot anything a lost message left stale.
local _, ns = ...
local DuoCore = ns.DuoCore

local PROTOCOL = 2
local HEARTBEAT = 60      -- seconds between full lists while a partner is around
local HEARTBEAT_STALE = 120  -- ...and while every partner has gone quiet (a long boss fight; under STALE_AFTER)
local HELLO_ALONE = 120   -- grouped but nobody answering: say hello this often
local MAX_QUESTS = 75     -- more than any quest log holds: a broken client can't grow our tables
local STALE_AFTER = 150   -- a partner silent this long is shown as out of date
local FULL_GAP = 10       -- full state at most this often (more requests wait for it)
local QUIET_FOR = 5       -- ask for missing details once their messages pause this long...
local MISSING_MAX = 25    -- ...or once something has been missing this long anyway
local NEED_BACKOFF = { 10, 30, 60, 120 }

ns.STALE_AFTER = STALE_AFTER
ns.PROTOCOL = PROTOCOL
ns.partners = {}  -- [key] = partner (see NewPartner)
ns.syncOff = {}   -- [key] = true: said bye (turned sync off) and hasn't said hello since

-- Wall-clock seconds: pickup times are saved across reloads.
function ns.Now() return time() end

-- Their pickup times and "with you or not" flags live in the saved settings,
-- so a /reload doesn't turn every quest of theirs into one of unknown age.
local KEEP_PARTNERS = 4
local function SavedPickups(key)
  local saved = ns.DB and ns.DB.partnerSeen
  if type(saved) ~= "table" then return {}, {}, {} end
  local keep = saved[key]
  if type(keep) ~= "table" or type(keep.seenAt) ~= "table" or type(keep.near) ~= "table" then
    local n = 0
    for k in pairs(saved) do
      n = n + 1
      local focus = type(ns.DB.focus) == "string" and ns.DB.focus:lower()
      local chosen = focus and (k:lower() == focus or DuoCore.Display(k):lower() == focus)
      if n >= KEEP_PARTNERS and not ns.partners[k] and k ~= ns.DB.lastPartner and not chosen then
        saved[k] = nil
      end
    end
    keep = { seenAt = {}, near = {} }
    saved[key] = keep
  end
  return keep.seenAt, keep.near, keep
end

-- A quest of theirs we first hear about without seeing the pickup (their
-- first list of a session, or its details arriving first): when?
local RECENT = 120  -- heard from them this recently: a gap in our view, not a session apart
local function Unseen(p, id)
  if p.seenAt[id] then return end
  local last = p.saved.at
  if p.saved.met and last and ns.Now() - last <= RECENT then
    -- (we reloaded, or they did, a moment ago: judged as a pickup now)
    p.seenAt[id] = ns.Now()
    p.near[id] = ns.Near(DuoCore.UnitFor(p.key)) ~= false
  else
    p.seenAt[id] = 0  -- age unknown: already there when we first met...
    -- ...or, if we've synced before, picked up in a session we weren't in: apart.
    if p.saved.met then p.near[id] = false end
  end
end

local function NewPartner(key)
  local seenAt, near, saved = SavedPickups(key)
  return {
    saved = saved,    -- (saved.met: we've had a full list from them before, in any session)
    key = key, name = DuoCore.Display(key),
    list = {},        -- [questID] = flags, from their latest L (plus U/D since)
    hashes = {},      -- [questID] = checksum their latest L gave for it
    quests = {},      -- [questID] = record with title/objectives (from U)
    done = {},        -- [questID] = true: of MY quests, the ones they've turned in
    doneIn = false,   -- their turned-in list has arrived (until then "doesn't have" is a guess)
    doneAt = nil,     -- when it last came
    acked = {},       -- [questID] = when their turned-in list last answered for this quest of mine
    learnedAt = {},   -- [questID] = when we learned of this quest of theirs (our lists answer for it a while)
    seenAt = seenAt,  -- [questID] = ns.Now() first seen (0 = already there when we met)
    near = near,      -- [questID] = false if they picked it up away from you (else true/nil)
    heard = GetTime(), lastData = GetTime(), helloAt = GetTime(),
    synced = false,   -- received a complete list from their current session
    needLevel = 0, nextNeed = 0, missingSince = nil, lastFilled = 0,
  }
end

local function Partner(key)
  local p = ns.partners[key]
  if not p then
    p = NewPartner(key)
    ns.partners[key] = p
  end
  return p
end

function ns.IsStale(p)
  return GetTime() - p.heard > STALE_AFTER
end

local function Changed(key, why)
  ns.Fire("PARTNER_CHANGED", key, why)
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------
local channel
local lastHeartbeat = -math.huge
local lastFull = -math.huge
local fullDue
local lastDoneKey

local function SortedIDs(t)
  local ids = {}
  for id in pairs(t) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

local sentAt = {}  -- [questID] = GetTime() its message last went out
local frontAt = {} -- [questID] = GetTime() it last jumped the queue
local frontDue = {} -- [questID] = GetTime() it may jump again (changed again too soon)
local FRONT_GAP = 3     -- a quest whose progress keeps changing jumps the queue at most this often
local RESEND_GAP = 5    -- a resend request repeats one quest's message at most this often
local resendDue = {}    -- [questID] = GetTime() to resend it (asked for again too soon after sending)

local function QueueQuest(id, front)
  channel:Send("Q:" .. id, function()
    sentAt[id] = GetTime()
    local rec = ns.mine[id]
    if rec then return rec.body end
    -- It left the log before we got to send it.
    return "D|" .. ns.To36(id) .. "|" .. (ns.IsDone(id) and 1 or 0)
  end, front)
end

local function SendList(front)
  channel:SendList("L", "L", function()
    local items = {}
    for _, id in ipairs(SortedIDs(ns.mine)) do items[#items + 1] = ns.ListItem(ns.mine[id]) end
    return items
  end, front)
  lastHeartbeat = GetTime()
end

-- Of the quests my partners have, the ones I've already turned in. One list
-- covers everyone in the group: each partner only looks at their own IDs.
-- (withAcks: plus "~id36" for each of their quests we learned of recently: the
-- C answers for those, so their "doesn't have" note can trust it. Older
-- builds skip such items.)
local ACK_FOR = 120
local function DoneIDs(withAcks)
  local ids, acks = {}, {}
  for _, p in pairs(ns.partners) do
    for id in pairs(p.list) do
      if not ns.mine[id] and ns.IsDone(id) then ids[id] = true end
      if withAcks and GetTime() - (p.learnedAt[id] or -math.huge) < ACK_FOR then acks[id] = true end
    end
  end
  local items = {}
  for _, id in ipairs(SortedIDs(ids)) do items[#items + 1] = ns.To36(id) end
  for _, id in ipairs(SortedIDs(acks)) do items[#items + 1] = "~" .. ns.To36(id) end
  return items
end

-- force: send even if it hasn't changed (heartbeat, a partner's new session).
-- front: ahead of the backlog (a partner who just synced needs it before they
-- decide what you're "missing").
local doneDue  -- a send held back by a list on its way: { force, front }, tried again each tick
local DONE_HOLD = 20  -- a list that hasn't come this long after their hello doesn't hold it back any more
local function SendDone(force, front)
  if not (ns.mineReady and channel:CanSend()) then return end
  -- Built from their lists: one that hasn't arrived yet (their messages in
  -- the wrong order after a reload) would make it wrongly short, and the
  -- receiver replaces what it knew. Their list's arrival sends it (OnList).
  -- (Not for long: a third player who said hello and went quiet doesn't
  -- hold back what your partner is waiting for.)
  for _, p in pairs(ns.partners) do
    if not (p.synced or p.resync) and GetTime() - p.helloAt < DONE_HOLD then
      doneDue = { force = force or (doneDue and doneDue.force), front = front or (doneDue and doneDue.front) }
      return
    end
  end
  doneDue = nil
  local key = table.concat(DoneIDs(), ",")
  if not force and key == lastDoneKey then return end
  lastDoneKey = key
  channel:SendList("C", "C", function() return DoneIDs(true) end, front)
end
ns.SendDone = SendDone

-- Everything: the list, then every quest's details. Already-queued entries
-- are reused, so asking twice in a row costs nothing.
function ns.SendFull()
  if not (channel and ns.mineReady and channel:CanSend()) then return false end
  -- (Ahead of any backlog: the asker can't compare anything without it. A
  -- list half sent goes again after it: the asker may have missed its start.)
  SendList(true)
  for _, id in ipairs(SortedIDs(ns.mine)) do QueueQuest(id) end
  lastFull = GetTime()
  fullDue = nil
  return true
end

-- A partner asked for our full state. Several asks close together share one
-- send (the next one waits for FULL_GAP), so a chatty group can't flood us.
local function RequestFull()
  if not (ns.mineReady and channel:CanSend()) then
    fullDue = GetTime()  -- (their hello beat our roster update: answer once we can)
    return
  end
  if channel:IsQueued("L") or GetTime() - lastFull >= FULL_GAP then
    ns.SendFull()
  else
    fullDue = lastFull + FULL_GAP
  end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
-- A partner's pickup: when, and whether they were with you.
local function Picked(p, id)
  p.seenAt[id] = ns.Now()
  p.near[id] = ns.Near(DuoCore.UnitFor(p.key)) ~= false
end

local function OnList(p, items)
  local list, hashes, n = {}, {}, 0
  for _, item in ipairs(items) do
    local id, flags, hash = ns.ParseListItem(item)
    if id and n < MAX_QUESTS then
      list[id], hashes[id] = flags, hash
      n = n + 1
    end
  end
  local first = not p.synced
  local before = p.list
  p.list, p.hashes = list, hashes
  for id in pairs(p.quests) do
    if not list[id] then p.quests[id] = nil end
  end
  for id in pairs(p.seenAt) do
    if not list[id] then p.seenAt[id], p.near[id] = nil, nil end
  end
  local added = false
  for id in pairs(p.learnedAt) do if not list[id] then p.learnedAt[id] = nil end end
  for id, flags in pairs(list) do
    if not before[id] or first then p.learnedAt[id] = GetTime() end
    local q = p.quests[id]
    if q then
      -- (their "finished" message may have been lost: the list says so too)
      if not ns.HasFlag(q.flags, ns.F_COMPLETE) and ns.HasFlag(flags, ns.F_COMPLETE) then
        ns.Fire("PARTNER_QUEST_COMPLETE", p.key, id)
      end
      q.flags = flags
    end
    if not before[id] then
      if first then
        Unseen(p, id)
      else
        -- A pickup whose own message was lost still counts as a pickup.
        Picked(p, id)
        ns.Fire("PARTNER_QUEST_ADDED", p.key, id)
        added = true
      end
    end
  end
  p.synced, p.resync = true, nil
  p.saved.met, p.saved.at = true, ns.Now()
  SendDone(first or added, first or added)  -- (a pickup we missed: answered as for its own message)
  Changed(p.key, "list")
end

local handlers = {}

handlers.L = function(p, fields)
  local items = channel:ReceiveList(p.key, "L", fields)
  if items then OnList(p, items) end
end

handlers.U = function(p, fields, body)
  local rec = ns.DecodeQuest(fields)
  if not rec then return end
  rec.hash = ns.Hash(body)
  local isNew = p.list[rec.id] == nil
  if isNew then
    local n = 0
    for _ in pairs(p.list) do n = n + 1 end
    if n >= MAX_QUESTS then return end
  end
  local old = p.quests[rec.id]
  if not old or (p.hashes[rec.id] and old.hash ~= p.hashes[rec.id]) then p.lastFilled = GetTime() end
  p.quests[rec.id] = rec
  p.list[rec.id] = rec.flags
  p.hashes[rec.id] = rec.hash
  if isNew then
    p.learnedAt[rec.id] = GetTime()
    if p.synced then
      Picked(p, rec.id)
      ns.Fire("PARTNER_QUEST_ADDED", p.key, rec.id)
    else
      Unseen(p, rec.id)  -- (arrived before their first list)
    end
    -- Our turned-in list, now (ahead of any backlog), even if unchanged: it
    -- also tells them we got it, so their "doesn't have" note can trust it.
    SendDone(true, true)
  end
  if old and not ns.HasFlag(old.flags, ns.F_COMPLETE) and ns.HasFlag(rec.flags, ns.F_COMPLETE) then
    ns.Fire("PARTNER_QUEST_COMPLETE", p.key, rec.id)
  end
  Changed(p.key, "quest")
end

handlers.D = function(p, fields)
  local id = ns.From36(fields[1])
  if not id then return end
  p.list[id], p.quests[id], p.hashes[id], p.seenAt[id], p.near[id] = nil, nil, nil, nil, nil
  if fields[2] == "1" then p.done[id] = true end
  Changed(p.key, "removed")
end

handlers.C = function(p, fields)
  local items = channel:ReceiveList(p.key, "C", fields)
  if not items then return end
  p.done, p.doneIn, p.doneAt = {}, true, GetTime()
  for _, item in ipairs(items) do
    local id = ns.From36(item)
    if id then p.done[id] = true end
    local ack = ns.From36(item:match("^~(.*)$"))
    if ack then p.acked[ack] = GetTime() end
  end
  Changed(p.key, "done")
end

local lastNeedList = -math.huge
local NEED_GAP = 8   -- a partner's resend requests are answered at most this often (theirs back off from 10s)

-- An empty request: they're back from a loading screen and may have missed
-- something: our turned-in list and our list, whenever we last sent them.
-- (Its own limit, so the requests for details that follow aren't held back;
-- one too soon after the last is answered when the limit allows, not dropped:
-- two loading screens in a row.)
local function AnswerListRequest(p)
  local wait = NEED_GAP - (GetTime() - (p.listAskedAt or -math.huge))
  if wait > 0 then
    p.listDue = GetTime() + wait
    return
  end
  p.listAskedAt, p.listDue = GetTime(), nil
  SendDone(true)  -- (first: until it's in, a quest they turned in looks like a gap)
  SendList()
end

handlers.N = function(p, fields)
  if DuoCore.Key(fields[1]) ~= DuoCore.Me() then return end  -- asked of someone else
  if (fields[2] or "") == "" then
    AnswerListRequest(p)
    return
  end
  if GetTime() - (p.answeredAt or -math.huge) < NEED_GAP then return end
  p.answeredAt = GetTime()
  local stale = false
  for id36 in (fields[2] or ""):gmatch("[^,]+") do
    local id = ns.From36(id36)
    if id then
      if not ns.mine[id] then
        stale = true
      elseif GetTime() - (sentAt[id] or -math.huge) >= RESEND_GAP then
        QueueQuest(id)
      else
        resendDue[id] = sentAt[id] + RESEND_GAP  -- (just sent: again in a moment, not once per request)
      end
    end
  end
  -- They're asking about quests we no longer have: their list is out of date.
  if stale and GetTime() - lastNeedList >= 10 then
    lastNeedList = GetTime()
    SendList()
  end
end

local function OnMessage(key, kind, fields, body)
  local handler = handlers[kind]
  if not handler then return end
  if kind == "N" and not ns.partners[key] then return end  -- a request, not a partner announcing themselves
  local p = ns.partners[key]
  if not p then
    p = Partner(key)
    Changed(key, "new")
  end
  p.heard = GetTime()
  if kind ~= "N" then p.lastData = GetTime() end
  if p.synced then p.saved.at = ns.Now() end  -- (last heard from, saved: see Unseen)
  handler(p, fields, body)
end

local function OnPeer(key, event)
  if event == "session" then
    -- They logged in or reloaded: their next list is a fresh start, not a
    -- burst of pickups.
    ns.syncOff[key] = nil
    local p = Partner(key)
    -- (the window keeps showing what they had until the new list is in)
    p.resync = p.synced or p.resync
    p.synced = false
    p.helloAt = GetTime()
    p.heard = GetTime()
    Changed(key, "session")
  elseif event == "request" then
    if ns.partners[key] then ns.partners[key].heard = GetTime() end
    RequestFull()  -- (our done list follows their list: OnList)
    -- (...but if we already have their list, e.g. from before their reload,
    -- send it now too: their list may never come if our request was lost)
    local p = ns.partners[key]
    if p and (p.resync or p.synced) then SendDone(true, true) end
  elseif event == "bye" or event == "left" then
    ns.syncOff[key] = event == "bye" or nil
    if ns.partners[key] or event == "bye" then
      ns.partners[key] = nil
      Changed(key, event)
    end
  end
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------
channel = DuoCore.NewChannel({
  prefix = "VulcanDuoQuest", protocol = PROTOCOL, oldest = PROTOCOL, label = "DuoQuest", version = ns.VERSION,
  -- Off until your quest log has been read: nothing to say, and nothing to hear yet.
  enabled = function() return ns.DB ~= nil and ns.DB.sync and ns.mineReady end,
  onMessage = OnMessage,
  onPeer = OnPeer,
  print = ns.Print,
  debug = function(kind, text) ns.Debug(kind, text) end,
})
ns.channel = channel

ns.On("CHAT_MSG_ADDON", function(...) channel:Receive(...) end)

ns.Listen("READY", function()
  if not channel:Register() then
    ns.Print("couldn't register the sync channel, so your partner won't see your quests. /reload may fix it.")
  end
end)

local announced = false  -- said hello since the log became readable / we joined
ns.Listen("MINE_CHANGED", function(added, removed, changed, first)
  if first then
    announced = channel:Hello(true)
    return
  end
  -- What you can see changing (progress, pickups) jumps the backlog.
  for _, id in ipairs(added) do QueueQuest(id, true) end
  -- (A quest changing every second, e.g. while grinding, mustn't keep the
  -- list and a reloading partner's resend waiting: it jumps at most every
  -- FRONT_GAP seconds.)
  local now = GetTime()
  for _, id in ipairs(changed) do
    local front = now - (frontAt[id] or -math.huge) >= FRONT_GAP
    if front then
      frontAt[id], frontDue[id] = now, nil
    else
      frontDue[id] = frontAt[id] + FRONT_GAP  -- (it jumps then, if it hasn't gone out by itself)
    end
    QueueQuest(id, front)
  end
  for _, id in ipairs(removed) do QueueQuest(id, true) end  -- builds the D (with "turned in")
end)

-- Partners who left the group are forgotten. Joining a group says hello;
-- someone else joining doesn't (their own hello reaches us).
local rosterRetry
local function RosterUpdate()
  rosterRetry = nil
  local members, complete = DuoCore.GroupMembers()
  if not complete then
    rosterRetry = GetTime() + 2  -- names unreadable right now; look again shortly
    return
  end
  local inGroup = {}
  for _, m in ipairs(members) do inGroup[m.key] = true end
  channel:Prune(inGroup)  -- (each one that left comes back as onPeer "left")
  if not next(inGroup) then
    channel:Clear()
    announced, fullDue, doneDue = false, nil, nil
    wipe(resendDue)
    wipe(frontDue)
  elseif not announced and ns.mineReady then
    announced = channel:Hello(true)
  end
  ns.Fire("ROSTER")
end
-- Any loading screen but login and /reload (those say hello anyway): a
-- partner who logged in or reloaded meanwhile may have missed us. Our list
-- (one or two messages) tells them we're here; nobody yet, a hello.
ns.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
  if ns.plain(isLogin) or ns.plain(isReload) then return end
  if not (ns.DB and ns.DB.sync and ns.mineReady and announced and DuoCore.Distribution()) then return end
  -- Nobody heard from yet, though we said hello a moment ago (right after a
  -- login or /reload): their answers may have come while we were loading, so
  -- start over. (A partner whose list or turned-in list is missing gets the
  -- request below: its answer brings both.)
  local waiting = not next(ns.partners) and GetTime() - channel.lastHello < 20
  if waiting then
    channel:NewSession()
    channel:Hello(true)
  elseif next(ns.partners) then
    SendList(true)
    SendDone(true, true)  -- (ours may have been lost in their loading screen)
    -- ...and theirs in ours: ask for their list and turned-in list (an empty
    -- request; answered at most every 8 seconds).
    for key in pairs(ns.partners) do
      -- (its own queue key: a pending request for missing details isn't replaced)
      channel:Send("N0:" .. key, function() return "N|" .. DuoCore.Wire(key) .. "|" end, true)
    end
  else
    channel:Hello(false)
  end
end)
ns.On("GROUP_ROSTER_UPDATE", RosterUpdate)
ns.On("GROUP_JOINED", RosterUpdate)
ns.On("GROUP_LEFT", RosterUpdate)

-- Called when /dq sync changes.
function ns.SetSync(on)
  if not on then
    channel:Bye()  -- the bye still goes out (with retries) now that sync is off
    wipe(ns.partners)
    announced = false
    Changed(nil, "sync")
  else
    channel:NewSession()  -- (if our bye was lost, partners must still start over)
    announced = channel:Hello(true)
    ns.groupedAt = GetTime()  -- (the status line says "Waiting for" while their answer comes)
  end
end

-- Quests in their list that we have no details for, or stale details.
local function Missing(p)
  local out = {}
  for id in pairs(p.list) do
    local q = p.quests[id]
    if not q or (p.hashes[id] and q.hash ~= p.hashes[id]) then out[#out + 1] = id end
  end
  table.sort(out)
  return out
end
ns.MissingDetails = Missing

local function NeedRequest(p)
  channel:Send("N:" .. p.key, function()
    local missing = Missing(p)
    if #missing == 0 or not ns.partners[p.key] then return nil end
    local parts, size = {}, 0
    for _, id in ipairs(missing) do
      local id36 = ns.To36(id)
      if size + #id36 + 1 > 180 then break end  -- the rest next time
      parts[#parts + 1] = id36
      size = size + #id36 + 1
    end
    return "N|" .. DuoCore.Wire(p.key) .. "|" .. table.concat(parts, ",")
  end, true)
end

local lastPump
ns.Listen("TICK", function()
  local now = GetTime()
  channel:Pump(lastPump and (now - lastPump) or 0)
  lastPump = now
  if rosterRetry and now >= rosterRetry then RosterUpdate() end
  if not (ns.DB and ns.DB.sync and ns.mineReady) or not DuoCore.Distribution() then return end
  if not announced then announced = channel:Hello(true) end
  if fullDue and now >= fullDue then ns.SendFull() end
  for id, at in pairs(frontDue) do
    if now >= at then
      frontDue[id] = nil
      if channel:IsQueued("Q:" .. id) then
        frontAt[id] = now
        QueueQuest(id, true)
      end
    end
  end
  if doneDue then SendDone(doneDue.force, doneDue.front) end
  for id, at in pairs(resendDue) do
    if now >= at then
      resendDue[id] = nil
      if ns.mine[id] then QueueQuest(id) end
    end
  end
  -- Heartbeat while a partner with DuoQuest is around; slower if they've all
  -- gone quiet (after a long boss fight both sides would otherwise wait for
  -- each other forever). Nobody at all: an occasional hello.
  local live, any = false, false
  for _, p in pairs(ns.partners) do
    any = true
    if not ns.IsStale(p) then live = true end
  end
  if any and now - lastHeartbeat >= (live and HEARTBEAT or HEARTBEAT_STALE) then
    SendList()
    SendDone(true)
  elseif not any and now - channel.lastHello >= HELLO_ALONE then
    channel:Hello(false)
  end
  for _, p in pairs(ns.partners) do
    if p.listDue and now >= p.listDue then AnswerListRequest(p) end
    local missing = #Missing(p) > 0
    if not missing or ns.IsStale(p) then
      p.missingSince = nil
      if not missing then p.needLevel = 0 end
    else
      p.missingSince = p.missingSince or now
      -- Usually their details are on the way: wait for a pause in their
      -- messages, but not forever (a busy partner never pauses).
      local waiting = now - math.max(p.missingSince, p.lastFilled)  -- (time since anything missing arrived)
      if (now - p.lastData >= QUIET_FOR or waiting >= MISSING_MAX) and now >= p.nextNeed then
        NeedRequest(p)
        p.needLevel = math.min(p.needLevel + 1, #NEED_BACKOFF)
        p.nextNeed = now + NEED_BACKOFF[p.needLevel]
      end
    end
  end
end)
