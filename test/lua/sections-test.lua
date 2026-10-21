-- The sections of addon 0.4.0, the cache, the captures and the window, on small
-- fixed game data. Usage (from the repository root):
--     lua app/test/lua/sections-test.lua <scenario>
-- Prints lines `label<TAB>value`: the value is an export text, or JSON written
-- with the addon's own serializer (chat lines, window text, the saved table).
-- The Vitest test (addon-lua.test.ts) parses them. A failing assertion in a
-- scenario raises, so the exit code is non-zero.
local scenario = arg[1] or "full"
local variant = arg[2]
local Env = dofile("app/test/lua/wow-env.lua")
local World = dofile("app/test/lua/world.lua")

local function emit(label, value)
    if type(value) == "string" then
        print(label .. "\t" .. value)
    else
        print(label .. "\t" .. Env.ns.Serialize(value))
    end
end

local function out(label)
    emit(label or "export", Env.run())
end

-- The small game, with containers: a closed bank with one character tab and one warband tab.
local function full()
    local g = World.full()
    g.world = {
        open = false, enum = { CharacterBankTab_1 = 6, AccountBankTab_1 = 12 },
        slots = { [0] = 2, [6] = 2, [12] = 2 }, items = { [0] = { 900, 901 }, [6] = { 11, 12 }, [12] = { 91, 92 } },
        bankBags = { [6] = true, [12] = true },
    }
    Env.installContainers(g.world)
    return g
end

local function open_windows(g)
    -- the profession window, the flight map and the bank, in this order
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

local function chat() return Env.chat end

-- ── scenarios ───────────────────────────────────────────────────────────
if scenario == "bare" then
    -- None of the new game functions exist: only what 0.3.1 read is live, the rest says why.
    Env.load()
    out()
    emit("chat", chat())
    emit("db", toawowcharDB or {})

elseif scenario == "full" then
    local g = full()
    Env.useTimers()
    Env.load()
    Env.fire("ADDON_LOADED", "toawowchar")
    open_windows(g)
    out()
    emit("chat", chat())
    emit("window", Env.windowText())
    emit("log", g.rep.log)

elseif scenario == "quests-login" then
    -- The completed list is empty just after login (and at logout) and fills in later.
    local g = full()
    g.quests.ids = {}
    Env.load()
    out("empty-no-cache")
    g.quests.ids = { 40, 10 }
    out("filled")
    g.quests.ids = {}
    out("empty-again")
    g.quests.ids = { 10 }
    out("shorter")

elseif scenario == "quests-cache" then
    -- Two play sessions with the saved variable kept between them.
    local g = full()
    g.quests.ids = { 10, 20, 30 }
    Env.load()
    out("session1")
    local saved = toawowcharDB
    Env.relog()
    Env.now = Env.now + 7200
    toawowcharDB = saved
    local g2 = full()
    g2.quests.ids = {}
    Env.load()
    Env.fire("ADDON_LOADED", "toawowchar")
    out("session2-empty")
    g2.quests.ids = { 20, 40 }
    out("session2-filled")
    emit("db", toawowcharDB)

elseif scenario == "quests-missing-function" then
    local g = full()
    g.quests.missing = true
    C_QuestLog.GetAllCompletedQuestIDs = nil
    Env.load()
    out()

elseif scenario == "quests-cap" then
    -- More completed quests than the cap: the lowest ids stay and the export says it cut.
    local g = full()
    local ids = {}
    for i = 1, 5100 do ids[i] = 1000 + i end
    g.quests.ids = ids
    Env.load()
    out()

elseif scenario == "savedvars" then
    -- The saved variable is nil, a string, a number, true, or a table with damaged records.
    local g = full()
    if variant == "string" then toawowcharDB = "garbage"
    elseif variant == "number" then toawowcharDB = 5
    elseif variant == "true" then toawowcharDB = true
    elseif variant == "damaged" then
        toawowcharDB = {
            Forever = {
                Thor = {
                    bank = { at = "yesterday", items = { 1, 2 } },
                    warbank = { at = 1790000000, items = { 5, "x", -1, 1.5, 2 ^ 40, 7 } },
                    recipes = {
                        [197] = { at = 1790000000, name = "Tailoring\1", recipes = { [5] = { { 2589, 2 }, { "x", 1 }, { 100, 0 }, { 100, 99999 }, { 7, 7 } }, [-3] = {}, [6] = "no" } },
                        [-5] = { at = 1790000000, recipes = {} },
                        [198] = "no",
                    },
                    flights = { at = 1790000000, ids = { 3, 2, 3, "a", 0 } },
                    quests = { at = 1790000000, ids = { 9, 8, 9 } },
                    legacy = { at = 1790000000, trees = { { tree = 1187, spent = "x", nodes = { { 1, 1, 1 }, { 2, 0, 0 }, { 3, 999, 0 }, "no" } }, "no" } },
                },
            },
            ["Other"] = "no",
        }
    elseif variant == "realm-not-table" then
        toawowcharDB = { Forever = 5 }
    end
    Env.load()
    Env.fire("ADDON_LOADED", "toawowchar")
    out()
    emit("db-type", type(toawowcharDB))

elseif scenario == "bank-cache" then
    -- The bank read in one session shows as cache in the next, a new read replaces it,
    -- /wowchar reset forgets it.
    local world = {
        open = false, enum = { CharacterBankTab_1 = 6, AccountBankTab_1 = 12 },
        slots = { [0] = 4, [6] = 3, [12] = 3 }, items = { [0] = { 900 }, [6] = { 1, 2, 3 }, [12] = { 91, 92 } },
        bankBags = { [6] = true, [12] = true },
    }
    Env.installContainers(world)
    Env.load()
    world.open = true
    Env.fire("BANKFRAME_OPENED")
    emit("chat-open", chat())
    Env.fire("BANKFRAME_CLOSED")
    emit("chat-closed", chat())
    world.open = false
    out("session1")
    local saved = toawowcharDB
    Env.relog()
    Env.now = Env.now + 3 * 86400 + 60
    toawowcharDB = saved
    Env.installContainers(world)
    Env.load()
    out("session2-cache")
    world.items[6] = { 7, 8 }
    world.open = true
    Env.fire("BANKFRAME_OPENED")
    Env.fire("BANKFRAME_CLOSED")
    world.open = false
    out("session2-live")
    emit("chat-session2", chat())
    Env.chat = {}
    -- the same bank again: nothing new, nothing said
    world.open = true
    Env.fire("BANKFRAME_OPENED")
    Env.fire("BANKFRAME_CLOSED")
    world.open = false
    emit("chat-same-again", chat())
    Env.run("reset")
    emit("chat-reset", chat())
    emit("db-after-reset", toawowcharDB)
    -- after the reset the window is not opened and the bank is not seen
    out("after-reset")

elseif scenario == "recipes" then
    local g = full()
    g.trade.withAllIds = variant == "all" or variant == "all-empty"
    if g.trade.withAllIds then
        C_TradeSkillUI.GetAllRecipeIDs = function() return g.trade.window and g.trade.window.all or {} end
    end
    Env.useTimers()
    Env.load()
    out("before")
    -- the window shows a filtered view first
    g.trade.window = {
        base = { professionID = 197, professionName = "Tailoring" },
        all = variant == "all" and { 1, 2, 3, 4 } or (variant == "all-empty" and {} or nil),
        filtered = { 1, 2 },
        recipes = {
            [1] = { learned = true, reagents = { { 2589, 2 }, { 2320, 1 } } },
            [2] = { learned = true, reagents = { { 2589, 3 }, { currencyID = 12, count = 5 }, { 7000, 1, required = false }, { 7001, 1, type = 2 } } },
            [3] = { learned = true, reagents = { { 4306, 1 } } },
            [4] = { learned = false, reagents = { { 4307, 1 } } },
        },
    }
    -- several list updates at once are one capture
    Env.fire("TRADE_SKILL_LIST_UPDATE")
    Env.fire("TRADE_SKILL_LIST_UPDATE")
    Env.fire("TRADE_SKILL_DATA_SOURCE_CHANGED")
    emit("timers", { #Env.timers })
    emit("chat-before-flush", chat())
    Env.flushTimers()
    emit("chat-first", chat())
    out("first")
    -- the filter changes: other recipes show up; earlier ones are kept
    Env.chat = {}
    g.trade.window.filtered = { 3, 4 }
    Env.fire("TRADE_SKILL_LIST_UPDATE")
    Env.flushTimers()
    emit("chat-second", chat())
    out("second")
    -- the same recipes again: nothing new, nothing said
    Env.chat = {}
    Env.fire("TRADE_SKILL_LIST_UPDATE")
    Env.flushTimers()
    emit("chat-third", chat())
    -- a second profession
    g.trade.window = {
        base = { professionID = 129, professionName = "First Aid" },
        filtered = { 50 },
        recipes = { [50] = { learned = true, reagents = { { 1251, 1 } } } },
    }
    Env.fire("TRADE_SKILL_LIST_UPDATE")
    Env.flushTimers()
    out("two-professions")

elseif scenario == "recipes-skipped" then
    -- Linked, guild and NPC windows are not the player's own recipes; so are combat and
    -- a window with no base profession.
    local g = full()
    Env.useTimers()
    Env.load()
    local function window()
        g.trade.window = {
            base = { professionID = 197, professionName = "Tailoring" },
            filtered = { 1 },
            recipes = { [1] = { learned = true, reagents = { { 2589, 2 } } } },
        }
    end
    for _, kind in ipairs({ "linked", "guild", "guildMember", "npc" }) do
        window()
        g.trade.window[kind] = true
        Env.fire("TRADE_SKILL_LIST_UPDATE")
        Env.flushTimers()
    end
    window()
    Env.combat = true
    Env.fire("TRADE_SKILL_LIST_UPDATE")
    Env.flushTimers()
    Env.combat = false
    g.trade.window = { filtered = { 1 }, recipes = {} }
    Env.fire("TRADE_SKILL_LIST_UPDATE")
    Env.flushTimers()
    emit("chat", chat())
    out("nothing-saved")
    window()
    Env.fire("TRADE_SKILL_LIST_UPDATE")
    Env.flushTimers()
    out("own-window")

elseif scenario == "recipes-no-timer" then
    -- A client without C_Timer: the capture runs at once.
    local g = full()
    g.trade.window = {
        base = { professionID = 197, professionName = "Tailoring" },
        filtered = { 1 },
        recipes = { [1] = { learned = true, reagents = { { 2589, 2 } } } },
    }
    Env.load()
    Env.fire("TRADE_SKILL_LIST_UPDATE")
    emit("chat", chat())
    out()

elseif scenario == "recipes-cap" then
    -- 650 recipes in one window: the line keeps 600 and says it cut.
    local g = full()
    Env.useTimers()
    Env.load()
    local ids, recipes = {}, {}
    for i = 1, 650 do ids[i] = i; recipes[i] = { learned = true, reagents = { { 2589, 1 } } } end
    g.trade.window = { base = { professionID = 197, professionName = "Tailoring" }, filtered = ids, recipes = recipes }
    Env.fire("TRADE_SKILL_LIST_UPDATE")
    Env.flushTimers()
    out()

elseif scenario == "reputation" then
    -- Collapsed headers are opened to read and collapsed again afterwards.
    local g = full()
    if variant == "no-collapse" then
        g.rep.noExpand = true
        C_Reputation.ExpandAllFactionHeaders = nil
        C_Reputation.CollapseFactionHeader = nil
    end
    Env.load()
    out()
    emit("log", g.rep.log)
    emit("collapsed-after", { g.rep.factions[1].collapsed })

elseif scenario == "quest-log" then
    local g = full()
    Env.load()
    out()

elseif scenario == "combat" then
    local g = full()
    Env.load()
    Env.combat = true
    SlashCmdList["WOWCHAR"]() -- no window: the editBox does not exist yet
    emit("chat-combat", chat())
    emit("window-made", { Env.editBox ~= nil })
    Env.combat = false
    Env.fire("PLAYER_REGEN_ENABLED")
    emit("after-combat", Env.editBox.text)
    -- nothing pending now
    Env.editBox.text = "x"
    Env.fire("PLAYER_REGEN_ENABLED")
    emit("not-opened-twice", { Env.editBox.text == "x" })

elseif scenario == "secret" then
    -- The game hides values (combat restrictions): the section is missing/in_combat.
    local g = full()
    local hidden = {}
    issecretvalue = function(v) return hidden[v] == true end
    hidden[123456789] = true -- the money
    hidden[3500] = true -- one reputation value
    Env.load()
    out()

elseif scenario == "taxi" then
    local g = full()
    if variant == "no-map-function" then GetTaxiMapID = nil end
    if variant == "unreachable-only" then g.taxi.maps[1414] = { all = { { 13, 2 } }, forMap = { { 15, true } } } end
    if variant == "none" then C_TaxiMap = nil end
    Env.load()
    out("before")
    Env.fire("TAXIMAP_OPENED")
    emit("chat", chat())
    out("opened")
    -- a node discovered while the map is open
    Env.chat = {}
    if g.taxi.maps[1414] then
        g.taxi.maps[1414].forMap[#g.taxi.maps[1414].forMap + 1] = { 99, false }
    end
    Env.fire("TAXI_NODE_STATUS_CHANGED")
    emit("chat-status", chat())
    Env.fire("TAXIMAP_CLOSED")
    Env.chat = {}
    Env.fire("TAXI_NODE_STATUS_CHANGED")
    emit("chat-closed", chat())
    out("closed")

elseif scenario == "legacy" then
    local g = full()
    if variant == "constants" then
        Constants = { LegacyConsts = { LEGACY_TREE_PROFESSIONS_ID = 1187, LEGACY_TREE_ADVENTURE_ID = 1188, LEGACY_TREE_PROGRESSION_ID = 1189 } }
    end
    if variant == "login" then
        -- no config for any tree yet
        for _, l in pairs(g.traits.legacy) do l.config = nil end
    end
    Env.load()
    out("first")
    if variant == "login" then return end
    -- the next time the trees are not ready: the cache answers
    for _, l in pairs(g.traits.legacy) do l.config = nil end
    out("not-ready")

elseif scenario == "legacy-cache" then
    local g = full()
    Env.load()
    out("session1")
    local saved = toawowcharDB
    Env.relog()
    Env.now = Env.now + 90
    toawowcharDB = saved
    local g2 = full()
    for _, l in pairs(g2.traits.legacy) do l.config = nil end
    Env.load()
    out("session2")

elseif scenario == "nothing-opened" then
    -- A full game, but no window was opened in this session and nothing is cached.
    local g = full()
    Env.load()
    out()

elseif scenario == "window" then
    local g = full()
    if variant == "no-templates" then
        Env.missingTemplates.BasicFrameTemplateWithInset = true
        Env.missingTemplates.InputScrollFrameTemplate = true
    elseif variant == "no-input-template" then
        Env.missingTemplates.InputScrollFrameTemplate = true
    elseif variant == "no-backdrop" then
        Env.missingTemplates.BasicFrameTemplateWithInset = true
        Env.missingTemplates.BackdropTemplate = true
    elseif variant == "no-special-frames" then
        UISpecialFrames = nil
    end
    Env.useTimers()
    Env.load()
    open_windows(g)
    local text = Env.run()
    local f = Env.frameNamed("toawowcharFrame")
    emit("export-length", { #text })
    emit("window", Env.windowText())
    emit("frame", {
        template = f.template or "none",
        width = f.width, height = f.height, strata = f.strata, movable = f.movable or false, clamped = f.clamped or false,
        shown = f.shown, special = UISpecialFrames and UISpecialFrames[1] or "none",
        drag = f.drag and f.drag[1] or "none",
        title = f.TitleText and f.TitleText.text or "none",
    })
    emit("box", {
        highlighted = Env.editBox.highlighted or false, focused = Env.editBox.focused or false,
        maxLetters = Env.editBox.maxLetters, maxBytes = Env.editBox.maxBytes, same = Env.editBox.text == text,
        kind = Env.editBox.kind,
    })
    -- typing in the box puts the export back
    Env.type(Env.editBox, "typed over it")
    emit("after-typing", { Env.editBox.text == text })
    -- Escape in the box closes the window and gives the keyboard back
    local hook = Env.editBox.hooks.OnEscapePressed and Env.editBox.hooks.OnEscapePressed[1] or Env.editBox.scripts.OnEscapePressed
    hook(Env.editBox)
    emit("after-escape", { f.shown, Env.editBox.focused })
    -- opening again shows it again
    Env.run()
    emit("reopened", { f.shown })
    f:Hide()
    emit("after-hide", { Env.editBox.focused })

elseif scenario == "window-buttons" then
    local g = full()
    Env.load()
    Env.run()
    local select, close
    for _, f in ipairs(Env.frames) do
        if f.kind == "Button" and f.text == "Select all" then select = f end
        if f.kind == "Button" and f.text == "Close" then close = f end
    end
    Env.editBox.highlighted, Env.editBox.focused = false, false
    select.scripts.OnClick(select)
    emit("select-all", { Env.editBox.highlighted, Env.editBox.focused })
    close.scripts.OnClick(close)
    emit("close", { Env.frameNamed("toawowcharFrame").shown, Env.editBox.focused })

elseif scenario == "bounds" then
    -- One value outside the server's bounds (ADDON_BOUNDS) in each section: its row is
    -- left out (or its optional field), and everything else is exported, so the server
    -- never refuses the paste. The values just inside the bound ("Edge") are kept.
    local BIG = 2000000000
    local OVER_ID = 2147483648
    local g = full()
    -- reputation: reaction 0..20, standing, floor and ceiling within +-1e9
    local f = g.rep.factions
    f[#f + 1] = { id = 500, name = "BadReaction", reaction = 21 }
    f[#f + 1] = { id = 501, name = "BadNegative", reaction = -1 }
    f[#f + 1] = { id = 502, name = "BadStanding", standing = BIG }
    f[#f + 1] = { id = 503, name = "BadFloor", floor = -BIG }
    f[#f + 1] = { id = 504, name = "BadCeiling", ceiling = BIG }
    f[#f + 1] = { id = 505, name = "Edge", reaction = 20, standing = 1000000000, floor = -1000000000, ceiling = 1000000000 }
    f[#f + 1] = { id = OVER_ID, name = "BadId" }
    -- quest log: objective counts 0..1e9, a quest id above the id bound
    local e = g.log.entries
    e[#e + 1] = { id = 7010, complete = false, objectives = { { "Edge", 1000000000, 1000000000, false }, { "Over", BIG, 1, false }, { "Under", -1, 1, false }, { "Need", 1, BIG, false } } }
    e[#e + 1] = { id = OVER_ID, complete = false, objectives = {} }
    -- player: money, xp and rested out of range are left out, the rest stays
    g.player.money, g.player.xp, g.player.rested = 100000000000000, -1, BIG
    -- completed quests, flight paths, spells: an id above the bound is left out
    g.quests.ids = { 5, 3, OVER_ID, 0, -4, 2147483647 }
    g.taxi.maps[1414].all[#g.taxi.maps[1414].all + 1] = { OVER_ID, 0 }
    g.taxi.maps[1414].all[#g.taxi.maps[1414].all + 1] = { 2147483647, 1 }
    local lines = g.spells.lines
    lines[#lines + 1] = { name = "Extra", items = { { OVER_ID, 1 }, { 2147483647, 1 } } }
    g.spells = World.spells({ lines = lines })
    -- talents: a node with a rank above 255 or an entry above the id bound is left out
    local nodes = g.traits.trees[1100].nodes
    nodes[#nodes + 1] = { 20, 256, 1 }
    nodes[#nodes + 1] = { 21, 1, OVER_ID }
    nodes[#nodes + 1] = { 22, 255, 2147483647 }
    nodes[#nodes + 1] = { OVER_ID, 1, 1 }
    -- Legacy: points beyond 1e9 are left out of `points`, a tree with such a count is left out
    g.traits.legacy[1187].quantity = BIG
    g.traits.legacy[1187].spentInTree = BIG
    -- honor: the season maximum above 1000 is left out
    g.honor.info = { renownLevel = 4, maxLevel = 1001 }
    -- professions: a name over 64 bytes leaves the profession out, a rank above 1e6 only the rank
    local p = g.trade.professions
    p[#p + 1] = { name = string.rep("x", 65), rank = 1, maxRank = 2, line = 3 }
    p[1].rank = 2000000
    -- identity
    GetRealmName = function() return string.rep("r", 101) end
    UnitClass = function() return "Warrior", "WARRIOR", 2000000 end
    C_SpecializationInfo = { GetSpecialization = function() return 1 end, GetSpecializationInfo = function() return 71, string.rep("s", 51) end }
    GetInventoryItemID = function(_, slot)
        if slot == 1 then return OVER_ID end
        if slot == 2 then return 100 end
        return nil
    end
    Env.useTimers()
    Env.load()
    -- recipes: a reagent count above 9999 leaves that reagent out, a recipe id above the id bound the recipe
    g.trade.window = {
        base = { professionID = 197, professionName = "Tailoring" },
        filtered = { 1, 2, OVER_ID },
        recipes = {
            [1] = { learned = true, reagents = { { 2589, 9999 }, { 2320, 10000 }, { OVER_ID, 1 } } },
            [2] = { learned = true, reagents = {} },
        },
    }
    Env.fire("TRADE_SKILL_LIST_UPDATE")
    Env.flushTimers()
    Env.fire("TAXIMAP_OPENED")
    out()

elseif scenario == "bounds-honor" then
    -- The season rank above 1000 makes the section missing (it has no row to leave out).
    local g = full()
    g.honor.info = { renownLevel = 1001, maxLevel = 14 }
    Env.load()
    out()

elseif scenario == "bounds-identity" then
    -- A level above 255 is left out of the identity and of the player section; a name longer
    -- than 64 bytes makes no export at all.
    local g = full()
    if variant == "name" then
        UnitName = function() return string.rep("n", 65) end
        Env.load()
        SlashCmdList["WOWCHAR"]()
        emit("window", Env.windowText())
        emit("text", { Env.editBox and Env.editBox.text or "" })
        return
    end
    UnitLevel = function() return 300 end
    GetCurrentRegion = function() return 2000000 end
    GetCVar = function() return string.rep("p", 33) end
    Env.load()
    out()

elseif scenario == "bounds-time" then
    -- A clock the server would refuse (before 2001): the export has no capturedAt, live
    -- sections have no time, and what needs a time (a recipe line, a cached section) is missing.
    local g = full()
    Env.now = 5
    Env.useTimers()
    Env.load()
    open_windows(g)
    out()

elseif scenario == "constants" then
    -- What the addon repeats from the server: the caps, the bounds, the reason codes and the length limit.
    Env.load()
    emit("caps", Env.ns.CAPS)
    emit("bounds", Env.ns.BOUNDS)
    emit("reasons", Env.ns.REASONS)
    emit("max", { Env.ns.MAX_EXPORT_LENGTH })
    emit("bodymax", { Env.ns.ADDON_BODY_MAX })

elseif scenario == "unknown-command" then
    -- Anything but "reset" opens the window.
    local g = full()
    Env.load()
    local text = Env.run("  show me ")
    emit("export", text)
    local reset = Env.run("RESET")
    emit("after-reset", { reset == text })

else
    error("unknown scenario " .. tostring(scenario))
end
