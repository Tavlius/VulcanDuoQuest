-- DuoCore: the partner channel shared by the duo addons (the "DuoCore" layer from
-- the Duo Addon Ideas doc). Self-contained: it only uses WoW API globals, so the
-- file can be copied as-is into the next addon (Loot Split, Town Checklist...).
--
-- What it does:
--   * handshake: hellos carry your addon version and a session id, so a partner
--     can tell a login/reload from more of the same and ask for your full state;
--     a one-time note when your versions differ; a "bye" when sync is turned off
--   * registers the prefix and picks the channel (PARTY / RAID / INSTANCE_CHAT)
--   * a throttled send queue: one entry per key (re-queuing a key replaces it
--     and keeps its place), every message built at send time so it's never stale
--   * splitting: lists (comma-separated items) and long text over the 255-byte
--     limit go out in parts, snapshotted when the first part goes, sent back to back
--   * retries with backoff when the client refuses a send (throttle, encounter
--     lockdown); a message that keeps failing is dropped so it can't block the rest
--   * receiving: group channels only, your own echo filtered, strict parsing,
--     protocol version check with a one-time note
--   * group roster helpers with cross-realm-safe names
--
-- Wire format: "<protocol>|<kind>" or "<protocol>|<kind>|<fields...>", kind = one capital letter.
--   H|<version>|<session>|<reply>[|<to>]   hello (reply 0 = "I'm here, send me your state";
--                                           1 = an answer to <to>'s hello, asking for theirs)
--   B                                      bye
--   <kind>|<seq>|<part>|<total>|<chunk>    one part of a list or long text
-- H and B are handled here; every other kind goes to your onMessage.
--
-- Using it (what DuoQuest's Sync.lua does):
--   local ch = DuoCore.NewChannel({ prefix = "LootSplt", protocol = 1, label = "Loot Split",
--     version = "1.0.0", enabled = function() return db.sync end,
--     onMessage = function(key, kind, fields, body) ... end,
--     onPeer = function(key, event) if event == "request" then SendEverything() end end })
--   ADDON_LOADED:        ch:Register()
--   every 0.5-1s:        ch:Pump(secondsSinceLastPump)
--   CHAT_MSG_ADDON:      ch:Receive(...)
--   GROUP_ROSTER_UPDATE: ch:Prune(setOfMemberKeys)  (from DuoCore.GroupMembers())
--   joined a group / your data is ready: ch:Hello(true)
--   sending:             ch:Send(key, buildFn), ch:SendList(key, kind, itemsFn), ch:SendLong(key, kind, textFn)
--   receiving parts:     ch:ReceiveList(sender, kind, fields), ch:ReceiveLong(sender, kind, fields)
-- Queue keys "H" and "H>..." are used by the handshake.
local _, ns = ...

local DuoCore = {}
ns.DuoCore = DuoCore

local MAX_MSG = 255
local CHUNK_ROOM = 225      -- bytes of payload per part (headers fit in the rest)
local BUCKET_MAX = 6        -- burst (the client allows ~10 per prefix, then 1/s)
local BUCKET_RATE = 0.8     -- messages per second after the burst (client regen is 1/s)
local RETRY_MIN, RETRY_MAX = 2, 16  -- seconds between retries after a refused send
local DROP_AFTER = 12       -- consecutive refusals of one message before it's dropped
local PARTS_TTL = 90        -- seconds before a half-received list is forgotten
local MAX_PARTS = 40
local HELLO_GAP = 20        -- unprompted hellos at most this often
local ASK_GAP = 120         -- per peer: "who are you?" hellos (data without a hello) at most this often
local REPLY_GAP = 10        -- no answering hello if ours went out this recently
local REQUEST_GAP = 30      -- per peer: requests for our state at most this often (same session)
local GROUP_CHANNELS = { PARTY = true, RAID = true, INSTANCE_CHAT = true }

---------------------------------------------------------------------------
-- Small helpers (local copies so this file stands alone)
---------------------------------------------------------------------------
local issecret = issecretvalue or function() return false end
local function plain(v)
  if issecret(v) then return nil end
  return v
end
DuoCore.plain = plain

local function clear(t) for k in pairs(t) do t[k] = nil end return t end

-- Older clients return nothing/true; newer ones a result code where 0 = success.
-- A send that throws counts as refused.
local function Sent(ok, result)
  return ok and (result == nil or result == true or result == 0)
end

local SendAddon = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local function To36(n)
  n = math.floor(n)
  if n <= 0 then return "0" end
  local out = {}
  while n > 0 do
    local d = n % 36
    table.insert(out, 1, DIGITS:sub(d + 1, d + 1))
    n = math.floor(n / 36)
  end
  return table.concat(out)
end

-- "1.10.0" is newer than "1.9.2" (by number, not by text).
function DuoCore.NewerVersion(a, b)
  local pa, pb = {}, {}
  for n in tostring(a):gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
  for n in tostring(b):gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x > y end
  end
  return false
end

local function Realm(realm)
  realm = plain(realm)
  if type(realm) ~= "string" then return nil end
  realm = realm:gsub("[%s%-]", "")
  return realm ~= "" and realm or nil
end

local myRealm
local function MyRealm()
  if not myRealm then
    local r = GetNormalizedRealmName and plain(GetNormalizedRealmName())
    if not r and GetRealmName then r = plain(GetRealmName()) end
    myRealm = Realm(r)
  end
  return myRealm
end

-- A key as it goes over the wire: always "Name-Realm", so the receiver can
-- tell two Mirels on different realms apart.
function DuoCore.Wire(key)
  if not key or key:find("-", 1, true) then return key end
  return key .. "-" .. (MyRealm() or "")
end

-- A player's key: "Name" on your realm, "Name-Realm" on another, so two
-- Mirels on different realms stay apart. nil when the name can't be read.
function DuoCore.Key(name, realm)
  name = plain(name)
  if type(name) ~= "string" or name == "" or name == UNKNOWNOBJECT or name == "Unknown" then return nil end
  local n, r = name:match("^([^%-]+)%-(.+)$")
  if n then name, realm = n, r end
  realm = Realm(realm)
  if realm and realm ~= MyRealm() then return name .. "-" .. realm end
  return name
end

-- "Mirel-Emberfall" -> "Mirel", for display.
function DuoCore.Display(key)
  return key and (key:match("^[^%-]+") or key) or "?"
end

local me
function DuoCore.Me()
  if not me then
    me = DuoCore.Key(UnitName("player"))  -- cached while readable (echo filter)
  end
  return me
end

-- Everyone else in your group: { { key, name, unit } }, plus whether every
-- name could be read (in combat names can be unreadable for a moment; don't
-- treat that as people leaving).
function DuoCore.GroupMembers()
  local list, complete = {}, true
  if not (IsInGroup and plain(IsInGroup())) then return list, true end
  local raid = IsInRaid and plain(IsInRaid())
  local n = GetNumGroupMembers and plain(GetNumGroupMembers())
  if type(n) ~= "number" then return list, false end  -- unreadable right now
  for i = 1, raid and n or math.max(0, n - 1) do
    local unit = (raid and "raid" or "party") .. i
    if not (UnitIsUnit and plain(UnitIsUnit(unit, "player"))) then
      local key = DuoCore.Key(UnitName(unit))
      if key then
        if key ~= DuoCore.Me() then list[#list + 1] = { key = key, name = DuoCore.Display(key), unit = unit } end
      else
        complete = false
      end
    end
  end
  return list, complete
end

function DuoCore.UnitFor(key)
  for _, m in ipairs((DuoCore.GroupMembers())) do
    if m.key == key then return m.unit end
  end
  return nil
end

-- Which group channel reaches your partner, or nil when you're not grouped.
function DuoCore.Distribution()
  if not IsInGroup then return nil end
  local INSTANCE = LE_PARTY_CATEGORY_INSTANCE or 2
  if plain(IsInGroup(INSTANCE)) then return "INSTANCE_CHAT" end
  if not plain(IsInGroup()) then return nil end
  if IsInRaid and plain(IsInRaid()) then return "RAID" end
  return "PARTY"
end

---------------------------------------------------------------------------
-- Channel
---------------------------------------------------------------------------
local Channel = {}
Channel.__index = Channel

-- opts:
--   prefix, protocol, oldest (oldest protocol you can still read), label (for notes)
--   version            your addon's version (sent in hellos)
--   enabled()          false while the user has sync turned off
--   onMessage(key, kind, fields, body)   every kind except H and B
--   onPeer(key, event) "session" (they logged in or reloaded), "request" (send them
--                      your full state), "bye" (they turned sync off), "left" (Prune)
--   print(msg), debug(kind, text)
function DuoCore.NewChannel(opts)
  local self = setmetatable({}, Channel)
  self.prefix = opts.prefix
  self.protocol = opts.protocol
  self.oldest = opts.oldest or opts.protocol
  self.label = opts.label or opts.prefix
  -- (sanitized: a hello with odd characters would be rejected by the other side)
  self.version = tostring(opts.version or "0"):gsub("[^%w%.%-]", ""):sub(1, 16)
  if self.version == "" then self.version = "0" end
  self.enabled = opts.enabled or function() return true end
  self.onMessage = opts.onMessage
  self.onPeer = opts.onPeer or function() end
  self.print = opts.print or print
  self.debug = opts.debug or function() end
  self.queue = {}        -- ordered keys
  self.pending = {}      -- [key] = entry
  self.tokens = 3  -- (a /reload doesn't reset the client's own throttle: start gently)
  self.blockedUntil = -math.huge
  self.fails = 0
  self.registered = false
  self.noticed = {}      -- [key] = true once told about a protocol mismatch
  self.versionNoted = {} -- [key] = true once told about an addon version difference
  self.parts = {}        -- [sender|kind] = { seq, total, got, chunks, at }
  self.peers = {}        -- [key] = { session, version, heard }
  self.lastHello = -math.huge
  self.seq = math.random(1, 9000)  -- random start: a reload's lists can't mix with old halves
  self.askFor = {}  -- [key] = true: sent data without a hello; we'll ask once HELLO_GAP allows (askAt)
  self:NewSession()
  self.sentCount, self.dropped = 0, 0
  return self
end

function Channel:Register()
  if not RegisterPrefix then return false end
  -- 0 = success, 1 = already registered (also fine); older clients return true/nil.
  local ok, result = pcall(RegisterPrefix, self.prefix)
  self.registered = ok and (result == nil or result == true or result == 0 or result == 1) or false
  return self.registered
end

function Channel:CanSend()
  return self.registered and SendAddon ~= nil and self.enabled() and DuoCore.Distribution() ~= nil
end

local function InProgress(entry)
  return entry and entry.chunks ~= nil
end

local function Insert(self, key, front)
  if front then
    -- Never cut into a list that's half sent: its parts must go back to back.
    local at = InProgress(self.pending[self.queue[1]]) and 2 or 1
    table.insert(self.queue, math.min(at, #self.queue + 1), key)
  else
    self.queue[#self.queue + 1] = key
  end
end

local function MoveUp(self, key)
  for i = 2, #self.queue do
    if self.queue[i] == key then
      table.remove(self.queue, i)
      Insert(self, key, true)
      return
    end
  end
end

-- Queue a message. build() returns the body ("<kind>|...", without the
-- protocol number) or nil to skip. Re-queuing a key replaces it in place;
-- front = true puts it (or moves it) ahead of the backlog.
function Channel:Send(key, build, front)
  local entry = self.pending[key]
  if InProgress(entry) then
    entry.again = { build = build }  -- a list half sent under this key: after it
    return
  end
  if entry then
    if front then MoveUp(self, key) end
  else
    Insert(self, key, front)
  end
  self.pending[key] = { build = build }
end

-- Queue a split payload. make() is called when the first part goes out.
local function SendParts(self, key, kind, make, long, front)
  local entry = self.pending[key]
  if InProgress(entry) then
    -- Half sent: let it finish (restarting could starve it), then send again.
    entry.again = { kind = kind, make = make, long = long, front = front }
    return
  end
  if entry then
    if front then MoveUp(self, key) end
  else
    Insert(self, key, front)
  end
  self.pending[key] = { kind = kind, make = make, long = long }
end

-- A list: itemsFn() returns strings without commas or pipes.
function Channel:SendList(key, kind, itemsFn, front)
  SendParts(self, key, kind, itemsFn, false, front)
end

-- Long text: textFn() returns any string (pipes allowed), split by bytes.
function Channel:SendLong(key, kind, textFn, front)
  SendParts(self, key, kind, textFn, true, front)
end

-- One message that goes out even after sync is turned off (retried a few times).
function Channel:SendFinal(body)
  self.final = { body = body, tries = 0 }
end

function Channel:Queued() return #self.queue end
function Channel:IsQueued(key) return self.pending[key] ~= nil end

function Channel:Clear()
  clear(self.queue)
  clear(self.pending)
  self.fails = 0
end

-- Sends one body right now. Returns true on success.
function Channel:Raw(body)
  local dist = DuoCore.Distribution()
  if not (dist and SendAddon) then return false end
  local msg = self.protocol .. "|" .. body
  if #msg > MAX_MSG then
    self.debug("drop", "too long (" .. #msg .. " bytes): " .. msg:sub(1, 40))
    self.dropped = self.dropped + 1
    return true  -- drop it; retrying can't help
  end
  local sent = Sent(pcall(SendAddon, self.prefix, msg, dist))
  if sent then
    self.sentCount = self.sentCount + 1
    self.debug("send", msg)
  end
  return sent
end

local function ChunkItems(self, items)
  local chunks, cur, size = {}, {}, 0
  for _, item in ipairs(items) do
    item = tostring(item)
    if #item >= CHUNK_ROOM or item:find("[,|]") then
      self.debug("drop", "list item too long or has a comma/pipe: " .. item:sub(1, 30))
      item = nil
    end
    if item and size + #item + 1 > CHUNK_ROOM and #cur > 0 then
      chunks[#chunks + 1] = table.concat(cur, ",")
      cur, size = {}, 0
    end
    if item then
      cur[#cur + 1] = item
      size = size + #item + 1
    end
  end
  chunks[#chunks + 1] = table.concat(cur, ",")  -- an empty list is one empty part
  return chunks
end

local function ChunkText(text)
  local chunks = {}
  for i = 1, math.max(1, #text), CHUNK_ROOM do chunks[#chunks + 1] = text:sub(i, i + CHUNK_ROOM - 1) end
  return chunks
end

-- The next body for an entry, and whether more parts follow it.
local function NextBody(self, entry)
  if entry.build then return entry.build() end
  if not entry.chunks then
    local data = entry.make()
    entry.chunks = entry.long and ChunkText(tostring(data or "")) or ChunkItems(self, data or {})
    if #entry.chunks > MAX_PARTS then
      self.debug("drop", "too many parts (" .. #entry.chunks .. "), sending the first " .. MAX_PARTS)
      while #entry.chunks > MAX_PARTS do table.remove(entry.chunks) end
    end
    self.seq = self.seq % 9999 + 1
    entry.seq, entry.idx = self.seq, 0
  end
  local i = entry.idx + 1
  return string.format("%s|%d|%d|%d|%s", entry.kind, entry.seq, i, #entry.chunks, entry.chunks[i]),
    i < #entry.chunks
end

-- Removes the head entry; a split payload re-queued while it was going out
-- goes to the back as a fresh one.
local function Done(self, key, entry)
  if self.pending[key] ~= entry then return end
  table.remove(self.queue, 1)
  self.pending[key] = nil
  local again = entry.again
  if again then
    Insert(self, key, again.front)
    self.pending[key] = { build = again.build, kind = again.kind, make = again.make, long = again.long }
  end
end

-- Called on every tick with the seconds since the last one.
function Channel:Pump(dt)
  self.tokens = math.min(BUCKET_MAX, self.tokens + BUCKET_RATE * (dt or 0))
  local now = GetTime()
  if self.askAt and now >= self.askAt and next(self.askFor) then
    self.askAt = nil
    clear(self.askFor)
    self:Hello(false)
  end
  local locked = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and plain(C_ChatInfo.InChatMessagingLockdown())
  if self.final and not locked and now >= self.blockedUntil and self.tokens >= 1 then
    if self:Raw(self.final.body) then
      self.tokens = self.tokens - 1
      self.final = nil
    else
      self.final.tries = self.final.tries + 1
      if self.final.tries >= 5 or not DuoCore.Distribution() then self.final = nil end
      self.blockedUntil = now + RETRY_MIN
    end
  end
  if #self.queue == 0 then return end
  if not self:CanSend() then
    -- Out of group or sync off: nothing queued can ever reach anyone.
    if not DuoCore.Distribution() or not self.enabled() then self:Clear() end
    return
  end
  if now < self.blockedUntil then return end
  -- Newer clients say when addon messages are blocked (boss encounters): wait
  -- quietly instead of using up the refusals that drop a message.
  if locked then return end
  while self.tokens >= 1 and #self.queue > 0 do
    local key = self.queue[1]
    local entry = self.pending[key]
    local ok, body, more = pcall(NextBody, self, entry)
    if not ok then
      self.debug("error", tostring(body))
      body = nil
    end
    if body == nil then
      entry.again = nil
      Done(self, key, entry)
    elseif self:Raw(body) then
      self.tokens = self.tokens - 1
      self.fails = 0
      if entry.chunks then entry.idx = entry.idx + 1 end
      if not more then Done(self, key, entry) end
    else
      -- Throttled, or blocked (e.g. during a boss encounter): back off and retry.
      -- A message refused this many times in a row is dropped so it can't
      -- block everything behind it (the caller's periodic state heals it).
      self.fails = self.fails + 1
      if self.fails >= DROP_AFTER then
        self.debug("drop", "refused " .. self.fails .. " times: " .. tostring(body):sub(1, 40))
        self.dropped = self.dropped + 1
        self.fails = 0
        entry.again = nil
        Done(self, key, entry)
      end
      self.blockedUntil = now + math.min(RETRY_MAX, RETRY_MIN * 2 ^ math.min(self.fails, 3))
      return
    end
  end
end

-- "<seq>|<part>|<total>|<chunk>" -> numbers and the chunk; nil if malformed.
-- (Long text may contain pipes, so the chunk is everything after the third field.)
function DuoCore.PartFields(fields)
  local seq, part, total = fields[1], fields[2], fields[3]
  if not (seq and part and total) then return nil end
  if not (seq:match("^%d+$") and part:match("^%d+$") and total:match("^%d+$")) or #seq > 5 or #total > 3 then
    return nil
  end
  return tonumber(seq), tonumber(part), tonumber(total), table.concat(fields, "|", 4)
end

-- Feeds one part; returns all chunks in order once every part is in.
function Channel:Assemble(sender, kind, seq, part, total, chunk)
  if part < 1 or part > total or total > MAX_PARTS then return nil end
  local key = sender .. "|" .. kind
  local p = self.parts[key]
  local now = GetTime()
  if not p or p.seq ~= seq or p.total ~= total or now - p.at > PARTS_TTL then
    p = { seq = seq, total = total, got = 0, chunks = {}, at = now }
    self.parts[key] = p
  end
  if not p.chunks[part] then
    p.chunks[part] = chunk
    p.got = p.got + 1
  end
  if p.got < p.total then return nil end
  self.parts[key] = nil
  return p.chunks
end

-- A list message's fields -> the whole item array once complete (else nil).
function Channel:ReceiveList(sender, kind, fields)
  local seq, part, total, chunk = DuoCore.PartFields(fields)
  if not seq then return nil end
  local chunks = self:Assemble(sender, kind, seq, part, total, chunk)
  if not chunks then return nil end
  local items = {}
  for i = 1, #chunks do
    for item in chunks[i]:gmatch("[^,]+") do items[#items + 1] = item end
  end
  return items
end

-- A long-text message's fields -> the whole text once complete (else nil).
function Channel:ReceiveLong(sender, kind, fields)
  local seq, part, total, chunk = DuoCore.PartFields(fields)
  if not seq then return nil end
  local chunks = self:Assemble(sender, kind, seq, part, total, chunk)
  return chunks and table.concat(chunks) or nil
end

---------------------------------------------------------------------------
-- Handshake
---------------------------------------------------------------------------
-- Say hello ("I'm here: send me your state"). Unforced hellos are rate-limited.
-- Returns true if one was queued.
function Channel:Hello(force)
  if not self:CanSend() then return false end
  if not force and GetTime() - self.lastHello < HELLO_GAP then return false end
  self.lastHello = GetTime()
  self:Send("H", function()
    return string.format("H|%s|%s|0", self.version, self.session)
  end, true)
  return true
end

-- A fresh session id: partners treat what follows as a fresh start (a reload,
-- or sync turned back on), not as a stream of changes.
function Channel:NewSession()
  self.session = To36(math.floor((time and time() or 0) % 1679616) * 1296 + math.random(0, 1295))
  -- (partners answer the new session's hello: their answer's request for
  -- ours must not be held back by one from before)
  for _, peer in pairs(self.peers or {}) do peer.requestAt = nil end
end

-- Turn sync off: tell partners, forget them.
function Channel:Bye()
  self:Clear()
  self:SendFinal("B")
  clear(self.peers)
end

-- Forget peers who aren't in `keys` (a set) any more.
function Channel:Prune(keys)
  for key in pairs(self.peers) do
    if not keys[key] then
      self.peers[key] = nil
      self.onPeer(key, "left")
    end
  end
  for partKey in pairs(self.parts) do
    if not keys[partKey:match("^(.*)|") or ""] then self.parts[partKey] = nil end
  end
end

function Channel:Peer(key) return self.peers[key] end

local function OnHello(self, key, fields)
  local version, session, reply, to = fields[1], fields[2], fields[3], fields[4]
  if not (version and version:match("^[%w%.%-]+$") and #version <= 16 and session and session:match("^[0-9a-z]+$")
      and #session <= 12 and (reply == "0" or reply == "1")) then
    return
  end
  local peer = self.peers[key]
  if not peer then
    peer = {}
    self.peers[key] = peer
  end
  peer.version = version
  local newSession = peer.session ~= session
  if not self.versionNoted[key] and version ~= self.version then
    self.versionNoted[key] = true
    local name = DuoCore.Display(key)
    local function release(v) return tostring(v):match("^%d+%.%d+") ~= nil end
    if not release(version) or not release(self.version) then
      -- (A copy run from source says "dev": no newer or older to tell.)
      self.print(string.format("%s has %s %s and you have %s.", name, self.label, version, self.version))
    elseif DuoCore.NewerVersion(version, self.version) then
      self.print(string.format("%s has %s %s and you have %s: update yours when you can.", name, self.label,
        version, self.version))
    else
      self.print(string.format("%s has an older %s (%s, you have %s): ask them to update.", name, self.label,
        version, self.version))
    end
  end
  if newSession then
    peer.session = session
    self.onPeer(key, "session")
  end
  self.askFor[key] = nil  -- (they've just said hello)
  local forMe = reply == "0" or DuoCore.Key(to) == DuoCore.Me()
  if not forMe then return end
  -- One request per peer per REQUEST_GAP (a new session always counts), so a
  -- chatty or broken client can't keep us resending everything.
  local now = GetTime()
  if not newSession and peer.requestAt and now - peer.requestAt < REQUEST_GAP then return end
  peer.requestAt = now
  self.onPeer(key, "request")
  -- They just arrived: ask for theirs too, unless our own hello (which asks
  -- the same thing) just went out.
  -- (A new session always gets the question: our earlier hello may have
  -- reached them before they could answer, e.g. their log was still loading.)
  if reply == "0" and (newSession or now - self.lastHello > REPLY_GAP) and self:CanSend() then
    self:Send("H>" .. key, function()
      return string.format("H|%s|%s|1|%s", self.version, self.session, DuoCore.Wire(key))
    end, true)
  end
end

-- Entry point for CHAT_MSG_ADDON(prefix, text, channel, sender).
-- Returns the sender's key when the message was ours to handle.
function Channel:Receive(prefix, text, channel, sender)
  prefix, text, channel = plain(prefix), plain(text), plain(channel)
  if prefix ~= self.prefix or type(text) ~= "string" or not GROUP_CHANNELS[channel] then return nil end
  if not self.enabled() then return nil end
  local key = DuoCore.Key(sender)
  if not key or key == DuoCore.Me() then return nil end
  local verText, kind, rest = text:match("^(%d+)|(%u)|(.*)$")
  if not verText then
    verText, kind = text:match("^(%d+)|(%u)$")
    rest = ""
  end
  local ver = tonumber(verText)
  if not ver or #verText > 4 then return nil end
  if ver < self.protocol and ver >= self.oldest and not self.noticed[key] then
    -- We read theirs; their older version can't read ours.
    self.noticed[key] = true
    self.print(string.format("%s runs an older %s: you see their data, but they can't see yours until they update.",
      DuoCore.Display(key), self.label))
  end
  if ver < self.oldest or ver > self.protocol then
    if not self.noticed[key] then
      self.noticed[key] = true
      self.print(string.format("%s runs %s %s that can't talk to yours, so sync is off between you. "
        .. "%s should update.", DuoCore.Display(key), ver > self.protocol and "a newer" or "an older", self.label,
        ver > self.protocol and "You" or DuoCore.Display(key)))
    end
    return nil
  end
  local fields = {}
  if rest ~= "" then
    for field in (rest .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = field end
  end
  self.debug("recv", DuoCore.Display(key) .. ": " .. text)
  if kind == "H" then
    OnHello(self, key, fields)
  elseif kind == "B" then
    -- (even from someone we hadn't heard from yet: the bye says they're there, with sync off)
    self.peers[key] = nil
    self.onPeer(key, "bye")
  else
    local peer = self.peers[key]
    if not peer then
      peer = {}
      self.peers[key] = peer
    end
    if not peer.session and GetTime() - (peer.askedAt or -math.huge) >= ASK_GAP then
      -- Data from someone whose hello we never saw (they reloaded while we
      -- missed it, or we did): ask everyone for their state. (Right after our
      -- own hello, as soon as HELLO_GAP allows: Pump sends it.)
      peer.askedAt = GetTime()
      if not self:Hello(false) then
        self.askFor[key] = true
        self.askAt = self.lastHello + HELLO_GAP
      end
    end
    if self.onMessage then self.onMessage(key, kind, fields, kind .. (rest ~= "" and ("|" .. rest) or "")) end
  end
  return key
end
