-- WowcharExport 0.4.0
--
-- Type /wowchar to open a window with a text string (who the character is,
-- equipped items, bags, the bank and the warband bank, professions with their
-- recipes, completed quests and the quest log, reputation, money and XP,
-- talents, Legacy, flight paths, the season's PvP rank and the class spells
-- the character knows). Copy it (Ctrl+C) and paste it at wowchar: on «My
-- characters» to add the character, or on the character's BiS page to mark the
-- BiS items you already have as obtained. The addon sends nothing anywhere.
--
-- What it saves (SavedVariables: WowcharExportDB, a CACHE only): what the game
-- only lets it read while a window is open (the bank and the warband bank, the
-- recipes of each profession, the flight paths), the Legacy tree and the
-- completed quests. Each cached part has the time it was read. The addon works
-- exactly the same when nothing was saved or the client does not keep the file:
-- the text is then made from what the game answers now, and the parts it could
-- not read say why. "/wowchar reset" clears this character's cache.
--
-- Chat: the addon says one short line when it has cached something new (the
-- bank, a profession's recipes, flight paths), one when /wowchar is typed in
-- combat (the window then opens when combat ends) and one for "/wowchar reset".
-- It says nothing else.
--
-- The text is "WOWCHAR:3:" followed by plain JSON, written by the small
-- serializer below (format 3 = format 2's content plus "sections"). No
-- C_EncodingUtil, no compression, no base64. It is decoded by wowchar's
-- server/utils/addon-export.ts, and the shape is described in
-- docs/addon-export-format-3.md. That file and the table built in BuildPayload()
-- below belong together: change one, change the other.
--
-- Every section says where it came from (SOURCES below): "live" (read now, or
-- captured while its window was open earlier in this play session), "cache" (an
-- earlier session, with the time it was read) or "missing" with one of the
-- REASONS codes (not text: the server checks them and the page words them).
--
-- Region: identity.region is "US", "KR", "EU", "TW" or "CN", from
-- GetCurrentRegion() (1 to 5). Any other value (the Forever test client reports
-- 110) leaves region out and sends identity.regionId (the number) and
-- identity.portal (the "portal" setting) instead; wowchar then does not compare
-- regions. GetCurrentRegionName() is not used: it errors on the Forever test
-- client. Every call below is guarded, so a missing function is never an error.
--
-- Race and faction (0.3.1): identity.race is the race file token (the second
-- return of UnitRace("player"), for example "NightElf" or "Scourge") and
-- identity.faction is the first return of UnitFactionGroup("player") ("Alliance",
-- "Horde" or "Neutral"). A value that is not a string leaves its key out. The
-- server decides what it accepts (addon-export.ts), so the addon does not list
-- the races: the Forever tokens for the two new races are not confirmed.
--
-- API facts this file relies on (Gethe/wow-ui-source, branch forever, 172a387,
-- build 1.60.1.70450; nothing was run in a live client; the Blizzard_APIDocumentationGenerated
-- paths are meant): QuestLogDocumentation.lua, ReputationInfoDocumentation.lua,
-- SharedTraitsDocumentation.lua, ClassTalentsDocumentation.lua, TaxiMapDocumentation.lua,
-- TradeSkillUIDocumentation.lua, SpellBookDocumentation.lua, MajorFactionsDocumentation.lua,
-- LegacyConstantsDocumentation.lua. File and line references are with each reader.

-- Tests load this file with a private table as the second argument (the client
-- passes one too: the addon's own namespace) and read the helpers from it.
local addonName, ns = ...

local ADDON_VERSION = "0.4.0"
local FORMAT_VERSION = 3
local PREFIX = "WOWCHAR:" .. FORMAT_VERSION .. ":"
-- The longest text the server takes (MAX_ENCODED_LENGTH in
-- app/shared/addon-export-format.ts; a test compares the two). The window shows
-- the size; a longer text drops the lowest-priority sections (see Run).
local MAX_EXPORT_LENGTH = 131072
local CACHE_VERSION = 1

-- The caps on every list. The server refuses a list over its cap (ADDON_LIST_CAPS
-- in server/utils/addon-export.ts, sized from the maxed-character export of
-- test/lua/maxed-stub.lua; a test compares the two tables name by name), so the
-- lists here are cut at the same numbers. "ids" is MAX_IDS_PER_ARRAY there.
local CAPS = {
    ids = 500,
    professions = 32,
    questsDone = 5000,
    questLog = 50,
    objectivesPerQuest = 12,
    objectiveText = 255,
    factions = 200,
    nameText = 100,
    recipeLines = 12,
    recipesPerLine = 600,
    reagentsPerRecipe = 12,
    talentTrees = 4,
    nodesPerTree = 150,
    legacyTrees = 4,
    challenges = 500,
    flightPaths = 200,
    classSpells = 400,
}

-- Why a section is missing. Codes, not text. The server accepts exactly these
-- (MISSING_REASONS in app/shared/addon-sections.ts; a test compares the lists).
local REASONS = {
    "open_bank",
    "open_profession_window",
    "open_flight_map",
    "not_loaded",
    "in_combat",
    "not_available",
    "too_large",
}

-- The server refuses an array longer than 500 (MAX_IDS_PER_ARRAY in
-- addon-export.ts); the lists here are cut at the same number.
local MAX_IDS = CAPS.ids
local MAX_PROFESSIONS = CAPS.professions
local LAST_EQUIPMENT_SLOT = 19
-- The server refuses more than 32 bonus ids on one item (MAX_BONUS_IDS_PER_ITEM)
-- and more than 4 gems; the lists here are cut at the same numbers.
local MAX_BONUS_IDS = 32
local MAX_GEMS = 4
-- Item ids, enchant ids and so on are whole numbers that fit a 32-bit signed
-- integer (the server's MAX_ITEM_ID); anything else in an item string is ignored.
local MAX_ID = 2147483647
local MAX_REAGENT_COUNT = 9999
local MAX_TRAIT_RANK = 255
-- The honor system's rank is the renown level of this major faction (Forever,
-- Blizzard_UIPanels_Game/Camelot/PVPRankFrame.lua:1 and :91).
local PVP_RANK_FACTION_ID = 2800
-- The Legacy trees (LegacyConstantsDocumentation.lua, Constants.LegacyConsts; the
-- constants are used when the game has them, these numbers when it does not).
-- NOTE the third tree is "Progression" in Blizzard's code: key on the ids, never
-- on the names.
local LEGACY_TREES = { 1187, 1188, 1189 }

-- State of this play session. Nothing here is saved.
local session = {
    live = {},           -- section -> unix time it was read live in this play session
    bankOpen = false,
    bankDirty = false,   -- the bank cache changed while the bank was open: say so when it closes
    warbankDirty = false,
    pendingOpen = false, -- /wowchar was typed in combat: open the window when it ends
    taxiOpen = false,
    recipesPending = false,
}

-- Set when a read met a value the game hid (a "secret" value), so the section
-- becomes missing/in_combat instead of a half-read one.
local secretSeen = false
-- Set when a list had to be cut at its cap, so the window and the export can say
-- so. AddId sets `truncated` while a list is being collected. Run() resets it
-- before the bags are read; the bank is scanned earlier (when it opens), so its
-- result is kept apart (the cache's `cut` flag) and combined in BuildPayload.
local truncated = false
-- The same for the new sections, reset by BuildPayload.
local cutSections = false

local Cache = {}   -- SavedVariables cache
local Read = {}    -- one reader per section
local Capture = {} -- event captures (a window is open)
local UI = {}      -- the window

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function IsSecret(value)
    if issecretvalue then
        local ok, secret = pcall(issecretvalue, value)
        return ok and secret and true or false
    end
    return false
end

-- A finite number from a game function, or nil. A hidden (secret) value sets
-- secretSeen and gives nil.
local function Num(value)
    if IsSecret(value) then
        secretSeen = true
        return nil
    end
    if type(value) == "number" and value == value and value > -1e15 and value < 1e15 then
        return value
    end
    return nil
end

local function Int(value)
    local n = Num(value)
    if n and n == math.floor(n) then
        return n
    end
    return nil
end

-- A string for the export: control characters become spaces, the ends are
-- trimmed and the text is cut at `max` bytes on a character boundary. nil when
-- the value is not a string (or is hidden).
local function CleanText(value, max)
    if IsSecret(value) then
        secretSeen = true
        return nil
    end
    if type(value) ~= "string" then
        return nil
    end
    local text = (value:gsub("[%z\1-\31\127]", " "))
    text = text:match("^%s*(.-)%s*$")
    if #text > max then
        local n = max
        while n > 0 do
            local b = text:byte(n + 1)
            if b and b >= 0x80 and b < 0xC0 then
                n = n - 1
            else
                break
            end
        end
        text = text:sub(1, n)
    end
    return text
end

local function Now()
    return time and time() or 0
end

local function InCombat()
    return InCombatLockdown and InCombatLockdown() and true or false
end

-- One short line in the chat window.
local function Say(message)
    local line = "|cff8B7CFFwowchar:|r " .. message
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(line)
    elseif print then
        print(line)
    end
end

-- The keys of a set as a sorted list, cut at `cap`. Second result: true when cut.
local function SortedKeys(set, cap)
    local list = {}
    for id in pairs(set) do
        list[#list + 1] = id
    end
    table.sort(list)
    if #list > cap then
        for i = #list, cap + 1, -1 do
            list[i] = nil
        end
        return list, true
    end
    return list, false
end

local function SameSet(a, b)
    if #a ~= #b then
        return false
    end
    local set = {}
    for i = 1, #a do
        set[a[i]] = true
    end
    for i = 1, #b do
        if not set[b[i]] then
            return false
        end
    end
    return true
end

-- The sources. A marker is the start of a section table; the readers add the
-- data keys. `at` is unix seconds; nil leaves the key out.
local function Live(at)
    return { source = "live", at = at }
end

local function Cached(at)
    return { source = "cache", at = at }
end

local function Missing(why)
    return { source = "missing", why = why }
end

local function With(marker, data)
    for key, value in pairs(data) do
        marker[key] = value
    end
    return marker
end

---------------------------------------------------------------------------
-- Cache (SavedVariables: WowcharExportDB[realm][name])
---------------------------------------------------------------------------
-- The table is only a cache. The addon never needs it: when WowcharExportDB is
-- nil or not a table, or when the client does not save it, everything below works
-- on a table that lives for this play session. A record read from the saved file
-- is rebuilt field by field the first time it is used (Cache.Clean): only whole
-- numbers in range, strings cut at their caps, lists cut at the caps of the
-- export. So a file that was edited or damaged cannot make a bigger export than
-- the live game could.
--
-- A record (version 1):
--   bank      { at, source = "tabs"|"classic", items = {ids, sorted}, cut }
--   warbank   { at, items = {ids, sorted}, cut }
--   recipes   { [skillLine] = { at, name, cut, recipes = { [recipeId] = { {itemId, count}, ... } } } }
--   flights   { at, ids = {taxi node ids, sorted} }
--   quests    { at, ids = {completed quest ids, sorted}, cut }
--   legacy    { at, points = { available, cap, spent }, trees = { { tree, spent, nodes = { {node, rank, entry} } } } }
-- Caches are only ever MERGED into (recipes, flight paths and completed quests
-- keep everything seen before); the bank, the warband bank and Legacy are
-- replaced by a complete new read.

local checked = setmetatable({}, { __mode = "k" })
local fallbackRecord

local function CleanTime(value)
    local n = Int(value)
    if n and n >= 1000000000 and n <= 4102444800 then
        return n
    end
    return nil
end

-- A sorted list of the distinct whole numbers 1..MAX_ID found in a list or set.
-- Second result: true when cut at `cap`.
local function CleanIds(raw, cap)
    local set = {}
    if type(raw) == "table" then
        local looked = 0
        for _, value in pairs(raw) do
            looked = looked + 1
            if looked > cap * 4 + 16 then
                break
            end
            local id = Int(value)
            if id and id >= 1 and id <= MAX_ID then
                set[id] = true
            end
        end
    end
    return SortedKeys(set, cap)
end

local function CleanReagents(raw)
    local out = {}
    if type(raw) == "table" then
        for _, pair in ipairs(raw) do
            if #out >= CAPS.reagentsPerRecipe then
                break
            end
            if type(pair) == "table" then
                local item, count = Int(pair[1]), Int(pair[2])
                if item and item >= 1 and item <= MAX_ID and count and count >= 1 and count <= MAX_REAGENT_COUNT then
                    out[#out + 1] = { item, count }
                end
            end
        end
    end
    return out
end

-- Trait nodes { {node, rank, entry}, ... }, at most CAPS.nodesPerTree.
local function CleanNodes(raw)
    local out = {}
    if type(raw) == "table" then
        for _, triple in ipairs(raw) do
            if #out >= CAPS.nodesPerTree then
                break
            end
            if type(triple) == "table" then
                local node, rank, entry = Int(triple[1]), Int(triple[2]), Int(triple[3]) or 0
                if node and node >= 1 and node <= MAX_ID and rank and rank >= 1 and rank <= MAX_TRAIT_RANK and entry >= 0 and entry <= MAX_ID then
                    out[#out + 1] = { node, rank, entry }
                end
            end
        end
    end
    return out
end

local function CleanCount(value)
    local n = Int(value)
    if n and n >= 0 and n <= 1000000000 then
        return n
    end
    return nil
end

-- The Legacy points object, or nil when it would have no key (an empty table is
-- written as a list, and the server wants an object).
local function Points(available, cap, spent)
    if available == nil and cap == nil and spent == nil then
        return nil
    end
    return { available = available, cap = cap, spent = spent }
end

local function CleanLegacy(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local at = CleanTime(raw.at)
    if not at or type(raw.trees) ~= "table" then
        return nil
    end
    local clean = { at = at, trees = {} }
    if type(raw.points) == "table" then
        clean.points = Points(CleanCount(raw.points.available), CleanCount(raw.points.cap), CleanCount(raw.points.spent))
    end
    for _, tree in ipairs(raw.trees) do
        if #clean.trees >= CAPS.legacyTrees then
            break
        end
        if type(tree) == "table" then
            local id = Int(tree.tree)
            if id and id >= 1 and id <= MAX_ID then
                clean.trees[#clean.trees + 1] = { tree = id, spent = CleanCount(tree.spent) or 0, nodes = CleanNodes(tree.nodes) }
            end
        end
    end
    return clean
end

-- Rebuilds a record from whatever the saved file held.
function Cache.Clean(raw)
    local rec = { v = CACHE_VERSION, recipes = {} }
    if type(raw) ~= "table" then
        return rec
    end

    if type(raw.bank) == "table" then
        local at = CleanTime(raw.bank.at)
        local items, cut = CleanIds(raw.bank.items, MAX_IDS)
        if at and #items > 0 then
            rec.bank = { at = at, source = raw.bank.source == "classic" and "classic" or "tabs", items = items, cut = cut or raw.bank.cut == true }
        end
    end
    if type(raw.warbank) == "table" then
        local at = CleanTime(raw.warbank.at)
        local items, cut = CleanIds(raw.warbank.items, MAX_IDS)
        if at and #items > 0 then
            rec.warbank = { at = at, items = items, cut = cut or raw.warbank.cut == true }
        end
    end

    if type(raw.recipes) == "table" then
        local lines = 0
        for rawLine, entry in pairs(raw.recipes) do
            local line = Int(rawLine)
            if line and line >= 1 and line <= MAX_ID and type(entry) == "table" and lines < CAPS.recipeLines then
                local at = CleanTime(entry.at)
                if at and type(entry.recipes) == "table" then
                    local clean = { at = at, name = CleanText(entry.name, CAPS.nameText), recipes = {}, cut = entry.cut == true }
                    local count = 0
                    for rawId, reagents in pairs(entry.recipes) do
                        local id = Int(rawId)
                        if id and id >= 1 and id <= MAX_ID then
                            if count < CAPS.recipesPerLine then
                                clean.recipes[id] = CleanReagents(reagents)
                                count = count + 1
                            else
                                clean.cut = true
                            end
                        end
                    end
                    rec.recipes[line] = clean
                    lines = lines + 1
                end
            end
        end
    end

    if type(raw.flights) == "table" then
        local at = CleanTime(raw.flights.at)
        local ids = CleanIds(raw.flights.ids, CAPS.flightPaths)
        if at and #ids > 0 then
            rec.flights = { at = at, ids = ids }
        end
    end
    if type(raw.quests) == "table" then
        local at = CleanTime(raw.quests.at)
        local ids, cut = CleanIds(raw.quests.ids, CAPS.questsDone)
        if at and #ids > 0 then
            rec.quests = { at = at, ids = ids, cut = cut or raw.quests.cut == true }
        end
    end
    rec.legacy = CleanLegacy(raw.legacy)
    return rec
end

local function RealmName()
    if GetRealmName then
        local ok, value = pcall(GetRealmName)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    return nil
end

-- This character's record. Always a table: a play-session table when the saved
-- one cannot be used. The saved variable is looked up on every call (never kept),
-- because the client assigns the saved file's table after this file ran.
function Cache.Get()
    local name = UnitName and UnitName("player")
    if type(name) ~= "string" or name == "" then
        fallbackRecord = fallbackRecord or Cache.Clean(nil)
        return fallbackRecord
    end
    if type(WowcharExportDB) ~= "table" then
        WowcharExportDB = {}
    end
    local realm = RealmName() or "?"
    local realms = WowcharExportDB[realm]
    if type(realms) ~= "table" then
        realms = {}
        WowcharExportDB[realm] = realms
    end
    local rec = realms[name]
    if type(rec) ~= "table" or not checked[rec] then
        rec = Cache.Clean(rec)
        checked[rec] = true
        realms[name] = rec
    end
    return rec
end

-- /wowchar reset: forgets this character's cache and what was captured in this
-- play session.
function Cache.Reset()
    local name = UnitName and UnitName("player")
    if type(name) == "string" and name ~= "" and type(WowcharExportDB) == "table" then
        local realms = WowcharExportDB[RealmName() or "?"]
        if type(realms) == "table" then
            realms[name] = nil
        end
    end
    fallbackRecord = nil
    session.live = {}
    session.bankDirty, session.warbankDirty = false, false
    session.recipesPending = false
end

---------------------------------------------------------------------------
-- Collecting
---------------------------------------------------------------------------

-- Adds an item id to a list once; stops at MAX_IDS.
local function AddId(list, seen, id)
    if type(id) ~= "number" or id <= 0 or seen[id] then
        return
    end
    if #list >= MAX_IDS then
        truncated = true
        return
    end
    seen[id] = true
    list[#list + 1] = id
end

-- Adds the item ids of one container to a list. `last`, when given, is set to
-- the bag and slot of the last slot that held an item (the bank guard below
-- looks at it again). Returns false when the container cannot be read or has
-- no slots (a bank tab that was not bought has none).
local function ScanContainer(bag, list, seen, last)
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo) then
        return false
    end
    local numSlots = C_Container.GetContainerNumSlots(bag)
    if not numSlots or numSlots <= 0 then
        return false
    end
    for slot = 1, numSlots do
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then
            AddId(list, seen, info.itemID)
            if last then
                last.bag, last.slot = bag, slot
            end
        end
    end
    return true
end

---------------------------------------------------------------------------
-- Item strings
---------------------------------------------------------------------------

-- A whole number from 0 to MAX_ID, or nil. Item strings are text between colons;
-- an empty or odd field is "no value".
local function ToId(text)
    local n = tonumber(text)
    if n and n == math.floor(n) and n >= 0 and n <= MAX_ID then
        return n
    end
    return nil
end

-- Reads the numbers out of an item link by fixed position, like the item link
-- layout on warcraft.wiki.gg/wiki/ItemLink: after "item:" come
--   1 item id, 2 enchant id, 3-6 gem ids, 7 suffix id (negative for a random
--   suffix, written here as its absolute value), 8 unique id, 9 level,
--   10 spec, 11 flags, 12 context, 13 number of bonus ids, then that many ids.
-- Only digits, "-" and ":" are taken from the link (the pattern below), so
-- nothing else in the text, such as the item name, is ever read.
-- Returns a table { itemId, enchantId, suffixId, gemIds, bonusIds }, or nil when
-- there is no valid item id. Missing or odd fields count as 0 or are left out;
-- a short item string gives short results. Never raises.
local function ParseItemString(link)
    if type(link) ~= "string" then
        return nil
    end
    local str = link:match("|Hitem:([%-%d:]+)")
    if not str then
        return nil
    end
    -- Split on ":" keeping empty fields, so the positions stay right.
    local parts = {}
    local pos = 1
    while true do
        local colon = str:find(":", pos, true)
        if not colon then
            parts[#parts + 1] = str:sub(pos)
            break
        end
        parts[#parts + 1] = str:sub(pos, colon - 1)
        pos = colon + 1
    end

    local itemId = ToId(parts[1])
    if not itemId or itemId <= 0 then
        return nil
    end

    local gemIds = {}
    for i = 3, 6 do
        local gem = ToId(parts[i])
        if gem and gem > 0 and #gemIds < MAX_GEMS then
            gemIds[#gemIds + 1] = gem
        end
    end

    local suffix = tonumber(parts[7])
    suffix = suffix and ToId(math.abs(suffix)) or 0

    local bonusIds = {}
    local count = tonumber(parts[13])
    if count and count == math.floor(count) and count > 0 then
        local last = math.min(13 + count, #parts)
        for i = 14, last do
            local bonus = ToId(parts[i])
            if bonus and bonus > 0 and #bonusIds < MAX_BONUS_IDS then
                bonusIds[#bonusIds + 1] = bonus
            end
        end
    end

    return {
        itemId = itemId,
        enchantId = ToId(parts[2]) or 0,
        suffixId = suffix,
        gemIds = gemIds,
        bonusIds = bonusIds,
    }
end

local function CollectEquipped()
    local equipped = {}
    for slot = 1, LAST_EQUIPMENT_SLOT do
        local apiId = GetInventoryItemID("player", slot)
        if apiId and #equipped < MAX_IDS then
            -- The numbers come from the item string; the API id stands in when the
            -- client has no link yet (the item is not cached).
            local parsed = ParseItemString(GetInventoryItemLink("player", slot))
            if parsed then
                equipped[#equipped + 1] = {
                    slot = slot,
                    itemId = parsed.itemId,
                    enchantId = parsed.enchantId,
                    gemIds = parsed.gemIds,
                    suffixId = parsed.suffixId,
                    bonusIds = parsed.bonusIds,
                }
            else
                equipped[#equipped + 1] = {
                    slot = slot,
                    itemId = apiId,
                    enchantId = 0,
                    gemIds = {},
                    suffixId = 0,
                    bonusIds = {},
                }
            end
        end
    end
    return equipped
end

local function CollectBags()
    local list, seen = {}, {}
    -- Backpack (0), the four bag slots (1-4), and the reagent bag (5) if it has slots.
    for bag = 0, 5 do
        ScanContainer(bag, list, seen)
    end
    return list
end

---------------------------------------------------------------------------
-- The bank
---------------------------------------------------------------------------

-- The bank guard. A bank scan only counts if the bank was still open when it
-- ended: the last slot that had an item must still show an item, and the bank
-- must not have been closed (BANKFRAME_CLOSED). When the bank closes during a
-- scan, the game returns nothing for its slots, so the scan would be partial
-- and must not replace the list from the last full scan.
local function BankStillOpen(last)
    if not session.bankOpen or not last.bag then
        return false
    end
    if C_Container.GetContainerItemLink then
        local ok, link = pcall(C_Container.GetContainerItemLink, last.bag, last.slot)
        return ok and link ~= nil
    end
    local ok, info = pcall(C_Container.GetContainerItemInfo, last.bag, last.slot)
    return ok and info ~= nil
end

-- Reads the bank and the warband bank. Only works while the bank is open, so it
-- runs on BANKFRAME_OPENED (and when bags change while it is open) and the
-- result is kept in the cache record (and so in SavedVariables).
--
-- Two kinds of character bank exist in the client's code, and which one World of
-- Warcraft: Forever uses is not known until launch
-- (docs/forever-addon-research.md Q2, launch checklist items 8 and 9):
--   "tabs"    the character bank tabs, Enum.BagIndex.CharacterBankTab_1..9
--   "classic" the older bank: the main bank container plus the bank bags
-- The tabs are tried first. Only when none of them can be read does the classic
-- bank get a turn. The export says which one it was (bankSource), so the first
-- real export shows which path ran. Every global and enum below may be missing;
-- a missing one is skipped, never an error.
--
-- The warband bank is Enum.BagIndex.AccountBankTab_1, _2, ... up to the first
-- one that does not exist. It goes in its own list (warbank) with the same
-- guard. A tab with no slots gives nothing.
--
-- A scan that found no item at all replaces nothing (there is no slot to check
-- the bank against), so the previous list and its "seen" flag stay.
local function ScanBank()
    local previous = truncated

    -- Character bank.
    truncated = false
    local list, seen, last = {}, {}, {}
    local source = nil

    if Enum and Enum.BagIndex then
        for tab = 1, 9 do
            local bag = Enum.BagIndex["CharacterBankTab_" .. tab]
            if bag ~= nil and ScanContainer(bag, list, seen, last) then
                source = "tabs"
            end
        end
    end

    if not source then
        -- The main bank container: the enum value if there is one, else the global.
        local main = Enum and Enum.BagIndex and Enum.BagIndex.Bank
        if main == nil then
            main = BANK_CONTAINER
        end
        if type(main) == "number" and ScanContainer(main, list, seen, last) then
            source = "classic"
        end
        -- The bank bag slots come right after the player's own bag slots.
        if type(NUM_BAG_SLOTS) == "number" and type(NUM_BANKBAGSLOTS) == "number" then
            for bag = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do
                if ScanContainer(bag, list, seen, last) then
                    source = "classic"
                end
            end
        end
    end
    local cut = truncated

    -- Warband bank.
    truncated = false
    local wlist, wseen, wlast = {}, {}, {}
    local wsource = false
    if Enum and Enum.BagIndex and Enum.BagIndex.AccountBankTab_1 ~= nil then
        for tab = 1, 50 do
            local bag = Enum.BagIndex["AccountBankTab_" .. tab]
            if bag == nil then
                break
            end
            if ScanContainer(bag, wlist, wseen, wlast) then
                wsource = true
            end
        end
    end
    local wcut = truncated
    truncated = previous

    -- Nothing readable, or the bank closed during the scan: keep what was there.
    local rec = Cache.Get()
    local now = Now()
    if source and BankStillOpen(last) then
        table.sort(list)
        if not rec.bank or not SameSet(rec.bank.items, list) then
            session.bankDirty = true
        end
        rec.bank = { at = now, source = source, items = list, cut = cut }
        session.live.bank = now
    end
    if wsource and BankStillOpen(wlast) then
        table.sort(wlist)
        if not rec.warbank or not SameSet(rec.warbank.items, wlist) then
            session.warbankDirty = true
        end
        rec.warbank = { at = now, items = wlist, cut = wcut }
        session.live.warbank = now
    end
end

---------------------------------------------------------------------------
-- Professions, spec, region, race, faction
---------------------------------------------------------------------------

-- The professions: name, skill line, rank and max rank. Second result: false when
-- the game has no such function (the section is then missing).
local function CollectProfessions()
    local result = {}
    if not (GetProfessions and GetProfessionInfo) then
        return result, false
    end
    -- GetProfessions returns up to six indexes and nil for an empty slot, so
    -- they go in a table and are read by position, not with #. The skill line is
    -- the 7th return of GetProfessionInfo, proven in Forever's own UI
    -- (Blizzard_Professions/Camelot/Blizzard_ProfessionsFrame.lua:16 and :60). The
    -- ids 2937-2948 the owner mentioned (First Aid = 2942) have no source: no table
    -- of ids and names is kept here, the game's own name and id are sent.
    local indexes = { GetProfessions() }
    for position = 1, 6 do
        local index = indexes[position]
        if index and #result < MAX_PROFESSIONS then
            local name, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(index)
            if name then
                result[#result + 1] = {
                    name = name,
                    skillLineId = skillLine,
                    rank = rank,
                    maxRank = maxRank,
                }
            end
        end
    end
    return result, true
end

local function CollectSpec()
    local specId, specName
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization and C_SpecializationInfo.GetSpecializationInfo then
        pcall(function()
            local index = C_SpecializationInfo.GetSpecialization()
            if index then
                specId, specName = C_SpecializationInfo.GetSpecializationInfo(index)
            end
        end)
    end
    return specId, specName
end

-- GetCurrentRegion() numbers the five regions; anything else is not one of them.
local REGION_NAMES = { [1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN" }

-- Returns region (a name from REGION_NAMES or nil), regionId (the number the
-- client reported, only when it is not one of the five) and portal (a string or
-- nil). Never raises.
local function CollectRegion()
    local id
    if GetCurrentRegion then
        local ok, value = pcall(GetCurrentRegion)
        if ok and type(value) == "number" then
            id = value
        end
    end
    local region = id and REGION_NAMES[id] or nil

    local portal
    if GetCVar then
        local ok, value = pcall(GetCVar, "portal")
        if ok and type(value) == "string" and value ~= "" then
            portal = value
        end
    end

    if region then
        return region, nil, nil
    end
    return nil, id, portal
end

local function CollectRealm()
    return RealmName()
end

-- A string from a game function, or nil when the function is missing, raises, or
-- returns anything but a non-empty string. `index` picks which return value.
local function StringResult(fn, index)
    if not fn then
        return nil
    end
    local results = { pcall(fn, "player") }
    local value = results[index + 1] -- results[1] is pcall's own flag
    if results[1] and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

-- The race file token ("NightElf"), not the localized name: it does not change
-- with the client's language.
local function CollectRace()
    return StringResult(UnitRace, 2)
end

local function CollectFaction()
    return StringResult(UnitFactionGroup, 1)
end

local function IsHardcore()
    if C_GameRules and C_GameRules.IsHardcoreActive then
        local ok, value = pcall(C_GameRules.IsHardcoreActive)
        return ok and value and true or false
    end
    return false
end

---------------------------------------------------------------------------
-- Section readers
---------------------------------------------------------------------------
-- Each reader returns one section table: its source marker plus its data keys, or
-- Missing(reason). They run inside pcall (see Section), so a function the game
-- lacks, or one that raises, makes that section missing/not_available and never
-- stops the export. A reader that met a hidden (secret) value gives
-- missing/in_combat.

local function Section(reader, ...)
    secretSeen = false
    local ok, section = pcall(reader, ...)
    if not ok or type(section) ~= "table" then
        return Missing("not_available")
    end
    if secretSeen then
        return Missing("in_combat")
    end
    return section
end

-- Money, level, XP, XP max and rested XP.
-- UnitLevel, UnitXP and UnitXPMax carry no SecretReturns flag (UnitDocumentation.lua
-- :2474, :3474, :3489). GetMoney and GetXPExhaustion have no documentation entry;
-- Blizzard's own UI calls GetXPExhaustion (Blizzard_StatusTrackingBar/Shared/ExpBar.lua:128,
-- nil when the character is not rested). Every value goes through Int(), which also
-- turns a hidden value into "in_combat" when the game has issecretvalue.
function Read.Player()
    local section = Live(nil)
    local any = false
    local function put(key, fn, min, max, ...)
        if fn then
            local ok, value = pcall(fn, ...)
            value = ok and Int(value) or nil
            if value and value >= min and value <= max then
                section[key] = value
                any = true
            end
        end
    end
    put("money", GetMoney, 0, 10000000000000)
    put("level", UnitLevel, 1, 255, "player")
    put("xp", UnitXP, 0, 1000000000, "player")
    put("xpMax", UnitXPMax, 0, 1000000000, "player")
    if GetXPExhaustion then
        local ok, value = pcall(GetXPExhaustion)
        if ok then
            -- nil means "not rested".
            section.rested = Int(value) or 0
            if section.rested < 0 or section.rested > 1000000000 then
                section.rested = nil
            end
        end
    end
    if not any then
        return Missing("not_available")
    end
    return section
end

-- The completed quest ids: the union of the game's list and the cache.
-- C_QuestLog.GetAllCompletedQuestIDs() -> number[] (QuestLogDocumentation.lua:116);
-- no event says when it is ready, and it may be EMPTY just after login. Completed
-- quests only ever grow, so an empty or short answer never removes anything: the
-- cache keeps every id ever seen, and with no cache an empty answer is
-- missing/not_loaded, never "no quests done".
function Read.QuestsDone(rec, now)
    local fn = C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs
    local live
    if fn then
        local ok, list = pcall(fn)
        if ok and type(list) == "table" then
            live = list
        end
    end
    if live then
        local set = {}
        if rec.quests then
            for _, id in ipairs(rec.quests.ids) do
                set[id] = true
            end
        end
        local fresh, looked = 0, 0
        for _, value in pairs(live) do
            looked = looked + 1
            if looked > CAPS.questsDone * 4 then
                break
            end
            local id = Int(value)
            if id and id >= 1 and id <= MAX_ID then
                fresh = fresh + 1
                set[id] = true
            end
        end
        if fresh > 0 then
            local ids, cut = SortedKeys(set, CAPS.questsDone)
            rec.quests = { at = now, ids = ids, cut = cut or (rec.quests and rec.quests.cut) or false }
            session.live.questsDone = now
        end
    end
    if session.live.questsDone and rec.quests then
        if rec.quests.cut then
            cutSections = true
        end
        return With(Live(session.live.questsDone), { ids = rec.quests.ids })
    end
    if rec.quests then
        if rec.quests.cut then
            cutSections = true
        end
        return With(Cached(rec.quests.at), { ids = rec.quests.ids })
    end
    if not fn then
        return Missing("not_available")
    end
    return Missing("not_loaded")
end

-- The quest log: each quest's id, whether all its objectives are done, and its
-- objectives (text, have, need, done).
-- C_QuestLog.GetNumQuestLogEntries() -> numShownEntries, numQuests (:303);
-- GetInfo(index) -> QuestInfo (:191, struct :1547); GetQuestObjectives(questID)
-- -> {text, type, finished, numFulfilled, numRequired}[] (:477, struct :1581,
-- MayReturnNothing); IsComplete(questID) (:734).
-- Collapsed zone headers hide their quests from the numbered entries. The addon
-- does NOT expand them (that would change the player's quest log window): it counts
-- the quests it could see and sends `hidden`, the number of quests the log has
-- that it could not list. Hidden, task and world quests rows are not listed.
function Read.QuestLog()
    local Q = C_QuestLog
    if not (Q and Q.GetNumQuestLogEntries and Q.GetInfo and Q.GetQuestObjectives) then
        return Missing("not_available")
    end
    local shown, total = Q.GetNumQuestLogEntries()
    shown = Int(shown)
    if not shown then
        return Missing("not_loaded")
    end
    total = Int(total)
    local quests, seen, looked = {}, 0, 0
    for index = 1, shown do
        local info = Q.GetInfo(index)
        if type(info) == "table" and not info.isHeader then
            seen = seen + 1
            local id = Int(info.questID)
            if id and id >= 1 and id <= MAX_ID and not info.isHidden and not info.isTask then
                looked = looked + 1
                if #quests >= CAPS.questLog then
                    cutSections = true
                else
                    local objectives = {}
                    local ok, list = pcall(Q.GetQuestObjectives, id)
                    if ok and type(list) == "table" then
                        for _, objective in ipairs(list) do
                            if #objectives >= CAPS.objectivesPerQuest then
                                cutSections = true
                                break
                            end
                            if type(objective) == "table" then
                                objectives[#objectives + 1] = {
                                    text = CleanText(objective.text, CAPS.objectiveText) or "",
                                    have = math.max(0, math.min(Int(objective.numFulfilled) or 0, 1000000000)),
                                    need = math.max(0, math.min(Int(objective.numRequired) or 0, 1000000000)),
                                    done = objective.finished and true or false,
                                }
                            end
                        end
                    end
                    local complete = false
                    if Q.IsComplete then
                        local okc, value = pcall(Q.IsComplete, id)
                        complete = okc and value and true or false
                    end
                    quests[#quests + 1] = { id = id, done = complete, objectives = objectives }
                end
            end
        end
    end
    local hidden = 0
    if total and total > seen then
        hidden = math.min(total - seen, 1000)
    end
    return With(Live(nil), { quests = quests, hidden = hidden })
end

-- Reputation: faction id, reaction, standing, where the reaction starts, where the
-- next one starts, name. C_Reputation.GetNumFactions() (ReputationInfoDocumentation.lua:117),
-- GetFactionDataByIndex(i) -> FactionData (:63, struct :341-361: factionID, name,
-- reaction, currentStanding, currentReactionThreshold, nextReactionThreshold,
-- isHeader, isHeaderWithRep, isCollapsed). Rows under a collapsed header are not
-- listed, so when the game has both ExpandAllFactionHeaders and CollapseFactionHeader
-- the headers are opened for the read and the ones the player had collapsed are
-- collapsed again afterwards (from the bottom up, so indexes stay right). Headers
-- that sat inside a collapsed header are not known to have been collapsed and stay
-- open. Without both functions nothing is touched and the rows that are visible
-- are read.
function Read.Reputation()
    local R = C_Reputation
    if not (R and R.GetNumFactions and R.GetFactionDataByIndex) then
        return Missing("not_available")
    end

    local function rows()
        local count = Int(R.GetNumFactions()) or 0
        local list = {}
        for index = 1, count do
            local data = R.GetFactionDataByIndex(index)
            if type(data) == "table" then
                list[#list + 1] = { index = index, data = data }
            end
        end
        return list
    end

    local first = rows()
    local collapsed, anyCollapsed = {}, false
    for _, row in ipairs(first) do
        local id = Int(row.data.factionID)
        if row.data.isHeader and row.data.isCollapsed and id then
            collapsed[id] = true
            anyCollapsed = true
        end
    end

    local list = first
    local expanded = false
    if anyCollapsed and R.ExpandAllFactionHeaders and R.CollapseFactionHeader then
        expanded = true
        pcall(R.ExpandAllFactionHeaders)
        local ok, all = pcall(rows)
        if ok then
            list = all
        end
    end

    local out, seen = {}, {}
    for _, row in ipairs(list) do
        local d = row.data
        local id = Int(d.factionID)
        if id and id >= 1 and id <= MAX_ID and not seen[id] and (not d.isHeader or d.isHeaderWithRep) then
            local reaction = Int(d.reaction)
            local standing = Int(d.currentStanding)
            local floor = Int(d.currentReactionThreshold)
            local ceiling = Int(d.nextReactionThreshold)
            local name = CleanText(d.name, CAPS.nameText)
            if reaction and standing and floor and ceiling and name and name ~= "" then
                if #out >= CAPS.factions then
                    cutSections = true
                else
                    seen[id] = true
                    out[#out + 1] = { id, reaction, standing, floor, ceiling, name }
                end
            end
        end
    end

    if expanded then
        for position = #list, 1, -1 do
            local id = Int(list[position].data.factionID)
            if id and collapsed[id] and list[position].data.isHeader then
                pcall(R.CollapseFactionHeader, list[position].index)
            end
        end
    end

    if #out == 0 then
        return Missing("not_loaded")
    end
    return With(Live(nil), { factions = out })
end

-- Trait nodes the character has ranks in: { {node, rank, entry}, ... }.
-- C_Traits.GetTreeNodes(treeID) -> nodeID[] (SharedTraitsDocumentation.lua:586,
-- it lists the nodes of ALL specs, so only nodes with activeRank > 0 are kept);
-- C_Traits.GetNodeInfo(configID, nodeID) -> TraitNodeInfo (:370-385, struct
-- :1093: activeRank, activeEntry = TraitEntryRankInfo { entryID, rank } or nil).
local function TreeNodes(configID, treeID)
    local nodes = {}
    local ok, ids = pcall(C_Traits.GetTreeNodes, treeID)
    if not ok or type(ids) ~= "table" then
        return nodes
    end
    local looked = 0
    for _, nodeId in ipairs(ids) do
        looked = looked + 1
        if looked > 4000 then
            break
        end
        local okInfo, info = pcall(C_Traits.GetNodeInfo, configID, nodeId)
        if okInfo and type(info) == "table" then
            local rank = Int(info.activeRank)
            local node = Int(nodeId)
            if node and node >= 1 and node <= MAX_ID and rank and rank > 0 then
                if #nodes >= CAPS.nodesPerTree then
                    cutSections = true
                    break
                end
                local entry = 0
                if type(info.activeEntry) == "table" then
                    entry = Int(info.activeEntry.entryID) or 0
                end
                nodes[#nodes + 1] = { node, math.min(rank, MAX_TRAIT_RANK), entry }
            end
        end
    end
    return nodes
end

-- Talents: C_ClassTalents.GetActiveConfigID() (nilable; ClassTalentsDocumentation.lua:73)
-- -> C_Traits.GetConfigInfo(configID).treeIDs (SharedTraitsDocumentation.lua:201-216)
-- -> the nodes of each tree. C_TraitConfig is an empty namespace and is not used.
function Read.Talents()
    if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits and C_Traits.GetConfigInfo
        and C_Traits.GetTreeNodes and C_Traits.GetNodeInfo) then
        return Missing("not_available")
    end
    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then
        return Missing("not_loaded")
    end
    local info = C_Traits.GetConfigInfo(configID)
    if type(info) ~= "table" or type(info.treeIDs) ~= "table" then
        return Missing("not_loaded")
    end
    local trees = {}
    for _, treeId in ipairs(info.treeIDs) do
        local tree = Int(treeId)
        if tree and tree >= 1 and tree <= MAX_ID then
            if #trees >= CAPS.talentTrees then
                cutSections = true
                break
            end
            trees[#trees + 1] = { tree = tree, nodes = TreeNodes(configID, tree) }
        end
    end
    if #trees == 0 then
        return Missing("not_loaded")
    end
    return With(Live(nil), { trees = trees })
end

-- Legacy: points available / cap / spent and the ranks in the three trees.
-- configID = C_Traits.GetConfigIDByTreeID(tree) (MayReturnNothing; Blizzard_LegacySystem/
-- Blizzard_LegacySystemUtil.lua:43); C_Traits.GetTreeCurrencyInfo(configID, tree, false)[1]
-- -> quantity (available), maxQuantity (cap, nilable), spent, spentInTree (SharedTraitsDocumentation.lua:537,
-- struct :1188; the UI reads tree 1187 as the shared pool, Blizzard_LegacySystemUtil.lua:41-60).
-- Whether Legacy is account-wide is not proven in the source, so it is cached per
-- character like the rest. The challenges are achievements, listed only through the
-- achievement UI's filtered view (Blizzard_LegacyChallenges.lua:85, 285-309, async,
-- "wait for ACHIEVEMENT_SEARCH_UPDATED") and no root category id is in the source,
-- so there is no reliable list: the challenges are always missing/not_available in
-- 0.4.0.
function Read.Legacy(rec, now)
    local function fromCache()
        if rec.legacy then
            return With(Cached(rec.legacy.at), {
                points = rec.legacy.points,
                trees = rec.legacy.trees,
                challenges = Missing("not_available"),
            })
        end
        return nil
    end

    if not (C_Traits and C_Traits.GetConfigIDByTreeID and C_Traits.GetTreeNodes and C_Traits.GetNodeInfo) then
        return fromCache() or Missing("not_available")
    end

    local consts = Constants and Constants.LegacyConsts
    local ids = {
        consts and consts.LEGACY_TREE_PROFESSIONS_ID or LEGACY_TREES[1],
        consts and consts.LEGACY_TREE_ADVENTURE_ID or LEGACY_TREES[2],
        consts and consts.LEGACY_TREE_PROGRESSION_ID or LEGACY_TREES[3],
    }

    local trees, points = {}, nil
    for _, treeId in ipairs(ids) do
        local tree = Int(treeId)
        local okConfig, configID = pcall(C_Traits.GetConfigIDByTreeID, treeId)
        if tree and okConfig and configID and #trees < CAPS.legacyTrees then
            local spentInTree = 0
            if C_Traits.GetTreeCurrencyInfo then
                local okCurrency, currency = pcall(C_Traits.GetTreeCurrencyInfo, configID, treeId, false)
                local first = okCurrency and type(currency) == "table" and currency[1] or nil
                if type(first) == "table" then
                    spentInTree = CleanCount(first.spentInTree) or 0
                    if not points then
                        points = Points(CleanCount(first.quantity), CleanCount(first.maxQuantity), CleanCount(first.spent))
                    end
                end
            end
            trees[#trees + 1] = { tree = tree, spent = spentInTree, nodes = TreeNodes(configID, treeId) }
        end
    end

    if #trees == 0 then
        -- Not loaded yet (no config for any tree): the last good read, if any.
        return fromCache() or Missing("not_loaded")
    end
    rec.legacy = { at = now, points = points, trees = trees }
    session.live.legacy = now
    return With(Live(now), { points = points, trees = trees, challenges = Missing("not_available") })
end

-- The season's PvP rank. Forever has no Classic honor rank (UnitPVPRank and
-- GetPVPRankInfo are not in its API); its PvP rank is the renown level of major
-- faction 2800 (Camelot/PVPRankFrame.lua:1, :91), per season, 0 = unranked.
-- C_MajorFactions.GetMajorFactionProgressionInfo(2800) -> renownLevel, maxLevel
-- (MajorFactionsDocumentation.lua:56, struct :287-297). There is no "highest ever"
-- value, so the keys say "season".
function Read.Honor()
    if not (C_MajorFactions and C_MajorFactions.GetMajorFactionProgressionInfo) then
        return Missing("not_available")
    end
    local factionId = type(PVP_RANK_POINTS_FACTION_ID) == "number" and PVP_RANK_POINTS_FACTION_ID or PVP_RANK_FACTION_ID
    local data = C_MajorFactions.GetMajorFactionProgressionInfo(factionId)
    if type(data) ~= "table" then
        return Missing("not_loaded")
    end
    local rank = Int(data.renownLevel)
    if not rank or rank < 0 or rank > 1000 then
        return Missing("not_available")
    end
    local maxRank = Int(data.maxLevel)
    if maxRank and (maxRank < 0 or maxRank > 1000) then
        maxRank = nil
    end
    return With(Live(nil), { seasonRank = rank, seasonMax = maxRank })
end

-- The spells the class knows, from the spell book (not the trainer window, which
-- only lists what that trainer teaches). C_SpellBook.GetNumSpellBookSkillLines()
-- (SpellBookDocumentation.lua:137), GetSpellBookSkillLineInfo(i) (:486, struct
-- :1028: name, itemIndexOffset, numSpellBookItems, isGuild, shouldHide),
-- GetSpellBookItemInfo(slot, Enum.SpellBookSpellBank.Player) (:290, struct :1012:
-- spellID, actionID, itemType, isOffSpec). Skipped: guild and hidden lines, lines
-- named like a profession the character has (profession spells), off-spec items,
-- anything that is not a spell (flyouts, future spells) and entries without a
-- spellID. The id sent is the spellID.
function Read.ClassSpells(professionNames)
    local B = C_SpellBook
    if not (B and B.GetNumSpellBookSkillLines and B.GetSpellBookSkillLineInfo and B.GetSpellBookItemInfo) then
        return Missing("not_available")
    end
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
    local lines = Int(B.GetNumSpellBookSkillLines())
    if not lines or lines < 1 then
        return Missing("not_loaded")
    end
    local set, count = {}, 0
    for line = 1, lines do
        local info = B.GetSpellBookSkillLineInfo(line)
        if type(info) == "table" and not info.isGuild and not info.shouldHide and not professionNames[info.name or ""] then
            local offset = Int(info.itemIndexOffset) or 0
            local number = Int(info.numSpellBookItems) or 0
            for slot = offset + 1, offset + math.min(number, 1000) do
                local item = B.GetSpellBookItemInfo(slot, bank)
                if type(item) == "table" and not item.isOffSpec and (spellType == nil or item.itemType == spellType) then
                    local id = Int(item.spellID)
                    if id and id >= 1 and id <= MAX_ID and not set[id] then
                        count = count + 1
                        if count > CAPS.classSpells then
                            cutSections = true
                        else
                            set[id] = true
                        end
                    end
                end
            end
        end
    end
    if count == 0 then
        return Missing("not_loaded")
    end
    local list = SortedKeys(set, CAPS.classSpells)
    return With(Live(nil), { ids = list })
end

-- The recipes of every profession read so far (cache record + this session).
-- Live when a profession window was read in this play session, cache otherwise,
-- missing/open_profession_window when none ever was. Each profession carries the
-- time its recipes were last read.
function Read.Recipes(rec)
    local lines = {}
    local newest = 0
    for line, entry in pairs(rec.recipes) do
        local recipes = {}
        for id, reagents in pairs(entry.recipes) do
            recipes[#recipes + 1] = { id, reagents }
        end
        table.sort(recipes, function(a, b) return a[1] < b[1] end)
        lines[#lines + 1] = { line = line, name = entry.name, at = entry.at, recipes = recipes }
        if entry.at > newest then
            newest = entry.at
        end
        if entry.cut then
            cutSections = true
        end
    end
    if #lines == 0 then
        local T = C_TradeSkillUI
        if not (T and T.GetRecipeSchematic) then
            return Missing("not_available")
        end
        return Missing("open_profession_window")
    end
    table.sort(lines, function(a, b) return a.line < b.line end)
    if session.live.recipes then
        return With(Live(session.live.recipes), { lines = lines })
    end
    return With(Cached(newest), { lines = lines })
end

function Read.FlightPaths(rec)
    if not rec.flights then
        if not (C_TaxiMap and (C_TaxiMap.GetAllTaxiNodes or C_TaxiMap.GetTaxiNodesForMap)) then
            return Missing("not_available")
        end
        return Missing("open_flight_map")
    end
    if session.live.flights then
        return With(Live(session.live.flights), { ids = rec.flights.ids })
    end
    return With(Cached(rec.flights.at), { ids = rec.flights.ids })
end

---------------------------------------------------------------------------
-- Captures: what the game only lets the addon read while a window is open. They
-- run on events, do nothing in combat, never print more than one line and put
-- what they read in the cache record (merged, never replaced).
---------------------------------------------------------------------------

local function Plural(count, one, many)
    return count == 1 and one or many
end

-- Recipes and reagents of the profession whose window is open.
-- C_TradeSkillUI.GetBaseProfessionInfo() -> ProfessionInfo (TradeSkillUIDocumentation.lua:130;
-- the UI takes parentProfessionID or professionID as the skill line,
-- Blizzard_Professions/ProfessionsTemplates/Blizzard_Professions.lua:1678-1681);
-- GetAllRecipeIDs() exists only in the community API list (the generated docs do not
-- have it), so GetFilteredRecipeIDs() (used at Blizzard_Professions.lua:847; it follows
-- the window's search and filters) is the fallback; GetRecipeInfo(id).learned (:639);
-- GetRecipeSchematic(id, false).reagentSlotSchematics[] (:753): for each slot
-- reagents[1].itemID and quantityRequired. Skipped: slots that are not required
-- (optional and finishing reagents), slots whose first reagent is a currency (no
-- itemID), and quality tiers other than the first. Other people's windows are skipped
-- with the test Blizzard's own UI uses (Blizzard_Professions.lua:281, :378):
-- IsTradeSkillLinked, IsTradeSkillGuild, IsTradeSkillGuildMember, and IsNPCCrafting.
function Capture.Recipes()
    session.recipesPending = false
    if InCombat() then
        return
    end
    local T = C_TradeSkillUI
    if not (T and T.GetBaseProfessionInfo and T.GetRecipeInfo and T.GetRecipeSchematic) then
        return
    end
    for _, name in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember" }) do
        local fn = _G[name]
        if fn then
            local ok, value = pcall(fn)
            if ok and value then
                return
            end
        end
    end
    if T.IsNPCCrafting then
        local ok, value = pcall(T.IsNPCCrafting)
        if ok and value then
            return
        end
    end

    secretSeen = false
    local okBase, base = pcall(T.GetBaseProfessionInfo)
    if not okBase or type(base) ~= "table" then
        return
    end
    local line = Int(base.parentProfessionID)
    if not line or line <= 0 then
        line = Int(base.professionID)
    end
    if not line or line < 1 or line > MAX_ID then
        return
    end
    local professionName = CleanText(base.professionName, CAPS.nameText)

    -- The ids: everything the window knows, else what its filters show.
    local ids
    for _, fnName in ipairs({ "GetAllRecipeIDs", "GetFilteredRecipeIDs" }) do
        local fn = T[fnName]
        if fn and not (type(ids) == "table" and #ids > 0) then
            local ok, list = pcall(fn)
            if ok and type(list) == "table" then
                ids = list
            end
        end
    end
    if type(ids) ~= "table" or #ids == 0 or secretSeen then
        return
    end

    local rec = Cache.Get()
    local now = Now()
    local entry = rec.recipes[line]
    if not entry then
        local lines = 0
        for _ in pairs(rec.recipes) do
            lines = lines + 1
        end
        if lines >= CAPS.recipeLines then
            return
        end
        entry = { at = now, name = professionName, recipes = {}, cut = false }
        rec.recipes[line] = entry
    end

    local known = 0
    for _ in pairs(entry.recipes) do
        known = known + 1
    end
    local added = 0
    local required = Enum and Enum.CraftingReagentType
    local looked = 0
    for _, rawId in ipairs(ids) do
        looked = looked + 1
        if looked > CAPS.recipesPerLine * 4 then
            break
        end
        local id = Int(rawId)
        if id and id >= 1 and id <= MAX_ID then
            local existing = entry.recipes[id]
            if existing == nil or #existing == 0 then
                local okInfo, info = pcall(T.GetRecipeInfo, id)
                if okInfo and type(info) == "table" and info.learned then
                    if existing == nil and known >= CAPS.recipesPerLine then
                        entry.cut = true
                    else
                        local reagents = {}
                        local okSchematic, schematic = pcall(T.GetRecipeSchematic, id, false)
                        if okSchematic and type(schematic) == "table" and type(schematic.reagentSlotSchematics) == "table" then
                            for _, slot in ipairs(schematic.reagentSlotSchematics) do
                                if type(slot) == "table" and #reagents < CAPS.reagentsPerRecipe and slot.required ~= false then
                                    local skip = required and (slot.reagentType == required.Finishing or slot.reagentType == required.Modifying)
                                    local first = type(slot.reagents) == "table" and slot.reagents[1] or nil
                                    local item = type(first) == "table" and Int(first.itemID) or nil
                                    local count = Int(slot.quantityRequired)
                                    if not skip and item and item >= 1 and item <= MAX_ID and count and count >= 1 then
                                        reagents[#reagents + 1] = { item, math.min(count, MAX_REAGENT_COUNT) }
                                    end
                                end
                            end
                        end
                        if existing == nil then
                            known = known + 1
                            added = added + 1
                        end
                        entry.recipes[id] = reagents
                    end
                end
            end
        end
    end

    if secretSeen then
        return
    end
    entry.at = now
    entry.name = professionName or entry.name
    session.live.recipes = now
    if added > 0 then
        Say(string.format("saved %d %s %s.", known, entry.name or "profession", Plural(known, "recipe", "recipes")))
    end
end

-- Debounced: the window fires its list update many times while it loads or is
-- filtered. Without C_Timer the capture runs at once.
function Capture.ScheduleRecipes()
    if session.recipesPending then
        return
    end
    if C_Timer and C_Timer.After then
        session.recipesPending = true
        C_Timer.After(0.6, Capture.Recipes)
    else
        Capture.Recipes()
    end
end

-- Flight paths known, while a flight map is open.
-- Forever (game type "camelot") does not load Blizzard's TaxiFrame that uses
-- NumTaxiNodes/TaxiNodeName/TaxiNodeGetType (Blizzard_UIPanels_Game.toc:133-136),
-- so those globals are not used. C_TaxiMap.GetAllTaxiNodes(uiMapID) -> {nodeID, name,
-- state} where state is Enum.FlightPathState (Current 0, Reachable 1: known; Unreachable
-- 2) (TaxiMapDocumentation.lua:11-24), and GetTaxiNodesForMap(uiMapID) -> {nodeID,
-- isUndiscovered} (:26-39). The map to ask about: GetTaxiMapID() (the flight map being
-- shown) when the game has it, else the player's map and its parents. Stable
-- nodeIDs are merged into the cache, never removed.
function Capture.Flights()
    if InCombat() then
        return
    end
    local T = C_TaxiMap
    if not (T and (T.GetAllTaxiNodes or T.GetTaxiNodesForMap)) then
        return
    end
    secretSeen = false
    local maps, seenMap = {}, {}
    local function addMap(value)
        local id = Int(value)
        if id and id > 0 and not seenMap[id] and #maps < 8 then
            seenMap[id] = true
            maps[#maps + 1] = id
        end
    end
    if GetTaxiMapID then
        local ok, value = pcall(GetTaxiMapID)
        if ok then
            addMap(value)
        end
    end
    if C_Map and C_Map.GetBestMapForUnit then
        local ok, value = pcall(C_Map.GetBestMapForUnit, "player")
        if ok then
            addMap(value)
            local current = Int(value)
            for _ = 1, 5 do
                if not (current and C_Map.GetMapInfo) then
                    break
                end
                local okInfo, info = pcall(C_Map.GetMapInfo, current)
                current = okInfo and type(info) == "table" and Int(info.parentMapID) or nil
                if current and current > 0 then
                    addMap(current)
                else
                    break
                end
            end
        end
    end

    local state = Enum and Enum.FlightPathState
    local currentState = state and state.Current or 0
    local reachableState = state and state.Reachable or 1
    local found = {}
    for _, map in ipairs(maps) do
        if T.GetAllTaxiNodes then
            local ok, nodes = pcall(T.GetAllTaxiNodes, map)
            if ok and type(nodes) == "table" then
                for _, node in ipairs(nodes) do
                    if type(node) == "table" and (node.state == currentState or node.state == reachableState) then
                        local id = Int(node.nodeID)
                        if id and id >= 1 and id <= MAX_ID then
                            found[id] = true
                        end
                    end
                end
            end
        end
        if T.GetTaxiNodesForMap then
            local ok, nodes = pcall(T.GetTaxiNodesForMap, map)
            if ok and type(nodes) == "table" then
                for _, node in ipairs(nodes) do
                    if type(node) == "table" and node.isUndiscovered == false then
                        local id = Int(node.nodeID)
                        if id and id >= 1 and id <= MAX_ID then
                            found[id] = true
                        end
                    end
                end
            end
        end
    end
    if secretSeen or next(found) == nil then
        return
    end

    local rec = Cache.Get()
    local now = Now()
    local before = rec.flights and rec.flights.ids or {}
    local all = {}
    for _, id in ipairs(before) do
        all[id] = true
    end
    local added = 0
    for id in pairs(found) do
        if not all[id] then
            all[id] = true
            added = added + 1
        end
    end
    local ids = SortedKeys(all, CAPS.flightPaths)
    rec.flights = { at = now, ids = ids }
    session.live.flights = now
    if added > 0 then
        Say(string.format("saved %d %s.", #ids, Plural(#ids, "flight path", "flight paths")))
    end
end

---------------------------------------------------------------------------
-- The payload
---------------------------------------------------------------------------

-- What the window shows about the character (set by BuildPayload).
local view = {}

-- Returns the payload table, or nil and a short reason.
local function BuildPayload()
    local name = UnitName("player")
    if not name or name == "" then
        return nil, "Could not read the character's name."
    end
    local region, regionId, portal = CollectRegion()

    local _, classFile, classId = UnitClass("player")
    local _, build, _, interface = GetBuildInfo()
    local specId, specName = CollectSpec()

    local now = Now()
    local rec = Cache.Get()
    cutSections = false

    -- The bank lists come from the cache record: the last full scan, read in this
    -- play session (live) or an earlier one (cache). Nothing is sent as bank
    -- contents when the bank was never read.
    local bank, bankSeen, bankSource = {}, false, nil
    local bankCut = false
    if rec.bank then
        for i = 1, #rec.bank.items do
            bank[i] = rec.bank.items[i]
        end
        bankSeen, bankSource, bankCut = true, rec.bank.source, rec.bank.cut
    end
    local warbank, warbankSeen = {}, false
    local warbankCut = false
    if rec.warbank then
        for i = 1, #rec.warbank.items do
            warbank[i] = rec.warbank.items[i]
        end
        warbankSeen, warbankCut = true, rec.warbank.cut
    end

    -- Bags are read now; the bank lists were cut at the time they were scanned.
    local bags = CollectBags()
    local equipped = CollectEquipped()
    local professions, professionsOk = CollectProfessions()
    local professionNames = {}
    for _, profession in ipairs(professions) do
        professionNames[profession.name] = true
    end

    local sections = {
        equipped = Live(nil),
        bags = Live(nil),
        bank = rec.bank and (session.live.bank and Live(session.live.bank) or Cached(rec.bank.at))
            or Missing(C_Container and "open_bank" or "not_available"),
        -- A client with no warband bank tabs (Enum.BagIndex.AccountBankTab_1) has no such bank to open.
        warbank = rec.warbank and (session.live.warbank and Live(session.live.warbank) or Cached(rec.warbank.at))
            or Missing(C_Container and Enum and Enum.BagIndex and Enum.BagIndex.AccountBankTab_1 ~= nil and "open_bank" or "not_available"),
        professions = professionsOk and Live(nil) or Missing("not_available"),
        recipes = Section(Read.Recipes, rec),
        questsDone = Section(Read.QuestsDone, rec, now),
        questLog = Section(Read.QuestLog),
        reputation = Section(Read.Reputation),
        player = Section(Read.Player),
        talents = Section(Read.Talents),
        legacy = Section(Read.Legacy, rec, now),
        flightPaths = Section(Read.FlightPaths, rec),
        honor = Section(Read.Honor),
        classSpells = Section(Read.ClassSpells, professionNames),
    }

    local cut = truncated or bankCut or warbankCut or cutSections

    -- The window shows the names in the player's language (the first returns).
    view = {
        name = name,
        level = UnitLevel("player"),
        race = StringResult(UnitRace, 1) or CollectRace(),
        class = StringResult(UnitClass, 1) or classFile,
        realm = CollectRealm(),
    }

    return {
        format = FORMAT_VERSION,
        addonVersion = ADDON_VERSION,
        client = { build = build, interface = interface },
        capturedAt = now,
        identity = {
            name = name,
            region = region, -- nil leaves the key out
            regionId = regionId,
            portal = portal,
            realm = CollectRealm(), -- nil leaves the key out
            guid = UnitGUID("player"),
            classFile = classFile,
            classID = classId,
            race = CollectRace(), -- nil leaves the key out
            faction = CollectFaction(), -- nil leaves the key out
            level = UnitLevel("player"),
            specID = specId,
            specName = specName,
            hardcore = IsHardcore(),
        },
        equipped = equipped,
        bags = bags,
        bank = bank,
        bankSeen = bankSeen,
        bankSource = bankSeen and bankSource or nil, -- left out when the bank was not seen
        warbank = warbank,
        warbankSeen = warbankSeen,
        truncated = cut or nil, -- true only when a list was cut; nil leaves the key out
        professions = professions,
        sections = sections,
    }
end

---------------------------------------------------------------------------
-- Encoding: plain JSON, written here
---------------------------------------------------------------------------

-- The text of an export is "WOWCHAR:3:" and then one JSON value. The writer
-- below handles only what the payload holds: whole numbers, booleans, strings,
-- lists and objects. Rules (the tests pin them):
--   * Object keys are written in sorted order, so the same data always gives the
--     same text. A key whose value is nil is not written.
--   * A table with no keys at all is written as [] (an empty list). Every list
--     in the payload may be empty and none of the objects is, so the server can
--     rely on that.
--   * A table whose keys are exactly 1..n is a list; one with only string keys is
--     an object. Anything else (mixed keys, holes, other key types), a cycle,
--     more than MAX_DEPTH levels, or a value that is a function, userdata or
--     thread, is an error: the export is not made.
--   * A number that is a whole number (within +-2^53) is written as an integer.
--     A fraction, NaN, infinity or a larger number is written as null (the
--     payload has none of these).
--   * Strings are escaped: " and \ get a backslash, line feed, carriage return
--     and tab are written \n, \r and \t, every other control character (below
--     0x20) and DEL are written as \u00XX, and "|" is written as |. A "|"
--     is the start of a colour code or link in the game's text box, so no "|"
--     may reach the copy box; the server reads | as "|" again. Other bytes
--     (UTF-8 letters) are written as they are.
-- The deepest value is a reagent in a recipe of a profession of the recipes
-- section: payload > sections > recipes > lines > line > recipes > recipe >
-- reagents > reagent > number, 9 tables and the number: MAX_DEPTH leaves room.
local MAX_DEPTH = 10

local function EscapeChar(c)
    if c == '"' then return '\\"'
    elseif c == "\\" then return "\\\\"
    elseif c == "\n" then return "\\n"
    elseif c == "\r" then return "\\r"
    elseif c == "\t" then return "\\t"
    end
    return string.format("\\u%04x", c:byte())
end

local function WriteString(buffer, value)
    buffer[#buffer + 1] = '"' .. value:gsub('[%z\1-\31\127"\\|]', EscapeChar) .. '"'
end

local function WriteNumber(buffer, value)
    if value ~= value or value ~= math.floor(value) or value > 9007199254740991 or value < -9007199254740991 then
        buffer[#buffer + 1] = "null"
    else
        buffer[#buffer + 1] = string.format("%.0f", value)
    end
end

local WriteValue

local function WriteTable(buffer, value, depth)
    if depth > MAX_DEPTH then
        error("too deep")
    end
    local count, stringKeys = 0, {}
    for key in pairs(value) do
        count = count + 1
        if type(key) == "string" then
            stringKeys[#stringKeys + 1] = key
        end
    end

    if count == 0 then
        buffer[#buffer + 1] = "[]"
    elseif #stringKeys == 0 then
        -- Must be exactly 1..count.
        for i = 1, count do
            if value[i] == nil then
                error("list with a hole or a key that is not a string")
            end
        end
        buffer[#buffer + 1] = "["
        for i = 1, count do
            if i > 1 then
                buffer[#buffer + 1] = ","
            end
            WriteValue(buffer, value[i], depth + 1)
        end
        buffer[#buffer + 1] = "]"
    elseif #stringKeys == count then
        table.sort(stringKeys)
        buffer[#buffer + 1] = "{"
        for i, key in ipairs(stringKeys) do
            if i > 1 then
                buffer[#buffer + 1] = ","
            end
            WriteString(buffer, key)
            buffer[#buffer + 1] = ":"
            WriteValue(buffer, value[key], depth + 1)
        end
        buffer[#buffer + 1] = "}"
    else
        error("table with mixed keys")
    end
end

WriteValue = function(buffer, value, depth)
    local kind = type(value)
    if kind == "string" then
        WriteString(buffer, value)
    elseif kind == "number" then
        WriteNumber(buffer, value)
    elseif kind == "boolean" then
        buffer[#buffer + 1] = value and "true" or "false"
    elseif kind == "table" then
        -- A table inside itself would never end; the depth limit stops it.
        WriteTable(buffer, value, depth)
    else
        error("cannot write a " .. kind)
    end
end

-- Returns the JSON text of a value. Raises on what the rules above refuse.
local function Serialize(value)
    local buffer = {}
    WriteValue(buffer, value, 1)
    return table.concat(buffer)
end

local function Encode(payload)
    local ok, result = pcall(Serialize, payload)
    if not ok or type(result) ~= "string" then
        return nil, "The export could not be made."
    end
    return PREFIX .. result
end

if type(ns) == "table" then
    ns.Serialize = Serialize
    ns.ParseItemString = ParseItemString
    ns.CAPS = CAPS
    ns.REASONS = REASONS
    ns.MAX_EXPORT_LENGTH = MAX_EXPORT_LENGTH
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
-- A frame made from Blizzard's own templates, no libraries:
--   BasicFrameTemplateWithInset   title bar, close button and the inset
--   InputScrollFrameTemplate      the scrolling text box (child .EditBox)
--   UIPanelButtonTemplate         the two buttons
-- Each is made inside pcall and has a fallback (a BackdropTemplate frame, a
-- UIPanelScrollFrameTemplate with an EditBox), so a client where a template is
-- missing or renamed still gets a working window. Size 620 x 470, centred, draggable
-- by any part of the frame, closed by Escape (UISpecialFrames, when the client has
-- it), Close and the title bar's X.
--
-- Layout (all offsets from the frame's edges, y downward):
--   title            the template's title text, "wowchar export", primary colour
--   character line   TOPLEFT 16,-34: name (accent), "level L Race Class - Realm"
--   divider          1 px line, primary at 60 percent, y -58
--   checklist        two columns from y -66, 18 px a row, 8 + 7 rows:
--                       <icon> <section>  <state in words>
--   export header    y -214: "Export text (selected: press Ctrl+C to copy)"
--   text box         TOPLEFT 16,-234, 568 x 130 (scrolls)
--   size line        BOTTOMLEFT 16,72: characters, KB, format, cut warnings
--   paste line       BOTTOMLEFT 16,54: "Paste it on wowchar.toaweb.com > My characters"
--   buttons          "Select all" BOTTOMLEFT 16,14; "Close" BOTTOMRIGHT -16,14; 110 x 24
-- Colours: background #131129, primary #8B7CFF (title, divider, "saved earlier"),
-- accent #5FD4E6 (name, "read now"), muted violet #9A97B8 for hints, soft red
-- #FF7A8A for what is missing.
-- The icons in the checklist are Blizzard's ready-check textures, drawn with |T..|t in
-- the window's text only (never in the export): Ready (read now), Waiting (saved
-- earlier), NotReady (missing). The state is also in words on every row, so a client
-- without those textures loses nothing.

local WINDOW_WIDTH, WINDOW_HEIGHT = 620, 470
local ICON_LIVE = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t"
local ICON_CACHE = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:14|t"
local ICON_MISSING = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14|t"
local COLOR_LIVE, COLOR_CACHE, COLOR_MISSING, COLOR_HINT = "ff5FD4E6", "ff8B7CFF", "ffFF7A8A", "ff9A97B8"

-- The rows of the checklist: section, label, column. Left column first.
local ROWS = {
    { "equipped", "Equipped items" },
    { "bags", "Bags" },
    { "bank", "Bank" },
    { "warbank", "Warband bank" },
    { "professions", "Professions" },
    { "recipes", "Recipes" },
    { "questsDone", "Completed quests" },
    { "questLog", "Quest log" },
    { "reputation", "Reputation" },
    { "player", "Gold, level, XP" },
    { "talents", "Talents" },
    { "legacy", "Legacy" },
    { "flightPaths", "Flight paths" },
    { "honor", "Honor rank (season)" },
    { "classSpells", "Class spells" },
}

-- What to do about a missing section, in words (the codes are in REASONS).
local WHY_TEXT = {
    open_bank = "open your bank",
    open_profession_window = "open a profession window",
    open_flight_map = "open a flight map",
    not_loaded = "not loaded yet, try again",
    in_combat = "hidden in combat",
    not_available = "not in this game version",
    too_large = "left out: text too long",
}

local function Ago(at)
    local seconds = Now() - at
    if seconds < 60 then
        return "just now"
    elseif seconds < 3600 then
        return string.format("%d min ago", math.floor(seconds / 60))
    elseif seconds < 86400 then
        return string.format("%d h ago", math.floor(seconds / 3600))
    end
    return string.format("%d d ago", math.floor(seconds / 86400))
end

local function Thousands(n)
    local text = string.format("%d", n)
    local out = text
    while true do
        local replaced
        out, replaced = out:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        if replaced == 0 then
            break
        end
    end
    return out
end

-- How much a section holds, for the checklist ("" when it has no count).
local function Detail(name, payload)
    local s = payload.sections[name]
    if s.source == "missing" then
        return ""
    end
    local count
    if name == "bank" then
        count = #payload.bank
    elseif name == "warbank" then
        count = #payload.warbank
    elseif name == "recipes" then
        count = 0
        for _, line in ipairs(s.lines) do
            count = count + #line.recipes
        end
    elseif name == "questsDone" or name == "flightPaths" or name == "classSpells" then
        count = #s.ids
    elseif name == "questLog" then
        count = #s.quests
    elseif name == "reputation" then
        count = #s.factions
    end
    if count then
        return " (" .. Thousands(count) .. ")"
    end
    return ""
end

-- The text of one checklist row.
local function RowText(name, label, payload)
    local s = payload.sections[name]
    local icon, color, state
    if s.source == "live" then
        icon, color, state = ICON_LIVE, COLOR_LIVE, "read now"
    elseif s.source == "cache" then
        icon, color, state = ICON_CACHE, COLOR_CACHE, "saved " .. Ago(s.at)
    else
        icon, color, state = ICON_MISSING, COLOR_MISSING, WHY_TEXT[s.why] or s.why
    end
    return icon .. " " .. label .. Detail(name, payload) .. "  |c" .. color .. state .. "|r"
end

local frame, editBox, currentText
local widgets = {}

-- The text box. InputScrollFrameTemplate (InputBoxTemplates.xml:72, child EditBox, key
-- value maxLetters = 0 for no limit) when the client has it; else the plain scroll
-- frame and edit box of 0.3.1.
local function CreateTextBox(parent)
    local ok, scroll = pcall(CreateFrame, "ScrollFrame", "WowcharExportInput", parent, "InputScrollFrameTemplate")
    if ok and type(scroll) == "table" and type(scroll.EditBox) == "table" then
        scroll:SetPoint("TOPLEFT", 16, -234)
        scroll:SetSize(556, 130)
        if type(scroll.CharCount) == "table" then
            scroll.CharCount:Hide()
        end
        local box = scroll.EditBox
        box:SetWidth(530)
        box:SetMaxLetters(0)
        box:SetMaxBytes(0)
        return scroll, box, true
    end

    local plain = CreateFrame("ScrollFrame", "WowcharExportScroll", parent, "UIPanelScrollFrameTemplate")
    plain:SetPoint("TOPLEFT", 16, -234)
    plain:SetSize(540, 130)
    local box = CreateFrame("EditBox", "WowcharExportEditBox", plain)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject(ChatFontNormal)
    box:SetWidth(520)
    box:SetMaxLetters(0)
    box:SetMaxBytes(0)
    plain:SetScrollChild(box)
    return plain, box, false
end

function UI.Create()
    local templated = true
    local created, f = pcall(CreateFrame, "Frame", "WowcharExportFrame", UIParent, "BasicFrameTemplateWithInset")
    if not created or type(f) ~= "table" then
        templated = false
        created, f = pcall(CreateFrame, "Frame", "WowcharExportFrame", UIParent, "BackdropTemplate")
        if not created then
            f = CreateFrame("Frame", "WowcharExportFrame", UIParent)
        end
        if f.SetBackdrop then
            f:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 32,
                insets = { left = 8, right = 8, top = 8, bottom = 8 },
            })
        end
    end
    f:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- Indigo (#131129) over the template's marble, inside its inset.
    local background = f:CreateTexture(nil, "BACKGROUND", nil, 3)
    background:SetColorTexture(0.0745, 0.0667, 0.1608, 1)
    if templated then
        background:SetPoint("TOPLEFT", 6, -26)
        background:SetPoint("BOTTOMRIGHT", -8, 6)
    else
        background:SetPoint("TOPLEFT", 10, -10)
        background:SetPoint("BOTTOMRIGHT", -10, 10)
    end

    -- Escape closes the window (when the client has the list; not verified on Forever).
    pcall(function()
        if type(UISpecialFrames) == "table" and tinsert then
            tinsert(UISpecialFrames, "WowcharExportFrame")
        end
    end)

    local title = type(f.TitleText) == "table" and f.TitleText or nil
    if not title then
        title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -6)
    end
    title:SetText("wowchar export")
    title:SetTextColor(0.545, 0.486, 1)
    widgets.title = title

    local character = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
    character:SetPoint("TOPLEFT", 16, -34)
    character:SetPoint("TOPRIGHT", -16, -34)
    character:SetJustifyH("LEFT")
    widgets.character = character

    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.545, 0.486, 1, 0.6)
    divider:SetPoint("TOPLEFT", 16, -58)
    divider:SetPoint("TOPRIGHT", -16, -58)
    divider:SetHeight(1)

    widgets.rows = {}
    for i, row in ipairs(ROWS) do
        local text = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        local column = i <= 8 and 0 or 1
        local position = i <= 8 and i or i - 8
        text:SetPoint("TOPLEFT", 16 + column * 296, -66 - (position - 1) * 18)
        text:SetWidth(290)
        text:SetJustifyH("LEFT")
        widgets.rows[i] = text
    end

    local header = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("TOPLEFT", 16, -214)
    header:SetTextColor(0.373, 0.831, 0.902)
    header:SetText("Export text (selected: press Ctrl+C to copy)")
    widgets.header = header

    local box, edit
    box, edit = CreateTextBox(f)
    editBox = edit
    -- The text is for copying: typing in the box puts the original back. Hooked, not
    -- replaced, so the template's own scripts keep running.
    local function onChanged(self, userInput)
        if userInput and currentText and self:GetText() ~= currentText then
            self:SetText(currentText)
            self:HighlightText()
        end
    end
    local function onEscape(self)
        self:ClearFocus()
        f:Hide()
    end
    if edit.HookScript then
        edit:HookScript("OnTextChanged", onChanged)
        edit:HookScript("OnEscapePressed", onEscape)
    else
        edit:SetScript("OnTextChanged", onChanged)
        edit:SetScript("OnEscapePressed", onEscape)
    end

    local size = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    size:SetPoint("BOTTOMLEFT", 16, 72)
    size:SetPoint("BOTTOMRIGHT", -16, 72)
    size:SetJustifyH("LEFT")
    widgets.size = size

    local paste = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    paste:SetPoint("BOTTOMLEFT", 16, 54)
    paste:SetTextColor(0.545, 0.486, 1)
    paste:SetText("Paste it on wowchar.toaweb.com > My characters")
    widgets.paste = paste

    local selectAll = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    selectAll:SetSize(110, 24)
    selectAll:SetPoint("BOTTOMLEFT", 16, 14)
    selectAll:SetText("Select all")
    selectAll:SetScript("OnClick", function()
        editBox:SetFocus()
        editBox:HighlightText()
    end)

    local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    close:SetSize(110, 24)
    close:SetPoint("BOTTOMRIGHT", -16, 14)
    close:SetText("Close")
    close:SetScript("OnClick", function()
        editBox:ClearFocus()
        f:Hide()
    end)

    -- However the window closes (Escape through UISpecialFrames, Close, or
    -- another addon), the box gives up the keyboard so typing reaches the game.
    f:SetScript("OnHide", function()
        editBox:ClearFocus()
    end)

    f:Hide()
    return f
end

-- Shows the window with the checklist and the export text, or with a message
-- (an error) and no text.
function UI.Show(text, payload, message)
    if not frame then
        frame = UI.Create()
    end
    currentText = text
    if payload then
        local line = "|cff5FD4E6" .. (view.name or "?") .. "|r"
        local parts = {}
        if view.level then parts[#parts + 1] = "level " .. view.level end
        if view.race then parts[#parts + 1] = view.race end
        if view.class then parts[#parts + 1] = view.class end
        if #parts > 0 then
            line = line .. "  " .. table.concat(parts, " ")
        end
        if view.realm then
            line = line .. "  |c" .. COLOR_HINT .. "- " .. view.realm .. "|r"
        end
        widgets.character:SetText(line)
        for i, row in ipairs(ROWS) do
            widgets.rows[i]:SetText(RowText(row[1], row[2], payload))
        end
    else
        widgets.character:SetText("")
        for i = 1, #ROWS do
            widgets.rows[i]:SetText("")
        end
    end

    local sizeText = message or ""
    if text then
        sizeText = string.format("%s characters (%.1f KB), format %d.", Thousands(#text), #text / 1024, FORMAT_VERSION)
        if message then
            sizeText = sizeText .. " " .. message
        end
    end
    widgets.size:SetText("|c" .. COLOR_HINT .. sizeText .. "|r")

    editBox:SetText(text or "")
    frame:Show()
    if text then
        editBox:HighlightText()
        editBox:SetFocus()
    end
end

-- The new sections, lowest priority first: the order they are left out of a text
-- that is longer than the server takes (docs/addon-export-format-3.md).
local DROP_ORDER = { "classSpells", "flightPaths", "legacy", "talents", "honor", "reputation", "questLog", "recipes" }

local function Run()
    truncated = false
    local payload, reason = BuildPayload()
    if not payload then
        UI.Show(nil, nil, reason)
        return
    end
    local text, encodeReason = Encode(payload)
    if not text then
        UI.Show(nil, nil, encodeReason)
        return
    end

    local dropped = {}
    for _, name in ipairs(DROP_ORDER) do
        if #text <= MAX_EXPORT_LENGTH then
            break
        end
        payload.sections[name] = Missing("too_large")
        dropped[#dropped + 1] = name
        text = Encode(payload)
        if not text then
            break
        end
    end
    if not text or #text > MAX_EXPORT_LENGTH then
        UI.Show(nil, payload, "The export is longer than wowchar takes even without the extra sections.")
        return
    end

    local message
    if #dropped > 0 then
        message = "Left out to keep it short: " .. table.concat(dropped, ", ") .. "."
    end
    if payload.truncated then
        message = (message and (message .. " ") or "") .. "Some lists were cut at their limit."
    end
    UI.Show(text, payload, message)
end

---------------------------------------------------------------------------
-- Events and command
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName and type(WowcharExportDB) ~= "table" then
            -- The client has put the saved table in WowcharExportDB by now, or left it
            -- nil (nothing saved, or SavedVariables not kept): start with an empty one.
            -- The character's record is looked up and checked when it is first needed.
            WowcharExportDB = {}
        end
    elseif event == "BANKFRAME_OPENED" then
        session.bankOpen = true
        if not InCombat() then
            ScanBank()
        end
    elseif event == "BANKFRAME_CLOSED" then
        session.bankOpen = false
        local bank, warbank = session.bankDirty, session.warbankDirty
        session.bankDirty, session.warbankDirty = false, false
        if bank and warbank then
            Say("saved the bank and the warband bank.")
        elseif warbank then
            Say("saved the warband bank.")
        elseif bank then
            Say("saved the bank.")
        end
    elseif event == "BAG_UPDATE_DELAYED" and session.bankOpen then
        -- Bank tabs can fill in just after the window opens.
        if not InCombat() then
            ScanBank()
        end
    elseif event == "TRADE_SKILL_LIST_UPDATE" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then
        Capture.ScheduleRecipes()
    elseif event == "TAXIMAP_OPENED" then
        session.taxiOpen = true
        Capture.Flights()
    elseif event == "TAXI_NODE_STATUS_CHANGED" then
        if session.taxiOpen then
            Capture.Flights()
        end
    elseif event == "TAXIMAP_CLOSED" then
        session.taxiOpen = false
    elseif event == "PLAYER_REGEN_ENABLED" then
        if session.pendingOpen then
            session.pendingOpen = false
            Run()
        end
    end
end)

-- An event name the client does not know raises an error, so each is tried alone.
for _, event in ipairs({
    "ADDON_LOADED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "BAG_UPDATE_DELAYED",
    "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
    "TAXIMAP_OPENED", "TAXIMAP_CLOSED", "TAXI_NODE_STATUS_CHANGED", "PLAYER_REGEN_ENABLED",
}) do
    pcall(events.RegisterEvent, events, event)
end

local function Command(message)
    local word = (type(message) == "string" and message or ""):lower():match("^%s*(%S*)")
    if word == "reset" then
        Cache.Reset()
        Say("cleared the saved data of this character.")
        return
    end
    -- In combat the game hides values from addons: wait until it ends.
    if InCombat() then
        session.pendingOpen = true
        Say("in combat. The export window opens when combat ends.")
        return
    end
    Run()
end

SLASH_WOWCHAR1 = "/wowchar"
SlashCmdList["WOWCHAR"] = Command
