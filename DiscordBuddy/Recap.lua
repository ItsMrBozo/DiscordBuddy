-- DiscordBuddy - weekly stats and recap text.
-- Stats are kept per character per game week (the week starts at your region's
-- weekly reset, e.g. Tuesday 15:00 UTC in the Americas). The finished recap
-- text is stored in DiscordBuddyDB.recaps[weekStart]; DiscordBuddy Companion posts it
-- once the week has ended.

local ADDON_NAME, ns = ...
local WEEK = 604800
local KEEP_WEEKS = 5

local QUALITY = { [0] = "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Artifact", "Heirloom" }

function ns.WeekStart()
    local now = time()
    if C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then
        local ok, s = pcall(C_DateAndTime.GetSecondsUntilWeeklyReset)
        if ok and type(s) == "number" and not ns.IsSecret(s) and s > 0 and s <= WEEK then
            return math.floor((now + s - WEEK + 150) / 300) * 300
        end
    end
    local ref = 486000   -- Tuesday 1970-01-06 15:00 UTC (Americas weekly reset)
    return math.floor((now - ref) / WEEK) * WEEK + ref
end

local function Current()
    local db = ns.db
    if not db then return nil end
    db.weeks = db.weeks or {}
    local ws = ns.WeekStart()
    local week = db.weeks[ws]
    if not week then
        week = {}
        db.weeks[ws] = week
    end
    local name = ns.PlayerName()
    local s = week[name]
    local level = UnitLevel("player")
    if not s then
        s = { levelStart = level }
        week[name] = s
    end
    if type(level) == "number" and not ns.IsSecret(level) then s.levelEnd = level end
    return s
end
ns.CurrentStats = Current

function ns.StatAdd(field, n)
    local s = Current()
    if s then s[field] = (s[field] or 0) + (n or 1) end
end

function ns.StatSet(field, value)
    local s = Current()
    if s then s[field] = value end
end

-- Keep the record with the highest .value
function ns.StatBest(field, info)
    local s = Current()
    if not s then return end
    local cur = s[field]
    if type(cur) ~= "table" or (info.value or 0) > (cur.value or 0) then s[field] = info end
end

-------------------------------------------------------------------------------
-- Recap text
-------------------------------------------------------------------------------
local function Duration(sec)
    sec = math.floor(sec or 0)
    local h, m = math.floor(sec / 3600), math.floor(sec / 60) % 60
    if h > 0 then return ("%dh %dm"):format(h, m) end
    return ("%dm"):format(m)
end

local function Num(n)
    n = math.floor(n or 0)
    local s = tostring(n)
    while true do
        local t, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        s = t
        if k == 0 then break end
    end
    return s
end

local function Plural(n, word)
    n = math.floor(n or 0)
    return Num(n) .. " " .. word .. (n == 1 and "" or "s")
end

local function HasActivity(s)
    return (s.kills or 0) > 0 or (s.gatherNodes or 0) > 0 or (s.gold or 0) > 0 or (s.hk or 0) > 0
        or (s.honor or 0) > 0 or (s.playSeconds or 0) >= 600
        or ((s.levelEnd or 0) > (s.levelStart or 0))
end

function ns.BuildRecap(ws)
    local db = ns.db
    local week = db and db.weeks and db.weeks[ws]
    if not week then return nil end

    local names = {}
    for name, s in pairs(week) do
        if type(s) == "table" and HasActivity(s) then names[#names + 1] = name end
    end
    if #names == 0 then return nil end
    table.sort(names)

    local out = { ("**Weekly recap** - %s to %s"):format(date("%b %d", ws), date("%b %d", ws + WEEK)) }
    for _, name in ipairs(names) do
        local s = week[name]
        local head = "**" .. ns.Escape(name) .. "**"
        local a, b = s.levelStart or 0, s.levelEnd or s.levelStart or 0
        if b > a then
            head = head .. (" - level %d -> %d (+%d)"):format(a, b, b - a)
        elseif b > 0 then
            head = head .. (" - level %d"):format(b)
        end
        out[#out + 1] = ""
        out[#out + 1] = head

        local parts = {}
        if (s.kills or 0) > 0 then
            parts[#parts + 1] = Plural(s.kills, "kill") ..
                (((s.rareKills or 0) > 0) and (" (" .. s.rareKills .. " rare)") or "")
        end
        if (s.bosses or 0) > 0 then parts[#parts + 1] = Plural(s.bosses, "boss kill") end
        parts[#parts + 1] = Plural(s.deaths, "death")
        if (s.playSeconds or 0) > 0 then parts[#parts + 1] = Duration(s.playSeconds) .. " played" end
        out[#out + 1] = "- " .. table.concat(parts, " | ")

        if (s.gatherNodes or 0) > 0 then
            out[#out + 1] = ("- Gathered: %s (%s)"):format(Plural(s.gatherNodes, "node"), Plural(s.gatherItems, "item"))
        end
        if (s.gold or 0) > 0 then
            out[#out + 1] = "- Gold gained: " .. ns.Money(s.gold)
        end
        local loot = {}
        if type(s.bestLoot) == "table" and (s.bestLoot.value or 0) > 0 then
            loot[#loot + 1] = ("Most valuable: %s (%s)"):format(ns.Escape(s.bestLoot.name), ns.Money(s.bestLoot.value))
        end
        if type(s.rarestLoot) == "table" and (s.rarestLoot.value or 0) >= 2 then
            loot[#loot + 1] = ("Rarest: %s (%s)"):format(ns.Escape(s.rarestLoot.name),
                QUALITY[s.rarestLoot.value] or "?")
        end
        if #loot > 0 then out[#out + 1] = "- " .. table.concat(loot, " | ") end
        if type(s.profs) == "table" then
            local p = {}
            for prof, rank in pairs(s.profs) do p[#p + 1] = ns.Escape(prof) .. " " .. rank end
            table.sort(p)
            if #p > 0 then out[#out + 1] = "- Professions: " .. table.concat(p, ", ") end
        end
        if (s.repUps or 0) > 0 then out[#out + 1] = "- Reputation tiers gained: " .. s.repUps end
        if (s.legacy or 0) > 0 then out[#out + 1] = "- Legacy / achievements earned: " .. s.legacy end
        if type(s.bigFight) == "table" and (s.bigFight.value or 0) > 0 then
            local f = s.bigFight
            local dps = (f.duration or 0) > 0 and (" (%s DPS)"):format(Num(f.value / f.duration)) or ""
            out[#out + 1] = ("- Biggest fight: %s damage in %ds%s"):format(Num(f.value), f.duration or 0, dps)
        end

        local pvp = {}
        if (s.hk or 0) > 0 then pvp[#pvp + 1] = Plural(s.hk, "honorable kill") end
        if (s.honor or 0) > 0 then pvp[#pvp + 1] = "+" .. Num(s.honor) .. " Honor" end
        if (s.rankPoints or 0) > 0 then pvp[#pvp + 1] = "+" .. Num(s.rankPoints) .. " rank points" end
        if s.pvpRank then pvp[#pvp + 1] = ns.Escape(s.pvpRank) end
        if #pvp > 0 then out[#out + 1] = "- PvP: " .. table.concat(pvp, " | ") end
    end
    return table.concat(out, "\n")
end

local function Refresh()
    local db = ns.db
    if not db or not db.weeks then return end
    db.recaps = {}
    local cutoff = ns.WeekStart() - KEEP_WEEKS * WEEK
    for ws in pairs(db.weeks) do
        if ws < cutoff then
            db.weeks[ws] = nil
        else
            db.recaps[ws] = ns.BuildRecap(ws)
        end
    end
end
ns.RefreshRecaps = Refresh

function ns.RecapPreview()
    local text = ns.BuildRecap(ns.WeekStart())
    if not text then
        ns.Print("nothing recorded this week yet.")
        return
    end
    ns.Print("this week so far:")
    for line in text:gmatch("[^\n]+") do print("  " .. line:gsub("%*%*", "")) end
end

-------------------------------------------------------------------------------
-- Play time + periodic refresh
-------------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_LOGOUT")
f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGOUT" then
        Refresh()
    elseif event == "PLAYER_ENTERING_WORLD" and not f.ticking then
        f.ticking = true
        Current()
        C_Timer.NewTicker(60, function()
            ns.StatAdd("playSeconds", 60)
        end)
        C_Timer.NewTicker(300, Refresh)
        C_Timer.After(5, Refresh)
    end
end)
