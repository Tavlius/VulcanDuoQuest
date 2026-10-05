-- DuoQuest: the window. Sections:
--   <Partner> doesn't have   your quests they lack, with a Share button
--   You don't have           their quests you lack
--   Both on                  shared quests, objectives side by side (you | them)
--   Already turned in        quests one of you has turned in (collapsed)
local _, ns = ...

local WIDTH = 340
local ROW = 15
local PAD = 8
local MAX_ROWS = 24
local HEADER = 42  -- title + status line
local FOOTER = 14  -- "scroll for N more"
local SHARE_W = 50

local GOLD, GREY, GREEN, BLUE, ORANGE, RED = "|cffffd100", "|cff9d9d9d", "|cff60ff60", "|cff66ccff", "|cffffa040",
  "|cffff6060"

-- CreateFrame with a template, falling back to a plain frame if this client
-- doesn't have the template.
local function Make(kind, parent, template)
  local ok, f = pcall(CreateFrame, kind, nil, parent, template)
  if ok and f then return f, true end
  return CreateFrame(kind, nil, parent), false
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local frame = CreateFrame("Frame", "VulcanDuoQuestFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
ns.frame = frame
frame:SetSize(WIDTH, 120)
frame:SetFrameStrata("MEDIUM")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:EnableMouseWheel(true)
frame:RegisterForDrag("LeftButton")
frame:Hide()
if frame.SetBackdrop then
  frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  frame:SetBackdropColor(0, 0, 0, 0.8)
  frame:SetBackdropBorderColor(ns.ACCENT[1], ns.ACCENT[2], ns.ACCENT[3], 0.9)
end
-- Not in UISpecialFrames: it's a display you keep up while grouped, and Esc
-- (closing bags or the map) shouldn't hide it. The close button and /dq do.

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", PAD, -PAD)
title:SetText("DuoQuest")
title:SetTextColor(ns.ACCENT[1], ns.ACCENT[2], ns.ACCENT[3])

local status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
status:SetPoint("TOPLEFT", PAD, -PAD - 16)
status:SetJustifyH("LEFT")
status:SetWidth(WIDTH - PAD * 2 - 20)  -- clear of the close button
if status.SetWordWrap then status:SetWordWrap(false) end
ns.statusText = status

local more = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
more:SetPoint("BOTTOMRIGHT", -PAD, PAD - 2)
more:SetJustifyH("RIGHT")
ns.moreText = more

local close, templated = Make("Button", frame, "UIPanelCloseButton")
if not templated then
  close:SetSize(20, 20)
  close:SetText("x")
end
close:SetPoint("TOPRIGHT", 2, 2)
close:SetScript("OnClick", function() ns.SetShown(false) end)

local dragging = false
local function StartDrag()
  if not ns.DB.locked then
    frame:StartMoving()
    dragging = true
  end
end
local function StopDrag()
  dragging = false
  frame:StopMovingOrSizing()
  if frame.SetUserPlaced then frame:SetUserPlaced(false) end  -- we save the spot ourselves
  -- Saved by the top-left corner, so a growing list extends downward.
  local left, top = frame:GetLeft(), frame:GetTop()
  if left and top then
    ns.DB.point = { "TOPLEFT", "BOTTOMLEFT", math.floor(left + 0.5), math.floor(top + 0.5) }
    -- (The client re-anchors a dragged frame by its nearest screen corner;
    -- pin it by its top left again so a growing list extends downward.)
    ns.PlaceFrame()
  end
end
frame:SetScript("OnDragStart", StartDrag)
frame:SetScript("OnDragStop", StopDrag)
-- A drag that never gets its stop (the row it started on was hidden by a
-- refresh, or the window hid): end it, so the window doesn't stick to the mouse.
frame:SetScript("OnHide", function() if dragging then StopDrag() end end)
ns.Listen("TICK", function()
  if dragging and IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then StopDrag() end
end)

function ns.PlaceFrame()
  local p = ns.DB.point
  frame:ClearAllPoints()
  frame:SetPoint(p[1] or "TOPLEFT", UIParent, p[2] or "TOPLEFT", p[3] or 0, p[4] or 0)
end

---------------------------------------------------------------------------
-- Rows (pooled)
---------------------------------------------------------------------------
local rows = {}
ns.rows = rows

local function ShowTooltip(owner, lines)
  if not GameTooltip or not lines then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  for i, line in ipairs(lines) do
    if i == 1 then GameTooltip:AddLine(line, 1, 1, 1) else GameTooltip:AddLine(line, 0.85, 0.85, 0.85, true) end
  end
  GameTooltip:Show()
end
local function HideTooltip() if GameTooltip then GameTooltip:Hide() end end

local function Row(i)
  if rows[i] then return rows[i] end
  local r = CreateFrame("Button", nil, frame)
  r:SetHeight(ROW)
  r:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -HEADER - (i - 1) * ROW)
  r:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -HEADER - (i - 1) * ROW)
  r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  r:RegisterForDrag("LeftButton")
  r:SetScript("OnDragStart", StartDrag)  -- drag the window from anywhere
  r:SetScript("OnDragStop", StopDrag)
  local hl = r:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)
  r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.text:SetPoint("LEFT", 0, 0)
  r.text:SetJustifyH("LEFT")
  if r.text.SetWordWrap then r.text:SetWordWrap(false) end
  r.right = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.right:SetPoint("RIGHT", 0, 0)
  r.right:SetJustifyH("RIGHT")
  r.share = Make("Button", r, "UIPanelButtonTemplate")
  r.share:SetSize(SHARE_W, ROW)
  r.share:SetPoint("RIGHT", 0, 0)
  r.share:SetText("Share")
  r.share:SetScript("OnClick", function(self)
    if self.questID then ns.ShareCommand(self.questID) end
  end)
  -- Disabled buttons only show tooltips with this on (says why Share is off).
  if r.share.SetMotionScriptsWhileDisabled then r.share:SetMotionScriptsWhileDisabled(true) end
  r.share:SetScript("OnEnter", function(self) ShowTooltip(self, self.tip) end)
  r.share:SetScript("OnLeave", HideTooltip)
  r:SetScript("OnEnter", function(self) ShowTooltip(self, self.tip) end)
  r:SetScript("OnLeave", HideTooltip)
  r:SetScript("OnClick", function(self, button)
    if self.section and button ~= "RightButton" then
      ns.DB.collapsed[self.section] = not ns.DB.collapsed[self.section]  -- (false, not nil: defaults would undo it)
      ns.Refresh(true)
      ns.Redraw()  -- (at once: the header is under the mouse)
    elseif self.questID and button == "RightButton" then
      ns.ToggleIgnore(self.questID)  -- (its redraw refreshes the tooltip under the mouse: see Layout)
    end
  end)
  r:SetScript("OnMouseWheel", function(_, delta) ns.Scroll(delta) end)
  r:EnableMouseWheel(true)
  rows[i] = r
  return r
end

---------------------------------------------------------------------------
-- Content
---------------------------------------------------------------------------
-- getter: who has to get a quest that can't be shared ("they", "you"; nil: nobody).
local function QuestTip(e, partnerName, getter)
  local tip = { ns.QuestName(e) .. ((e.level or 0) > 0 and (" [" .. e.level .. "]") or "") }
  local function Objs(owner, rec)
    if not rec then return end
    if ns.HasFlag(rec.flags, ns.F_FAILED) then
      tip[#tip + 1] = owner .. ": " .. RED .. "failed|r"
    elseif ns.HasFlag(rec.flags, ns.F_COMPLETE) then
      tip[#tip + 1] = owner .. ": " .. GREEN .. "ready to turn in|r"
    end
    for _, o in ipairs(rec.objs or {}) do
      tip[#tip + 1] = owner .. ": " .. (o.label ~= "" and (o.label .. " ") or "") .. ns.ObjText(o)
    end
  end
  Objs("You", e.mine)
  Objs(partnerName, e.theirs)
  if e.how == "giver" and getter then
    tip[#tip + 1] = ORANGE .. "Can't be shared: " .. (getter == "they" and (partnerName .. " has to get it")
      or "get it yourself") .. " (usually from the quest giver).|r"
  end
  if ns.IsIgnored(e.id) then tip[#tip + 1] = GREY .. "Ignored: no warnings, notes or /dq share. Right-click to undo.|r"
  else tip[#tip + 1] = GREY .. "Right-click: ignore in warnings, notes and /dq share (e.g. a class quest).|r" end
  return tip
end

local function StateText(rec)
  if not rec then return GREY .. "?|r" end
  if ns.HasFlag(rec.flags, ns.F_FAILED) then return RED .. "failed|r" end
  if ns.HasFlag(rec.flags, ns.F_COMPLETE) then return GREEN .. "ready|r" end
  if rec.stub then return GREY .. "?|r" end
  local done, total = 0, #(rec.objs or {})
  for _, o in ipairs(rec.objs or {}) do if o.done then done = done + 1 end end
  if total == 0 then return GREY .. "-|r" end
  if total == 1 then return ns.ObjText(rec.objs[1]) end  -- (one objective: its own progress, e.g. 6/10)
  return done .. "/" .. total .. " obj"
end

local function Name(e)
  local n = ns.QuestName(e)
  if ns.IsIgnored(e.id) then return GREY .. n .. " (ignored)|r" end
  return n
end

-- Builds the row list: { text, right, share, shareOff, shareTip, tip, section, questID }
function ns.BuildRows(focus, view)
  local out = {}
  local name = focus.name
  local inRange = ns.InRange(focus.unit)
  local apart = ns.Apart(focus)  -- (offline, or in another instance: no share can reach them)
  local offline = ns.Offline(focus)
  local function Header(key, text, count)
    local collapsed = ns.DB.collapsed[key]
    out[#out + 1] = { text = GOLD .. (collapsed and "+ " or "- ") .. text .. " (" .. count .. ")|r", section = key }
    return not collapsed
  end
  if #view.theyNeed > 0 then
    -- (Not sure yet while their turned-in list is on its way.)
    local label = (view.unsure or view.checking) and (name .. " may not have") or (name .. " doesn't have")
    if Header("theyNeed", label, #view.theyNeed) then
      for _, e in ipairs(view.theyNeed) do
        local row = { text = "  " .. Name(e), tip = QuestTip(e, name, "they"), questID = e.id }
        if e.how == "share" or e.how == "maybe" then
          row.share = e.id
          row.shareOff = inRange == false or apart
          row.shareTip = row.shareOff and { "Share", (offline and (name .. " is offline."))
            or (name .. (apart and " isn't here" or " is too far away") .. " to receive it.") }
            or { "Share", "Asks the game to share this quest with your group." }
        elseif e.how == "failed" then row.right = RED .. "yours failed|r"
        else row.right = ORANGE .. "can't share|r" end
        out[#out + 1] = row
      end
    end
  end
  if #view.iNeed > 0 and Header("iNeed", "You don't have", #view.iNeed) then
    for _, e in ipairs(view.iNeed) do
      local right = (e.how == "share" or e.how == "maybe") and (BLUE .. "ask " .. name .. "|r")
        or (e.how == "failed" and (RED .. name .. "'s failed|r") or (ORANGE .. "can't share|r"))
      out[#out + 1] = { text = "  " .. Name(e), right = right, tip = QuestTip(e, name, "you"), questID = e.id }
    end
  end
  if #view.both > 0 and Header("both", view.live and ("Both on (you | " .. name .. ")") or "Both on", #view.both) then
    for _, e in ipairs(view.both) do
      local right = view.live and (StateText(e.mine) .. GREY .. " | |r" .. StateText(e.theirs)) or StateText(e.mine)
      out[#out + 1] = { text = "  " .. Name(e), right = right, tip = QuestTip(e, name), questID = e.id }
      if ns.DB.objectives and view.live then
        local mine, theirs = e.mine.objs or {}, (e.theirs and e.theirs.objs) or {}
        local bothReady = ns.HasFlag(e.mine.flags, ns.F_COMPLETE)
          and e.theirs and ns.HasFlag(e.theirs.flags, ns.F_COMPLETE)
        -- (one objective: the quest's own row already shows it)
        if not bothReady and math.max(#mine, #theirs) > 1 then
          for i = 1, math.max(#mine, #theirs) do
            local o = mine[i] or theirs[i]
            local label = (o and o.label ~= "") and o.label or ("Objective " .. i)
            out[#out + 1] = { text = "      " .. GREY .. label .. "|r",
              right = ns.ObjText(mine[i]) .. GREY .. " | |r" .. ns.ObjText(theirs[i]), tip = QuestTip(e, name),
              questID = e.id }
          end
        end
      end
    end
  end
  local function DoneSection(key, label, list)
    if #list > 0 and Header(key, label, #list) then
      for _, e in ipairs(list) do
        out[#out + 1] = { text = "  " .. GREY .. ns.QuestName(e) .. "|r", tip = QuestTip(e, name), questID = e.id }
      end
    end
  end
  DoneSection("theyDid", name .. " already turned in", view.theyDid)
  DoneSection("iDid", "You already turned in", view.iDid)
  if #out == 0 then
    out[1] = { text = GREY .. (view.live and "No quests in either log." or "No quests to compare yet.") .. "|r" }
  end
  return out
end

local function StatusLine(focus)  -- (also /dq status's reason when there's no live data: ns.StatusLine)
  if not focus then
    if #(ns.DuoCore.GroupMembers()) > 0 then
      return GREY .. "Nobody here runs DuoQuest yet (/dq partner <name>).|r"
    end
    return GREY .. "Not in a group.|r"
  end
  local p = focus.data
  if not ns.DB.sync then
    return ORANGE .. "Sync is off (/dq sync).|r " .. GREY .. "Game info only.|r"
  end
  if focus.unit and UnitIsConnected and ns.plain(UnitIsConnected(focus.unit)) == false then
    return ORANGE .. focus.name .. " is offline.|r"
  end
  if p and p.synced and (p.doneIn or ns.IsStale(p)) then
    local ago = GetTime() - p.heard
    if ns.IsStale(p) then return ORANGE .. focus.name .. ": no update for " .. ns.Ago(ago) .. "|r" end
    local pending = ns.channel and ns.channel:Queued() or 0
    return GREEN .. "Synced with " .. focus.name .. "|r" .. GREY .. " (" .. ns.Ago(ago) .. " ago"
      .. (pending > 0 and (", sending " .. pending) or "") .. ")|r"
  end
  if p and p.resync and ns.IsStale(p) then
    return ORANGE .. focus.name .. ": no update for " .. ns.Ago(GetTime() - p.heard) .. "|r"
  end
  if p then return GREY .. (p.resync and "Resyncing with " or "Syncing with ") .. focus.name .. "...|r" end
  if ns.channel and ns.channel.noticed[focus.key] then
    return ORANGE .. focus.name .. "'s DuoQuest can't talk to yours: update.|r"
  end
  if ns.syncOff[focus.key] then
    return GREY .. focus.name .. " turned DuoQuest sync off: game info only.|r"
  end
  if ns.groupedAt and GetTime() - ns.groupedAt < 15 then
    return GREY .. "Waiting for " .. focus.name .. "'s DuoQuest...|r"
  end
  return GREY .. focus.name .. " doesn't run DuoQuest: game info only.|r"
end
ns.StatusLine = StatusLine

---------------------------------------------------------------------------
-- Layout and scrolling
---------------------------------------------------------------------------
local content = {}
local offset = 0

local function Layout()
  local visible = math.min(#content, MAX_ROWS)
  offset = math.max(0, math.min(offset, #content - visible))
  for i = 1, visible do
    local data = content[i + offset]
    local r = Row(i)
    r.text:SetText(data.text or "")
    r.right:SetText(data.right or "")
    r.right:SetShown(data.share == nil)
    r.share.questID = data.share
    r.share.tip = data.shareTip
    r.share:SetShown(data.share ~= nil)
    if r.share.SetEnabled then r.share:SetEnabled(not data.shareOff) end
    r.tip = data.tip
    r.section = data.section
    r.questID = data.questID
    -- Leave room for the right-hand column so long titles don't run under it.
    local rightW = data.share and SHARE_W or ((r.right.GetStringWidth and r.right:GetStringWidth()) or 60)
    r.text:SetWidth(math.max(60, WIDTH - PAD * 2 - rightW - 6))
    r:Show()
    -- (A tooltip open on this row shows what the row says now: the list may
    -- have moved under the mouse, or his progress changed.)
    if GameTooltip and GameTooltip.IsOwned then
      if GameTooltip:IsOwned(r) then
        if r.tip then ShowTooltip(r, r.tip) else HideTooltip() end
      elseif GameTooltip:IsOwned(r.share) then
        if r.share:IsShown() then ShowTooltip(r.share, r.share.tip) else HideTooltip() end
      end
    end
  end
  for i = visible + 1, #rows do
    if GameTooltip and GameTooltip.IsOwned and (GameTooltip:IsOwned(rows[i]) or GameTooltip:IsOwned(rows[i].share)) then
      HideTooltip()
    end
    rows[i]:Hide()
  end
  local hidden = #content - visible
  local below = #content - visible - offset
  more:SetText(hidden > 0 and (below > 0 and ("scroll for " .. below .. " more") or "scroll up for more") or "")
  frame:SetHeight(HEADER + visible * ROW + PAD + (hidden > 0 and FOOTER or 0))
  ns.scrollInfo = { offset = offset, total = #content, visible = visible }
end

function ns.Scroll(delta)
  offset = offset - (delta or 0) * 3
  Layout()
end
frame:SetScript("OnMouseWheel", function(_, delta) ns.Scroll(delta) end)

local dirty = true
local lastRefresh = -math.huge

function ns.Refresh(now)
  dirty = true
  if now then lastRefresh = -math.huge end
end

local function Redraw()
  if not ns.DB then return end
  local focus = ns.FocusPartner()
  -- Up when there's someone to compare with (a pug or raid without your
  -- partner doesn't count), or always with /dq solo on.
  local wanted = ns.DB.shown and (focus ~= nil or not ns.DB.hideSolo)
  frame:SetShown(wanted)
  if not wanted then return end
  status:SetText(StatusLine(focus))
  content = focus and ns.BuildRows(focus, ns.Compare(focus)) or {}
  Layout()
end
ns.Redraw = Redraw

ns.Listen("TICK", function(count)
  -- Redraw on changes (at most twice a second), and every 5s for the "ago" clock.
  if (dirty and GetTime() - lastRefresh >= 0.5) or count % 10 == 0 then
    dirty = false
    lastRefresh = GetTime()
    Redraw()
  end
end)

for _, event in ipairs({ "MINE_CHANGED", "PARTNER_CHANGED", "ROSTER" }) do
  ns.Listen(event, function() ns.Refresh() end)
end
-- Your partner walking in or out of sharing range turns Share on and off;
-- party quest changes matter when they don't run DuoQuest.
-- (Only your partner's; in a raid these fire for everyone. A secret unit: can't tell, so redraw.)
local function ForFocus(unit)
  unit = ns.plain(unit)
  if not unit then return true end
  local focus = ns.FocusPartner()
  return focus ~= nil and focus.unit == unit
end
ns.On("UNIT_IN_RANGE_UPDATE", function(unit) if ForFocus(unit) then ns.Refresh() end end)
ns.On("UNIT_QUEST_LOG_CHANGED", function(unit) if ForFocus(unit) then ns.Refresh() end end)

-- When you joined the group (for the "waiting for their DuoQuest" line).
local wasGrouped = false
ns.Listen("ROSTER", function()
  local grouped = #(ns.DuoCore.GroupMembers()) > 0
  if grouped and not wasGrouped then ns.groupedAt = GetTime() end
  wasGrouped = grouped
end)
ns.Listen("LOGIN", function() ns.groupedAt = GetTime() end)  -- (also after a /reload)

function ns.SetShown(show)
  ns.DB.shown = show and true or false
  if show and ns.DB.hideSolo and #(ns.DuoCore.GroupMembers()) == 0 then
    ns.Print("the window shows up when you're in a group (/dq solo shows it always; /dq hide keeps it off).")
  elseif show and ns.DB.hideSolo and not ns.FocusPartner() then
    ns.Print("nobody in this group to compare with: /dq partner <name> picks someone (/dq solo shows it always).")
  elseif not show and not ns.hideTold then
    ns.hideTold = true  -- (once a session: the key binding toggles it often)
    ns.Print("window hidden: /dq brings it back.")
  end
  ns.Refresh(true)
  Redraw()
end

-- /dq, the key binding and the addon menu: by what you can see. (While it's
-- waiting for a group it's wanted but not showing: that says so, rather
-- than switching it off for good.)
function ns.ToggleWindow()
  if ns.DB.shown and not frame:IsShown() then
    ns.SetShown(true)
  else
    ns.SetShown(not ns.DB.shown)
  end
end

function ns.ToggleIgnore(id)
  local link = ns.QuestLink(id, ns.TitleFor(id))
  if ns.DB.ignored[id] then
    ns.DB.ignored[id] = nil
    ns.Print("no longer ignoring " .. link .. ".")
  else
    ns.DB.ignored[id] = true
    ns.Print("ignoring " .. link .. " in warnings, notes and /dq share (/dq ignore " .. id .. " or a right-click undoes it).")
  end
  ns.Refresh(true)
  ns.Redraw()
end

ns.Listen("READY", function()
  ns.PlaceFrame()
  ns.Refresh(true)
end)
