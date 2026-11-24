-- DiscordBuddy - core: settings, marker encoding, capture queue, settings window.
--
-- WoW addons cannot make web requests, so this works together with the
-- DiscordBuddy Companion program on your PC:
--   1. When something post-worthy happens the addon draws a grid of coloured
--      blocks in the top-left corner that encodes the finished Discord message,
--      and takes a screenshot (the "marker shot").
--   2. It removes the blocks (and by default hides chat) and takes a clean shot.
--   3. DiscordBuddy Companion decodes and deletes the marker shot and posts the message
--      with the clean shot to the webhook saved in these settings.
-- The weekly recap is written into this addon's SavedVariables; DiscordBuddy Companion
-- posts it after the weekly reset.
--
-- The marker format MUST match DiscordBuddyCompanion.ps1.

local ADDON_NAME, ns = ...
ns.VERSION = "1.0.0"

-------------------------------------------------------------------------------
-- Marker format v3 (row-major, COLS blocks per row)
--   blocks 1-3: red, green, blue signature
--   then bits: test(1) | length(7) | flags(8) | payload bytes(8 each) | checksum(8)
--   payload  = eventKey .. "\31" .. message      (UTF-8, max 127 bytes)
--   flags    bit 0 = a clean screenshot follows
--   checksum = (length + flags + sum of payload bytes) % 256
-------------------------------------------------------------------------------
local BLOCK_FRAC  = 0.012
local COLS        = 40
local SIGNATURE   = { {1, 0, 0}, {0, 1, 0}, {0, 0, 1} }
local MAX_PAYLOAD = 127

local QUEUE_GAP   = 3.0   -- seconds between queued captures
local MAX_QUEUE   = 5

local PREFIX = "|cff7289daDiscordBuddy:|r "
function ns.Print(msg) print(PREFIX .. msg) end
local Print = ns.Print

-------------------------------------------------------------------------------
-- Event definitions (order = order in the settings window)
-------------------------------------------------------------------------------
ns.EVENTS = {
    { key = "level",      label = "Level up",              on = true,
      msg = "**{name}** just hit **level {level}**!" },
    { key = "maxlevel",   label = "Max level",             on = true,
      msg = "**{name}** reached **max level {level}**!" },
    { key = "profession", label = "Profession milestone",  on = true,
      msg = "**{name}** reached **{detail}**!" },
    { key = "reputation", label = "Reputation tier",       on = false,
      msg = "**{name}** is now **{detail}**!" },
    { key = "loot",       label = "Epic+ loot",            on = false,
      msg = "**{name}** looted **{detail}**!" },
    { key = "rare",       label = "Rare kill",             on = false,
      msg = "**{name}** slew the rare **{detail}**!" },
    { key = "boss",       label = "First boss kill",       on = false,
      msg = "**{name}** defeated **{detail}** for the first time!" },
    { key = "gold",       label = "Gold milestone",        on = false,
      msg = "**{name}** now has **{detail}**!" },
    { key = "death",      label = "Death",                 on = false,
      msg = "**{name}** died at level {level} in {zone}." },
    { key = "legacy",     label = "Legacy / achievement",  on = true,
      msg = "**{name}** earned **{detail}**!" },
    { key = "pvp",        label = "PvP rank / honor level", on = true,
      msg = "**{name}** reached **{detail}**!" },
    { key = "title",      label = "New title",             on = false,
      msg = "**{name}** earned the title **{detail}**!" },
}
ns.EVENT_BY_KEY = {}
for _, e in ipairs(ns.EVENTS) do ns.EVENT_BY_KEY[e.key] = e end

local SHOT_MODES = { "nochat", "full", "none" }
local SHOT_MODE_LABEL = {
    nochat = "Screenshot (chat hidden)",
    full   = "Screenshot (everything)",
    none   = "No screenshot, text only",
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
function ns.IsSecret(v)
    return type(issecretvalue) == "function" and issecretvalue(v)
end

-- Escape Discord markdown so names/items can't break formatting.
function ns.Escape(s)
    s = tostring(s or "")
    return (s:gsub("([\\%*_~`|>%[%]])", "\\%1"))
end

function ns.Money(copper)
    copper = math.floor(tonumber(copper) or 0)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    if g > 0 then return s > 0 and ("%dg %ds"):format(g, s) or ("%dg"):format(g) end
    if s > 0 then return ("%ds %dc"):format(s, c) end
    return ("%dc"):format(c)
end

local WEBHOOK_HOSTS = { "discord.com", "discordapp.com", "ptb.discord.com", "canary.discord.com" }

local function NormalizeWebhook(url)
    if type(url) ~= "string" then return nil end
    url = strtrim(url):gsub("%?.*$", "")
    for _, host in ipairs(WEBHOOK_HOSTS) do
        local prefix = "https://" .. host .. "/api/webhooks/"
        if url:sub(1, #prefix) == prefix then
            local id, token = url:sub(#prefix + 1):match("^(%d+)/([%w_%-]+)$")
            if id and token and #id >= 15 and #token >= 30 then
                return "https://discord.com/api/webhooks/" .. id .. "/" .. token
            end
        end
    end
end

local function MaskWebhook(url)
    local id = url and url:match("/webhooks/(%d+)/")
    if not id then return "not set" end
    return "saved (webhook " .. id:sub(1, 4) .. "..." .. id:sub(-3) .. ")"
end

-------------------------------------------------------------------------------
-- Character name (WoW Forever: first name + surname)
-------------------------------------------------------------------------------
local playerName

local function Clean(v)
    if type(v) ~= "string" or ns.IsSecret(v) then return nil end
    v = v:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    v = strtrim(v)
    if v == "" or v == UNKNOWNOBJECT then return nil end
    return v
end

local function FindSurname(first)
    if type(C_PlayerInfo) ~= "table" then return nil end
    for key, fn in pairs(C_PlayerInfo) do
        if type(fn) == "function" and type(key) == "string" and key:find("Surname")
           and not key:find("^Should") and not key:find("^Set") then
            local ok, a, b = pcall(fn)
            if not ok or type(a) ~= "string" then ok, a, b = pcall(fn, "player") end
            if ok then
                for _, v in ipairs({ a, b }) do
                    v = Clean(v)
                    if v and v ~= first then return v end
                end
            end
        end
    end
end

function ns.RefreshName()
    pcall(function()
        local first = Clean(UnitName("player"))
        if not first then return end
        local best = first
        local function consider(v)
            v = Clean(v)
            if v and #v > #best and #v <= 40 and v:sub(1, #first) == first then best = v end
        end
        local surname = FindSurname(first)
        if surname then consider(first .. " " .. surname) end
        local fs = _G.PlayerName or (PlayerFrame and (PlayerFrame.name or
            (PlayerFrame.PlayerFrameContent and PlayerFrame.PlayerFrameContent.PlayerFrameContentMain
             and PlayerFrame.PlayerFrameContent.PlayerFrameContentMain.Name)))
        if fs and fs.GetText then consider(fs:GetText()) end
        if GetUnitName then consider(GetUnitName("player", true)) end
        playerName = best
    end)
    return playerName
end

function ns.PlayerName()
    return playerName or ns.RefreshName() or "Someone"
end

-------------------------------------------------------------------------------
-- Marker frame
-------------------------------------------------------------------------------
local marker = CreateFrame("Frame", nil, UIParent)
marker:SetFrameStrata("TOOLTIP")
marker:SetFrameLevel(9000)
marker:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
marker:Hide()

local function MarkerParent()
    local parent = UIParent:IsShown() and UIParent or WorldFrame
    if marker:GetParent() ~= parent then
        marker:SetParent(parent)
        marker:SetFrameStrata("TOOLTIP")
        marker:SetFrameLevel(9000)
    end
    marker:ClearAllPoints()
    marker:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    return parent
end

local blocks = {}
local function GetBlock(i)
    if not blocks[i] then blocks[i] = marker:CreateTexture(nil, "OVERLAY") end
    return blocks[i]
end

local function PushBits(list, value, n)
    for b = n - 1, 0, -1 do
        list[#list + 1] = math.floor(value / 2 ^ b) % 2
    end
end

-- Cut a UTF-8 string to at most maxBytes without splitting a character.
local function Utf8Cut(s, maxBytes)
    if #s <= maxBytes then return s end
    local cut = maxBytes
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end   -- next byte starts a char
        cut = cut - 1
    end
    return s:sub(1, cut)
end
ns.Utf8Cut = Utf8Cut

local function Encode(payload, isTest, flags)
    payload = Utf8Cut(payload, MAX_PAYLOAD)
    local bits = {}
    PushBits(bits, isTest and 1 or 0, 1)
    PushBits(bits, #payload, 7)
    PushBits(bits, flags, 8)
    local sum = #payload + flags
    for i = 1, #payload do
        local byte = payload:byte(i)
        PushBits(bits, byte, 8)
        sum = sum + byte
    end
    PushBits(bits, sum % 256, 8)

    local size = MarkerParent():GetHeight() * BLOCK_FRAC
    local total = #SIGNATURE + #bits
    marker:SetSize(size * COLS, size * math.ceil(total / COLS))

    for i = 1, math.max(total, #blocks) do
        local tex = GetBlock(i)
        if i <= total then
            local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
            tex:ClearAllPoints()
            tex:SetSize(size, size)
            tex:SetPoint("TOPLEFT", marker, "TOPLEFT", col * size, -row * size)
            local c = SIGNATURE[i]
            if c then
                tex:SetColorTexture(c[1], c[2], c[3], 1)
            else
                local v = bits[i - #SIGNATURE]
                tex:SetColorTexture(v, v, v, 1)
            end
            tex:Show()
        else
            tex:Hide()
        end
    end
end

-------------------------------------------------------------------------------
-- Hiding chat (and our own window) for screenshots
-------------------------------------------------------------------------------
local hidden = {}

local function HideForShot(hideChat)
    wipe(hidden)
    local names = { "DiscordBuddyPanel" }
    if hideChat then
        for i = 1, (NUM_CHAT_WINDOWS or 10) do
            names[#names + 1] = "ChatFrame" .. i
            names[#names + 1] = "ChatFrame" .. i .. "Tab"
            names[#names + 1] = "ChatFrame" .. i .. "EditBox"
        end
        for _, n in ipairs({ "GeneralDockManager", "ChatFrameMenuButton", "ChatFrameChannelButton",
                             "QuickJoinToastButton", "ChatFrameToggleVoiceDeafenButton",
                             "ChatFrameToggleVoiceMuteButton", "ChatAlertFrame" }) do
            names[#names + 1] = n
        end
    end
    for _, n in ipairs(names) do
        local f = _G[n]
        if f and f.GetAlpha and f.SetAlpha then
            pcall(function()
                hidden[f] = f:GetAlpha()
                f:SetAlpha(0)
            end)
        end
    end
end

local function RestoreAfterShot()
    for f, a in pairs(hidden) do pcall(f.SetAlpha, f, a) end
    wipe(hidden)
end

-------------------------------------------------------------------------------
-- Posting: build the message, then queue a capture
--   t=0 marker shown, 0.3 marker shot, 1.6 marker hidden (+chat), 1.9 clean
--   shot, 2.3 restore. The clean shot is >1s after the marker shot because WoW
--   names screenshot files per second.
-------------------------------------------------------------------------------
local queue, busy, verbose = {}, false, false
local lastByKey = {}

local function Say(msg) if verbose then Print(msg) end end

local function Fill(template, vars)
    return (template:gsub("{(%w+)}", function(k)
        local v = vars[k]
        if v == nil then return "{" .. k .. "}" end
        return tostring(v)
    end))
end

function ns.FormatMessage(key, vars)
    local db = ns.db
    local template = (db and db.messages[key]) or (ns.EVENT_BY_KEY[key] and ns.EVENT_BY_KEY[key].msg) or "{detail}"
    local all = {
        name   = ns.Escape(vars.name or ns.PlayerName()),
        level  = vars.level or UnitLevel("player"),
        detail = ns.Escape(vars.detail or ""),
        zone   = ns.Escape(vars.zone or (GetRealZoneText and GetRealZoneText()) or ""),
    }
    return Fill(template, all)
end

local function Shoot(label)
    local ok, err = pcall(Screenshot)
    if ok then Say(label .. " screenshot taken.") else Print(label .. " screenshot error: " .. tostring(err)) end
end

local RunQueue

local function Capture(item)
    busy = true
    local mode = ns.db.shotMode
    local clean = mode ~= "none"
    Encode(item.key .. "\31" .. item.message, item.test, clean and 1 or 0)
    HideForShot(false)
    marker:Show()
    C_Timer.After(0.3, function() Shoot("Marker") end)
    C_Timer.After(1.6, function()
        marker:Hide()
        if clean then RestoreAfterShot(); HideForShot(mode == "nochat") end
    end)
    if clean then C_Timer.After(1.9, function() Shoot("Clean") end) end
    C_Timer.After(2.3, function()
        RestoreAfterShot()
        Say("done. If nothing reaches Discord within a few seconds, check that DiscordBuddy Companion is running.")
        C_Timer.After(QUEUE_GAP - 2.3 + 0.7, function()
            busy = false
            RunQueue()
        end)
    end)
end

RunQueue = function()
    if busy or #queue == 0 then return end
    Capture(table.remove(queue, 1))
end

-- Public: post an event. vars = { detail=, level=, zone=, name= }, delay in seconds.
function ns.Post(key, vars, opts)
    opts = opts or {}
    local db = ns.db
    if not db then return end
    if not opts.test then
        if not db.enabled or not db.events[key] then return end
        -- the same event type at most once every 20 seconds (stops loot/rare spam)
        local now = GetTime()
        if lastByKey[key] and now - lastByKey[key] < 20 then return end
        lastByKey[key] = now
    end
    if not db.webhook then
        if opts.test then Print("no Discord webhook set. Type |cffffff00/buddy|r to set one up.") end
        return
    end
    if #queue >= MAX_QUEUE then return end
    local item = { key = key, message = ns.FormatMessage(key, vars or {}), test = opts.test }
    C_Timer.After(opts.delay or 0.6, function()
        queue[#queue + 1] = item
        RunQueue()
    end)
end

function ns.Test()
    verbose = true
    Print("test post (v" .. ns.VERSION .. ").")
    ns.Post("level", { level = UnitLevel("player") }, { test = true, delay = 0.1 })
end

-------------------------------------------------------------------------------
-- Settings window (/buddy)
-------------------------------------------------------------------------------
local panel

local function MakeLabel(parent, text, x, y, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
end

local function MakeEditBox(parent, x, y, width, maxLetters)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetPoint("TOPLEFT", x, y)
    eb:SetSize(width, 22)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(maxLetters)
    eb:SetScript("OnEscapePressed", eb.ClearFocus)
    eb:SetScript("OnEnterPressed", eb.ClearFocus)
    return eb
end

local function MakeButton(parent, text, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 24)
    b:SetText(text)
    return b
end

local function MakeCheck(parent, text, x, y, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)
    cb:SetSize(24, 24)
    local label = MakeLabel(parent, text, x + 26, y - 5, "GameFontHighlightSmall")
    cb.label = label
    cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    return cb
end

local function UpdatePanel()
    if not panel then return end
    local db = ns.db
    panel.enabled:SetChecked(db.enabled)
    panel.recap:SetChecked(db.recapEnabled)
    for key, cb in pairs(panel.eventChecks) do cb:SetChecked(db.events[key]) end
    panel.webhookStatus:SetText("Webhook: " .. (db.webhook and ("|cff40ff40" .. MaskWebhook(db.webhook) .. "|r")
        or "|cffff6060not set|r"))
    panel.modeButton:SetText(SHOT_MODE_LABEL[db.shotMode])
    local e = ns.EVENTS[panel.editIndex]
    panel.editWhich:SetText(e.label)
    panel.message:SetText(db.messages[e.key] or e.msg)
    panel.dirty:SetShown(panel.pending and true or false)
end

local function CreatePanel()
    local db = ns.db
    panel = CreateFrame("Frame", "DiscordBuddyPanel", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(500, 560)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:Hide()
    tinsert(UISpecialFrames, "DiscordBuddyPanel")
    panel.editIndex = 1
    panel.eventChecks = {}

    local title = rawget(panel, "TitleText") or panel.TitleText
    if type(title) ~= "table" or not title.SetText then
        title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", 0, -5)
    end
    title:SetText("DiscordBuddy " .. ns.VERSION)

    local function markDirty() panel.pending = true; panel.dirty:Show() end

    panel.enabled = MakeCheck(panel, "Post to Discord", 14, -30, function(v) db.enabled = v; markDirty() end)
    panel.recap = MakeCheck(panel, "Weekly recap (after the weekly reset)", 200, -30,
        function(v) db.recapEnabled = v; markDirty() end)

    -- Webhook
    MakeLabel(panel, "Discord webhook URL", 18, -62)
    panel.webhookStatus = MakeLabel(panel, "", 170, -63, "GameFontHighlightSmall")
    panel.webhook = MakeEditBox(panel, 24, -80, 330, 300)
    local setHook = MakeButton(panel, "Set", 54)
    setHook:SetPoint("LEFT", panel.webhook, "RIGHT", 8, 0)
    local clearHook = MakeButton(panel, "Clear", 60)
    clearHook:SetPoint("LEFT", setHook, "RIGHT", 4, 0)
    local hint = MakeLabel(panel, "Discord: Server Settings > Integrations > Webhooks > Copy Webhook URL. "
        .. "Paste with Ctrl+V. Anyone with this link can post to your channel - keep it private.",
        18, -106, "GameFontDisableSmall")
    hint:SetWidth(464)

    local function applyWebhook()
        local url = NormalizeWebhook(panel.webhook:GetText())
        if url then
            db.webhook = url
            panel.webhook:SetText("")
            panel.webhook:ClearFocus()
            markDirty()
            UpdatePanel()
        else
            Print("that doesn't look like a Discord webhook URL (https://discord.com/api/webhooks/...).")
        end
    end
    setHook:SetScript("OnClick", applyWebhook)
    panel.webhook:SetScript("OnEnterPressed", applyWebhook)
    clearHook:SetScript("OnClick", function() db.webhook = nil; markDirty(); UpdatePanel() end)

    -- Events
    MakeLabel(panel, "Post when...", 18, -138)
    for i, e in ipairs(ns.EVENTS) do
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        local key = e.key
        panel.eventChecks[key] = MakeCheck(panel, e.label, 18 + col * 236, -154 - row * 24,
            function(v) db.events[key] = v; markDirty() end)
    end
    local y = -154 - math.ceil(#ns.EVENTS / 2) * 24 - 8

    -- Message template editor
    MakeLabel(panel, "Message for:", 18, y)
    panel.editWhich = MakeButton(panel, "", 200)
    panel.editWhich:SetPoint("TOPLEFT", 110, y + 5)
    panel.editWhich:SetScript("OnClick", function()
        panel.editIndex = panel.editIndex % #ns.EVENTS + 1
        UpdatePanel()
    end)
    local reset = MakeButton(panel, "Default", 70)
    reset:SetPoint("LEFT", panel.editWhich, "RIGHT", 6, 0)
    reset:SetScript("OnClick", function()
        db.messages[ns.EVENTS[panel.editIndex].key] = nil
        markDirty()
        UpdatePanel()
    end)
    panel.message = MakeEditBox(panel, 24, y - 24, 450, 200)
    panel.message:SetScript("OnTextChanged", function(self, user)
        if user then
            local key = ns.EVENTS[panel.editIndex].key
            local t = strtrim(self:GetText())
            db.messages[key] = (t ~= "" and t ~= ns.EVENT_BY_KEY[key].msg) and t or nil
            markDirty()
        end
    end)
    MakeLabel(panel, "{name} {level} {detail} {zone} are filled in. Discord formatting like **bold** works.",
        18, y - 50, "GameFontDisableSmall")

    -- Screenshot mode
    y = y - 76
    MakeLabel(panel, "Screenshot", 18, y)
    panel.modeButton = MakeButton(panel, "", 220)
    panel.modeButton:SetPoint("TOPLEFT", 100, y + 5)
    panel.modeButton:SetScript("OnClick", function()
        local idx = 1
        for i, m in ipairs(SHOT_MODES) do if m == db.shotMode then idx = i end end
        db.shotMode = SHOT_MODES[idx % #SHOT_MODES + 1]
        markDirty()
        UpdatePanel()
    end)
    MakeLabel(panel, "Hiding chat keeps whispers private.", 328, y - 2, "GameFontDisableSmall"):SetWidth(160)

    panel.dirty = MakeLabel(panel, "|cffffd100Click Save & Reload so DiscordBuddy Companion sees your changes.|r",
        18, -484, "GameFontNormalSmall")
    panel.dirty:Hide()
    MakeLabel(panel, "Needs |cffffffffDiscordBuddy Companion|r running on your PC (it does the posting).",
        18, -502, "GameFontDisableSmall")

    local save = MakeButton(panel, "Save & Reload", 130)
    save:SetPoint("BOTTOMLEFT", 16, 14)
    save:SetScript("OnClick", function() ReloadUI() end)
    local test = MakeButton(panel, "Send test post", 130)
    test:SetPoint("LEFT", save, "RIGHT", 8, 0)
    test:SetScript("OnClick", function()
        if panel.pending then
            Print("save first (Save & Reload) so DiscordBuddy Companion has your latest settings.")
            return
        end
        ns.Test()
    end)

    UpdatePanel()
end

function ns.TogglePanel()
    if not panel then CreatePanel() end
    if panel:IsShown() then panel:Hide() else UpdatePanel(); panel:Show() end
end

local function RegisterOptionsCategory()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
    pcall(function()
        local canvas = CreateFrame("Frame")
        local text = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetPoint("TOPLEFT", 16, -16)
        text:SetText("DiscordBuddy settings live in their own window.")
        local b = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
        b:SetSize(200, 26)
        b:SetPoint("TOPLEFT", 16, -44)
        b:SetText("Open DiscordBuddy")
        b:SetScript("OnClick", function()
            if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
            ns.TogglePanel()
        end)
        Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(canvas, "DiscordBuddy"))
    end)
end

-------------------------------------------------------------------------------
-- Loading
-------------------------------------------------------------------------------
ns.onLoad = {}   -- other files add functions here; called after settings load

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        DiscordBuddyDB = DiscordBuddyDB or {}
        local db = DiscordBuddyDB
        ns.db = db
        if db.enabled == nil then db.enabled = true end
        if db.recapEnabled == nil then db.recapEnabled = true end
        if not SHOT_MODE_LABEL[db.shotMode] then db.shotMode = "nochat" end
        db.webhook = NormalizeWebhook(db.webhook)
        db.events = db.events or {}
        for _, e in ipairs(ns.EVENTS) do
            if db.events[e.key] == nil then db.events[e.key] = e.on end
        end
        db.messages = db.messages or {}
        if type(db.message) == "string" then       -- v2.0 single message -> level template
            if db.message ~= ns.EVENT_BY_KEY.level.msg then db.messages.level = db.message end
            db.message = nil
        end
        db.history = nil                           -- v2.0 leftovers
        db.addonVersion = ns.VERSION
        RegisterOptionsCategory()
        for _, fn in ipairs(ns.onLoad) do pcall(fn, db) end

    elseif event == "PLAYER_ENTERING_WORLD" then
        ns.RefreshName()
        if ns.db and not ns.db.webhook and not ns.db.nagged then
            ns.db.nagged = true
            Print("type |cffffff00/buddy|r to connect a Discord channel.")
        end
    end
end)

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
SLASH_DISCORDBUDDY1 = "/buddy"
SLASH_DISCORDBUDDY2 = "/discordbuddy"
SlashCmdList.DISCORDBUDDY = function(msg)
    msg = strlower(strtrim(msg or ""))
    local sub = msg:match("^probe%s*(.*)$")
    if sub and DiscordBuddy_Probe then DiscordBuddy_Probe(sub) return end
    if msg == "test" then
        ns.Test()
    elseif msg == "name" then
        Print("name for posts: " .. tostring(ns.RefreshName()))
    elseif msg == "recap" then
        if ns.RecapPreview then ns.RecapPreview() end
    elseif msg == "on" or msg == "off" then
        ns.db.enabled = (msg == "on")
        Print((ns.db.enabled and "enabled" or "disabled") .. ".")
    else
        ns.TogglePanel()
    end
end
