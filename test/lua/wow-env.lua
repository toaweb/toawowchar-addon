-- A stub of the WoW API for running addon/WowcharExport/WowcharExport.lua in
-- plain Lua 5.1 (no client). Usage from a test script, run from the repository
-- root:
--     local Env = dofile("app/test/lua/wow-env.lua")
--     Env.load()               -- loads the addon; Env.ns has its helpers
--     Env.fire("BANKFRAME_OPENED")
--     local text = Env.run()   -- what /wowchar puts in the copy box
local Env = {}

Env.editBox = nil
Env.frames = {}
Env.ns = {}

-- A frame stub: SetScript and SetText are remembered, every other method does
-- nothing and returns the frame.
local methods = {
    SetScript = function(self, name, fn) self.scripts[name] = fn end,
    SetText = function(self, text) self.text = text end,
    GetText = function(self) return self.text or "" end,
}
local frameMeta = {
    __index = function(self, key)
        return methods[key] or function() return self end
    end,
}

function CreateFrame(_, name)
    local f = setmetatable({ scripts = {}, name = name }, frameMeta)
    if name == "WowcharExportEditBox" then
        Env.editBox = f
    end
    Env.frames[#Env.frames + 1] = f
    return f
end

UIParent = CreateFrame("Frame")
UISpecialFrames = {}
tinsert = table.insert
SlashCmdList = {}
ChatFontNormal = {}
time = function() return 1792000000 end

-- Identity and client, the same in every scenario unless a script changes them.
UnitName = function() return "Thor" end
UnitClass = function() return "Warrior", "WARRIOR", 1 end
UnitLevel = function() return 60 end
UnitGUID = function() return "Player-0000-00000001" end
GetBuildInfo = function() return "1.60.1", "70450", "Jan 1 2026", 16001 end
GetInventoryItemID = function() return nil end
GetInventoryItemLink = function() return nil end
GetCurrentRegion = function() return 3 end
GetCVar = function() return "public" end
GetRealmName = function() return "Forever" end

-- The addon must never use C_EncodingUtil any more; a call would raise.
C_EncodingUtil = setmetatable({}, { __index = function() error("C_EncodingUtil must not be used") end })
-- GetCurrentRegionName errors on the Forever test client and must not be called.
GetCurrentRegionName = function() error("GetCurrentRegionName must not be called") end

-- Sends an event to every frame that has an OnEvent script.
function Env.fire(event)
    for _, f in ipairs(Env.frames) do
        if f.scripts.OnEvent then
            f.scripts.OnEvent(f, event)
        end
    end
end

-- Loads the addon. The second argument stands in for the addon's namespace table
-- the client passes (the addon puts its helpers in it).
function Env.load()
    local chunk = assert(loadfile("addon/WowcharExport/WowcharExport.lua"))
    chunk("WowcharExport", Env.ns)
end

-- Containers. `world` is { slots = {[bag] = n}, items = {[bag] = {[slot] = itemId}},
-- bankBags = {[bag] = true} (readable only while world.open), enum = the table
-- for Enum.BagIndex, onInfo = optional function(bag, slot) called on every
-- slot read }. Bank bags answer nil for every slot while the bank is closed,
-- like the game does.
function Env.installContainers(world)
    Enum = { BagIndex = world.enum or {} }
    local function itemAt(bag, slot)
        if world.bankBags[bag] and not world.open then
            return nil
        end
        local list = world.items[bag]
        return list and list[slot] or nil
    end
    C_Container = {
        GetContainerNumSlots = function(bag) return world.slots[bag] or 0 end,
        GetContainerItemInfo = function(bag, slot)
            if world.onInfo then world.onInfo(bag, slot) end
            local id = itemAt(bag, slot)
            return id and { itemID = id } or nil
        end,
        GetContainerItemLink = function(bag, slot)
            local id = itemAt(bag, slot)
            return id and ("|cffffffff|Hitem:" .. id .. "|h[Item " .. id .. "]|h|r") or nil
        end,
    }
end

-- Types /wowchar and returns the text now in the copy box.
function Env.run()
    SlashCmdList["WOWCHAR"]()
    assert(Env.editBox, "the window was not made")
    return Env.editBox.text
end

return Env
