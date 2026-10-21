-- Stubbed run of addon/toawowchar/toawowchar.lua (Lua 5.1, no WoW client).
-- Usage: lua region-stub.lua <scenario>   (run from the repository root)
-- Prints the export text /wowchar makes (one line) for a client that reports its
-- region in the way the scenario says; the test parses it. A failing scenario
-- raises, so the exit code is non-zero.
local scenario = arg[1] or "eu"
local Env = dofile("app/test/lua/wow-env.lua")

if scenario == "eu" then
    GetCurrentRegion = function() return 3 end
    GetCVar = function() return "public" end
    GetRealmName = function() return "Some Realm" end
elseif scenario == "us" then
    GetCurrentRegion = function() return 1 end
elseif scenario == "kr" then
    GetCurrentRegion = function() return 2 end
elseif scenario == "tw" then
    GetCurrentRegion = function() return 4 end
elseif scenario == "cn" then
    GetCurrentRegion = function() return 5 end
elseif scenario == "forever" then
    GetCurrentRegion = function() return 110 end
    GetCVar = function(name) if name == "portal" then return "test" end end
    GetRealmName = function() return "" end
elseif scenario == "missing" then
    -- No region, CVar or realm function at all.
    GetCurrentRegion, GetCVar, GetRealmName = nil, nil, nil
elseif scenario == "erroring" then
    GetCurrentRegion = function() error("boom") end
    GetCVar = function() error("boom") end
    GetRealmName = function() error("boom") end
elseif scenario == "wrongtypes" then
    GetCurrentRegion = function() return "EU" end
    GetCVar = function() return 5 end
    GetRealmName = nil
else
    error("unknown scenario " .. scenario)
end

Env.load()
print(Env.run())
