-- The event-driven snapshot (the cache kept current by game events), the relog
-- (save, reload, /wowchar), the two slash words and the "no Forever detection by
-- interface number" checks of addon 0.4.0, on small fixed game data. Usage (from the
-- repository root):
--     lua test/lua/snapshot-test.lua <scenario> [variant]
-- Prints lines `label<TAB>value` like sections-test.lua; the value is an export text
-- or JSON written with the addon's own serializer. test/addon-lua.test.mjs parses them.
-- The scenario `relog-text` prints only the export text a character gets after a
-- relog; the test compares it with test/fixtures/export-relog.txt. To make
-- the fixture again after a deliberate change (the variant `blind` is the second file):
--     lua test/lua/snapshot-test.lua relog-text > test/fixtures/export-relog.txt
--     lua test/lua/snapshot-test.lua relog-text blind > test/fixtures/export-relog-blind.txt
local scenario = arg[1] or "relog"
local variant = arg[2]
local Env = dofile("test/lua/wow-env.lua")
local World = dofile("test/lua/world.lua")

local T = Env.now

local function emit(label, value)
    if type(value) == "string" then
        print(label .. "\t" .. value)
    else
        print(label .. "\t" .. Env.ns.Serialize(value))
    end
end

-- A deep copy: what the client writes to disk at logout and reads back at login.
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

-- The small game: every section readable, a closed bank with one character tab and
-- one warband tab, and some gear. Every read of the five snapshot parts is counted.
local gear = {
    [1] = { id = 12640, link = "|cffa335ee|Hitem:12640:2564:213:0:218:0:-9:1234:60:71:0:5:3:1472:6652:7881:1:28:1234|h[Lionheart Helm]|h|r" },
    [2] = { id = 18404, link = "|cffa335ee|Hitem:18404|h[Onyxia Tooth Pendant]|h|r" },
}
local reads = { equipped = 0, bags = 0, quests = 0, professions = 0, player = 0 }

local function game()
    local g = World.full()
    g.world = {
        open = false, enum = { CharacterBankTab_1 = 6, AccountBankTab_1 = 12 },
        slots = { [0] = 2, [6] = 2, [12] = 2 }, items = { [0] = { 900, 901 }, [6] = { 11, 12 }, [12] = { 91, 92 } },
        bankBags = { [6] = true, [12] = true },
        onInfo = function(bag, slot) if bag == 0 and slot == 1 then reads.bags = reads.bags + 1 end end,
    }
    Env.installContainers(g.world)
    GetInventoryItemID = function(_, slot)
        if slot == 1 then reads.equipped = reads.equipped + 1 end
        return gear[slot] and gear[slot].id or nil
    end
    GetInventoryItemLink = function(_, slot) return gear[slot] and gear[slot].link or nil end
    C_SpecializationInfo = {
        GetSpecialization = function() return 1 end,
        GetSpecializationInfo = function() return 71, "Arms" end,
    }
    -- Count the reads (the game's own answers stay those of world.lua).
    local ids = C_QuestLog.GetAllCompletedQuestIDs
    C_QuestLog.GetAllCompletedQuestIDs = function() reads.quests = reads.quests + 1; return ids() end
    local professions = GetProfessions
    GetProfessions = function() reads.professions = reads.professions + 1; return professions() end
    local money = GetMoney
    GetMoney = function() reads.player = reads.player + 1; return money() end
    return g
end

local function counts()
    return { reads.equipped, reads.bags, reads.quests, reads.professions, reads.player }
end

local function resetReads()
    for k in pairs(reads) do reads[k] = 0 end
end

-- The profession window, the flight map and the bank, in this order (as sections-test.lua).
local function openWindows(g)
    g.trade.window = {
        base = { professionID = 197, professionName = "Tailoring" },
        filtered = { 1, 2, 3, 4 },
        recipes = {
            [1] = { learned = true, reagents = { { 2589, 2 }, { 2320, 1 } } },
            [2] = { learned = true, reagents = { { 2589, 3 }, { currencyID = 12, count = 5 }, { 7000, 1, required = false }, { 7001, 1, type = 2 } } },
            [3] = { learned = false, reagents = { { 4306, 1 } } },
            [4] = { learned = true, reagents = {} },
        },
    }
    Env.fire("TRADE_SKILL_LIST_UPDATE")
    Env.flushTimers()
    Env.fire("TAXIMAP_OPENED")
end

local function record()
    return toawowcharDB and toawowcharDB.Forever and toawowcharDB.Forever.Thor
end

-- ── the relog ───────────────────────────────────────────────────────────
-- Session 1: the bank is opened once, a profession window and the flight map are
-- opened, and the game's events fire. The saved table is copied (the client writes
-- it at logout). Session 2: a relog; the bank, the profession window and the flight
-- map are closed (their game functions answer nothing), and /wowchar is typed.
local function relog()
    local g = game()
    Env.useTimers()
    Env.load()
    Env.fire("ADDON_LOADED", "toawowchar")
    g.world.open = true
    Env.fire("BANKFRAME_OPENED")
    Env.fire("BANKFRAME_CLOSED")
    g.world.open = false
    openWindows(g)
    -- play: a new piece of gear, loot, a turned-in quest, a new skill, a level
    gear[16] = { id = 19019, link = "|cffa335ee|Hitem:19019:3368:0:0:0:0:0:0:60|h[Thunderfury]|h|r" }
    Env.fire("PLAYER_EQUIPMENT_CHANGED", 16)
    g.world.items[0] = { 900, 901 }
    Env.fire("BAG_UPDATE_DELAYED")
    g.quests.ids = { 3, 5, 9, 1001 }
    Env.fire("QUEST_TURNED_IN", 1001, 100, 50)
    g.trade.professions[#g.trade.professions + 1] = { name = "Cooking", rank = 5, maxRank = 75, line = 185 }
    Env.fire("SKILL_LINES_CHANGED")
    g.player.level = 61
    g.player.money = 123999999
    Env.fire("PLAYER_LEVEL_UP", 61)
    Env.flushTimers()                    -- one second later: the read asks for a rebuild, the quest's was just now
    Env.flushTimers()                    -- the rest of the interval is over: the rebuild
    local chat1 = Env.chat
    local rec = record()
    local snapshot = { equipped = #rec.equipped.items, bags = rec.bags.ids, quests = rec.quests.ids, professions = #rec.professions.list, level = rec.player.level }
    local before = Env.run()
    local saved = copy(toawowcharDB)

    -- the relog
    Env.relog()
    Env.now = Env.now + 7200
    toawowcharDB = saved
    g.trade.window = nil                 -- no profession window: recipes cannot be read
    g.taxi.maps = {}                     -- no flight map: the taxi functions answer nothing
    g.world.open = false                 -- no bank: its bags answer nothing
    if variant == "blind" then
        -- the game also hides the money (a secret value: the player section is missing/in_combat) and has no profession list
        GetProfessions = nil
        GetMoney = function() return 77777777 end
        issecretvalue = function(v) return v == 77777777 end
    end
    Env.load()
    Env.fire("ADDON_LOADED", "toawowchar")
    return { before = before, chat1 = chat1, snapshot = snapshot, g = g }
end

if scenario == "relog-text" then
    local r = relog()
    assert(Env.slash("/wowchar"), "/wowchar answers")
    print(Env.editBox.text)

elseif scenario == "relog" then
    local r = relog()
    emit("chat-session1", r.chat1)
    emit("snapshot", r.snapshot)
    emit("session1", r.before)
    assert(Env.slash("/wowchar"), "/wowchar answers")
    emit("relog", Env.editBox.text)
    Env.editBox.text = ""
    assert(Env.slash("/toawowchar"), "/toawowchar answers")
    emit("relog-alias", Env.editBox.text)
    emit("chat-session2", Env.chat)
    emit("window", Env.windowText())

-- ── the events and what each one refreshes ──────────────────────────────
elseif scenario == "events" then
    local g = game()
    Env.useTimers()
    Env.load()
    local order = { "PLAYER_EQUIPMENT_CHANGED", "BAG_UPDATE_DELAYED", "QUEST_TURNED_IN", "SKILL_LINES_CHANGED", "PLAYER_MONEY", "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP" }
    for i, event in ipairs(order) do
        Env.now = T + i * 100 -- far apart: the throttle is not in play
        resetReads()
        Env.fire(event, 1)
        if event == "PLAYER_LEVEL_UP" then
            -- read one second later, not when the event fires
            emit("level-up-at-once", counts())
            emit("level-up-delays", Env.timerDelays)
            Env.flushTimers()
        end
        emit(event, counts())
    end
    emit("timers", { #Env.timers })
    emit("chat", Env.chat)
    local rec = record()
    emit("cache", {
        equipped = rec.equipped.items, bags = rec.bags.ids, quests = rec.quests.ids,
        professions = rec.professions.list, player = rec.player,
    })

elseif scenario == "throttle" then
    local g = game()
    Env.useTimers()
    Env.load()
    Env.now = T
    Env.fire("PLAYER_EQUIPMENT_CHANGED")
    emit("first", { reads.equipped, #Env.timers })
    -- five more events in the next four seconds: no rebuild, ONE scheduled for when the interval is over
    gear[3] = { id = 1001, link = nil }
    for i = 1, 4 do
        Env.now = T + i
        Env.fire("PLAYER_EQUIPMENT_CHANGED")
    end
    Env.fire("PLAYER_EQUIPMENT_CHANGED")
    emit("burst", { reads.equipped, #Env.timers, Env.timerDelays[1] })
    -- another section is not held back by this one
    resetReads()
    Env.fire("BAG_UPDATE_DELAYED")
    emit("other-section", { reads.bags, reads.equipped, #Env.timers })
    -- the last change in the burst is in the cache after the trailing rebuild
    gear[4] = { id = 1002, link = nil }
    resetReads()
    Env.now = T + 5
    Env.flushTimers()
    local items = {}
    for _, item in ipairs(record().equipped.items) do items[#items + 1] = item.slot end
    emit("trailing", { reads.equipped, #Env.timers, items })
    -- an event after the interval: at once, nothing scheduled
    resetReads()
    Env.now = T + 30
    Env.fire("PLAYER_EQUIPMENT_CHANGED")
    emit("later", { reads.equipped, #Env.timers })
    -- and one right after it waits for the rest of the interval
    resetReads()
    Env.now = T + 32
    Env.fire("PLAYER_EQUIPMENT_CHANGED")
    emit("wait", { reads.equipped, #Env.timers, Env.timerDelays[1] })
    emit("chat", Env.chat)

elseif scenario == "clock-back" then
    -- The clock goes back: the wait is never longer than the interval.
    local g = game()
    Env.useTimers()
    Env.load()
    Env.now = T + 1000
    Env.fire("PLAYER_MONEY")
    Env.now = T
    Env.fire("PLAYER_MONEY")
    emit("delay", { Env.timerDelays[1] })

elseif scenario == "combat" then
    local g = game()
    Env.useTimers()
    Env.load()
    Env.now = T
    Env.combat = true
    for _ = 1, 3 do
        Env.fire("PLAYER_EQUIPMENT_CHANGED")
        Env.fire("BAG_UPDATE_DELAYED")
        Env.fire("QUEST_TURNED_IN", 1001)
        Env.fire("SKILL_LINES_CHANGED")
        Env.fire("PLAYER_MONEY")
        Env.fire("PLAYER_XP_UPDATE")
    end
    emit("in-combat", { counts(), #Env.timers })
    -- combat ends: every section is rebuilt once
    Env.combat = false
    Env.now = T + 60
    Env.fire("PLAYER_REGEN_ENABLED")
    emit("after-combat", { counts(), #Env.timers })
    -- nothing is pending any more
    Env.fire("PLAYER_REGEN_ENABLED")
    emit("again", { counts() })
    emit("chat", Env.chat)
    -- a rebuild scheduled before combat that fires in combat waits as well
    resetReads()
    Env.now = T + 100
    Env.fire("PLAYER_MONEY")         -- at once
    Env.now = T + 101
    Env.fire("PLAYER_XP_UPDATE")     -- scheduled
    Env.combat = true
    Env.flushTimers()
    emit("timer-in-combat", { counts(), #Env.timers })
    Env.combat = false
    Env.now = T + 200
    Env.fire("PLAYER_REGEN_ENABLED")
    emit("timer-after-combat", { counts() })

elseif scenario == "quest-turned-in" then
    local g = game()
    Env.useTimers()
    Env.load()
    Env.now = T
    -- never read before: one id would look like a complete list, so only the game's list is used
    g.quests.ids = {}
    Env.fire("QUEST_TURNED_IN", 777)
    emit("no-cache", { record() and record().quests and 1 or 0 })
    -- read once, then quests are turned in and the game's list does not have them yet
    g.quests.ids = { 3, 5, 9 }
    Env.now = T + 100
    Env.run()
    emit("cached", record().quests.ids)
    Env.now = T + 200
    Env.fire("QUEST_TURNED_IN", 777) -- the rebuild runs at once
    Env.now = T + 201
    Env.fire("QUEST_TURNED_IN", 778) -- the rebuild waits for the interval, the id does not
    emit("immediately", { record().quests.ids, #Env.timers })
    -- bad ids are ignored
    Env.now = T + 300
    Env.fire("QUEST_TURNED_IN", "x")
    Env.fire("QUEST_TURNED_IN", -4)
    Env.fire("QUEST_TURNED_IN", 2 ^ 40)
    Env.fire("QUEST_TURNED_IN", nil)
    emit("bad-ids", record().quests.ids)
    emit("chat", Env.chat)

elseif scenario == "reset" then
    -- /wowchar reset forgets the snapshot; a rebuild scheduled before it does not bring it back
    local g = game()
    Env.useTimers()
    Env.load()
    Env.now = T
    Env.fire("PLAYER_EQUIPMENT_CHANGED")
    Env.now = T + 1
    Env.fire("PLAYER_EQUIPMENT_CHANGED")
    emit("scheduled", { #Env.timers })
    emit("before-reset", { record().equipped and 1 or 0 })
    assert(Env.slash("/toawowchar reset"))
    emit("db-after-reset", toawowcharDB)
    Env.flushTimers()
    emit("db-after-timer", toawowcharDB)
    emit("chat", Env.chat)
    -- the next event after the reset is a fresh start (nothing is throttled)
    Env.now = T + 2
    resetReads()
    Env.fire("PLAYER_EQUIPMENT_CHANGED")
    emit("fresh", { reads.equipped, record().equipped and 1 or 0 })

elseif scenario == "no-timer" then
    -- A client without C_Timer: every event rebuilds at once, nothing is scheduled, nothing raises.
    local g = game()
    Env.load()
    Env.now = T
    for _ = 1, 3 do Env.fire("PLAYER_EQUIPMENT_CHANGED") end
    emit("reads", counts())
    emit("timer", { C_Timer == nil })

elseif scenario == "hidden" then
    -- A value the game hides (a secret value) is never written to the snapshot.
    local g = game()
    local hidden = {}
    issecretvalue = function(v) return hidden[v] == true end
    Env.useTimers()
    Env.load()
    Env.now = T
    Env.fire("PLAYER_MONEY")
    emit("first", { record().player.money })
    hidden[g.player.money] = true
    Env.now = T + 100
    Env.fire("PLAYER_MONEY")
    emit("hidden", { record().player.money, record().player.at })

elseif scenario == "player-events" then
    -- Gold and XP events: the same 5-second throttle as every part, no chat.
    local g = game()
    Env.useTimers()
    Env.load()
    Env.now = T
    Env.fire("PLAYER_MONEY")
    emit("first", { reads.player, #Env.timers })
    -- a burst of money and XP events in the next four seconds: no read, ONE timer for the rest of the interval
    for i = 1, 4 do
        Env.now = T + i
        g.player.money = 1000 + i
        g.player.xp = 2000 + i
        Env.fire(i % 2 == 0 and "PLAYER_MONEY" or "PLAYER_XP_UPDATE", "player")
    end
    emit("burst", { reads.player, #Env.timers, Env.timerDelays[1] })
    -- the last value of the burst is not in the cache yet ...
    emit("before-timer", { record().player.money, record().player.xp })
    -- ... and the one trailing rebuild brings it
    g.player.money = 5555
    g.player.xp = 4444
    resetReads()
    Env.now = T + 5
    Env.flushTimers()
    emit("trailing", { reads.player, #Env.timers, record().player.money, record().player.xp })
    emit("chat", Env.chat)

elseif scenario == "player-combat" then
    -- In combat nothing is read and nothing is scheduled; PLAYER_REGEN_ENABLED rebuilds once.
    local g = game()
    Env.useTimers()
    Env.load()
    Env.now = T
    Env.combat = true
    for _ = 1, 3 do
        Env.fire("PLAYER_MONEY")
        Env.fire("PLAYER_XP_UPDATE", "player")
    end
    emit("in-combat", { reads.player, #Env.timers, record() and record().player and 1 or 0 })
    g.player.money = 777
    Env.combat = false
    Env.now = T + 60
    Env.fire("PLAYER_REGEN_ENABLED")
    emit("after-combat", { reads.player, #Env.timers, record().player.money })
    Env.fire("PLAYER_REGEN_ENABLED")
    emit("again", { reads.player })
    emit("chat", Env.chat)

elseif scenario == "level-up" then
    -- The client still answers the old level and XP max when PLAYER_LEVEL_UP fires; they
    -- change one tick later. The stub's answers change when the timer runs.
    local g = game()
    Env.useTimers()
    Env.load()
    Env.now = T
    g.player.level = 59
    g.player.xpMax = 5000
    Env.fire("PLAYER_LEVEL_UP", 60)
    emit("at-once", { reads.player, record() and record().player and 1 or 0, Env.timerDelays[1], #Env.timers })
    g.player.level = 60
    g.player.xpMax = 6000
    g.player.xp = 12
    Env.flushTimers()
    local p = record().player
    emit("after-one-tick", { reads.player, p.level, p.xpMax, p.xp })
    emit("chat", Env.chat)

elseif scenario == "level-up-throttled" then
    -- The delayed read goes through the throttle: a rebuild a moment ago makes it wait for the rest of the interval.
    local g = game()
    Env.useTimers()
    Env.load()
    Env.now = T
    g.player.level = 59
    Env.fire("PLAYER_XP_UPDATE")          -- the kill: read at once, still level 59
    Env.now = T + 1
    g.player.level = 60
    Env.fire("PLAYER_LEVEL_UP", 60)
    Env.flushTimers()                     -- 1 s later: inside the interval, so it schedules the rest (4 s)
    emit("waiting", { reads.player, #Env.timers, Env.timerDelays[1], record().player.level })
    Env.now = T + 5
    Env.flushTimers()
    emit("trailing", { reads.player, #Env.timers, record().player.level })

elseif scenario == "level-up-combat" then
    -- A level-up in combat: nothing is read, and one rebuild follows PLAYER_REGEN_ENABLED.
    local g = game()
    Env.useTimers()
    Env.load()
    Env.now = T
    Env.combat = true
    g.player.level = 61
    Env.fire("PLAYER_LEVEL_UP", 61)
    Env.flushTimers()
    emit("in-combat", { reads.player, #Env.timers, record() and record().player and 1 or 0 })
    Env.combat = false
    Env.now = T + 10
    Env.fire("PLAYER_REGEN_ENABLED")
    emit("after-combat", { reads.player, #Env.timers, record().player.level })

elseif scenario == "level-up-reset" then
    -- /wowchar reset between the event and the read: the read does nothing.
    local g = game()
    Env.useTimers()
    Env.load()
    Env.now = T
    Env.fire("PLAYER_LEVEL_UP", 61)
    assert(Env.slash("/toawowchar reset"))
    Env.flushTimers()
    emit("record", { record() and 1 or 0 })
    emit("reads", { reads.player })

elseif scenario == "level-up-no-timer" then
    -- A client without C_Timer: the player part is read at once.
    local g = game()
    Env.load()
    Env.now = T
    g.player.level = 61
    Env.fire("PLAYER_LEVEL_UP", 61)
    emit("reads", { reads.player, record().player.level })

-- What the saved record holds after everything the addon can capture: the keys, for the pin against ADDON_CACHED_SECTIONS.
elseif scenario == "cached-keys" then
    local r = relog()
    local keys = {}
    for key in pairs(record()) do keys[#keys + 1] = key end
    table.sort(keys)
    emit("keys", keys)

elseif scenario == "damaged" then
    -- The four new parts of a damaged record are rebuilt field by field.
    toawowcharDB = {
        Forever = {
            Thor = {
                equipped = { at = T, items = {
                    { slot = 1, itemId = 5, enchantId = "x", gemIds = { 1, "a", 2 }, suffixId = -3, bonusIds = { 9, 8, 9 } },
                    { slot = 99, itemId = 6 }, { slot = 2, itemId = 2 ^ 40 }, "no",
                } },
                bags = { at = T, ids = { 4, 4, "x", 0, 2 ^ 40, 3 }, cut = "yes" },
                professions = { at = T, list = { { name = "Tailoring", skillLineId = 197, rank = 2000000, maxRank = 75 }, { name = "" }, "no", { name = string.rep("p", 65) } } },
                player = { at = T, money = 100000000000000, level = 300, xp = 5, xpMax = "x", rested = -1 },
            },
        },
    }
    local g = game()
    Env.load()
    Env.fire("ADDON_LOADED", "toawowchar")
    -- The record is rebuilt the first time it is used; opening a bank that holds nothing uses it without writing the four parts.
    Env.fire("BANKFRAME_OPENED")
    local clean = record()
    emit("equipped", clean.equipped)
    emit("bags", clean.bags)
    emit("professions", clean.professions)
    emit("player", clean.player)

-- ── the two slash words ─────────────────────────────────────────────────
elseif scenario == "slash" then
    local g = game()
    Env.load()
    emit("globals", { SLASH_WOWCHAR1, SLASH_WOWCHAR2, SLASH_WOWCHAR3 or "none" })
    emit("handlers", { type(SlashCmdList["WOWCHAR"]) })
    local function opened() return Env.editBox ~= nil and Env.editBox.text ~= nil and Env.editBox.text ~= "" end
    local answered = Env.slash("/wowchar")
    emit("wowchar", { answered, opened() })
    local first = Env.editBox.text
    Env.editBox.text = ""
    answered = Env.slash("/toawowchar")
    emit("toawowchar", { answered, Env.editBox.text == first })
    Env.editBox.text = ""
    answered = Env.slash("/TOAWOWCHAR")
    emit("upper", { answered, Env.editBox.text == first })
    emit("other", { Env.slash("/other") })
    -- reset by either word
    Env.run()
    emit("db-before", { record() and 1 or 0 })
    Env.chat = {}
    answered = Env.slash("/wowchar reset")
    emit("reset-wowchar", { answered, record() and 1 or 0 })
    emit("chat-wowchar", Env.chat)
    Env.run()
    Env.chat = {}
    answered = Env.slash("/toawowchar reset")
    emit("reset-toawowchar", { answered, record() and 1 or 0 })
    emit("chat-toawowchar", Env.chat)

-- ── Forever is recognised by which functions exist ──────────────────────
elseif scenario == "interface" then
    -- variant "<interface>[:<WOW_PROJECT_ID>]": the same game under another interface number
    local number, project = (variant or "16001"):match("^(%d+):?(%d*)$")
    GetBuildInfo = function() return "9.9.9", "12345", "Jan 1 2030", tonumber(number) end
    if project ~= "" then
        WOW_PROJECT_ID = tonumber(project)
        WOW_PROJECT_MAINLINE, WOW_PROJECT_CLASSIC, WOW_PROJECT_CATA_CLASSIC = 1, 2, 14
    end
    local g = game()
    Env.useTimers()
    Env.load()
    openWindows(g)
    emit("export", Env.run())

elseif scenario == "without" then
    -- variant: the dotted name of a game function that does not exist in this client
    local g = game()
    Env.useTimers()
    Env.load()
    local path = {}
    for part in (variant or ""):gmatch("[^.]+") do path[#path + 1] = part end
    local holder = _G
    for i = 1, #path - 1 do holder = holder[path[i]] end
    holder[path[#path]] = nil
    openWindows(g)
    emit("export", Env.run())

else
    error("unknown scenario " .. tostring(scenario))
end
