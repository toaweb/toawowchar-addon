-- One complete, deterministic export from the real addon code with stubbed game
-- data: equipped items with links (and one without), bags, the bank and the
-- warband bank, professions, a spec. Prints the text /wowchar makes; the test
-- compares it with app/test/fixtures/addon-export-v2.txt and decodes it on the
-- server side. Run from the repository root.
local Env = dofile("app/test/lua/wow-env.lua")

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

GetProfessions = function() return 1, nil, 3 end
GetProfessionInfo = function(index)
    if index == 1 then return "Blacksmithing", nil, 225, 300, nil, nil, 164 end
    return "Zul\195\182te |cffff0000\"Bergbau\"|r", nil, 10, 75, nil, nil, 186
end
C_SpecializationInfo = {
    GetSpecialization = function() return 1 end,
    GetSpecializationInfo = function() return 71, "Arms" end,
}

local world = {
    open = false,
    enum = { CharacterBankTab_1 = 6, AccountBankTab_1 = 12 },
    slots = { [0] = 4, [1] = 2, [6] = 3, [12] = 2 },
    items = { [0] = { 6948, nil, 2589 }, [1] = { 4540 }, [6] = { 21, 22, 12640 }, [12] = { 91, 12640 } },
    bankBags = { [6] = true, [12] = true },
}
Env.installContainers(world)
Env.load()
world.open = true
Env.fire("BANKFRAME_OPENED")
print(Env.run())
