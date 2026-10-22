-- The bank guard and the warband bank, run through the addon's events and
-- /wowchar. Usage: lua test/lua/bank-test.lua <scenario> (from the repo root).
-- Prints one export text per line, one for each /wowchar the scenario types; the
-- test/addon-lua.test.mjs parses them.
local scenario = arg[1]
local Env = dofile("test/lua/wow-env.lua")

-- Character bank tabs 6..8 and warband tabs 12..14 (the numbers are arbitrary).
local world = {
    open = false,
    enum = { CharacterBankTab_1 = 6, CharacterBankTab_2 = 7, AccountBankTab_1 = 12, AccountBankTab_2 = 13, AccountBankTab_3 = 14 },
    slots = { [0] = 4, [6] = 3, [7] = 3, [12] = 3, [13] = 3, [14] = 0 },
    items = { [0] = { 900, 901 }, [6] = { 1, 2, 3 }, [7] = { 4 }, [12] = { 91, 92 }, [13] = { nil, nil, 93 } },
    bankBags = { [6] = true, [7] = true, [12] = true, [13] = true, [14] = true },
}

local function open()
    world.open = true
    Env.fire("BANKFRAME_OPENED")
end
local function close()
    world.open = false
    Env.fire("BANKFRAME_CLOSED")
end
local function out() print(Env.run()) end

if scenario == "enum-missing" then
    world.enum = { CharacterBankTab_1 = 6, CharacterBankTab_2 = 7 } -- no AccountBankTab_*
elseif scenario == "stops-at-first-missing" then
    world.enum.AccountBankTab_4 = nil
    world.enum.AccountBankTab_5 = 15
    world.slots[15] = 2
    world.items[15] = { 95, 96 }
    world.bankBags[15] = true
elseif scenario == "tabs-without-slots" then
    world.slots[12], world.slots[13] = 0, 0
end

Env.installContainers(world)
Env.load()

if scenario == "never-opened" then
    out()
elseif scenario == "enum-missing" or scenario == "stops-at-first-missing" or scenario == "tabs-without-slots" or scenario == "open" then
    open()
    out()
elseif scenario == "closed-before-the-end" then
    -- First a full read; then the bank closes while the next scan is running, so
    -- the slots after that point read as empty: the first list must stay.
    open()
    out()
    close()
    world.items[6], world.items[7] = { 7 }, nil
    world.items[12], world.items[13] = { 97 }, nil
    local reads = 0
    world.onInfo = function()
        reads = reads + 1
        if reads == 2 then close() end
    end
    world.open = true
    Env.fire("BANKFRAME_OPENED")
    world.onInfo = nil
    out()
elseif scenario == "closed-flag-only" then
    -- The close event arrives during the scan although the slots still read: the
    -- flag alone makes the scan untrusted.
    open()
    out()
    world.items[6], world.items[7] = { 7 }, nil
    world.onInfo = function()
        Env.fire("BANKFRAME_CLOSED")
    end
    Env.fire("BAG_UPDATE_DELAYED")
    world.onInfo = nil
    out()
elseif scenario == "still-open-replaces" then
    open()
    out()
    world.items[6], world.items[7] = { 7 }, nil
    world.items[12], world.items[13] = { 97 }, nil
    Env.fire("BAG_UPDATE_DELAYED") -- the bank is still open: scanned again
    out()
elseif scenario == "empty-scan-keeps" then
    open()
    out()
    world.items[6], world.items[7], world.items[12], world.items[13] = nil, nil, nil, nil
    Env.fire("BAG_UPDATE_DELAYED")
    out()
elseif scenario == "empty-first-scan" then
    -- Nothing in the bank at all the first time: nothing was seen.
    world.items[6], world.items[7], world.items[12], world.items[13] = nil, nil, nil, nil
    open()
    out()
elseif scenario == "not-loaded" then
    -- Open, but the last item's link is not there yet: the scan is not trusted.
    open()
    out()
    world.items[6], world.items[7] = { 7 }, nil
    local link = C_Container.GetContainerItemLink
    C_Container.GetContainerItemLink = function() return nil end
    Env.fire("BAG_UPDATE_DELAYED")
    out()
    C_Container.GetContainerItemLink = link
elseif scenario == "scan-after-close-ignored" then
    open()
    out()
    close()
    world.items[6] = { 7 }
    Env.fire("BAG_UPDATE_DELAYED") -- the bank is closed: no scan
    out()
elseif scenario == "closed-during-warband-scan" then
    -- The bank closes while the warband tabs are read (after the character
    -- tabs): the whole scan is not trusted, both lists stay.
    open()
    out()
    world.items[6], world.items[7] = { 7 }, nil
    world.items[12], world.items[13] = { 97 }, nil
    world.onInfo = function(bag)
        if bag == 12 then close() end
    end
    Env.fire("BAG_UPDATE_DELAYED")
    world.onInfo = nil
    out()
elseif scenario == "warband-not-loaded" then
    -- Each list has its own guard: the warband's last item shows no link, the
    -- character bank's does. The character list is replaced, the warband list stays.
    open()
    out()
    world.items[6], world.items[7] = { 7 }, nil
    world.items[12], world.items[13] = { 97 }, nil
    local link = C_Container.GetContainerItemLink
    C_Container.GetContainerItemLink = function(bag, slot)
        if bag >= 12 then return nil end
        return link(bag, slot)
    end
    Env.fire("BAG_UPDATE_DELAYED")
    out()
elseif scenario == "cap" then
    -- 600 different items in the bank and the warband bank: each list is cut at 500.
    world.slots[6], world.slots[12] = 600, 600
    world.items[6], world.items[12] = {}, {}
    for i = 1, 600 do
        world.items[6][i] = 10000 + i
        world.items[12][i] = 20000 + i
    end
    open()
    out()
else
    error("unknown scenario " .. tostring(scenario))
end
