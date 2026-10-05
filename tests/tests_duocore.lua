-- DuoCore's own tests. Only DuoCore.lua is loaded (no DuoQuest), the way the
-- next duo addon will use it: here a made-up "Loot Split" on its own prefix.
package.path = assert(os.getenv("DQ_TESTS"), "DQ_TESTS unset: run tests/run.sh") .. "?.lua;" .. package.path
local H = require("harness")
local check = H.check

-- A client with only DuoCore loaded, grouped with Mirel, and one channel.
local function Setup(opts)
  opts = opts or {}
  opts.files = { "DuoCore.lua" }
  local c = H.boot(opts)
  c.inGroup, c.group = true, opts.group or { "Mirel" }
  local D = c.realNs.DuoCore
  local got, printed, peers = {}, {}, {}
  local enabled = true
  local ch = D.NewChannel({
    prefix = "LootSplt", protocol = 3, oldest = opts.oldest or 2, label = "Loot Split", version = opts.version or "2.0.0",
    enabled = function() return enabled end,
    onMessage = function(key, kind, fields, body) got[#got + 1] = { key = key, kind = kind, fields = fields, body = body } end,
    onPeer = function(key, event) peers[#peers + 1] = key .. ":" .. event end,
    print = function(m) printed[#printed + 1] = m end,
  })
  H.use(c)
  ch:Register()
  local t = { c = c, D = D, ch = ch, got = got, printed = printed, peers = peers }
  function t.sent(from)
    local out = {}
    for i = from or 1, #c.addonSent do
      if c.addonSent[i].prefix == "LootSplt" then out[#out + 1] = c.addonSent[i].msg end
    end
    return out
  end
  function t.pump(n)
    for _ = 1, n or 1 do
      c.now = c.now + 0.5
      H.use(c)
      ch:Pump(0.5)
    end
  end
  function t.recv(text, channel, sender)
    H.use(c)
    return ch:Receive("LootSplt", text, channel or "PARTY", sender or "Mirel-Realm")
  end
  function t.enable(v) enabled = v end
  return t
end

local function has(list, value)
  for _, v in ipairs(list) do if v == value then return true end end
  return false
end

-- Loads on its own
do
  local t = Setup()
  check("standalone: DuoCore loads without DuoQuest", t.D ~= nil and t.c.realNs.Print == nil)
end

-- Registration results
do
  for _, case in ipairs({ { 0, true }, { 1, true }, { 2, false } }) do
    local t = Setup({ prefixResult = case[1] })
    check("register: result " .. case[1], t.ch.registered == case[2])
  end
end

-- Queue: de-duplication, order, front, built at send time
do
  local t = Setup()
  local value = "old"
  t.ch:Send("a", function() return "A|" .. value end)
  t.ch:Send("b", function() return "B2|1" end)
  t.ch:Send("a", function() return "A|" .. value end)  -- same key: keeps its place
  t.ch:Send("c", function() return "C|1" end, true)    -- front
  t.ch:Send("b", function() return "B|1" end, true)    -- already queued + front: moves up
  value = "new"
  t.ch:Send("skip", function() return nil end)
  t.pump(4)
  local s = t.sent()
  check("queue: front, moved up, kept place, built at send time",
    table.concat(s, " ") == "3|B|1 3|C|1 3|A|new", table.concat(s, " "))
  check("queue: empty", t.ch:Queued() == 0)
end

-- Token bucket: a burst, then a steady rate under the client's 1/s
do
  local t = Setup()
  for i = 1, 30 do t.ch:Send("k" .. i, function() return "K|" .. i end) end
  t.pump(1)
  check("bucket: starts gently (3: a /reload doesn't reset the client's throttle)", #t.sent() == 3, #t.sent())
  t.pump(20)  -- 10 seconds
  local n = #t.sent()
  check("bucket: about 0.8/s", n >= 10 and n <= 12, n)
  check("bucket: the client never throttled", t.c.throttled == 0)
  local idle = Setup()
  idle.pump(20)  -- idle: the burst refills
  for i = 1, 10 do idle.ch:Send("k" .. i, function() return "K|" .. i end) end
  idle.pump(1)
  check("bucket: refills to a burst of 6", #idle.sent() == 6, #idle.sent())
end

-- Lists: split, snapshotted at the first part, back to back, not cut into
do
  local t = Setup()
  local items = {}
  for i = 1, 200 do items[i] = string.format("item%03d.x", i) end
  local snapshot = items
  t.ch:Send("before", function() return "P|1" end)
  t.ch:SendList("L", "L", function() return snapshot end)
  t.pump(1)  -- "before" + the first parts (more parts than one burst)
  snapshot = { "changed" }  -- changes after the first part must not mix in
  t.ch:Send("urgent", function() return "U|1" end, true)
  t.pump(30)
  local s = t.sent()
  local parts, urgentAt, lastPartAt = {}, nil, nil
  for i, m in ipairs(s) do
    if m:find("^3|L|") then parts[#parts + 1] = m lastPartAt = i end
    if m == "3|U|1" then urgentAt = i end
  end
  check("list: split into parts", #parts >= 8, #parts)
  local total = tonumber(parts[1]:match("^3|L|%d+|%d+|(%d+)|"))
  check("list: part count matches", total == #parts)
  local all = {}
  for _, m in ipairs(parts) do
    check("list: part fits", #m <= 255, #m)
    for item in m:match("^3|L|%d+|%d+|%d+|(.*)$"):gmatch("[^,]+") do all[#all + 1] = item end
  end
  check("list: every item, from the snapshot", #all == 200 and all[200] == "item200.x", #all)
  check("list: urgent message waits for the list to finish", urgentAt and urgentAt > lastPartAt, urgentAt)
  -- The other side puts it back together (fed in reverse, and with a duplicate).
  local other = Setup()
  local res
  for i = #parts, 1, -1 do
    res = other.ch:ReceiveList("Mirel", "L", (function()
      local f = {}
      for x in (parts[i]:sub(5) .. "|"):gmatch("([^|]*)|") do f[#f + 1] = x end
      return f
    end)()) or res
    if i == #parts then
      local f = {}
      for x in (parts[i]:sub(5) .. "|"):gmatch("([^|]*)|") do f[#f + 1] = x end
      check("list: a duplicate part doesn't complete it early", other.ch:ReceiveList("Mirel", "L", f) == nil)
    end
  end
  check("list: reassembles", res and #res == 200 and res[1] == "item001.x")
end

-- A list asked for again while half sent finishes first, then goes again
do
  local t = Setup()
  local items = {}
  for i = 1, 200 do items[i] = string.format("item%03d.x", i) end
  local round = 0
  local function make() round = round + 1 return items end
  t.ch:SendList("L", "L", make)
  t.pump(1)
  for _ = 1, 20 do
    t.ch:SendList("L", "L", make)  -- asked again and again while it's going out
    t.pump(2)
  end
  t.pump(100)
  local seqs, firstParts = {}, 0
  for _, m in ipairs(t.sent()) do
    local seq, part = m:match("^3|L|(%d+)|(%d+)|")
    if seq then
      seqs[seq] = (seqs[seq] or 0) + 1
      if part == "1" then firstParts = firstParts + 1 end
    end
  end
  local complete = 0
  for _, n in pairs(seqs) do if n >= 9 then complete = complete + 1 end end
  check("list again: never restarted half way (every list sent whole)", complete == firstParts, complete .. "/" .. firstParts)
  check("list again: repeats coalesce (one queued at a time)", firstParts <= 4 and round == firstParts, firstParts)
end

-- Long text: any characters, split by bytes
do
  local t = Setup()
  local text = string.rep("a|b,c~", 120)  -- 720 bytes with pipes and commas
  t.ch:SendLong("X", "X", function() return text end)
  t.pump(10)
  local s = t.sent()
  check("long: split", #s == 4, #s)
  local other = Setup()
  local res
  for _, m in ipairs(s) do
    local f = {}
    for x in (m:sub(5) .. "|"):gmatch("([^|]*)|") do f[#f + 1] = x end
    res = other.ch:ReceiveLong("Mirel", "X", f) or res
  end
  check("long: reassembled exactly", res == text)
end

-- Part bookkeeping
do
  local t = Setup()
  local ch, D = t.ch, t.D
  check("part fields: strict numbers", D.PartFields({ "1", "1.5", "2", "" }) == nil
    and D.PartFields({ "1", "1", "x", "" }) == nil and D.PartFields({ "1" }) == nil
    and D.PartFields({ "1", "1", "999999", "" }) == nil)
  check("assemble: part out of range", ch:Assemble("K", "L", 1, 3, 2, "a") == nil)
  check("assemble: too many parts", ch:Assemble("K", "L", 1, 1, 99, "a") == nil)
  check("ttl: first half held", ch:Assemble("K", "L", 5, 1, 2, "a,b") == nil)
  t.c.now = t.c.now + 91
  check("ttl: stale half dropped", ch:Assemble("K", "L", 5, 2, 2, "c") == nil)
  local r = ch:Assemble("K", "L", 5, 1, 2, "a,b")
  check("ttl: fresh pair completes", r and r[1] == "a,b" and r[2] == "c")
  check("assemble: a new seq replaces a half", ch:Assemble("K", "L", 6, 1, 2, "x") == nil
    and ch:Assemble("K", "L", 7, 2, 2, "y") == nil and ch:Assemble("K", "L", 7, 1, 2, "z")[1] == "z")
  -- Two lists in a row with part 2 of the first lost: the second isn't mixed with the first.
  local a = Setup()
  a.ch:SendList("L", "L", function() local x = {} for i = 1, 60 do x[i] = "first" .. i end return x end)
  a.pump(4)
  a.ch:SendList("L", "L", function() local x = {} for i = 1, 60 do x[i] = "second" .. i end return x end)
  a.pump(8)
  local b = Setup()
  local res
  for i, m in ipairs(a.sent()) do
    if not (m:find("^3|L|%d+|2|") and i <= 3) then  -- lose part 2 of the first list
      local f = {}
      for x in (m:sub(5) .. "|"):gmatch("([^|]*)|") do f[#f + 1] = x end
      res = b.ch:ReceiveList("Mirel", "L", f) or res
    end
  end
  check("lists: the second arrives whole, nothing from the first", res and res[1] == "second1" and #res == 60, res and res[1])
end

-- Refusals: backoff; a message that never goes is dropped; intermittent refusals are fine
do
  local t = Setup()
  t.ch:Send("x", function() return "X|1" end)
  t.ch:Send("y", function() return "Y|1" end)
  t.c.addonResult = 9
  t.pump(60)  -- 30 seconds of refusals
  check("backoff: few attempts while refused", t.c.sendAttempts <= 8, t.c.sendAttempts)
  t.pump(400)
  check("refused forever: dropped one by one", t.ch.dropped >= 1, t.ch.dropped)
  t.c.addonResult = 0
  t.ch:Send("z", function() return "Z|1" end)
  t.pump(10)
  check("refused: the queue moves again", t.sent()[#t.sent()] == "3|Z|1", t.sent()[#t.sent()])
  local u = Setup()
  for i = 1, 30 do u.ch:Send("m" .. i, function() return "M|" .. i end) end
  u.c.refuseEveryOther = true
  u.pump(400)
  check("intermittent refusals: nothing dropped", u.ch.dropped == 0 and #u.sent() == 30, u.ch.dropped .. "/" .. #u.sent())
  local th = Setup()
  th.c.addonThrows = true
  th.ch:Send("x", function() return "X|1" end)
  th.pump(2)
  check("a send that throws counts as refused", th.ch:Queued() == 1 and th.ch.fails >= 1)
end

-- Final message: goes out when disabled, costs a token, gives up after a few tries
do
  local t = Setup()
  for i = 1, 10 do t.ch:Send("x" .. i, function() return "X|" .. i end) end
  t.ch:SendFinal("B")
  t.pump(1)
  check("final: within the burst (it costs a token too)", #t.sent() == 3 and t.sent()[1] == "3|B", #t.sent())
  t.enable(false)
  t.ch:SendFinal("B")
  t.pump(10)
  local s = t.sent()
  check("final: sent while disabled", s[#s] == "3|B", s[#s])
  check("final: the rest of the queue was dropped", t.ch:Queued() == 0)
  t.c.addonResult = 9
  t.ch:SendFinal("B")
  t.pump(60)
  check("final: gives up after a few tries", t.ch.final == nil)
end

-- Too-long messages are dropped, not retried forever
do
  local t = Setup()
  t.ch:Send("big", function() return "X|" .. string.rep("a", 300) end)
  t.ch:Send("ok", function() return "Y|1" end)
  t.pump(2)
  check("too long: dropped, next one sent", t.sent()[1] == "3|Y|1" and t.ch.dropped == 1)
end

-- Receiving
do
  local t = Setup()
  local got = t.got
  check("recv: ok", t.recv("3|U|a|b") == "Mirel" and got[1].kind == "U" and got[1].fields[1] == "a"
    and got[1].fields[2] == "b" and got[1].body == "U|a|b")
  check("recv: no fields", t.recv("3|Z") == "Mirel" and #got[2].fields == 0 and got[2].body == "Z")
  check("recv: empty fields kept", t.recv("3|U|a||") and #got[3].fields == 3 and got[3].fields[3] == "")
  check("recv: older protocol in range", t.recv("2|U|x") == "Mirel")
  check("recv: kind must be followed by |", t.recv("3|Ujunk") == nil)
  check("recv: other prefix", t.ch:Receive("Other", "3|U|a", "PARTY", "Mirel-Realm") == nil)
  check("recv: whisper ignored", t.recv("3|U|a", "WHISPER") == nil)
  check("recv: guild ignored", t.recv("3|U|a", "GUILD") == nil)
  check("recv: own echo ignored", t.recv("3|U|a", "PARTY", "Tavlius-Realm") == nil)
  check("recv: own echo without realm", t.recv("3|U|a", "PARTY", "Tavlius") == nil)
  check("recv: unknown sender name", t.recv("3|U|a", "PARTY", "Unknown") == nil)
  t.enable(false)
  check("recv: nothing while disabled", t.recv("3|U|a") == nil)
  t.enable(true)
  local n = #got
  t.recv("1|U|a") t.recv("1|U|a") t.recv("4|U|a")
  check("recv: out-of-range protocol ignored", #got == n)
  check("recv: older-but-readable noted once", t.printed[1] and t.printed[1]:find("they can't see yours"), t.printed[1])
  check("recv: one notice per sender", #t.printed == 1)
  local o = Setup({ oldest = 3 })
  o.recv("1|U|a") o.recv("1|U|a") o.recv("4|U|a")
  check("recv: unreadable protocol noted once", #o.printed == 1 and o.printed[1]:find("an older Loot Split")
    and o.printed[1]:find("Mirel should update"), o.printed[1])
end

-- Handshake
do
  local t = Setup()
  check("hello: queued", t.ch:Hello(true))
  t.pump(1)
  local hello = t.sent()[1]
  local ver, session = hello:match("^3|H|([^|]+)|([0-9a-z]+)|0$")
  check("hello: version and session", ver == "2.0.0" and session == t.ch.session, hello)
  check("hello: unforced ones are rate-limited", t.ch:Hello(false) == false)
  -- Mirel says hello: we're asked for our state, and ask for his.
  t.c.now = t.c.now + 30
  t.recv("3|H|2.0.0|abc|0")
  check("hello in: new session + request", has(t.peers, "Mirel:session") and has(t.peers, "Mirel:request"))
  t.pump(1)
  local reply = t.sent()[#t.sent()]
  check("hello in: answered (to Mirel, full name)", reply == "3|H|2.0.0|" .. t.ch.session .. "|1|Mirel-Realm", reply)
  local before = #t.peers
  t.c.now = t.c.now + 31
  t.recv("3|H|2.0.0|abc|1|Dana")
  check("hello reply to someone else: no request", #t.peers == before)
  t.recv("3|H|2.0.0|abc|1|Tavlius")
  check("hello reply to me: request", #t.peers == before + 1)
  before = #t.peers
  t.recv("3|H|2.0.0|abc|1|Tavlius")
  check("hello reply to me within 30s: no second request", #t.peers == before)
  t.c.now = t.c.now + 31
  t.recv("3|H|2.0.0|abc|1|Tavlius-Realm")
  check("hello reply to me (full name): request", t.peers[#t.peers] == "Mirel:request" and #t.peers == before + 1)
  t.recv("3|H|2.0.0|xyz|1|Tavlius")
  check("new session noticed", has(t.peers, "Mirel:session") and t.ch:Peer("Mirel").session == "xyz")
  -- Our own new session: his answer to its hello asks for our state again,
  -- even within 30s of his last ask.
  before = #t.peers
  t.recv("3|H|2.0.0|xyz|1|Tavlius")
  check("same session, within 30s: no request", #t.peers == before)
  t.ch:NewSession()
  t.recv("3|H|2.0.0|xyz|1|Tavlius")
  check("after our new session: his answer's request counts", #t.peers == before + 1 and t.peers[#t.peers] == "Mirel:request")
  -- Both say hello at once: no extra answer.
  local u = Setup()
  u.ch:Hello(true)
  u.pump(1)
  local sent = #u.sent()
  u.recv("3|H|2.0.0|abc|0")
  u.pump(2)
  check("simultaneous hellos: one answer (their session is new)", #u.sent() == sent + 1)
  u.recv("3|H|2.0.0|abc|0")
  u.pump(2)
  check("simultaneous hellos: not repeated", #u.sent() == sent + 1)
  -- Junk hellos are ignored.
  local v = Setup()
  for _, junk in ipairs({ "3|H", "3|H|1.0", "3|H|1.0|ABC|0", "3|H|1.0|abc|2", "3|H|1 0|abc|0",
      "3|H|" .. string.rep("9", 20) .. "|abc|0", "3|H|1.0|" .. string.rep("a", 20) .. "|0" }) do
    v.recv(junk)
  end
  check("hello: junk ignored", #v.peers == 0, #v.peers)
end

-- Version notes
do
  local t = Setup({ version = "1.2.0" })
  t.recv("3|H|1.10.0|abc|0")
  t.recv("3|H|1.10.0|abd|0")
  check("version: newer noted once", #t.printed == 1 and t.printed[1]:find("Mirel has Loot Split 1.10.0 and you have 1.2.0"),
    t.printed[1])
  local u = Setup({ version = "1.2.0" })
  u.recv("3|H|1.1.9|abc|0")
  check("version: older noted", u.printed[1] and u.printed[1]:find("older Loot Split %(1.1.9"), u.printed[1])
  local w = Setup({ version = "1.2.0" })
  w.recv("3|H|1.2.0|abc|0")
  check("version: same says nothing", #w.printed == 0)
end

-- A copy run from source says "dev": there's no newer or older to tell, either way.
do
  local d = Setup({ version = "dev" })
  d.recv("3|H|1.2.0|abc|0")
  check("version: you on dev, no update advice", d.printed[1] ~= nil
    and d.printed[1]:find("Mirel has Loot Split 1.2.0 and you have dev.", 1, true) ~= nil
    and not d.printed[1]:find("update"), d.printed[1])
  local e = Setup({ version = "1.2.0" })
  e.recv("3|H|dev|abc|0")
  check("version: partner on dev, no update advice", e.printed[1] ~= nil
    and e.printed[1]:find("Mirel has Loot Split dev and you have 1.2.0.", 1, true) ~= nil
    and not e.printed[1]:find("update"), e.printed[1])
  check("version: a dev partner still syncs", e.ch:Peer("Mirel") ~= nil and e.ch:Peer("Mirel").session ~= nil)
end

-- Data from someone we never heard a hello from: we say hello
do
  local t = Setup()
  t.recv("3|U|a")
  t.pump(1)
  check("unknown sender: hello sent", t.sent()[1] and t.sent()[1]:find("^3|H|"))
  local n = #t.sent()
  t.recv("3|U|b")
  t.pump(4)
  check("unknown sender: not again right away", #t.sent() == n)
end

-- Bye and roster
do
  local t = Setup()
  t.recv("3|H|2.0.0|abc|1|Tavlius")
  t.recv("3|B")
  check("bye in: peer gone", has(t.peers, "Mirel:bye") and t.ch:Peer("Mirel") == nil)
  t.recv("3|H|2.0.0|abc|1|Tavlius")
  t.ch:Prune({})
  check("prune: left", has(t.peers, "Mirel:left") and t.ch:Peer("Mirel") == nil)
  t.recv("3|H|2.0.0|abc|1|Tavlius")
  t.ch:Bye()
  t.pump(2)
  check("bye out: sent, peers forgotten", t.sent()[#t.sent()] == "3|B" and t.ch:Peer("Mirel") == nil)
end

-- Names and groups
do
  local t = Setup({ realm = "Ember Hollow", group = { "Mirel", "Dana" } })
  local D = t.D
  check("key: same realm", D.Key("Mirel-Realm") == "Mirel" and D.Key("Mirel") == "Mirel")
  check("key: other realm normalized", D.Key("Mirel", "Ember Hollow") == "Mirel-EmberHollow")
  check("key: unknown", D.Key("Unknown") == nil and D.Key(nil) == nil and D.Key("") == nil)
  check("display", D.Display("Mirel-EmberHollow") == "Mirel")
  local m, complete = D.GroupMembers()
  check("members", #m == 2 and complete and m[1].unit == "party1" and m[1].key == "Mirel-EmberHollow")
  t.c.unknownMember = 2
  m, complete = D.GroupMembers()
  check("members: unreadable name flagged", #m == 1 and complete == false)
  t.c.unknownMember = nil
  t.c.inRaid = true
  t.c.group = { "Tavlius", "Mirel" }  -- in a raid you're one of the raid units
  m = D.GroupMembers()
  check("members: raid skips yourself", #m == 1 and m[1].name == "Mirel", #m)
  check("unit for key", D.UnitFor("Mirel-EmberHollow") == "raid2")
end

-- Odd version strings are cleaned (the other side would reject the hello)
do
  local t = Setup({ version = "1.2.0 beta (test)" })
  check("version: sanitized", t.ch.version == "1.2.0betatest", t.ch.version)
  t.ch:Hello(true)
  t.pump(1)
  local other = Setup()
  other.recv(t.sent()[1])
  check("version: hello accepted by the other side", other.ch:Peer("Mirel") and other.ch:Peer("Mirel").session ~= nil)
end

-- One request per peer per 30s (a new session always counts)
do
  local t = Setup()
  t.c.now = t.c.now + 100
  local requests = function()
    local n = 0
    for _, e in ipairs(t.peers) do if e == "Mirel:request" then n = n + 1 end end
    return n
  end
  for _ = 1, 60 do
    t.recv("3|H|2.0.0|same|0")
    t.pump(2)
  end
  check("requests: limited per peer", requests() <= 3, requests())
  local before = requests()
  t.recv("3|H|2.0.0|newer|0")
  check("requests: a new session always counts", requests() == before + 1)
  local replies = 0
  for _, m in ipairs(t.sent()) do if m:find("^3|H|.*|1|Mirel") then replies = replies + 1 end end
  check("requests: replies limited too", replies <= 4, replies)
end

-- Asking an unknown sender who they are: once, then again only after a while
do
  local t = Setup()
  t.recv("3|U|a")
  t.pump(1)
  local hellos = function()
    local n = 0
    for _, m in ipairs(t.sent()) do if m:find("^3|H|") then n = n + 1 end end
    return n
  end
  check("ask: hello", hellos() == 1)
  for _ = 1, 100 do t.recv("3|U|a") t.pump(1) end  -- 50s of data, still no hello from them
  check("ask: not every 20s", hellos() == 1, hellos())
  for _ = 1, 160 do t.recv("3|U|a") t.pump(1) end  -- past 2 minutes
  check("ask: again after a while", hellos() == 2, hellos())
end

-- API traps: oversized list items, Send() over a half-sent list, empty long text, part caps
do
  local t = Setup()
  t.ch:SendList("L", "L", function() return { "ok1", string.rep("x", 300), "bad,comma", "ok2" } end)
  t.pump(2)
  local m = t.sent()[1]
  check("oversized item: skipped, list still whole", m == "3|L|" .. m:match("^3|L|(%d+)") .. "|1|1|ok1,ok2", m)
  local u = Setup()
  local items = {}
  for i = 1, 200 do items[i] = string.format("item%03d.x", i) end
  u.ch:SendList("K", "L", function() return items end)
  u.pump(1)
  u.ch:Send("K", function() return "Z|after" end)
  u.pump(40)
  local parts, after = 0, false
  for _, msg in ipairs(u.sent()) do
    if msg:find("^3|L|") then parts = parts + 1 end
    if msg == "3|Z|after" then after = parts end
  end
  check("Send over a half-sent list: list finishes, then the message", parts == 10 and after == 10, parts .. "/" .. tostring(after))
  local e = Setup()
  e.ch:SendLong("X", "X", function() return "" end)
  e.pump(1)
  local f = {}
  for x in (e.sent()[1]:sub(5) .. "|"):gmatch("([^|]*)|") do f[#f + 1] = x end
  check("empty long text: one empty part", #e.sent() == 1 and Setup().ch:ReceiveLong("Mirel", "X", f) == "")
  local big = Setup()
  local many = {}
  for i = 1, 2000 do many[i] = string.format("i%04d", i) end
  big.ch:SendList("B", "L", function() return many end)
  big.pump(200)
  local total = tonumber(big.sent()[1]:match("^3|L|%d+|%d+|(%d+)|"))
  check("part cap: at most 40 parts sent", total == 40 and #big.sent() == 40, total)
  local res41, res40
  for i = 1, 41 do res41 = big.ch:Assemble("K", "L", 1, i, 41, "a") or res41 end
  for i = 1, 40 do res40 = big.ch:Assemble("K", "L", 2, i, 40, "a") or res40 end
  check("part cap: 41 parts refused on receipt, 40 fine", res41 == nil and res40 and #res40 == 40)
end

-- A list asked for again while going out is sent once more after the last ask
do
  local t = Setup()
  local items = {}
  for i = 1, 200 do items[i] = string.format("item%03d.x", i) end
  t.ch:SendList("L", "L", function() return items end)
  t.pump(1)
  for i = 1, 3 do
    t.ch:SendList("L", "L", function() local x = {} for j = 1, 200 do x[j] = "v" .. i .. "-" .. j end return x end)
    t.pump(2)
  end
  t.pump(60)
  local last = t.sent()[#t.sent()]
  check("list again: the last list carries the newest items", last and last:find("v3%-200"), last)
end

-- Bye: spaced retries, waits out a lockdown; nothing at all if registration failed
do
  local t = Setup()
  t.c.addonResult = 9
  t.ch:SendFinal("B")
  t.pump(3)  -- 1.5s
  check("bye retries: spaced (not every tick)", t.c.sendAttempts == 1, t.c.sendAttempts)
  t.pump(10)
  check("bye retries: a few", t.c.sendAttempts >= 3 and t.c.sendAttempts <= 6, t.c.sendAttempts)
  local u = Setup()
  u.c.lockdown = true
  u.ch:SendFinal("B")
  u.pump(60)
  check("bye in lockdown: waits, no tries used", (u.c.sendAttempts or 0) == 0 and u.ch.final ~= nil)
  u.c.lockdown = false
  u.pump(2)
  check("bye after lockdown: sent", u.sent()[1] == "3|B")
  local r = Setup({ prefixResult = 2 })
  r.ch:Send("x", function() return "X|1" end)
  r.ch:Hello(true)
  r.pump(10)
  check("registration failed: nothing sent", #r.sent() == 0 and r.ch:CanSend() == false)
end

-- A list re-queued with front while half sent goes to the front again afterwards
do
  local t = Setup()
  local items = {}
  for i = 1, 200 do items[i] = string.format("item%03d.x", i) end
  for i = 1, 5 do t.ch:Send("b" .. i, function() return "B|" .. i end) end
  t.ch:SendList("L", "L", function() return items end, true)
  t.pump(1)
  t.ch:SendList("L", "L", function() return items end, true)
  t.pump(60)
  local s = t.sent()
  local firstB
  for i, m in ipairs(s) do if m:find("^3|B|") then firstB = firstB or i end end
  local parts = 0
  for i = 1, (firstB or #s) - 1 do if s[i]:find("^3|L|") then parts = parts + 1 end end
  check("front list again: both lists before the backlog", parts == 20, parts)
end

-- Unreadable group size: not "everyone left"; leaving members' half lists are dropped
do
  local t = Setup({ group = { "Mirel", "Dana" } })
  t.c.secrets.groupSize, t.c.secretType = true, "number"
  local m, complete = t.D.GroupMembers()
  check("group size secret: incomplete", #m == 0 and complete == false)
  t.c.secrets.groupSize = nil
  t.ch:Assemble("Dana", "L", 1, 1, 2, "a")
  t.ch:Assemble("Mirel", "L", 1, 1, 2, "a")
  t.ch:Prune({ Mirel = true })
  check("prune: half lists of leavers dropped", t.ch.parts["Dana|L"] == nil and t.ch.parts["Mirel|L"] ~= nil)
end

-- A list already queued, asked for again at the front: it moves up.
do
  local t = Setup()
  t.ch:Send("x", function() return "X|1" end)
  t.ch:SendList("L", "L", function() return { "a", "b" } end)
  t.ch:Send("y", function() return "Y|1" end)
  t.ch:SendList("L", "L", function() return { "a", "b" } end, true)
  t.pump(6)
  local s = t.sent()
  check("list re-queued at the front moves up", s[1] and s[1]:find("^3|L|") ~= nil, s[1])
end

-- Data from someone whose hello we missed, right after our own hello: we ask
-- (say hello again) as soon as the hello limit allows, not never.
do
  local t = Setup()
  H.use(t.c)
  t.ch:Hello(true)
  t.pump(4)
  local function hellos()
    local n = 0
    for _, m in ipairs(t.sent()) do if m:find("^3|H|") then n = n + 1 end end
    return n
  end
  local n = hellos()
  t.recv("3|X|1")
  t.pump(10)
  check("missed hello: not inside the hello limit", hellos() == n)
  t.pump(40)
  check("missed hello: asked once the limit allows", hellos() == n + 1, hellos() - n)
  t.recv("3|X|2")
  t.pump(60)
  check("missed hello: asked only once", hellos() == n + 1, hellos() - n)
end

-- ...and if they say hello meanwhile, no extra ask.
do
  local t = Setup()
  H.use(t.c)
  t.ch:Hello(true)
  t.pump(4)
  local function hellos()
    local n = 0
    for _, m in ipairs(t.sent()) do if m:find("^3|H|") then n = n + 1 end end
    return n
  end
  t.recv("3|X|1")
  local n = hellos()
  t.recv("3|H|2.0.0|abc|1|Tavlius-Realm")
  t.pump(60)
  check("missed hello: their hello cancels the ask", hellos() == n, hellos() - n)
end

-- A message the client keeps refusing is dropped after two to three minutes.
do
  local t = Setup()
  H.use(t.c)
  t.c.addonResult = 9
  t.ch:Send("x", function() return "X|1" end)
  local start, gone = t.c.now, nil
  for _ = 1, 600 do
    t.pump(1)
    if t.ch.dropped > 0 or t.ch:Queued() == 0 then gone = t.c.now - start break end
  end
  check("refused message dropped after 2-3 minutes", gone and gone >= 120 and gone <= 180, gone)
end

-- Two peers whose hellos we missed: one saying hello doesn't cancel asking the other.
do
  local t = Setup({ group = { "Mirel", "Dana" } })
  H.use(t.c)
  t.ch:Hello(true)
  t.pump(4)
  local function hellos()
    local n = 0
    for _, m in ipairs(t.sent()) do if m:find("^3|H|") then n = n + 1 end end
    return n
  end
  local n = hellos()
  t.recv("3|X|1", "PARTY", "Mirel-Realm")
  t.recv("3|X|1", "PARTY", "Dana-Realm")
  t.recv("3|H|2.0.0|abc|1|Tavlius-Realm", "PARTY", "Dana-Realm")
  t.pump(60)
  check("missed hellos: still ask the other one", hellos() == n + 1, hellos() - n)
end

os.exit(H.summary("duocore") and 0 or 1)
