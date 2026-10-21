-- The game data behind the new sections of addon 0.4.0, as installers for the
-- WoW API stub (wow-env.lua). Each installer sets the globals one section reads and
-- returns the table it keeps its state in, so a scenario can change the game's
-- answer later (an empty list at login that fills in a moment later, a window that
-- closes). The API names and shapes are the ones the addon's comments cite
-- (Gethe/wow-ui-source, branch forever, 172a387).
local World = {}

-- Money, level, XP, XP max and rested XP. `state.rested = nil` is a character that is not rested.
function World.player(state)
    GetMoney = function() return state.money end
    UnitLevel = function() return state.level or 60 end
    UnitXP = function() return state.xp end
    UnitXPMax = function() return state.xpMax end
    GetXPExhaustion = function() return state.rested end
    return state
end

-- C_QuestLog.GetAllCompletedQuestIDs: `state.ids` is what the game answers (it may
-- be empty just after login); `state.missing = true` removes the function.
function World.completedQuests(state)
    C_QuestLog = C_QuestLog or {}
    C_QuestLog.GetAllCompletedQuestIDs = (not state.missing) and function() return state.ids end or nil
    return state
end

-- The quest log. `state.entries` is what the log shows (collapsed zones show only their header):
-- { id = n, header = true } or { id = questID, complete = bool, hidden = bool, task = bool,
-- objectives = { { text, have, need, done } } }. `state.total` is numQuests (the log's quests,
-- also those under collapsed headers); default: the quests listed.
function World.questLog(state)
    C_QuestLog = C_QuestLog or {}
    C_QuestLog.GetNumQuestLogEntries = function()
        local quests = 0
        for _, e in ipairs(state.entries) do if not e.header then quests = quests + 1 end end
        return #state.entries, state.total or quests
    end
    C_QuestLog.GetInfo = function(index)
        local e = state.entries[index]
        if not e then return nil end
        return { questID = e.id, isHeader = e.header or false, isHidden = e.hidden or false, isTask = e.task or false, title = "Quest " .. tostring(e.id) }
    end
    C_QuestLog.GetQuestObjectives = function(id)
        for _, e in ipairs(state.entries) do
            if e.id == id and not e.header then
                if e.noObjectives then return nil end
                local list = {}
                for _, o in ipairs(e.objectives or {}) do
                    list[#list + 1] = { text = o[1], type = "monster", finished = o[4] or false, numFulfilled = o[2], numRequired = o[3] }
                end
                return list
            end
        end
        return nil
    end
    C_QuestLog.IsComplete = function(id)
        for _, e in ipairs(state.entries) do
            if e.id == id then return e.complete or false end
        end
        return false
    end
    return state
end

-- Reputation. `state.factions` is the full tree in order: { id, name, reaction, standing, floor, ceiling,
-- header = bool, withRep = bool, collapsed = bool, parent = headerId }. A row under a collapsed header is
-- not listed by index, like the game. `state.log` records the Expand/Collapse calls.
function World.reputation(state)
    state.log = state.log or {}
    local function visible()
        local rows = {}
        local hidden = {}
        for _, f in ipairs(state.factions) do
            if not (f.parent and hidden[f.parent]) then
                rows[#rows + 1] = f
                if f.header and f.collapsed then hidden[f.id] = true end
            elseif f.header then
                hidden[f.id] = true
            end
        end
        return rows
    end
    C_Reputation = {
        GetNumFactions = function() return #visible() end,
        GetFactionDataByIndex = function(i)
            local f = visible()[i]
            if not f then return nil end
            return {
                factionID = f.id, name = f.name, reaction = f.reaction or 4, currentStanding = f.standing or 0,
                currentReactionThreshold = f.floor or 0, nextReactionThreshold = f.ceiling or 3000,
                isHeader = f.header or false, isHeaderWithRep = f.withRep or false, isCollapsed = f.collapsed or false,
            }
        end,
    }
    if not state.noExpand then
        C_Reputation.ExpandAllFactionHeaders = function()
            state.log[#state.log + 1] = "expand-all"
            for _, f in ipairs(state.factions) do f.collapsed = false end
        end
        C_Reputation.CollapseFactionHeader = function(i)
            local f = visible()[i]
            state.log[#state.log + 1] = "collapse:" .. tostring(f and f.id)
            if f then f.collapsed = true end
        end
    end
    return state
end

-- Professions and the profession window (C_TradeSkillUI). `state.professions` is what GetProfessions lists:
-- { name, rank, maxRank, line }. `state.window` describes the open window:
--   { base = { professionID, parentProfessionID, professionName }, all = ids or nil, filtered = ids,
--     recipes = { [id] = { learned = bool, reagents = { { itemID, count } or { currencyID = n, count = n } } } },
--     linked, guild, guildMember, npc }
-- Set `state.window = nil` for a closed window (the functions then answer nothing).
function World.tradeskill(state)
    GetProfessions = function()
        local out = {}
        for i = 1, 6 do out[i] = state.professions[i] and i or nil end
        return unpack(out, 1, 6)
    end
    GetProfessionInfo = function(i)
        local p = state.professions[i]
        return p.name, nil, p.rank, p.maxRank, nil, nil, p.line
    end
    Enum = Enum or {}
    Enum.CraftingReagentType = { Modifying = 0, Basic = 1, Finishing = 2 }
    local function w() return state.window or {} end
    IsTradeSkillLinked = function() return w().linked or false, nil end
    IsTradeSkillGuild = function() return w().guild or false end
    IsTradeSkillGuildMember = function() return w().guildMember or false end
    C_TradeSkillUI = {
        IsNPCCrafting = function() return w().npc or false end,
        GetBaseProfessionInfo = function() return w().base end,
        GetFilteredRecipeIDs = function() return w().filtered or {} end,
        GetRecipeInfo = function(id)
            local r = w().recipes and w().recipes[id]
            if not r then return nil end
            return { recipeID = id, learned = r.learned, name = "Recipe " .. id }
        end,
        GetRecipeSchematic = function(id, isRecraft)
            assert(isRecraft == false, "GetRecipeSchematic needs isRecraft = false")
            local r = w().recipes and w().recipes[id]
            local slots = {}
            for i, reagent in ipairs(r and r.reagents or {}) do
                local entry = reagent.currencyID and { currencyID = reagent.currencyID } or { itemID = reagent[1] }
                slots[#slots + 1] = {
                    reagentType = reagent.type, required = reagent.required, slotIndex = i,
                    quantityRequired = reagent.currencyID and reagent.count or reagent[2],
                    reagents = { entry, { itemID = (entry.itemID or 0) + 1 } }, -- a second tier that must not be read
                }
            end
            return { recipeID = id, reagentSlotSchematics = slots }
        end,
    }
    if state.withAllIds then
        C_TradeSkillUI.GetAllRecipeIDs = function() return w().all or {} end
    end
    return state
end

-- Trait trees: talents (C_ClassTalents + C_Traits) and the Legacy trees. `state.talents` =
-- { config = id or nil, treeIDs = {...} }; `state.trees[treeID]` = { nodes = { {id, rank, entry} ... },
-- extra = nodes with rank 0 } (all nodes are listed by GetTreeNodes, only those with rank > 0 count);
-- `state.legacy[treeID]` = { config = id or nil, quantity, maxQuantity, spent, spentInTree }.
function World.traits(state)
    C_ClassTalents = { GetActiveConfigID = function() return state.talents and state.talents.config end }
    C_Traits = {
        GetConfigInfo = function(id)
            if state.talents and id == state.talents.config then return { ID = id, treeIDs = state.talents.treeIDs } end
            return nil
        end,
        GetTreeNodes = function(tree)
            local t = state.trees[tree]
            if not t then return nil end
            local ids = {}
            for _, n in ipairs(t.nodes) do ids[#ids + 1] = n[1] end
            for _, id in ipairs(t.extra or {}) do ids[#ids + 1] = id end
            return ids
        end,
        GetNodeInfo = function(config, nodeId)
            for _, t in pairs(state.trees) do
                for _, n in ipairs(t.nodes) do
                    if n[1] == nodeId then
                        return { ID = nodeId, activeRank = n[2], activeEntry = n[3] and { entryID = n[3], rank = n[2] } or nil }
                    end
                end
                for _, id in ipairs(t.extra or {}) do
                    if id == nodeId then return { ID = nodeId, activeRank = 0 } end
                end
            end
            return nil
        end,
        GetConfigIDByTreeID = function(tree)
            local l = state.legacy and state.legacy[tree]
            return l and l.config or nil
        end,
        GetTreeCurrencyInfo = function(config, tree, excludeStaged)
            assert(excludeStaged == false, "GetTreeCurrencyInfo needs excludeStagedChanges = false")
            local l = state.legacy and state.legacy[tree]
            if not l or l.config ~= config then return nil end
            return { { traitCurrencyID = 4225, quantity = l.quantity, maxQuantity = l.maxQuantity, spent = l.spent, spentInTree = l.spentInTree } }
        end,
    }
    return state
end

-- Flight paths. `state.maps[uiMapID]` = { all = { {nodeID, state} }, forMap = { {nodeID, undiscovered} } };
-- `state.taxiMap` is what GetTaxiMapID answers (nil: the function does not exist), `state.best` the player's map,
-- `state.parents[map]` its parent.
function World.taxi(state)
    C_TaxiMap = {
        GetAllTaxiNodes = function(map)
            local m = state.maps[map]
            local out = {}
            for _, n in ipairs(m and m.all or {}) do out[#out + 1] = { nodeID = n[1], state = n[2], name = "Node " .. n[1] } end
            return out
        end,
        GetTaxiNodesForMap = function(map)
            local m = state.maps[map]
            local out = {}
            for _, n in ipairs(m and m.forMap or {}) do out[#out + 1] = { nodeID = n[1], isUndiscovered = n[2] } end
            return out
        end,
    }
    Enum = Enum or {}
    Enum.FlightPathState = { Current = 0, Reachable = 1, Unreachable = 2 }
    GetTaxiMapID = state.taxiMap and function() return state.taxiMap end or nil
    C_Map = {
        GetBestMapForUnit = function() return state.best end,
        GetMapInfo = function(map) return { mapID = map, parentMapID = state.parents and state.parents[map] or 0 } end,
    }
    return state
end

-- The spell book. `state.lines` = { { name, items = { { spellID, actionID, itemType, isOffSpec } ... }, isGuild, shouldHide } }.
function World.spells(state)
    Enum = Enum or {}
    Enum.SpellBookSpellBank = { Player = 0 }
    Enum.SpellBookItemType = { None = 0, Spell = 1, FutureSpell = 2, PetAction = 3, Flyout = 4 }
    local offsets, total = {}, 0
    for i, line in ipairs(state.lines) do
        offsets[i] = total
        total = total + #line.items
    end
    C_SpellBook = {
        GetNumSpellBookSkillLines = function() return #state.lines end,
        GetSpellBookSkillLineInfo = function(i)
            local line = state.lines[i]
            return { name = line.name, itemIndexOffset = offsets[i], numSpellBookItems = #line.items, isGuild = line.isGuild or false, shouldHide = line.shouldHide or false }
        end,
        GetSpellBookItemInfo = function(slot, bank)
            assert(bank == 0, "the player's spell book bank")
            for i, line in ipairs(state.lines) do
                local item = line.items[slot - offsets[i]]
                if slot > offsets[i] and item then
                    return { spellID = item[1], actionID = item[2], itemType = item[3] or 1, isOffSpec = item[4] or false }
                end
            end
            return nil
        end,
    }
    return state
end

-- The honor system's rank (major faction 2800).
function World.honor(state)
    C_MajorFactions = {
        GetMajorFactionProgressionInfo = function(id)
            assert(id == 2800, "the PvP rank is major faction 2800")
            return state.info
        end,
    }
    return state
end

-- A game where every section can be read, with small data: each installer's state in `g`.
function World.full()
    local g = {}
    g.player = World.player({ money = 123456789, level = 60, xp = 1000, xpMax = 5000, rested = nil })
    g.quests = World.completedQuests({ ids = { 5, 3, 9, 3 } })
    g.log = World.questLog({ entries = {
        { id = 7000, header = true },
        { id = 7001, complete = false, objectives = { { "Kobold Miner slain", 3, 10, false }, { "Candle\9of\1 Light", 1, 1, true } } },
        { id = 7002, complete = true, objectives = {} },
        { id = 7003, hidden = true, objectives = {} },
        { id = 7004, task = true, objectives = {} },
        { id = 7005, header = true },
    }, total = 6 })
    g.rep = World.reputation({ factions = {
        { id = 1, name = "Classic", header = true, collapsed = true },
        { id = 72, name = "Stormwind", reaction = 5, standing = 3500, floor = 3000, ceiling = 9000, parent = 1 },
        { id = 69, name = "Darnassus", reaction = 8, standing = 42000, floor = 21000, ceiling = 42000, parent = 1 },
        { id = 169, name = "Steamwheedle Cartel", header = true, withRep = true, reaction = 4, standing = 0, floor = 0, ceiling = 3000 },
    } })
    g.trade = World.tradeskill({ professions = { { name = "Tailoring", rank = 225, maxRank = 300, line = 197 }, { name = "First Aid", rank = 100, maxRank = 150, line = 129 } } })
    g.traits = World.traits({
        talents = { config = 5000, treeIDs = { 1100 } },
        trees = {
            [1100] = { nodes = { { 10, 2, 100 }, { 11, 1 }, { 12, 0 } }, extra = { 13 } },
            [1187] = { nodes = { { 201, 1, 5 } } },
            [1188] = { nodes = {} },
            [1189] = { nodes = { { 401, 3 } } },
        },
        legacy = {
            [1187] = { config = 6001, quantity = 5, maxQuantity = 50, spent = 20, spentInTree = 8 },
            [1188] = { config = 6002, quantity = 5, maxQuantity = 50, spent = 20, spentInTree = 7 },
            [1189] = { config = 6003, quantity = 5, maxQuantity = 50, spent = 20, spentInTree = 5 },
        },
    })
    g.taxi = World.taxi({ maps = { [1414] = { all = { { 11, 0 }, { 12, 1 }, { 13, 2 } }, forMap = { { 12, false }, { 14, false }, { 15, true } } } }, taxiMap = 1414, best = 1415, parents = { [1415] = 1414 } })
    g.spells = World.spells({ lines = {
        { name = "General", items = { { 6603, 6603 }, { 3365, 3365, 4 } } },
        { name = "Warrior", items = { { 78, 78 }, { 100, 100, 1, true }, { 2, 2, 2 }, { nil, 2457 }, { 772, 772 } } },
        { name = "Tailoring", items = { { 3908, 3908 } } },
        { name = "Guild", isGuild = true, items = { { 83968, 83968 } } },
    } })
    g.honor = World.honor({ info = { renownLevel = 4, maxLevel = 14 } })
    return g
end

return World
