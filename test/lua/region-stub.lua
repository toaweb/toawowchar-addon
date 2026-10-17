-- Stubbed run of addon/WowcharExport/WowcharExport.lua (Lua 5.1, no WoW client).
-- Usage: lua region-stub.lua <scenario>   (run from the repository root)
-- Prints one line per identity field the addon sent: region, regionId, portal,
-- realm. A failing scenario raises, so the exit code is non-zero.
local scenario = arg[1] or "eu"

-- Any method on a frame stub does nothing and returns the stub.
local function stub()
    local t = {}
    return setmetatable(t, { __index = function(self) return function() return self end end })
end

CreateFrame = function() return stub() end
UIParent = stub()
UISpecialFrames = {}
tinsert = table.insert
SlashCmdList = {}
ChatFontNormal = stub()
time = os.time

UnitName = function() return "Thor" end
UnitClass = function() return "Warrior", "WARRIOR", 1 end
UnitLevel = function() return 60 end
UnitGUID = function() return "Player-0000-00000001" end
GetBuildInfo = function() return "1.0", "70450", "Jan 1 2026", 16001 end
GetInventoryItemID = function() return nil end
GetInventoryItemLink = function() return nil end

-- The Forever test client errors on this one; it must never be called.
GetCurrentRegionName = function() error("GetCurrentRegionName must not be called") end

local captured
C_EncodingUtil = {
    SerializeJSON = function(payload) captured = payload; return "{}" end,
    CompressString = function(s) return s end,
    EncodeBase64 = function(s) return s end,
}
Enum = { CompressionMethod = { Deflate = 0 } }

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
elseif scenario == "erroring" then
    GetCurrentRegion = function() error("boom") end
    GetCVar = function() error("boom") end
    GetRealmName = function() error("boom") end
elseif scenario == "wrongtypes" then
    GetCurrentRegion = function() return "EU" end
    GetCVar = function() return 5 end
else
    error("unknown scenario " .. scenario)
end

dofile("addon/WowcharExport/WowcharExport.lua")
SlashCmdList["WOWCHAR"]()

assert(captured, "no payload was built")
local id = captured.identity
print("region=" .. tostring(id.region))
print("regionId=" .. tostring(id.regionId))
print("portal=" .. tostring(id.portal))
print("realm=" .. tostring(id.realm))
print("name=" .. tostring(id.name))
