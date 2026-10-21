-- One complete, deterministic export from the real addon code with stubbed game
-- data: equipped items with links (and one without), bags, the bank and the
-- warband bank, professions with recipes, a spec, and every section of format 3
-- (completed quests, quest log, reputation, money and XP, talents, Legacy, flight
-- paths, the season's PvP rank, class spells), some live and some from a cache of an
-- earlier session. Prints the text /wowchar makes; the test compares it with
-- app/test/fixtures/addon-export-v3.txt and decodes it on the server side. Run from
-- the repository root. To make the fixture again after a deliberate change:
--     lua app/test/lua/export-full.lua > app/test/fixtures/addon-export-v3.txt
local Env = dofile("app/test/lua/wow-env.lua")
local World = dofile("app/test/lua/world.lua")

GetRealmName = function() return "Argent Dawn" end
UnitName = function() return "Thorin" end
UnitRace = function() return "Dwarf", "Dwarf", 3 end
UnitFactionGroup = function() return "Alliance", "Alliance" end

local links = {
    [1] = "|cffa335ee|Hitem:12640:2564:213:0:218:0:-9:1234:60:71:0:5:3:1472:6652:7881:1:28:1234|h[Lionheart Helm]|h|r",
    [2] = "|cffa335ee|Hitem:18404|h[Onyxia Tooth Pendant]|h|r",
    [16] = "|cffa335ee|Hitem:19019:3368:0:0:0:0:0:0:60|h[Thunderfury, Blessed Blade of the Windseeker]|h|r",
}
local ids = { [1] = 12640, [2] = 18404, [16] = 19019, [15] = 13340 } -- 15: no link yet
GetInventoryItemID = function(_, slot) return ids[slot] end
GetInventoryItemLink = function(_, slot) return links[slot] end

C_SpecializationInfo = {
    GetSpecialization = function() return 1 end,
    GetSpecializationInfo = function() return 71, "Arms" end,
}

-- Every section can be read (small data), then the professions are this character's own.
local g = World.full()
g.trade.professions = {
    { name = "Blacksmithing", rank = 225, maxRank = 300, line = 164 },
    { name = "Zul\195\182te |cffff0000\"Bergbau\"|r", rank = 10, maxRank = 75, line = 186 },
}
g.player.rested = 250000
g.quests.ids = { 4, 8, 15, 16, 23, 42, 1001, 1002 }

local world = {
    open = false,
    enum = { CharacterBankTab_1 = 6, AccountBankTab_1 = 12 },
    slots = { [0] = 4, [1] = 2, [6] = 3, [12] = 2 },
    items = { [0] = { 6948, nil, 2589 }, [1] = { 4540 }, [6] = { 21, 22, 12640 }, [12] = { 91, 12640 } },
    bankBags = { [6] = true, [12] = true },
}
Env.installContainers(world)
Env.load()

-- An earlier session read the Blacksmithing recipes: they are in the cache, this
-- session did not open that window. (The cache is the saved variable, kept by the client.)
WowcharExportDB = {
    ["Argent Dawn"] = {
        Thorin = {
            v = 1,
            recipes = {
                [164] = { at = 1791913600, name = "Blacksmithing", recipes = { [2663] = { { 2840, 1 } }, [2662] = { { 2840, 2 }, { 2589, 1 } } } },
            },
        },
    },
}

world.open = true
Env.fire("BANKFRAME_OPENED")
Env.fire("TAXIMAP_OPENED")
print(Env.run())
