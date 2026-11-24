-- DiscordBuddy - event detection (posts + weekly stats).
-- Everything here is defensive: WoW: Forever and the Classic clients don't all
-- have the same events and functions, and some values can be "secret" (hidden
-- from addons) in combat or instances. Anything unavailable is skipped quietly.

local ADDON_NAME, ns = ...

local f = CreateFrame("Frame")
local handlers = {}
local playerGUID

local function S(v)            -- drop secret values
    if ns.IsSecret(v) then return nil end
    return v
end

local function On(event, fn)
    handlers[event] = fn
    pcall(f.RegisterEvent, f, event)
end

f:SetScript("OnEvent", function(_, event, ...)
    local fn = handlers[event]
    if fn and ns.db then
        local ok, err = pcall(fn, ...)
        if not ok and ns.db.debug then ns.Print(event .. " error: " .. tostring(err)) end
    end
end)

-- Turn a GlobalStrings format ("You receive loot: %s.") into a Lua pattern.
local function FormatToPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    fmt = fmt:gsub("%%%d%$", "%%")                      -- "%1$s" -> "%s"
    fmt = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")   -- escape magic chars
    fmt = fmt:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
    return "^" .. fmt
end

local function CharKey() return ns.PlayerName() end

-------------------------------------------------------------------------------
-- Level / max level
-------------------------------------------------------------------------------
On("PLAYER_LEVEL_UP", function(level)
    level = tonumber(S(level)) or ((UnitLevel("player") or 0) + 1)
    local s = ns.CurrentStats()
    if s then s.levelEnd = level end
    local max = GetMaxPlayerLevel and GetMaxPlayerLevel()
    if max and level >= max and ns.db.events.maxlevel then
        ns.Post("maxlevel", { level = level })
    else
        ns.Post("level", { level = level })
    end
end)

-------------------------------------------------------------------------------
-- Professions
-------------------------------------------------------------------------------
local PROF_MILESTONES = { [75] = true, [150] = true, [225] = true, [300] = true, [375] = true, [450] = true }
local PROF_NAMES = {
    Alchemy = true, Blacksmithing = true, Enchanting = true, Engineering = true, Herbalism = true,
    Leatherworking = true, Mining = true, Skinning = true, Tailoring = true, Jewelcrafting = true,
    Inscription = true, Cooking = true, ["First Aid"] = true, Fishing = true,
}
local function IsProfession(name)
    if PROF_NAMES[name] then return true end
    if GetProfessions and GetProfessionInfo then
        local ok, res = pcall(function()
            for _, idx in ipairs({ GetProfessions() }) do
                if idx and GetProfessionInfo(idx) == name then return true end
            end
        end)
        if ok and res then return true end
    end
    return false
end

local skillPattern = FormatToPattern(SKILL_RANK_UP) or "^Your skill in (.+) has increased to (%d+)%."

On("CHAT_MSG_SKILL", function(msg)
    msg = S(msg)
    if type(msg) ~= "string" then return end
    local name, rank = msg:match(skillPattern)
    rank = tonumber(rank)
    if not name or not rank or not IsProfession(name) then return end
    local s = ns.CurrentStats()
    if s then
        s.profs = s.profs or {}
        s.profs[name] = rank
    end
    if PROF_MILESTONES[rank] then
        ns.Post("profession", { detail = name .. " " .. rank })
    end
end)

-------------------------------------------------------------------------------
-- Reputation tiers (Honored and up)
-------------------------------------------------------------------------------
local standings, repTimer

local function ScanFactions()
    local result = {}
    if not (C_Reputation and C_Reputation.GetNumFactions and C_Reputation.GetFactionDataByIndex) then return result end
    for i = 1, C_Reputation.GetNumFactions() do
        local d = C_Reputation.GetFactionDataByIndex(i)
        if type(d) == "table" and not d.isHeader and d.factionID and d.reaction and d.name then
            result[d.factionID] = { reaction = d.reaction, name = d.name }
        end
    end
    return result
end

local function CheckFactions()
    repTimer = nil
    local now = ScanFactions()
    if standings then
        for id, d in pairs(now) do
            local before = standings[id]
            if before and d.reaction > before.reaction and d.reaction >= 6 then
                local label = _G["FACTION_STANDING_LABEL" .. d.reaction] or ("standing " .. d.reaction)
                ns.StatAdd("repUps", 1)
                ns.Post("reputation", { detail = label .. " with " .. d.name })
            end
        end
    end
    standings = now
end

On("UPDATE_FACTION", function()
    if not repTimer then repTimer = C_Timer.After(2, CheckFactions) or true end
end)

-------------------------------------------------------------------------------
-- Loot, gathering
-------------------------------------------------------------------------------
local GATHER_SPELLS = { ["Herb Gathering"] = true, ["Herbalism"] = true, ["Mining"] = true, ["Skinning"] = true }
local GATHER_IDS = { [2366] = true, [2368] = true, [3570] = true, [11993] = true,
                     [2575] = true, [2576] = true, [3564] = true, [10248] = true,
                     [8613] = true, [8617] = true, [8618] = true, [10768] = true }
local lastGather = -100

On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
    if S(unit) ~= "player" then return end
    spellID = S(spellID)
    if not spellID then return end
    local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID))
        or (GetSpellInfo and GetSpellInfo(spellID))
    if GATHER_IDS[spellID] or (name and GATHER_SPELLS[S(name)]) then
        ns.StatAdd("gatherNodes", 1)
        lastGather = GetTime()
    end
end)

local selfLootPrefixes = {}
for _, g in ipairs({ "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF",
                     "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_CREATED_SELF" }) do
    local fmt = _G[g]
    if type(fmt) == "string" then
        local prefix = fmt:match("^(.-)%%")
        if prefix and prefix ~= "" then selfLootPrefixes[#selfLootPrefixes + 1] = prefix end
    end
end
if #selfLootPrefixes == 0 then selfLootPrefixes = { "You receive loot: ", "You receive item: " } end

local function IsSelfLoot(msg, guid)
    guid = S(guid)
    if guid and playerGUID and guid ~= "" then return guid == playerGUID end
    for _, p in ipairs(selfLootPrefixes) do
        if msg:sub(1, #p) == p then return true end
    end
    return false
end

local function ItemQuality(link)
    local q = tonumber(link:match("|cnIQ(%d):"))
    if q then return q end
    if C_Item and C_Item.GetItemInfo then
        local _, _, quality = C_Item.GetItemInfo(link)
        return tonumber(quality)
    end
end

local function ItemSellPrice(link)
    if C_Item and C_Item.GetItemInfo then
        local ok, price = pcall(function() return select(11, C_Item.GetItemInfo(link)) end)
        if ok then return tonumber(price) end
    end
end

On("CHAT_MSG_LOOT", function(msg, ...)
    msg = S(msg)
    if type(msg) ~= "string" then return end
    local guid = select(11, ...)
    if not IsSelfLoot(msg, guid) then return end
    local link = msg:match("(|c[^|]*|Hitem:.-|h.-|h|r)") or msg:match("(|Hitem:.-|h.-|h)")
    if not link then return end
    local name = link:match("%[(.-)%]") or "?"
    local count = tonumber(msg:match("|rx(%d+)") or msg:match("x(%d+)%.?$")) or 1

    if GetTime() - lastGather < 3 then ns.StatAdd("gatherItems", count) end

    local quality = ItemQuality(link) or 1
    local price = ItemSellPrice(link)
    if price and price > 0 then
        ns.StatBest("bestLoot", { name = name, value = price * count })
    end
    ns.StatBest("rarestLoot", { name = name, value = quality })
    if quality >= 4 then ns.Post("loot", { detail = name }) end
end)

-------------------------------------------------------------------------------
-- Kills, rares, bosses
-------------------------------------------------------------------------------
local rares, rareCount = {}, 0
local RARE = { rare = true, rareelite = true, worldboss = true }

local function NoteUnit(unit)
    local guid = S(UnitGUID(unit))
    if not guid or rares[guid] then return end
    local cls = S(UnitClassification(unit))
    if cls and RARE[cls] then
        rareCount = rareCount + 1
        if rareCount > 200 then wipe(rares); rareCount = 0 end
        rares[guid] = S(UnitName(unit)) or "a rare"
    end
end

On("PLAYER_TARGET_CHANGED", function() NoteUnit("target") end)
On("UPDATE_MOUSEOVER_UNIT", function() NoteUnit("mouseover") end)
On("NAME_PLATE_UNIT_ADDED", function(unit) unit = S(unit); if unit then NoteUnit(unit) end end)

On("PARTY_KILL", function(attacker, target)
    attacker, target = S(attacker), S(target)
    if not attacker or attacker ~= playerGUID then return end
    ns.StatAdd("kills", 1)
    if target and rares[target] then
        ns.StatAdd("rareKills", 1)
        ns.Post("rare", { detail = rares[target] })
        rares[target] = nil
    end
end)

local function BossKilled(id, name)
    id, name = S(id), S(name)
    if not id or not name then return end
    ns.StatAdd("bosses", 1)
    local db = ns.db
    db.bossKills = db.bossKills or {}
    local key = CharKey()
    db.bossKills[key] = db.bossKills[key] or {}
    if not db.bossKills[key][id] then
        db.bossKills[key][id] = true
        ns.Post("boss", { detail = name })
    end
end
local lastBoss
On("BOSS_KILL", function(id, name) lastBoss = id; BossKilled(id, name) end)
On("ENCOUNTER_END", function(id, name, _, _, success)
    if S(success) == 1 and S(id) ~= lastBoss then BossKilled(id, name) end
end)

-------------------------------------------------------------------------------
-- Gold
-------------------------------------------------------------------------------
local GOLD_MILESTONES = { 10, 100, 500, 1000, 5000, 10000, 50000, 100000 }
local lastMoney

On("PLAYER_MONEY", function()
    local m = S(GetMoney())
    if not m then return end
    if lastMoney and m > lastMoney then
        ns.StatAdd("gold", m - lastMoney)
        local db = ns.db
        db.goldMilestones = db.goldMilestones or {}
        local key = CharKey()
        local best = db.goldMilestones[key] or 0
        for _, g in ipairs(GOLD_MILESTONES) do
            local c = g * 10000
            if lastMoney < c and m >= c and g > best then
                best = g
                db.goldMilestones[key] = g
                ns.Post("gold", { detail = g .. " gold" })
            end
        end
    end
    lastMoney = m
end)

-------------------------------------------------------------------------------
-- Death
-------------------------------------------------------------------------------
On("PLAYER_DEAD", function()
    ns.StatAdd("deaths", 1)
    ns.Post("death", {})
end)

-------------------------------------------------------------------------------
-- Legacy (Forever) / achievements
-------------------------------------------------------------------------------
On("ACHIEVEMENT_EARNED", function(id)
    id = S(id)
    ns.StatAdd("legacy", 1)
    local name
    if id and GetAchievementInfo then
        local ok, _, n = pcall(GetAchievementInfo, id)
        if ok then name = S(n) end
    end
    ns.Post("legacy", { detail = name or "a Legacy challenge" })
end)

-------------------------------------------------------------------------------
-- PvP: honor level, rank, honor / rank-point currencies, honorable kills
-------------------------------------------------------------------------------
On("HONOR_LEVEL_UPDATE", function(isHigher)
    if S(isHigher) == false then return end
    local lvl = UnitHonorLevel and S(UnitHonorLevel("player"))
    if lvl then
        ns.StatSet("pvpRank", "honor level " .. lvl)
        ns.Post("pvp", { detail = "honor level " .. lvl })
    end
end)

On("PLAYER_PVP_RANK_CHANGED", function()
    local rank = UnitPVPRank and S(UnitPVPRank("player"))
    local name = rank and GetPVPRankInfo and S(GetPVPRankInfo(rank))
    if name then
        ns.StatSet("pvpRank", name)
        ns.Post("pvp", { detail = name })
    end
end)

On("CURRENCY_DISPLAY_UPDATE", function(currencyID, _, change)
    currencyID, change = S(currencyID), tonumber(S(change))
    if not currencyID or not change or change <= 0 then return end
    if not (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo) then return end
    local info = C_CurrencyInfo.GetCurrencyInfo(currencyID)
    local name = info and S(info.name)
    if type(name) ~= "string" then return end
    if name:find("Honor") then
        ns.StatAdd("honor", change)
    elseif name:find("Rank") then
        ns.StatAdd("rankPoints", change)
    end
end)

On("CHAT_MSG_COMBAT_HONOR_GAIN", function(msg)
    msg = S(msg)
    if type(msg) == "string" and msg:lower():find("honorable kill") then ns.StatAdd("hk", 1) end
end)

-------------------------------------------------------------------------------
-- Titles
-------------------------------------------------------------------------------
On("NEW_TITLE_EARNED", function(titleID)
    titleID = S(titleID)
    local name = titleID and GetTitleName and S(GetTitleName(titleID))
    if type(name) == "string" then
        name = strtrim((name:gsub("%%s", "")))
        ns.Post("title", { detail = name })
    end
end)

-------------------------------------------------------------------------------
-- Biggest fight (from the built-in damage meter, read after combat)
-------------------------------------------------------------------------------
On("PLAYER_REGEN_ENABLED", function()
    if not (C_DamageMeter and C_DamageMeter.GetCombatSessionFromType) then return end
    C_Timer.After(0.5, function()
        pcall(function()
            local session = C_DamageMeter.GetCombatSessionFromType(1, 0)
            if type(session) ~= "table" then return end
            local total, duration = S(session.totalAmount), S(session.durationSeconds)
            if type(total) == "number" and type(duration) == "number" and total > 0 then
                ns.StatBest("bigFight", { value = total, duration = duration })
            end
        end)
    end)
end)

-------------------------------------------------------------------------------
-- Startup
-------------------------------------------------------------------------------
On("PLAYER_ENTERING_WORLD", function()
    playerGUID = S(UnitGUID("player"))
    lastMoney = S(GetMoney())
    if not standings then C_Timer.After(3, function() standings = ScanFactions() end) end
end)
