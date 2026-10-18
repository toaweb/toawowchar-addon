-- WowcharExport 0.3.0
--
-- Type /wowchar to open a window with a text string (equipped items, bags,
-- the bank and the warband bank if you opened the bank, professions, and who
-- the character is). Copy it
-- (Ctrl+C) and paste it at wowchar: on «My characters» to add the character, or
-- on the character's BiS page to mark the BiS items you already have as
-- obtained. The addon sends nothing anywhere, saves nothing to disk (no
-- SavedVariables) and does nothing until you type /wowchar, apart from
-- remembering what is in the bank while you have it open.
--
-- The text is "WOWCHAR:2:" followed by plain JSON, written by the small
-- serializer below (format 2). No C_EncodingUtil, no compression, no base64.
-- It is decoded by wowchar's server/utils/addon-export.ts. That file and the
-- table built in BuildPayload() below belong together: change one, change the
-- other.
--
-- Region: identity.region is "US", "KR", "EU", "TW" or "CN", from
-- GetCurrentRegion() (1 to 5). Any other value (the Forever test client reports
-- 110) leaves region out and sends identity.regionId (the number) and
-- identity.portal (the "portal" setting) instead; wowchar then does not compare
-- regions. GetCurrentRegionName() is not used: it errors on the Forever test
-- client. Every call below is guarded, so a missing function is never an error.

-- Tests load this file with a private table as the second argument (the client
-- passes one too: the addon's own namespace) and read the helpers from it.
local _, ns = ...

local ADDON_VERSION = "0.3.0"
local FORMAT_VERSION = 2
local PREFIX = "WOWCHAR:" .. FORMAT_VERSION .. ":"

-- The server refuses an array longer than 500 (MAX_IDS_PER_ARRAY in
-- addon-export.ts); the lists here are cut at the same number.
local MAX_IDS = 500
local MAX_PROFESSIONS = 32
local LAST_EQUIPMENT_SLOT = 19
-- The server refuses more than 32 bonus ids on one item (MAX_BONUS_IDS_PER_ITEM)
-- and more than 4 gems; the lists here are cut at the same numbers.
local MAX_BONUS_IDS = 32
local MAX_GEMS = 4
-- Item ids, enchant ids and so on are whole numbers that fit a 32-bit signed
-- integer (the server's MAX_ITEM_ID); anything else in an item string is ignored.
local MAX_ID = 2147483647

-- What was seen in the bank and the warband bank, kept in memory only and lost
-- at logout/reload.
local bankItems = {}
local bankSeen = false
local bankSource = nil -- "tabs" or "classic": which kind of bank was read
local bankOpen = false
local warbankItems = {}
local warbankSeen = false

-- Set when a list had to be cut at MAX_IDS, so the window and the export can say
-- so. AddId sets `truncated` while a list is being collected. Run() resets it
-- before the bags are read; the bank is scanned earlier (when it opens), so its
-- result is kept apart in `bankTruncated` and combined in BuildPayload.
local truncated = false
local bankTruncated = false
local warbankTruncated = false

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

-- The bank guard. A bank scan only counts if the bank was still open when it
-- ended: the last slot that had an item must still show an item, and the bank
-- must not have been closed (BANKFRAME_CLOSED). When the bank closes during a
-- scan, the game returns nothing for its slots, so the scan would be partial
-- and must not replace the list from the last full scan.
local function BankStillOpen(last)
    if not bankOpen or not last.bag then
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
-- result is kept in memory.
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
    if source and BankStillOpen(last) then
        bankItems = list
        bankSeen = true
        bankSource = source
        bankTruncated = cut
    end
    if wsource and BankStillOpen(wlast) then
        warbankItems = wlist
        warbankSeen = true
        warbankTruncated = wcut
    end
end

local function CollectProfessions()
    local result = {}
    if not (GetProfessions and GetProfessionInfo) then
        return result
    end
    -- GetProfessions returns up to six indexes and nil for an empty slot, so
    -- they go in a table and are read by position, not with #.
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
    return result
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
    if GetRealmName then
        local ok, value = pcall(GetRealmName)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    return nil
end

local function IsHardcore()
    if C_GameRules and C_GameRules.IsHardcoreActive then
        local ok, value = pcall(C_GameRules.IsHardcoreActive)
        return ok and value and true or false
    end
    return false
end

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

    -- Nothing is sent as bank contents unless the bank was read this session.
    local bank = {}
    if bankSeen then
        for i = 1, #bankItems do
            bank[i] = bankItems[i]
        end
    end
    local warbank = {}
    if warbankSeen then
        for i = 1, #warbankItems do
            warbank[i] = warbankItems[i]
        end
    end

    -- Bags are read now; the bank lists were cut at the time they were scanned.
    local bags = CollectBags()
    local equipped = CollectEquipped()
    local cut = truncated or (bankSeen and bankTruncated) or (warbankSeen and warbankTruncated)

    return {
        format = FORMAT_VERSION,
        addonVersion = ADDON_VERSION,
        client = { build = build, interface = interface },
        capturedAt = time(),
        identity = {
            name = name,
            region = region, -- nil leaves the key out
            regionId = regionId,
            portal = portal,
            realm = CollectRealm(), -- nil leaves the key out
            guid = UnitGUID("player"),
            classFile = classFile,
            classID = classId,
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
        professions = CollectProfessions(),
        completedQuestIds = {}, -- reserved, not filled in this version
    }
end

---------------------------------------------------------------------------
-- Encoding: plain JSON, written here
---------------------------------------------------------------------------

-- The text of an export is "WOWCHAR:2:" and then one JSON value. The writer
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
local MAX_DEPTH = 8

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
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local frame, messageText, editBox, currentText

local function CreateWindow()
    local created, f = pcall(CreateFrame, "Frame", "WowcharExportFrame", UIParent, "BackdropTemplate")
    if not created then
        f = CreateFrame("Frame", "WowcharExportFrame", UIParent)
    end
    f:SetSize(580, 300)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
    end

    -- Escape closes the window.
    tinsert(UISpecialFrames, "WowcharExportFrame")

    local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Wowchar Export")

    messageText = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    messageText:SetPoint("TOPLEFT", 20, -42)
    messageText:SetPoint("TOPRIGHT", -20, -42)
    messageText:SetJustifyH("LEFT")
    messageText:SetHeight(32)

    local scroll = CreateFrame("ScrollFrame", "WowcharExportScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 20, -80)
    scroll:SetPoint("BOTTOMRIGHT", -40, 48)

    editBox = CreateFrame("EditBox", "WowcharExportEditBox", scroll)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(500)
    editBox:SetMaxLetters(0)
    editBox:SetMaxBytes(0)
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        f:Hide()
    end)
    -- The text is for copying: typing in the box puts the original back.
    editBox:SetScript("OnTextChanged", function(self, userInput)
        if userInput and currentText and self:GetText() ~= currentText then
            self:SetText(currentText)
            self:HighlightText()
        end
    end)
    scroll:SetScrollChild(editBox)

    local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    close:SetSize(100, 24)
    close:SetPoint("BOTTOM", 0, 16)
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

-- Shows the window with either the export text or an error message.
local function ShowWindow(text, message)
    if not frame then
        frame = CreateWindow()
    end
    currentText = text
    messageText:SetText(message or "")
    editBox:SetText(text or "")
    frame:Show()
    if text then
        editBox:HighlightText()
        editBox:SetFocus()
    end
end

local function Run()
    truncated = false
    local payload, reason = BuildPayload()
    if not payload then
        ShowWindow(nil, reason)
        return
    end
    local text, encodeReason = Encode(payload)
    if not text then
        ShowWindow(nil, encodeReason)
        return
    end

    local message = "Press Ctrl+C to copy, then paste it at wowchar (My characters, or this character's BiS page)."
    if not bankSeen then
        message = message .. " The bank was not read this session (open it first), so bank items are not included."
    end
    if payload.truncated then
        message = message .. " Some items were left out: a list was longer than " .. MAX_IDS .. " items."
    end
    ShowWindow(text, message)
end

---------------------------------------------------------------------------
-- Events and command
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event)
    if event == "BANKFRAME_OPENED" then
        bankOpen = true
        ScanBank()
    elseif event == "BANKFRAME_CLOSED" then
        bankOpen = false
    elseif event == "BAG_UPDATE_DELAYED" and bankOpen then
        -- Bank tabs can fill in just after the window opens.
        ScanBank()
    end
end)

-- An event name the client does not know raises an error, so each is tried alone.
for _, event in ipairs({ "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "BAG_UPDATE_DELAYED" }) do
    pcall(events.RegisterEvent, events, event)
end

SLASH_WOWCHAR1 = "/wowchar"
SlashCmdList["WOWCHAR"] = Run
