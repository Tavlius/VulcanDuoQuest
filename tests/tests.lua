-- DuoQuest end-to-end tests: two (or three) simulated clients talking over a
-- simulated party channel.
package.path = assert(os.getenv("DQ_TESTS"), "DQ_TESTS unset: run tests/run.sh") .. "?.lua;" .. package.path
local H = require("harness")
local check = H.check

local function noErrors(c, label)
  check(label .. ": no errors", #c.errors() == 0, table.concat(c.errors(), " / "))
end

-- A grouped, logged-in duo with the quests set up before login, already synced.
local function Duo(setupA, setupB, optsA, optsB)
  local a, b = H.duo(optsA, optsB)
  if setupA then setupA(a) end
  if setupB then setupB(b) end
  a.login() b.login()
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 40)
  return a, b
end

local function Standard()
  return Duo(function(a)
    a.addQuest({ id = 101, title = "Wolves Across the Border", objs = { { label = "Wolf Meat", have = 2, need = 8 } } }, true)
    a.addQuest({ id = 102, title = "Report to Goldshire", pushable = false }, true)
    a.addQuest({ id = 103, title = "Kobold Camp Cleanup", objs = { { label = "Kobold Vermin slain", have = 6, need = 10 } } }, true)
  end, function(b)
    b.addQuest({ id = 103, title = "Kobold Camp Cleanup", objs = { { label = "Kobold Vermin slain", have = 10, need = 10 } } }, true)
    b.addQuest({ id = 104, title = "Brotherhood of Thieves", objs = { { label = "Red Burlap Bandana", have = 1, need = 12 } } }, true)
  end)
end

-- Quests picked up after login (so they count as "picked up at this hub").
local function FreshGaps(a, b)
  a.addQuest({ id = 201, title = "Fresh Shareable", objs = { { label = "Boars", have = 0, need = 5 } } })
  a.addQuest({ id = 202, title = "Fresh Giver Only", pushable = false, objs = { { label = "x", have = 0, need = 1 } } })
  b.addQuest({ id = 203, title = "Mirel's Fresh One", objs = { { label = "y", have = 0, need = 2 } } })
  H.run({ a, b }, 20)
end

-- 1. Solo login
do
  local c = H.boot()
  c.addQuest({ id = 1, title = "A" }, true)
  c.login()
  check("solo: quest log read", c.ns.mineReady and c.ns.mine[1] ~= nil)
  check("solo: window hidden when not grouped", not c.ui.shown)
  check("solo: welcome printed once", c.printedCount("loaded%.") == 1)
  check("solo: nothing sent", #c.addonSent == 0)
  c.slash("solo on")
  c.tick(2)
  check("solo on: window shows while solo", c.ui.shown and c.printedMatch("shows even when there's nobody to compare with"))
  check("solo on: says not in a group", c.statusText():find("Not in a group"), c.statusText())
  c.slash("solo off")
  c.tick(2)
  check("solo off: hidden again", not c.ui.shown)
  c.slash("solo")
  check("solo: toggles", c.ns.DB.hideSolo == false)
  local esc = false
  for _, n in ipairs(_G.UISpecialFrames) do if n == "VulcanDuoQuestFrame" then esc = true end end
  check("solo: Esc doesn't hide it (it's a display you keep up)", not esc)
  noErrors(c, "solo")
end

-- 2. Waits for the quest log to load before telling anyone anything
do
  local a, b = H.duo()
  a.addQuest({ id = 5, title = "Five" }, true)
  a.inGroup, a.group = true, { "Mirel" }
  b.login() b.setGroup({ "Tavlius" })
  a.fire("ADDON_LOADED", "VulcanDuoQuest")
  a.fire("PLAYER_LOGIN")
  a.fire("PLAYER_ENTERING_WORLD", true, false)
  H.run({ a, b }, 6)  -- 3s, no QUEST_LOG_UPDATE yet
  check("first scan: nothing sent before the log loads", #a.addonSent == 0, #a.addonSent)
  a.fire("QUEST_LOG_UPDATE")
  H.run({ a, b }, 30)
  check("first scan: sent after the log loads", b.ns.partners.Tavlius and b.ns.partners.Tavlius.quests[5] ~= nil)
  local c = H.boot({ name = "Dana" })
  c.addQuest({ id = 6 }, true)
  c.fire("ADDON_LOADED", "VulcanDuoQuest") c.fire("PLAYER_LOGIN")
  c.tick(14)
  check("first scan: waits up to ~8s without the event", c.ns.mineReady == false)
  c.tick(4)
  check("first scan: then scans anyway", c.ns.mineReady == true)
  noErrors(a, "firstscan")
end

-- 3. Duo sync basics
do
  local a, b = Standard()
  local p = a.ns.partners.Mirel
  check("sync: partner known and synced", p and p.synced)
  check("sync: partner list", p and p.list[103] and p.list[104] and not p.list[101])
  check("sync: partner details", p and p.quests[104] and p.quests[104].title == "Brotherhood of Thieves")
  check("sync: reverse direction", b.ns.partners.Tavlius and b.ns.partners.Tavlius.quests[101] ~= nil)
  check("sync: no client throttling", a.throttled == 0 and b.throttled == 0, a.throttled .. "/" .. b.throttled)
  a.tick(2)
  local rows = a.rowTexts()
  local expect = {
    "- Mirel doesn't have (2) || ",
    "Report to Goldshire || can't share",
    "Wolves Across the Border || [Share]",
    "- You don't have (1) || ",
    "Brotherhood of Thieves || ask Mirel",
    "- Both on (you | Mirel) (1) || ",
    "Kobold Camp Cleanup || 6/10 | ready",  -- (one objective: its progress, no separate row)
  }
  check("window: exact rows", table.concat(rows, "\n") == table.concat(expect, "\n"), "\n" .. table.concat(rows, "\n"))
  check("status: synced", a.statusText():find("^Synced with Mirel"), a.statusText())
  local r1 = a.realNs.rows[1]
  check("rows: anchored top-left and top-right (no conflicting points)", r1.points[1][1] == "TOPLEFT"
    and r1.points[2][1] == "TOPRIGHT" and r1.points[1][5] == r1.points[2][5])
  for _, m in ipairs(a.addonSent) do
    check("sync: message fits (" .. m.msg:sub(1, 12) .. ")", #m.msg <= 255)
    check("sync: party channel", m.ch == "PARTY")
  end
  noErrors(a, "sync A") noErrors(b, "sync B")
end

-- 4. Joining: one full exchange each way, and none for members without DuoQuest
do
  local a, b = H.duo()
  for i = 1, 10 do a.addQuest({ id = 300 + i }, true) b.addQuest({ id = 400 + i }, true) end
  a.login() b.login()
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 60)
  check("join: each quest sent once (A)", a.sentMatching("^2|U|") == 10, a.sentMatching("^2|U|"))
  check("join: each quest sent once (B)", b.sentMatching("^2|U|") == 10, b.sentMatching("^2|U|"))
  check("join: a hello and at most one answer each", a.sentMatching("^2|H|") <= 2 and b.sentMatching("^2|H|") <= 2)
  local sent = #a.addonSent
  for i, name in ipairs({ "Pug1", "Pug2", "Pug3" }) do
    a.setGroup({ "Mirel", name }) b.setGroup({ "Tavlius", name })
    H.run({ a, b }, 10 * i)
  end
  check("join: strangers joining cause no resend", a.sentMatching("^2|U|", sent + 1) == 0
    and a.sentMatching("^2|H|", sent + 1) == 0, #a.addonSent - sent)
  noErrors(a, "join") noErrors(b, "join B")
end

-- 5. A reload: one full exchange, no pickup notes
do
  local a, b = Standard()
  b.distance.party1 = 500  -- apart, so notes would show
  local sentB = #b.addonSent
  local printedB = #b.printed
  local a2 = H.boot({ name = "Tavlius", saved = a.saved() })
  for _, q in ipairs(a.log) do a2.addQuest(q, true) end
  a2.addQuest({ id = 150, title = "Got While Away" }, true)  -- (picked up on another session)
  a2.inGroup, a2.group = true, { "Mirel" }
  a2.login()
  H.run({ a2, b }, 60)
  check("reload: partner resynced", a2.ns.partners.Mirel and a2.ns.partners.Mirel.synced
    and a2.ns.partners.Mirel.quests[104] ~= nil)
  check("reload: B sent its quests once", b.sentMatching("^2|U|", sentB + 1) == 2, b.sentMatching("^2|U|", sentB + 1))
  check("reload: A sent its quests once", a2.sentMatching("^2|U|") == 4, a2.sentMatching("^2|U|"))
  H.run({ a2, b }, 20)
  check("reload: no pickup notes on B", not b.printedMatch("picked up", printedB + 1))
  check("reload: B sees the new quest", b.ns.partners.Tavlius.quests[150] ~= nil)
  check("reload: B's record kept", b.ns.partners.Tavlius.list[101] ~= nil)
  noErrors(a2, "reload") noErrors(b, "reload B")
end

-- 6. Objective progress flows across, and progress jumps the backlog
do
  local a, b = Standard()
  b.progress(104, 1, 7)
  H.run({ a, b }, 4)
  local q = a.ns.partners.Mirel.quests[104]
  check("progress: partner objective updated", q and q.objs[1].have == 7, q and q.objs[1].have)
  a.progress(103, 1, 10)
  H.run({ a, b }, 4)
  a.tick(2)
  local text = a.windowText()
  check("progress: both ready hides objective lines", text:find("Kobold Camp Cleanup || ready | ready")
    and not text:find("Kobold Vermin slain"), text)
  -- A big backlog doesn't delay a visible change.
  for i = 1, 20 do b.addQuest({ id = 700 + i }, true) end
  b.ns.SendFull()
  b.progress(104, 1, 9)
  H.run({ a, b }, 3)
  check("progress: sent ahead of a backlog", a.ns.partners.Mirel.quests[104].objs[1].have == 9)
  noErrors(a, "progress")
end

-- 7. Sharing
do
  local a, b = Standard()
  a.selected = 103
  local row = a.rowFor("Wolves Across")
  check("share: row has an enabled Share button", row and row.share.shown and row.share.enabled)
  check("share: no right-hand text under the button", row and not row.right.shown)
  row.share:Click()
  check("share: pushed the right quest by log index", a.pushed[1] == 101, a.pushed[1])
  check("share: your quest log selection untouched", a.selected == 103, a.selected)
  check("share: wording says asked", a.printedMatch("asked the game to share .*Wolves"))
  row.share:Hover()
  check("share: button tooltip", a.tooltip[2] and a.tooltip[2]:find("Asks the game"), a.tooltip[2])
  local ok, why = a.ns.ShareQuest(102)
  check("share: unshareable refused with reason", ok == false and why:find("get it themselves"), why)
  a.slash("share 999")
  check("share: unknown quest refused", a.printedMatch("can't share.*isn't in your quest log"))
  a.slash("share abc")
  check("share: bad argument explained", a.printedMatch("usage: /dq share"))
  a.pushFails = true
  a.slash("share 101")
  check("share: game refusal reported", a.printedMatch("the game refused"))
  a.pushFails = false
  -- Out of range: button off, command refuses.
  a.inRange.party1 = false
  a.fire("UNIT_IN_RANGE_UPDATE", "party1", false)
  a.tick(2)
  row = a.rowFor("Wolves Across")
  check("share: disabled when too far", row and row.share.shown and not row.share.enabled)
  local before = #a.pushed
  row.share:Click()
  a.slash("share 101")
  check("share: nothing pushed when too far", #a.pushed == before and a.printedMatch("too far away"))
  noErrors(a, "share") noErrors(b, "share B")
end

-- 8. /dq share walks through the list, oldest-shared first, even as it shrinks
do
  local a, b = Duo(function(a)
    for i, t in ipairs({ "Alpha", "Bravo", "Charlie" }) do
      a.addQuest({ id = 500 + i, title = t, objs = { { label = "o", have = 0, need = 1 } } }, true)
    end
  end, nil)
  a.slash("share") a.slash("share") a.slash("share")
  check("share next: three different quests", a.pushed[1] == 501 and a.pushed[2] == 502 and a.pushed[3] == 503,
    table.concat(a.pushed, ","))
  b.addQuest({ id = 501, title = "Alpha" })  -- Mirel accepted Alpha
  H.run({ a, b }, 10)
  a.slash("share")
  check("share next: skips what they took, oldest first", a.pushed[4] == 502, a.pushed[4])
  check("share next: says how many remain", a.printedMatch("1 more: press again %(or /dq share%)"))
  -- A finished quest can still be shared if the game allows it.
  a.addQuest({ id = 510, title = "Delivery" })  -- no objectives: complete at once
  H.run({ a, b }, 10)
  a.tick(2)
  check("share: complete quest still has Share", a.windowText():find("Delivery || %[Share%]"), a.windowText())
  a.addQuest({ id = 511, title = "Escort", failed = true, objs = { { label = "e", have = 0, need = 1 } } })
  H.run({ a, b }, 10)
  a.tick(2)
  check("share: failed quest shows failed", a.windowText():find("Escort || yours failed"), a.windowText())
  local ok = a.ns.ShareQuest(511)
  check("share: failed quest refused", ok == false)
  noErrors(a, "sharenext")
end

-- 9. Leave warnings: only gaps picked up at this hub, each once
do
  local a, b = Standard()
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("warn: gaps of unknown age (there at login) warn once", a.printedMatch("Before you fly", before + 1)
    and a.printedMatch("Wolves Across", before + 1) and a.printedMatch("Brotherhood", before + 1))
  before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("warn: ...and only once", not a.printedMatch("Before you", before + 1))
  FreshGaps(a, b)
  before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("warn: flight map warns", a.printedMatch("Before you fly", before + 1))
  check("warn: lists what Mirel lacks", a.printedMatch("Mirel doesn't have: .*Fresh Shareable.*you can share it", before + 1))
  check("warn: giver-only quest", a.printedMatch("Fresh Giver Only.*can't be shared", before + 1))
  check("warn: lists what you lack", a.printedMatch("You don't have: .*Mirel's Fresh One.*Mirel can share it", before + 1))
  check("warn: old gaps not included", not a.printedMatch("Wolves Across", before + 1))
  check("warn: center text", a.errorsFrame[#a.errorsFrame] and a.errorsFrame[#a.errorsFrame]:find("missing 3 quests"),
    a.errorsFrame[#a.errorsFrame])
  check("warn: the quest-log sound (not a whisper's)", a.sounds[#a.sounds] == 875, a.sounds[#a.sounds])
  before = #a.printed
  a.fire("TAXIMAP_OPENED")
  a.fire("UNIT_SPELLCAST_START", "player", "Cast-1", 8690)
  check("warn: each gap once", not a.printedMatch("Before you", before + 1))
  a.addQuest({ id = 204, title = "Another Fresh" })
  H.run({ a, b }, 10)
  a.fire("UNIT_SPELLCAST_START", "player", "Cast-2", 8690)
  check("warn: hearth warns about the new gap", a.printedMatch("Before you hearth", before + 1)
    and a.printedMatch("Another Fresh", before + 1))
  check("warn: and only the new gap", not a.printedMatch("Fresh Shareable", before + 1))
  noErrors(a, "warn")
end

-- 10. Leave triggers: details
do
  local a, b = Standard()
  a.fire("TAXIMAP_OPENED")  -- (the gaps of unknown age from login)
  -- Walking off: the hub is where you rested or handled quests.
  a.subzone = "Goldshire"
  FreshGaps(a, b)  -- accepted in Goldshire
  local before = #a.printed
  a.subzone = "Lion's Pride Inn"
  a.resting = true a.fire("PLAYER_UPDATE_RESTING")  -- the inn is part of the hub too
  H.run({ a, b }, 40)
  a.resting = false a.fire("PLAYER_UPDATE_RESTING")
  a.subzone = "Goldshire"
  H.run({ a, b }, 40)
  check("hub: moving around the hub doesn't warn", not a.printedMatch("Leaving", before + 1))
  a.subzone = "Elwynn Forest"
  H.run({ a, b }, 20)
  a.subzone = "Goldshire"
  H.run({ a, b }, 20)
  check("hub: a short walk out and back doesn't warn", not a.printedMatch("Leaving", before + 1))
  a.dead = true
  a.subzone = "Fargodeep Mine"
  H.run({ a, b }, 40)
  check("hub: not while dead", not a.printedMatch("Leaving", before + 1))
  a.dead = false
  a.subzone = "Goldshire"
  H.run({ a, b }, 2)
  a.subzone = "Fargodeep Mine"
  H.run({ a, b }, 27)
  check("hub: not before 15s away", not a.printedMatch("Leaving", before + 1))
  H.run({ a, b }, 4)
  check("hub: walking away warns after 15s", a.printedMatch("Leaving Goldshire:", before + 1)
    and a.printedMatch("Fresh Shareable", before + 1))
  a.subzone = "Stormwind City"
  a.resting = true
  a.addQuest({ id = 299, title = "City Quest" })
  H.run({ a, b }, 10)
  before = #a.printed
  a.subzone = "Old Town"  -- another district of the same city: still resting
  H.run({ a, b }, 40)
  check("hub: districts of a city aren't leaving", not a.printedMatch("Leaving", before + 1))
  a.resting = false
  a.subzone = "Goldshire"
  -- Other casts, and other units' casts, don't count.
  a.addQuest({ id = 205, title = "Gap Five" })
  H.run({ a, b }, 10)
  before = #a.printed
  a.fire("UNIT_SPELLCAST_START", "player", "Cast-3", 133)
  a.fire("UNIT_SPELLCAST_START", "party1", "Cast-4", 8690)
  check("hearth: other spells and other units ignored", not a.printedMatch("Before you", before + 1))
  -- The interaction-manager signal for flight masters (and not for merchants).
  a.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 5)
  check("flight: merchant window ignored", not a.printedMatch("Before you", before + 1))
  a.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 6)
  check("flight: taxi interaction warns", a.printedMatch("Before you fly", before + 1))
  -- In combat the warning waits for the fight to end.
  a.addQuest({ id = 206, title = "Gap Six" })
  H.run({ a, b }, 10)
  before = #a.printed
  a.combat = true
  a.fire("UNIT_SPELLCAST_START", "player", "Cast-5", 8690)
  check("combat: held", not a.printedMatch("Before you", before + 1))
  a.combat = false
  a.fire("PLAYER_REGEN_ENABLED")
  check("combat: shown after the fight", a.printedMatch("Before you hearth", before + 1))
  a.addQuest({ id = 207, title = "Gap Seven" })
  H.run({ a, b }, 10)
  before = #a.printed
  a.combat = true
  a.fire("TAXIMAP_OPENED")
  H.run({ a, b }, 80)
  a.combat = false
  a.fire("PLAYER_REGEN_ENABLED")
  check("combat: still shown after a long fight", a.printedMatch("Before you fly", before + 1))
  -- Walked off, fought, and fought your way back into town: not leaving.
  a.addQuest({ id = 2071, title = "Came Back" })
  H.run({ a, b }, 10)
  before = #a.printed
  a.subzone = "Elwynn Forest"
  a.combat = true
  H.run({ a, b }, 32)
  a.subzone = "Goldshire"
  a.combat = false
  a.fire("PLAYER_REGEN_ENABLED")
  check("combat: back at the hub after the fight, no warning", not a.printedMatch("Leaving", before + 1))
  a.fire("TAXIMAP_OPENED")
  check("combat: ...and it's still the same hub", a.printedMatch("Before you fly.*", before + 1)
    and a.printedMatch("Came Back", before + 1))
  -- New zone: last-chance note, and a fresh start for the new place.
  a.addQuest({ id = 2072, title = "Zone Gap" })
  H.run({ a, b }, 10)
  a.zone = "Westfall"
  a.fire("ZONE_CHANGED_NEW_AREA")
  check("zone: left-zone note", a.printedMatch("You left Elwynn Forest", before + 1))
  -- Landing from a flight is arriving somewhere new.
  a.addQuest({ id = 208, title = "Before Flight" })
  H.run({ a, b }, 10)
  a.onTaxi = true a.tick(4) a.onTaxi = false a.tick(4)
  before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("flight: the flight master on arrival doesn't warn", not a.printedMatch("Before you", before + 1))
  -- Ignore list and the off switch.
  a.addQuest({ id = 209, title = "Ignored Class Quest", pushable = false })
  H.run({ a, b }, 10)
  a.slash("ignore 209")
  a.fire("TAXIMAP_OPENED")
  check("ignore: ignored quests don't warn", not a.printedMatch("Before you", before + 1))
  a.slash("ignore 209")
  a.slash("warn off")
  a.fire("TAXIMAP_OPENED")
  check("warn off: silent", not a.printedMatch("Before you", before + 1))
  noErrors(a, "triggers")
end

-- 11. Warnings only for your duo partner
do
  local a = H.boot()
  a.addQuest({ id = 101, title = "Mine Only" }, true)
  a.addQuest({ id = 103, title = "Both" }, true)
  a.login()
  a.unitOnQuest.party1 = { [103] = true }
  a.setGroup({ "Bob" })
  a.tick(4)
  check("no-addon: waiting at first", a.statusText():find("Waiting for Bob's DuoQuest"), a.statusText())
  a.tick(40)
  local text = a.windowText()
  check("no-addon: may-not-have section", text:find("Bob may not have %(1%)") and text:find("Mine Only"), text)
  check("no-addon: both section (no partner column)", text:find("Both on %(1%)"), text)
  check("no-addon: status explains", a.statusText():find("doesn't run DuoQuest"), a.statusText())
  a.addQuest({ id = 105, title = "Fresh For Bob" })
  a.tick(10)
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("stranger: no warning for a random groupmate", not a.printedMatch("Before you", before + 1))
  a.slash("partner bob")
  a.fire("TAXIMAP_OPENED")
  check("chosen: warning uses may-not-have", a.printedMatch("Bob may not have: .*Fresh For Bob", before + 1))
  noErrors(a, "noaddon")
end

-- 12. No gaps: no warning, no notes when you both accept together
do
  local a, b = Duo(function(a) a.addQuest({ id = 7, title = "Same" }, true) end,
    function(b) b.addQuest({ id = 7, title = "Same" }, true) end)
  a.addQuest({ id = 8, title = "Both Took It" })
  H.run({ a, b }, 2)
  b.addQuest({ id = 8, title = "Both Took It" })
  H.run({ a, b }, 20)
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("no gaps: no warning", not a.printedMatch("Before you", before + 1))
  a.slash("status")
  check("no gaps: status says so", a.printedMatch("no gaps"))
  check("no gaps: quiet", not a.printedMatch("doesn't have") and not b.printedMatch("doesn't have")
    and not a.printedMatch("picked up") and not b.printedMatch("picked up"))
  noErrors(a, "nogaps") noErrors(b, "nogaps B")
end

-- 13. Quests one of you already turned in
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 101, title = "Wolves" }, true)
    a.completed[202] = true
  end, function(b)
    b.completed[101] = true
    b.addQuest({ id = 202, title = "Theirs" }, true)
  end)
  H.run({ a, b }, 20)
  a.tick(2)
  local view = a.ns.Compare(a.ns.FocusPartner())
  check("done: not in theyNeed", #view.theyNeed == 0, #view.theyNeed)
  check("done: in theyDid", #view.theyDid == 1)
  check("done: my turned-in quest not in iNeed", #view.iNeed == 0 and #view.iDid == 1)
  local text = a.windowText()
  check("done: collapsed sections by default", text:find("%+ Mirel already turned in %(1%)")
    and text:find("%+ You already turned in %(1%)") and not text:find("Wolves ||"), text)
  a.rowFor("Mirel already turned in"):Click()
  a.tick(2)
  check("done: expands to list them", a.windowText():find("Wolves ||"), a.windowText())
  noErrors(a, "done")
end

-- 14. Turning in: the partner knows at once (even if the done-list is lost)
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 300, title = "Shared", objs = { { label = "x", have = 1, need = 1 } } }, true)
    a.addQuest({ id = 301, title = "Only Mine", objs = { { label = "x", have = 1, need = 1 } } }, true)
  end, function(b)
    b.addQuest({ id = 300, title = "Shared", objs = { { label = "x", have = 0, need = 1 } } }, true)
  end)
  b.dropFrom = function(m) return m.msg:find("^2|C|") ~= nil end
  a.removeQuest(301, true, true)  -- the game's completed flag lags behind the event
  a.removeQuest(300, true, true)
  H.run({ a, b }, 6)
  local view = b.ns.Compare(b.ns.FocusPartner())
  check("turn-in: partner doesn't list it as both", #view.both == 0)
  check("turn-in: no false gap", #view.iNeed == 0 and #view.theyNeed == 0, #view.theyNeed)
  check("turn-in: partner knows it's done", b.ns.partners.Tavlius.done[300] == true)
  noErrors(b, "turnin")
end

-- 15. Notes: delayed, re-checked, and once
do
  local a, b = Standard()
  a.distance.party1 = 500  -- (apart: when you're at the same hub, pickup notes stay quiet)
  local before = #a.printed
  b.addQuest({ id = 105, title = "The Fargodeep Mine" })
  H.run({ a, b }, 4)
  check("notify: waits a moment", not a.printedMatch("Fargodeep", before + 1))
  H.run({ a, b }, 12)
  check("notify: partner pickup noted", a.printedMatch("Mirel picked up .*Fargodeep Mine.*Mirel can share it", before + 1))
  before = #a.printed
  b.addQuest({ id = 109, title = "Picked And Dropped" })
  H.run({ a, b }, 4)
  b.removeQuest(109)
  H.run({ a, b }, 16)
  check("notify: re-checked before printing", not a.printedMatch("picked up", before + 1))
  a.addQuest({ id = 106, title = "Princess Must Die", objs = { { label = "p", have = 0, need = 1 } } })
  H.run({ a, b }, 16)
  check("notify: my pickup partner lacks", a.printedMatch("Mirel doesn't have .*Princess Must Die.*/dq share", before + 1))
  a.addQuest({ id = 107, title = "Unshareable", pushable = false })
  H.run({ a, b }, 16)
  check("notify: unshareable pickup", a.printedMatch("Unshareable.*can't be shared"))
  -- Apart, but you both accept the same quest a moment apart: no notes either way.
  before = #a.printed
  local bBefore = #b.printed
  b.distance.party1 = 500
  a.addQuest({ id = 108, title = "Together Apart" })
  H.run({ a, b }, 2)
  b.addQuest({ id = 108, title = "Together Apart" })
  H.run({ a, b }, 16)
  check("notify: accepting at the same time is quiet", not a.printedMatch("Together Apart", before + 1)
    and not b.printedMatch("Together Apart", bBefore + 1))
  before = #a.printed
  a.addQuest({ id = 104, title = "Brotherhood of Thieves", objs = { { label = "Red Burlap Bandana", have = 3, need = 12 } } })
  H.run({ a, b }, 16)
  b.progress(104, 1, 12)
  H.run({ a, b }, 16)
  check("notify: partner finished a shared quest",
    a.printedMatch("Mirel finished .*Brotherhood.*You: Red Burlap Bandana 3/12", before + 1))
  before = #a.printed
  a.completed[1105] = true
  b.addQuest({ id = 1105, title = "Silent" })
  H.run({ a, b }, 16)
  check("notify: not for quests I've done", not a.printedMatch("Silent", before + 1))
  a.slash("ignore 2001")
  b.addQuest({ id = 2001, title = "Ignored One" })
  H.run({ a, b }, 16)
  check("notify: not for ignored quests", not a.printedMatch("Mirel picked up .*Ignored One"))
  a.distance.party1 = nil  -- together again
  b.addQuest({ id = 2002, title = "Right Here" })
  a.addQuest({ id = 2003, title = "Mine Right Here" })
  H.run({ a, b }, 16)
  check("notify: quiet while together", not a.printedMatch("Right Here"))
  a.distance.party1 = 500
  b.addQuest({ id = 2005, title = "Picked Twice" })
  H.run({ a, b }, 16)
  b.removeQuest(2005)  -- noted; dropped and picked up again a moment later: no second note
  H.run({ a, b }, 6)
  b.addQuest({ id = 2005, title = "Picked Twice" })
  H.run({ a, b }, 16)
  check("notify: once for a quick re-pickup", a.printedCount("Mirel picked up .*Picked Twice") == 1,
    a.printedCount("Mirel picked up .*Picked Twice"))
  b.removeQuest(2005)  -- ...but picked up again minutes later (a repeatable): noted again
  H.run({ a, b }, 140)
  b.addQuest({ id = 2005, title = "Picked Twice" })
  H.run({ a, b }, 16)
  check("notify: again for a later re-pickup", a.printedCount("Mirel picked up .*Picked Twice") == 2,
    a.printedCount("Mirel picked up .*Picked Twice"))
  a.slash("notify off")
  b.addQuest({ id = 2000, title = "Quiet Please" })
  H.run({ a, b }, 16)
  check("notify: can be turned off", not a.printedMatch("Quiet Please"))
  noErrors(a, "notify") noErrors(b, "notify B")
end

-- 16. Abandoning and leaving the group
do
  local a, b = Standard()
  b.removeQuest(104)
  H.run({ a, b }, 6)
  check("abandon: gone from partner list", not a.ns.partners.Mirel.list[104])
  check("abandon: not marked done", not a.ns.partners.Mirel.done[104])
  a.addQuest({ id = 998, title = "Queued" })
  a.setGroup({})
  a.tick(2)
  check("leave: partner forgotten", a.ns.partners.Mirel == nil)
  check("leave: queue cleared", a.realNs.channel:Queued() == 0)
  check("leave: window hidden", not a.ui.shown)
  local sent = #a.addonSent
  a.addQuest({ id = 999, title = "Solo" })
  a.tick(130)
  check("leave: nothing sent while solo (no heartbeat)", #a.addonSent == sent)
  noErrors(a, "leave")
end

-- 17. Versions, echoes, strangers and junk
do
  local a, b = Standard()
  a.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "3|H|9.0|abc|0", "PARTY", "Newer-Realm")
  a.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "3|H|9.0|abc|0", "PARTY", "Newer-Realm")
  check("protocol: newer noticed once", a.printedCount("Newer runs a newer DuoQuest") == 1)
  check("protocol: says who should update", a.printedMatch("You should update"))
  check("protocol: newer not a partner", a.ns.partners.Newer == nil)
  b.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|H|1.9.0|zz9|1", "PARTY", "Mirel-Realm")
  check("echo: own name ignored", b.ns.partners.Mirel == nil)
  a.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|H|1.10.0|q1|1", "PARTY", "Mirel-Realm")
  check("version: newer app version noted", a.printedMatch("Mirel has DuoQuest 1.10.0 and you have"))
  a.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|H|1.10.0|q2|1", "PARTY", "Mirel-Realm")
  check("version: noted once", a.printedCount("Mirel has DuoQuest") == 1)
  a.tick(40)  -- (answering those hellos)
  local sent = #a.addonSent
  a.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|D|zz|0", "WHISPER", "Stranger-Realm")
  a.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|U|2t|0|1|Hi|", "GUILD", "Stranger-Realm")
  a.tick(4)
  check("stranger: other channels ignored", a.ns.partners.Stranger == nil and #a.addonSent == sent)
  local p = a.ns.partners.Mirel
  for _, junk in ipairs({ "", "garbage", "2|", "2|U", "2|Ujunk", "2|U|zz~|x|y", "2|U|!!|1|1|t|",
      "2|L|1|5|2|abc", "2|L|x|y|z|", "2|L|1|1.5|2|aa.0.0", "2|C|1|1|1|,,,", "2|N", "2|Z|what",
      "2|U|" .. string.rep("z", 20) .. "|1|1|t|", "2|U|9x|99|1|Bad flags|", "2|U|9y|1|1e9|Bad level|",
      "2|U|9z|0x1|1|Hex flags|", "2|U|a1|1|1|Too|many|fields", "2|D", "2|D|!!|1" }) do
    a.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", junk, "PARTY", "Mirel-Realm")
  end
  check("junk: bad flags rejected", p.list[a.ns.From36("9x")] == nil)
  check("junk: bad level / hex rejected", p.list[a.ns.From36("9y")] == nil and p.list[a.ns.From36("9z")] == nil)
  check("junk: extra fields rejected", p.list[a.ns.From36("a1")] == nil)
  check("junk: partner data intact", p.quests[104] ~= nil and p.quests[103] ~= nil)
  local n = 0
  for _ in pairs(p.list) do n = n + 1 end
  check("junk: nothing else got in", n == 2, n)
  noErrors(a, "junk") noErrors(b, "junk B")
end

-- 18. Big quest logs stay inside the message limits and the client's throttle
do
  local long = string.rep("Long Title With Words ", 6)
  local a, b = Duo(function(a)
    for i = 1, 35 do
      local objs = {}
      for j = 1, 6 do objs[j] = { label = "A rather long objective description number " .. j, have = j, need = 20 } end
      a.addQuest({ id = 20000 + i * 37, title = long .. i, objs = objs }, true)
    end
  end, function(b) b.addQuest({ id = 5, title = "Small" }, true) end)
  H.run({ a, b }, 120)
  local p = b.ns.partners.Tavlius
  local n, list = 0, 0
  for _ in pairs(p.quests) do n = n + 1 end
  for _ in pairs(p.list) do list = list + 1 end
  check("big: every quest arrived", n == 35, n)
  check("big: list complete", list == 35, list)
  local q = p.quests[20000 + 37]
  check("big: objectives and numbers kept", q and #q.objs == 6 and q.objs[3].have == 3 and q.objs[3].need == 20)
  check("big: long titles cut to 48 bytes", q and #q.title == 48, q and #q.title)
  local maxLen = 0
  for _, m in ipairs(a.addonSent) do maxLen = math.max(maxLen, #m.msg) end
  check("big: all messages <= 255 bytes", maxLen <= 255, maxLen)
  check("big: the client never throttled us", a.throttled == 0, a.throttled)
  check("big: no detail requests needed", b.sentMatching("^2|N|") == 0, b.sentMatching("^2|N|"))
  noErrors(a, "big") noErrors(b, "big B")
end

-- 19. Lost messages heal
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 1, title = "One", objs = { { label = "o", have = 0, need = 5 } } }, true)
  end, function(b) b.addQuest({ id = 5, title = "Five" }, true) end)
  local dropped = 0
  b.dropFrom = function(m)
    if m.msg:find("^2|U|") and dropped == 0 then dropped = dropped + 1 return true end
    return false
  end
  a.addQuest({ id = 2, title = "Two" })
  H.run({ a, b }, 4)
  check("lost pickup: details missing at first", b.ns.partners.Tavlius.quests[2] == nil)
  b.dropFrom = nil
  H.run({ a, b }, 140)
  check("lost pickup: list heals by heartbeat", b.ns.partners.Tavlius.list[2] ~= nil)
  check("lost pickup: details recovered", b.ns.partners.Tavlius.quests[2] and b.ns.partners.Tavlius.quests[2].title == "Two")
  -- A lost progress update: the heartbeat checksum catches it.
  b.dropFrom = function(m) return m.msg:find("^2|U|1|") ~= nil end
  a.progress(1, 1, 3)
  H.run({ a, b }, 4)
  check("lost progress: stale at first", b.ns.partners.Tavlius.quests[1].objs[1].have == 0)
  b.dropFrom = nil
  H.run({ a, b }, 150)
  check("lost progress: healed", b.ns.partners.Tavlius.quests[1].objs[1].have == 3,
    b.ns.partners.Tavlius.quests[1].objs[1].have)
  -- A lost removal heals too.
  b.dropFrom = function(m) return m.msg:find("^2|D|") ~= nil end
  a.removeQuest(1)
  H.run({ a, b }, 4)
  b.dropFrom = nil
  H.run({ a, b }, 130)
  check("lost removal: heals", b.ns.partners.Tavlius.list[1] == nil and b.ns.partners.Tavlius.quests[1] == nil)
  -- Details that never come: asked for with growing gaps, not every few seconds.
  local asked = b.sentMatching("^2|N|")
  b.dropFrom = function(m) return m.msg:find("^2|U|3|") ~= nil end  -- Three's details always lost
  a.addQuest({ id = 3, title = "Three" })
  H.run({ a, b }, 1200)  -- 10 minutes
  local n = b.sentMatching("^2|N|") - asked
  check("missing details: asked for, with backoff", n >= 3 and n <= 8, n)
  check("missing details: still listed", b.ns.partners.Tavlius.list[3] ~= nil and b.ns.partners.Tavlius.quests[3] == nil)
  noErrors(a, "lost") noErrors(b, "lost B")
end

-- 20. Refused sends: retried with backoff; a message refused forever is dropped
do
  local a, b = Duo(nil, nil)
  a.addonResult = 9
  a.addQuest({ id = 77, title = "Retry Me" })
  H.run({ a, b }, 10)
  check("refused: not delivered yet", b.ns.partners.Tavlius.quests[77] == nil)
  a.addonResult = 0
  H.run({ a, b }, 40)
  check("refused: delivered after", b.ns.partners.Tavlius.quests[77] ~= nil)
  a.addonResult = 9
  a.addQuest({ id = 78, title = "Stuck" })
  H.run({ a, b }, 600)
  check("refused forever: dropped, queue moves on", a.realNs.channel.dropped >= 1 and a.realNs.channel:Queued() <= 2,
    a.realNs.channel:Queued())
  a.addonResult = 0
  H.run({ a, b }, 150)
  check("refused forever: healed later", b.ns.partners.Tavlius.quests[78] ~= nil)
  noErrors(a, "refused")
end

-- 21. Classic quest API
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 41, title = "Classic One", objs = { { label = "Boars", have = 3, need = 8 } } }, true)
  end, function(b) b.addQuest({ id = 42, title = "Modern" }, true) end, { name = "Tavlius", classic = true })
  check("classic: scanned", a.ns.mine[41] and a.ns.mine[41].objs[1].have == 3 and a.ns.mine[41].objs[1].label == "Boars")
  check("classic: share unknown flagged", a.ns.HasFlag(a.ns.mine[41].flags, a.realNs.F_SHARE_UNKNOWN))
  local q = b.ns.partners.Tavlius and b.ns.partners.Tavlius.quests[41]
  check("classic: synced", q and q.title == "Classic One")
  a.selectedIndex = 0
  a.slash("share 41")
  check("classic: share via index", a.pushed[1] == 41, a.pushed[1])
  check("classic: selection restored", a.selectedIndex == 0, a.selectedIndex)
  noErrors(a, "classic") noErrors(b, "classic B")
end

-- 22. Secret values (they keep their Lua type, like the real client)
do
  local a, b = Standard()
  -- Group names unreadable for a moment: nobody is "removed".
  a.secrets.members = true
  a.secretType = "string"
  a.fire("GROUP_ROSTER_UPDATE")
  a.tick(2)
  check("secret roster: partner kept", a.ns.partners.Mirel ~= nil)
  a.secrets.members = nil
  a.tick(6)
  check("secret roster: still synced afterwards", a.ns.partners.Mirel and a.ns.partners.Mirel.synced)
  -- The quest count unreadable: no quest is "dropped", and it re-reads later.
  local sent = #a.addonSent
  a.secrets.log = true
  a.secretType = "number"
  a.progress(103, 1, 7)
  H.run({ a, b }, 6)
  check("secret log: no removals sent", a.sentMatching("^2|D|", sent + 1) == 0)
  check("secret log: quests kept", a.ns.mine[101] ~= nil and a.ns.mine[103] ~= nil)
  a.secrets.log = nil
  H.run({ a, b }, 6)
  check("secret log: re-read once readable", b.ns.partners.Tavlius.quests[103].objs[1].have == 7)
  -- Resting flag unreadable: no crash.
  a.secrets.resting = true
  a.secretType = "boolean"
  a.fire("PLAYER_UPDATE_RESTING")
  a.tick(20)
  a.secrets.resting = nil
  -- Event arguments that are secret.
  a.secretType = "string"
  a.fire("CHAT_MSG_ADDON", H.SECRET, H.SECRET, "PARTY", H.SECRET)
  a.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", H.SECRET, "PARTY", "Mirel-Realm")
  a.fire("UNIT_SPELLCAST_START", "player", H.SECRET, H.SECRET)
  a.fire("ADDON_LOADED", H.SECRET)
  a.fire("UNIT_QUEST_LOG_CHANGED", H.SECRET)
  a.secretType = "number"
  a.fire("QUEST_ACCEPTED", H.SECRET)
  a.fire("QUEST_TURNED_IN", H.SECRET, H.SECRET, H.SECRET)
  a.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", H.SECRET)
  a.tick(10)
  noErrors(a, "secret")
  -- Your own name unreadable at login: still never mistake your echo for a partner.
  local c = H.boot({ name = "Tavlius", secrets = { player = true }, secretType = "string" })
  c.login()
  c.secrets.player = nil
  c.setGroup({ "Mirel" })
  c.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|U|2t|0|1|Echo|", "PARTY", "Tavlius-Realm")
  check("secret name: echo still ignored", c.ns.partners.Tavlius == nil)
  noErrors(c, "secret name")
end

-- 23. Sync off/on
do
  local a, b = Standard()
  a.bucket = 0  -- the client is throttling right now: "bye" must still get through
  a.slash("sync")
  H.run({ a, b }, 10)
  check("sync off: setting saved", a.ns.DB.sync == false)
  check("sync off: partner drops us (bye retried)", b.ns.partners.Tavlius == nil)
  check("sync off: we drop them", next(a.ns.partners) == nil)
  local sent = #a.addonSent
  a.addQuest({ id = 555, title = "Private" })
  H.run({ a, b }, 140)
  check("sync off: nothing sent", #a.addonSent == sent)
  check("sync off: incoming ignored", next(a.ns.partners) == nil)
  a.tick(2)
  check("sync off: status says so", a.statusText():find("Sync is off"), a.statusText())
  a.slash("sync on")
  H.run({ a, b }, 40)
  check("sync on: synced again", a.ns.partners.Mirel and a.ns.partners.Mirel.synced
    and b.ns.partners.Tavlius and b.ns.partners.Tavlius.quests[555] ~= nil)
  a.slash("sync on")
  check("sync: already on", a.printedMatch("already on"))
  noErrors(a, "syncoff") noErrors(b, "syncoff B")
end

-- 24. Settings survive a reload
do
  local a = Standard()
  a.slash("partner mirel")
  a.slash("objectives off")
  a.slash("lock")
  a.slash("ignore 104")
  local a2 = H.boot({ name = "Tavlius", saved = a.saved() })
  a2.login()
  check("saved: focus", a2.ns.DB.focus == "Mirel")
  check("saved: toggles", a2.ns.DB.objectives == false and a2.ns.DB.locked == true)
  check("saved: ignore list", a2.ns.DB.ignored[104] == true)
  local old = H.boot({ name = "Tavlius", saved = { version = 1, point = { "CENTER", "CENTER", 1, 2 }, shown = false } })
  old.login()
  check("migration: v1 center point replaced", old.ns.DB.point[1] == "TOPLEFT" and old.ns.DB.shown == false)
  noErrors(a2, "saved")
end

-- 25. Collapsed quest-log headers don't look like dropped quests
do
  local a, b = Duo(function(a)
    a.log[#a.log + 1] = { header = "Elwynn Forest" }
    a.addQuest({ id = 11, title = "Under Elwynn", objs = { { label = "w", have = 0, need = 4 } } }, true)
    a.log[#a.log + 1] = { header = "Westfall" }
    a.addQuest({ id = 12, title = "Under Westfall" }, true)
  end, nil)
  local sent = #a.addonSent
  a.collapsed["Elwynn Forest"] = true
  a.fire("QUEST_LOG_UPDATE")
  H.run({ a, b }, 10)
  check("collapsed: no removal sent", a.sentMatching("^2|D|", sent + 1) == 0)
  check("collapsed: partner still sees it", b.ns.partners.Tavlius.list[11] ~= nil)
  a.progress(11, 1, 2)
  H.run({ a, b }, 6)
  check("collapsed: progress still read", b.ns.partners.Tavlius.quests[11].objs[1].have == 2)
  -- Accepted while its header is collapsed.
  table.insert(a.log, 2, { id = 13, title = "Hidden New", objs = {}, level = 5 })
  a.fire("QUEST_ACCEPTED", 13)
  a.fire("QUEST_LOG_UPDATE")
  H.run({ a, b }, 6)
  check("collapsed: new quest found by its accept event", a.ns.mine[13] ~= nil and b.ns.partners.Tavlius.list[13] ~= nil)
  -- And after a reload with the header still collapsed.
  local a2 = H.boot({ name = "Tavlius", saved = a.saved() })
  a2.log, a2.collapsed = a.log, a.collapsed
  a2.login()
  check("collapsed: remembered across a reload", a2.ns.mine[11] ~= nil and a2.ns.mine[13] ~= nil)
  noErrors(a, "collapsed") noErrors(a2, "collapsed reload")
end

-- 26. Multi-part lists
do
  local c = H.boot()
  c.login()
  c.setGroup({ "Mirel" })
  c.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|L|7|2|2|1c.4.aa", "PARTY", "Mirel")
  check("parts: incomplete list not applied", not (c.ns.partners.Mirel and c.ns.partners.Mirel.synced))
  c.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|L|7|1|2|1a.0.aa,1b.1.bb", "PARTY", "Mirel")
  local p = c.ns.partners.Mirel
  check("parts: assembled out of order", p.synced and p.list[46] == 0 and p.list[47] == 1 and p.list[48] == 4)
  c.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|L|8|1|2|1a.0.aa", "PARTY", "Mirel")
  c.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|L|9|2|2|zz.0.aa", "PARTY", "Mirel")
  c.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|L|9|1|2|", "PARTY", "Mirel")
  check("parts: a newer list replaces mixed halves", p.list[1295] == 0 and not p.list[46])
  c.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|L|11|1|3|1a.0.aa", "PARTY", "Mirel")
  c.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|L|11|1|1|1d.0.aa", "PARTY", "Mirel")
  check("parts: a changed total starts over", p.list[49] == 0 and not p.list[1295])
  c.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|L|12|1|1|", "PARTY", "Mirel")
  check("parts: empty list clears", next(p.list) == nil)
  noErrors(c, "parts")
end

-- 27. Encoding: round trip, odd characters, progress bars, truncation
do
  local c = H.boot()
  c.login()
  local ns = c.ns
  check("base36", ns.To36(26180) == "k78" and ns.From36("k78") == 26180 and ns.To36(0) == "0"
    and ns.From36(ns.To36(999999)) == 999999)
  check("base36 rejects junk", ns.From36("K78") == nil and ns.From36("") == nil and ns.From36(nil) == nil)
  local rec = { id = 12345, flags = 5, level = 12, title = ns.Clean("Pipes | tildes ~ and ^carets|cffff0000red|r"),
    objs = { { label = ns.ObjectiveLabel("3/8 Wolf Meat"), have = 3, need = 8, done = false },
             { label = ns.ObjectiveLabel("Defias slain: 10/10"), have = 10, need = 10, done = true },
             { label = ns.ObjectiveLabel("Research (45%)"), have = 45, need = 100, done = false, bar = true } } }
  local body = ns.EncodeQuest(rec)
  check("encode: no stray separators in title", not rec.title:find("[|~^]"), rec.title)
  local fields = {}
  for f in (body:sub(3) .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = f end
  local back = ns.DecodeQuest(fields)
  check("decode: id/flags/level", back and back.id == 12345 and back.flags == 5 and back.level == 12)
  check("decode: labels without numbers", back and back.objs[1].label == "Wolf Meat"
    and back.objs[2].label == "Defias slain" and back.objs[3].label == "Research", back and back.objs[3].label)
  check("decode: done flags", back and back.objs[2].done and not back.objs[1].done)
  check("decode: progress bar", back and back.objs[3].bar and ns.ObjText(back.objs[3]) == "45%",
    back and ns.ObjText(back.objs[3]))
  check("encode: same body after a round trip (checksums agree)", ns.EncodeQuest(back) == body)
  local utf = ns.Truncate("Ãéíóú", 3)
  check("truncate keeps whole UTF-8 characters", utf == "Ã", utf)
  check("join list", ns.JoinList({ "a", "b", "c" }) == "a, b and c" and ns.JoinList({ "a" }) == "a"
    and ns.JoinList({ "a", "b", "c", "d" }, 2) == "a, b and 2 more")
  local V = c.realNs.DuoCore.NewerVersion
  check("version compare", V("1.10.0", "1.9.2") and not V("1.1", "1.1.0") and not V("1.0.9", "1.1"))
  noErrors(c, "encode")
end

-- 28. Progress bars from the game
do
  local a = Duo(function(a)
    a.addQuest({ id = 61, title = "Bar Quest", barPct = 45, objs = { { label = "Research", have = 0, need = 1,
      type = "progressbar", text = "Research (45%)" } } }, true)
  end, function(b)
    b.addQuest({ id = 61, title = "Bar Quest", barPct = 80, objs = { { label = "Research", have = 0, need = 1,
      type = "progressbar", text = "Research (80%)" } } }, true)
  end)
  a.tick(2)
  check("bar: shown as percent", a.windowText():find("Bar Quest || 45%% | 80%%"), a.windowText())
  noErrors(a, "bar")
end

-- 29. Stale partner
do
  local a, b = Standard()
  FreshGaps(a, b)
  a.tick(400)  -- Mirel goes silent (nothing delivered)
  check("stale: status says so", a.statusText():find("no update for"), a.statusText())
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("stale: no warning from old data", not a.printedMatch("Before you", before + 1))
  H.run({ a, b }, 130)
  check("stale: heartbeat revives", not a.ns.IsStale(a.ns.partners.Mirel))
  noErrors(a, "stale")
end

-- 30. Window interactions
do
  local a, b = Duo(function(a)
    for i = 1, 30 do a.addQuest({ id = 400 + i, title = string.format("Mine %02d", i) }, true) end
  end, function(b)
    for i = 1, 10 do b.addQuest({ id = 600 + i, title = string.format("Theirs %02d", i) }, true) end
  end)
  a.tick(2)
  local info = a.ns.scrollInfo
  check("scroll: limited rows", info.visible == 24 and info.total > 24, info.total)
  check("scroll: says there's more", a.realNs.moreText.text:find("scroll for %d+ more"), a.realNs.moreText.text)
  a.ns.Scroll(-3)
  check("scroll: moves", a.ns.scrollInfo.offset == 9, a.ns.scrollInfo.offset)
  a.ns.Scroll(-100)
  check("scroll: clamps", a.ns.scrollInfo.offset == info.total - 24)
  a.ns.Scroll(100)
  check("scroll: back to top", a.ns.scrollInfo.offset == 0)
  a.realNs.rows[1]:Click()  -- the "Mirel doesn't have" header
  a.tick(2)
  local text = a.windowText()
  check("collapse: header click collapses", text:find("%+ Mirel doesn't have %(30%)") and not text:find("Mine 01"), text)
  a.realNs.rows[1]:Click()
  a.tick(2)
  check("collapse: and expands", a.windowText():find("Mine 01"))
  local row = a.rowFor("Mine 01")
  row:Hover()
  check("tooltip: shows quest", a.tooltip[1] and a.tooltip[1]:find("Mine 01"), a.tooltip[1])
  row:Click("RightButton")
  a.tick(2)
  check("right-click: ignores", a.ns.IsIgnored(401) and a.windowText():find("Mine 01 %(ignored%)"), a.windowText())
  a.rowFor("Mine 01"):Click("RightButton")
  check("right-click: and un-ignores", not a.ns.IsIgnored(401))
  a.ui:Drag(250, 600)
  check("drag: saved by top-left", a.ns.DB.point[1] == "TOPLEFT" and a.ns.DB.point[3] == 250 and a.ns.DB.point[4] == 600,
    table.concat(a.ns.DB.point, ","))
  a.realNs.rows[3]:Drag(300, 500)
  check("drag: works from a row too", a.ns.DB.point[3] == 300)
  local moves = a.ui.moves
  a.slash("lock")
  a.ui:Drag(10, 10)
  check("lock: doesn't start moving while locked", a.ui.moves == moves, a.ui.moves)
  a.realNs.rows[1]:Click("RightButton")
  a.tick(2)
  check("right-click on a header doesn't collapse it", a.windowText():find("%- Mirel doesn't have"), a.windowText())
  a.slash("objectives off")
  a.tick(2)
  noErrors(a, "ui") noErrors(b, "ui B")
end

-- 31. Channels
do
  local c = H.boot()
  c.login()
  local D = c.realNs.DuoCore
  c.inGroup = true
  check("channel: party", D.Distribution() == "PARTY")
  c.inRaid = true
  check("channel: raid", D.Distribution() == "RAID")
  c.inRaid, c.instanceGroup = false, true
  check("channel: instance group preferred", D.Distribution() == "INSTANCE_CHAT")
  c.inGroup = false
  check("channel: instance only", D.Distribution() == "INSTANCE_CHAT")
  c.instanceGroup = false
  check("channel: none solo", D.Distribution() == nil)
  noErrors(c, "channel")
end

-- 32. Three in a group: a steady focus, and addressed requests
do
  local a = H.boot({ name = "Tavlius" })
  local b = H.boot({ name = "Mirel" })
  local d = H.boot({ name = "Dana" })
  a.addQuest({ id = 1, title = "A1" }, true)
  b.addQuest({ id = 2, title = "B2", objs = { { label = "b", have = 0, need = 30 } } }, true)
  d.addQuest({ id = 3, title = "D3", objs = { { label = "d", have = 0, need = 30 } } }, true)
  for _, c in ipairs({ a, b, d }) do c.login() end
  a.setGroup({ "Mirel", "Dana" }) b.setGroup({ "Tavlius", "Dana" }) d.setGroup({ "Tavlius", "Mirel" })
  H.run({ a, b, d }, 40)
  check("trio: both partners synced", a.ns.partners.Mirel and a.ns.partners.Mirel.synced
    and a.ns.partners.Dana and a.ns.partners.Dana.synced)
  local first = a.ns.FocusPartner().key
  local flips = 0
  for i = 1, 20 do
    if i % 2 == 0 then b.progress(2, 1, i) else d.progress(3, 1, i) end
    H.run({ a, b, d }, 6)
    if a.ns.FocusPartner().key ~= first then flips = flips + 1 end
  end
  check("trio: automatic focus doesn't flip", flips == 0 and first == "Dana", first)
  a.slash("partner MIREL")
  a.tick(2)
  check("trio: chosen focus", a.ns.FocusPartner().key == "Mirel" and a.windowText():find("Mirel doesn't have"))
  local sentByDana = #d.addonSent
  d.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|N|Mirel|3", "PARTY", "Tavlius-Realm")
  d.tick(4)
  check("trio: a request for someone else is ignored", d.sentMatching("^2|U|", sentByDana + 1) == 0)
  d.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|N|Dana|3", "PARTY", "Tavlius-Realm")
  d.tick(4)
  check("trio: a request for me is answered", d.sentMatching("^2|U|3|", sentByDana + 1) == 1)
  a.slash("partner auto")
  check("trio: auto focus", a.ns.DB.focus == nil)
  noErrors(a, "trio") noErrors(b, "trio B") noErrors(d, "trio D")
end

-- 33. Cross-realm names
do
  local a = H.boot({ name = "Tavlius", realm = "Other Realm" })
  a.login()
  a.setGroup({ "Mirel" })
  local m = a.realNs.DuoCore.GroupMembers()
  check("realm: member key keeps the realm", m[1].key == "Mirel-OtherRealm" and m[1].name == "Mirel", m[1].key)
  a.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|U|2t|4|1|From Afar|", "PARTY", "Mirel-OtherRealm")
  check("realm: message keyed the same way", a.ns.partners["Mirel-OtherRealm"] ~= nil)
  a.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|U|2u|4|1|Same Name|", "PARTY", "Tavlius-OtherRealm")
  check("realm: someone with my name on another realm isn't me", a.ns.partners["Tavlius-OtherRealm"] ~= nil)
  noErrors(a, "realm")
end

-- 34. Commands and help
do
  local c = H.boot()
  c.addQuest({ id = 1, title = "No Objectives" }, true)
  c.login()
  c.slash("help")
  check("help: lists share and ignore", c.printedMatch("/dq share") and c.printedMatch("/dq ignore"))
  c.slash("bogus")
  check("unknown command", c.printedMatch("unknown command 'bogus'"))
  c.slash("check")
  check("check: reports APIs", c.printedMatch("yes.*C_QuestLog.GetInfo"))
  check("check: measures the log", c.printedMatch("log: 1 entries, 1 quests by the game's count, 1 read"))
  check("check: quests without objectives", c.printedMatch("No Objectives %(complete%)"))
  check("check: interface number", c.printedMatch("interface 16001"))
  c.slash("status")
  check("status solo", c.printedMatch("not in a group"))
  c.slash("debug on")
  check("debug on", c.ns.DB.debug == true)
  c.slash("resetpos")
  check("resetpos", c.ns.DB.point[1] == "TOPLEFT" and c.ns.DB.point[3] == 260)
  c.slash("")
  check("toggle while waiting for a group: still wanted, says when it shows", c.ns.DB.shown == true
    and c.printedMatch("shows up when you're in a group"))
  c.slash("solo on")
  c.tick(2)
  c.slash("")
  check("toggle hides", c.ns.DB.shown == false and c.printedMatch("/dq brings it back"))
  c.slash("solo off")
  c.slash("show")
  check("show", c.ns.DB.shown == true)
  c.slash("sound off")
  check("sound off", c.ns.DB.sound == false)
  c.slash("ignore list")
  check("ignore list empty", c.printedMatch("no ignored quests"))
  c.slash("ignore 1")
  c.slash("ignore list")
  check("ignore list", c.printedMatch("ignored: .*No Objectives"))
  c.slash("ignore nonsense")
  check("ignore usage", c.printedMatch("usage: /dq ignore"))
  _G.VulcanDuoQuest_ShareNext()
  check("binding: share next works solo", c.printedMatch("you're not in a group"))
  noErrors(c, "commands")
end

-- 35. Task and hidden quests are not compared
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 900, title = "Bonus Area", task = true }, true)
    a.addQuest({ id = 901, title = "Hidden", hidden = true }, true)
  end, nil)
  check("tasks: skipped", a.ns.mine[900] == nil and a.ns.mine[901] == nil)
  check("tasks: partner doesn't see them", next(b.ns.partners.Tavlius.list) == nil)
  noErrors(a, "tasks")
end

-- 36. Older clients: no RegisterUnitEvent, missing templates
do
  local a, b = Duo(nil, nil, { name = "Tavlius", noUnitEvents = true, badTemplates = { UIPanelButtonTemplate = true,
    UIPanelCloseButton = true } })
  FreshGaps(a, b)
  local before = #a.printed
  a.fire("UNIT_SPELLCAST_START", "party1", "Cast-1", 8690)
  check("fallback: other units still filtered", not a.printedMatch("Before you", before + 1))
  local hub = a.realNs.DB.hub
  a.fire("UNIT_SPELLCAST_SUCCEEDED", "party1", "Cast-1", 8690)
  a.tick(1)
  check("fallback: his hearth going off isn't yours (same hub)", a.realNs.DB.hub == hub)
  a.fire("UNIT_SPELLCAST_START", "player", "Cast-2", 8690)
  check("fallback: own hearth seen", a.printedMatch("Before you hearth", before + 1))
  a.tick(2)
  check("fallback: window works without templates", a.windowText():find("Fresh Shareable || %[Share%]"), a.windowText())
  noErrors(a, "fallback")
end

-- 37. Focus stays on your partner when someone else with DuoQuest joins
do
  local a, b = Standard()
  local d = H.boot({ name = "Dana" })
  d.addQuest({ id = 3, title = "D3" }, true)
  d.login()
  check("focus: Mirel first", a.ns.FocusPartner().key == "Mirel")
  a.setGroup({ "Mirel", "Dana" }) b.setGroup({ "Tavlius", "Dana" }) d.setGroup({ "Tavlius", "Mirel" })
  H.run({ a, b, d }, 40)
  check("focus: Dana synced", a.ns.partners.Dana and a.ns.partners.Dana.synced)
  check("focus: still Mirel (alphabetical would pick Dana)", a.ns.FocusPartner().key == "Mirel", a.ns.FocusPartner().key)
  a.setGroup({ "Dana" }) d.setGroup({ "Tavlius" })
  H.run({ a, d }, 4)
  check("focus: moves on when Mirel leaves", a.ns.FocusPartner().key == "Dana")
  noErrors(a, "focus")
end

-- 38. No heartbeat in a group where nobody else runs DuoQuest
do
  local a = H.boot()
  a.addQuest({ id = 1, title = "One" }, true)
  a.login()
  a.setGroup({ "Bob" })
  a.tick(300)
  check("alone: an occasional hello, no lists", a.sentMatching("^2|H|") == 2 and a.sentMatching("^2|L|") == 0
    and #a.addonSent == 2, #a.addonSent)
  noErrors(a, "alone")
end

-- 39. More sync paths
do
  local a, b = Standard()
  a.distance.party1 = 500
  -- A pickup learned only from the list (its details lost): noted once details arrive.
  local before = #a.printed
  local lost = false
  a.dropFrom = function(m)
    if not lost and m.msg:find("^2|U|") then lost = true return true end
    return false
  end
  b.addQuest({ id = 150, title = "Learned Late" })
  H.run({ a, b }, 150)
  a.dropFrom = nil
  check("late pickup: noted with its title", a.printedMatch("Mirel picked up .*Learned Late", before + 1))
  -- A request about a quest we no longer have gets our list.
  local sent = #b.addonSent
  b.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|N|Mirel|" .. b.ns.To36(999), "PARTY", "Tavlius-Realm")
  b.tick(4)
  check("N for a dropped quest: list resent", b.sentMatching("^2|L|", sent + 1) >= 1)
  -- A request from someone we don't know doesn't make them a partner.
  b.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|N|Mirel|1", "PARTY", "Dana-Realm")
  check("N from a stranger: not a partner", b.ns.partners.Dana == nil)
  -- The done list is healed by the heartbeat.
  b.completed[101] = true
  a.dropFrom = function(m) return m.msg:find("^2|C|") ~= nil end
  b.ns.SendDone(true)
  H.run({ a, b }, 10)
  a.dropFrom = nil
  check("done list lost at first", not a.ns.partners.Mirel.done[101])
  H.run({ a, b }, 130)
  check("done list healed", a.ns.partners.Mirel.done[101] == true)
  -- Leaving and rejoining says hello again.
  a.setGroup({}) b.setGroup({})
  H.run({ a, b }, 4)
  local hellos = a.sentMatching("^2|H|")
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 40)
  check("rejoin: hello again and synced", a.sentMatching("^2|H|") > hellos and a.ns.partners.Mirel
    and a.ns.partners.Mirel.synced)
  noErrors(a, "sync paths") noErrors(b, "sync paths B")
end

-- 40. Cross-realm duo, end to end
do
  local a = H.boot({ name = "Tavlius", realm = "Emberfall" })
  local b = H.boot({ name = "Mirel", myRealm = "Emberfall", realm = "Realm" })
  a.addQuest({ id = 1, title = "Here" }, true)
  b.addQuest({ id = 2, title = "There" }, true)
  a.login() b.login()
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 40)
  local p = a.ns.partners["Mirel-Emberfall"]
  check("cross-realm: synced under the realm key", p and p.synced and p.quests[2] ~= nil)
  check("cross-realm: shown by name", a.windowText():find("Mirel doesn't have"), a.windowText())
  a.addQuest({ id = 3, title = "Third" })
  b.dropFrom = function(m) return m.msg:find("^2|U|3|") ~= nil end
  H.run({ a, b }, 200)
  b.dropFrom = nil
  H.run({ a, b }, 100)
  local pc = b.ns.partners["Tavlius-Realm"]
  check("cross-realm: addressed resend requests work", pc and pc.quests[3] ~= nil)
  noErrors(a, "xrealm") noErrors(b, "xrealm B")
end

-- 41. Sharing: edge cases
do
  local a, b = Duo(function(a)
    a.log[#a.log + 1] = { header = "Elwynn Forest" }
    a.addQuest({ id = 31, title = "Collapsed One", objs = { { label = "c", have = 0, need = 1 } } }, true)
  end, nil)
  a.collapsed["Elwynn Forest"] = true
  a.fire("QUEST_LOG_UPDATE")
  H.run({ a, b }, 6)
  a.selected = 7
  a.slash("share")
  check("share collapsed: falls back to selecting it", a.pushed[#a.pushed] == 31, a.pushed[#a.pushed])
  check("share collapsed: selection put back", a.selected == 7, a.selected)
  a.rangeUnknown.party1 = true
  a.mapID.party1 = 1429  -- (distance unreadable, but on your map: can't tell)
  a.fire("UNIT_IN_RANGE_UPDATE", "party1", false)
  a.tick(2)
  local row = a.rowFor("Collapsed One")
  check("range unknown: Share stays on", row and row.share.enabled)
  local solo = H.boot()
  solo.addQuest({ id = 5, title = "Alone" }, true)
  solo.login()
  local ok, why = solo.ns.ShareQuest(5)
  check("share solo: refused with reason", ok == false and why:find("group"), why)
  local n = H.boot({ name = "Tavlius", noLogIndex = true })
  n.addQuest({ id = 6, title = "Six" }, true)
  n.login()
  n.setGroup({ "Mirel" })
  n.selected = 9
  check("share without log index: by selection", n.ns.ShareQuest(6) == true and n.pushed[1] == 6 and n.selected == 9)
  noErrors(a, "share edges")
end

-- 42. Classic: /dq share picks a "maybe" quest
do
  local a = Duo(function(a)
    a.addQuest({ id = 41, title = "Classic One", objs = { { label = "Boars", have = 3, need = 8 } } }, true)
  end, nil, { name = "Tavlius", classic = true })
  a.slash("share")
  check("classic: share next picks a maybe-shareable quest", a.pushed[1] == 41, a.pushed[1])
  a.addQuest({ id = 42, title = "Accepted Classic" })
  a.tick(4)
  check("classic: QUEST_ACCEPTED (index, id) handled", a.ns.mine[42] ~= nil)
  noErrors(a, "classic share")
end

-- 43. Leave warnings: more paths
do
  local a, b = Standard()
  a.fire("TAXIMAP_OPENED")  -- the unknown-age gaps from login
  -- Flight map events arrive together: one warning.
  a.addQuest({ id = 220, title = "Gap Twenty" })
  H.run({ a, b }, 10)
  local before = #a.printed
  a.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 6)
  a.fire("TAXIMAP_OPENED")
  check("flight: both events, one warning", a.printedCount("Before you fly", before + 1) == 1)
  check("center text: Mirel is missing", a.errorsFrame[#a.errorsFrame]:find("Mirel is missing 1 quest from here"),
    a.errorsFrame[#a.errorsFrame])
  b.addQuest({ id = 221, title = "His Gap" })
  H.run({ a, b }, 10)
  a.slash("sound off")
  local sounds = #a.sounds
  a.fire("TAXIMAP_OPENED")
  check("center text: You are missing", a.errorsFrame[#a.errorsFrame]:find("You are missing 1 quest"),
    a.errorsFrame[#a.errorsFrame])
  check("sound off: silent", #a.sounds == sounds)
  -- A hearth: warned before; after the loading screen no "You left".
  a.addQuest({ id = 222, title = "Before Hearth" })
  H.run({ a, b }, 10)
  before = #a.printed
  a.fire("UNIT_SPELLCAST_START", "player", "Cast-9", 171253)  -- another hearthstone, same name
  check("hearth: other hearthstones by name", a.printedMatch("Before you hearth", before + 1))
  a.fire("UNIT_SPELLCAST_START", "player", "Cast-10", 94719)
  a.zone = "Westfall"
  a.fire("PLAYER_ENTERING_WORLD", false, false)
  a.fire("ZONE_CHANGED_NEW_AREA")
  check("hearth: no 'You left' after the loading screen", not a.printedMatch("You left", before + 1))
  -- On a flight, zone lines don't count.
  a.addQuest({ id = 223, title = "Before Takeoff" })
  H.run({ a, b }, 30)
  a.onTaxi = true
  a.tick(2)
  before = #a.printed
  a.zone = "Redridge Mountains"
  a.fire("ZONE_CHANGED_NEW_AREA")
  check("taxi: zone lines during a flight don't warn", not a.printedMatch("You left", before + 1))
  a.onTaxi = false
  a.tick(2)
  a.fire("TAXIMAP_OPENED")
  check("taxi: gaps from before takeoff aren't warned after landing", not a.printedMatch("Before you", before + 1))
  -- Dead: no warnings at all.
  a.addQuest({ id = 224, title = "Ghost Gap" })
  H.run({ a, b }, 10)
  a.dead = true
  a.fire("TAXIMAP_OPENED")
  a.zone = "Duskwood"
  H.run({ a, b }, 30)
  a.fire("ZONE_CHANGED_NEW_AREA")
  check("dead: no warnings", not a.printedMatch("Before you", before + 1) and not a.printedMatch("You left", before + 1))
  a.dead = false
  noErrors(a, "warn paths")
end

-- 44. /dq status lists every gap, wherever and whenever it was picked up
do
  local a, b = Duo(function(a)
    for i = 1, 8 do a.addQuest({ id = 800 + i, title = "Old Gap " .. i }, true) end
  end, nil)
  for i = 1, 8 do a.realNs.seenAt[800 + i] = a.wall - 86400 end  -- picked up yesterday
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("old gaps (known age) aren't warned", not a.printedMatch("Before you", before + 1))
  a.slash("status")
  local line = a.printedMatch("Mirel doesn't have", before + 1) or ""
  check("status: all 8 listed, no 'more'", select(2, line:gsub("Old Gap", "")) == 8 and not line:find("more"), line)
  noErrors(a, "status") noErrors(b, "status B")
end

-- 45. The finish note: only when you're not done yourself
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 60, title = "Race", objs = { { label = "r", have = 5, need = 5 } } }, true)
  end, function(b)
    b.addQuest({ id = 60, title = "Race", objs = { { label = "r", have = 1, need = 5 } } }, true)
  end)
  a.distance.party1 = 500
  b.progress(60, 1, 5)
  H.run({ a, b }, 20)
  check("finish note: not when you're done too", not a.printedMatch("Mirel finished"))
  noErrors(a, "finish")
end

-- 46. Window: closing it keeps it closed
do
  local a = Standard()
  a.tick(2)
  local closeButton
  for _, f in ipairs(a.frames) do
    if f.kind == "Button" and f.scripts.OnClick and not f.questID and f.text == nil and f ~= a.realNs.rows[1] then
      closeButton = closeButton or f
    end
  end
  closeButton:Click()
  a.tick(20)
  check("closed: stays closed", not a.ui.shown and a.ns.DB.shown == false)
  a.slash("")
  a.tick(2)
  check("closed: /dq brings it back", a.ui.shown)
  _G.VulcanDuoQuest_ToggleWindow()
  a.tick(2)
  check("key binding: hides", not a.ui.shown and a.ns.DB.shown == false)
  _G.VulcanDuoQuest_ToggleWindow()
  a.tick(2)
  check("key binding: shows", a.ui.shown and a.ns.DB.shown == true)
end

-- 47. Robustness: a failing listener, unknown events, error cap, welcome once
do
  local c = H.boot({ unknownEvents = { TAXIMAP_OPENED = true, PLAYER_INTERACTION_MANAGER_FRAME_SHOW = true } })
  c.addQuest({ id = 1, title = "One" }, true)
  c.login()
  check("unknown events: still loads and scans", c.ns.mineReady == true)
  local ran = 0
  c.realNs.Listen("TICK", function() error("boom") end)
  c.realNs.Listen("TICK", function() ran = ran + 1 end)
  c.tick(4)
  check("a failing listener doesn't stop the others", ran == 4, ran)
  check("errors reported once", #c.errors() == 1, #c.errors())
  for i = 1, 8 do c.realNs.Listen("TICK", function() error("distinct " .. i) end) end
  c.tick(2)
  check("error reports capped at 5", #c.errors() == 5, #c.errors())
  local again = H.boot({ saved = c.saved() })
  again.login()
  check("welcome: once across sessions", again.printedCount("loaded%.") == 0)
end

-- 48. Pickup times: kept across a reload, and fresh for list-learned pickups
do
  local a, b = Standard()
  a.fire("TAXIMAP_OPENED")  -- (unknown-age gaps from login)
  a.addQuest({ id = 230, title = "Yesterday's" })
  H.run({ a, b }, 10)
  a.realNs.seenAt[230] = a.wall - 86400
  local a2 = H.boot({ name = "Tavlius", saved = a.saved() })
  for _, q in ipairs(a.log) do a2.addQuest(q, true) end
  a2.inGroup, a2.group = true, { "Mirel" }
  a2.login()
  H.run({ a2, b }, 40)
  local before = #a2.printed
  a2.fire("TAXIMAP_OPENED")
  check("reload: a quest picked up yesterday isn't 'from here'", not a2.printedMatch("Yesterday's", before + 1))
  -- A pickup we only learned about from the list is fresh.
  a2.fire("TAXIMAP_OPENED")
  a2.dropFrom = function(m) return m.msg:find("^2|U|") ~= nil end
  b.addQuest({ id = 231, title = "Learned From List" })
  H.run({ a2, b }, 140)
  a2.dropFrom = nil
  before = #a2.printed
  a2.fire("TAXIMAP_OPENED")
  check("list-learned pickup counts as from here", a2.printedMatch("You don't have: .*Quest #231", before + 1)
    or a2.printedMatch("You don't have: .*Learned From List", before + 1))
  check("list-learned pickup has a pickup time", (a2.ns.partners.Mirel.seenAt[231] or 0) > 0)
  noErrors(a2, "pickup times")
end

-- 49. Checksums tell different quest states apart
do
  local c = H.boot()
  c.login()
  local seen, n = {}, 0
  for have = 0, 49 do
    local h = c.ns.Hash(c.ns.EncodeQuest({ id = 777, flags = 4, level = 10, title = "Same Quest",
      objs = { { label = "Wolves", have = have, need = 50, done = false } } }))
    if not seen[h] then seen[h] = true n = n + 1 end
  end
  check("checksum: 50 progress states, (almost) all different", n >= 48, n)
end

-- 50. A busy partner still gets missing details re-sent
do
  local a, b = Duo(nil, function(b)
    b.addQuest({ id = 70, title = "Grind", objs = { { label = "g", have = 0, need = 100 } } }, true)
  end)
  local lost = false
  a.dropFrom = function(m)
    if not lost and m.msg:find("^2|U|1z|") then lost = true return true end  -- id 71 in base 36
    return false
  end
  b.addQuest({ id = 71, title = "Lost While Busy" })
  local listed, got
  for i = 1, 60 do
    b.progress(70, 1, i)  -- a kill every 2 seconds, for 2 minutes
    H.run({ a, b }, 4)
    local p = a.ns.partners.Mirel
    if not listed and p.list[71] then listed = i * 2 end  -- (his next list shows it: details missing from here)
    if not got and p.quests[71] then got = i * 2 end
  end
  check("busy partner: details re-requested anyway", a.ns.partners.Mirel.quests[71] ~= nil)
  check("busy partner: asked within about half a minute of noticing", listed and got and got - listed <= 30,
    tostring(listed) .. " -> " .. tostring(got))
  noErrors(a, "busy")
end

-- 51. Hellos can't make you resend everything over and over
do
  local a, b = Standard()
  local sentU, sentL = a.sentMatching("^2|U|"), a.sentMatching("^2|L|")
  for i = 1, 24 do
    a.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|H|1.1.0|spam" .. i .. "|0", "PARTY", "Mirel-Realm")
    H.run({ a, b }, 10)
  end
  local n = (a.sentMatching("^2|U|") - sentU) + (a.sentMatching("^2|L|") - sentL)
  check("hello spam: at most one full send per 10s", n <= 13 * 4, n)  -- 3 quests + 1 list part
  check("hello spam: lists at most one per 10s", a.sentMatching("^2|L|") - sentL <= 13, a.sentMatching("^2|L|") - sentL)
  noErrors(a, "hello spam")
end

-- 51b. A request right after a full send still gets one, a little later
do
  local a, b = Standard()
  a.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|H|1.1.0|again1|0", "PARTY", "Mirel-Realm")  -- a full goes out
  H.run({ a, b }, 4)
  local d = H.boot({ name = "Dana" })
  d.login()
  a.setGroup({ "Mirel", "Dana" }) b.setGroup({ "Tavlius", "Dana" }) d.setGroup({ "Tavlius", "Mirel" })
  H.run({ a, b, d }, 30)
  check("second requester served within 15s", d.ns.partners.Tavlius and d.ns.partners.Tavlius.quests[101] ~= nil)
  noErrors(a, "deferred full")
end

-- 52. Partner chosen before they're in the group, any capitalization
do
  local a, b = Duo(nil, nil)
  local d = H.boot({ name = "Dana" })
  d.login()
  a.slash("partner DANA")
  a.setGroup({ "Mirel", "Dana" }) b.setGroup({ "Tavlius", "Dana" }) d.setGroup({ "Tavlius", "Mirel" })
  H.run({ a, b, d }, 30)
  check("focus: picked earlier, matched once they join", a.ns.FocusPartner().key == "Dana")
  noErrors(a, "focus later")
end

-- 53. Hearthstone by spell ID when names can't be read; loading screens are arrivals
do
  local a, b = Duo(nil, nil, { name = "Tavlius", noSpellNames = true })
  a.fire("TAXIMAP_OPENED")
  a.addQuest({ id = 240, title = "Hearth Gap" })
  H.run({ a, b }, 10)
  local before = #a.printed
  a.fire("UNIT_SPELLCAST_START", "player", "Cast-1", 8690)
  check("hearth by ID", a.printedMatch("Before you hearth", before + 1))
  -- A portal: loading screen into a new zone, no hearth. Arriving is a new hub,
  -- and the zone line around the loading screen isn't "You left".
  a.addQuest({ id = 241, title = "Portal Gap" })
  H.run({ a, b }, 10)
  before = #a.printed
  a.fire("LOADING_SCREEN_ENABLED")
  a.zone = "Darnassus"
  a.fire("ZONE_CHANGED_NEW_AREA")
  a.fire("PLAYER_ENTERING_WORLD", false, false)
  a.fire("LOADING_SCREEN_DISABLED")
  check("portal: no 'You left' around the loading screen", not a.printedMatch("You left", before + 1))
  a.fire("TAXIMAP_OPENED")
  check("portal: gaps from before aren't 'from here'", not a.printedMatch("Before you", before + 1))
  a.addQuest({ id = 242, title = "Dungeon Gap" })
  H.run({ a, b }, 30)
  a.zone = "The Deadmines"
  a.fire("PLAYER_ENTERING_WORLD", false, false)  -- no zone event at all
  a.fire("TAXIMAP_OPENED")
  check("loading screen alone: a new hub", not a.printedMatch("Dungeon Gap", before + 1))
  noErrors(a, "hearth id")
end

-- 54. Bounty-style quests aren't compared
do
  local a, b = Duo(function(a) a.addQuest({ id = 950, title = "Bounty", bounty = true }, true) end, nil)
  check("bounty: skipped", a.ns.mine[950] == nil and next(b.ns.partners.Tavlius.list) == nil)
end

-- 55. The 12.x client: UnitInRange is secret; distances still work
do
  local a, b = Standard()
  a.secrets.range, a.secretType = true, "boolean"
  b.secrets.range, b.secretType = true, "boolean"
  local before = #a.printed
  b.addQuest({ id = 260, title = "Right Beside You" })
  H.run({ a, b }, 20)
  check("secret range: notes quiet while together", not a.printedMatch("Right Beside You", before + 1))
  a.distance.party1 = 80
  a.fire("UNIT_IN_RANGE_UPDATE", "party1", H.SECRET)
  a.tick(2)
  local row = a.rowFor("Wolves Across")
  check("secret range: Share greys out by distance", row and not row.share.enabled)
  a.slash("check")
  check("check: distance shown", a.printedMatch("80 yards away"))
  check("check: partner version shown", a.printedMatch("partner Mirel: DuoQuest dev"))  -- (from source: the TOC token is dev)
  noErrors(a, "secret range")
end

-- 56. A warning held for combat keeps its gaps (walking away, zone lines)
do
  local a, b = Standard()
  a.fire("TAXIMAP_OPENED")  -- (unknown-age gaps from login)
  H.run({ a, b }, 6)
  a.subzone = "Goldshire"
  a.addQuest({ id = 270, title = "Walked Off With It" })
  H.run({ a, b }, 10)
  local before = #a.printed
  a.subzone = "Elwynn Forest"
  a.combat = true  -- pulled something on the way out
  H.run({ a, b }, 32)
  check("combat walk-away: nothing yet", not a.printedMatch("Leaving", before + 1))
  a.combat = false
  a.fire("PLAYER_REGEN_ENABLED")
  check("combat walk-away: warned after the fight", a.printedMatch("Leaving Goldshire", before + 1)
    and a.printedMatch("Walked Off With It", before + 1))
  a.addQuest({ id = 271, title = "Zone Line Fight" })
  H.run({ a, b }, 10)
  before = #a.printed
  a.combat = true
  a.zone, a.subzone = "Westfall", "Jangolode Mine"
  a.fire("ZONE_CHANGED_NEW_AREA")
  H.run({ a, b }, 10)
  a.combat = false
  a.fire("PLAYER_REGEN_ENABLED")
  check("combat zone line: warned after the fight", a.printedMatch("You left Elwynn Forest", before + 1)
    and a.printedMatch("Zone Line Fight", before + 1))
  noErrors(a, "held")
end

-- 57. A long two-sided outage (boss fight) heals by itself
do
  local a, b = Standard()
  H.outage({ a, b }, 480)
  H.run({ a, b }, 400)
  check("outage: partner fresh again (A)", not a.ns.IsStale(a.ns.partners.Mirel))
  check("outage: partner fresh again (B)", not b.ns.IsStale(b.ns.partners.Tavlius))
  b.progress(104, 1, 5)
  H.run({ a, b }, 10)
  check("outage: updates flow again", a.ns.partners.Mirel.quests[104].objs[1].have == 5)
  -- With the client's lockdown signal, nothing is wasted while it lasts.
  a.lockdown = true
  local attempts = a.sendAttempts or 0
  a.progress(103, 1, 9)
  H.run({ a, b }, 120)
  check("lockdown: no send attempts while locked", (a.sendAttempts or 0) == attempts)
  a.lockdown = false
  H.run({ a, b }, 10)
  check("lockdown: sent afterwards", b.ns.partners.Tavlius.quests[103].objs[1].have == 9)
  noErrors(a, "outage") noErrors(b, "outage B")
end

-- 58. /reload keeps the hub: what you picked up before it still warns
do
  local a, b = Standard()
  a.fire("TAXIMAP_OPENED")
  a.addQuest({ id = 280, title = "Before Reload" })
  H.run({ a, b }, 10)
  local a2 = H.boot({ name = "Tavlius", saved = a.saved() })
  for _, q in ipairs(a.log) do a2.addQuest(q, true) end
  a2.inGroup, a2.group = true, { "Mirel" }
  a2.wall = a.wall + 5
  a2.login(true)
  H.run({ a2, b }, 40)
  local before = #a2.printed
  a2.fire("TAXIMAP_OPENED")
  check("reload: gap from before the reload warned", a2.printedMatch("Before Reload", before + 1))
  check("reload: old gaps already warned aren't repeated", not a2.printedMatch("Wolves Across", before + 1))
  -- A fresh login starts over.
  local a3 = H.boot({ name = "Tavlius", saved = a2.saved() })
  for _, q in ipairs(a.log) do a3.addQuest(q, true) end
  a3.inGroup, a3.group = true, { "Mirel" }
  a3.wall = a2.wall + 3600
  a3.login()
  H.run({ a3, b }, 40)
  before = #a3.printed
  a3.fire("TAXIMAP_OPENED")
  check("login: yesterday's pickups aren't from here", not a3.printedMatch("Before Reload", before + 1))
  noErrors(a2, "reload hub") noErrors(a3, "login hub")
end

-- 59. Partner pickups made away from you aren't "from here"
do
  local a, b = Standard()
  a.fire("TAXIMAP_OPENED")
  a.distance.party1 = 1500
  b.addQuest({ id = 290, title = "Far Away Pickup" })
  H.run({ a, b }, 10)
  a.distance.party1 = nil
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("away pickup: not in the hub warning", not a.printedMatch("Far Away Pickup", before + 1))
  a.slash("status")
  check("away pickup: still in /dq status", a.printedMatch("Far Away Pickup", before + 1))
  -- Without distances, the map decides.
  a.rangeUnknown.party1 = true
  a.mapID.party1 = 1436
  b.addQuest({ id = 291, title = "Other Map Pickup" })
  H.run({ a, b }, 10)
  a.rangeUnknown.party1, a.mapID.party1 = nil, nil
  before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("away pickup: other map not from here", not a.printedMatch("Other Map Pickup", before + 1))
  -- Unknown-age gaps don't claim "from here".
  local c, d = Duo(function(c) c.addQuest({ id = 292, title = "Unknown Age" }, true) end, nil)
  c.fire("TAXIMAP_OPENED")
  check("center text: no 'from here' for unknown-age gaps", c.errorsFrame[#c.errorsFrame]
    and not c.errorsFrame[#c.errorsFrame]:find("from here"), c.errorsFrame[#c.errorsFrame])
  noErrors(a, "away") noErrors(d, "away D")
end

-- 60. Flights: a zone line in the air isn't "You left", even with a fresh gap
do
  local a, b = Standard()
  a.fire("TAXIMAP_OPENED")
  a.onTaxi = true
  H.run({ a, b }, 4)
  b.addQuest({ id = 300, title = "Picked Up While You Fly" })
  H.run({ a, b }, 10)
  local before = #a.printed
  a.zone = "Westfall"
  a.fire("ZONE_CHANGED_NEW_AREA")
  check("in flight: no 'You left'", not a.printedMatch("You left", before + 1))
  a.onTaxi = false
  noErrors(a, "flight zone")
end

-- 61. Hub bookkeeping
do
  local a, b = Standard()
  a.fire("TAXIMAP_OPENED")
  -- Logging in at an inn makes the inn the hub.
  local r = H.boot({ name = "Dana" })
  r.resting, r.subzone = true, "Lion's Pride Inn"
  r.login()
  r.resting = false
  check("login resting: hub marked", r.realNs.DB.hub and r.realNs.DB.hub.areas["Lion's Pride Inn"] == "rest")
  -- Quest areas name the hub over the inn.
  a.subzone = "Lion's Pride Inn"
  a.resting = true a.fire("PLAYER_UPDATE_RESTING")
  a.resting = false
  a.subzone = "Goldshire"
  a.addQuest({ id = 310, title = "Named Hub" })
  H.run({ a, b }, 10)
  a.subzone = "Elwynn Forest"
  H.run({ a, b }, 32)
  check("hub name: the quest area", a.printedMatch("Leaving Goldshire:"))
  -- A new hub forgets the old one's areas, and leaving with no gaps still starts a new hub.
  local before = #a.printed
  a.subzone = "Goldshire"
  H.run({ a, b }, 40)
  check("new hub: old areas forgotten (no 'Leaving' for walking back)", not a.printedMatch("Leaving", before + 1))
  a.subzone = "Westbrook Garrison"
  a.addQuest({ id = 311, title = "Garrison Quest" })
  b.addQuest({ id = 311, title = "Garrison Quest" })
  H.run({ a, b }, 10)
  a.subzone = "Elwynn Forest"
  H.run({ a, b }, 32)
  a.addQuest({ id = 312, title = "Roadside Quest" })
  H.run({ a, b }, 10)
  before = #a.printed
  a.subzone = "Westbrook Garrison"
  H.run({ a, b }, 40)
  check("walk-away without gaps: still a new hub", not a.printedMatch("Leaving Westbrook", before + 1))
  -- Unnamed wilderness: the zone name stands in.
  before = #a.printed
  a.subzone = ""
  a.addQuest({ id = 313, title = "Wilderness Quest" })
  H.run({ a, b }, 10)
  a.subzone = "Fargodeep Mine"
  H.run({ a, b }, 32)
  check("no subzone: open road hub says 'Moving on', not 'Leaving' the zone", a.printedMatch("Moving on:", before + 1)
    and not a.printedMatch("Leaving Elwynn Forest", before + 1), table.concat(a.printed, "\n", before + 1))
  noErrors(a, "hub")
end

-- 62. Same-second gaps are warned once
do
  local a, b = Standard()
  a.fire("TAXIMAP_OPENED")
  a.addQuest({ id = 320, title = "Same Second" })
  H.run({ a, b }, 6)
  a.fire("TAXIMAP_OPENED")
  local before = #a.printed
  a.tick(6)
  a.fire("UNIT_SPELLCAST_START", "player", "Cast-1", 8690)
  check("same second: not warned twice", not a.printedMatch("Same Second", before + 1))
end

-- 63. Notes: retries, staleness, turning off
do
  local a, b = Standard()
  a.distance.party1 = 500
  -- Details that take a while still get the note (within ~30s)...
  local delay = true
  a.dropFrom = function(m) return delay and m.msg:find("^2|U|99|") ~= nil end  -- 333 = "99"
  b.addQuest({ id = 333, title = "Slow Details" })
  H.run({ a, b }, 2)
  b.ns.SendFull()  -- (the list arrives, the details don't)
  H.run({ a, b }, 20)
  delay = false
  H.run({ a, b }, 40)
  check("late details: note printed", a.printedMatch("Mirel picked up .*Slow Details"))
  -- ...but not forever.
  a.dropFrom = function(m) return m.msg:find("^2|U|9a|") ~= nil end  -- 334
  b.addQuest({ id = 334, title = "Never Arrives" })
  H.run({ a, b }, 2)
  b.ns.SendFull()
  H.run({ a, b }, 100)
  a.dropFrom = nil
  H.run({ a, b }, 40)
  check("details too late: no note", not a.printedMatch("Never Arrives"))
  -- Nothing about a partner whose data is stale.
  local before = #a.printed
  a.tick(400)  -- Mirel silent
  a.addQuest({ id = 335, title = "Stale Note" })
  a.tick(20)
  check("stale partner: no note", not a.printedMatch("Stale Note", before + 1))
  H.run({ a, b }, 130)
  -- Turning notes off drops the ones already waiting.
  b.addQuest({ id = 336, title = "Waiting Note" })
  H.run({ a, b }, 4)
  a.slash("notify off")
  H.run({ a, b }, 20)
  a.slash("notify on")
  H.run({ a, b }, 20)
  check("notify off: waiting notes dropped", not a.printedMatch("Waiting Note"))
  noErrors(a, "note paths")
end

-- 64. Sync details
do
  local a, b = Standard()
  -- A quest you've already done: Mirel hears so before his note would fire.
  a.distance.party1 = 500
  b.distance.party1 = 500
  a.completed[340] = true
  local before = #b.printed
  b.addQuest({ id = 340, title = "Done It Already" })
  a.addQuest({ id = 341, title = "Filler" })
  H.run({ a, b }, 20)
  check("done before note: no false note", not b.printedMatch("Tavlius doesn't have .*Done It", before + 1)
    and b.ns.partners.Tavlius.done[340] == true)
  -- Details are re-requested quickly again once the earlier gap healed.
  local lost = 0
  a.dropFrom = function(m)
    if m.msg:find("^2|U|9k|") and lost < 4 then lost = lost + 1 return true end  -- 344, lost 4 times
    return false
  end
  b.addQuest({ id = 344, title = "First Gap" })
  H.run({ a, b }, 2)
  b.ns.SendFull()
  H.run({ a, b }, 600)
  check("first gap healed", a.ns.partners.Mirel.quests[344] ~= nil)
  -- The second gap's first resend is lost too: the next request comes 10s later, not 2 minutes.
  local dropped = 0
  a.dropFrom = function(m)
    if m.msg:find("^2|U|9l|") and dropped < 4 then dropped = dropped + 1 return true end  -- 345: pickup, full, 2 resends
    return false
  end
  b.addQuest({ id = 345, title = "Second Gap" })
  H.run({ a, b }, 2)
  b.ns.SendFull()
  H.run({ a, b }, 100)
  check("backoff resets after healing", a.ns.partners.Mirel.quests[345] ~= nil)
  -- The list's flags update details we already have.
  a.dropFrom = function(m) return m.msg:find("^2|U|2w|") ~= nil end  -- 104
  a.dropFrom = function(m) return m.msg:find("^2|U|2w|") ~= nil end  -- 104
  b.progress(104, 1, 12)  -- Mirel finishes it; the U is lost
  H.run({ a, b }, 2)
  b.ns.SendFull()
  H.run({ a, b }, 10)
  a.dropFrom = nil
  check("list flags: shows ready even before the details", a.ns.HasFlag(a.ns.partners.Mirel.quests[104].flags,
    a.realNs.F_COMPLETE))
  noErrors(a, "sync details") noErrors(b, "sync details B")
end

-- 65. Details that arrive before the first list have unknown age
do
  local c = H.boot()
  c.login()
  c.setGroup({ "Mirel" })
  c.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|U|2t|4|1|Early|", "PARTY", "Mirel-Realm")
  check("early details: unknown age", c.ns.partners.Mirel and c.ns.partners.Mirel.seenAt[101] == 0)
end

-- 66. Window: waiting status, height, motion scripts, sections remembered
do
  local a = H.boot()
  a.addQuest({ id = 1, title = "One" }, true)
  a.login()
  a.setGroup({ "Bob" })
  a.tick(40)
  a.setGroup({ "Bob" })  -- a roster update later doesn't restart "waiting"
  a.tick(12)
  check("waiting: not restarted by later roster changes", not a.statusText():find("Waiting"), a.statusText())
  a.setGroup({ "Bob" })
  a.tick(12)
  local small = a.ui.h
  for i = 2, 9 do a.addQuest({ id = i }) end
  a.tick(12)
  check("height grows with rows", a.ui.h > small, a.ui.h .. " vs " .. small)
  check("disabled Share still shows its tooltip", a.realNs.rows[2].share.motionWhileDisabled == true)
  local b, k = Duo(function(x) x.addQuest({ id = 5, title = "Five" }, true) x.completed[6] = true end,
    function(y) y.addQuest({ id = 6, title = "Six" }, true) end)
  b.rowFor("You already turned in"):Click()
  local saved = b.saved()
  check("sections: expanded state saved as false", saved.collapsed.iDid == false)
  local b2 = H.boot({ name = "Tavlius", saved = saved })
  b2.completed[6] = true
  b2.addQuest({ id = 5, title = "Five" }, true)
  b2.login(true)
  b2.setGroup({ "Mirel" })
  H.run({ b2, k }, 40)
  check("sections: still expanded after a reload", b2.windowText():find("%- You already turned in"), b2.windowText())
  -- A partner on a protocol that can't talk to ours.
  b2.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "9|H|9.0|zz|0", "PARTY", "Pug-Realm")
  b2.slash("partner pug")
  b2.inGroup, b2.group = true, { "Mirel", "Pug" }
  b2.fire("GROUP_ROSTER_UPDATE")
  b2.tick(40)
  check("status: incompatible version explained", b2.statusText():find("can't talk to yours"), b2.statusText())
end

-- 67. v1 settings: migrated once, then kept
do
  local old = H.boot({ name = "Tavlius", saved = { version = 1, point = { "CENTER", "CENTER", 1, 2 } } })
  old.login()
  old.ui:Drag(300, 400)
  local again = H.boot({ name = "Tavlius", saved = old.saved() })
  again.login(true)
  check("migration: position kept on the next reload", again.ns.DB.point[3] == 300 and again.ns.DB.point[4] == 400)
end

-- 68. Corpse runs, returning to an old area, quick rejoin, and caps
do
  local a, b = Standard()
  a.fire("TAXIMAP_OPENED")
  a.addQuest({ id = 400, title = "Before Dying" })
  H.run({ a, b }, 10)
  a.dead = true
  a.zone = "Westfall" a.fire("ZONE_CHANGED_NEW_AREA")  -- ghost runs across the line
  a.zone = "Elwynn Forest" a.fire("ZONE_CHANGED_NEW_AREA")
  a.dead = false
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("corpse run: the hub survives", a.printedMatch("Before Dying", before + 1))
  -- A new hub doesn't treat the old hub's areas as its own.
  a.subzone = "Goldshire"
  a.addQuest({ id = 401, title = "Goldshire Quest" })
  H.run({ a, b }, 10)
  a.subzone = "Elwynn Forest"
  H.run({ a, b }, 32)  -- "Leaving Goldshire"
  a.subzone = "Westbrook Garrison"
  a.addQuest({ id = 402, title = "Westbrook Quest" })
  H.run({ a, b }, 10)
  before = #a.printed
  a.subzone = "Goldshire"  -- walking back to the old hub
  H.run({ a, b }, 32)
  check("old hub's areas aren't this hub's", a.printedMatch("Leaving Westbrook Garrison", before + 1))
  -- Quick leave and rejoin: hello right away.
  a.setGroup({}) b.setGroup({})
  H.run({ a, b }, 4)
  local hellos = a.sentMatching("^2|H|")
  a.setGroup({ "Mirel" }) b.setGroup({ "Tavlius" })
  H.run({ a, b }, 2)
  check("rejoin: hello at once", a.sentMatching("^2|H|") > hellos)
  -- A broken client can't grow our tables without limit.
  for i = 1, 100 do
    a.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|U|" .. a.ns.To36(5000 + i) .. "|4|1|Spam " .. i .. "|", "PARTY", "Mirel-Realm")
  end
  local n = 0
  for _ in pairs(a.ns.partners.Mirel.list) do n = n + 1 end
  check("caps: partner list bounded", n <= 75, n)
  noErrors(a, "corpse")
end

-- 69. Task, hidden and bounty quests accepted during play stay out (and after a reload)
do
  local a, b = Standard()
  a.subzone = "Goldshire"
  a.addQuest({ id = 410, title = "Real Hub Quest" })
  H.run({ a, b }, 6)
  a.subzone = "Jasperlode Mine"
  a.addQuest({ id = 411, title = "Bonus: Kobolds", task = true })  -- auto-accepted walking in
  a.addQuest({ id = 412, title = "Hidden Tracker", hidden = true })
  a.addQuest({ id = 413, title = "Bounty Board", bounty = true })
  H.run({ a, b }, 10)
  check("tasks during play: not compared", a.ns.mine[411] == nil and a.ns.mine[412] == nil and a.ns.mine[413] == nil)
  check("tasks during play: partner doesn't see them", b.ns.partners.Tavlius.list[411] == nil
    and b.ns.partners.Tavlius.list[412] == nil and b.ns.partners.Tavlius.list[413] == nil)
  H.run({ a, b }, 32)
  check("bonus area isn't the hub: walking into it is leaving", a.printedMatch("Leaving Goldshire"))
  local a2 = H.boot({ name = "Tavlius", saved = a.saved() })
  for _, q in ipairs(a.log) do a2.addQuest(q, true) end
  a2.login(true)
  check("tasks after a reload: still out", a2.ns.mine[411] == nil and a2.ns.mine[412] == nil)
  noErrors(a, "tasks play")
end

-- 70. Your own pickups made while your partner is elsewhere aren't "from here"
do
  local a, b = Standard()
  a.fire("TAXIMAP_OPENED")
  a.distance.party1 = 900
  a.addQuest({ id = 420, title = "My Solo Pickup" })
  H.run({ a, b }, 10)
  a.distance.party1 = nil
  local before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("own away pickup: warned once they're here (you got here first)", a.printedMatch("My Solo Pickup", before + 1))
  check("own away pickup: their side doesn't claim it", not b.printedMatch("My Solo Pickup"))
  -- Still elsewhere when you leave: not theirs to walk back for.
  a.distance.party1 = 900
  a.addQuest({ id = 421, title = "Second Solo Pickup" })
  H.run({ a, b }, 10)
  before = #a.printed
  a.fire("TAXIMAP_OPENED")
  check("own away pickup: not warned while they're elsewhere", not a.printedMatch("Second Solo Pickup", before + 1))
  noErrors(a, "own away")
end

-- 71. The turned-in list arrives before the details on a new partner
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 101, title = "Already Done By Mirel" }, true)
    for i = 1, 24 do a.addQuest({ id = 600 + i, title = "Shared " .. i }, true) end
  end, function(b)
    b.completed[101] = true
    for i = 1, 24 do b.addQuest({ id = 600 + i, title = "Shared " .. i }, true) end
  end)
  -- (Duo already ran 20s; check how quickly it was known)
  check("done list early: known", a.ns.partners.Mirel.done[101] == true)
  local c, d = H.duo()
  c.addQuest({ id = 101, title = "Already Done" }, true)
  for i = 1, 24 do c.addQuest({ id = 600 + i }, true) d.addQuest({ id = 600 + i }, true) end
  d.completed[101] = true
  c.login() d.login()
  c.setGroup({ "Mirel" }) d.setGroup({ "Tavlius" })
  H.run({ c, d }, 10)  -- 5 seconds
  check("done list early: within 5s of grouping", c.ns.partners.Mirel and c.ns.partners.Mirel.done[101] == true)
  noErrors(c, "done early") noErrors(b, "done early B")
end

-- 72. Both log in at once, one quest log loads late: one exchange each, quickly
do
  local a, b = H.duo()
  for i = 1, 10 do a.addQuest({ id = 300 + i }, true) b.addQuest({ id = 400 + i }, true) end
  a.inGroup, a.group = true, { "Mirel" }
  b.inGroup, b.group = true, { "Tavlius" }
  a.login()
  b.fire("ADDON_LOADED", "VulcanDuoQuest") b.fire("PLAYER_LOGIN") b.fire("PLAYER_ENTERING_WORLD", true, false)
  H.run({ a, b }, 10)  -- Mirel's log is still loading
  b.fire("QUEST_LOG_UPDATE")
  H.run({ a, b }, 40)
  check("staggered login: both synced within 20s", a.ns.partners.Mirel and a.ns.partners.Mirel.synced
    and b.ns.partners.Tavlius and b.ns.partners.Tavlius.quests[301] ~= nil)
  check("staggered login: each quest sent once", a.sentMatching("^2|U|") == 10 and b.sentMatching("^2|U|") == 10,
    a.sentMatching("^2|U|") .. "/" .. b.sentMatching("^2|U|"))
end

-- 73. Notes: finished via the list, ignored quests, wording when far
do
  local a, b = Duo(function(a)
    a.addQuest({ id = 430, title = "Shared Kill", objs = { { label = "k", have = 1, need = 5 }, { label = "j", have = 3, need = 3 } } }, true)
    a.addQuest({ id = 431, title = "Ignored Shared", objs = { { label = "k", have = 1, need = 5 } } }, true)
  end, function(b)
    b.addQuest({ id = 430, title = "Shared Kill", objs = { { label = "k", have = 4, need = 5 }, { label = "j", have = 3, need = 3 } } }, true)
    b.addQuest({ id = 431, title = "Ignored Shared", objs = { { label = "k", have = 1, need = 5 } } }, true)
  end)
  a.distance.party1 = 500
  a.dropFrom = function(m) return m.msg:find("^2|U|by|") ~= nil end  -- 430's finish is lost
  b.progress(430, 1, 5)
  H.run({ a, b }, 140)
  a.dropFrom = nil
  local line = a.printedMatch("Mirel finished .*Shared Kill")
  check("finish note: comes from the list when the message is lost", line ~= nil)
  check("finish note: lists only what you have left", line and line:find("You: k 1/5") and not line:find(" j "), line)
  a.slash("ignore 431")
  b.progress(431, 1, 5)
  H.run({ a, b }, 20)
  check("finish note: not for ignored quests", not a.printedMatch("finished .*Ignored Shared"))
  a.distance.party1 = 300
  a.addQuest({ id = 432, title = "Far Pickup" })
  H.run({ a, b }, 20)
  check("far: note says to share when together, by ID", a.printedMatch("Far Pickup.*share it when you're together.*/dq share 432%)"))
  noErrors(a, "notes 73")
end

-- 74. A pug or raid without your partner keeps the window down
do
  local a = H.boot()
  a.addQuest({ id = 1, title = "One" }, true)
  a.login()
  a.setGroup({ "Pug1", "Pug2", "Pug3" })
  a.tick(12)
  check("pug: window hidden", not a.ui.shown)
end

-- 75. Every API that can be secret on 12.x, one at a time
do
  for _, which in ipairs({ "info", "objectives", "distance", "unitOnQuest", "pushable", "subzone", "taxi", "combat",
      "groupSize", "range", "members", "resting", "zone", "dead", "visible", "map" }) do
    local a, b = Standard()
    FreshGaps(a, b)
    local sent = #a.addonSent
    a.secrets[which] = true
    a.secretType = ({ info = "number", objectives = "number", distance = "number", groupSize = "number",
      subzone = "string", members = "string", zone = "string", map = "number" })[which] or "boolean"
    a.fire("QUEST_LOG_UPDATE")
    a.fire("GROUP_ROSTER_UPDATE")
    a.fire("UNIT_IN_RANGE_UPDATE", "party1", H.SECRET)
    a.fire("ZONE_CHANGED_NEW_AREA")
    a.fire("PLAYER_UPDATE_RESTING")
    H.run({ a, b }, 40)
    a.fire("TAXIMAP_OPENED")
    a.slash("status")
    a.slash("check")
    a.ns.Compare(a.ns.FocusPartner())
    check("secret " .. which .. ": no quests dropped", a.sentMatching("^2|D|", sent + 1) == 0 and a.ns.mine[101] ~= nil)
    check("secret " .. which .. ": partner kept", a.ns.partners.Mirel ~= nil)
    a.secrets[which] = nil
    H.run({ a, b }, 20)
    noErrors(a, "secret " .. which)
  end
end

-- 76. Smaller paths
do
  local a, b = Standard()
  -- /dq status counts Mirel's ready quests.
  a.slash("status")
  check("status: ready counts", a.printedMatch("ready to turn in: you 0, Mirel 1"))
  -- "failed" shows in the Both on section.
  b.quest(103).failed = true
  b.fire("QUEST_LOG_UPDATE")
  H.run({ a, b }, 10)
  a.tick(2)
  check("both on: failed shown", a.windowText():find("Kobold Camp Cleanup || 6/10 | failed"), a.windowText())
  -- /dq ignore takes a shift-clicked link; commands ignore case; Mirel's titles are used.
  a.slash("IGNORE |cffffff00|Hquest:104:10|h[Brotherhood of Thieves]|h|r")
  check("ignore: from a link, case-insensitive", a.ns.IsIgnored(104) and a.printedMatch("ignoring .*Brotherhood of Thieves"))
  a.slash("ignore list")
  check("ignore list: partner's title", a.printedMatch("ignored: .*Brotherhood of Thieves"))
  -- A zone event for the zone you're already in isn't leaving.
  a.addQuest({ id = 440, title = "Same Zone" })
  H.run({ a, b }, 10)
  local before = #a.printed
  a.fire("ZONE_CHANGED_NEW_AREA")
  check("same-zone event: nothing", not a.printedMatch("You left", before + 1))
  -- "no update for 3m"
  a.tick(360)
  a.tick(2)
  check("stale minutes", a.statusText():find("no update for 3m"), a.statusText())
  H.run({ a, b }, 130)
  -- The done list answers each pickup of his (once), not his other messages.
  local cs = a.sentMatching("^2|C|")
  for i = 1, 6 do b.addQuest({ id = 450 + i }) H.run({ a, b }, 4) end
  check("done list: once per pickup", a.sentMatching("^2|C|") - cs == 6, a.sentMatching("^2|C|") - cs)
  b.addQuest({ id = 460, objs = { { label = "x", have = 0, need = 9 } } })
  H.run({ a, b }, 4)
  cs = a.sentMatching("^2|C|")
  for i = 1, 6 do b.progress(460, 1, i) H.run({ a, b }, 4) end
  check("done list: not resent for progress (a heartbeat at most)", a.sentMatching("^2|C|") - cs <= 1, a.sentMatching("^2|C|") - cs)
  -- A partner who left while names were unreadable is removed once they can be read.
  a.secrets.members, a.secretType = true, "string"
  a.inGroup, a.group = true, { "Pug" }  -- Mirel left, Pug joined, while names were unreadable
  a.fire("GROUP_ROSTER_UPDATE")
  a.tick(2)
  a.secrets.members = nil
  a.tick(6)
  check("roster retry: departed partner removed", a.ns.partners.Mirel == nil)
  noErrors(a, "small paths")
end

-- 77. Other clients: no IsPushableQuest; classic failed quests; label shrinking; collapsed levels
do
  local a, b = Duo(function(a) a.addQuest({ id = 460, title = "Maybe Shareable" }, true) end, nil,
    { name = "Tavlius", noPushable = true })
  a.tick(2)
  check("no IsPushableQuest: Share offered (maybe)", a.windowText():find("Maybe Shareable || %[Share%]"), a.windowText())
  noErrors(a, "nopush") noErrors(b, "nopush B")
  local c = Duo(function(c)
    c.addQuest({ id = 461, title = "Classic Failed", failed = true, objs = { { label = "f", have = 0, need = 1 } } }, true)
  end, nil, { name = "Tavlius", classic = true })
  check("classic failed: flagged", c.ns.HasFlag(c.ns.mine[461].flags, c.realNs.F_FAILED))
  local e = H.boot()
  e.login()
  local objs = {}
  for j = 1, 6 do objs[j] = { label = string.rep("Lengthy", 6) .. j, have = j, need = 9, done = false } end
  local body = e.ns.EncodeQuest({ id = 1, flags = 4, level = 5, title = "T", objs = objs })
  local labels = {}
  for l in body:gmatch(":([^~|]*)") do labels[#labels + 1] = l end
  check("labels: shrunk only as much as needed", #body <= 245 and #labels[1] >= 18 and #labels[1] <= 28, #labels[1])
  check("clean: colors stripped", e.ns.Clean("|cffff0000Red|r Text") == "Red Text")
  local g, h = Duo(function(x)
    x.log[#x.log + 1] = { header = "Westfall" }
  end, nil)
  g.collapsed.Westfall = true
  g.log[#g.log + 1] = { id = 462, title = "Collapsed Level", level = 17, objs = {} }  -- accepted while collapsed
  g.fire("QUEST_ACCEPTED", 462)
  g.fire("QUEST_LOG_UPDATE")
  H.run({ g, h }, 6)
  check("collapsed: level kept", g.ns.mine[462] and g.ns.mine[462].level == 17)
end

-- 78. Hostile or odd input stays bounded
do
  local c = H.boot()
  c.login()
  c.setGroup({ "Mirel" })
  local ns = c.ns
  local back = ns.DecodeQuest({ "2t", "4", "1", "Big", "01234567/9:x~01/2:ok" })
  check("decode: huge numbers dropped", back and #back.objs == 1 and back.objs[1].label == "ok")
  check("encode: level clamped", ns.EncodeQuest({ id = 1, flags = 0, level = 5000, title = "x", objs = {} }):find("|999|"))
  check("list item: long hash rejected", ns.ParseListItem("1a.0.abcd") == nil and ns.ParseListItem("1a.0.abc") == 46)
  c.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "12345|U|2t|4|1|Long Protocol|", "PARTY", "Mirel-Realm")
  check("protocol number: length checked", c.ns.partners.Mirel == nil)
  local items = {}
  for i = 1, 100 do items[i] = ns.To36(9000 + i) .. ".4.a" end
  c.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|L|1|1|1|" .. table.concat(items, ",", 1, 40), "PARTY", "Mirel-Realm")
  local big = {}
  for i = 1, 100 do big[#big + 1] = items[i] end
  local parts, cur = {}, {}
  for _, it in ipairs(big) do
    cur[#cur + 1] = it
    if #cur == 30 then parts[#parts + 1] = table.concat(cur, ",") cur = {} end
  end
  if #cur > 0 then parts[#parts + 1] = table.concat(cur, ",") end
  for i, chunk in ipairs(parts) do
    c.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|L|2|" .. i .. "|" .. #parts .. "|" .. chunk, "PARTY", "Mirel-Realm")
  end
  local n = 0
  for _ in pairs(c.ns.partners.Mirel.list) do n = n + 1 end
  check("list: bounded", n == 75, n)
  -- A turned-in list replaces the previous one.
  c.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|C|3|1|1|2t,2u", "PARTY", "Mirel-Realm")
  c.fire("CHAT_MSG_ADDON", "VulcanDuoQuest", "2|C|4|1|1|2u", "PARTY", "Mirel-Realm")
  check("done list: replaced, not accumulated", not c.ns.partners.Mirel.done[101] and c.ns.partners.Mirel.done[102])
  -- Objectives per quest are capped.
  local d = H.boot()
  local objs = {}
  for j = 1, 12 do objs[j] = { label = "o" .. j, have = 0, need = 1 } end
  d.addQuest({ id = 7, title = "Many", objs = objs }, true)
  d.login()
  check("objectives: capped at 8", #d.ns.mine[7].objs == 8)
end

-- 79. Resend requests stay inside one message even when most details are missing
do
  local a, b = Duo(nil, function(b)
    for i = 1, 70 do b.addQuest({ id = 30000 + i * 997, title = "Many " .. i }, true) end
  end)
  -- Lose everything but the list for a fresh set of quests.
  a.dropFrom = function(m) return m.msg:find("^2|U|") ~= nil end
  b.ns.SendFull()
  for i = 1, 70 do b.quest(30000 + i * 997).title = "Renamed " .. i end
  b.fire("QUEST_LOG_UPDATE")
  H.run({ a, b }, 200)
  local maxN = 0
  for _, m in ipairs(a.addonSent) do if m.msg:find("^2|N|") then maxN = math.max(maxN, #m.msg) end end
  check("resend request fits", maxN > 0 and maxN <= 255, maxN)
  a.dropFrom = nil
  H.run({ a, b }, 400)
  check("and everything heals", #a.ns.MissingDetails(a.ns.partners.Mirel) == 0, #a.ns.MissingDetails(a.ns.partners.Mirel))
end

-- 80. After a partner reloads, they get our turned-in list right away
do
  local a, b = Duo(function(a) a.completed[500] = true end, function(b) b.addQuest({ id = 500, title = "Did It" }, true) end)
  local b2 = H.boot({ name = "Mirel", saved = b.saved() })
  b2.addQuest({ id = 500, title = "Did It" }, true)
  b2.inGroup, b2.group = true, { "Tavlius" }
  b2.login(true)
  H.run({ a, b2 }, 20)
  check("partner reload: done list within 10s", b2.ns.partners.Tavlius and b2.ns.partners.Tavlius.done[500] == true)
end

-- 81. Notes are about your focus partner only; giver-only tooltip line
do
  local a = H.boot({ name = "Tavlius" })
  local b = H.boot({ name = "Mirel" })
  local d = H.boot({ name = "Dana" })
  for _, c in ipairs({ a, b, d }) do c.login() end
  a.setGroup({ "Mirel", "Dana" }) b.setGroup({ "Tavlius", "Dana" }) d.setGroup({ "Tavlius", "Mirel" })
  H.run({ a, b, d }, 40)
  a.slash("partner dana")
  a.distance.party1, a.distance.party2 = 500, 500
  b.addQuest({ id = 510, title = "Mirel Only" })
  H.run({ a, b, d }, 20)
  check("notes: not about someone you're not comparing with", not a.printedMatch("Mirel Only"))
  a.addQuest({ id = 511, title = "Giver Only", pushable = false })
  H.run({ a, b, d }, 6)
  a.tick(2)
  a.rowFor("Giver Only"):Hover()
  local tip = table.concat(a.tooltip, " ")
  check("tooltip: giver-only explained", tip:find("Can't be shared"), tip)
end

os.exit(H.summary("tests") and 0 or 1)
