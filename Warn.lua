-- DuoQuest: the leave warning and partner notes.
--
-- A "gap" is a quest one of you has and the other doesn't (and hasn't turned in).
-- The warning is about gaps picked up at the hub you're leaving, with both of
-- you there: those are the ones that cost a walk back. Leaving is detected as:
--   * flight map opened             "Before you fly"
--   * Hearthstone cast started      "Before you hearth"
--   * walked away from the hub      "Leaving <hub>": 15 seconds outside every area
--     where you rested or handled quests this visit, and out of any town
--   * into a new zone on foot       "You left <zone>" (last chance to turn back)
-- Each gap is warned about once. Taking off, a Hearthstone, any loading screen
-- or a new zone starts a new hub; a /reload, logging back in within 10 minutes
-- in the same zone (a disconnect), or logging back in at one of the hub's
-- areas any time later (you logged out at its inn) keeps it. A gap whose
-- age is unknown (from before you two synced) counts until warned about once.
-- Nothing fires while you're dead; in combat the warning waits for the fight
-- (and for you to be alive again), and is dropped if you're back at the hub.
local _, ns = ...
local plain = ns.plain

local MAX_NAMED = 5         -- quests named per line of a warning (the rest: "and N more (/dq status)")
local AWAY_FOR = 15         -- seconds away from the hub's areas before "Leaving <hub>"
local LOAD_QUIET = 10       -- no "You left" around a loading screen (hearth, portal: already gone)
local NOTE_DELAY = 6        -- notes wait this long, then re-check (you both accept at once)
local NOTE_TRIES = 5        -- ...and wait again (up to this many times) for a quest's details
local ACK_LATE = 70        -- a turned-in list this long after a pickup was built knowing of it
local NOTE_WAIT_MAX = 150   -- a note waiting for a reloading partner's list gives up after this
local RELOG_KEEP = 600      -- logging back in this soon, in the same zone, keeps the hub (a disconnect)
local NEAR_PICKUP = 60      -- yards: your partner's pickup this close makes your spot part of your hub
local DOOR_WINDOW = 2       -- seconds after resting ends inside the inn's own area: the next one is its door
local HEARTH_SPELLS = { [8690] = true, [556] = true }  -- Hearthstone, Astral Recall
ns.HEARTH_SPELLS = HEARTH_SPELLS

-- The current hub, saved so a /reload (or a quick relog) doesn't forget it:
--   since  ns.Now() when you arrived     areas  [area] = "quest" | "rest" | "door"
--   name   what to call it               zone, at  where and when you last were there
--   rested, restArea  you rested here (an inn)   wild  the zone's name standing in for open road
-- ("door": the area you stepped into when you left a rest area. It keeps an
-- inn's town square in the hub.)
-- Gaps already warned about are kept in DB.told, across sessions.
local hub
local function NewHub()
  return { since = ns.Now(), areas = {} }
end
ns.hubSince = 0

local function Link(e)
  return ns.QuestLink(e.id, ns.QuestName(e), e.level)
end

local function HowText(e, owner)
  if e.how == "share" then return owner == "you" and "you can share it" or (owner .. " can share it") end
  if e.how == "maybe" then return owner == "you" and "try sharing it" or ("ask " .. owner .. " to share it") end
  if e.how == "failed" then return owner == "you" and "yours failed" or (owner .. "'s failed") end
  return owner == "you" and "can't be shared" or "can't be shared: get it yourself"
end
ns.HowText = HowText

-- Lines describing these gaps, or nil if there are none. max: entries per line
-- before "and N more" (nil = all).
function ns.GapLines(focus, theyNeed, iNeed, unsure, max)
  if #theyNeed == 0 and #iNeed == 0 then return nil end
  local lines = {}
  local function Add(list, prefix, owner)
    if #list == 0 then return end
    local parts = {}
    for _, e in ipairs(list) do parts[#parts + 1] = Link(e) .. " (" .. HowText(e, owner) .. ")" end
    lines[#lines + 1] = prefix .. ns.JoinList(parts, max) .. ((max and #parts > max) and " (/dq status)" or "")
  end
  Add(theyNeed, focus.name .. (unsure and " may not have: " or " doesn't have: "), "you")
  Add(iNeed, "You don't have: ", focus.name)
  return lines, #theyNeed + #iNeed
end

-- Where you are: the subzone, or the zone in unnamed wilderness (subOnly: nil there).
local function Area(subOnly)
  local sub = GetSubZoneText and plain(GetSubZoneText())
  if type(sub) == "string" and sub ~= "" then return sub end
  if subOnly then return nil end
  local z = GetRealZoneText and plain(GetRealZoneText())
  return type(z) == "string" and z ~= "" and z or nil
end

local zone
local function Save()
  hub.zone, hub.at = zone or hub.zone, ns.Now()
  if ns.DB then ns.DB.hub = hub end
  ns.hubSince = hub.since
end

local doorUntil  -- GetTime() until which a newly entered area counts as the inn's door
local function Arrived()
  hub = NewHub()
  doorUntil = nil  -- (the old hub's inn has nothing to do with the new one)
  Save()
end
ns.Arrived = Arrived

-- This area is part of the hub. Quest areas name the hub over rest areas
-- ("Goldshire", not "Lion's Pride Inn", when you handled quests outside).
local RANK = { door = 1, rest = 2, quest = 3 }
-- (Unnamed open country only stands in, as the zone's name, for a hub with
-- no areas yet: otherwise one accept on the road out of town would make the
-- whole zone's open country part of the town, and "Leaving" would never come.
-- And the stand-in (hub.wild) gives way as soon as a named place joins.)
local function HubArea(kind)
  return Area(kind == "door" or (hub ~= nil and next(hub.areas) ~= nil))
end
local function MarkHub(kind)
  local a = HubArea(kind)
  if not (a and hub) then return end
  if not Area(true) then
    hub.wild = a
  elseif hub.wild then  -- (a door is always a named place too: e.g. where he picked up a quest by you)
    hub.areas[hub.wild] = nil
    if hub.name == hub.wild then hub.name = nil end
    hub.wild = nil
  end
  if (RANK[hub.areas[a]] or 0) < RANK[kind] then hub.areas[a] = kind end
  -- (rested even if that area also had quests: see the door. restArea: where
  -- resting began on this visit, i.e. the inn)
  if kind == "rest" then hub.rested, hub.restArea = true, hub.restArea or a end
  -- (A town you only rested in is named after its streets, not the inn.)
  if not hub.name or (kind == "quest" and hub.areas[hub.name] ~= "quest")
      or (kind == "door" and (hub.areas[hub.name] == "rest" or hub.name == hub.restArea)) then
    hub.name = a
  end
  Save()
end

local held  -- a warning waiting for combat (or death) to end: { reason, place, since, areas, name, wild, rested, restArea }

local function InCombat()
  return (InCombatLockdown and plain(InCombatLockdown())) or (UnitAffectingCombat and plain(UnitAffectingCombat("player")))
end
local function Dead()
  return UnitIsDeadOrGhost and plain(UnitIsDeadOrGhost("player")) and true or false
end

local GIVER_FIRST = { giver = 1, failed = 2, maybe = 3, share = 4 }
local function WalkBackFirst(a, b)
  local fa, fb = (a.seenAt or 0) > 0, (b.seenAt or 0) > 0
  if fa ~= fb then return fa end
  local ga, gb = GIVER_FIRST[a.how] or 5, GIVER_FIRST[b.how] or 5
  if ga ~= gb then return ga < gb end
  local ta, tb = ns.QuestName(a), ns.QuestName(b)
  if ta ~= tb then return ta < tb end
  return a.id < b.id
end

-- reason: "town", "flight", "hearth", "zone". since: the hub's start (a held
-- warning keeps the one from when it was triggered). Returns true if it warned.
function ns.CheckLeaving(reason, place, since, wild)
  if not (ns.DB and ns.mineReady and ns.DB.warnLeave and hub) then return false end
  if Dead() then return false end  -- a graveyard trip isn't leaving
  since = since or hub.since
  local focus = ns.FocusPartner()
  if not focus then return false end
  -- Only about a partner you sync with, or one you picked yourself: a random
  -- groupmate without DuoQuest isn't your duo.
  -- (While they reload, the list from before still counts.)
  if not ((focus.data and (focus.data.synced or focus.data.resync)) or focus.chosen) then return false end
  -- Out-of-date data would warn about quests they've long picked up.
  if focus.data and ns.IsStale(focus.data) then return false end
  if InCombat() then
    -- A second signal in the same fight (a zone line) keeps the first one's
    -- start and areas, so the town's gaps aren't lost.
    local areas = held and held.areas or {}
    for a, kind in pairs(hub.areas) do areas[a] = areas[a] or kind end
    held = { reason = reason, place = place, since = held and math.min(held.since, since) or since, areas = areas,
      name = held and held.name or hub.name, wild = held and held.wild or hub.wild,
      rested = (held and held.rested) or hub.rested, restArea = (held and held.restArea) or hub.restArea }
    return false
  end
  local told = ns.DB.told
  -- Forget warnings about quests neither of you has any more (picked up
  -- again later, they're new gaps).
  local theirs = focus.data and focus.data.list or {}
  for id in pairs(told) do
    if not ns.mine[id] and not theirs[id] then told[id] = nil end
  end
  local view = ns.Compare(focus)
  -- Your partner is here now: what you picked up here before they arrived
  -- counts too.
  local theyNeed, iNeed = ns.Gaps(view, since, told, ns.Near(focus.unit) == true)
  -- The ones that cost a walk back come first: picked up here (not from
  -- before you synced), and can't be shared.
  for _, list in ipairs({ theyNeed, iNeed }) do table.sort(list, WalkBackFirst) end
  local lines, count = ns.GapLines(focus, theyNeed, iNeed, view.unsure, MAX_NAMED)
  if not lines then return false end  -- (a second signal for the same trip finds them all told)
  local allFromHere = true
  for _, list in ipairs({ theyNeed, iNeed }) do
    for _, e in ipairs(list) do
      told[e.id] = true  -- (also the "and N more": /dq status lists them)
      if (e.seenAt or 0) == 0 then allFromHere = false end
    end
  end
  -- (A hub that's only the zone's open road, e.g. an item-started quest: you
  -- haven't left the zone, just that spot.)
  -- (wild: the held hub's stand-in; a new hub may have replaced it meanwhile)
  if wild == nil then wild = hub.wild end
  local road = place ~= nil and place == wild
  local lead = ({ town = road and "Moving on" or ("Leaving " .. (place or "town")), flight = "Before you fly",
    hearth = "Before you hearth", hearthed = "You hearthed away from " .. (place or "town"),
    zone = "You left " .. (place or "the area") })[reason] or "Quest check"
  ns.Print("|cffff9933" .. lead .. ":|r")
  for _, line in ipairs(lines) do ns.Print("  " .. line) end
  if UIErrorsFrame and UIErrorsFrame.AddMessage then
    local who = (#theyNeed > 0 and #iNeed > 0) and ("You and " .. focus.name .. " are")
      or (#theyNeed > 0 and (focus.name .. " is")) or "You are"
    pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, string.format("DuoQuest: %s missing %d quest%s%s",
      view.unsure and (who:gsub(" is$", " may be"):gsub(" are$", " may be")) or who, count, count == 1 and "" or "s",
      allFromHere and " from here" or ""), 1, 0.6, 0.2)
  end
  if ns.DB.sound and PlaySound and SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_OPEN then
    pcall(PlaySound, SOUNDKIT.IG_QUEST_LIST_OPEN)  -- the quest-log sound, not a whisper's
  end
  return true
end

---------------------------------------------------------------------------
-- Leaving triggers
---------------------------------------------------------------------------
local onTaxi = false
local loadedAt = -math.huge
local awaySince

local function ReadZone()
  local z = GetRealZoneText and plain(GetRealZoneText())
  return type(z) == "string" and z ~= "" and z or nil
end
local function Resting()
  return IsResting and plain(IsResting()) and true or false
end

local hearthName
local function IsHearth(spellID)
  if HEARTH_SPELLS[spellID] then return true end
  -- Other hearthstones share the name on some clients ("... Hearthstone").
  local getName = C_Spell and C_Spell.GetSpellName
  if not getName then return false end
  hearthName = hearthName or plain(getName(8690))
  local name = plain(getName(spellID))
  return type(hearthName) == "string" and type(name) == "string" and name:find(hearthName, 1, true) ~= nil
end

local loading = false
ns.On("LOADING_SCREEN_ENABLED", function() loadedAt, loading = GetTime(), true end)
ns.On("LOADING_SCREEN_DISABLED", function() loadedAt, loading = GetTime(), false end)

-- The saved hub, if it's still where you are: always after a /reload; after
-- a login only if you were there moments ago (a disconnect), in the same zone.
local function SavedHub(isReload, z)
  local h = ns.DB and ns.DB.hub
  if type(h) ~= "table" or type(h.since) ~= "number" then return nil end
  if isReload then return h end
  local at = type(h.at) == "number" and h.at or 0
  if z and h.zone == z and ns.Now() - at <= RELOG_KEEP then return h end
  -- Logged out at the hub (say, its inn) and back in there, any time later:
  -- the same hub (you can't have picked anything up meanwhile).
  local area = Area()
  if z and h.zone == z and type(h.areas) == "table" and area and h.areas[area] and area ~= h.wild then return h end
  return nil
end

-- Login and /reload: the hub you were at (see SavedHub) or a new one. Any
-- other loading screen means you travelled (hearth, portal, dungeon, boat):
-- a new hub, even within the same zone.
ns.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
  isLogin, isReload = plain(isLogin), plain(isReload)
  loadedAt = GetTime()
  local z = ReadZone()
  local saved = not hub and (isReload or isLogin) and SavedHub(isReload, z)
  if saved then
    hub = saved
    hub.areas = type(hub.areas) == "table" and hub.areas or {}
    hub.told = nil  -- (early test builds kept these per hub)
    zone = z or hub.zone
    Save()
  elseif not isLogin and not isReload and Dead() then
    -- (Releasing your spirit: a graveyard trip isn't travelling. The corpse
    -- run brings you back to the hub, as without a loading screen.)
    zone = z or zone
  elseif not isReload or not hub then
    zone = z or zone
    Arrived()
    if Resting() then MarkHub("rest") end  -- logged in (or arrived) at a town
  end
  zone = z or zone
end)

-- Where you rest or handle quests is the hub. (Not a bonus objective that
-- auto-accepts as you walk into its area: that's the field, not the hub.)
-- Stepping out of a rest area (an inn's door) keeps the area outside in the
-- hub too: the town square isn't "leaving".
ns.On("PLAYER_UPDATE_RESTING", function()
  -- (Flying over a town, or taking off from one; a ghost's graveyard isn't the hub either.)
  if onTaxi or (UnitOnTaxi and plain(UnitOnTaxi("player"))) or Dead() then return end
  if Resting() then
    MarkHub("rest")
  elseif hub and hub.rested then
    -- Out of the inn: where you are now is its door. If the rest area ended
    -- while you were still in the inn's own area, the next place you walk
    -- into within DOOR_WINDOW is.
    local here = Area(true)
    if here and here == hub.restArea then
      doorUntil = GetTime() + DOOR_WINDOW
    else
      MarkHub("door")
    end
  end
end)
-- QUEST_ACCEPTED: (questID), or (logIndex, questID) on classic.
-- QUEST_TURNED_IN: (questID, xp, money). QUEST_COMPLETE: no quest ID.
for _, event in ipairs({ "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_COMPLETE" }) do
  ns.On(event, function(a, b)
    local id = (event == "QUEST_ACCEPTED" and plain(b)) or plain(a)
    if event ~= "QUEST_COMPLETE" and ns.IsTaskQuest(id) then return end
    if onTaxi or Dead() then return end  -- (a share accepted in flight, or as a ghost: not this spot)
    MarkHub("quest")
  end)
end

ns.On("ZONE_CHANGED_NEW_AREA", function()
  local z = ReadZone()
  if not hub then zone = z or zone return end  -- (before PLAYER_ENTERING_WORLD: that decides the hub)
  if not z or z == zone then return end
  local left = zone
  zone = z
  if Dead() then return end  -- a corpse run: not leaving
  if not onTaxi and not loading and left and GetTime() - loadedAt > LOAD_QUIET then
    ns.CheckLeaving("zone", left, hub and hub.since)
  end
  Arrived()
end)

-- (A flight map can fire both events; the second finds every gap already warned.)
local function FlightMap() ns.CheckLeaving("flight") end
ns.On("TAXIMAP_OPENED", FlightMap)
do
  local taxi = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.TaxiNode
  if taxi then
    ns.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(kind)
      if plain(kind) == taxi then FlightMap() end
    end)
  end
end

-- Only your own casts (a unit event, so other people's casts never wake us).
ns.OnUnit("UNIT_SPELLCAST_START", "player", function(unit, _, spellID)
  if plain(unit) ~= "player" then return end
  spellID = plain(spellID)
  if type(spellID) == "number" and IsHearth(spellID) then ns.CheckLeaving("hearth") end
end)
-- The hearth went off: you're somewhere else now, even when a short hop
-- skips the loading screen.
ns.OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", function(unit, _, spellID)
  if plain(unit) ~= "player" then return end
  spellID = plain(spellID)
  if type(spellID) == "number" and IsHearth(spellID) then
    loadedAt = GetTime()
    -- (Cast in a fight and gone through: the held warning comes after the
    -- trip, so it says so instead of "Before you hearth".)
    if held and held.reason == "hearth" then held.reason, held.place = "hearthed", held.name end
    Arrived()
  end
end)

-- The fight is over (or you're alive again): the held warning, unless you
-- ended up back in the hub. Dying in that fight keeps it held until you're
-- back on your feet.
local function DeliverHeld()
  local h = held
  if not h or InCombat() or Dead() then return end
  held = nil
  -- Walked off, fought, and came back into the hub (or a town)? Then you didn't leave.
  local area = Area()
  -- (Back in any town counts after walking off; after a zone line, only the hub itself does.)
  if (h.reason == "town" and Resting()) or ((h.reason == "town" or h.reason == "zone") and area and h.areas[area]) then
    -- ...and it's still the same hub, named as before.
    hub.since, hub.name, hub.wild, hub.rested, hub.restArea = h.since, h.name or hub.name, h.wild, h.rested, h.restArea
    for a, kind in pairs(h.areas) do hub.areas[a] = kind end
    Save()
    return
  end
  ns.CheckLeaving(h.reason, h.place, h.since, h.wild or false)
end
ns.On("PLAYER_REGEN_ENABLED", DeliverHeld)
ns.On("PLAYER_ALIVE", DeliverHeld)   -- released, or resurrected by a spirit healer / player
ns.On("PLAYER_UNGHOST", DeliverHeld) -- back in your body at the corpse

ns.Listen("TICK", function()
  local now = GetTime()
  if not hub then return end
  -- Taking off: whatever you land at is a new hub.
  local taxiNow = UnitOnTaxi and plain(UnitOnTaxi("player")) and true or false
  if taxiNow and not onTaxi then Arrived() end
  onTaxi = taxiNow
  if not taxiNow and not Dead() then hub.at = ns.Now() end  -- (still here: see SavedHub)
  if not taxiNow and Resting() and not Dead() then
    -- (resting without the event saying so: a login, or landing in a town)
    local here = HubArea("rest")
    if here and not hub.areas[here] then MarkHub("rest") end
  end
  if held then DeliverHeld() end  -- (in case the fight's end event came before combat cleared)
  -- Walking away: outside every area of this hub, and out of any town, for a while.
  local area = Area()
  if doorUntil then
    if now > doorUntil or taxiNow or Dead() then
      doorUntil = nil
    elseif area and Area(true) and not hub.areas[area] then
      doorUntil = nil
      MarkHub("door")
    end
  end
  if next(hub.areas) and area and not hub.areas[area] and not Resting() and not onTaxi and not Dead() then
    awaySince = awaySince or now
    if now - awaySince >= AWAY_FOR then
      awaySince = nil
      ns.CheckLeaving("town", hub.name, hub.since)
      Arrived()  -- warned or not, you've left
    end
  else
    awaySince = nil
  end
end)

---------------------------------------------------------------------------
-- Notes (/dq notify): checked again after a few seconds, because when you
-- both talk to the same quest giver your accepts arrive a moment apart.
-- Pickup notes stay quiet while your partner is right next to you (they can
-- see what you took, and the leave warning covers anything left over); the
-- "finished" note shows either way.
---------------------------------------------------------------------------
local told = {}     -- [key] = when it was printed: each note once, unless the quest comes back later
local NOTE_REPEAT = 60  -- a note about the same quest again only after this (picked up again later)
local NOTE_AFTER_LOAD = 3  -- seconds notes wait after a loading screen
local pending = {}  -- { key, at, tries, since, check } (check() returns text, or nil and whether to retry:
                    -- true = look again (counted), "wait" = their list is on the way (not counted))

-- After a loading screen, notes wait a moment for what was missed meanwhile
-- (the partner's answer to our request for his list).
ns.On("LOADING_SCREEN_DISABLED", function()
  for _, n in ipairs(pending) do n.at = math.max(n.at, GetTime() + NOTE_AFTER_LOAD) end
end)

local function Later(key, check)
  if told[key] and GetTime() - told[key] < NOTE_REPEAT then return end
  pending[#pending + 1] = { key = key, at = GetTime() + NOTE_DELAY, tries = 0, since = GetTime(), check = check }
end

ns.Listen("TICK", function()
  local now = GetTime()
  for i = #pending, 1, -1 do
    local n = pending[i]
    if not ns.DB.notify then
      table.remove(pending, i)  -- turned off: drop what was waiting
    elseif now >= n.at then
      local text, retry = n.check()
      if text and not (told[n.key] and now - told[n.key] < NOTE_REPEAT) then
        told[n.key] = now
        ns.Print(text)
        table.remove(pending, i)
      elseif retry == "wait" and now - n.since < NOTE_WAIT_MAX then
        n.at = now + NOTE_DELAY
      elseif retry and n.tries < NOTE_TRIES then
        n.tries = n.tries + 1
        n.at = now + NOTE_DELAY
      else
        table.remove(pending, i)
      end
    end
  end
end)

local function FocusSynced(key)
  local focus = ns.FocusPartner()
  if not focus or (key and focus.key ~= key) then return nil end
  local p = focus.data
  if not (p and p.synced) or ns.IsStale(p) then return nil end
  return focus, p
end

-- At the same hub (about 200 yards): pickup notes would only repeat what
-- you can both see; the leave warning covers anything left over.
local function Together(focus)
  return ns.Near(focus.unit) == true
end

-- Your partner took a quest you don't have (and haven't done).
ns.Listen("PARTNER_QUEST_ADDED", function(key, id)
  Later("add" .. id, function()
    local focus, p = FocusSynced(key)
    if not focus then
      local f = ns.FocusPartner()
      return nil, (f and f.key == key and f.data and f.data.resync) and "wait" or nil  -- (resyncing: look again)
    end
    if ns.mine[id] or ns.IsDone(id) or ns.IsIgnored(id) or Together(focus) then return nil end
    local q = p.quests[id]
    if not q then return nil, p.list[id] ~= nil end  -- still listed: details on the way, look again
    local e = { id = id, title = q.title, level = q.level, how = ns.HowToGet(p.list[id]) }
    return string.format("%s picked up %s, which you don't have (%s).", focus.name, Link(e), HowText(e, focus.name))
  end)
end)

-- A quest picked up (again): a new gap if it is one, even if an earlier copy
-- was warned about. Your partner handling quests right next to you makes
-- where you are part of your hub too (you may only have shopped there).
ns.Listen("PARTNER_QUEST_ADDED", function(key, id)
  local focus = ns.FocusPartner()
  if focus and focus.key == key then ns.DB.told[id] = nil end  -- (not a third player's pickup)
  local d = focus and focus.key == key and ns.Distance(focus.unit)
  if d and d <= NEAR_PICKUP and not onTaxi and not Dead() then MarkHub("door") end  -- (a named spot only)
end)

-- You took a quest your partner doesn't have.
ns.Listen("MINE_CHANGED", function(added, _, _, first)
  if first then return end
  local at = GetTime()
  for _, id in ipairs(added) do
    ns.DB.told[id] = nil
    Later("mine" .. id, function()
      local focus, p = FocusSynced()
      local rec = ns.mine[id]
      if not focus then
        local f = ns.FocusPartner()
        return nil, (f and f.data and f.data.resync) and "wait" or nil  -- (they're reloading: look again)
      end
      -- Whether they've turned it in comes from their client: not while
      -- they're offline, nor before their turned-in list has answered for
      -- this pickup (a pickup they never heard of, e.g. during their loading
      -- screen, waits until they have). A client that doesn't answer: any list
      -- of theirs once our next list (a minute at most) has surely reached them.
      if rec and (ns.Offline(focus) or ((p.acked[id] or -math.huge) < at and (p.doneAt or -math.huge) < at + ACK_LATE))
      then return nil, "wait" end
      if not rec or p.list[id] or p.done[id] or ns.IsIgnored(id) or Together(focus) then return nil end
      local e = { id = id, title = rec.title, level = rec.level, how = ns.HowToGet(rec.flags) }
      if e.how == "share" or e.how == "maybe" then
        -- (Notes only come while you're apart, so never "share it now".)
        return string.format("%s doesn't have %s: share it when you're together (Share in the DuoQuest window, "
          .. "or /dq share %d).", focus.name, Link(e), id)
      end
      return string.format("%s doesn't have %s, and it can't be shared: %s has to get it themselves (usually from "
        .. "the quest giver).", focus.name, Link(e), focus.name)
    end)
  end
end)

-- Your partner finished the objectives of a quest you're both on, and you haven't.
ns.Listen("PARTNER_QUEST_COMPLETE", function(key, id)
  Later("done" .. id, function()
    local focus, p = FocusSynced(key)
    local mine = ns.mine[id]
    local theirs = p and p.quests[id]
    if not focus or not mine or not theirs or ns.IsIgnored(id) or ns.HasFlag(mine.flags, ns.F_COMPLETE)
        or not ns.HasFlag(theirs.flags, ns.F_COMPLETE) then return nil end
    local left = {}
    for _, o in ipairs(mine.objs) do
      if not o.done then left[#left + 1] = (o.label ~= "" and (o.label .. " ") or "") .. ns.ObjText(o) end
    end
    return string.format("%s finished %s.%s", focus.name, ns.QuestLink(id, mine.title, mine.level),
      #left > 0 and (" You: " .. table.concat(left, ", ")) or "")
  end)
end)
