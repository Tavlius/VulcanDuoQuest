-- Mock WoW client for DuoQuest tests. Several clients can run side by side (you
-- and your partner): each has its own globals, clock, quest log and addon copy,
-- and H.use() swaps them in before anything runs. H.deliver()/H.run() carry
-- addon messages between clients like the party channel does (including the
-- echo back to the sender), and the client-side addon-message throttle is
-- modeled (10 per prefix, then 1 per second) so tests can prove we stay under it.
local H = {}
local ADDON_DIR = assert(os.getenv("DQ_DIR"), "DQ_DIR unset: run tests/run.sh")
local rawtype = type

-- Everything in _G before any client exists. print and type are replaced per
-- client, so they're swapped like the rest.
local BASE = {}
for k in pairs(_G) do BASE[k] = true end
BASE.print, BASE.type = nil, nil
H.print = print  -- the real one, for debugging tests

-- A secret value: arithmetic, comparisons, concatenation, indexing and calls
-- throw. (Lua 5.1 can't make == or a truthiness test throw, so code that
-- compares a raw API result before plain() isn't caught here.)
local SECRET = newproxy(true)
do
  local mt = getmetatable(SECRET)
  local function boom() error("secret value touched", 2) end
  for _, k in ipairs({ "__index", "__newindex", "__lt", "__le", "__add", "__sub", "__mul", "__div", "__mod",
      "__unm", "__concat", "__len", "__call" }) do mt[k] = boom end
  mt.__tostring = function() return "<secret>" end
end
H.SECRET = SECRET

local active  -- the client whose globals are in _G now

function H.use(c)
  if active == c then return end
  if active then
    active.globals = {}
    for k, v in pairs(_G) do
      if not BASE[k] then active.globals[k] = v end
    end
  end
  for k in pairs(_G) do
    if not BASE[k] then _G[k] = nil end
  end
  for k, v in pairs(c.globals) do _G[k] = v end
  active = c
end

local function readToc()
  local files, version = {}, nil
  if not io.open(ADDON_DIR .. "VulcanDuoQuest.toc", "r") then return files, version end
  for line in io.lines(ADDON_DIR .. "VulcanDuoQuest.toc") do
    if line:match("%.lua%s*$") then files[#files + 1] = line:match("^%s*(.-)%s*$") end
    version = version or line:match("^## Version:%s*(%S+)")
  end
  return files, version
end

-- Real widget methods the tests don't need to model: no-ops. Any other
-- method is an error, so a typo or a method the client lacks fails a test.
local NOOP_METHODS = {}
for _, m in ipairs({ "SetFrameStrata", "SetClampedToScreen", "SetMovable", "EnableMouse",
    "RegisterForDrag", "RegisterForClicks", "SetBackdrop", "SetBackdropColor", "SetBackdropBorderColor",
    "SetJustifyH", "SetJustifyV", "SetWordWrap", "SetAllPoints", "SetColorTexture", "SetUserPlaced",
    "SetNormalTexture", "SetPushedTexture", "SetHighlightTexture", "SetTexture", "SetAlpha", "SetScale",
    "SetToplevel", "SetFrameLevel" }) do NOOP_METHODS[m] = true end

-- A fake UI object: real methods for what the tests read, no-ops for the rest.
local function NewObject(c, kind, name)
  local o = { kind = kind, scripts = {}, events = {}, unitEvents = {}, shown = true, fontstrings = {}, w = 0, h = 0,
    enabled = true, left = 100, top = 700 }
  setmetatable(o, { __index = function(_, k)
    if NOOP_METHODS[k] then return function() end end
    if rawtype(k) == "string" and k:match("^%u") then error("unknown widget method " .. k, 2) end
    return nil  -- unknown fields are nil, like on real frames
  end })
  function o:SetMotionScriptsWhileDisabled(v) self.motionWhileDisabled = v end
  function o:SetTextColor(r, g, b) self.color = { r, g, b } end
  function o:RegisterEvent(e)
    if c.unknownEvents and c.unknownEvents[e] then error("unknown event " .. e) end
    self.events[e] = true
  end
  function o:RegisterUnitEvent(e, unit)
    if c.noUnitEvents then error("no RegisterUnitEvent") end
    self.unitEvents[e] = unit
  end
  function o:SetScript(n, fn) self.scripts[n] = fn end
  function o:GetScript(n) return self.scripts[n] end
  function o:CreateFontString()
    local fs = NewObject(c, "FontString")
    fs.text = ""
    table.insert(self.fontstrings, fs)
    return fs
  end
  function o:CreateTexture() return NewObject(c, "Texture") end
  -- (Like the client: OnShow/OnHide fire when the state changes.)
  function o:Show()
    local was = self.shown
    self.shown = true
    if not was and self.scripts.OnShow then self.scripts.OnShow(self) end
  end
  function o:Hide()
    local was = self.shown
    self.shown = false
    if was and self.scripts.OnHide then self.scripts.OnHide(self) end
  end
  function o:SetShown(v) if v then self:Show() else self:Hide() end end
  function o:IsShown() return self.shown end
  function o:SetEnabled(v) self.enabled = v and true or false end
  function o:IsEnabled() return self.enabled end
  function o:SetText(t) rawset(self, "text", t) end
  function o:GetText() return rawget(self, "text") end
  function o:SetSize(w, h) self.w, self.h = w, h end
  function o:SetWidth(w) self.w = w end
  function o:SetHeight(h) self.h = h end
  function o:GetHeight() return self.h end
  function o:GetStringWidth()
    return #(tostring(rawget(self, "text") or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) * 6
  end
  -- Like the client: setting a point replaces that same point's anchor and keeps the others.
  function o:SetPoint(point, ...)
    self.points = self.points or {}
    for i = #self.points, 1, -1 do
      if self.points[i][1] == point then table.remove(self.points, i) end
    end
    self.points[#self.points + 1] = { point, ... }
  end
  function o:ClearAllPoints() self.points = {} end
  function o:GetLeft() return self.left end
  function o:GetTop() return self.top end
  function o:StartMoving() self.moving = true self.moves = (self.moves or 0) + 1 end
  -- Like the client: a moved frame ends up anchored by its nearest screen corner.
  function o:StopMovingOrSizing()
    self.moving = false
    self.points = { { "BOTTOMRIGHT", nil, "BOTTOMRIGHT", -10, 10 } }
  end
  -- Interacting with a client's UI makes that client the active one.
  function o:Click(button)
    H.use(c)
    if self.scripts.OnClick and self.enabled then self.scripts.OnClick(self, button or "LeftButton") end
  end
  function o:EnableMouseWheel(on) self.wheel = on and true or false end
  -- The mouse wheel over this object: only an object that takes the wheel gets it.
  function o:Wheel(delta)
    H.use(c)
    if self.wheel and self.scripts.OnMouseWheel then self.scripts.OnMouseWheel(self, delta) return true end
    return false
  end
  function o:Hover()
    H.use(c)
    if self.scripts.OnEnter then self.scripts.OnEnter(self) end
  end
  function o:Drag(left, top)
    H.use(c)
    if self.scripts.OnDragStart then self.scripts.OnDragStart(self) end
    if c.ui.moving then c.ui.left, c.ui.top = left, top end  -- (only a frame that started moving moves)
    if self.scripts.OnDragStop then self.scripts.OnDragStop(self) end
  end
  if name then c.globals[name] = o _G[name] = o end
  return o
end

local bootCount = 0

-- opts: name, realm (partner realm returned by UnitName), classic, classicBare (classic without any
--   C_QuestLog extras), noPushable,
--   secrets = { player=, members=, log=, resting=, range=, info=, objectives=, distance=, unitOnQuest=,
--     pushable=, subzone=, taxi=, combat=, groupSize=, zone=, dead=, visible=, map= } (those APIs
--     return secret values), secretType,
--   saved (VulcanDuoQuestCharDB from an earlier session), unknownEvents, prefixResult, noUnitEvents,
--   badTemplates, noSpellNames, classicEmptyComplete (classic GetQuestLogTitle reports quests without
--   objectives as complete, as some clients may),
--   myRealm (this client's realm, default "Realm"), noLogIndex (no C_QuestLog.GetLogIndexForQuestID),
--   files (load only these addon files, e.g. { "DuoCore.lua" }), tocVersion (what the client reports as
--   the .toc's Version)
function H.boot(opts)
  opts = opts or {}
  bootCount = bootCount + 1
  local c = {
    name = opts.name or "Tavlius", opts = opts, now = 1000, wall = 1700000000 + bootCount * 7919,
    log = {},          -- ordered entries: { header = "Elwynn" } or quest tables (see c.addQuest)
    collapsed = {},    -- [header] = true: its quests are hidden from GetInfo (like the real client)
    completed = {},    -- [questID] = true: turned in
    group = {},        -- other members' names (party1..)
    inGroup = false, inRaid = false, instanceGroup = false, resting = false, combat = false, onTaxi = false,
    zone = "Elwynn Forest", subzone = "Goldshire", dead = false,
    realmName = opts.myRealm or "Realm",
    rangeUnknown = {}, -- [unit] = true: the game can't tell the distance (checked = false)
    distance = {},     -- [unit] = yards
    mapID = {},        -- [unit] = map ID (default 1429, Elwynn)
    prefixes = {},     -- registered addon-message prefixes
    printed = {}, addonSent = {}, delivered = 0, pushed = {}, sounds = {}, errorsFrame = {},
    unitOnQuest = {},  -- [unit] = { [questID] = bool } (game data without DuoQuest)
    inRange = {},      -- [unit] = false to be out of range
    selected = 0, frames = {}, globals = {},
    bucket = 10, bucketAt = 1000, throttled = 0,
    secrets = opts.secrets or {}, secretType = opts.secretType,
  }
  H.use(c)
  local G = _G
  local function sec(kind, v) if c.secrets[kind] then return SECRET end return v end

  G.issecretvalue = function(v) return rawequal(v, SECRET) end
  -- Real secrets keep their Lua type (a secret number is still a "number"), so
  -- type() checks alone don't filter them: c.secretType sets what type() says.
  G.type = function(v)
    if rawequal(v, SECRET) then return c.secretType or "userdata" end
    return rawtype(v)
  end
  G.print = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
    c.printed[#c.printed + 1] = table.concat(t, " ")
  end
  G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
  G.GetTime = function() return c.now end
  G.time = function() return math.floor(c.wall) end  -- whole seconds, like the real client
  G.GetBuildInfo = function() return "1.60.1", "69893", "Sep 2026", 16001 end
  G.GetNormalizedRealmName = function() return c.realmName end
  G.UNKNOWNOBJECT = "Unknown"
  local files, version = readToc()
  G.C_AddOns = { GetAddOnMetadata = function(_, field) if field == "Version" then return opts.tocVersion or version end end }
  G.UnitName = function(u)
    if u == "player" then return sec("player", c.name) end
    local i = tonumber((u or ""):match("^party(%d)$") or (u or ""):match("^raid(%d+)$"))
    if i and c.group[i] then
      if c.unknownMember == i then return "Unknown" end
      return sec("members", c.group[i]), opts.realm
    end
    return nil
  end
  local function Who(u)
    if u == "player" then return c.name end
    local i = tonumber((u or ""):match("^party(%d)$") or (u or ""):match("^raid(%d+)$"))
    return i and c.group[i]
  end
  G.UnitIsUnit = function(a, b) return Who(a) ~= nil and Who(a) == Who(b) end
  G.IsInGroup = function(category)
    if category == 2 then return c.instanceGroup end
    if category == 1 then return c.inGroup end
    return c.inGroup or c.instanceGroup
  end
  G.IsInRaid = function() return c.inRaid end
  -- In a party c.group lists the others; in a raid it lists everyone (you included), like raid1..N.
  G.GetNumGroupMembers = function()
    if c.secrets.groupSize then return SECRET end
    if not (c.inGroup or c.instanceGroup) then return 0 end
    return c.inRaid and #c.group or (#c.group + 1)
  end
  G.LE_PARTY_CATEGORY_HOME, G.LE_PARTY_CATEGORY_INSTANCE = 1, 2
  G.IsResting = function() return sec("resting", c.resting) end
  -- (Only the left button is held while dragging; c.mouseUp: it was let go.)
  G.IsMouseButtonDown = function(button) return button == "LeftButton" and not c.mouseUp end
  G.InCombatLockdown = function() return sec("combat", c.combat) end
  G.UnitAffectingCombat = function() return sec("combat", c.combat) end
  G.UnitOnTaxi = function() return sec("taxi", c.onTaxi) end
  G.GetRealZoneText = function() return sec("zone", c.zone) end
  G.GetSubZoneText = function() return sec("subzone", c.subzone) end
  G.UnitIsDeadOrGhost = function() return sec("dead", c.dead) end
  G.UnitIsConnected = function(u) return not (c.offline and c.offline[u]) end
  -- Distances: c.distance[unit] in yards; c.inRange[unit] = false means 100 yards;
  -- default 10. c.rangeUnknown[unit]: the game can't tell (other instance).
  -- An offline member (c.offline[unit]) has no position at all.
  local function Gone(u) return c.rangeUnknown[u] or (c.offline and c.offline[u]) end
  local function Yards(u)
    if c.distance[u] then return c.distance[u] end
    if c.inRange[u] == false then return 100 end
    return 10
  end
  G.UnitDistanceSquared = function(u)
    if c.secrets.distance then return SECRET, SECRET end
    if Gone(u) then return 0, false end
    return Yards(u) ^ 2, true
  end
  -- On the 12.x client UnitInRange returns secret values (c.secrets.range).
  G.UnitInRange = function(u)
    if c.secrets.range then return SECRET, SECRET end
    if Gone(u) then return false, false end
    return Yards(u) <= 40, true
  end
  -- (nil for someone in another instance, like the real client)
  G.UnitIsVisible = function(u)
    if c.secrets.visible then return SECRET end
    return not Gone(u) and Yards(u) <= 100
  end
  G.IsInInstance = function() return c.inInstance or false end
  G.C_Map = { GetBestMapForUnit = function(u)
    if c.secrets.map and u ~= "player" then return SECRET end
    if c.mapID[u] then return c.mapID[u] end
    if u:find("^raid") then return nil end  -- (the real client only answers for the player and party)
    return (not Gone(u)) and 1429 or nil
  end }
  local spellNames = { [8690] = "Hearthstone", [556] = "Astral Recall", [133] = "Fireball",
    [94719] = "The Innkeeper's Daughter", [171253] = "Garrison Hearthstone" }
  G.C_Spell = (not opts.noSpellNames) and { GetSpellName = function(id) return spellNames[id] end } or nil

  -- Quest log: the modern API unless opts.classic. Like the real client,
  -- quests under a collapsed header are left out of the GetInfo loop.
  local function Visible()
    local out, hidden = {}, false
    for _, e in ipairs(c.log) do
      if e.header then
        hidden = c.collapsed[e.header] or false
        out[#out + 1] = e
      elseif not hidden then
        out[#out + 1] = e
      end
    end
    return out
  end
  local function Find(id)
    for i, e in ipairs(c.log) do if e.id == id then return e, i end end
  end
  local function Complete(e)
    if e.failed then return false end
    if e.complete ~= nil then return e.complete end
    for _, o in ipairs(e.objs) do if o.have < o.need then return false end end
    return true  -- no objectives (delivery / talk-to quests): ready from the start
  end
  local function Objectives(id)
    local e = Find(id)
    if not e then return {} end
    local out = {}
    for i, o in ipairs(e.objs) do
      out[i] = { text = sec("objectives", o.text or (o.have .. "/" .. o.need .. " " .. o.label)),
        type = o.type or "monster", finished = sec("objectives", o.have >= o.need),
        numFulfilled = sec("objectives", o.have), numRequired = sec("objectives", o.need) }
    end
    return out
  end
  if not opts.classic then
    G.C_QuestLog = {
      GetNumQuestLogEntries = function()
        local quests = 0
        for _, e in ipairs(c.log) do if not e.header then quests = quests + 1 end end
        return sec("log", #Visible()), quests
      end,
      GetInfo = function(i)
        local e = Visible()[i]
        if not e then return nil end
        if e.header then return { title = e.header, isHeader = true, questID = 0 } end
        return { title = sec("info", e.title), questID = sec("info", e.id), level = sec("info", e.level),
          isHeader = false, isHidden = e.hidden or false, isTask = e.task or false, isBounty = e.bounty or false }
      end,
      GetQuestObjectives = Objectives,
      IsComplete = function(id) local e = Find(id) return e and Complete(e) or false end,
      ReadyForTurnIn = function(id) local e = Find(id) return e and Complete(e) or false end,
      GetQuestDifficultyLevel = function(id) local e = Find(id) return e and e.level or 0 end,
      IsFailed = function(id) local e = Find(id) return e and e.failed or false end,
      IsPushableQuest = (not opts.noPushable) and function(id)
        local e = Find(id)
        return sec("pushable", e and e.pushable ~= false or false)
      end or nil,
      IsQuestTask = function(id) local e = Find(id) return e and e.task or false end,
      IsQuestBounty = function(id) local e = Find(id) return e and e.bounty or false end,
      IsQuestFlaggedCompleted = function(id) return c.completed[id] or false end,
      IsOnQuest = function(id) return Find(id) ~= nil end,
      GetLogIndexForQuestID = (not opts.noLogIndex) and function(id)
        for i, e in ipairs(Visible()) do if e.id == id then return i end end
        return nil
      end or nil,
      IsUnitOnQuest = function(unit, id)
        return sec("unitOnQuest", c.unitOnQuest[unit] and c.unitOnQuest[unit][id] or false)
      end,
      GetSelectedQuest = function() return c.selected end,
      SetSelectedQuest = function(id) c.selected = id end,
      GetTitleForQuestID = function(id) local e = Find(id) return e and e.title or (c.titleCache or {})[id] end,
    }
    G.GetQuestProgressBarPercent = function(id) local e = Find(id) return e and e.barPct or 0 end
    G.QuestLogPushQuest = function(index)
      if c.pushFails then error("protected") end
      local id = c.selected
      if index then id = Visible()[index] and Visible()[index].id end
      c.pushed[#c.pushed + 1] = id
    end
  else
    -- Classic era: the old loop functions (which, like the real client, skip
    -- quests under a collapsed header), plus the few C_QuestLog functions it
    -- has (none of them with opts.classicBare).
    G.C_QuestLog = { IsQuestFlaggedCompleted = function(id) return c.completed[id] or false end }
    if not opts.classicBare then
      G.C_QuestLog.IsOnQuest = function(id) return Find(id) ~= nil end
      G.C_QuestLog.GetQuestObjectives = Objectives
      G.C_QuestLog.GetQuestInfo = function(id) local e = Find(id) return e and e.title or nil end
    end
    G.GetNumQuestLogEntries = function() local n = #Visible() return n, n end
    G.GetQuestLogTitle = function(i)
      local e = Visible()[i]
      if not e then return nil end
      if e.header then return e.header, 0, nil, true end
      local complete = nil
      if e.failed then complete = -1
      elseif (#e.objs > 0 or opts.classicEmptyComplete) and Complete(e) then complete = 1 end
      return e.title, e.level, nil, false, false, complete, nil, e.id
    end
    G.GetNumQuestLeaderBoards = function(i) return #(Visible()[i].objs or {}) end
    G.GetQuestLogLeaderBoard = function(j, i)
      local o = Visible()[i].objs[j]
      return o.label .. ": " .. o.have .. "/" .. o.need, "monster", o.have >= o.need
    end
    G.GetQuestLogIndexByID = function(id)
      for i, e in ipairs(Visible()) do if e.id == id then return i end end
      return 0
    end
    G.GetQuestLogSelection = function() return c.selectedIndex or 0 end
    G.SelectQuestLogEntry = function(i)
      c.selectedIndex = i
      c.selected = Visible()[i] and Visible()[i].id or 0
    end
    G.QuestLogPushQuest = function() c.pushed[#c.pushed + 1] = c.selected end
  end

  G.C_ChatInfo = {
    SendAddonMessage = function(prefix, msg, ch)
      if #msg > 255 then error("message too long") end
      c.sendAttempts = (c.sendAttempts or 0) + 1
      if c.addonThrows then error("addon messages blocked") end
      if c.addonResult and c.addonResult ~= 0 then return c.addonResult end
      if c.sendReturnsTrue then  -- older clients: true/false instead of a result code
        c.addonSent[#c.addonSent + 1] = { prefix = prefix, msg = msg, ch = ch, at = c.now }
        return true
      end
      if c.refuseEveryOther and c.sendAttempts % 2 == 1 then return 9 end
      -- The client's own throttle: 10 per prefix, refilling 1 per second.
      c.bucket = math.min(10, c.bucket + (c.now - c.bucketAt))
      c.bucketAt = c.now
      if c.bucket < 1 then
        c.throttled = c.throttled + 1
        return 3
      end
      c.bucket = c.bucket - 1
      c.addonSent[#c.addonSent + 1] = { prefix = prefix, msg = msg, ch = ch, at = c.now }
      return 0
    end,
    RegisterAddonMessagePrefix = function(prefix)
      c.prefixes[prefix] = true
      return opts.prefixResult or 0
    end,
    InChatMessagingLockdown = function() return c.lockdown or false end,
  }
  G.SOUNDKIT = { RAID_WARNING = 8959, TELL_MESSAGE = 3081, IG_QUEST_LIST_OPEN = 875 }
  G.PlaySound = function(id) c.sounds[#c.sounds + 1] = id end
  G.UIErrorsFrame = { AddMessage = function(_, msg) c.errorsFrame[#c.errorsFrame + 1] = msg end }
  G.Enum = { PlayerInteractionType = { TaxiNode = 6, Merchant = 5 } }
  G.BackdropTemplateMixin = {}
  G.UIParent = {}
  G.UISpecialFrames = {}
  G.SlashCmdList = {}
  c.tooltip = {}
  G.GameTooltip = {
    SetOwner = function(_, owner) c.tooltip = {} c.tooltipOwner = owner end,
    AddLine = function(_, t) c.tooltip[#c.tooltip + 1] = t end,
    Show = function() c.tooltip.shown = true end,
    Hide = function() c.tooltip.shown = false end,
    IsOwned = function(_, f) return c.tooltip.shown == true and c.tooltipOwner == f end,
  }
  G.CreateFrame = function(kind, name, _, template)
    if template and c.badTemplates and c.badTemplates[template] then error("unknown template " .. template) end
    local f = NewObject(c, kind, name)
    c.frames[#c.frames + 1] = f
    return f
  end
  G.C_Timer = { NewTicker = function(_, fn) c.ticker = fn end }
  c.unknownEvents = opts.unknownEvents
  c.noUnitEvents = opts.noUnitEvents
  c.badTemplates = opts.badTemplates
  if opts.saved then G.VulcanDuoQuestCharDB = opts.saved end
  if opts.marker then G.VulcanDuoQuestDB = opts.marker end  -- (the saved-data safety marker, Persist.lua)

  local ns = {}
  for _, file in ipairs(opts.files or files) do
    local chunk = assert(loadfile(ADDON_DIR .. file))
    chunk("VulcanDuoQuest", ns)
  end
  -- Tests reach into the addon through c.ns; calling a function through it
  -- switches to this client first (its clock, group, quest log).
  c.realNs = ns
  c.ns = setmetatable({}, {
    __index = function(_, k)
      local v = ns[k]
      if rawtype(v) == "function" then
        return function(...) H.use(c) return v(...) end
      end
      return v
    end,
    __newindex = ns,
  })
  c.ui = G.VulcanDuoQuestFrame

  -- Delivers an event to every frame that registered it (unit events only for
  -- their unit), like the real client.
  function c.fire(event, ...)
    H.use(c)
    local unit = ...
    for _, f in ipairs(c.frames) do
      if f.scripts.OnEvent and (f.events[event] or (f.unitEvents[event] and f.unitEvents[event] == unit)) then
        f.scripts.OnEvent(f, event, ...)
      end
    end
  end
  -- n ticks of 0.5s each.
  function c.tick(n)
    H.use(c)
    for _ = 1, n or 1 do
      c.now = c.now + 0.5
      c.wall = c.wall + 0.5
      c.ticker()
    end
  end
  function c.slash(s) H.use(c) _G.SlashCmdList.VULCANDUOQUEST(s) end
  -- Login like the real client: the log fires QUEST_LOG_UPDATE once loaded.
  -- reload = true: a /reload (PLAYER_ENTERING_WORLD says so).
  function c.login(reload)
    c.fire("ADDON_LOADED", "VulcanDuoQuest")
    c.fire("PLAYER_LOGIN")
    c.fire("PLAYER_ENTERING_WORLD", not reload, reload and true or false)
    c.fire("LOADING_SCREEN_DISABLED")
    c.tick(1)
    c.fire("QUEST_LOG_UPDATE")
    c.tick(2)
  end
  -- q: { id, title, level, objs = { { label, have, need, type } }, pushable, failed, task, hidden, complete,
  --      barPct }
  function c.addQuest(q, quiet)
    q.objs = q.objs or {}
    q.level = q.level or 10
    q.title = q.title or ("Quest " .. q.id)
    c.log[#c.log + 1] = q
    if not quiet then
      -- The classic client passes (logIndex, questID); the modern one (questID).
      if opts.classic then c.fire("QUEST_ACCEPTED", #c.log, q.id) else c.fire("QUEST_ACCEPTED", q.id) end
      c.fire("QUEST_LOG_UPDATE")
    end
    return q
  end
  function c.quest(id) return (Find(id)) end
  function c.progress(id, objIndex, have)
    Find(id).objs[objIndex].have = have
    c.fire("QUEST_LOG_UPDATE")
  end
  -- lag: the game's "completed" flag catches up later (it can trail the event).
  function c.removeQuest(id, turnedIn, lag)
    local _, i = Find(id)
    table.remove(c.log, i)
    if turnedIn then
      if not lag then c.completed[id] = true end
      c.fire("QUEST_TURNED_IN", id, 100, 0)
    end
    c.fire("QUEST_REMOVED", id)
    c.fire("QUEST_LOG_UPDATE")
  end
  function c.setGroup(names)
    c.group = names
    c.inGroup = #names > 0
    c.fire("GROUP_ROSTER_UPDATE")
  end
  function c.printedMatch(pat, from)
    for i = from or 1, #c.printed do
      if c.printed[i]:find(pat) then return c.printed[i] end
    end
    return nil
  end
  function c.printedCount(pat, from)
    local n = 0
    for i = from or 1, #c.printed do if c.printed[i]:find(pat) then n = n + 1 end end
    return n
  end
  function c.sentMatching(pat, from)
    local n = 0
    for i = from or 1, #c.addonSent do if c.addonSent[i].msg:find(pat) then n = n + 1 end end
    return n
  end
  function c.errors()
    local out = {}
    for _, p in ipairs(c.printed) do if p:find("error in") then out[#out + 1] = p end end
    return out
  end
  function c.saved()
    H.use(c)
    return _G.VulcanDuoQuestCharDB
  end
  -- Logging out fires PLAYER_LOGOUT before the client writes both saved files.
  function c.logout()
    c.fire("PLAYER_LOGOUT")
    H.use(c)
    return { char = _G.VulcanDuoQuestCharDB, marker = _G.VulcanDuoQuestDB }
  end
  local function strip(t) return (tostring(t or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
  -- Visible rows of the window as plain text ("left || right"), one string per row.
  function c.rowTexts()
    local out = {}
    for _, r in ipairs(c.realNs.rows) do
      if r.shown then
        local right = r.share.shown and (r.share.enabled and "[Share]" or "[Share-off]") or strip(r.right.text)
        out[#out + 1] = strip(r.text.text):gsub("^%s+", "") .. " || " .. right
      end
    end
    return out
  end
  function c.windowText() return table.concat(c.rowTexts(), "\n") end
  function c.statusText() return strip(c.realNs.statusText.text) end
  function c.rowFor(pat)
    for _, r in ipairs(c.realNs.rows) do
      if r.shown and strip(r.text.text):find(pat) then return r end
    end
  end
  return c
end

-- Deliver every message `from` has sent since last time to each client in
-- `to`, and (like the real party channel) back to `from` itself.
function H.deliver(from, to, noEcho)
  local start = from.delivered + 1
  from.delivered = #from.addonSent
  for i = start, #from.addonSent do
    local m = from.addonSent[i]
    for _, c in ipairs(to) do
      -- (the client only delivers prefixes the receiver registered)
      if c ~= from and c.prefixes[m.prefix] and not (c.dropFrom and c.dropFrom(m)) then
        c.fire("CHAT_MSG_ADDON", m.prefix, m.msg, m.ch, from.name .. "-" .. from.realmName)
      end
    end
    if not noEcho then from.fire("CHAT_MSG_ADDON", m.prefix, m.msg, m.ch, from.name .. "-" .. from.realmName) end
  end
end

-- Advance every client n ticks, delivering messages after each tick.
function H.run(clients, n)
  for _ = 1, n or 1 do
    for _, c in ipairs(clients) do c.tick(1) end
    for _, c in ipairs(clients) do H.deliver(c, clients) end
  end
end

-- Every client's addon messages refused for `seconds` (both sides in a long
-- boss encounter), then normal again.
function H.outage(clients, seconds)
  for _, c in ipairs(clients) do c.addonResult = 9 end
  H.run(clients, seconds * 2)
  for _, c in ipairs(clients) do c.addonResult = 0 end
end

-- The same character after a /reload (or, with relog = true, logging back in
-- `after` seconds later): saved settings round-tripped, the same quest log,
-- group and place, and (for a reload) the client's clock and addon-message
-- throttle carried over, like the real client.
function H.reload(old, relog, after)
  local function Copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = Copy(v) end
    return out
  end
  local c = H.boot({ name = old.name, saved = Copy(old.saved()), classic = old.opts.classic, myRealm = old.realmName,
    realm = old.opts.realm, noPushable = old.opts.noPushable, noLogIndex = old.opts.noLogIndex,
    classicBare = old.opts.classicBare, classicEmptyComplete = old.opts.classicEmptyComplete })
  c.log, c.collapsed, c.completed = old.log, old.collapsed, old.completed
  c.group, c.inGroup, c.inRaid, c.instanceGroup = old.group, old.inGroup, old.inRaid, old.instanceGroup
  c.zone, c.subzone, c.resting = old.zone, old.subzone, old.resting
  -- (where everyone is, and your own state, don't change with a reload)
  for _, k in ipairs({ "distance", "inRange", "rangeUnknown", "mapID", "unitOnQuest" }) do c[k] = Copy(old[k]) end
  c.offline, c.dead, c.onTaxi, c.combat, c.lockdown = Copy(old.offline), old.dead, old.onTaxi, old.combat, old.lockdown
  c.secrets = Copy(old.secrets)
  c.inInstance, c.titleCache, c.unknownMember = old.inInstance, Copy(old.titleCache), old.unknownMember
  c.now, c.wall = old.now + (after or 0), old.wall + (after or 0)
  if not relog then c.bucket, c.bucketAt = old.bucket, old.bucketAt end
  c.login(not relog)
  return c
end

-- Two clients, not yet logged in.
function H.duo(optsA, optsB)
  local a = H.boot(optsA or { name = "Tavlius" })
  local b = H.boot(optsB or { name = "Mirel" })
  return a, b
end

local passed, failed = 0, 0
function H.check(name, cond, detail)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    io.write("FAIL " .. name .. (detail ~= nil and ("  [" .. tostring(detail) .. "]") or "") .. "\n")
  end
end
function H.summary(label)
  io.write(string.format("%s%d passed, %d failed\n", label and (label .. ": ") or "", passed, failed))
  return failed == 0
end
return H
