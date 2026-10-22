-- Stubbed run of toawowchar/toawowchar.lua (Lua 5.1, no WoW client).
-- Usage: lua race-stub.lua <scenario>   (run from the repository root)
-- Prints the export text /wowchar makes (one line) for a client whose
-- UnitRace and UnitFactionGroup answer in the way the scenario says; the test
-- parses it. A failing scenario raises, so the exit code is non-zero.
local scenario = arg[1] or "nightelf"
local Env = dofile("test/lua/wow-env.lua")

if scenario == "nightelf" then
    UnitRace = function() return "Night Elf", "NightElf", 4 end
    UnitFactionGroup = function() return "Alliance", "Alliance" end
elseif scenario == "scourge" then
    UnitRace = function() return "Undead", "Scourge", 5 end
    UnitFactionGroup = function() return "Horde", "Horde" end
elseif scenario == "neutral" then
    UnitRace = function() return "Pandaren", "Pandaren", 24 end
    UnitFactionGroup = function() return "Neutral", "Neutral" end
elseif scenario == "unknown-token" then
    -- A token no list knows (the Forever Skyborne tokens are not confirmed): sent as is.
    UnitRace = function() return "Skyborne", "HighOrderSkyborne", 100 end
    UnitFactionGroup = function() return "Alliance", "Alliance" end
elseif scenario == "nil-returns" then
    UnitRace = function() return nil end
    UnitFactionGroup = function() return nil end
elseif scenario == "partial" then
    -- Race answers, faction does not.
    UnitFactionGroup = function() return nil end
elseif scenario == "missing" then
    UnitRace, UnitFactionGroup = nil, nil
elseif scenario == "erroring" then
    UnitRace = function() error("boom") end
    UnitFactionGroup = function() error("boom") end
elseif scenario == "wrongtypes" then
    UnitRace = function() return "Night Elf", 4, 4 end
    UnitFactionGroup = function() return 1, "Alliance" end
elseif scenario == "empty" then
    UnitRace = function() return "", "", 0 end
    UnitFactionGroup = function() return "", "" end
elseif scenario == "name-only" then
    -- The first return only (no file token): no race. No faction either.
    UnitRace = function() return "Night Elf" end
    UnitFactionGroup = function() return nil end
else
    error("unknown scenario " .. scenario)
end

Env.load()
print(Env.run())
