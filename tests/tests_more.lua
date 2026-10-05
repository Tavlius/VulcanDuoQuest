-- DuoQuest scenario tests added in the later audit rounds: real-client
-- situations (inn doors, deaths, hearths, disconnects, loading screens,
-- staggered arrivals, classic collapsed headers) and behavior the README
-- promises that the first suite didn't pin down.
package.path = assert(os.getenv("DQ_TESTS"), "DQ_TESTS unset: run tests/run.sh") .. "?.lua;" .. package.path
local H = require("harness")
local check = H.check

local function noErrors(c, label)
  check(label .. ": no errors", #c.errors() == 0, table.concat(c.errors(), " / "))
end

local function Duo(setupA, setupB, optsA, optsB)
  local a, b = H.duo(optsA, optsB)
  if setupA then setupA(a) end
  if setupB then setupB(b) end
  a.login() b.login()
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 40)
  return a, b
end

-- A copy of a client's saved settings, as the game would write and read them
-- back (so later sessions can't change the earlier one's).
local function Saved(c)
  local function Copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = Copy(v) end
    return out
  end
  return Copy(c.saved())
end

local function since(c, from) return table.concat(c.printed, "\n", from or 1) end

-- 1. Turning in a bonus objective out in the field doesn't make the field a
--    hub (QUEST_TURNED_IN is (questID, xp, money): the xp isn't a quest ID).
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  a.addQuest({ id = 301, title = "Town Q" }) b.addQuest({ id = 301, title = "Town Q" })
  H.run({ a, b }, 10)
  a.subzone = "Crystal Lake"
  H.run({ a, b }, 40)  -- walked away: a new hub with no areas yet
  a.subzone = "Jerod's Landing"
  a.addQuest({ id = 900, title = "Bonus", task = true }, true)
  a.fire("QUEST_TURNED_IN", 900, 450, 0)
  check("bonus turn-in: field isn't a hub area", next(a.realNs.DB.hub.areas) == nil)
  a.addQuest({ id = 450, title = "Ordinary" }, true)
  a.fire("QUEST_TURNED_IN", 450, 900, 0)
  check("ordinary turn-in: is (the quest ID is the first argument)", a.realNs.DB.hub.areas["Jerod's Landing"] == "quest")
  noErrors(a, "turn-in args")
end

-- 2. Logged in at an inn: stepping out into the town square isn't leaving;
--    walking out of town is.
do
  local a, b = H.duo()
  b.addQuest({ id = 501, title = "Mirel Old A" }, true)
  a.subzone, a.resting = "Lion's Pride Inn", true
  a.login() b.login()
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 40)
  local before = #a.printed
  a.subzone, a.resting = "Goldshire", false
  a.fire("PLAYER_UPDATE_RESTING")
  H.run({ a, b }, 40)
  check("inn door: the town square isn't leaving", not a.printedMatch("Leaving", before + 1), since(a, before + 1))
  check("inn door: the hub is named after the town", a.realNs.DB.hub.name == "Goldshire", a.realNs.DB.hub.name)
  a.subzone = "Crystal Lake"
  H.run({ a, b }, 40)
  check("inn door: walking out of town is", a.printedMatch("Leaving Goldshire", before + 1), since(a, before + 1))
  -- A city's rest area ending in unnamed open country: the country isn't hub.
  local c, d = H.duo()
  c.subzone, c.resting = "Lion's Pride Inn", true
  c.login() d.login()
  c.setGroup({ "Mirel" }) d.setGroup({ "Tavlius" })
  H.run({ c, d }, 40)
  c.subzone, c.resting = "", false
  c.fire("PLAYER_UPDATE_RESTING")
  check("rest area ending in open country: the country isn't hub", c.realNs.DB.hub.areas["Elwynn Forest"] == nil)
  noErrors(a, "inn door") noErrors(c, "city edge")
end

-- 3. Gaps of unknown age are warned about once, not again at every login.
do
  local function Session(savedA, savedB, wall)
    local a = H.boot({ name = "Tavlius", saved = savedA })
    local b = H.boot({ name = "Mirel", saved = savedB })
    if wall then a.wall, b.wall = wall, wall end
    a.addQuest({ id = 11, title = "Tavlius Old" }, true)
    b.addQuest({ id = 22, title = "Mirel Old" }, true)
    a.login() b.login()
    a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
    H.run({ a, b }, 40)
    local na = #a.printed
    a.fire("TAXIMAP_OPENED")
    return a, b, a.printedMatch("Mirel Old", na + 1) ~= nil
  end
  local a, b, first = Session()
  check("unknown age: warned at the first leave", first)
  local _, _, again = Session(Saved(a), Saved(b), a.wall + 7200)
  check("unknown age: not again at the next login", not again)
  -- Picked up again later (a new copy): a new gap.
  check("told list is saved", a.saved().told[22] == true)
end

-- 4. Staggered arrival: you got to the hub first and picked up a quest; your
--    partner arrives, and you leave together. Their own pickups made elsewhere
--    still don't count.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  a.distance.party1, b.distance.party1 = 260, 260
  a.addQuest({ id = 601, title = "Picked Up First" })
  b.addQuest({ id = 603, title = "Mirel Westfall Pickup" })
  H.run({ a, b }, 20)
  a.distance.party1, b.distance.party1 = 5, 5
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("staggered: your pickup before they arrived is warned", a.printedMatch("Picked Up First", before + 1))
  check("staggered: theirs from elsewhere isn't", not a.printedMatch("Mirel Westfall Pickup", before + 1))
  noErrors(a, "staggered")
end

-- 5. A walk-away warning held by a fight you die in: it waits until you're
--    alive again (not lost); and a zone line crossed in the same fight keeps
--    the town's gaps.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  a.addQuest({ id = 701, title = "Gap Here" })
  H.run({ a, b }, 10)
  a.subzone, a.combat = "Crystal Lake", true
  H.run({ a, b }, 40)
  a.dead, a.combat = true, false
  a.fire("PLAYER_REGEN_ENABLED")
  check("died: nothing while dead", not a.printedMatch("Gap Here"))
  a.fire("PLAYER_ALIVE")  -- released: a ghost, still dead
  check("died: nothing as a ghost", not a.printedMatch("Gap Here"))
  a.dead = false
  a.fire("PLAYER_UNGHOST")
  check("died: warned once alive again", a.printedMatch("Leaving Goldshire") and a.printedMatch("Gap Here"))
  -- Corpse-ran back to town and resurrected there: quiet.
  local c, d = Duo()
  c.subzone = "Goldshire"
  c.addQuest({ id = 702, title = "Back In Town" })
  H.run({ c, d }, 10)
  c.subzone, c.combat = "Crystal Lake", true
  H.run({ c, d }, 40)
  c.dead, c.combat = true, false
  c.fire("PLAYER_REGEN_ENABLED")
  c.subzone, c.dead = "Goldshire", false
  c.fire("PLAYER_UNGHOST")
  check("died: back at the hub when alive, quiet", not c.printedMatch("Back In Town"))
  -- Town held, then a zone line in the same fight: the town's gap still comes.
  local e, f = Duo()
  e.subzone = "Goldshire"
  e.addQuest({ id = 703, title = "Town Gap Kept" })
  H.run({ e, f }, 10)
  e.subzone, e.combat = "Crystal Lake", true
  H.run({ e, f }, 40)
  e.zone, e.subzone = "Westfall", "Longshore"
  e.fire("ZONE_CHANGED_NEW_AREA")
  H.run({ e, f }, 4)
  e.combat = false
  e.fire("PLAYER_REGEN_ENABLED")
  check("two signals in one fight: the town's gap is kept", e.printedMatch("Town Gap Kept"), since(e))
  noErrors(a, "died") noErrors(c, "died back") noErrors(e, "two signals")
end

-- 6. Fought back into the hub: it carries on, and leaving it later still warns.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  a.addQuest({ id = 300, title = "Hub Gap" })
  H.run({ a, b }, 10)
  a.subzone, a.combat = "Elwynn Forest", true
  H.run({ a, b }, 32)
  a.subzone, a.combat = "Goldshire", false
  a.fire("PLAYER_REGEN_ENABLED")
  check("fought back: quiet", not a.printedMatch("Hub Gap"))
  local before = #a.printed
  a.subzone = "Crystal Lake"
  H.run({ a, b }, 40)
  check("fought back: leaving again warns", a.printedMatch("Leaving Goldshire", before + 1), since(a, before + 1))
end

-- 7. A Hearthstone (or any loading screen) within the same zone starts a new hub.
do
  local a, b = Duo()
  a.subzone = "Eastvale Logging Camp"
  a.addQuest({ id = 802, title = "Eastvale Q" }) b.addQuest({ id = 802, title = "Eastvale Q" })
  H.run({ a, b }, 10)
  a.fire("UNIT_SPELLCAST_START", "player", "guid", 8690)
  a.fire("LOADING_SCREEN_ENABLED")
  a.subzone, a.resting = "Lion's Pride Inn", true
  a.fire("PLAYER_ENTERING_WORLD", false, false)
  a.fire("LOADING_SCREEN_DISABLED")
  a.fire("PLAYER_UPDATE_RESTING")
  H.run({ a, b }, 4)
  check("same-zone hearth: new hub", a.realNs.DB.hub.name == "Lion's Pride Inn", a.realNs.DB.hub.name)
  -- A /reload keeps it.
  local a2 = H.boot({ name = "Tavlius", saved = Saved(a) })
  a2.log, a2.subzone, a2.resting = a.log, a.subzone, true
  a2.group, a2.inGroup, a2.wall = { "Mirel" }, true, a.wall
  a2.login(true)
  check("reload: same hub", a2.realNs.DB.hub.name == "Lion's Pride Inn" and a2.realNs.hubSince == a.realNs.hubSince)
end

-- 8. A disconnect: logging back in within 10 minutes in the same zone keeps
--    the hub (and its gaps); so does logging back in at the hub itself any
--    time later (you logged out at its inn); anywhere else later is a new one.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  a.addQuest({ id = 810, title = "Before The Disconnect" })
  H.run({ a, b }, 10)
  local function Relog(after, zone, subzone)
    local a2 = H.boot({ name = "Tavlius", saved = Saved(a) })
    a2.log = a.log
    a2.subzone, a2.zone = subzone or "Goldshire", zone or "Elwynn Forest"
    a2.group, a2.inGroup = { "Mirel" }, true
    a2.wall = a.wall + after
    a2.login()
    H.run({ a2, b }, 40)
    a2.fire("TAXIMAP_OPENED")
    return a2.printedMatch("Before The Disconnect") ~= nil, a2  -- (walking off or flying: either warns)
  end
  local soon, a2 = Relog(120)
  check("disconnect: hub kept, gap warned", soon)
  check("disconnect: no error", #a2.errors() == 0, table.concat(a2.errors(), " / "))
  check("next day at the hub: same hub", Relog(72000))
  check("an hour later elsewhere in the zone: a new hub", not Relog(3600, nil, "Crystal Lake"))
  check("a few minutes later elsewhere in the zone: same hub (a disconnect)", Relog(300, nil, "Crystal Lake"))
  check("9 minutes later elsewhere in the zone: same hub (README: within 10 minutes)", Relog(540, nil, "Crystal Lake"))
  check("11 minutes later elsewhere in the zone: a new hub", not Relog(660, nil, "Crystal Lake"))
  check("another zone: a new hub", not Relog(120, "Westfall"))
end

-- 9. A partner who logs in while you're on a loading screen (their hello is
--    lost) is back in sync seconds after you arrive, not minutes.
do
  local a, b = Duo(function(a) a.addQuest({ id = 101, title = "A1" }, true) end,
    function(b) b.addQuest({ id = 201, title = "B1" }, true) end)
  for _ = 1, 300 do a.tick(1) H.deliver(a, { a }) end  -- Mirel logged off for a while
  local b2 = H.boot({ name = "Mirel", saved = Saved(b) })
  b2.addQuest({ id = 201, title = "B1" }, true)
  b2.addQuest({ id = 202, title = "B2" }, true)
  b2.inGroup, b2.group = true, { "Tavlius" }
  b2.now, b2.wall = a.now, a.wall
  a.dropFrom = function() return true end
  b2.login()
  for _ = 1, 20 do b2.tick(1) H.deliver(b2, { a, b2 }) end
  a.dropFrom = nil
  a.fire("PLAYER_ENTERING_WORLD", false, false)
  local t = 0
  while t < 400 do
    local pa, pb = a.ns.partners.Mirel, b2.ns.partners.Tavlius
    if pa and pa.synced and pa.quests[202] and not a.ns.IsStale(pa) and pb and pb.synced and pb.quests[101] then break end
    H.run({ a, b2 }, 1)
    t = t + 1
  end
  check("loading screen: resynced within 15s", t <= 30, t / 2 .. "s")
  -- Alone in the group: a loading screen says hello (no list to send).
  local c = H.boot({ name = "Tavlius" })
  c.login()
  c.setGroup({ "Stranger" })
  c.tick(60)
  local n = c.sentMatching("|H|")
  c.fire("PLAYER_ENTERING_WORLD", false, false)
  c.tick(2)
  check("loading screen, nobody synced: a hello", c.sentMatching("|H|") == n + 1)
  -- Login and /reload don't send extra (their own hello covers it).
  local m = #a.addonSent
  a.fire("PLAYER_ENTERING_WORLD", false, true)
  a.tick(2)
  check("reload event: no extra list", a.sentMatching("|L|", m + 1) == 0)
end

-- 10. Partner pickup times survive your /reload: theirs made at this hub stay
--     "from here", theirs made elsewhere stay out.
do
  local a, b = Duo()
  a.distance.party1, b.distance.party1 = 900, 900
  b.addQuest({ id = 1001, title = "Mirel Far Pickup" })
  H.run({ a, b }, 10)
  a.distance.party1, b.distance.party1 = nil, nil
  b.addQuest({ id = 1002, title = "Mirel Here Pickup" })
  H.run({ a, b }, 10)
  local a2 = H.boot({ name = "Tavlius", saved = Saved(a) })
  a2.log = a.log
  a2.group, a2.inGroup, a2.wall, a2.now = { "Mirel" }, true, a.wall, a.now
  a2.login(true)
  H.run({ a2, b }, 40)
  local before = #a2.printed
  a2.fire("TAXIMAP_OPENED")
  check("reload: partner's pickup here still warned", a2.printedMatch("Mirel Here Pickup", before + 1), since(a2, before + 1))
  check("reload: partner's far pickup still left out", not a2.printedMatch("Mirel Far Pickup", before + 1))
  check("reload: known ages say 'from here'", (a2.errorsFrame[#a2.errorsFrame] or ""):find("from here"),
    a2.errorsFrame[#a2.errorsFrame])
  -- Your own pickup made while they were elsewhere, still elsewhere after the reload: out.
  local c, d = Duo()
  c.distance.party1 = 900
  c.addQuest({ id = 1003, title = "My Far Pickup" })
  H.run({ c, d }, 10)
  local c2 = H.boot({ name = "Tavlius", saved = Saved(c) })
  c2.log, c2.distance.party1 = c.log, 900
  c2.group, c2.inGroup, c2.wall = { "Mirel" }, true, c.wall
  c2.login(true)
  H.run({ c2, d }, 40)
  before = #c2.printed
  c2.fire("TAXIMAP_OPENED")
  check("reload: own away flag kept", not c2.printedMatch("My Far Pickup", before + 1))
  noErrors(a2, "reload ages")
end

-- 11. Classic quest API: a collapsed header doesn't drop your quests (the
--     client has C_QuestLog.IsOnQuest); without it, they drop (documented).
do
  local a, b = Duo(function(a)
    a.log[#a.log + 1] = { header = "Elwynn Forest" }
    a.addQuest({ id = 41, title = "Wolves", objs = { { label = "Wolf Meat", have = 3, need = 8 } } }, true)
  end, function(b)
    b.addQuest({ id = 41, title = "Wolves", objs = { { label = "Wolf Meat", have = 1, need = 8 } } }, true)
  end, { name = "Tavlius", classic = true })
  a.collapsed["Elwynn Forest"] = true
  a.fire("QUEST_LOG_UPDATE")
  H.run({ a, b }, 20)
  check("classic collapsed: quest kept", a.ns.mine[41] ~= nil)
  check("classic collapsed: partner still sees it", b.ns.partners.Tavlius.list[41] ~= nil)
  a.quest(41).objs[1].have = 5
  a.fire("QUEST_LOG_UPDATE")
  H.run({ a, b }, 20)
  check("classic collapsed: progress still read", b.ns.partners.Tavlius.quests[41].objs[1].have == 5)
  a.collapsed["Elwynn Forest"] = nil
  a.fire("QUEST_LOG_UPDATE")
  H.run({ a, b }, 20)
  check("classic re-expanded: not a new pickup", (a.realNs.seenAt[41] or 0) == 0)
  -- After a /reload under the collapsed header.
  a.collapsed["Elwynn Forest"] = true
  local a2 = H.boot({ name = "Tavlius", saved = Saved(a), classic = true })
  a2.log, a2.collapsed = a.log, a.collapsed
  a2.group, a2.inGroup = { "Mirel" }, true
  a2.login(true)
  H.run({ a2, b }, 20)
  check("classic collapsed after reload: kept with its title", a2.ns.mine[41] and a2.ns.mine[41].title == "Wolves")
  local c = H.boot({ name = "Tavlius", classic = true, classicBare = true })
  c.log[#c.log + 1] = { header = "Elwynn Forest" }
  c.addQuest({ id = 42, title = "Bare" }, true)
  c.login()
  c.collapsed["Elwynn Forest"] = true
  c.fire("QUEST_LOG_UPDATE")
  c.tick(4)
  check("classic without IsOnQuest: collapsed quests can't be read", c.ns.mine[42] == nil)
  noErrors(a, "classic collapsed") noErrors(c, "classic bare")
end

-- 12. In a bigger group, your usual partner keeps the window after a reload
--     even if someone else's DuoQuest answers first.
do
  local a = H.boot({ name = "Tavlius" })
  local b = H.boot({ name = "Mirel" })
  local f = H.boot({ name = "Aaron" })
  for _, c in ipairs({ a, b, f }) do c.login() end
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 40)
  a.setGroup({ "Mirel", "Aaron" }) b.setGroup({ "Tavlius", "Aaron" }) f.setGroup({ "Tavlius", "Mirel" })
  H.run({ a, b, f }, 40)
  local a2 = H.boot({ name = "Tavlius", saved = Saved(a) })
  a2.group, a2.inGroup = { "Mirel", "Aaron" }, true
  a2.login(true)
  for _ = 1, 20 do  -- Mirel's messages are lost for 10s; Aaron's arrive
    a2.tick(1) b.tick(1) f.tick(1)
    H.deliver(a2, { b, f }) H.deliver(f, { a2, b })
    b.delivered = #b.addonSent
  end
  check("focus: usual partner kept while waiting", a2.ns.FocusPartner().key == "Mirel", a2.ns.FocusPartner().key)
  H.run({ a2, b, f }, 120)
  check("focus: still the usual partner", a2.ns.FocusPartner().key == "Mirel" and a2.realNs.DB.lastPartner == "Mirel",
    a2.realNs.DB.lastPartner)
end

-- 13. A partner who already finished a quest you're both on when you group
--     up: no "finished" note (that's old news).
do
  local a = Duo(function(a)
    a.addQuest({ id = 1, title = "Shared", objs = { { label = "x", have = 1, need = 5 } } }, true)
  end, function(b)
    b.addQuest({ id = 1, title = "Shared", objs = { { label = "x", have = 5, need = 5 } } }, true)
  end)
  check("join: no finish note for old progress", not a.printedMatch("Mirel finished"))
end

-- 14. Odd but real client details.
do
  -- Same-realm names that read with an empty realm.
  local a, b = Duo(nil, nil, { name = "Tavlius", realm = "" }, { name = "Mirel", realm = "" })
  a.addQuest({ id = 400, title = "Empty Realm" })
  H.run({ a, b }, 20)
  check("empty realm: synced", b.statusText():find("Synced with Tavlius"), b.statusText())
  -- Older clients: SendAddonMessage returns true.
  local c, d = H.duo()
  c.login() d.login()
  c.sendReturnsTrue = true
  c.setGroup({ "Mirel" }) d.setGroup({ "Tavlius" })
  H.run({ c, d }, 40)
  check("send returning true counts as sent", d.ns.partners.Tavlius and d.ns.partners.Tavlius.synced)
  -- Forged part 0 doesn't empty a list.
  local e, f = Duo(function(e) e.addQuest({ id = 8, title = "Keep" }, true) end)
  f.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|L|77|0|1|", "PARTY", "Tavlius-Realm")
  check("part 0 rejected", f.ns.partners.Tavlius.list[8] ~= nil)
  -- A message builder that throws: nothing odd goes out.
  H.use(e)
  local n = #e.addonSent
  e.ns.channel:Send("X", function() error("boom") end)
  e.tick(4)
  local odd = 0
  for i = n + 1, #e.addonSent do if not e.addonSent[i].msg:match("^%d+|%u") then odd = odd + 1 end end
  check("throwing builder sends nothing", odd == 0, odd)
end

-- 15. What you see changing goes out first: a pickup, its removal and the
--     done list jump a full resend's backlog.
do
  local a, b = Duo(function(a)
    for i = 1, 20 do a.addQuest({ id = 1100 + i, title = "Backlog " .. i }, true) end
  end)
  H.use(a)
  a.ns.SendFull()
  local n = #a.addonSent
  a.addQuest({ id = 1200, title = "Fresh Pickup" })
  a.tick(6)
  local firstNew = a.addonSent[n + 1] and a.addonSent[n + 1].msg or ""
  local pickupAt, backlogAt
  for i = n + 1, #a.addonSent do
    local m = a.addonSent[i].msg
    if not pickupAt and m:find("Fresh Pickup") then pickupAt = i end
    if not backlogAt and m:find("Backlog") then backlogAt = i end
  end
  check("priority: the pickup goes before the backlog", pickupAt and (not backlogAt or pickupAt < backlogAt),
    firstNew)
  a.removeQuest(1200)
  local m2 = #a.addonSent
  a.tick(4)
  local removedFirst = a.addonSent[m2 + 1] and a.addonSent[m2 + 1].msg:find("|D|" .. a.ns.To36(1200)) ~= nil
  check("priority: the removal goes first", removedFirst, a.addonSent[m2 + 1] and a.addonSent[m2 + 1].msg)
  H.run({ a, b }, 80)
  check("priority: everything arrives", b.ns.partners.Tavlius.quests[1120] ~= nil and b.ns.partners.Tavlius.list[1200] == nil)
end

-- 16. Commands and window details the README promises.
do
  local a = H.boot()
  a.login()
  a.slash("warn on")
  check("/dq warn on keeps it on", a.ns.DB.warnLeave == true)
  a.slash("warn off") a.slash("warn off")
  check("/dq warn off keeps it off", a.ns.DB.warnLeave == false)
  a.slash("debug off")
  check("/dq debug off keeps it off", a.ns.DB.debug == false)
  a.ui:Drag(10, 10)
  a.ns.PlaceFrame()
  a.slash("resetpos")
  local p = a.ui.points and a.ui.points[#a.ui.points]
  check("/dq resetpos moves the window now", p and p[4] == 260 and p[5] == -220, p and tostring(p[5]))

  local c = Duo(function(c)
    c.addQuest({ id = 7, title = "Shared Boars", objs = { { label = "Tusk", have = 1, need = 5 }, { label = "Hide", have = 0, need = 2 } } }, true)
    c.addQuest({ id = 8, title = "One Thing", objs = { { label = "Snout", have = 3, need = 6 } } }, true)
  end, function(d)
    d.addQuest({ id = 7, title = "Shared Boars", objs = { { label = "Tusk", have = 2, need = 5 }, { label = "Hide", have = 0, need = 2 } } }, true)
    d.addQuest({ id = 8, title = "One Thing", objs = { { label = "Snout", have = 4, need = 6 } } }, true)
  end)
  check("objectives shown", c.windowText():find("Tusk || 1/5 | 2/5", 1, true), c.windowText())
  check("one objective: on the quest's row, no extra row", c.windowText():find("One Thing || 3/6 | 4/6", 1, true)
    and not c.windowText():find("Snout"), c.windowText())
  c.rowFor("Shared Boars"):Hover()
  local tip = table.concat(c.tooltip, "\n")
  check("hover: your objectives and theirs", tip:find("You: Tusk") and tip:find("Mirel: Tusk"), tip)
  c.slash("objectives off")
  c.tick(2)
  check("/dq objectives off hides them", not c.windowText():find("Tusk"), c.windowText())

  local e = H.boot()
  e.addQuest({ id = 10, title = "Q" }, true)
  e.login()
  e.unitOnQuest.party1 = { [10] = true }
  e.setGroup({ "Stranger" })
  e.tick(40)
  local before = #e.printed
  e.slash("status")
  check("/dq status without their DuoQuest says so, not 'no gaps'", e.printedMatch("doesn't run DuoQuest", before + 1)
    and not e.printedMatch("no gaps", before + 1), since(e, before + 1))

  local f = Duo(function(f)
    f.addQuest({ id = 70, title = "Ready Mine", objs = { { label = "x", have = 1, need = 1 } } }, true)
    f.addQuest({ id = 71, title = "Shared Ready", objs = { { label = "x", have = 1, need = 1 } } }, true)
  end, function(g)
    g.addQuest({ id = 71, title = "Shared Ready", objs = { { label = "x", have = 0, need = 1 } } }, true)
  end)
  before = #f.printed
  f.slash("status")
  check("/dq status: your ready count", f.printedMatch("both on 1; ready to turn in: you 1, Mirel 0", before + 1), since(f, before + 1))
  noErrors(c, "commands") noErrors(e, "status")
end

-- 17. Classic (shareability unknown): your pickup note offers a share, not "can't be shared".
do
  local a, b = Duo(nil, nil, { name = "Tavlius", classic = true }, { name = "Mirel", classic = true })
  a.distance.party1, b.distance.party1 = 900, 900
  a.addQuest({ id = 13, title = "Maybe Share", objs = { { label = "x", have = 0, need = 2 } } })
  H.run({ a, b }, 30)
  check("classic note offers a share", a.printedMatch("Maybe Share") and not a.printedMatch("can't be shared"), since(a))
end

-- 18. More than five gaps: the ones that cost a walk back are named first
--     (picked up here, quest giver only); every gap in the warning counts as
--     warned; /dq status has the full list. A flight map's two events warn once.
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 1310, title = "AAA Old Before Sync" }, true)  -- unknown age
  end)
  for i = 1, 6 do a.addQuest({ id = 1300 + i, title = "Many " .. i }) end
  a.addQuest({ id = 1309, title = "ZZZ Giver Only", pushable = false })
  H.run({ a, b }, 20)
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  a.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 6)
  local text = since(a, before + 1)
  check("many gaps: one warning per flight map", a.printedCount("Before you fly", before + 1) == 1, text)
  check("many gaps: quest-giver-only named first", text:find("doesn't have: [^\n]*ZZZ Giver Only[^\n]*Many 1"), text)
  check("many gaps: unknown age last (in 'more')", not text:find("AAA Old Before Sync"), text)
  check("many gaps: 'and 3 more (/dq status)'", text:find("and 3 more %(/dq status%)"), text)
  a.tick(8)
  before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("many gaps: all counted as warned", not a.printedMatch("Before you fly", before + 1), since(a, before + 1))
  a.slash("status")
  check("many gaps: /dq status lists the rest", a.printedMatch("AAA Old Before Sync", before + 1)
    and a.printedMatch("Many 6", before + 1))
  -- Abandoned and picked up again: a new gap (no leave check needed in between).
  a.removeQuest(1301)
  H.run({ a, b }, 10)
  a.addQuest({ id = 1301, title = "Many 1" })
  H.run({ a, b }, 10)
  a.tick(8)
  before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("many gaps: abandoned and picked up again is new", a.printedMatch("Many 1", before + 1), since(a, before + 1))
  -- Theirs too.
  b.addQuest({ id = 1320, title = "Mirel Repick" })
  H.run({ a, b }, 10)
  a.tick(8)
  a.fire("TAXIMAP_OPENED")
  b.removeQuest(1320)
  H.run({ a, b }, 10)
  b.addQuest({ id = 1320, title = "Mirel Repick" })
  H.run({ a, b }, 10)
  a.tick(8)
  before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("many gaps: partner's re-pick is new", a.printedMatch("Mirel Repick", before + 1), since(a, before + 1))
end

-- 19. A partner's resend request that arrives before we can send is answered later.
do
  local a = Duo(function(a) a.addQuest({ id = 1400, title = "Answer Later" }, true) end)
  H.use(a)
  a.inGroup = false  -- (roster says solo for a moment)
  local before = a.sentMatching("Answer Later")
  a.realNs.channel.onPeer("Mirel", "request")
  a.inGroup = true
  a.tick(4)
  check("request while unable to send: answered once possible", a.sentMatching("Answer Later") > before)
end

-- 20. A partner gone quiet (a long boss fight on their side): our list
--     repeats every three minutes, not every minute.
do
  local a, b = Duo()
  a.dropFrom = function() return true end
  H.run({ a, b }, 400)  -- 200s: Mirel is stale
  local n = a.sentMatching("|L|")
  H.run({ a, b }, 240)  -- 120s more
  check("quiet partner: slower heartbeat", a.sentMatching("|L|") - n <= 1, a.sentMatching("|L|") - n)
end

-- 21. A partner quest whose details were lost: the window uses the game's
--     title for it, and shows what their list says (ready).
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 1500, title = "Shared Lost", objs = { { label = "x", have = 0, need = 2 } } }, true)
  end)
  a.titleCache = { [1501] = "Cached Title" }
  a.dropFrom = function(m) return m.msg:find("|U|") ~= nil end
  b.addQuest({ id = 1501, title = "Mirel Lost Details" })
  b.addQuest({ id = 1500, title = "Shared Lost", objs = { { label = "x", have = 2, need = 2 } } })
  H.run({ a, b }, 20)
  b.ns.SendFull()
  H.run({ a, b }, 20)
  local w = a.windowText()
  check("lost details: the game's title", w:find("Cached Title"), w)
  local row = a.rowFor("Shared Lost")
  check("lost details: their list's 'ready' shows", row and (row.right.text or ""):find("ready"), row and row.right.text)
end

-- 22. A zone line crossed in a fight and crossed back into the hub: quiet.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  a.addQuest({ id = 1600, title = "Zone Back" })
  H.run({ a, b }, 10)
  a.combat = true
  a.zone, a.subzone = "Westfall", "Longshore"
  a.fire("ZONE_CHANGED_NEW_AREA")
  H.run({ a, b }, 4)
  a.zone, a.subzone = "Elwynn Forest", "Goldshire"
  a.fire("ZONE_CHANGED_NEW_AREA")
  a.combat = false
  a.fire("PLAYER_REGEN_ENABLED")
  check("zone line and back in a fight: quiet", not a.printedMatch("Zone Back"), since(a))
  local before = #a.printed
  a.subzone = "Crystal Lake"
  H.run({ a, b }, 40)
  check("zone line and back: leaving later warns", a.printedMatch("Zone Back", before + 1), since(a, before + 1))
  check("zone line and back: the hub keeps its name", a.printedMatch("Leaving Goldshire", before + 1), since(a, before + 1))
end

-- 23. A long stay at one hub: a disconnect after it still keeps the hub.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  a.addQuest({ id = 1700, title = "Long Stay" })
  H.run({ a, b }, 1400)  -- 700s at the hub, no quest events
  local a2 = H.boot({ name = "Tavlius", saved = Saved(a) })
  a2.log, a2.subzone = a.log, "Crystal Lake"  -- (back in just outside town)
  a2.group, a2.inGroup, a2.wall = { "Mirel" }, true, a.wall + 60
  a2.login()
  H.run({ a2, b }, 40)
  a2.fire("TAXIMAP_OPENED")
  check("long stay then disconnect: hub kept", a2.printedMatch("Long Stay"), since(a2))
end

-- 24. A groupmate without DuoQuest, on a client where party quest data is a
--     secret: nothing is claimed about them.
do
  local a = H.boot({ name = "Tavlius", secrets = { unitOnQuest = true } })
  a.addQuest({ id = 1800, title = "Secret Party Data" }, true)
  a.login()
  a.setGroup({ "Stranger" })
  a.tick(40)
  check("secret party data: no 'may not have'", not a.windowText():find("may not have"), a.windowText())
  noErrors(a, "secret party data")
end

-- 25. Status line: a partner who went offline, or turned sync off.
do
  local a, b = Duo()
  a.offline = { party1 = true }
  a.tick(12)
  check("status: offline partner", a.statusText():find("Mirel is offline"), a.statusText())
  a.offline = nil
  b.slash("sync off")
  H.run({ a, b }, 12)
  check("status: partner turned sync off", a.statusText():find("Mirel turned DuoQuest sync off"), a.statusText())
  b.slash("sync on")
  H.run({ a, b }, 20)
  check("status: back on", a.statusText():find("Synced with Mirel"), a.statusText())
end

-- 26. Your pickups while Mirel wasn't with you (not grouped, offline, far):
--     not "from here" while he's elsewhere, warned once he's with you.
do
  local a, b = H.duo()
  a.login() b.login()
  a.addQuest({ id = 1900, title = "Solo Before Grouping" })
  a.tick(4)
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  a.distance.party1, b.distance.party1 = 3000, 3000
  H.run({ a, b }, 40)
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("solo pickup, partner far: not warned", not a.printedMatch("Solo Before Grouping", before + 1),
    since(a, before + 1))
  a.offline = { party1 = true }
  a.distance.party1, b.distance.party1 = nil, nil
  a.addQuest({ id = 1901, title = "While Mirel Offline" })
  H.run({ a, b }, 10)
  check("offline partner: pickup marked away", a.realNs.awayMine[1901] == true)
  a.offline = nil
  a.tick(8)
  before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("together now: both warned", a.printedMatch("Solo Before Grouping", before + 1)
    and a.printedMatch("While Mirel Offline", before + 1), since(a, before + 1))
end

-- 27. A Hearthstone that skips the loading screen (a short hop) still starts a new hub.
do
  local a, b = Duo()
  a.subzone = "Eastvale Logging Camp"
  a.addQuest({ id = 2000, title = "Eastvale Two" }) b.addQuest({ id = 2000, title = "Eastvale Two" })
  H.run({ a, b }, 10)
  a.fire("UNIT_SPELLCAST_START", "player", "guid", 8690)
  a.subzone = "Goldshire"
  a.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 8690)
  check("hearth without loading screen: new hub", next(a.realNs.DB.hub.areas) == nil)
  a.addQuest({ id = 2001, title = "Goldshire Two" }) b.addQuest({ id = 2001, title = "Goldshire Two" })
  a.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 133)
  check("another spell: no new hub", a.realNs.DB.hub.areas.Goldshire == "quest")
  -- Flying over a town that rests you doesn't add it to the hub.
  a.onTaxi = true
  a.tick(2)
  a.subzone, a.resting = "Lakeshire", true
  a.fire("PLAYER_UPDATE_RESTING")
  check("flying over a town: not part of the hub", a.realNs.DB.hub.areas.Lakeshire == nil)
end

-- 28. Held warnings: delivered once (a later fight doesn't bring it back);
--     a resurrection by another player (PLAYER_ALIVE only) delivers it; coming
--     back into any rest area cancels it.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  a.addQuest({ id = 2100, title = "Held Once" })
  H.run({ a, b }, 10)
  a.subzone, a.combat = "Crystal Lake", true
  H.run({ a, b }, 40)
  a.combat = false
  a.fire("PLAYER_REGEN_ENABLED")
  check("held: delivered", a.printedCount("Held Once") == 1)
  a.combat = true
  a.addQuest({ id = 2101, title = "Later Pickup" })
  H.run({ a, b }, 4)
  a.combat = false
  a.fire("PLAYER_REGEN_ENABLED")
  check("held: not delivered again after the next fight", a.printedCount("Leaving") == 1, since(a))

  local c, d = Duo()
  c.subzone = "Goldshire"
  c.addQuest({ id = 2102, title = "Rezzed By Mirel" })
  H.run({ c, d }, 10)
  c.subzone, c.combat = "Crystal Lake", true
  H.run({ c, d }, 40)
  c.dead, c.combat = true, false
  c.fire("PLAYER_REGEN_ENABLED")
  c.dead = false
  c.fire("PLAYER_ALIVE")
  check("held: delivered on a player's resurrection", c.printedMatch("Rezzed By Mirel"))

  local e, f = Duo()
  e.subzone = "Goldshire"
  e.addQuest({ id = 2103, title = "Back In An Inn" })
  H.run({ e, f }, 10)
  e.subzone, e.combat = "Crystal Lake", true
  H.run({ e, f }, 40)
  e.subzone, e.resting, e.combat = "Lakeshire Inn", true, false
  e.fire("PLAYER_REGEN_ENABLED")
  check("held: back in a rest area, quiet", not e.printedMatch("Back In An Inn"))
  -- Combat still reads true at the fight's end event: delivered on the next tick.
  local g, h = Duo()
  g.subzone = "Goldshire"
  g.addQuest({ id = 2104, title = "Late Combat Flag" })
  H.run({ g, h }, 10)
  g.subzone, g.combat = "Crystal Lake", true
  H.run({ g, h }, 40)
  g.fire("PLAYER_REGEN_ENABLED")
  g.combat = false
  g.tick(2)
  check("held: delivered once combat clears", g.printedMatch("Late Combat Flag"))
end

-- 29. Classic quest API under a collapsed header: abandoning still removes the
--     quest; failed, finished and level carry over.
do
  local a, b = Duo(function(a)
    a.log[#a.log + 1] = { header = "Westfall" }
    a.addQuest({ id = 51, title = "Will Fail", level = 14, objs = { { label = "x", have = 0, need = 2 } } }, true)
    a.addQuest({ id = 52, title = "Will Finish", level = 15, objs = { { label = "y", have = 0, need = 1 } } }, true)
    a.addQuest({ id = 53, title = "Delivery", level = 16 }, true)
    a.addQuest({ id = 54, title = "Abandon Me" }, true)
    a.addQuest({ id = 55, title = "Half Done", objs = { { label = "p", have = 1, need = 1 }, { label = "q", have = 0, need = 3 } } }, true)
  end, nil, { name = "Tavlius", classic = true })
  a.quest(51).failed = true
  a.fire("QUEST_LOG_UPDATE")
  H.run({ a, b }, 10)
  a.collapsed.Westfall = true
  a.quest(52).objs[1].have = 1
  a.fire("QUEST_LOG_UPDATE")
  H.run({ a, b }, 10)
  local m = a.ns.mine
  check("classic collapsed: failed kept", m[51] and a.ns.HasFlag(m[51].flags, a.realNs.F_FAILED)
    and not a.ns.HasFlag(m[51].flags, a.realNs.F_COMPLETE))
  check("classic collapsed: finished from objectives", m[52] and a.ns.HasFlag(m[52].flags, a.realNs.F_COMPLETE))
  check("classic collapsed: level kept", m[52] and m[52].level == 15 and m[53] and m[53].level == 16)
  check("classic collapsed: half done isn't finished", m[55] and not a.ns.HasFlag(m[55].flags, a.realNs.F_COMPLETE))
  check("classic collapsed: delivery quest not made ready", m[53] and not a.ns.HasFlag(m[53].flags, a.realNs.F_COMPLETE))
  a.removeQuest(54)
  H.run({ a, b }, 10)
  check("classic collapsed: abandoned quest goes", a.ns.mine[54] == nil and b.ns.partners.Tavlius.list[54] == nil)
end

-- 30. Modern client: a quest under a collapsed header after a /reload keeps its title.
do
  local a = H.boot({ name = "Tavlius" })
  a.log[#a.log + 1] = { header = "Duskwood" }
  a.addQuest({ id = 61, title = "Under The Header" }, true)
  a.login()
  a.collapsed.Duskwood = true
  local a2 = H.boot({ name = "Tavlius", saved = Saved(a) })
  a2.log, a2.collapsed = a.log, a.collapsed
  a2.login(true)
  check("modern collapsed after reload: title", a2.ns.mine[61] and a2.ns.mine[61].title == "Under The Header",
    a2.ns.mine[61] and a2.ns.mine[61].title)
end

-- 31. Your partner reloads: the window keeps their quests while the new list comes in.
do
  local a, b = Duo(function(a) a.addQuest({ id = 70, title = "Mine Alone" }, true) end,
    function(b) b.addQuest({ id = 71, title = "Theirs Alone" }, true) end)
  local b2 = H.boot({ name = "Mirel", saved = Saved(b) })
  b2.log = b.log
  b2.group, b2.inGroup, b2.now, b2.wall = { "Tavlius" }, true, b.now, b.wall
  a.dropFrom = function(m) return not m.msg:find("|H|") end  -- only their hello gets through for now
  b2.login(true)
  H.run({ a, b2 }, 2)
  check("partner reload: still shows their quests", a.windowText():find("Theirs Alone"), a.windowText())
  check("partner reload: says resyncing", a.statusText():find("Resyncing with Mirel"), a.statusText())
  check("partner reload: no 'may not have'", not a.windowText():find("may not have"), a.windowText())
  a.dropFrom = nil
  H.run({ a, b2 }, 20)
  check("partner reload: synced again", a.statusText():find("Synced with Mirel"), a.statusText())
end

-- 32. Window and status text for the less common cases.
do
  -- A quest only the partner can (maybe) share: "ask Mirel".
  local a = Duo(nil, function(b) b.addQuest({ id = 80, title = "Mirel Can Share" }, true) end)
  check("you don't have: 'ask Mirel'", (a.rowFor("Mirel Can Share").right.text or ""):find("ask Mirel"),
    a.rowFor("Mirel Can Share").right.text)
  -- Grouped, nobody runs DuoQuest, more than one other.
  local c = H.boot()
  c.login()
  c.setGroup({ "Bob", "Dana" })
  c.slash("solo on")  -- (no one to compare with: the window only shows when asked)
  c.tick(40)
  check("status: nobody runs DuoQuest", c.statusText():find("Nobody here runs DuoQuest yet"), c.statusText())
  -- Picked by display name (before grouping) with a partner from another realm.
  local e, f = H.duo({ name = "Tavlius", realm = "Other" }, { name = "Mirel", myRealm = "Other" })
  e.login() f.login()
  e.slash("partner mirel")
  e.setGroup({ "Mirel", "Bob" }) f.setGroup({ "Tavlius", "Bob" })
  H.run({ e, f }, 40)
  local fp = e.ns.FocusPartner()
  check("partner by display name across realms", fp and fp.chosen == true and fp.name == "Mirel", fp and fp.key)
  -- Their details arriving before their first list keep the saved pickup time.
  local g, h = Duo()
  h.addQuest({ id = 90, title = "Saved Time" })
  H.run({ g, h }, 10)
  local t = g.realNs.partners.Mirel.seenAt[90]
  local g2 = H.boot({ name = "Tavlius", saved = Saved(g) })
  g2.log, g2.group, g2.inGroup, g2.wall = g.log, { "Mirel" }, true, g.wall + 30
  g2.login(true)
  g2.dropFrom = function(m) return m.msg:find("|L|") ~= nil end
  H.use(h)
  h.realNs.SendFull()
  H.run({ g2, h }, 10)
  g2.dropFrom = nil
  H.run({ g2, h }, 80)
  check("details before the list: saved time kept", t and t > 0 and g2.realNs.partners.Mirel.seenAt[90] == t,
    tostring(t) .. " vs " .. tostring(g2.realNs.partners.Mirel and g2.realNs.partners.Mirel.seenAt[90]))
  -- The pickup note when distance can't be read (another instance): never "share it now".
  local k, l = Duo()
  k.rangeUnknown.party1, k.mapID.party1 = true, 1436
  k.addQuest({ id = 91, title = "Note Wording", objs = { { label = "x", have = 0, need = 2 } } })
  H.run({ k, l }, 30)
  check("pickup note: share when together", k.printedMatch("share it when you're together"), since(k))
  noErrors(f, "realms")
end

-- 33. Sync turned back on after a lost bye: their pickups meanwhile aren't "with you".
do
  local a, b = Duo()
  a.dropFrom = function(m) return m.msg:find("^%d+|B") ~= nil end
  b.slash("sync off")
  H.run({ a, b }, 400)  -- (off for a few minutes)
  b.distance.party1, a.distance.party1 = 900, 900
  b.addQuest({ id = 95, title = "Picked Up While Off" })
  b.tick(4)
  a.distance.party1, b.distance.party1 = nil, nil
  b.slash("sync on")
  H.run({ a, b }, 30)
  a.dropFrom = nil
  check("lost bye: back in sync within 15s", a.ns.partners.Mirel and a.ns.partners.Mirel.list[95] ~= nil)
  local before = #a.printed
  a.tick(8)
  a.fire("TAXIMAP_OPENED")
  check("lost bye: no 'from here' for their pickup while off",
    not (a.errorsFrame[#a.errorsFrame] or ""):find("from here"), a.errorsFrame[#a.errorsFrame])
  check("lost bye: no pickup note", not a.printedMatch("Mirel picked up .*Picked Up While Off"), since(a, before))
end

-- 34. While their first list hasn't arrived, partial data isn't shown as their log.
do
  local a, b = H.duo()
  a.addQuest({ id = 2200, title = "Only Mine" }, true)
  b.addQuest({ id = 2201, title = "Only Theirs" }, true)
  a.login() b.login()
  a.dropFrom = function(m) return m.msg:find("|L|") ~= nil end
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 20)
  check("first list missing: not shown as synced data", not a.windowText():find("Mirel doesn't have"), a.windowText())
  a.dropFrom = nil
  H.run({ a, b }, 140)
  check("first list arrives: synced", a.windowText():find("Mirel doesn't have"), a.windowText())
end

-- 35. With many DuoQuest partners over time, your usual partner's saved pickup times stay.
do
  local saved = { lastPartner = "Mirel", partnerSeen = { Mirel = { seenAt = { [5] = 123 }, near = {} } } }
  for i = 1, 8 do saved.partnerSeen["Old" .. i] = { seenAt = {}, near = {} } end
  local a = H.boot({ name = "Tavlius", saved = saved })
  local d = H.boot({ name = "Dana" })
  a.login() d.login()
  a.setGroup({ "Dana" }) d.setGroup({ "Tavlius" })
  H.run({ a, d }, 40)
  check("usual partner's pickup times kept", a.saved().partnerSeen.Mirel ~= nil)
  -- Same for a partner you picked by typing their name (any case).
  local saved2 = { focus = "mirel", partnerSeen = { Mirel = { seenAt = { [5] = 123 }, near = {} } } }
  for i = 1, 8 do saved2.partnerSeen["Old" .. i] = { seenAt = {}, near = {} } end
  local c = H.boot({ name = "Tavlius", saved = saved2 })
  local e = H.boot({ name = "Dana" })
  c.login() e.login()
  c.setGroup({ "Dana" }) e.setGroup({ "Tavlius" })
  H.run({ c, e }, 40)
  check("chosen partner's pickup times kept", c.saved().partnerSeen.Mirel ~= nil)
  local n = 0
  for _ in pairs(a.saved().partnerSeen) do n = n + 1 end
  check("saved partners bounded", n <= 6, n)
end

-- 36. Mirel logs off in the party and comes back on an alt: the window follows
--     whoever is online (and goes back to the main when he returns).
do
  local a = Duo(function(a) a.addQuest({ id = 10, title = "Mine" }, true) end,
    function(b) b.addQuest({ id = 20, title = "Mirel Main Quest" }, true) end)
  a.offline = { party1 = true }
  H.run({ a }, 20)
  local alt = H.boot({ name = "Mirelalt" })
  alt.addQuest({ id = 30, title = "Alt Quest" }, true)
  alt.now, alt.wall = a.now, a.wall
  alt.login()
  a.setGroup({ "Mirel", "Mirelalt" })
  alt.setGroup({ "Tavlius", "Mirel" })
  alt.offline = { party2 = true }
  H.run({ a, alt }, 60)
  check("alt: window follows the online alt", a.ns.FocusPartner().key == "Mirelalt", a.ns.FocusPartner().key)
  check("alt: usual partner remembered", a.realNs.DB.lastPartner == "Mirel")
  a.offline = nil
  check("alt: main back online gets the window back", a.ns.FocusPartner().key == "Mirel")
end

-- 37. Quests Mirel picked up in a session without you aren't "from here" in
--     your next session together (only before your very first sync is a
--     quest's age unknown).
do
  local a, b = Duo(function(a) a.addQuest({ id = 1, title = "Shared" }, true) end,
    function(b) b.addQuest({ id = 1, title = "Shared" }, true) end)
  local b2 = H.reload(b, true, 3600)  -- Mirel alone, later
  b2.inGroup, b2.group = false, {}
  b2.fire("GROUP_ROSTER_UPDATE")
  b2.zone, b2.subzone = "Westfall", "Sentinel Hill"
  for i = 11, 13 do b2.addQuest({ id = i, title = "Westfall " .. i }) b2.tick(4) end
  local a3 = H.reload(a, true, 86400)
  local b3 = H.reload(b2, true, 86400 - 3600)
  b3.zone, b3.subzone = a3.zone, a3.subzone
  a3.setGroup({ "Mirel" }) b3.setGroup({ "Tavlius" })
  H.run({ a3, b3 }, 40)
  local before = #a3.printed
  a3.fire("TAXIMAP_OPENED")
  check("solo session: Mirel's pickups elsewhere not warned", not a3.printedMatch("Westfall 1", before + 1),
    since(a3, before + 1))
  a3.slash("status")
  check("solo session: still in /dq status", a3.printedMatch("Westfall 11", before + 1))
end

-- 38. Mirel in a dungeon (another instance): his pickups there aren't "from
--     here", and yours in town while he's inside are made apart.
do
  local a, b = Duo()
  a.rangeUnknown.party1, b.rangeUnknown.party1 = true, true
  b.addQuest({ id = 1601, title = "Dungeon Quest" })
  a.addQuest({ id = 1602, title = "Town Quest While Inside" })
  H.run({ a, b }, 20)
  check("other instance: my pickup made apart", a.realNs.awayMine[1602] == true)
  check("other instance: his pickup made apart", a.realNs.partners.Mirel.near[1601] == false)
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("other instance: nothing 'from here' while he's inside", not a.printedMatch("Dungeon Quest", before + 1)
    and not a.printedMatch("Town Quest While Inside", before + 1), since(a, before + 1))
  -- A raid unit's map can't be read: that's "can't tell", not "apart".
  a.rangeUnknown.raid2 = true
  check("raid unit without a map: can't tell", a.ns.Near("raid2") == nil)
end

-- 39. A zone line on foot starts a new hub, named after where you handle quests next.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  a.addQuest({ id = 701, title = "Goldshire Gap" })
  H.run({ a, b }, 20)
  local start = a.realNs.hubSince
  a.wall = a.wall + 30
  a.zone, a.subzone = "Westfall", "Sentinel Hill"
  a.fire("ZONE_CHANGED_NEW_AREA")
  check("zone line: You left", a.printedMatch("You left Elwynn Forest"))
  check("zone line: new hub", a.realNs.hubSince > start)
  a.addQuest({ id = 702, title = "Sentinel Gap" })
  H.run({ a, b }, 4)
  a.subzone = "The Dagger Hills"
  local before = #a.printed
  H.run({ a, b }, 40)
  check("zone line: named after the new place", a.printedMatch("Leaving Sentinel Hill", before + 1), since(a, before + 1))
  -- A zone line inside a loading screen (a boat, a slow portal) isn't walking out.
  local c, d = Duo()
  c.addQuest({ id = 703, title = "Boat Gap" })
  H.run({ c, d }, 10)
  c.fire("LOADING_SCREEN_ENABLED")
  c.tick(30)
  c.zone, c.subzone = "Wetlands", "Menethil Harbor"
  c.fire("ZONE_CHANGED_NEW_AREA")
  check("zone line during a loading screen: quiet", not c.printedMatch("You left"))
end

-- 40. Three players: a pickup by Bob (not your focus) of a quest Mirel has isn't a "Mirel picked up" note.
do
  local a = H.boot({ name = "Tavlius" })
  local b = H.boot({ name = "Mirel" })
  local c = H.boot({ name = "Bob" })
  b.addQuest({ id = 1501, title = "Mirel Had It" }, true)
  a.login() b.login() c.login()
  a.setGroup({ "Mirel", "Bob" }) b.setGroup({ "Tavlius", "Bob" }) c.setGroup({ "Tavlius", "Mirel" })
  a.slash("partner Mirel")
  for _, x in ipairs({ a, b, c }) do x.distance.party1, x.distance.party2 = 1000, 1000 end
  H.run({ a, b, c }, 60)
  local before = #a.printed
  c.addQuest({ id = 1501, title = "Mirel Had It" })
  H.run({ a, b, c }, 40)
  check("3 players: no note about Mirel for Bob's pickup", not a.printedMatch("picked up", before + 1),
    since(a, before + 1))
end

-- 41. Classic, collapsed header: a quest there keeps its Share button.
do
  local a = Duo(function(a)
    a.log[#a.log + 1] = { header = "Elwynn" }
    a.addQuest({ id = 1702, title = "Kill Things", objs = { { label = "Wolf", have = 1, need = 5 } } }, true)
  end, nil, { name = "Tavlius", classic = true }, { name = "Mirel", classic = true })
  a.collapsed.Elwynn = true
  a.fire("QUEST_LOG_UPDATE")
  a.tick(6)
  check("classic collapsed: Share button stays", a.windowText():find("Kill Things || %[Share"), a.windowText())
end

-- 42. A chosen partner without DuoQuest: only gaps picked up at this hub are warned.
do
  local a = H.boot({ name = "Tavlius" })
  a.addQuest({ id = 3301, title = "Yesterday" }, true)
  a.login()
  a.setGroup({ "Bob" })
  a.slash("partner Bob")
  a.tick(4)
  a.realNs.seenAt[3301] = a.wall - 86400
  a.unitOnQuest.party1 = {}
  a.addQuest({ id = 3302, title = "Today" })
  a.tick(4)
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("chosen without DuoQuest: today's gap warned", a.printedMatch("Today", before + 1), since(a, before + 1))
  check("chosen without DuoQuest: yesterday's not", not a.printedMatch("Yesterday", before + 1))
  check("chosen without DuoQuest: 'may be missing' on screen", (a.errorsFrame[#a.errorsFrame] or ""):find("Bob may be missing"),
    a.errorsFrame[#a.errorsFrame])
end

-- 43. A /reload while apart doesn't turn quests you picked up together into "apart" ones.
do
  local a, b = Duo()
  a.addQuest({ id = 4701, title = "Together Pickup" })
  H.run({ a, b }, 20)
  a.distance.party1 = 1000
  local a2 = H.reload(a)
  a2.distance.party1 = 1000
  a2.tick(6)
  check("reload while apart: still together", a2.realNs.awayMine[4701] == nil, tostring(a2.realNs.awayMine[4701]))
  -- The reload keeps the client's throttle: the burst after it isn't throttled.
  check("reload: no throttle trips", a2.throttled == 0, a2.throttled)
end

-- 44. "The same hub" is about 200 yards: no pickup note at 150, a note at 250.
do
  local a, b = Duo()
  a.distance.party1, b.distance.party1 = 150, 150
  b.addQuest({ id = 4401, title = "At 150 Yards" })
  H.run({ a, b }, 30)
  check("150 yards: no note", not a.printedMatch("At 150 Yards"))
  a.distance.party1, b.distance.party1 = 250, 250
  b.addQuest({ id = 4402, title = "At 250 Yards" })
  H.run({ a, b }, 30)
  check("250 yards: note", a.printedMatch("Mirel picked up .*At 250 Yards"), since(a))
end

-- 45. Arriving by flight straight into a town's rest area makes it part of the new hub.
do
  local a = Duo()
  a.onTaxi = true
  a.tick(2)
  a.subzone, a.resting = "Lakeshire", true
  a.fire("PLAYER_UPDATE_RESTING")
  a.onTaxi = false
  a.tick(2)
  check("landed in a town: its rest area is the hub", a.realNs.DB.hub.areas.Lakeshire == "rest")
  -- Same through a loading screen.
  a.fire("LOADING_SCREEN_ENABLED")
  a.zone, a.subzone, a.resting = "Ironforge", "The Commons", true
  a.fire("PLAYER_ENTERING_WORLD", false, false)
  a.fire("LOADING_SCREEN_DISABLED")
  check("arrived through a loading screen into a town: rest area marked", a.realNs.DB.hub.areas["The Commons"] == "rest")
  noErrors(a, "arrivals")
end

-- 46. Mirel reloading at the moment you leave: the warning still comes (from his
--     list before the reload); a pickup note waits for his new list.
do
  local a, b = Duo()
  a.addQuest({ id = 4600, title = "Leaving While He Reloads" })
  H.run({ a, b }, 10)
  local b2 = H.reload(b)
  a.dropFrom = function(m) return not m.msg:find("|H|") end
  H.run({ a, b2 }, 2)
  check("partner reloading: resyncing", a.realNs.partners.Mirel.resync == true)
  a.distance.party1, b2.distance.party1 = 900, 900
  a.addQuest({ id = 4601, title = "Note After Resync" })
  a.tick(2)
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("partner reloading: warning still comes", a.printedMatch("Leaving While He Reloads", before + 1), since(a, before + 1))
  H.run({ a, b2 }, 16)  -- (his new list is still on the way when the note is due)
  check("partner reloading: note waits", not a.printedMatch("Note After Resync", before + 1))
  a.dropFrom = nil
  H.run({ a, b2 }, 160)  -- (his next list, at the latest his heartbeat)
  check("partner reloading: pickup note after the resync", a.printedMatch("Mirel doesn't have .*Note After Resync"), since(a))
end

-- 47. A bye from someone we haven't heard from (they sent it right after our reload).
do
  local a, b = Duo()
  local a2 = H.reload(a)
  a2.dropFrom = function(m) return not m.msg:find("^%d+|B") end  -- (their hello and list don't get through)
  H.run({ a2, b }, 30)
  b.slash("sync off")
  H.run({ a2, b }, 4)
  check("bye from an unknown peer: status says sync is off", a2.statusText():find("Mirel turned DuoQuest sync off"),
    a2.statusText())
end

-- 48. A secret map ID for your partner: "can't tell" (no error), and your pickups still register.
do
  local a, b = Duo(nil, nil, { name = "Tavlius", secrets = { map = true } })
  a.rangeUnknown.party1 = true
  a.addQuest({ id = 4800, title = "Secret Map Pickup" })
  H.run({ a, b }, 10)
  check("secret map: can't tell", a.ns.Near("party1") == nil)
  check("secret map: pickup registered and synced", a.ns.mine[4800] ~= nil and b.ns.partners.Tavlius.list[4800] ~= nil)
  check("secret map: not counted as apart", a.realNs.awayMine[4800] == nil)
  noErrors(a, "secret map")
  -- Distance unreadable but the same map: together; your own map unreadable: can't tell.
  local c, d = Duo()
  c.rangeUnknown.party1, c.mapID.party1 = true, 1429
  c.addQuest({ id = 4801, title = "Same Map Pickup" })
  H.run({ c, d }, 10)
  check("unknown distance, same map: together", c.realNs.awayMine[4801] == nil)
  c.mapID.party1, c.mapID.player = nil, nil
  H.use(c)
  local oldMap = _G.C_Map.GetBestMapForUnit
  _G.C_Map.GetBestMapForUnit = function() return nil end
  check("your own map unreadable: can't tell", c.realNs.Near("party1") == nil)
  _G.C_Map.GetBestMapForUnit = oldMap
end

-- 49. Mirel picks up a quest beside you while you /reload (the pickup message
--     is lost): it still counts as picked up here, with you.
do
  local a, b = Duo()
  H.run({ a, b }, 20)
  b.addQuest({ id = 4900, title = "Took It Beside You" })
  b.tick(2)
  b.delivered = #b.addonSent  -- (lost: you were on the loading screen)
  local a2 = H.reload(a)
  H.run({ a2, b }, 40)
  local before = #a2.printed
  a2.fire("TAXIMAP_OPENED")
  check("reload: partner's pickup beside you warned", a2.printedMatch("Took It Beside You", before + 1), since(a2, before + 1))
  check("reload: ...as from here", (a2.errorsFrame[#a2.errorsFrame] or ""):find("from here"), a2.errorsFrame[#a2.errorsFrame])
end

-- 50. You only shopped at the hub, Mirel picked up a quest beside you: walking
--     out still warns you.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  H.run({ a, b }, 4)
  b.addQuest({ id = 5000, title = "Mirel Took It In Town", pushable = false })
  H.run({ a, b }, 10)
  local before = #a.printed
  a.subzone = "Jasperlode Mine"
  H.run({ a, b }, 40)
  check("shopping hub: walking out warns", a.printedMatch("Leaving Goldshire", before + 1)
    and a.printedMatch("Mirel Took It In Town", before + 1), since(a, before + 1))
end

-- 51. Share is greyed out (and /dq share refuses) while Mirel is offline or in another instance.
do
  local a = Duo(function(a) a.addQuest({ id = 5100, title = "Share Me" }, true) end)
  a.offline = { party1 = true }
  a.tick(12)
  local row = a.rowFor("Share Me")
  check("offline: Share greyed out", row and not row.share.enabled)
  local before = #a.printed
  a.slash("share")
  check("offline: /dq share refuses", a.printedMatch("Mirel is offline: .*can't be shared now", before + 1) and #a.pushed == 0, since(a, before + 1))
  a.offline = nil
  a.rangeUnknown.party1 = true  -- (in a dungeon: no map either)
  a.tick(12)
  row = a.rowFor("Share Me")
  check("other instance: Share greyed out", row and not row.share.enabled)
  row.share:Hover()
  check("other instance: tooltip says he isn't here", table.concat(a.tooltip, "\n"):find("Mirel isn't here to receive it"),
    table.concat(a.tooltip, "\n"))
  before = #a.printed
  a.slash("share")
  check("other instance: /dq share says he isn't here", a.printedMatch("Mirel isn't here to receive", before + 1)
    and #a.pushed == 0, since(a, before + 1))
  a.rangeUnknown.party1 = nil
  a.tick(12)
  row = a.rowFor("Share Me")
  check("back: Share on", row and row.share.enabled)
end

-- 52. After a /reload the hub's areas are still there: walking out warns.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  a.addQuest({ id = 5200, title = "Reload Then Walk" })
  H.run({ a, b }, 10)
  local a2 = H.reload(a)
  H.run({ a2, b }, 20)
  local before = #a2.printed
  a2.subzone = "Crystal Lake"
  H.run({ a2, b }, 40)
  check("reload then walk out: warned", a2.printedMatch("Leaving Goldshire", before + 1), since(a2, before + 1))
end

-- 53. After a loading screen ends, zone lines warn again; a stale zone name at
--     arrival doesn't make a "You left" right after it.
do
  local a, b = Duo()
  a.fire("LOADING_SCREEN_ENABLED")
  a.zone, a.subzone = "Dun Morogh", "Ironforge"
  a.fire("PLAYER_ENTERING_WORLD", false, false)
  a.fire("LOADING_SCREEN_DISABLED")
  H.run({ a, b }, 30)
  a.addQuest({ id = 5300, title = "Ironforge Gap" })
  H.run({ a, b }, 10)
  a.zone, a.subzone = "Loch Modan", "Thelsamar"
  a.fire("ZONE_CHANGED_NEW_AREA")
  check("after a loading screen: zone lines warn again", a.printedMatch("You left Dun Morogh"), since(a))
  -- The zone name still old when you arrive, updated a moment later.
  -- (A gap of unknown age, from before you synced, is what a stray "You left" would list.)
  local c, d = Duo(nil, function(d) d.addQuest({ id = 5301, title = "Stale Zone Gap" }, true) end)
  H.run({ c, d }, 10)
  c.fire("LOADING_SCREEN_ENABLED")
  c.fire("PLAYER_ENTERING_WORLD", false, false)  -- (zone text not updated yet)
  c.fire("LOADING_SCREEN_DISABLED")
  c.tick(4)
  c.zone = "Darnassus"
  c.fire("ZONE_CHANGED_NEW_AREA")
  check("stale zone at arrival: no 'You left'", not c.printedMatch("You left"), since(c))
end

-- 54. Who the window is about, in bigger groups.
do
  -- Your only DuoQuest partner is offline (and was never your usual one): still shown.
  local a, b = H.duo()
  a.login() b.login()
  a.setGroup({ "Mirel", "Bob" }) b.setGroup({ "Tavlius", "Bob" })
  H.run({ a, b }, 40)
  a.realNs.DB.lastPartner = nil
  a.offline = { party1 = true }
  check("only partner offline: still the focus", a.ns.FocusPartner() and a.ns.FocusPartner().key == "Mirel",
    a.ns.FocusPartner() and a.ns.FocusPartner().key)
  -- Your usual partner left the group: the new one becomes usual, so his return doesn't flip the window.
  local c = H.boot({ name = "Tavlius" })
  local d = H.boot({ name = "Mirel" })
  local e = H.boot({ name = "Aaron" })
  for _, x in ipairs({ c, d, e }) do x.login() end
  c.setGroup({ "Mirel" }) d.setGroup({ "Tavlius" })
  H.run({ c, d }, 40)
  c.setGroup({ "Aaron" }) e.setGroup({ "Tavlius" }) d.setGroup({})
  H.run({ c, e }, 80)
  check("usual partner gone: the new one is usual", c.realNs.DB.lastPartner == "Aaron", c.realNs.DB.lastPartner)
  c.setGroup({ "Aaron", "Mirel" }) e.setGroup({ "Tavlius", "Mirel" }) d.setGroup({ "Tavlius", "Aaron" })
  H.run({ c, d, e }, 80)
  check("old partner back: window stays", c.ns.FocusPartner().key == "Aaron")
  -- No usual partner: the first by name.
  c.realNs.DB.lastPartner = nil
  check("first by name", c.ns.FocusPartner().key == "Aaron")
end

-- 55. Status and edge cases around partners.
do
  -- First contact: "Syncing with".
  local a, b = H.duo()
  a.login() b.login()
  a.dropFrom = function(m) return m.msg:find("|L|") ~= nil end
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 40)
  check("first contact: Syncing with", a.statusText():find("^Syncing with Mirel"), a.statusText())
  -- Their details arrived but not their list: no leave warning from half data.
  b.addQuest({ id = 5500, title = "Half Data" })
  H.run({ a, b }, 10)
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("half data: no warning", not a.printedMatch("Before you fly", before + 1), since(a, before + 1))
  -- Leaving the group isn't "turned sync off".
  a.dropFrom = nil
  a.setGroup({}) b.setGroup({})
  a.tick(4)
  check("left the group: not 'sync off'", not a.realNs.syncOff.Mirel)
  -- A current partner's saved pickups aren't evicted when others are.
  local saved = { partnerSeen = {} }
  for i = 1, 8 do saved.partnerSeen["Old" .. i] = { seenAt = {}, near = {} } end
  local c = H.boot({ name = "Tavlius", saved = saved })
  local d = H.boot({ name = "Mirel" })
  local e = H.boot({ name = "Dana" })
  for _, x in ipairs({ c, d, e }) do x.login() end
  c.setGroup({ "Mirel", "Dana" }) d.setGroup({ "Tavlius", "Dana" }) e.setGroup({ "Tavlius", "Mirel" })
  H.run({ c, d, e }, 60)
  check("current partners' saved pickups kept", c.saved().partnerSeen.Mirel ~= nil and c.saved().partnerSeen.Dana ~= nil)
end

-- 56. Grinding (one quest's progress changing every second) doesn't hold up a
--     reloading partner's resync or the heartbeat.
do
  local a, b = Duo(function(a)
    for i = 1, 25 do a.addQuest({ id = 5600 + i, title = "Grind " .. i, objs = { { label = "x", have = 0, need = 500 } } }, true) end
  end)
  local b2 = H.reload(b)
  local t = 0
  while t < 240 do
    if t % 2 == 0 then a.progress(5601, 1, t / 2 + 1) end
    H.run({ a, b2 }, 1)
    t = t + 1
    local p = b2.ns.partners.Tavlius
    if p and p.synced and #b2.realNs.MissingDetails(p) == 0 and p.quests[5625] then break end
  end
  check("grinding: partner's resync completes within 90s", t <= 180, t / 2 .. "s")
end

-- 57. Resend requests are answered at most every 8 seconds.
do
  local a = Duo(function(a) a.addQuest({ id = 5700, title = "Flooded" }, true) end)
  local n = a.sentMatching("|U|" .. a.ns.To36(5700) .. "|")
  for _ = 1, 30 do
    a.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|N|Tavlius-Realm|" .. a.ns.To36(5700), "PARTY", "Mirel-Realm")
    a.tick(4)
  end
  local sent = a.sentMatching("|U|" .. a.ns.To36(5700) .. "|") - n
  check("request flood: answered at most every 8s", sent <= 8, sent)
  check("request flood: still answered", sent >= 4, sent)
end

-- 58. A partner's pickup that arrives while you're flying doesn't change your hub.
do
  local a, b = Duo()
  a.onTaxi = true
  a.tick(2)
  local areas = 0
  for _ in pairs(a.realNs.DB.hub.areas) do areas = areas + 1 end
  b.addQuest({ id = 5800, title = "At The Flight Master" })
  H.run({ a, b }, 6)
  local after = 0
  for _ in pairs(a.realNs.DB.hub.areas) do after = after + 1 end
  check("flying: partner pickup doesn't mark your hub", areas == 0 and after == 0, after)
end

-- 59. /dq share all lists only quests that can be shared; the partner note says how to get it.
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 5900, title = "Can Share This" }, true)
    a.addQuest({ id = 5901, title = "Cannot Share This", pushable = false }, true)
  end)
  local before = #a.printed
  a.slash("share all")
  check("share all: the shareable one", a.printedMatch("Can Share This", before + 1), since(a, before + 1))
  check("share all: not the other", not a.printedMatch("Cannot Share This", before + 1), since(a, before + 1))
  a.distance.party1, b.distance.party1 = 900, 900
  b.addQuest({ id = 5902, title = "Mirel Unshareable", pushable = false })
  H.run({ a, b }, 30)
  check("partner note: can't be shared", a.printedMatch("Mirel picked up .*Mirel Unshareable.*can't be shared"), since(a))
end

-- 60. Mirel's distance unreadable (secret): his pickup still counts as with you,
--     and doesn't make your spot part of your hub.
do
  local a, b = Duo(nil, nil, { name = "Tavlius", secrets = { distance = true, map = true } })
  b.addQuest({ id = 6000, title = "Unknown Distance Pickup" })
  H.run({ a, b }, 10)
  local p = a.realNs.partners.Mirel
  check("unknown distance: his pickup isn't apart", p.near[6000] ~= false)
  check("unknown distance: your hub unchanged", next(a.realNs.DB.hub.areas) == nil)
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("unknown distance: warned", a.printedMatch("Unknown Distance Pickup", before + 1), since(a, before + 1))
end

-- 61. A note waiting for a partner's resync gives up after a while.
do
  local a, b = Duo()
  local b2 = H.reload(b)
  a.dropFrom = function(m) return not m.msg:find("|H|") end
  H.run({ a, b2 }, 2)
  a.distance.party1, b2.distance.party1 = 900, 900
  a.addQuest({ id = 6100, title = "Given Up Note" })
  H.run({ a, b2 }, 340)  -- 170s: his list never arrives
  a.dropFrom = nil
  H.run({ a, b2 }, 160)
  check("note: given up after its wait", not a.printedMatch("Given Up Note"), since(a))
end

-- 62. Someone you can see is near, even without a distance (another floor of a
--     dungeon); a missing map inside an instance is "can't tell".
do
  local a = Duo()
  a.distance.party1 = 80
  H.use(a)
  local d2 = _G.UnitDistanceSquared
  _G.UnitDistanceSquared = function() return 0, false end
  a.mapID.party1 = 9999
  check("visible: near", a.realNs.Near("party1") == true)
  a.rangeUnknown.party1 = true
  a.mapID.party1 = nil
  a.inInstance = true
  check("inside an instance, no map: can't tell", a.realNs.Near("party1") == nil)
  a.inInstance = false
  check("outside, no map: apart", a.realNs.Near("party1") == false)
  _G.UnitDistanceSquared = d2
end

-- 63. Keywords in any case.
do
  local a = H.boot()
  a.login()
  a.slash("sync ON")
  check("/dq sync ON keeps sync on", a.ns.DB.sync == true)
  a.slash("WARN Off")
  check("/dq WARN Off turns warnings off", a.ns.DB.warnLeave == false)
  local before = #a.printed
  a.slash("share ALL")
  check("/dq share ALL lists", not a.printedMatch("usage", before + 1), since(a, before + 1))
  a.slash("partner Mirel")
  check("/dq partner keeps the name as typed", a.ns.DB.focus == "Mirel")
  a.slash("partner AUTO")
  check("/dq partner AUTO", a.ns.DB.focus == nil)
end

-- 64. A quest asked for again right after it went out: resent once the 5s gap ends, not at once.
do
  local a = Duo(function(a) a.addQuest({ id = 6400, title = "Just Sent", objs = { { label = "x", have = 0, need = 9 } } }, true) end)
  H.use(a)
  a.progress(6400, 1, 1)
  a.tick(2)
  local id36 = a.ns.To36(6400)
  local n = a.sentMatching("|U|" .. id36 .. "|")
  a.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|N|Tavlius-Realm|" .. id36, "PARTY", "Mirel-Realm")
  a.tick(4)
  check("just sent: not again at once", a.sentMatching("|U|" .. id36 .. "|") == n)
  a.tick(8)
  check("just sent: again after the gap", a.sentMatching("|U|" .. id36 .. "|") == n + 1)
end

-- 65. A quest that changes again right after jumping the queue still jumps it
--     (a little later), instead of waiting behind a backlog.
do
  local a, b = Duo(function(a)
    for i = 1, 25 do a.addQuest({ id = 6500 + i, title = "Backlog Two " .. i }, true) end
    a.addQuest({ id = 6550, title = "Wolves", objs = { { label = "Wolf", have = 0, need = 2 } } }, true)
  end)
  local b2 = H.reload(b)
  H.run({ a, b2 }, 4)  -- (our full resend for his reload is queued)
  a.progress(6550, 1, 1)
  H.run({ a, b2 }, 4)
  a.progress(6550, 1, 2)  -- (2s later: too soon to jump right away)
  local t = 0
  while t < 80 do
    H.run({ a, b2 }, 1)
    t = t + 1
    local q = b2.ns.partners.Tavlius and b2.ns.partners.Tavlius.quests[6550]
    if q and q.objs[1] and q.objs[1].have == 2 then break end
  end
  check("second change: out within a few seconds", t <= 12, t / 2 .. "s")
end

-- 66. Mirel's pickup 100 yards away, or a third player's beside you, doesn't mark your spot.
do
  local a, b = Duo()
  a.subzone = "Crystal Lake"
  a.distance.party1, b.distance.party1 = 100, 100
  b.addQuest({ id = 6600, title = "Hundred Yards" })
  H.run({ a, b }, 10)
  check("100 yards: your spot isn't marked", a.realNs.DB.hub.areas["Crystal Lake"] == nil)
  -- Beside you in unnamed open country, on a hub with no areas yet: not the whole zone.
  a.distance.party1, b.distance.party1 = 10, 10
  a.subzone = "Crystal Lake"
  H.run({ a, b }, 40)  -- (walked off: a new hub)
  a.subzone = ""
  b.addQuest({ id = 6602, title = "Open Country Pickup" })
  H.run({ a, b }, 10)
  check("partner pickup in open country: the zone isn't marked", a.realNs.DB.hub.areas["Elwynn Forest"] == nil)
  local c = H.boot({ name = "Tavlius" })
  local d = H.boot({ name = "Mirel" })
  local e = H.boot({ name = "Bob" })
  for _, x in ipairs({ c, d, e }) do x.login() end
  c.setGroup({ "Mirel", "Bob" }) d.setGroup({ "Tavlius", "Bob" }) e.setGroup({ "Tavlius", "Mirel" })
  c.slash("partner Mirel")
  H.run({ c, d, e }, 40)
  c.subzone = "Crystal Lake"
  e.addQuest({ id = 6601, title = "Bob Beside You" })
  H.run({ c, d, e }, 10)
  check("third player's pickup: your spot isn't marked", c.realNs.DB.hub.areas["Crystal Lake"] == nil)
end

-- 67. Resting while on a flight (passing a town) doesn't add it to the hub, even without the event.
do
  local a = Duo()
  a.onTaxi = true
  a.tick(2)
  a.subzone, a.resting = "Lakeshire", true
  a.tick(6)
  check("flying over a town: not marked by the tick either", a.realNs.DB.hub.areas.Lakeshire == nil)
  a.onTaxi = false
  a.tick(2)
  check("landed there: marked", a.realNs.DB.hub.areas.Lakeshire == "rest")
end

-- 68. Mirel's distance and visibility unreadable: pickup notes are about being apart, so none at an unknown distance.
do
  local a, b = Duo(nil, nil, { name = "Tavlius", secrets = { distance = true, map = true, visible = true } })
  b.addQuest({ id = 6800, title = "Unknown Whereabouts" })
  H.run({ a, b }, 30)
  check("unknown distance: pickup note (can't tell you're together)", a.printedMatch("Mirel picked up .*Unknown Whereabouts"),
    since(a))
end

-- 69. A partner picks up, abandons and picks up again within a few seconds: one note.
do
  local a, b = Duo()
  a.distance.party1, b.distance.party1 = 900, 900
  b.addQuest({ id = 6900, title = "Twice Quickly" })
  H.run({ a, b }, 2)
  b.removeQuest(6900)
  H.run({ a, b }, 2)
  b.addQuest({ id = 6900, title = "Twice Quickly" })
  H.run({ a, b }, 30)
  check("quick re-pick: one note", a.printedCount("Mirel picked up .*Twice Quickly") == 1, a.printedCount("Twice Quickly"))
end

-- 70. A left-click on a quest doesn't ignore it; a secret party-quest answer isn't "Both on".
do
  local a = Duo(function(a) a.addQuest({ id = 7000, title = "Left Click Me" }, true) end)
  a.rowFor("Left Click Me"):Click("LeftButton")
  check("left-click: not ignored", not a.ns.DB.ignored[7000])
  local c = H.boot({ name = "Tavlius", secrets = { unitOnQuest = true } })
  c.addQuest({ id = 7001, title = "Secret Both" }, true)
  c.login()
  c.setGroup({ "Stranger" })
  c.tick(40)
  check("secret party data: no 'Both on'", not c.windowText():find("Both on"), c.windowText())
end

-- 71. /dq while solo (the window waiting for a group) doesn't switch it off for good.
do
  local a, b = H.duo()
  a.login() b.login()
  a.slash("")
  _G.VulcanDuoQuest_ToggleWindow()
  check("solo /dq: still wanted", a.ns.DB.shown == true)
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 40)
  check("solo /dq: shows once grouped", a.ui.shown)
end

-- 72. Accepting a quest on unnamed ground on the way out of town doesn't make
--     the open country part of the town.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  a.addQuest({ id = 7200, title = "Town Gap Before The Road" })
  H.run({ a, b }, 10)
  a.subzone = ""
  H.run({ a, b }, 10)
  a.addQuest({ id = 7201, title = "Shared On The Road" }) b.addQuest({ id = 7201, title = "Shared On The Road" })
  H.run({ a, b }, 30)
  check("road accept: open country isn't hub", a.realNs.DB.hub.areas["Elwynn Forest"] == nil)
  check("road accept: still warned on the road", a.printedMatch("Leaving Goldshire") and a.printedMatch("Town Gap Before The Road"),
    since(a))
  -- Resting in an unnamed spot of a hub that has areas: not added either.
  local c = Duo()
  c.subzone = "Goldshire"
  c.addQuest({ id = 7202, title = "Another Town Quest" })
  c.tick(4)
  c.subzone, c.resting = "", true
  c.tick(4)
  check("unnamed rest spot: not added", c.realNs.DB.hub.areas["Elwynn Forest"] == nil)
end

-- 73. Mirel offline while you're inside an instance: Share still greyed out.
do
  local a = Duo(function(a) a.addQuest({ id = 7300, title = "Offline Inside" }, true) end)
  a.inInstance = true
  a.offline = { party1 = true }
  a.tick(12)
  local row = a.rowFor("Offline Inside")
  check("offline, you inside: Share greyed out", row and not row.share.enabled)
  local before = #a.printed
  a.slash("share")
  check("offline, you inside: /dq share refuses", a.printedMatch("Mirel is offline", before + 1) and #a.pushed == 0)
end

-- 74. "Maybe" shareable (a client that can't tell): "ask Mirel", "ask Mirel to share it", "try sharing it".
do
  local a, b = Duo(nil, function(b) b.addQuest({ id = 7400, title = "Maybe Quest" }, true) end, nil,
    { name = "Mirel", noPushable = true })
  check("maybe: 'ask Mirel' in the window", a.windowText():find("Maybe Quest || ask Mirel"), a.windowText())
  b.addQuest({ id = 7401, title = "Maybe Fresh" })
  H.run({ a, b }, 10)
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("maybe: warning says ask him to share", a.printedMatch("Maybe Fresh.*ask Mirel to share it", before + 1), since(a, before + 1))
  a.addQuest({ id = 7402, title = "Mine Fresh" })
  H.run({ a, b }, 10)
  before = #b.printed
  b.fire("TAXIMAP_OPENED")
  check("maybe: owner's side says try sharing", b.printedMatch("Mine Fresh") and true, since(b, before + 1))
  check("maybe: owner wording", b.printedMatch("Maybe Fresh.*try sharing it", 1) or b.printedMatch("try sharing it", 1), since(b))
end

-- 75. Astral Recall counts as a Hearthstone.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  a.addQuest({ id = 7500, title = "Recall Gap" })
  H.run({ a, b }, 10)
  local before = #a.printed
  a.fire("UNIT_SPELLCAST_START", "player", "guid", 556)
  check("astral recall: before you hearth", a.printedMatch("Before you hearth", before + 1))
  a.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 556)
  check("astral recall: new hub", next(a.realNs.DB.hub.areas) == nil)
end

-- 76. Classic: sharing a quest under a collapsed header says it can't be found (nothing pushed).
do
  local a = Duo(function(a)
    a.log[#a.log + 1] = { header = "Westfall" }
    a.addQuest({ id = 7600, title = "Hidden Share" }, true)
  end, nil, { name = "Tavlius", classic = true })
  a.collapsed.Westfall = true
  a.fire("QUEST_LOG_UPDATE")
  a.tick(4)
  local before = #a.printed
  a.slash("share 7600")
  check("classic collapsed share: can't find it", a.printedMatch("couldn't find it", before + 1) and #a.pushed == 0,
    since(a, before + 1))
end

-- 77. Text a duo relies on.
do
  local a = H.boot()
  a.addQuest({ id = 7700, title = "Lonely" }, true)
  a.login()
  a.unitOnQuest.party1 = { [7700] = true }
  a.setGroup({ "Bob" })
  a.tick(40)
  local before = #a.printed
  a.slash("status")
  check("status, partner without DuoQuest on everything: says so", a.printedMatch("on all 1 of your quests", before + 1),
    since(a, before + 1))
  a.addQuest({ id = 7702, title = "Bob Lacks This" })
  a.tick(4)
  before = #a.printed
  a.slash("status")
  check("status, partner without DuoQuest: gaps but no 'ready to turn in' line", a.printedMatch("Bob may not have", before + 1)
    and not a.printedMatch("ready to turn in", before + 1), since(a, before + 1))
  a.setGroup({ "Bob", "Dana" })
  a.tick(4)
  before = #a.printed
  a.slash("status")
  check("status: nobody runs DuoQuest", a.printedMatch("nobody in your group runs DuoQuest yet", before + 1))
  a.slash("share")
  check("share with nobody: says so", a.printedMatch("nobody in your group to share with", before + 1))
  a.slash("check")
  check("check: members without DuoQuest", a.printedMatch("Bob: no DuoQuest messages yet", before + 1))

  local c, d = Duo()
  before = #c.printed
  c.slash("share all")
  check("share all, nothing: says so", c.printedMatch("Mirel isn't missing any quest you can share", before + 1))
  c.slash("share")
  check("share, nothing: says so", c.printedMatch("isn't missing any quest you can share", before + 1))
  c.slash("share 999")
  check("share an unknown quest: named by ID", c.printedMatch("Quest #999", before + 1), since(c, before + 1))
  c.tick(12)
  check("empty window: says so", c.windowText():find("No quests in either log"), c.windowText())
  d.addQuest({ id = 7701, title = "No Objectives Here", complete = false })
  c.addQuest({ id = 7701, title = "No Objectives Here", complete = false })
  H.run({ c, d }, 20)
  check("both on, no objectives: '-'", c.windowText():find("No Objectives Here || %- | %-"), c.windowText())
  c.rowFor("No Objectives Here"):Hover()
  check("tooltip: level", table.concat(c.tooltip, " "):find("%[10%]"), table.concat(c.tooltip, " "))

  local e = H.boot({ name = "Tavlius", classic = true })
  e.login()
  e.slash("check")
  check("check: classic functions line", e.printedMatch("using the classic quest log functions instead"))
end

-- 78. Many rows: scrolled to the bottom says "scroll up for more".
do
  local a = Duo(function(a) for i = 1, 40 do a.addQuest({ id = 7800 + i, title = string.format("Row %02d", i) }, true) end end)
  for _ = 1, 30 do a.realNs.Scroll(-1) end
  a.tick(2)
  check("scrolled to the bottom: 'scroll up for more'", a.realNs.moreText and a.realNs.moreText.text
    and a.realNs.moreText.text:find("scroll up for more") or false, a.realNs.moreText and a.realNs.moreText.text)
end

-- 79. Accepting a quest on the open road starts a hub there only until a
--     named place joins it: then that place names it, and the road isn't hub.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  H.run({ a, b }, 4)
  a.subzone = "Crystal Lake"
  H.run({ a, b }, 40)  -- (walked off: a new hub)
  a.subzone = ""
  a.addQuest({ id = 7900, title = "Road Item Quest" }) b.addQuest({ id = 7900, title = "Road Item Quest" })
  H.run({ a, b }, 4)
  a.subzone = "Westbrook Garrison"
  a.addQuest({ id = 7901, title = "Garrison Gap" })
  H.run({ a, b }, 10)
  check("road stand-in: replaced by the named place", a.realNs.DB.hub.areas["Elwynn Forest"] == nil
    and a.realNs.DB.hub.name == "Westbrook Garrison", a.realNs.DB.hub.name)
  local before = #a.printed
  a.subzone = ""
  H.run({ a, b }, 40)
  check("road stand-in: walking back onto the road warns", a.printedMatch("Leaving Westbrook Garrison", before + 1),
    since(a, before + 1))
end

-- 80. The window in a group with nobody to compare with: /dq says why it stays down.
do
  local a = H.boot()
  a.login()
  a.setGroup({ "Bob", "Dana" })
  a.tick(4)
  local before = #a.printed
  a.slash("")
  check("pug: /dq explains", a.printedMatch("nobody in this group to compare with", before + 1), since(a, before + 1))
  -- With /dq solo on, /dq show while solo says nothing about groups.
  local c = H.boot()
  c.login()
  c.slash("solo on")
  c.slash("hide")
  before = #c.printed
  c.slash("show")
  check("solo on: no 'shows up when you're in a group'", not c.printedMatch("in a group", before + 1), since(c, before + 1))
  -- The addon menu, while waiting for a group, keeps it wanted.
  local e = H.boot()
  e.login()
  _G.VulcanDuoQuest_OnAddonCompartmentClick()
  check("addon menu while solo: still wanted", e.ns.DB.shown == true)
end

-- 81. Mirel offline with no sync data yet (you logged in first): nothing claimed about him.
do
  local a = H.boot()
  a.addQuest({ id = 8100, title = "Mine While He Sleeps" }, true)
  a.login()
  a.offline = { party1 = true }
  a.setGroup({ "Mirel" })
  a.tick(40)
  check("offline, no data: no 'may not have'", not a.windowText():find("may not have"), a.windowText())
  local before = #a.printed
  a.slash("status")
  check("offline, no data: /dq status says offline", a.printedMatch("Mirel is offline", before + 1), since(a, before + 1))
end

-- 82. /dq status gives the real reason when there's no live data.
do
  local a = Duo()
  a.slash("sync off")
  local before = #a.printed
  a.slash("status")
  check("status, your sync off: says so", a.printedMatch("Sync is off", before + 1)
    and not a.printedMatch("doesn't run DuoQuest", before + 1), since(a, before + 1))
  a.slash("sync on")
  local c, d = H.duo()
  c.login() d.login()
  c.dropFrom = function(m) return m.msg:find("|L|") ~= nil end
  c.setGroup({ "Mirel" }) d.setGroup({ "Tavlius" })
  H.run({ c, d }, 20)
  before = #c.printed
  c.slash("status")
  check("status, mid-sync: says syncing", c.printedMatch("Syncing with Mirel", before + 1), since(c, before + 1))
end

-- 83. Each Share button shares its own quest; failed quests say "failed"; text checks.
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 11, title = "Alpha" }, true)
    a.addQuest({ id = 12, title = "Beta" }, true)
  end, function(b)
    b.addQuest({ id = 13, title = "Failed One", failed = true }, true)
    b.addQuest({ id = 14, title = "Both Kinds", objs = { { label = "Pelt", have = 2, need = 2 }, { label = "Fang", have = 0, need = 3 } } }, true)
  end)
  a.rowFor("Beta").share:Click()
  check("share button: its own quest", a.pushed[#a.pushed] == 12, a.pushed[#a.pushed])
  check("you don't have: failed says whose", a.windowText():find("Failed One || Mirel's failed"), a.windowText())
  a.addQuest({ id = 14, title = "Both Kinds", objs = { { label = "Pelt", have = 2, need = 2 }, { label = "Fang", have = 3, need = 3 } } })
  H.run({ a, b }, 20)
  check("only you ready: objective lines stay", a.windowText():find("Fang"), a.windowText())
  b.fail = true
  local before = #b.printed
  b.slash("warn off")
  check("toggle message: off", b.printedMatch("off", before + 1) and not b.printedMatch(" on", before + 1), since(b, before + 1))
  b.slash("unlock")
  check("/dq unlock", b.ns.DB.locked == false)
  b.slash("lock")
  b.slash("unlock")
  check("/dq unlock after lock", b.ns.DB.locked == false)
  b.slash("debug on")
  before = #b.printed
  b.addQuest({ id = 15, title = "Debug Me" })
  H.run({ a, b }, 6)
  check("debug: prints sync messages with visible separators", b.printedMatch("DuoQuest send.*||"), since(b, before + 1))
  b.slash("debug off")
  -- Non-DuoQuest partner: Both rows show your state only.
  local c = H.boot()
  c.addQuest({ id = 16, title = "Shared With Bob", objs = { { label = "x", have = 0, need = 2 } } }, true)
  c.login()
  c.unitOnQuest.party1 = { [16] = true }
  c.setGroup({ "Bob" })
  c.tick(40)
  check("non-DuoQuest both row: no partner column", c.windowText():find("Shared With Bob || 0/2$")
    or c.windowText():find("Shared With Bob || 0/1\n"), c.windowText())
end

-- 84. Your own pickup note respects the ignore list; a failed gap reads "failed".
do
  local a, b = Duo()
  a.distance.party1, b.distance.party1 = 900, 900
  a.slash("ignore 8400")
  a.addQuest({ id = 8400, title = "Ignored Pickup" })
  H.run({ a, b }, 30)
  check("own pickup note: ignored quest quiet", not a.printedMatch("Ignored Pickup"), since(a))
  a.distance.party1, b.distance.party1 = nil, nil
  a.addQuest({ id = 8401, title = "Will Fail Here", objs = { { label = "x", have = 0, need = 1 } } })
  H.run({ a, b }, 4)
  a.quest(8401).failed = true
  a.fire("QUEST_LOG_UPDATE")
  H.run({ a, b }, 10)
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("failed gap: '(yours failed)'", a.printedMatch("Will Fail Here.*%(yours failed%)", before + 1), since(a, before + 1))
end

-- 85. The mouse wheel scrolls over the rows and over the window.
do
  local a = Duo(function(a) for i = 1, 40 do a.addQuest({ id = 8500 + i, title = string.format("Wheel %02d", i) }, true) end end)
  local first = a.rowTexts()[1]
  local row = a.realNs.rows[3]
  check("wheel over a row: taken", row:Wheel(-1))
  a.tick(2)
  check("wheel over a row: scrolls", a.rowTexts()[1] ~= first)
  check("wheel over the window: taken", a.ui:Wheel(1))
end

-- 86. A hub that started on the open road isn't brought back by logging in
--     anywhere on that zone's open road days later.
do
  local a, b = Duo()
  a.subzone = "Crystal Lake"
  H.run({ a, b }, 40)
  a.subzone = ""
  a.addQuest({ id = 8600, title = "Road Start" }) b.addQuest({ id = 8600, title = "Road Start" })
  H.run({ a, b }, 4)
  local old = a.realNs.DB.hub.since
  local a2 = H.reload(a, true, 86400)
  check("relog on the open road days later: a new hub", a2.realNs.DB.hub.since ~= old)
end

-- 87. An errand for the innkeeper (a quest handled inside the inn): stepping
--     out into the town square still isn't leaving, whichever comes first,
--     the rest area ending or the area name changing.
do
  for _, restFirst in ipairs({ false, true }) do
    local a, b = H.duo()
    a.subzone, a.resting = "Lion's Pride Inn", true
    a.login() b.login()
    a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
    H.run({ a, b }, 40)
    a.addQuest({ id = 8700, title = "Innkeeper Errand" })
    H.run({ a, b }, 10)
    local before = #a.printed
    if restFirst then
      a.resting = false
      a.fire("PLAYER_UPDATE_RESTING")
      a.tick(1)
      a.subzone = "Goldshire"
    else
      a.subzone = "Goldshire"
      a.resting = false
      a.fire("PLAYER_UPDATE_RESTING")
    end
    H.run({ a, b }, 40)
    local label = restFirst and "rest ends first" or "area changes first"
    check("innkeeper errand, " .. label .. ": town square isn't leaving", not a.printedMatch("Leaving", before + 1),
      since(a, before + 1))
    check("innkeeper errand, " .. label .. ": named after the town", a.realNs.DB.hub.name == "Goldshire", a.realNs.DB.hub.name)
    a.subzone = "Crystal Lake"
    H.run({ a, b }, 40)
    check("innkeeper errand, " .. label .. ": walking out of town warns", a.printedMatch("Leaving Goldshire.*", before + 1)
      and a.printedMatch("Innkeeper Errand", before + 1), since(a, before + 1))
  end
end

-- 88. Stepping out briefly and coming back resets the 15 seconds.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  a.addQuest({ id = 8800, title = "Short Steps" })
  H.run({ a, b }, 10)
  local start = a.realNs.DB.hub.since
  a.subzone = "Crystal Lake"
  H.run({ a, b }, 20)  -- 10s out
  a.subzone = "Goldshire"
  H.run({ a, b }, 120) -- back for a minute
  a.subzone = "Crystal Lake"
  H.run({ a, b }, 4)   -- 2s out
  check("short steps: no 'Leaving'", not a.printedMatch("Leaving"), since(a))
  check("short steps: same hub", a.realNs.DB.hub.since == start)
end

-- 89. A road stand-in hub, then resting at an inn and stepping out: named after the town.
do
  local a, b = Duo()
  a.subzone = "Crystal Lake"
  H.run({ a, b }, 40)
  a.subzone = ""
  a.addQuest({ id = 8900, title = "Road Errand" }) b.addQuest({ id = 8900, title = "Road Errand" })
  H.run({ a, b }, 4)
  a.subzone, a.resting = "Lion's Pride Inn", true
  a.fire("PLAYER_UPDATE_RESTING")
  a.subzone, a.resting = "Goldshire", false
  a.fire("PLAYER_UPDATE_RESTING")
  H.run({ a, b }, 4)
  check("road then inn: named after the town", a.realNs.DB.hub.name == "Goldshire", a.realNs.DB.hub.name)
  check("road then inn: road not hub", a.realNs.DB.hub.areas["Elwynn Forest"] == nil)
end

-- 90. Showing the window says nothing about hiding it; the "hidden" hint comes once a session.
do
  local a = Duo()
  local before = #a.printed
  a.slash("hide")
  check("hide: the hint", a.printedCount("window hidden", before + 1) == 1, since(a, before + 1))
  before = #a.printed
  a.slash("show")
  a.slash("")
  a.slash("")
  check("show, and hiding again: no more 'hidden' lines", a.printedCount("window hidden", before + 1) == 0, since(a, before + 1))
end

-- 91. A road stand-in hub survives a fight-and-return intact: a named place still replaces it later.
do
  local a, b = Duo()
  a.subzone = "Crystal Lake"
  H.run({ a, b }, 40)
  a.subzone = ""
  a.addQuest({ id = 9100, title = "Road Fight" }) b.addQuest({ id = 9100, title = "Road Fight" })
  H.run({ a, b }, 4)
  a.subzone, a.combat = "Jasperlode Mine", true
  H.run({ a, b }, 40)
  a.subzone, a.combat = "", false
  a.fire("PLAYER_REGEN_ENABLED")
  a.subzone = "Goldshire"
  a.addQuest({ id = 9101, title = "Town After Fight" })
  H.run({ a, b }, 4)
  check("fight on the road: the stand-in still gives way", a.realNs.DB.hub.areas["Elwynn Forest"] == nil
    and a.realNs.DB.hub.name == "Goldshire", a.realNs.DB.hub.name)
end

-- 92. Out of the inn and onto a flight at once: the town you left isn't part of where you land.
do
  local a, b = H.duo()
  a.subzone, a.resting = "Lion's Pride Inn", true
  a.login() b.login()
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 40)
  a.resting = false
  a.fire("PLAYER_UPDATE_RESTING")  -- (still in the inn's area: the door window opens)
  a.onTaxi = true
  a.subzone = "Goldshire"
  a.tick(1)
  a.subzone = "Redridge Canyons"
  a.tick(20)
  a.onTaxi = false
  a.subzone = "Lakeshire"
  a.tick(2)
  check("inn then flight: the old town isn't in the new hub", a.realNs.DB.hub.areas.Goldshire == nil
    and a.realNs.DB.hub.areas["Lion's Pride Inn"] == nil)
  -- Resting ends as the flight takes off (the flight master at the rest area's edge).
  local c, d = H.duo()
  c.subzone, c.resting = "Lion's Pride Inn", true
  c.login() d.login()
  c.setGroup({ "Mirel" }) d.setGroup({ "Tavlius" })
  H.run({ c, d }, 40)
  c.onTaxi = true
  c.subzone, c.resting = "Goldshire", false
  c.fire("PLAYER_UPDATE_RESTING")
  c.tick(2)
  check("rest ends at takeoff: no door added", c.realNs.DB.hub.areas.Goldshire == nil)
end

-- 93. The inn's door window is short and marks one place.
do
  local a, b = H.duo()
  a.subzone, a.resting = "Lion's Pride Inn", true
  a.login() b.login()
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 40)
  a.resting = false
  a.fire("PLAYER_UPDATE_RESTING")
  a.tick(8)  -- (4s in the inn's area: the window is gone)
  a.subzone = "Goldshire"
  a.tick(2)
  check("door window: closed after a moment", a.realNs.DB.hub.areas.Goldshire == nil)
  local c, e = H.duo()
  c.subzone, c.resting = "Lion's Pride Inn", true
  c.login() e.login()
  c.setGroup({ "Mirel" }) e.setGroup({ "Tavlius" })
  H.run({ c, e }, 40)
  c.resting = false
  c.fire("PLAYER_UPDATE_RESTING")
  c.subzone = "Goldshire"
  c.tick(1)
  c.subzone = "Northshire Valley"
  c.tick(1)
  check("door window: one place only", c.realNs.DB.hub.areas.Goldshire == "door"
    and c.realNs.DB.hub.areas["Northshire Valley"] == nil)
end

-- 94. Fighting across a zone line and finishing the fight in another town: still left.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  a.addQuest({ id = 9400, title = "Zone Fight Gap" })
  H.run({ a, b }, 10)
  a.combat = true
  a.zone, a.subzone = "Stormwind City", "Trade District"
  a.fire("ZONE_CHANGED_NEW_AREA")
  a.resting = true
  a.fire("PLAYER_UPDATE_RESTING")
  a.combat = false
  a.fire("PLAYER_REGEN_ENABLED")
  check("zone fight into a city: warned", a.printedMatch("You left Elwynn Forest") and a.printedMatch("Zone Fight Gap"), since(a))
end

-- 95. A ghost leaving a rest area doesn't add the graveyard to the hub.
do
  local a, b = H.duo()
  a.subzone, a.resting = "Lion's Pride Inn", true
  a.login() b.login()
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 40)
  a.dead = true
  a.subzone, a.resting = "Goldshire Graveyard", false
  a.fire("PLAYER_UPDATE_RESTING")
  a.tick(2)
  check("ghost: graveyard not added", a.realNs.DB.hub.areas["Goldshire Graveyard"] == nil)
end

-- 96. A Hearthstone right after stepping out of the inn: the door window doesn't follow you.
do
  local a, b = H.duo()
  a.subzone, a.resting = "Lion's Pride Inn", true
  a.login() b.login()
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 40)
  a.resting = false
  a.fire("PLAYER_UPDATE_RESTING")
  a.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 8690)
  a.subzone = "Lakeshire"
  a.tick(1)
  check("hearth out of the inn: the new hub isn't given a door", a.realNs.DB.hub.areas.Lakeshire == nil)
end

-- 97. "Share next" and "/dq share all" skip quests you ignore (a class quest he can't take).
do
  local a = Duo(function(a)
    a.addQuest({ id = 71, title = "Aa Hunter Class Quest" }, true)
    a.addQuest({ id = 72, title = "Bb Normal Quest" }, true)
  end)
  a.slash("ignore 71")
  a.slash("share")
  a.slash("share")
  check("share next: skips the ignored one", a.pushed[1] == 72 and a.pushed[2] == 72, table.concat(a.pushed, ","))
  local before = #a.printed
  a.slash("share all")
  check("share all: ignored left out", not a.printedMatch("Hunter Class Quest", before + 1), since(a, before + 1))
  a.rowFor("Hunter Class Quest").share:Click()
  check("its own Share button still works", a.pushed[#a.pushed] == 71)
end

-- 98. Standing on an unnamed street of a city you rest in isn't leaving.
do
  local a, b = Duo()
  a.zone, a.subzone = "Stormwind City", "Trade District"
  a.fire("ZONE_CHANGED_NEW_AREA")
  a.resting = true
  a.fire("PLAYER_UPDATE_RESTING")
  a.addQuest({ id = 9800, title = "City Gap" })
  H.run({ a, b }, 10)
  a.subzone = ""
  H.run({ a, b }, 60)
  check("unnamed city street: not leaving", not a.printedMatch("Leaving"), since(a))
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("unnamed city street: the flight master still warns", a.printedMatch("City Gap", before + 1), since(a, before + 1))
end

-- 99. The zone event arriving before PLAYER_ENTERING_WORLD (reload or relog) doesn't lose the hub.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  a.addQuest({ id = 9900, title = "Event Order Gap" })
  H.run({ a, b }, 10)
  for _, relog in ipairs({ false, true }) do
    local a2 = H.boot({ name = "Tavlius", saved = Saved(a), opts = nil })
    a2.log, a2.subzone, a2.group, a2.inGroup = a.log, "Goldshire", { "Mirel" }, true
    a2.wall = a.wall + 60
    a2.fire("ADDON_LOADED", "VulcanDuoQuest")
    a2.fire("PLAYER_LOGIN")
    a2.fire("ZONE_CHANGED_NEW_AREA")
    a2.fire("PLAYER_ENTERING_WORLD", relog, not relog)
    a2.tick(1)
    a2.fire("QUEST_LOG_UPDATE")
    H.run({ a2, b }, 40)
    a2.fire("TAXIMAP_OPENED")
    check("zone event first (" .. (relog and "relog" or "reload") .. "): hub kept", a2.printedMatch("Event Order Gap"), since(a2))
  end
end

-- 100. Still resting a moment after the area name changes (the rest area reaches past the door):
--      the hub is still named after the town.
do
  local a, b = H.duo()
  a.subzone, a.resting = "Lion's Pride Inn", true
  a.login() b.login()
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 40)
  a.subzone = "Goldshire"
  a.tick(2)  -- (still resting here)
  a.resting = false
  a.fire("PLAYER_UPDATE_RESTING")
  a.tick(2)
  check("lingering rest: named after the town", a.realNs.DB.hub.name == "Goldshire", a.realNs.DB.hub.name)
end

-- 101. The window is placed at login (a frame with no anchor isn't drawn), at
--      its saved spot; a spot never moved from the old default moves to the new one.
do
  local a = H.boot({ name = "Tavlius", saved = { version = 2, point = { "TOPLEFT", "TOPLEFT", 300, -400 } } })
  a.login()
  local p = a.ui.points and a.ui.points[#a.ui.points]
  check("login: placed at the saved spot", p and p[4] == 300 and p[5] == -400, p and (tostring(p[4]) .. "," .. tostring(p[5])))
  local c = H.boot({ name = "Tavlius", saved = { version = 2, point = { "TOPLEFT", "TOPLEFT", 40, -200 } } })
  c.login()
  check("old default spot: moved clear of the party frames", c.ns.DB.point[3] == 260 and c.ns.DB.point[4] == -220)
end

-- 102. One-sided gaps: no empty "You don't have:" line.
do
  local a, b = Duo()
  a.addQuest({ id = 10200, title = "Only Mine Fresh" })
  H.run({ a, b }, 10)
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  a.slash("status")
  local empty = false
  for i = before + 1, #a.printed do if a.printed[i]:find("have: *$") then empty = true end end
  check("one-sided: no empty line", not empty, since(a, before + 1))
end

-- 103. Mirel's pickup beside you, then your own accept in the inn: the hub keeps the town's name.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  a.addQuest({ id = 10300, title = "Same Giver" })
  H.run({ a, b }, 4)
  b.addQuest({ id = 10300, title = "Same Giver" })
  H.run({ a, b }, 10)
  a.subzone = "Lion's Pride Inn"
  a.addQuest({ id = 10301, title = "Inn Errand Two" })
  H.run({ a, b }, 4)
  check("partner pickup doesn't downgrade the town", a.realNs.DB.hub.areas.Goldshire == "quest" and a.realNs.DB.hub.name == "Goldshire",
    a.realNs.DB.hub.name)
end

-- 104. Mirel has a backlog; you pick up a quest he turned in long ago: he says so first, no wrong note.
do
  local a, b = Duo(nil, function(b)
    for i = 1, 25 do b.addQuest({ id = 10400 + i, title = "Mirel Backlog " .. i }, true) end
    b.completed[777] = true
  end)
  a.distance.party1, b.distance.party1 = 900, 900
  H.use(b)
  b.realNs.SendFull()
  a.addQuest({ id = 777, title = "Old Errand" })
  H.run({ a, b }, 30)
  check("turned in long ago: no 'doesn't have' note", not a.printedMatch("Mirel doesn't have .*Old Errand"), since(a))
  check("turned in long ago: listed as done", a.ns.partners.Mirel.done[777] == true)
end

-- 105. Accepting a share in flight doesn't mark the area below.
do
  local a = Duo()
  a.onTaxi = true
  a.tick(2)
  a.subzone = "Redridge Canyons"
  a.addQuest({ id = 10500, title = "Accepted In Flight" })
  a.tick(2)
  check("accept in flight: area below not marked", a.realNs.DB.hub.areas["Redridge Canyons"] == nil)
end

-- 106. After a drag the window is pinned by its top left again (the client
--      re-anchors a moved frame by its nearest corner).
do
  local a = Duo()
  a.ui:Drag(700, 200)
  local p = a.ui.points[#a.ui.points]
  check("drag: pinned by the top left at the saved spot", p and p[1] == "TOPLEFT" and p[3] == "BOTTOMLEFT"
    and p[4] == 700 and p[5] == 200, p and table.concat({ tostring(p[1]), tostring(p[3]), tostring(p[4]), tostring(p[5]) }, ","))
end

-- 107. Mirel picks up a quest Tavlius turned in long ago: Mirel's window shows
--      it as turned in within a moment.
do
  local a, b = Duo()
  a.completed[555] = true
  b.addQuest({ id = 555, title = "Done By Tavlius" })
  H.run({ a, b }, 4)
  check("turned in: shown promptly", b.windowText():find("Tavlius already turned in"), b.windowText())
end

-- 108. /dq status with your sync off: the reason, then what the game reports.
do
  local a = Duo(function(a) a.addQuest({ id = 10800, title = "Game Says Missing" }, true) end)
  a.slash("sync off")
  a.unitOnQuest.party1 = { [10800] = false }
  local before = #a.printed
  a.slash("status")
  check("status, sync off: reason", a.printedMatch("Sync is off", before + 1))
  check("status, sync off: then the game's view", a.printedMatch("Mirel may not have", before + 1), since(a, before + 1))
end

-- 109. Two quick reloads while Mirel is still sending his full log: his
--      record of what you turned in is never wiped by a half-built answer.
do
  local a, b = H.duo()
  for i = 1, 20 do b.addQuest({ id = 600 + i, title = "Mirel Q" .. i }, true) end
  a.completed[1010] = true
  b.addQuest({ id = 1010, title = "Tavlius Did This" }, true)
  a.login() b.login()
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 120)
  local a2 = H.reload(a)
  H.run({ a2, b }, 16)
  local a3 = H.reload(a2)
  local wrong, warned = 0, false
  for t = 1, 120 do
    H.run({ a3, b }, 1)
    local p = b.realNs.partners.Tavlius
    if not (p and p.done[1010]) then wrong = wrong + 1 end
    if t == 6 then
      local before = #b.printed
      b.tick(8)
      b.fire("TAXIMAP_OPENED")
      warned = b.printedMatch("Tavlius doesn't have.*Tavlius Did This", before + 1) ~= nil
    end
  end
  check("quick reloads: turned-in record never wiped", wrong == 0, wrong / 2 .. "s")
  -- ...and the second reload syncs quickly: Mirel's list goes ahead of his backlog.
  local a4 = H.reload(a3)
  H.run({ a4, b }, 16)
  local a5 = H.reload(a4)
  local t = 0
  while t < 120 do
    H.run({ a5, b }, 1)
    t = t + 1
    if a5.ns.partners.Mirel and a5.ns.partners.Mirel.synced then break end
  end
  check("quick reloads: synced again within 10s", t <= 20, t / 2 .. "s")
  check("quick reloads: no warning about a quest you turned in", not warned)
end

-- 110. A third player's pickup doesn't make a gap you were already warned about "new" again.
do
  local a = H.boot({ name = "Tavlius" })
  local b = H.boot({ name = "Mirel" })
  local c = H.boot({ name = "Bob" })
  a.addQuest({ id = 11000, title = "Warned Once" }, true)
  for _, x in ipairs({ a, b, c }) do x.login() end
  a.setGroup({ "Mirel", "Bob" }) b.setGroup({ "Tavlius", "Bob" }) c.setGroup({ "Tavlius", "Mirel" })
  a.slash("partner Mirel")
  H.run({ a, b, c }, 60)
  a.fire("TAXIMAP_OPENED")
  check("third player: warned once first", a.printedMatch("Warned Once"))
  c.addQuest({ id = 11000, title = "Warned Once" })
  H.run({ a, b, c }, 20)
  local before = #a.printed
  a.tick(8)
  a.fire("TAXIMAP_OPENED")
  check("third player's pickup: not warned again", not a.printedMatch("Warned Once", before + 1), since(a, before + 1))
end

-- 111. Two zone lines in a row on foot: each warning names the zone you left; walking back starts a new hub.
do
  local a, b = Duo()
  a.zone, a.subzone = "Westfall", "Sentinel Hill"
  a.fire("ZONE_CHANGED_NEW_AREA")
  H.run({ a, b }, 30)
  a.addQuest({ id = 11100, title = "Westfall Gap" })
  H.run({ a, b }, 10)
  a.zone, a.subzone = "Duskwood", "Darkshire"
  a.fire("ZONE_CHANGED_NEW_AREA")
  check("second zone line: names the zone you left", a.printedMatch("You left Westfall"), since(a))
  check("second zone line: hub zone saved", a.realNs.DB.hub.zone == "Duskwood", a.realNs.DB.hub.zone)
  local start = a.realNs.DB.hub.since
  a.wall = a.wall + 5
  a.zone, a.subzone = "Westfall", "Moonbrook"
  a.fire("ZONE_CHANGED_NEW_AREA")
  check("walking back: a new hub", a.realNs.DB.hub.since ~= start)
end

-- 112. The window has exactly one anchor (its top left) after login, a drag and /dq resetpos;
--      a drag from a row moves it; a locked window doesn't move.
do
  local a = Duo(function(a) a.addQuest({ id = 11200, title = "Drag Row" }, true) end)
  check("login: one anchor", #a.ui.points == 1 and a.ui.points[1][1] == "TOPLEFT", #a.ui.points)
  a.ui:Drag(500, 600)
  check("drag: one anchor", #a.ui.points == 1 and a.ui.points[1][1] == "TOPLEFT", #a.ui.points)
  a.slash("resetpos")
  check("resetpos: one anchor", #a.ui.points == 1, #a.ui.points)
  local moves = a.ui.moves or 0
  a.rowFor("Drag Row"):Drag(450, 550)
  check("drag from a row: the window moves", (a.ui.moves or 0) == moves + 1 and a.ns.DB.point[3] == 450)
  a.slash("lock")
  a.ui:Drag(10, 10)
  check("locked: doesn't move", a.ns.DB.point[3] == 450 and a.ns.DB.point[4] == 550)
end

-- 113. Every quest message fits in one addon message, however long the title,
--      labels and counts; a near-limit quest reaches the partner.
do
  local a, b = Duo()
  H.use(a)
  local worst = 0
  local seed = 7
  local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648 return seed % n end
  for _ = 1, 400 do
    local objs = {}
    for i = 1, 1 + rnd(8) do
      local bar = rnd(4) == 0
      objs[i] = { label = string.rep("Ŵ", rnd(30)) .. string.rep("x", rnd(60)), have = rnd(1000000), need = 1 + rnd(1000000),
        done = rnd(2) == 0, bar = bar or nil }
    end
    local rec = { id = 1 + rnd(2000000), title = string.rep("Ä", rnd(40)) .. string.rep("T", rnd(120)), level = rnd(1000),
      flags = rnd(16), objs = objs }
    local body = a.realNs.EncodeQuest(rec)
    if #("2|" .. body) > worst then worst = #("2|" .. body) end
  end
  -- (and a dense sweep: every objective count and label length, with long titles and 6-digit counts)
  for nobj = 1, 8 do
    for lab = 0, 80 do
      for _, tl in ipairs({ 20, 60, 120 }) do
        local objs = {}
        for i = 1, nobj do objs[i] = { label = string.rep("w", lab), have = 0, need = 100000 + i, done = false } end
        local body = a.realNs.EncodeQuest({ id = 26180, title = string.rep("t", tl), level = 60, flags = 4, objs = objs })
        if #("2|" .. body) > worst then worst = #("2|" .. body) end
      end
    end
  end
  check("every quest message fits in 255 bytes", worst <= 255, worst)
  local q = a.addQuest({ id = 999999, title = string.rep("Long Title ", 12), objs = {
    { label = string.rep("Long Label ", 6), have = 123456, need = 654321 },
    { label = string.rep("Another Label ", 5), have = 99999, need = 999999 },
    { label = string.rep("Third ", 9), have = 5, need = 777777 },
    { label = string.rep("Fourth Objective ", 4), have = 1, need = 888888 } } })
  H.run({ a, b }, 20)
  local got = b.ns.partners.Tavlius.quests[999999]
  check("near-limit quest delivered", got and #got.objs == 4 and a.realNs.channel.dropped == 0, q.title)
end

-- 114. A third DuoQuest player who said hello and went silent doesn't hold back
--      your turned-in list for long.
do
  local a = H.boot({ name = "Tavlius" })
  local b = H.boot({ name = "Mirel" })
  local c = H.boot({ name = "Gabi" })
  a.completed[777] = true
  for _, x in ipairs({ a, b, c }) do x.login() end
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 40)
  a.setGroup({ "Mirel", "Gabi" }) b.setGroup({ "Tavlius", "Gabi" }) c.setGroup({ "Tavlius", "Mirel" })
  H.run({ a, b, c }, 2)
  c.addonResult = 9  -- (Gabi disconnects: nothing more from her)
  H.run({ a, b }, 400)
  b.addQuest({ id = 777, title = "Tavlius Did It Long Ago" })
  H.run({ a, b }, 20)
  check("silent third player: turned-in list still goes out", b.ns.partners.Tavlius.done[777] == true)
end

-- 115. Command details: /dq share takes a link; /dq partner takes Name-YourRealm; /dq status
--      says when the data is old or only ignored quests differ; /dq check knows sync is off.
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 11500, title = "Linked Share" }, true)
  end, function(b) b.addQuest({ id = 11501, title = "Mirel Only" }, true) end)
  a.slash("share |cffffff00|Hquest:11500:10|h[Linked Share]|h|r")
  check("share by link", a.pushed[#a.pushed] == 11500)
  a.slash("partner Mirel-Realm")
  check("partner Name-YourRealm", a.ns.DB.focus == "Mirel", a.ns.DB.focus)
  a.slash("partner auto")
  a.slash("ignore 11500")
  a.slash("ignore 11501")
  local before = #a.printed
  a.slash("status")
  check("status: only ignored gaps", a.printedMatch("apart from quests you ignore", before + 1), since(a, before + 1))
  a.offline = { party1 = true }
  before = #a.printed
  a.slash("status")
  check("status: offline partner's data marked as old", a.printedMatch("from their last update", before + 1), since(a, before + 1))
  a.offline = nil
  b.slash("sync off")
  H.run({ a, b }, 6)
  before = #a.printed
  a.slash("check")
  check("check: partner turned sync off", a.printedMatch("Mirel: turned DuoQuest sync off", before + 1), since(a, before + 1))
end

-- 116. Your name cached at login: if it reads as a secret later, your own messages still aren't a partner.
do
  local a = Duo()
  a.secrets.player = true
  a.addQuest({ id = 11600, title = "Echo Test" })
  a.tick(6)
  H.deliver(a, { a })
  check("own echo with a secret name: not a partner", a.ns.partners.Tavlius == nil)
end

-- 117. /dq partner with a realm, typed before grouping or in other capitals, still picks him.
do
  local a = H.boot({ name = "Tavlius" })
  local b = H.boot({ name = "Mirel" })
  local c = H.boot({ name = "Bob" })
  for _, x in ipairs({ a, b, c }) do x.login() end
  a.slash("partner Mirel-Realm")
  check("partner before grouping: saved as his key", a.ns.DB.focus == "Mirel", a.ns.DB.focus)
  a.setGroup({ "Bob", "Mirel" }) b.setGroup({ "Tavlius", "Bob" }) c.setGroup({ "Tavlius", "Mirel" })
  H.run({ a, b, c }, 40)
  local f = a.ns.FocusPartner()
  check("partner before grouping: picked once grouped", f and f.key == "Mirel" and f.chosen == true, f and f.key)
  a.slash("partner mirel-realm")
  check("partner in other capitals", a.ns.DB.focus == "Mirel", a.ns.DB.focus)
  a.slash("partner Mirel-Cinder Reach")
  check("partner on another realm with a space", a.ns.DB.focus == "Mirel-CinderReach", a.ns.DB.focus)
end

-- 118. Ignoring a quest twice un-ignores it; the list says so.
do
  local a = Duo(function(a) a.addQuest({ id = 11800, title = "Ignore Me Twice" }, true) end)
  a.slash("ignore 11800")
  a.slash("ignore 11800")
  local before = #a.printed
  a.slash("ignore list")
  check("un-ignored: gone from the list", a.ns.DB.ignored[11800] == nil and a.printedMatch("no ignored quests", before + 1),
    since(a, before + 1))
end

-- 119. Collapsing a section or ignoring a quest shows at once (no wait for the next redraw).
do
  local a = Duo(function(a) a.addQuest({ id = 11900, title = "Collapse Me" }, true) end)
  local header = a.rowFor("Mirel doesn't have")
  header:Click()
  check("collapse: at once", not a.windowText():find("Collapse Me"), a.windowText())
  header = a.rowFor("Mirel doesn't have")
  header:Click()
  a.rowFor("Collapse Me"):Click("RightButton")
  check("ignore: at once", a.windowText():find("Collapse Me %(ignored%)"), a.windowText())
end

-- 120. /dq partner with a realm that has a dash (written without it in names).
do
  local a = Duo(nil, nil, { name = "Tavlius", realm = "Ash-Vale" }, { name = "Mirel", myRealm = "Ash-Vale" })
  a.slash("partner Mirel-Ash-Vale")
  local f = a.ns.FocusPartner()
  check("partner, dashed realm: picked", a.ns.DB.focus == "Mirel-AshVale" and f and f.chosen == true, a.ns.DB.focus)
end

-- 121. Distance and range unreadable (secret): /dq share still shares.
do
  local a = Duo(function(a) a.addQuest({ id = 12100, title = "Share Blind" }, true) end, nil,
    { name = "Tavlius", secrets = { distance = true, range = true } })
  a.slash("share")
  check("unreadable range: /dq share pushes", a.pushed[#a.pushed] == 12100, a.printed[#a.printed])
end

-- 122. Classic quest functions: a finished quest in the visible log is ready.
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 12200, title = "Classic Finish", objs = { { label = "x", have = 0, need = 2 } } }, true)
  end, function(b)
    b.addQuest({ id = 12200, title = "Classic Finish", objs = { { label = "x", have = 0, need = 2 } } }, true)
  end, { name = "Tavlius", classic = true })
  a.progress(12200, 1, 2)
  H.run({ a, b }, 10)
  check("classic finished: complete flag", a.ns.HasFlag(a.ns.mine[12200].flags, a.realNs.F_COMPLETE))
  check("classic finished: partner sees ready", b.windowText():find("Classic Finish || 0/2 | ready"), b.windowText())
end

-- 123. A partner's progress shows in your window within a second (not at the next 5s redraw).
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 12300, title = "Kill Count", objs = { { label = "Wolf", have = 0, need = 9 } } }, true)
  end, function(b)
    b.addQuest({ id = 12300, title = "Kill Count", objs = { { label = "Wolf", have = 0, need = 9 } } }, true)
  end)
  -- (line the clock up just after a periodic redraw)
  local count = 0
  while (a.realNs.tickCount or 0) % 10 ~= 1 and count < 20 do H.run({ a, b }, 1) count = count + 1 end
  b.progress(12300, 1, 4)
  H.run({ a, b }, 2)
  check("partner progress: shown within a second", a.windowText():find("0/9 | 4/9"), a.windowText())
end

-- 124. A secret "can it be shared" answer means "try sharing it", not "can't".
do
  local a = Duo(function(a) a.addQuest({ id = 12400, title = "Secret Pushable" }, true) end, nil,
    { name = "Tavlius", secrets = { pushable = true } })
  check("secret pushable: Share offered", a.windowText():find("Secret Pushable || %[Share"), a.windowText())
end

-- 125. A partner saved as "Name-YourRealm" by an older build still matches.
do
  local a = H.boot({ name = "Tavlius", saved = { version = 2, focus = "Mirel-Realm" } })
  local b = H.boot({ name = "Mirel" })
  local c = H.boot({ name = "Bob" })
  for _, x in ipairs({ a, b, c }) do x.login() end
  a.setGroup({ "Bob", "Mirel" }) b.setGroup({ "Tavlius", "Bob" }) c.setGroup({ "Tavlius", "Mirel" })
  H.run({ a, b, c }, 40)
  local f = a.ns.FocusPartner()
  check("old saved Name-YourRealm: still the chosen partner", f and f.key == "Mirel" and f.chosen == true, f and f.key)
end

-- 126. Times read naturally: "12s ago" in the first minute, then minutes.
do
  local a = Duo()
  check("ago: seconds", a.ns.Ago(12) == "12s", a.ns.Ago(12))
  check("ago: minutes", a.ns.Ago(180) == "3m", a.ns.Ago(180))
  check("status line: seconds ago after a sync", a.statusText():find("%(%d+s ago"), a.statusText())
end

-- 127. Icons and named colours in quest text don't reach the partner as garbage.
do
  local a = H.boot()
  H.use(a)
  local cleaned = a.realNs.Clean("|TInterface\\Icons\\INV_Misc_Bag_08:0|t Collect |cnNORMAL_FONT_COLOR:Bags|r |A:quest-icon:0:0|a")
  check("clean: icons and named colours removed", cleaned == "Collect Bags", cleaned)
end

-- 128. After a flight, everything works again: pickups mark the new hub, walking
--      off warns, zone lines on foot warn, and the next takeoff starts a new hub.
do
  local a, b = Duo()
  a.onTaxi = true
  a.tick(2)
  a.zone, a.subzone = "Redridge Mountains", "Three Corners"
  a.fire("ZONE_CHANGED_NEW_AREA")
  a.onTaxi = false
  a.subzone = "Lakeshire"
  a.tick(2)
  a.addQuest({ id = 12800, title = "Landed Gap" })
  H.run({ a, b }, 4)
  check("landed: pickup marks the hub", a.realNs.DB.hub.areas.Lakeshire == "quest")
  a.subzone = "Lake Everstill"
  H.run({ a, b }, 40)
  check("landed: walking off warns", a.printedMatch("Leaving Lakeshire") and a.printedMatch("Landed Gap"), since(a))
  a.addQuest({ id = 12801, title = "Road Gap After Landing" })
  H.run({ a, b }, 4)
  a.zone, a.subzone = "Burning Steppes", "Flame Crest"
  a.fire("ZONE_CHANGED_NEW_AREA")
  check("landed: zone line on foot warns", a.printedMatch("You left Redridge Mountains"), since(a))
  local start = a.realNs.DB.hub.since
  a.wall = a.wall + 5
  a.onTaxi = true
  a.tick(2)
  check("second takeoff: a new hub", a.realNs.DB.hub.since ~= start)
end

-- 129. Mirel's first sync arriving while you're in the air: a zone line in flight still says nothing.
do
  local a, b = H.duo()
  b.addQuest({ id = 12900, title = "Mirel From Before" }, true)
  a.login() b.login()
  a.onTaxi = true
  a.tick(2)
  local start = a.realNs.DB.hub.since
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 40)
  check("in flight: the hub stays put", a.realNs.DB.hub.since == start)
  a.zone = "Redridge Mountains"
  a.fire("ZONE_CHANGED_NEW_AREA")
  check("first sync in flight: no 'You left'", not a.printedMatch("You left"), since(a))
end

-- 130. A partner's finished progress bar reads "done".
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 13000, title = "Bar Quest", objs = { { label = "Pacify", have = 0, need = 1, type = "progressbar" },
      { label = "Report", have = 0, need = 1 } }, barPct = 10 }, true)
  end, function(b)
    b.addQuest({ id = 13000, title = "Bar Quest", objs = { { label = "Pacify", have = 0, need = 1, type = "progressbar" },
      { label = "Report", have = 0, need = 1 } }, barPct = 10 }, true)
  end)
  b.quest(13000).barPct = 100
  b.quest(13000).objs[1].have = 1
  b.fire("QUEST_LOG_UPDATE")
  H.run({ a, b }, 10)
  local q = a.ns.partners.Mirel.quests[13000]
  check("finished bar: done", q and q.objs[1] and q.objs[1].done == true, q and q.objs[1] and tostring(q.objs[1].have))
  check("finished bar: window says done", a.windowText():find("Pacify || [^\n]*| done"), a.windowText())
end

-- 131. /dq check tells the truth: shown entries vs quests, quests without
--      objectives ready or not, and a missing API says "no".
do
  local c = H.boot({ name = "Tavlius", noPushable = true })
  c.log[#c.log + 1] = { header = "Elwynn Forest" }
  c.addQuest({ id = 1, title = "Ready Delivery" }, true)
  c.addQuest({ id = 2, title = "Not Ready Yet", complete = false }, true)
  c.login()
  local before = #c.printed
  c.slash("check")
  check("check: entries vs quests", c.printedMatch("log: 3 entries, 2 quests by the game's count, 2 read", before + 1),
    since(c, before + 1))
  check("check: ready delivery", c.printedMatch("Ready Delivery %(complete%)", before + 1))
  check("check: not ready", c.printedMatch("Not Ready Yet %(not complete%)", before + 1), since(c, before + 1))
  check("check: a missing API says no", c.printedMatch("no.*C_QuestLog%.IsPushableQuest", before + 1), since(c, before + 1))
end

-- 132. Classic: a quest accepted under a collapsed header is found.
do
  local a = H.boot({ name = "Tavlius", classic = true })
  a.log[#a.log + 1] = { header = "Westfall" }
  a.addQuest({ id = 13200, title = "First" }, true)
  a.login()
  a.collapsed.Westfall = true
  a.fire("QUEST_LOG_UPDATE")
  a.tick(4)
  a.addQuest({ id = 13201, title = "Accepted While Collapsed" })
  a.tick(4)
  check("classic collapsed accept: found", a.ns.mine[13201] ~= nil and a.ns.mine[13201].title == "Accepted While Collapsed")
end

-- 133. Your partner's range change redraws at once.
do
  local a = Duo(function(a) a.addQuest({ id = 13300, title = "Range Watch" }, true) end)
  a.tick(12)
  a.distance.party1 = 80
  a.fire("UNIT_IN_RANGE_UPDATE", "party1", false)
  a.tick(1)
  local row = a.rowFor("Range Watch")
  check("partner range change: redrawn at once", row and not row.share.enabled)
end

-- 134. A quest under a header that was already collapsed before DuoQuest first
--      saw it: found through your partner's list (not shown as a gap), and not
--      treated as a new pickup.
do
  local a, b = H.duo()
  a.log[#a.log + 1] = { header = "Elwynn Forest" }
  a.addQuest({ id = 100, title = "Visible Shared" }, true)
  a.log[#a.log + 1] = { header = "Westfall" }
  a.addQuest({ id = 501, title = "The Defias Brotherhood" }, true)
  a.collapsed.Westfall = true
  b.addQuest({ id = 100, title = "Visible Shared" }, true)
  b.addQuest({ id = 501, title = "The Defias Brotherhood" }, true)
  a.login() b.login()
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 80)
  check("collapsed before first load: found", a.ns.mine[501] ~= nil)
  check("collapsed before first load: not a gap on his side", not b.windowText():find("Tavlius doesn't have"), b.windowText())
  check("collapsed before first load: not a pickup", (a.realNs.seenAt[501] or 0) == 0)
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("collapsed before first load: no warning", not a.printedMatch("Defias", before + 1), since(a, before + 1))
end

-- 135. The tooltip shows his ready and failed states and the quest's level.
do
  local a = Duo(function(a)
    a.addQuest({ id = 13500, title = "My Failed One", level = 12, failed = true, objs = { { label = "x", have = 0, need = 2 } } }, true)
  end, function(b)
    b.addQuest({ id = 13501, title = "His Ready One", level = 14, objs = { { label = "y", have = 3, need = 3 } } }, true)
  end)
  local function Tip() return (table.concat(a.tooltip, "\n"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
  a.rowFor("His Ready One"):Hover()
  local tip = Tip()
  check("tooltip: his ready state", tip:find("Mirel: ready to turn in"), tip)
  check("tooltip: his quest's level", tip:find("His Ready One %[14%]"), tip)
  a.rowFor("My Failed One"):Hover()
  tip = Tip()
  check("tooltip: your failed state", tip:find("You: failed"), tip)
end

-- 136. Share range is about 40 yards: on at 35, greyed out (and /dq share refuses) at 50.
do
  local a = Duo(function(a) a.addQuest({ id = 13600, title = "Range Forty" }, true) end)
  a.distance.party1 = 35
  a.fire("UNIT_IN_RANGE_UPDATE", "party1", true)
  a.tick(2)
  check("35 yards: Share on", a.windowText():find("Range Forty || %[Share%]"), a.windowText())
  a.distance.party1 = 50
  a.fire("UNIT_IN_RANGE_UPDATE", "party1", false)
  a.tick(2)
  check("50 yards: Share greyed out", a.windowText():find("Range Forty || %[Share%-off%]"), a.windowText())
  local before = #a.printed
  a.slash("share")
  check("50 yards: /dq share refuses", a.printedMatch("too far away", before + 1) and #a.pushed == 0, since(a, before + 1))
end

-- 137. Accepting a quest your partner already has, with the log a moment behind the event: a real pickup.
do
  local a = Duo(nil, function(b) b.addQuest({ id = 13700, title = "He Has It" }, true) end)
  H.use(a)
  a.log[#a.log + 1] = { id = 13700, title = "He Has It", level = 10, objs = {} }
  a.fire("QUEST_LOG_UPDATE")  -- (the log shows it; the accept event comes a tick later)
  a.tick(1)
  a.fire("QUEST_ACCEPTED", 13700)
  a.tick(2)
  check("lagged accept: timed as a pickup", (a.realNs.seenAt[13700] or 0) > 0, a.realNs.seenAt[13700])
end

-- 138. The "can't be shared" tooltip line names who has to get the quest.
do
  local a = Duo(function(a)
    a.addQuest({ id = 13800, title = "Mine No Share", pushable = false }, true)
    a.addQuest({ id = 13802, title = "Both No Share", pushable = false }, true)
  end, function(b)
    b.addQuest({ id = 13801, title = "His No Share", pushable = false }, true)
    b.addQuest({ id = 13802, title = "Both No Share", pushable = false }, true)
  end)
  local function Tip(title)
    a.rowFor(title):Hover()
    return (table.concat(a.tooltip, "\n"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
  end
  local tip = Tip("Mine No Share")
  check("can't-share tip, yours he lacks: he gets it", tip:find("Can't be shared: Mirel has to get it"), tip)
  tip = Tip("His No Share")
  check("can't-share tip, his you lack: you get it", tip:find("Can't be shared: get it yourself"), tip)
  tip = Tip("Both No Share")
  check("can't-share tip, both on it: no line", not tip:find("Can't be shared"), tip)
end

-- 139. Share button tooltips say why it's greyed out: too far away, or not here (offline).
do
  local a = Duo(function(a) a.addQuest({ id = 13900, title = "Grey Share" }, true) end)
  a.distance.party1 = 50
  a.fire("UNIT_IN_RANGE_UPDATE", "party1", false)
  a.tick(2)
  local function ShareTip()
    a.rowFor("Grey Share").share:Hover()
    return table.concat(a.tooltip, "\n")
  end
  local tip = ShareTip()
  check("greyed Share tip: too far away", tip:find("Mirel is too far away to receive it"), tip)
  a.offline = { party1 = true }
  a.tick(12)
  tip = ShareTip()
  check("greyed Share tip: offline says so", tip:find("Mirel is offline%."), tip)
end

-- 140. Grouping up later in a session: "Waiting for" his DuoQuest first, not "doesn't run DuoQuest".
do
  local a = H.boot()
  a.addQuest({ id = 14000, title = "Solo A While" }, true)
  a.login()
  a.tick(120)
  a.setGroup({ "Bob" })
  a.tick(4)
  check("grouped mid-session: waiting first", a.statusText():find("Waiting for Bob's DuoQuest"), a.statusText())
  a.tick(40)
  check("grouped mid-session: then explains", a.statusText():find("Bob doesn't run DuoQuest"), a.statusText())
end

-- 141. Mirel offline: picking up a quest he turned in long ago gives no "he doesn't have" note
--      (only his client knows what he's turned in).
do
  local a = Duo(nil, function(b) b.completed[14100] = true end)
  a.distance.party1 = 900
  a.offline = { party1 = true }
  H.run({ a }, 60)
  local before = #a.printed
  a.addQuest({ id = 14100, title = "He Did It Offline" })
  H.run({ a }, 40)
  check("offline partner: no 'doesn't have' note", not a.printedMatch("Mirel doesn't have", before + 1), since(a, before + 1))
end

-- 141b. A note held while he shows as offline (e.g. a moment's disconnect) still comes once he's back.
do
  local a, b = Duo()
  a.distance.party1, b.distance.party1 = 900, 900
  a.offline = { party1 = true }
  local before = #a.printed
  a.addQuest({ id = 14150, title = "Held Note" })
  H.run({ a, b }, 30)
  check("held note: not while he's offline", not a.printedMatch("Held Note", before + 1), since(a, before + 1))
  a.offline = nil
  H.run({ a, b }, 20)
  check("held note: comes once he's back", a.printedMatch("Mirel doesn't have .*Held Note", before + 1), since(a, before + 1))
end

-- 142. Right after your /reload, before his turned-in list is in (here: its first copy
--      lost): no warning that he lacks a quest he did.
do
  local a, b = Duo(nil, function(b)
    b.completed[14200] = true
    for i = 1, 12 do b.addQuest({ id = 14210 + i, title = "Mirel Q" .. i }, true) end
  end)
  a.addQuest({ id = 14200, title = "He Did This" })
  H.run({ a, b }, 20)
  check("setup: he did it", a.realNs.partners.Mirel.done[14200] == true)
  local a2 = H.reload(a)
  local lostC = 0
  a2.dropFrom = function(m)
    if lostC < 2 and m.msg:find("^%d+|C|") then lostC = lostC + 1 return true end
    return false
  end
  local warnedWrong, sawChecking = false, false
  for _ = 1, 160 do
    H.run({ a2, b }, 1)
    local p = a2.realNs.partners.Mirel
    if p and p.synced and not p.doneIn then
      sawChecking = sawChecking or a2.statusText():find("Syncing with Mirel") ~= nil
      local before = #a2.printed
      a2.fire("TAXIMAP_OPENED")
      warnedWrong = warnedWrong or a2.printedMatch("Mirel doesn't have.*He Did This", before + 1) ~= nil
    end
  end
  check("own reload: his list in before his turned-in list (the case is real)", sawChecking)
  check("own reload: no warning about a quest he turned in", not warnedWrong)
  check("own reload: not marked as warned", not a2.realNs.DB.told[14200])
  check("own reload: then filed as turned in", a2.windowText():find("Mirel already turned in"), a2.windowText())
  check("own reload: then synced", a2.statusText():find("^Synced with Mirel"), a2.statusText())
end

-- 143. Tavlius reloads twice quickly; Mirel, far away, picks up a quest Tavlius did long ago:
--      no "Tavlius doesn't have" note (it waits for Tavlius's turned-in list).
do
  local a, b = H.duo()
  a.completed[14300] = true
  for i = 1, 6 do b.addQuest({ id = 14310 + i, title = "Mirel Q" .. i }, true) end
  a.login() b.login()
  a.distance.party1, b.distance.party1 = 300, 300
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 60)
  local a2 = H.reload(a)
  H.run({ a2, b }, 5)
  local a3 = H.reload(a2)
  H.run({ a3, b }, 3)
  local before = #b.printed
  b.addQuest({ id = 14300, title = "Tavlius Did This Long Ago" })
  H.run({ a3, b }, 40)
  check("double reload: Mirel learns Tavlius did it", b.realNs.partners.Tavlius.done[14300] == true)
  check("double reload: no wrong note", not b.printedMatch("Tavlius doesn't have", before + 1), since(b, before + 1))
  -- ...and a quest Tavlius hasn't done still gets its note.
  before = #b.printed
  b.addQuest({ id = 14301, title = "Tavlius Lacks This" })
  H.run({ a3, b }, 20)
  check("double reload: a real gap still noted", b.printedMatch("Tavlius doesn't have .*Tavlius Lacks This", before + 1),
    since(b, before + 1))
end

-- 144. /dq status while his turned-in list hasn't come in yet: says so, and doesn't claim
--      everything left is ignored.
do
  local a, b = Duo(function(a) a.addQuest({ id = 14400, title = "He Lacks This" }, true) end)
  local a2 = H.reload(a)
  a2.dropFrom = function(m) return m.msg:find("^%d+|C|") ~= nil end  -- (his turned-in list doesn't arrive)
  H.run({ a2, b }, 20)
  check("setup: synced, turned-in list not in", a2.realNs.partners.Mirel.synced and not a2.realNs.partners.Mirel.doneIn)
  local before = #a2.printed
  a2.slash("status")
  local out = since(a2, before + 1)
  check("status while checking: says it's waiting", a2.printedMatch("Syncing with Mirel.*turned in isn't in yet", before + 1), out)
  check("status while checking: no 'apart from quests you ignore'", not out:find("apart from quests you ignore"), out)
  check("status while checking: nothing of his missing", out:find("you have all of Mirel's quests"), out)
  a2.slash("ignore 14400")
  before = #a2.printed
  a2.slash("status")
  check("status while checking, yours ignored: still not 'apart from quests you ignore'",
    a2.printedMatch("you have all of Mirel's quests%.", before + 1) and not a2.printedMatch("apart from", before + 1),
    since(a2, before + 1))
  a2.slash("ignore 14400")
  -- His quest you lack is still listed meanwhile, and the leave warning still names it.
  b.addQuest({ id = 14401, title = "His Own" })
  H.run({ a2, b }, 10)
  before = #a2.printed
  a2.slash("status")
  check("status while checking: his quests you lack still listed", a2.printedMatch("You don't have: .*His Own", before + 1),
    since(a2, before + 1))
  check("status while checking: not 'he doesn't have'", not a2.printedMatch("Mirel doesn't have", before + 1), since(a2, before + 1))
  before = #a2.printed
  a2.fire("TAXIMAP_OPENED")
  check("warning while checking: names his quest you lack", a2.printedMatch("His Own", before + 1), since(a2, before + 1))
  check("warning while checking: not yours he lacks", not a2.printedMatch("He Lacks This", before + 1), since(a2, before + 1))
  -- Once it's in, everything is back.
  a2.dropFrom = nil
  H.run({ a2, b }, 140)
  before = #a2.printed
  a2.slash("status")
  check("status after: he doesn't have it", a2.printedMatch("Mirel doesn't have: .*He Lacks This", before + 1), since(a2, before + 1))
end

-- 145. /dq status when every gap is one you ignore.
do
  local a = Duo(function(a) a.addQuest({ id = 14500, title = "Ignored Gap" }, true) end)
  a.slash("ignore 14500")
  local before = #a.printed
  a.slash("status")
  check("status, only ignored gaps: says so", a.printedMatch("no gaps apart from quests you ignore", before + 1), since(a, before + 1))
  a.slash("ignore 14500")
  before = #a.printed
  a.slash("status")
  check("status, gap no longer ignored: listed", a.printedMatch("Mirel doesn't have: .*Ignored Gap", before + 1), since(a, before + 1))
end

-- 146. A third DuoQuest player who said hello and went silent doesn't hold back the
--      turned-in list your partner needs for long (nor lose a pickup note).
do
  local a, b = Duo(function(a) a.addQuest({ id = 14600, title = "Third Player Gap" }, true) end,
    function(b) b.completed[14601] = true end)
  local bob = H.boot({ name = "Bob" })
  bob.login()
  a.setGroup({ "Mirel", "Bob" }) b.setGroup({ "Tavlius", "Bob" }) bob.setGroup({ "Tavlius", "Mirel" })
  bob.tick(1)
  H.deliver(bob, { a, b, bob })
  bob.addonSent, bob.delivered = {}, 0
  a.offline, b.offline = { party2 = true }, { party2 = true }
  H.run({ a, b }, 4)
  local a2 = H.reload(a)
  a2.distance.party1, b.distance.party1 = 900, 900
  local t
  for s = 1, 120 do
    H.run({ a2, b }, 1)
    if not t and a2.realNs.partners.Mirel and a2.realNs.partners.Mirel.doneIn then t = s / 2 end
  end
  check("silent third player: turned-in list in within ~20s", t and t <= 25, t)
  local before = #a2.printed
  a2.addQuest({ id = 14601, title = "He Did It Already" })
  a2.addQuest({ id = 14602, title = "He Lacks It" })
  H.run({ a2, b }, 40)
  check("silent third player: note for a real gap", a2.printedMatch("Mirel doesn't have .*He Lacks It", before + 1), since(a2, before + 1))
  check("silent third player: no note for one he did", not a2.printedMatch("He Did It Already", before + 1), since(a2, before + 1))
end

-- 147. Tooltips and rows in the other sections: no "can't be shared" line on an objective
--      row of a quest you're both on or on a turned-in one; no "[0]" level; unlabeled
--      objectives numbered; the ignored line; the Synced status' sending count.
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 14700, title = "Both Locked", pushable = false, objs = { { label = "", have = 1, need = 3 }, { label = "", have = 0, need = 1 } } }, true)
    a.addQuest({ id = 14701, title = "He Turned In", pushable = false }, true)
    a.addQuest({ id = 14702, title = "No Level", level = 0 }, true)
  end, function(b)
    b.addQuest({ id = 14700, title = "Both Locked", pushable = false, objs = { { label = "", have = 0, need = 3 }, { label = "", have = 0, need = 1 } } }, true)
    b.completed[14701] = true
  end)
  a.slash("objectives on")
  H.run({ a, b }, 20)
  local function Tip(row)
    row:Hover()
    return (table.concat(a.tooltip, "\n"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
  end
  local text = a.windowText()
  check("unlabeled objective: numbered", text:find("Objective 1 || 1/3 | 0/3"), text)
  local tip = Tip(a.rowFor("Objective 1"))
  check("objective row tip: no can't-share line", not tip:find("Can't be shared"), tip)
  a.ns.DB.collapsed.theyDid = false
  a.ns.Refresh(true) a.ns.Redraw()
  tip = Tip(a.rowFor("He Turned In"))
  check("turned-in row tip: no can't-share line", not tip:find("Can't be shared"), tip)
  tip = Tip(a.rowFor("No Level"))
  check("tooltip: no [0] level", not tip:find("%[0%]"), tip)
  check("tooltip: right-click hint", tip:find("Right%-click: ignore"), tip)
  a.slash("ignore 14702")
  H.run({ a, b }, 2)
  tip = Tip(a.rowFor("No Level"))
  check("tooltip: ignored line", tip:find("Ignored: no warnings, notes or /dq share"), tip)
  check("synced status: no sending count when nothing is queued", a.statusText():find("%(%d+s ago%)$"), a.statusText())
  for i = 1, 12 do a.addQuest({ id = 14710 + i, title = "Burst " .. i }) end
  a.tick(1)
  a.ns.Redraw()
  check("synced status: sending count while queued", a.statusText():find("sending %d+"), a.statusText())
end

-- 148. No sync data and nothing the game reports: "No quests to compare yet."
do
  local a = H.boot()
  a.login()
  a.setGroup({ "Bob" })
  a.tick(40)
  check("empty, no sync: nothing to compare yet", a.windowText():find("No quests to compare yet"), a.windowText())
end

-- 149. A loading screen right after your /reload (a portal a second later): everything
--      from Mirel that came in meanwhile is asked for again, not left for the next minute.
do
  for _, delay in ipairs({ 0, 2 }) do
    local a, b = Duo(function(a)
      a.addQuest({ id = 14900, title = "He Lacks Load" }, true)
      a.addQuest({ id = 14901, title = "He Did Load" }, true)
    end, function(b)
      b.completed[14901] = true
      b.addQuest({ id = 14902, title = "His Load Quest" }, true)
    end)
    local a2 = H.reload(a)
    H.run({ a2, b }, delay)
    a2.fire("LOADING_SCREEN_ENABLED")
    a2.dropFrom = function() return true end
    H.run({ a2, b }, 8)
    a2.dropFrom = nil
    a2.fire("PLAYER_ENTERING_WORLD", false, false)
    a2.fire("LOADING_SCREEN_DISABLED")
    H.run({ a2, b }, 20)  -- 10 seconds
    local p = a2.realNs.partners.Mirel
    check("loading screen after reload (" .. delay .. "): synced within 10s", p and p.synced and p.doneIn,
      a2.statusText())
    a2.ns.Redraw()
    local text = a2.windowText()
    check("loading screen after reload (" .. delay .. "): his quest shown", text:find("His Load Quest"), text)
    check("loading screen after reload (" .. delay .. "): his turned-in one filed", text:find("Mirel already turned in"), text)
    noErrors(a2, "loading screen after reload")
  end
end

-- 150. Logging back in while Mirel is on a loading screen: what he's turned in arrives in seconds.
do
  local a, b = Duo(function(a) a.addQuest({ id = 15000, title = "Did It While You Were Gone" }, true) end,
    function(b) b.completed[15000] = true end)
  b.offline = { party1 = true }
  H.run({ b }, 600)
  local a2 = H.reload(a, true, 300)
  b.offline = nil
  H.run({ a2, b }, 2)
  b.fire("LOADING_SCREEN_ENABLED")
  b.dropFrom = function() return true end
  H.run({ a2, b }, 6)
  b.dropFrom = nil
  b.fire("PLAYER_ENTERING_WORLD", false, false)
  b.fire("LOADING_SCREEN_DISABLED")
  H.run({ a2, b }, 20)
  local p = a2.realNs.partners.Mirel
  check("partner's loading screen at your login: his turned-in list within 10s", p and p.doneIn and p.done[15000],
    a2.statusText())
  b.ns.Redraw()
  check("partner's loading screen at your login: he's synced with you too", b.statusText():find("^Synced with Tavlius"),
    b.statusText())
end

-- 151. While his turned-in list is on its way: the section says "may not have", /dq share and
--      /dq share all wait, /dq status joins its notes into one line and skips the empty summary.
do
  local a, b = Duo(function(a) a.addQuest({ id = 15100, title = "Pending Share" }, true) end,
    function(b) b.addQuest({ id = 15101, title = "His Ignored One" }, true) end)
  local a2 = H.reload(a)
  a2.dropFrom = function(m) return m.msg:find("^%d+|C|") ~= nil end
  H.run({ a2, b }, 20)
  a2.ns.Redraw()
  check("checking: section says may not have", a2.windowText():find("Mirel may not have %(1%)"), a2.windowText())
  local before = #a2.printed
  a2.slash("share")
  check("checking: /dq share waits", a2.printedMatch("still syncing with Mirel", before + 1) and #a2.pushed == 0,
    since(a2, before + 1))
  before = #a2.printed
  a2.slash("share all")
  check("checking: /dq share all waits", a2.printedMatch("still syncing with Mirel", before + 1), since(a2, before + 1))
  a2.slash("ignore 15101")
  before = #a2.printed
  a2.slash("status")
  local out = since(a2, before + 1)
  check("checking + his ignored: says some are ignored", out:find("you have all of Mirel's quests apart from ones you ignore"), out)
  check("status: no empty 'both on 0' line", not out:find("both on 0"), out)
  a2.slash("ignore 15101")
  a2.offline = { party1 = true }
  a2.tick(4)
  before = #a2.printed
  a2.slash("status")
  out = since(a2, before + 1)
  check("offline + checking: one joined line", a2.printedMatch("from their last update; what they've turned in isn't in yet",
    before + 1), out)
  local n = 0
  for _ in out:gmatch("Mirel is offline") do n = n + 1 end
  check("offline + checking: status line once", n == 1, out)
  a2.offline = nil
  a2.dropFrom = nil
  H.run({ a2, b }, 140)
  a2.ns.Redraw()
  check("after: doesn't have again", a2.windowText():find("Mirel doesn't have %(1%)"), a2.windowText())
end

-- 152. Stale data whose turned-in list never came: says "no update", not "Syncing".
do
  local a, b = Duo(function(a) a.addQuest({ id = 15200, title = "Stale Pending" }, true) end)
  local a2 = H.reload(a)
  a2.dropFrom = function(m) return m.msg:find("^%d+|C|") ~= nil end
  H.run({ a2, b }, 20)
  a2.dropFrom = function() return true end
  H.run({ a2 }, 340)
  a2.ns.Redraw()
  check("stale while checking: no update", a2.statusText():find("Mirel: no update for"), a2.statusText())
end

-- 153. "Waiting for his DuoQuest" holds for a while (his log may still be loading).
do
  local a = H.boot()
  a.login()
  a.tick(60)
  a.setGroup({ "Bob" })
  a.tick(20)
  a.ns.Refresh(true) a.ns.Redraw()
  check("waiting status: still waiting after 10s", a.statusText():find("Waiting for Bob's DuoQuest"), a.statusText())
end

-- 154. /dq share with only one quest to share: no "0 more".
do
  local a = Duo(function(a) a.addQuest({ id = 15400, title = "Only One" }, true) end)
  local before = #a.printed
  a.slash("share")
  check("one to share: shared", a.printedMatch("asked the game to share", before + 1), since(a, before + 1))
  check("one to share: no 'more'", not a.printedMatch(" more: press again", before + 1), since(a, before + 1))
end

-- 155. A loading screen while his turned-in list is missing restarts sync: Mirel is back in sync
--      with you in seconds too (not a minute of "Resyncing"), and your pickup reaches him as a note.
do
  local a, b = Duo(function(a) a.addQuest({ id = 15500, title = "He Lacks Restart" }, true) end,
    function(b) b.addQuest({ id = 15501, title = "His Restart Quest" }, true) end)
  H.run({ a, b }, 60)
  local a2 = H.reload(a)
  a2.dropFrom = function(m) return m.msg:find("^%d+|C|") ~= nil end
  H.run({ a2, b }, 10)
  a2.dropFrom = nil
  a2.fire("PLAYER_ENTERING_WORLD", false, false)  -- (a portal a few seconds after the reload)
  a2.fire("LOADING_SCREEN_DISABLED")
  H.run({ a2, b }, 20)
  b.ns.Redraw()
  check("restart: Mirel synced with you within 10s", b.statusText():find("^Synced with Tavlius"), b.statusText())
  check("restart: you synced with Mirel", a2.realNs.partners.Mirel.doneIn == true)
  a2.distance.party1, b.distance.party1 = 400, 400
  H.run({ a2, b }, 4)
  local before = #b.printed
  a2.addQuest({ id = 15502, title = "Picked Up After Restart" })
  H.run({ a2, b }, 30)
  check("restart: your pickup reaches him as a note", b.printedMatch("Tavlius picked up .*Picked Up After Restart", before + 1),
    since(b, before + 1))
  -- ...and his "Tavlius doesn't have" notes don't wait a minute for your turned-in list.
  before = #b.printed
  b.addQuest({ id = 15503, title = "Mirel Picked After Restart" })
  H.run({ a2, b }, 20)
  check("restart: his note about your gap comes in seconds",
    b.printedMatch("Tavlius doesn't have .*Mirel Picked After Restart", before + 1), since(b, before + 1))
end

-- 156. You reload while Mirel is on a loading screen (your hello lost): his list and turned-in
--      list reach you in seconds after his loading screen.
do
  local a, b = Duo(function(a) a.addQuest({ id = 15600, title = "Mine P1" }, true) end,
    function(b) b.completed[15600] = true b.addQuest({ id = 15601, title = "His P1" }, true) end)
  H.run({ a, b }, 30)
  b.fire("LOADING_SCREEN_ENABLED")
  b.dropFrom = function() return true end
  local a2 = H.reload(a)
  H.run({ a2, b }, 6)
  b.dropFrom = nil
  b.fire("PLAYER_ENTERING_WORLD", false, false)
  b.fire("LOADING_SCREEN_DISABLED")
  H.run({ a2, b }, 20)
  local p = a2.realNs.partners.Mirel
  check("partner's loading screen during your reload: in sync within 10s", p and p.synced and p.doneIn and p.done[15600],
    a2.statusText())
end

-- 157. His first turned-in list lost, then a loading screen of his: it comes within seconds.
do
  local a, b = H.duo()
  a.addQuest({ id = 15700, title = "Mine P2" }, true)
  b.addQuest({ id = 15701, title = "His P2" }, true)
  a.login() b.login()
  b.dropFrom = function(m) return m.msg:find("^%d+|C|") ~= nil end
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 16)
  b.dropFrom = nil
  local p = b.realNs.partners.Tavlius
  check("setup: synced, turned-in list missing", p and p.synced and not p.doneIn)
  b.fire("LOADING_SCREEN_ENABLED")
  b.fire("PLAYER_ENTERING_WORLD", false, false)
  b.fire("LOADING_SCREEN_DISABLED")
  H.run({ a, b }, 20)
  p = b.realNs.partners.Tavlius
  check("loading screen with the turned-in list missing: in within 10s", p and p.doneIn, b.statusText())
end

-- 158. A share the game refuses still moves /dq share on to the next quest.
do
  local a = Duo(function(a)
    a.addQuest({ id = 15800, title = "Alpha Share" }, true)
    a.addQuest({ id = 15801, title = "Beta Share" }, true)
  end)
  a.pushFails = true
  local before = #a.printed
  a.slash("share")
  local first = since(a, before + 1):match("%[(%a+) Share%]")
  check("refused share: says so", a.printedMatch("can't share", before + 1), since(a, before + 1))
  a.pushFails = nil
  before = #a.printed
  a.slash("share")
  local second = since(a, before + 1):match("%[(%a+) Share%]")
  check("refused share: the next press moves on", first and second and first ~= second, tostring(first) .. " / " .. tostring(second))
end

-- 159. /dq status with a partner gone quiet (online): says the data is from his last update.
do
  local a, b = Duo(function(a) a.addQuest({ id = 15900, title = "Quiet One" }, true) end)
  a.dropFrom = function() return true end
  H.run({ a, b }, 400)
  a.dropFrom = nil
  local before = #a.printed
  a.slash("status")
  check("quiet partner: status says it's old data", a.printedMatch("Mirel: no update for .*from their last update", before + 1),
    since(a, before + 1))
end

-- 160. The usual partner keeps the window for 30 seconds only: then one who runs DuoQuest takes over.
do
  local a, b = Duo()
  local c = H.boot({ name = "Aaron" })
  c.login()
  b.slash("sync off")
  a.setGroup({ "Mirel", "Aaron" }) b.setGroup({ "Tavlius", "Aaron" }) c.setGroup({ "Tavlius", "Mirel" })
  H.run({ a, b, c }, 100)
  local f = a.ns.FocusPartner()
  check("after 30s a synced partner replaces a silent usual one", f and f.key == "Aaron", f and f.key)
end

-- 161. Small wording: no stray period before a note, "may not have" for game-only data in
--      /dq share all, the same "not in a group" as /dq share, "1 quest", /dq hide hint, and the
--      tooltip updating under the mouse after a right-click.
do
  local a = Duo(function(a) a.addQuest({ id = 16100, title = "Wording" }, true) end)
  a.offline = { party1 = true }
  a.tick(4)
  local before = #a.printed
  a.slash("status")
  check("offline status: no stray period", a.printedMatch("Mirel is offline|r %(what follows", before + 1)
    and not a.printedMatch("offline%.|r %(", before + 1), since(a, before + 1))
  a.offline = nil
  a.tick(4)
  a.rowFor("Wording"):Hover()
  a.rowFor("Wording"):Click("RightButton")
  local tip = table.concat(a.tooltip, "\n")
  check("tooltip after right-click: shows ignored", tip:find("Ignored: no warnings, notes or /dq share"), tip)
  a.rowFor("Wording"):Click("RightButton")
  local n = H.boot()
  n.addQuest({ id = 16101, title = "Solo Quest" }, true)
  n.login()
  n.tick(10)
  before = #n.printed
  n.slash("share all")
  check("share all, not grouped: says so", n.printedMatch("you're not in a group", before + 1), since(n, before + 1))
  before = #n.printed
  n.slash("status")
  check("status: 1 quest", n.printedMatch("%(1 quest in your log%)", before + 1), since(n, before + 1))
  before = #n.printed
  n.slash("show")
  check("solo show: /dq hide hint", n.printedMatch("/dq hide keeps it off", before + 1), since(n, before + 1))
  local g = H.boot()
  g.addQuest({ id = 16102, title = "Game Only" }, true)
  g.login()
  g.setGroup({ "Bob" })
  g.tick(40)
  before = #g.printed
  g.slash("share all")
  check("share all, game-only data: may not have", g.printedMatch("Bob may not have: .*Game Only", before + 1), since(g, before + 1))
end

-- 162. You pick up a quest while Mirel is on a loading screen (your message to him is lost):
--      no "he doesn't have" note if he turned it in long ago; a real gap is still noted after it.
do
  local a, b = Duo(nil, function(b) b.completed[16200] = true end)
  a.distance.party1, b.distance.party1 = 500, 500
  H.run({ a, b }, 4)
  b.fire("LOADING_SCREEN_ENABLED")
  b.dropFrom = function() return true end
  local before = #a.printed
  H.run({ a, b }, 1)
  a.addQuest({ id = 16200, title = "He Did This Already" })
  a.addQuest({ id = 16201, title = "He Really Lacks This" })
  H.run({ a, b }, 20)
  b.dropFrom = nil
  b.fire("PLAYER_ENTERING_WORLD", false, false)
  b.fire("LOADING_SCREEN_DISABLED")
  H.run({ a, b }, 20)
  check("pickup in his loading screen: he did it, known in seconds", a.realNs.partners.Mirel.done[16200] == true)
  check("pickup in his loading screen: no wrong note", not a.printedMatch("Mirel doesn't have .*He Did This Already", before + 1),
    since(a, before + 1))
  check("pickup in his loading screen: a real gap still noted",
    a.printedMatch("Mirel doesn't have .*He Really Lacks This", before + 1), since(a, before + 1))
end

-- 163. The quest row counts objectives done on each side.
do
  local a = Duo(function(a)
    a.addQuest({ id = 16300, title = "Two Parts", objs = { { label = "A", have = 5, need = 5 }, { label = "B", have = 0, need = 3 } } }, true)
  end, function(b)
    b.addQuest({ id = 16300, title = "Two Parts", objs = { { label = "A", have = 1, need = 5 }, { label = "B", have = 0, need = 3 } } }, true)
  end)
  check("quest row: objectives done per side", a.windowText():find("Two Parts || 1/2 obj | 0/2 obj", 1, true), a.windowText())
end

-- 164. Classic client that reports a quest without objectives as complete: collapsing its header
--      keeps it ready.
do
  local a, b = Duo(function(a)
    a.log[#a.log + 1] = { header = "Elwynn Forest" }
    a.addQuest({ id = 16400, title = "Deliver The Letter" }, true)
  end, function(b) b.addQuest({ id = 16400, title = "Deliver The Letter" }, true) end,
    { name = "Tavlius", classic = true, classicEmptyComplete = true })
  H.run({ a, b }, 10)
  check("classic, no objectives: ready", a.ns.HasFlag(a.ns.mine[16400].flags, a.ns.F_COMPLETE))
  a.collapsed["Elwynn Forest"] = true
  a.fire("QUEST_LOG_UPDATE")
  H.run({ a, b }, 20)
  check("classic, no objectives, collapsed: still ready", a.ns.mine[16400] and a.ns.HasFlag(a.ns.mine[16400].flags, a.ns.F_COMPLETE))
  check("classic, no objectives, collapsed: partner sees ready", b.windowText():find("Deliver The Letter || ready | ready", 1, true),
    b.windowText())
end

-- 165. Mirel reloads and then goes quiet (online): "no update for", not "Resyncing" forever.
do
  local a, b = Duo()
  local b2 = H.reload(b)
  a.dropFrom = function(m) return not m.msg:find("|H|") end
  H.run({ a, b2 }, 4)
  check("setup: resyncing", a.realNs.partners.Mirel.resync == true)
  a.dropFrom = function() return true end
  H.run({ a }, 340)
  a.ns.Redraw()
  check("resync gone quiet: no update", a.statusText():find("Mirel: no update for"), a.statusText())
end

-- 166. /dq share all when he can't receive a share right now says so instead of "/dq share sends".
do
  local a = Duo(function(a) a.addQuest({ id = 16600, title = "Later Share" }, true) end)
  a.offline = { party1 = true }
  a.tick(4)
  local before = #a.printed
  a.slash("share all")
  check("share all, offline: says why", a.printedMatch("Mirel doesn't have: .*Later Share.*%(Mirel is offline: share it when", before + 1)
    and not a.printedMatch("sends the next one", before + 1), since(a, before + 1))
  a.offline = nil
  a.distance.party1 = 80
  a.fire("UNIT_IN_RANGE_UPDATE", "party1", false)
  a.tick(4)
  before = #a.printed
  a.slash("share all")
  check("share all, too far: says why", a.printedMatch("Mirel is too far away: share it when", before + 1), since(a, before + 1))
  a.distance.party1 = 10
  a.fire("UNIT_IN_RANGE_UPDATE", "party1", true)
  a.tick(4)
  before = #a.printed
  a.slash("share all")
  check("share all, close: /dq share sends it", a.printedMatch("%. /dq share sends it%.", before + 1), since(a, before + 1))
end

-- 167. An idle duo sends its turned-in list about once a minute (its heartbeat), not again for
--      every list of his.
do
  local a, b = Duo(function(a) a.addQuest({ id = 16700, title = "Idle A" }, true) end,
    function(b) b.addQuest({ id = 16701, title = "Idle B" }, true) end)
  local cs = a.sentMatching("^2|C|")
  H.run({ a, b }, 600)  -- 5 minutes
  check("idle: turned-in list about once a minute", a.sentMatching("^2|C|") - cs <= 6, a.sentMatching("^2|C|") - cs)
end

-- 168. Your pickup message lost (no loading screen): his answer comes with your next list, so the
--      note waits for it instead of guessing.
do
  local a, b = Duo(nil, function(b) b.completed[16800] = true end)
  a.distance.party1, b.distance.party1 = 500, 500
  H.run({ a, b }, 4)
  local lost = false
  b.dropFrom = function(m)
    if not lost and m.msg:find("^%d+|U|") then lost = true return true end
    return false
  end
  local before = #a.printed
  a.addQuest({ id = 16800, title = "Lost Pickup He Did" })
  H.run({ a, b }, 150)
  check("lost pickup message: he did it, known", a.realNs.partners.Mirel.done[16800] == true)
  check("lost pickup message: no wrong note", not a.printedMatch("Lost Pickup He Did", before + 1), since(a, before + 1))
end

-- 169. A list of yours that shows him a pickup he never heard of is answered at once with his
--      turned-in list (even unchanged), so your note doesn't wait for his next heartbeat.
do
  local a, b = Duo()
  a.distance.party1, b.distance.party1 = 500, 500
  H.run({ a, b }, 20)
  b.dropFrom = function() return true end  -- (nothing of yours reaches him for now)
  local from = #a.addonSent + 1
  a.addQuest({ id = 16900, title = "He Never Heard" })
  H.run({ a, b }, 2)
  a.ns.SendFull()
  H.run({ a, b }, 4)
  local list
  for i = from, #a.addonSent do
    if a.addonSent[i].msg:find("^%d+|L|") then list = a.addonSent[i].msg end
  end
  b.dropFrom = nil
  check("setup: your list went out", list ~= nil)
  local cs = b.sentMatching("^2|C|")
  b.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", list, "PARTY", "Tavlius-Realm")
  b.tick(2)
  check("missed pickup in a list: answered at once", b.sentMatching("^2|C|") - cs >= 1, b.sentMatching("^2|C|") - cs)
end

-- 170. His loading screen ends at any moment after your pickup of a quest he did: no wrong note
--      (his first list after it may be built before he knew of your quest).
do
  local wrong = {}
  for endTicks = 1, 14 do
    local a, b = Duo(nil, function(b) b.completed[17000] = true end)
    a.distance.party1, b.distance.party1 = 500, 500
    H.run({ a, b }, 4)
    b.fire("LOADING_SCREEN_ENABLED")
    b.dropFrom = function() return true end
    H.run({ a, b }, 1)
    local before = #a.printed
    a.addQuest({ id = 17000, title = "He Did This One" })
    H.run({ a, b }, endTicks)
    b.dropFrom = nil
    b.fire("PLAYER_ENTERING_WORLD", false, false)
    b.fire("LOADING_SCREEN_DISABLED")
    H.run({ a, b }, 40)
    if a.printedMatch("Mirel doesn't have .*He Did This One", before + 1) then wrong[#wrong + 1] = endTicks / 2 end
  end
  check("loading screen ending any time after your pickup: no wrong note", #wrong == 0, table.concat(wrong, "s, "))
end

-- 171. Your pickup message lost, his heartbeat at any phase: no wrong note for a quest he did.
do
  local wrong = {}
  for offset = 0, 120, 12 do
    local a, b = Duo(nil, function(b) b.completed[17100] = true end)
    a.distance.party1, b.distance.party1 = 900, 900
    b.tick(offset) H.deliver(b, { a, b })  -- (his heartbeat out of step with yours)
    H.run({ a, b }, 10)
    local before = #a.printed
    a.addQuest({ id = 17100, title = "He Did This Too" })
    a.tick(1)
    b.dropFrom = function(m) return m.msg:find("|U|") ~= nil end
    H.deliver(a, { a, b })
    b.dropFrom = nil
    H.run({ a, b }, 200)
    if a.printedMatch("Mirel doesn't have .*He Did This Too", before + 1) then wrong[#wrong + 1] = offset end
  end
  check("lost pickup message, any heartbeat phase: no wrong note", #wrong == 0, table.concat(wrong, ", "))
end

-- 172. /dq share all while he's in another instance (no distance, no range): "isn't here".
do
  local a = Duo(function(a) a.addQuest({ id = 17200, title = "Elsewhere Share" }, true) end)
  a.rangeUnknown.party1 = true
  a.tick(4)
  local before = #a.printed
  a.slash("share all")
  check("share all, other instance: isn't here", a.printedMatch("Mirel isn't here: share it when", before + 1)
    and not a.printedMatch("sends the next one", before + 1), since(a, before + 1))
end

-- 173. Mirel reloads, then takes a portal before the resync finishes (his client starts over):
--      your window keeps his quests and says Resyncing.
do
  local a, b = Duo(nil, function(b) b.addQuest({ id = 17301, title = "Theirs Portal" }, true) end)
  local onlyHello = function(m) return not m.msg:find("|H|") end
  local b2 = H.reload(b)
  a.dropFrom, b2.dropFrom = onlyHello, onlyHello
  H.run({ a, b2 }, 4)
  b2.fire("LOADING_SCREEN_ENABLED")
  b2.fire("PLAYER_ENTERING_WORLD", false, false)
  b2.fire("LOADING_SCREEN_DISABLED")
  H.run({ a, b2 }, 4)
  a.ns.Redraw()
  check("reload + portal: still shows his quests", a.windowText():find("Theirs Portal"), a.windowText())
  check("reload + portal: says resyncing", a.statusText():find("Resyncing with Mirel"), a.statusText())
end

-- 174. /dq share <ID> of a quest you don't have says so, even with him out of range.
do
  local a = Duo()
  a.distance.party1 = 80
  a.fire("UNIT_IN_RANGE_UPDATE", "party1", false)
  a.tick(4)
  local before = #a.printed
  a.slash("share 99999")
  check("share unknown quest, far: not in your log", a.printedMatch("isn't in your quest log", before + 1)
    and not a.printedMatch("too far away", before + 1), since(a, before + 1))
end

-- 175. He turns in a quest you both had while you're on a loading screen (his messages lost):
--      after it, the window doesn't call it his gap, whatever the phase of his heartbeat.
do
  local function Try(load, offset)
    local a, b = H.duo()
    a.addQuest({ id = 17500, title = "Both Had This" }, true)
    b.addQuest({ id = 17500, title = "Both Had This" }, true)
    a.login() b.login()
    a.distance.party1, b.distance.party1 = 500, 500
    a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
    H.run({ a, b }, 70 + offset)
    a.fire("LOADING_SCREEN_ENABLED")
    a.dropFrom = function() return true end
    for i = 1, load * 2 do  -- (your client frozen: only his runs)
      if i == 2 then b.completed[17500] = true b.removeQuest(17500, true) end
      b.tick(1) H.deliver(b, { a, b })
    end
    a.now, a.wall = b.now, b.wall
    a.dropFrom = nil
    a.fire("PLAYER_ENTERING_WORLD", false, false)
    a.fire("LOADING_SCREEN_DISABLED")
    local wrong = 0
    for _ = 6, 120 do  -- (from 3s after the loading screen)
      H.run({ a, b }, 1)
      a.ns.Redraw()
      if a.windowText():find("Mirel doesn't have") then wrong = wrong + 1 end
    end
    return wrong
  end
  local bad = {}
  for _, load in ipairs({ 5, 15 }) do
    for off = 0, 118, 12 do
      local w = Try(load, off)
      if w > 0 then bad[#bad + 1] = load .. "s/" .. off end
    end
  end
  check("turn-in during your loading screen: not shown as his gap after it", #bad == 0, table.concat(bad, ", "))
end

-- 176. A quiet spell of about two minutes (a lost heartbeat) doesn't make him out of date.
do
  local a, b = Duo()
  a.addQuest({ id = 17600, title = "Gap Kept" })
  H.run({ a, b }, 20)
  a.dropFrom = function() return true end
  H.run({ a, b }, 260)
  a.dropFrom = nil
  a.ns.Redraw()
  check("2 min quiet: not out of date", not a.statusText():find("no update"), a.statusText())
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("2 min quiet: still warns", a.printedMatch("Gap Kept", before + 1), since(a, before + 1))
end

-- 177. Without his DuoQuest, a quest with several objectives has no "you | ?" sub-rows.
do
  local a = H.boot()
  a.addQuest({ id = 17700, title = "Two Parts Solo", objs = { { label = "Boar", have = 1, need = 5 }, { label = "Wolf", have = 0, need = 3 } } }, true)
  a.login()
  a.unitOnQuest.party1 = { [17700] = true }
  a.setGroup({ "Bob" })
  a.tick(44)
  local text = a.windowText()
  check("no-addon: both on it", text:find("Two Parts Solo || 0/2 obj", 1, true), text)
  check("no-addon: no objective sub-rows", not text:find("Boar"), text)
end

-- 178. /dq share <ID> of a quest that can never be shared, or a failed one, says so before any
--      range message; with him offline and no data, /dq share says there's nothing to compare yet.
do
  local a = Duo(function(a)
    a.addQuest({ id = 17800, title = "Giver Only", pushable = false }, true)
    a.addQuest({ id = 17801, title = "Failed One", failed = true }, true)
  end)
  a.distance.party1 = 80
  a.fire("UNIT_IN_RANGE_UPDATE", "party1", false)
  a.tick(4)
  local before = #a.printed
  a.slash("share 17800")
  check("share unshareable, far: says who gets it", a.printedMatch("Giver Only.*can't be shared: Mirel has to get it themselves", before + 1)
    and not a.printedMatch("too far away", before + 1), since(a, before + 1))
  before = #a.printed
  a.slash("share 17801")
  check("share failed, far: says failed", a.printedMatch("failed quests can't be shared", before + 1)
    and not a.printedMatch("too far away", before + 1), since(a, before + 1))
  local c = H.boot()
  c.addQuest({ id = 17802, title = "Waiting For Him" }, true)
  c.login()
  c.setGroup({ "Mirel" })
  c.offline = { party1 = true }
  c.tick(40)
  before = #c.printed
  c.slash("share")
  check("share, him offline without data: nothing to compare", c.printedMatch("Mirel is offline: nothing to compare yet", before + 1),
    since(c, before + 1))
  before = #c.printed
  c.slash("share all")
  check("share all, him offline without data: nothing to compare", c.printedMatch("Mirel is offline: nothing to compare yet", before + 1),
    since(c, before + 1))
end

-- 179. His details still on the way: his side shows "?", not "-" (no objectives).
do
  local a, b = Duo(function(a) a.addQuest({ id = 17900, title = "Details Pending", objs = { { label = "x", have = 1, need = 4 } } }, true) end)
  a.dropFrom = function(m) return m.msg:find("^%d+|U|") ~= nil end
  b.addQuest({ id = 17900, title = "Details Pending", objs = { { label = "x", have = 0, need = 4 } } })
  H.run({ a, b }, 2)
  b.ns.SendFull()
  H.run({ a, b }, 4)
  a.ns.Redraw()
  check("details pending: ?", a.windowText():find("Details Pending || 1/4 | ?", 1, true), a.windowText())
  a.dropFrom = nil
end

-- 180. /dq share all with several: "/dq share sends the next one".
do
  local a = Duo(function(a)
    a.addQuest({ id = 18000, title = "First Of Two" }, true)
    a.addQuest({ id = 18001, title = "Second Of Two" }, true)
  end)
  local before = #a.printed
  a.slash("share all")
  check("share all, two: sends the next one", a.printedMatch("Mirel doesn't have: .*First Of Two.*Second Of Two.*sends the next one",
    before + 1), since(a, before + 1))
end

-- 181. Both ready on a quest with several objectives: its objective rows are folded away.
do
  local a = Duo(function(a)
    a.addQuest({ id = 18100, title = "Both Done Two", objs = { { label = "Fang", have = 2, need = 2 }, { label = "Claw", have = 3, need = 3 } } }, true)
  end, function(b)
    b.addQuest({ id = 18100, title = "Both Done Two", objs = { { label = "Fang", have = 2, need = 2 }, { label = "Claw", have = 3, need = 3 } } }, true)
  end)
  local text = a.windowText()
  check("both ready: quest row says ready", text:find("Both Done Two || ready | ready", 1, true), text)
  check("both ready: no objective rows", not text:find("Fang"), text)
end

-- 182. What you missed during his loading screen (a new quest, progress) reaches him within
--      about 10 seconds: his list request doesn't use up his requests for details.
do
  for _, load in ipairs({ 3, 6, 10 }) do
    local a, b = Duo(function(a)
      a.addQuest({ id = 18201, title = "Both On Load", objs = { { label = "Boar", have = 0, need = 8 } } }, true)
    end, function(b)
      b.addQuest({ id = 18201, title = "Both On Load", objs = { { label = "Boar", have = 0, need = 8 } } }, true)
    end)
    H.run({ a, b }, 30)
    b.fire("LOADING_SCREEN_ENABLED")
    for i = 1, load * 2 do  -- (his client frozen: only yours runs, its messages lost)
      if i == 2 then
        a.addQuest({ id = 18200, title = "Picked During His Load" })
        a.progress(18201, 1, 5)
      end
      a.tick(1) a.delivered = #a.addonSent
    end
    b.now, b.wall = a.now, a.wall
    b.fire("PLAYER_ENTERING_WORLD", false, false)
    b.fire("LOADING_SCREEN_DISABLED")
    local t0 = a.now
    local gotNew, gotProg
    for _ = 1, 60 do
      H.run({ a, b }, 1)
      local p = b.realNs.partners.Tavlius
      if not gotNew and p.quests[18200] then gotNew = a.now - t0 end
      if not gotProg and p.quests[18201] and p.quests[18201].objs[1].have == 5 then gotProg = a.now - t0 end
    end
    check("after his " .. load .. "s loading screen: your new quest's details within 10s", gotNew and gotNew <= 10, gotNew)
    check("after his " .. load .. "s loading screen: your progress within 10s", gotProg and gotProg <= 10, gotProg)
  end
end

-- 183. His turned-in lists carry no answers (an older build): your "doesn't have" note still
--      comes, from a list of his built after the pickup, whatever his heartbeat's phase.
do
  local missed = {}
  for offset = 0, 110, 22 do
    local a, b = Duo()
    b.tick(offset) H.deliver(b, { a, b })
    a.dropFrom = function(m)
      if m.msg:find("^%d+|C|") then m.msg = m.msg:gsub(",?~[0-9a-z]+", "") end
      return false
    end
    a.distance.party1, b.distance.party1 = 400, 400
    H.run({ a, b }, 10)
    local before = #a.printed
    a.addQuest({ id = 18300, title = "No Answer Gap" })
    H.run({ a, b }, 60)
    local early = a.printedMatch("No Answer Gap", before + 1)
    H.run({ a, b }, 300)
    if early or not a.printedMatch("Mirel doesn't have .*No Answer Gap", before + 1) then missed[#missed + 1] = offset end
  end
  check("no answers: note comes later, not early, at any heartbeat phase", #missed == 0, table.concat(missed, ", "))
end

-- 184. Share on other clients: a push that refuses an argument; a client with log indexes but no
--      SetSelectedQuest; no push function at all.
do
  local a = Duo(function(a)
    a.addQuest({ id = 18400, title = "Push No Arg" }, true)
    a.addQuest({ id = 18401, title = "Index Only" }, true)
  end)
  H.use(a)
  local orig = _G.QuestLogPushQuest
  _G.QuestLogPushQuest = function(index)
    if index ~= nil then error("Usage: QuestLogPushQuest()") end
    return orig()
  end
  local n = #a.pushed
  a.slash("share 18400")
  check("push refusing an argument: shared through the selection", a.pushed[n + 1] == 18400, tostring(a.pushed[n + 1]))
  H.use(a) _G.QuestLogPushQuest = orig
  local sel = C_QuestLog.SetSelectedQuest
  C_QuestLog.SetSelectedQuest = nil
  n = #a.pushed
  a.slash("share 18401")
  check("index-only client: shared by index", a.pushed[n + 1] == 18401, tostring(a.pushed[n + 1]))
  H.use(a) C_QuestLog.SetSelectedQuest = sel
  _G.QuestLogPushQuest = nil
  local before = #a.printed
  a.slash("share 18400")
  check("no push function: says so", a.printedMatch("no quest sharing function", before + 1), since(a, before + 1))
  H.use(a) _G.QuestLogPushQuest = orig
end

-- 185. Quest IDs typed into commands: whole numbers only ("nan", "inf", 0 get the usage line, no error).
do
  local a = Duo(function(a) a.addQuest({ id = 18500, title = "Typed" }, true) end)
  for _, bad in ipairs({ "nan", "inf", "0", "-5", "1e3", "0x1f" }) do
    local before = #a.printed
    a.slash("ignore " .. bad)
    check("ignore " .. bad .. ": usage", a.printedMatch("usage: /dq ignore", before + 1), since(a, before + 1))
    before = #a.printed
    a.slash("share " .. bad)
    check("share " .. bad .. ": usage", a.printedMatch("usage: /dq share", before + 1), since(a, before + 1))
  end
  check("typed IDs: nothing ignored", next(a.realNs.DB.ignored) == nil)
  noErrors(a, "typed IDs")
end

-- 186. /dq share <ID> of Mirel's quest: says it's his, by name.
do
  local a = Duo(nil, function(b) b.addQuest({ id = 18600, title = "His Own Quest" }, true) end)
  local before = #a.printed
  a.slash("share 18600")
  check("share his quest: says it's his", a.printedMatch("His Own Quest.* is Mirel's quest, not yours: ask Mirel to share it", before + 1),
    since(a, before + 1))
end

-- 187. The note for a quest of yours he lacks that can't be shared names who has to get it.
do
  local a, b = Duo()
  a.distance.party1, b.distance.party1 = 400, 400
  H.run({ a, b }, 4)
  local before = #a.printed
  a.addQuest({ id = 18700, title = "Giver Note", pushable = false })
  H.run({ a, b }, 20)
  check("unshareable note: Mirel has to get it", a.printedMatch("Giver Note.*can't be shared: Mirel has to get it themselves", before + 1),
    since(a, before + 1))
end

-- 188. Right-click ignores from an objective row and from a turned-in row too.
do
  local a = Duo(function(a)
    a.addQuest({ id = 18800, title = "Two Obj Ignore", objs = { { label = "Paw", have = 0, need = 2 }, { label = "Ear", have = 0, need = 2 } } }, true)
    a.addQuest({ id = 18801, title = "He Did Ignore" }, true)
  end, function(b)
    b.addQuest({ id = 18800, title = "Two Obj Ignore", objs = { { label = "Paw", have = 0, need = 2 }, { label = "Ear", have = 0, need = 2 } } }, true)
    b.completed[18801] = true
  end)
  a.slash("objectives on")
  a.ns.DB.collapsed.theyDid = false
  a.ns.Refresh(true) a.ns.Redraw()
  a.rowFor("Paw"):Click("RightButton")
  check("right-click on an objective row: ignores its quest", a.ns.IsIgnored(18800))
  a.rowFor("He Did Ignore"):Click("RightButton")
  check("right-click on a turned-in row: ignores it", a.ns.IsIgnored(18801))
end

-- 189. His details request backed off (your sends were refused for a while), then a loading
--      screen of yours: your list request doesn't replace his pending one; details within 20s.
do
  local a, b = H.duo()
  a.addQuest({ id = 18900, title = "Mine Backoff" }, true)
  b.addQuest({ id = 18901, title = "His Detail Quest" }, true)
  a.dropFrom = function(m) return m.msg:find("|U|") ~= nil end  -- (his details don't arrive)
  a.login() b.login()
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 20)
  a.addonResult = 9  -- (your sends refused for a while: his details request backs off)
  a.dropFrom = nil
  H.run({ a, b }, 200)
  a.fire("LOADING_SCREEN_ENABLED")
  a.addonResult = 0
  a.fire("PLAYER_ENTERING_WORLD", false, false)
  a.fire("LOADING_SCREEN_DISABLED")
  local got
  for t = 1, 120 do
    H.run({ a, b }, 1)
    if not got and a.realNs.partners.Mirel.quests[18901] then got = t / 2 end
  end
  check("backed-off details after your loading screen: within 20s", got and got <= 20, got)
end

-- 190. Two loading screens of yours 1-3 seconds apart: what he changed meanwhile reaches you in
--      seconds (the second list request is answered when the limit allows, not dropped).
do
  local slow = {}
  for _, gap in ipairs({ 2, 4, 6 }) do
    local a, b = Duo(nil, function(b) b.addQuest({ id = 19000, title = "He Turns In" }, true) end)
    a.distance.party1, b.distance.party1 = 500, 500
    H.run({ a, b }, 20)
    local function Load(ticks, during)
      a.fire("LOADING_SCREEN_ENABLED")
      for i = 1, ticks do
        if during and i == 2 then during() end
        b.tick(1) H.deliver(b, { b })  -- (your client frozen: his messages to you lost)
      end
      a.now, a.wall = b.now, b.wall
      a.fire("PLAYER_ENTERING_WORLD", false, false)
      a.fire("LOADING_SCREEN_DISABLED")
    end
    Load(6)
    H.run({ a, b }, gap)
    Load(6, function()
      b.completed[19000] = true b.removeQuest(19000, true)
      b.addQuest({ id = 19001, title = "He Picks Up" })
    end)
    local t
    for i = 1, 60 do
      H.run({ a, b }, 1)
      local p = a.realNs.partners.Mirel
      if not t and p.list[19001] and not p.list[19000] then t = i / 2 end
    end
    if not (t and t <= 10) then slow[#slow + 1] = gap / 2 .. "s:" .. tostring(t) end
  end
  check("two loading screens: his changes within 10s", #slow == 0, table.concat(slow, ", "))
end

-- 191. You /reload a few seconds after a pickup: his "Tavlius picked up" note still comes.
do
  local lost = {}
  for _, after in ipairs({ 1, 4, 8, 11 }) do
    local a, b = Duo()
    a.distance.party1, b.distance.party1 = 500, 500
    H.run({ a, b }, 4)
    local before = #b.printed
    a.addQuest({ id = 19100, title = "Far Pickup Reload" })
    H.run({ a, b }, after)
    local a2 = H.reload(a)
    a2.distance.party1 = 500
    H.run({ a2, b }, 60)
    if not b.printedMatch("Tavlius picked up .*Far Pickup Reload", before + 1) then lost[#lost + 1] = after / 2 end
  end
  check("your reload after a pickup: his note still comes", #lost == 0, table.concat(lost, "s, "))
end

-- 192. A repeatable quest (never flagged completed): after you turn it in, Mirel taking it is a
--      gap again, not "already turned in". On a client without the completed flag, a turn-in
--      this session still counts.
do
  local a, b = Duo(function(a) a.addQuest({ id = 19200, title = "Additional Runecloth" }, true) end)
  a.removeQuest(19200, true, true)  -- (turned in; the completed flag never set)
  H.run({ a, b }, 140)
  b.addQuest({ id = 19200, title = "Additional Runecloth" })
  H.run({ a, b }, 20)
  check("repeatable: a gap again", a.windowText():find("You don't have") and not a.windowText():find("You already turned in"),
    a.windowText())
  local c = H.boot()
  c.addQuest({ id = 19201, title = "No Flag API" }, true)
  c.login()
  H.use(c)
  C_QuestLog.IsQuestFlaggedCompleted = nil
  _G.IsQuestFlaggedCompleted = nil
  c.removeQuest(19201, true, true)
  c.tick(300)
  check("no completed-flag API: this session's turn-in still known", c.realNs.IsDone(19201) == true)
end

-- 193. Odd typed IDs: a 10-digit number gets the usage line.
do
  local a = Duo()
  local before = #a.printed
  a.slash("ignore 1234567890")
  check("huge typed ID: usage", a.printedMatch("usage: /dq ignore", before + 1), since(a, before + 1))
  a.slash("ignore 123456789")
  check("a 9-digit ID is taken", a.ns.IsIgnored(123456789))
end

-- 194. /dq ignore: the confirmation says how to undo; undoing says so; /dq ignore alone lists them.
do
  local a = Duo(function(a) a.addQuest({ id = 19400, title = "Undo Me" }, true) end)
  local before = #a.printed
  a.slash("ignore 19400")
  check("ignore: says how to undo", a.printedMatch("Undo Me.*/dq ignore 19400 or a right%-click undoes it", before + 1), since(a, before + 1))
  before = #a.printed
  a.slash("ignore")
  check("ignore alone: lists them", a.printedMatch("ignored: .*Undo Me", before + 1), since(a, before + 1))
  before = #a.printed
  a.slash("ignore 19400")
  check("ignore again: no longer ignoring", a.printedMatch("no longer ignoring .*Undo Me", before + 1), since(a, before + 1))
end

-- 195. An objective only his copy shows yet (yours not read) takes its name from his.
do
  local a = Duo(function(a)
    a.addQuest({ id = 19500, title = "Uneven Objs", objs = { { label = "Horn", have = 0, need = 2 } } }, true)
  end, function(b)
    b.addQuest({ id = 19500, title = "Uneven Objs", objs = { { label = "Horn", have = 1, need = 2 }, { label = "Hoof", have = 0, need = 2 } } }, true)
  end)
  local text = a.windowText()
  check("objective only on his side: named from his", text:find("Hoof || - | 0/2", 1, true), text)
end

-- 196. His pickup of a quest that can't be shared: the note says you have to get it yourself.
do
  local a, b = Duo()
  a.distance.party1, b.distance.party1 = 500, 500
  H.run({ a, b }, 4)
  local before = #a.printed
  b.addQuest({ id = 19600, title = "His Giver Quest", pushable = false })
  H.run({ a, b }, 20)
  check("his unshareable pickup: get it yourself", a.printedMatch("His Giver Quest.*can't be shared: get it yourself", before + 1),
    since(a, before + 1))
end

-- 197. Requests for your list: one right after a details request is answered at once (their own
--      limits); two within a second get one answer now and one later, not two at once.
do
  local a, b = Duo(function(a) a.addQuest({ id = 19700, title = "Asked About" }, true) end)
  H.run({ a, b }, 30)
  local function Ask(list)
    a.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|N|Tavlius-Realm|" .. list, "PARTY", "Mirel-Realm")
  end
  local l0 = a.sentMatching("^2|L|")
  Ask(a.realNs.To36(19700))  -- (details)
  a.tick(2)
  Ask("")                    -- (his list request, a second later)
  a.tick(2)
  check("list request right after a details request: answered at once", a.sentMatching("^2|L|") - l0 == 1, a.sentMatching("^2|L|") - l0)
  Ask("")
  a.tick(1)
  check("second list request within a second: not answered at once", a.sentMatching("^2|L|") - l0 == 1, a.sentMatching("^2|L|") - l0)
  a.tick(20)
  check("second list request: answered when the limit allows", a.sentMatching("^2|L|") - l0 == 2, a.sentMatching("^2|L|") - l0)
  a.tick(30)
  check("list requests: answered once each, not again and again", a.sentMatching("^2|L|") - l0 == 2, a.sentMatching("^2|L|") - l0)
end

-- 198. A gap of his that failed reads "Mirel's failed" in /dq status.
do
  local a = Duo(nil, function(b) b.addQuest({ id = 19800, title = "His Failed Gap", failed = true }, true) end)
  local before = #a.printed
  a.slash("status")
  check("his failed gap: whose", a.printedMatch("His Failed Gap.*%(Mirel's failed%)", before + 1), since(a, before + 1))
end

-- 199. A turn-in whose completed flag lags (up to a minute): still "already turned in" for him
--      when his next pickup is answered a few seconds later.
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 19900, title = "Shared Lag", objs = { { label = "x", have = 1, need = 1 } } }, true)
  end, function(b)
    b.addQuest({ id = 19900, title = "Shared Lag", objs = { { label = "x", have = 0, need = 1 } } }, true)
  end)
  H.run({ a, b }, 10)
  a.removeQuest(19900, true, true)  -- (the game's completed flag lags the turn-in)
  H.run({ a, b }, 10)
  b.addQuest({ id = 19901, title = "His Next" })  -- (your client answers with its turned-in list)
  H.run({ a, b }, 10)
  local view = b.ns.Compare(b.ns.FocusPartner())
  check("lagged completed flag: still turned in for him", b.ns.partners.Tavlius.done[19900] == true and #view.theyDid == 1, #view.theyDid)
end

-- 200. A 40-byte title arrives whole (only longer ones are cut).
do
  local title = string.rep("Abcdefghij", 4)
  local a = Duo(nil, function(b) b.addQuest({ id = 20000, title = title }, true) end)
  local q = a.ns.partners.Mirel.quests[20000]
  check("40-byte title: whole", q and q.title == title, q and q.title)
end

-- 201. /dq solo on while the window is closed says how to open it; a drag whose row disappears
--      (or the window hides) is ended, and the spot saved.
do
  local a = Duo()
  a.slash("hide")
  local before = #a.printed
  a.slash("solo on")
  check("solo on while closed: says /dq shows it", a.printedMatch("It's closed: /dq shows it", before + 1), since(a, before + 1))
  before = #a.printed
  a.slash("warn on")
  check("another toggle while closed: no 'It's closed'", not a.printedMatch("It's closed", before + 1), since(a, before + 1))
  a.slash("show")
  a.slash("solo off")
  before = #a.printed
  a.slash("solo on")
  check("solo on while open: no 'It's closed'", a.printedMatch("window shows even", before + 1)
    and not a.printedMatch("It's closed", before + 1), since(a, before + 1))
  a.slash("solo off")
  local f = a.realNs.frame
  local row = a.realNs.rows[1]
  H.use(a)
  row:GetScript("OnDragStart")(row)
  check("setup: dragging", f.moving == true)
  f:Hide()
  check("drag ended when the window hides", not f.moving, tostring(f.moving))
  f:Show()
  row:GetScript("OnDragStart")(row)
  a.tick(3)
  check("a held drag keeps going", f.moving == true, tostring(f.moving))
  a.mouseUp = true
  a.tick(1)
  check("drag ended when the button is up and no stop came", not f.moving, tostring(f.moving))
  a.mouseUp = nil
end

-- 202. /dq status with the same quests: "no gaps between you and Mirel"; /dq show on a fresh
--      session never says "hidden".
do
  local a = Duo(function(a) a.addQuest({ id = 20200, title = "Same" }, true) end,
    function(b) b.addQuest({ id = 20200, title = "Same" }, true) end)
  local before = #a.printed
  a.slash("status")
  check("same quests: no gaps between you", a.printedMatch("no gaps between you and Mirel%.", before + 1), since(a, before + 1))
  before = #a.printed
  a.slash("show")
  check("show on a fresh session: no 'hidden'", not a.printedMatch("window hidden", before + 1), since(a, before + 1))
end

-- 203. A loading screen while dead (releasing your spirit) isn't travelling: the corpse run
--      back to town and walking out still warns about the town's gaps.
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  H.run({ a, b }, 4)
  b.addQuest({ id = 20300, title = "Mirel Town Pickup" })
  H.run({ a, b }, 10)
  a.dead = true
  a.fire("LOADING_SCREEN_ENABLED")
  a.subzone = "Northshire Graveyard"
  a.fire("PLAYER_ENTERING_WORLD", false, false)
  a.fire("LOADING_SCREEN_DISABLED")
  H.run({ a, b }, 20)
  a.subzone = "Goldshire"
  H.run({ a, b }, 10)
  a.dead = false
  H.run({ a, b }, 4)
  local before = #a.printed
  a.subzone = "Fargodeep Mine"
  H.run({ a, b }, 40)
  check("loading screen while dead: town's gap still warned", a.printedMatch("Leaving Goldshire", before + 1)
    and a.printedMatch("Mirel Town Pickup", before + 1), since(a, before + 1))
end

-- 204. A tooltip open on a row follows the row: the list moving under the mouse, or his progress.
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 20401, title = "Zebra Quest", objs = { { label = "Z", have = 2, need = 8 } } }, true)
  end, function(b)
    b.addQuest({ id = 20401, title = "Zebra Quest", objs = { { label = "Z", have = 2, need = 8 } } }, true)
  end)
  local row = a.rowFor("Zebra Quest")
  row:Hover()
  b.progress(20401, 1, 5)
  H.run({ a, b }, 12)
  a.ns.Redraw()
  local tip = table.concat(a.tooltip, "\n")
  check("hovered tooltip: his new progress", tip:find("Mirel: Z 5/8"), tip)
  a.addQuest({ id = 20402, title = "Aardvark Quest" })  -- (sorts in above it)
  H.run({ a, b }, 12)
  a.ns.Redraw()
  tip = table.concat(a.tooltip, "\n")
  local want = row.questID and a.ns.TitleFor(row.questID)
  check("hovered tooltip: follows what the row shows now", row.questID ~= 20401
    and (want and tip:find(want, 1, true) or (not want and not a.tooltip.shown)), tostring(want) .. " / " .. tip)
end

-- 204b. A Share tooltip open while he walks out of range says so after the redraw.
do
  local a = Duo(function(a) a.addQuest({ id = 20410, title = "Hover Share" }, true) end)
  a.distance.party1 = 10
  a.fire("UNIT_IN_RANGE_UPDATE", "party1", true)
  a.tick(2)
  a.rowFor("Hover Share").share:Hover()
  check("share tooltip: in range", table.concat(a.tooltip, "\n"):find("Asks the game to share"), table.concat(a.tooltip, "\n"))
  a.distance.party1 = 80
  a.fire("UNIT_IN_RANGE_UPDATE", "party1", false)
  a.tick(12)
  a.ns.Redraw()
  check("share tooltip: updated to too far", table.concat(a.tooltip, "\n"):find("too far away"), table.concat(a.tooltip, "\n"))
end

-- 205. Right after /dq sync on: "Waiting for Mirel's DuoQuest", not "doesn't run DuoQuest".
do
  local a = Duo()
  a.slash("sync off")
  a.tick(4)
  a.slash("sync on")
  a.tick(1)
  a.ns.Redraw()
  check("sync on: waiting, not 'doesn't run'", a.statusText():find("Waiting for Mirel") or a.statusText():find("Syncing with Mirel"),
    a.statusText())
end

-- 206. An open-road spot left in a fight: the held warning still says "Moving on".
do
  local a, b = Duo()
  a.subzone = ""
  H.run({ a, b }, 4)
  a.addQuest({ id = 20600, title = "Wilderness Held" })
  H.run({ a, b }, 10)
  a.combat = true
  a.subzone = "Fargodeep Mine"
  H.run({ a, b }, 34)
  local before = #a.printed
  a.combat = false
  a.fire("PLAYER_REGEN_ENABLED")
  a.tick(1)
  check("held open-road warning: Moving on", a.printedMatch("Moving on:", before + 1)
    and not a.printedMatch("Leaving Elwynn Forest", before + 1), since(a, before + 1))
end

-- 207. Logging in as a ghost: the hub still starts, so walking out of town warns.
do
  local a, b = H.duo()
  a.dead = true
  a.subzone = "Northshire Graveyard"
  a.login() b.login()
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 40)
  a.dead = false
  a.fire("PLAYER_ALIVE")
  a.subzone = "Goldshire"
  H.run({ a, b }, 4)
  a.addQuest({ id = 20700, title = "Town Pick Ghost" })
  H.run({ a, b }, 10)
  local before = #a.printed
  a.subzone = "Fargodeep Mine"
  H.run({ a, b }, 40)
  check("logged in as a ghost: walking out still warns", a.printedMatch("Leaving Goldshire", before + 1), since(a, before + 1))
end

-- 208. A section header slides under the mouse: the old quest's tooltip goes away.
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 20801, title = "Alpha Mine" }, true)
    a.addQuest({ id = 20802, title = "Beta Mine" }, true)
  end, function(b) b.addQuest({ id = 20803, title = "Mirel Thing" }, true) end)
  a.ns.Redraw()
  local row = a.rowFor("Beta Mine")
  row:Hover()
  check("setup: tooltip on Beta Mine", table.concat(a.tooltip, " "):find("Beta Mine", 1, true) and a.tooltip.shown)
  b.addQuest({ id = 20801, title = "Alpha Mine" }) b.addQuest({ id = 20802, title = "Beta Mine" })
  H.run({ a, b }, 20)
  a.ns.Redraw()
  check("setup: a header is under the mouse now", row.section ~= nil and row.questID == nil, tostring(row.questID))
  check("header under the mouse: old tooltip gone", not a.tooltip.shown, table.concat(a.tooltip, " | "))
end

-- 209. Notes about the same quest: a re-pickup 45s or 57s after its note gets none; 75s after, one.
do
  local counts = {}
  for _, gap in ipairs({ 90, 114, 150 }) do  -- (half-seconds after the note)
    local a, b = Duo()
    a.distance.party1, b.distance.party1 = 500, 500
    H.run({ a, b }, 4)
    b.addQuest({ id = 20900, title = "Picked Again" })
    local t = 0
    while a.printedCount("Mirel picked up .*Picked Again") == 0 and t < 30 do H.run({ a, b }, 1) t = t + 1 end
    b.removeQuest(20900)
    H.run({ a, b }, gap)
    b.addQuest({ id = 20900, title = "Picked Again" })
    H.run({ a, b }, 30)
    counts[#counts + 1] = a.printedCount("Mirel picked up .*Picked Again")
  end
  check("re-pickup 45s after the note: no second note", counts[1] == 1, counts[1])
  check("re-pickup 57s after the note: no second note", counts[2] == 1, counts[2])
  check("re-pickup 75s after the note: a second note", counts[3] == 2, counts[3])
end

-- 210. A note due while his client is loading waits for what he missed: Tavlius turns the quest in
--      during Mirel's loading screen, and Mirel gets no "picked up" note for it.
do
  local a, b = Duo()
  a.distance.party1, b.distance.party1 = 500, 500
  H.run({ a, b }, 4)
  local before = #b.printed
  a.addQuest({ id = 21000, title = "Talk To The Guard" })
  a.tick(1) H.deliver(a, { a, b })
  b.fire("LOADING_SCREEN_ENABLED")
  for i = 1, 14 do  -- (his client frozen 7s; yours turns it in meanwhile, its messages lost)
    if i == 3 then a.completed[21000] = true a.removeQuest(21000, true) end
    a.tick(1) a.delivered = #a.addonSent
  end
  b.now, b.wall = a.now, a.wall
  b.fire("PLAYER_ENTERING_WORLD", false, false)
  b.fire("LOADING_SCREEN_DISABLED")
  H.run({ a, b }, 20)
  check("note after his loading screen: none for a quest already gone", not b.printedMatch("Talk To The Guard", before + 1),
    since(b, before + 1))
end

-- 211. Mirel picks up a quest right by you in town after you came from the open road: the town
--      replaces the road stand-in, so walking back onto the road warns.
do
  local a, b = Duo()
  a.subzone = ""
  H.run({ a, b }, 4)
  a.addQuest({ id = 21100, title = "Roadside Item" })
  H.run({ a, b }, 6)
  a.subzone = "Goldshire"
  a.distance.party1, b.distance.party1 = 20, 20
  H.run({ a, b }, 4)
  b.addQuest({ id = 21101, title = "Mirel Goldshire Pickup" })
  H.run({ a, b }, 6)
  check("partner pickup by you: town replaces the road", a.realNs.DB.hub.areas.Goldshire ~= nil and a.realNs.DB.hub.wild == nil,
    tostring(a.realNs.DB.hub.wild))
end

-- 212. A Hearthstone cast in a fight that goes through: the held warning, given after the trip,
--      says "You hearthed away from <town>", not "Before you hearth".
do
  local a, b = Duo()
  a.subzone = "Goldshire"
  H.run({ a, b }, 4)
  a.addQuest({ id = 21200, title = "Hearth Gap" })
  H.run({ a, b }, 10)
  local before = #a.printed
  a.combat = true
  a.fire("UNIT_SPELLCAST_START", "player", "Cast-H", 8690)
  a.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-H", 8690)
  a.fire("LOADING_SCREEN_ENABLED")
  a.zone, a.subzone = "Dun Morogh", "Kharanos"
  a.fire("PLAYER_ENTERING_WORLD", false, false)
  a.fire("LOADING_SCREEN_DISABLED")
  a.combat = false
  a.fire("PLAYER_REGEN_ENABLED")
  check("hearth through in a fight: says it already happened", a.printedMatch("You hearthed away from Goldshire:", before + 1)
    and not a.printedMatch("Before you hearth", before + 1) and a.printedMatch("Hearth Gap", before + 1), since(a, before + 1))
end

-- 213. His pickup about 45 yards from you (README: within about 60) makes your spot part of the hub.
do
  local a, b = Duo()
  a.subzone = "Crystal Lake"
  a.distance.party1, b.distance.party1 = 45, 45
  H.run({ a, b }, 4)
  b.addQuest({ id = 21300, title = "Lakeside Pickup" })
  H.run({ a, b }, 10)
  check("his pickup 45 yards away: your spot joins the hub", a.realNs.DB.hub.areas["Crystal Lake"] ~= nil)
end

-- 214. Exactly five gaps: all named, no "(/dq status)" pointer.
do
  local a, b = Duo()
  H.run({ a, b }, 4)
  for i = 1, 5 do a.addQuest({ id = 21400 + i, title = "Five Gap " .. i }) end
  H.run({ a, b }, 10)
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  local out = since(a, before + 1)
  local named = 0
  for i = 1, 5 do if out:find("Five Gap " .. i, 1, true) then named = named + 1 end end
  check("five gaps: all named", named == 5, out)
  check("five gaps: no /dq status pointer", not out:find("/dq status", 1, true), out)
end

os.exit(H.summary("more") and 0 or 1)
