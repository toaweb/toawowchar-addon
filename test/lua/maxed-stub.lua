-- A maxed character, for measuring the export and checking the caps. Usage (from
-- the repository root):
--     lua app/test/lua/maxed-stub.lua [maxed|saturated]
-- Prints the text /wowchar makes, one line. All numbers are fixed (a small
-- deterministic generator), so the size is the same on every run.
--
-- "maxed" is a character a Classic-era game can really produce (what the
-- caps of the export are sized from; docs/addon-export-format-3.md):
--   level 60, 1,500 completed quests (ids spread over 1..30,000),
--   a full quest log (25 quests, 3 objectives each, texts of 28 to 74 characters),
--   Blacksmithing and Tailoring with 260 recipes each, First Aid (12), Cooking (120)
--   and Fishing (6), every recipe with 1 to 6 reagents (3.5 on average),
--   all bags full (backpack 16 + four bags of 18 = 88 slots, all different items),
--   the bank full (28 slots + 7 bank bags of 18 = 154), the warband bank full (5 tabs of 98),
--   80 reputations, a talent tree with 70 nodes, three Legacy trees with 60 nodes each,
--   60 flight paths and 150 class spells.
-- "saturated" fills every list to its cap: more than the server's total length, so
-- the addon has to leave sections out.
local scenario = arg[1] or "maxed"
local Env = dofile("app/test/lua/wow-env.lua")
local World = dofile("app/test/lua/world.lua")

local seed = 12345
local function rnd(n) -- 1..n
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n + 1
end

local maxed = scenario == "maxed"
local N = maxed and {
    quests = 1500, log = 25, objectives = 3, factions = 80, talents = 70, legacyNodes = 60, flights = 60, spells = 150,
    lines = { { "Blacksmithing", 164, 260 }, { "Tailoring", 197, 260 }, { "First Aid", 129, 12 }, { "Cooking", 185, 120 }, { "Fishing", 356, 6 } },
    reagents = nil, -- 1..6 by position
} or {
    quests = 5000, log = 50, objectives = 12, factions = 200, talents = 150, legacyNodes = 150, flights = 200, spells = 400,
    lines = {},
    reagents = 12,
}
if not maxed then
    for i = 1, 12 do N.lines[i] = { "Profession " .. i, 1000 + i, 600 } end
end

-- Character.
GetRealmName = function() return "Argent Dawn" end
UnitName = function() return "Thorin" end
UnitRace = function() return "Dwarf", "Dwarf", 3 end
World.player({ money = 999999999999, level = 60, xp = 1234567, xpMax = 2500000, rested = 345678 })

-- Equipped: 19 slots, every item with enchant, gems and bonus ids.
GetInventoryItemID = function(_, slot) return 10000 + slot end
GetInventoryItemLink = function(_, slot)
    return "|cffa335ee|Hitem:" .. (10000 + slot) .. ":2564:213:218:0:0:-9:1234:60:71:0:5:3:1472:6652:7881:1:28:1234|h[Item]|h|r"
end

-- Completed quests.
do
    local set, ids = {}, {}
    while #ids < N.quests do
        local id = maxed and rnd(30000) or (100000 + #ids * 7)
        if not set[id] then set[id] = true; ids[#ids + 1] = id end
    end
    World.completedQuests({ ids = ids })
end

-- The quest log.
do
    local entries = {}
    for i = 1, N.log do
        local objectives = {}
        for j = 1, N.objectives do
            local length = maxed and (28 + rnd(46)) or 255
            local text = ("Kill creatures of kind number %d in area %d "):rep(10):sub(1, length)
            objectives[j] = { text, rnd(10), 10, false }
        end
        entries[#entries + 1] = { id = 1000 + rnd(25000) + i, complete = i % 5 == 0, objectives = objectives }
    end
    World.questLog({ entries = entries })
end

-- Reputation.
do
    local factions = { { id = 1, name = "Classic", header = true } }
    for i = 1, N.factions do
        factions[#factions + 1] = { id = 100 + i * 3, name = maxed and ("Faction of the Valley %d"):format(i):sub(1, 14 + rnd(10)) or ("N"):rep(100),
            reaction = rnd(8), standing = rnd(40000) - 6000, floor = -6000 + rnd(1000), ceiling = 3000 + rnd(40000), parent = 1 }
    end
    World.reputation({ factions = factions })
end

-- Professions and their recipes. The trade skill window is open on the first line.
do
    local professions, recipes = {}, {}
    for i, line in ipairs(N.lines) do
        professions[i] = { name = line[1], rank = 300, maxRank = 300, line = line[2] }
    end
    local state = World.tradeskill({ professions = professions, withAllIds = true })
    Env.maxedLines = N.lines
    Env.tradeState = state
    Env.recipeSets = {}
    for l, line in ipairs(N.lines) do
        local ids, byId = {}, {}
        for r = 1, line[3] do
            local reagents = {}
            local count = N.reagents or ((r - 1) % 6 + 1)
            for k = 1, count do reagents[k] = { 1000 + rnd(60000), maxed and rnd(12) or 9999 } end
            local id = line[2] * 1000 + r
            ids[#ids + 1] = id
            byId[id] = { learned = true, reagents = reagents }
        end
        Env.recipeSets[l] = { ids = ids, recipes = byId }
    end
end

-- Bags, bank, warband bank.
local world = {
    open = false,
    enum = { CharacterBankTab_1 = 20, CharacterBankTab_2 = 21, AccountBankTab_1 = 30, AccountBankTab_2 = 31, AccountBankTab_3 = 32, AccountBankTab_4 = 33, AccountBankTab_5 = 34 },
    slots = { [0] = 16, [1] = 18, [2] = 18, [3] = 18, [4] = 18 },
    items = { [0] = {}, [1] = {}, [2] = {}, [3] = {}, [4] = {} },
    bankBags = {},
}
local nextItem = 20000
local function fill(bag, slots)
    world.slots[bag] = slots
    world.items[bag] = {}
    for s = 1, slots do
        nextItem = nextItem + 1 + rnd(7)
        world.items[bag][s] = nextItem
    end
end
for bag = 0, 4 do fill(bag, world.slots[bag]) end
fill(20, maxed and 80 or 300); fill(21, maxed and 74 or 300)
for bag = 30, 34 do fill(bag, maxed and 98 or 200) end
for bag = 20, 34 do world.bankBags[bag] = true end
Env.installContainers(world)

-- Talents and Legacy.
do
    local trees = {}
    local function nodes(first, count)
        local list = {}
        for i = 1, count do list[i] = { first + i, rnd(3), i % 3 == 0 and (90000 + i) or nil } end
        return list
    end
    trees[1100] = { nodes = nodes(10000, N.talents), extra = { 99001, 99002, 99003 } }
    trees[1187] = { nodes = nodes(20000, N.legacyNodes) }
    trees[1188] = { nodes = nodes(30000, N.legacyNodes) }
    trees[1189] = { nodes = nodes(40000, N.legacyNodes) }
    World.traits({
        talents = { config = 5000, treeIDs = { 1100 } },
        trees = trees,
        legacy = {
            [1187] = { config = 6001, quantity = 12, maxQuantity = 80, spent = 55, spentInTree = 20 },
            [1188] = { config = 6002, quantity = 12, maxQuantity = 80, spent = 55, spentInTree = 20 },
            [1189] = { config = 6003, quantity = 12, maxQuantity = 80, spent = 55, spentInTree = 15 },
        },
    })
end

-- Flight paths: read while a flight map is open.
local nodes = {}
for i = 1, N.flights do nodes[i] = { 100 + i * 2, 1 } end
World.taxi({ maps = { [1414] = { all = nodes } }, taxiMap = 1414, best = 1414 })

-- Class spells.
do
    local items = {}
    for i = 1, N.spells do items[i] = { 1000 + i * 11, 1000 + i * 11 } end
    World.spells({ lines = { { name = "General", items = {} }, { name = "Warrior", items = items } } })
end
World.honor({ info = { renownLevel = 7, maxLevel = 14 } })

Env.load()
Env.useTimers()

-- Open the bank, the profession windows and the flight map, as a player does.
world.open = true
Env.fire("BANKFRAME_OPENED")
for l, line in ipairs(N.lines) do
    local set = Env.recipeSets[l]
    Env.tradeState.window = { base = { professionID = line[2], professionName = line[1] }, all = set.ids, recipes = set.recipes }
    Env.fire("TRADE_SKILL_LIST_UPDATE")
    Env.flushTimers()
end
Env.tradeState.window = nil
Env.fire("TAXIMAP_OPENED")
Env.chat = {}

print(Env.run())
