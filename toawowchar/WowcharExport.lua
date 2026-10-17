-- WowcharExport 0.1.0
--
-- Type /wowchar to open a window with a text string (equipped items, bags,
-- the bank if you opened it, professions, and who the character is). Copy it
-- (Ctrl+C) and paste it on the character's BiS page at wowchar, which ticks off
-- the BiS items you already have. The addon sends nothing anywhere, saves
-- nothing to disk (no SavedVariables) and does nothing until you type /wowchar,
-- apart from remembering what is in the bank while you have it open.
--
-- The text format is decoded by wowchar's server/utils/addon-export.ts. That
-- file and the table built in BuildPayload() below belong together: change one,
-- change the other.

local ADDON_VERSION = "0.1.0"
local FORMAT_VERSION = 1
local PREFIX = "WOWCHAR:" .. FORMAT_VERSION .. ":"

-- The server refuses an array longer than 500 (MAX_IDS_PER_ARRAY in
-- addon-export.ts); the lists here are cut at the same number.
local MAX_IDS = 500
local MAX_PROFESSIONS = 32
local LAST_EQUIPMENT_SLOT = 19

-- What was seen in the bank, kept in memory only and lost at logout/reload.
local bankItems = {}
local bankSeen = false
local bankOpen = false

-- Set when a list had to be cut at MAX_IDS, so the window and the export can say
-- so. AddId sets `truncated` while a list is being collected. Run() resets it
-- before the bags are read; the bank is scanned earlier (when it opens), so its
-- result is kept apart in `bankTruncated` and combined in BuildPayload.
local truncated = false
local bankTruncated = false

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

-- Adds the item ids of one container to a list.
local function ScanContainer(bag, list, seen)
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
        end
    end
    return true
end

local function CollectEquipped()
    local equipped = {}
    for slot = 1, LAST_EQUIPMENT_SLOT do
        local itemId = GetInventoryItemID("player", slot)
        if itemId and #equipped < MAX_IDS then
            equipped[#equipped + 1] = {
                slot = slot,
                itemId = itemId,
                link = GetInventoryItemLink("player", slot), -- nil leaves the key out
            }
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

-- Reads the character bank tabs. Only works while the bank is open, so it runs
-- on BANKFRAME_OPENED and the result is kept in memory.
local function ScanBank()
    if not (Enum and Enum.BagIndex) then
        return
    end
    local list, seen = {}, {}
    local foundTab = false
    local previous = truncated
    truncated = false
    for tab = 1, 9 do
        local bag = Enum.BagIndex["CharacterBankTab_" .. tab]
        if bag ~= nil and ScanContainer(bag, list, seen) then
            foundTab = true
        end
    end
    local cut = truncated
    truncated = previous
    -- Without a single readable tab nothing was seen, so do not claim it.
    if foundTab then
        bankItems = list
        bankSeen = true
        bankTruncated = cut
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
    local region = GetCurrentRegionName and GetCurrentRegionName()
    if not name or name == "" then
        return nil, "Could not read the character's name."
    end
    if not region or region == "" then
        return nil, "Could not read the region."
    end

    local _, classFile, classId = UnitClass("player")
    local _, build, _, interface = GetBuildInfo()
    local specId, specName = CollectSpec()

    -- Nothing is sent as bank contents unless the bank was open this session.
    local bank = {}
    if bankSeen then
        for i = 1, #bankItems do
            bank[i] = bankItems[i]
        end
    end

    -- Bags are read now; the bank list was cut at the time it was scanned.
    local bags = CollectBags()
    local equipped = CollectEquipped()
    local cut = truncated or (bankSeen and bankTruncated)

    return {
        format = FORMAT_VERSION,
        addonVersion = ADDON_VERSION,
        client = { build = build, interface = interface },
        capturedAt = time(),
        identity = {
            name = name,
            region = region,
            realm = GetRealmName and GetRealmName() or nil,
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
        truncated = cut or nil, -- true only when a list was cut; nil leaves the key out
        professions = CollectProfessions(),
        completedQuestIds = {}, -- reserved, not filled in this version
    }
end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------

-- UNVERIFIED ON A REAL CLIENT (launch checklist item 12 in wowchar's
-- docs/forever-addon-research.md): that this chain exists on Forever, what
-- SerializeJSON writes (an empty list may come out as {} or []), whether
-- Deflate means raw deflate, zlib or gzip, and which base64 alphabet is used.
-- The server's addon-export.ts (COMPRESSION and the checks) must change with it.
local function Encode(payload)
    local encoding = C_EncodingUtil
    if not (encoding and encoding.SerializeJSON and encoding.CompressString and encoding.EncodeBase64
        and Enum and Enum.CompressionMethod and Enum.CompressionMethod.Deflate ~= nil) then
        return nil, "This game client has no C_EncodingUtil, so the export cannot be made."
    end
    local ok, result = pcall(function()
        local json = encoding.SerializeJSON(payload)
        local packed = encoding.CompressString(json, Enum.CompressionMethod.Deflate)
        return PREFIX .. encoding.EncodeBase64(packed)
    end)
    if not ok or type(result) ~= "string" then
        return nil, "The export could not be encoded."
    end
    return result
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

    local message = "Press Ctrl+C to copy, then paste it on this character's BiS page at wowchar."
    if not bankSeen then
        message = message .. " The bank was not opened this session, so bank items are not included."
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
