-- A stub of the WoW API for running toawowchar/toawowchar.lua in
-- plain Lua 5.1 (no client). Usage from a test script, run from the repository
-- root:
--     local Env = dofile("test/lua/wow-env.lua")
--     Env.load()               -- loads the addon; Env.ns has its helpers
--     Env.fire("BANKFRAME_OPENED")
--     local text = Env.run()   -- what /wowchar puts in the copy box
--
-- The stub frames know only the methods in METHODS (a method the addon calls that
-- is not there raises, so a typo is found), and a key a real frame does not have
-- is nil, as in the game: `frame.TitleText` exists only when the template that
-- makes it was asked for. Templates the stub knows:
--     BasicFrameTemplateWithInset   .TitleText
--     InputScrollFrameTemplate      .EditBox, .CharCount
-- Env.slash("/toawowchar reset") types a command by its slash word (every alias).
-- Env.now is what time() answers (unix seconds; a scenario moves it to age a cache).
-- Env.missingTemplates["Name"] = true makes CreateFrame raise for that template
-- (the addon must fall back). Env.chat is every line the addon said in the chat
-- window; Env.combat is what InCombatLockdown() answers; Env.timers holds the
-- C_Timer.After callbacks (Env.useTimers() installs C_Timer, Env.flushTimers()
-- runs them).
local Env = {}

Env.editBox = nil
Env.frames = {}
Env.fontStrings = {}
Env.ns = {}
Env.chat = {}
Env.combat = false
Env.missingTemplates = {}
Env.timers = {}
Env.timerDelays = {}

local METHODS = {
    -- anything with a position
    "SetPoint", "ClearAllPoints", "SetSize", "SetWidth", "SetHeight", "SetAllPoints",
    "SetFrameStrata", "SetMovable", "EnableMouse", "SetClampedToScreen", "RegisterForDrag",
    "StartMoving", "StopMovingOrSizing", "SetBackdrop", "SetAlpha", "SetParent",
    -- text and textures
    "SetTextColor", "SetJustifyH", "SetJustifyV", "SetFontObject", "SetColorTexture",
    "SetWordWrap",
    -- edit boxes and scroll frames
    "SetMultiLine", "SetAutoFocus", "SetMaxLetters", "SetMaxBytes", "SetScrollChild",
    "ClearFocus", "SetFocus", "HighlightText", "SetCursorPosition",
    -- buttons
    "Enable", "Disable", "RegisterForClicks",
    -- events
    "RegisterEvent", "UnregisterEvent",
}
local noop = {}
for _, name in ipairs(METHODS) do noop[name] = true end

local frameMethods = {}
local fontMethods = {}

local function fire(self, name, ...)
    if self.scripts[name] then self.scripts[name](self, ...) end
    for _, hook in ipairs(self.hooks[name] or {}) do hook(self, ...) end
end

local function newObject(kind, name, parent)
    local object = { kind = kind, name = name, parent = parent, scripts = {}, hooks = {}, shown = false, points = {} }
    return object
end

local function newFontString(parent)
    local f = newObject("FontString", nil, parent)
    f.shown = true
    Env.fontStrings[#Env.fontStrings + 1] = f
    return setmetatable(f, { __index = function(_, key)
        if fontMethods[key] then return fontMethods[key] end
        if noop[key] then return function(self) return self end end
        return nil
    end })
end

local function newTexture(parent)
    local t = newObject("Texture", nil, parent)
    t.shown = true
    return setmetatable(t, { __index = function(_, key)
        if key == "SetColorTexture" then return function(self, r, g, b, a) self.color = { r, g, b, a } end end
        if key == "Hide" then return function(self) self.shown = false end end
        if key == "Show" then return function(self) self.shown = true end end
        if key == "SetPoint" then return function(self, ...) self.points[#self.points + 1] = { ... } end end
        if noop[key] then return function(self) return self end end
        return nil
    end })
end

fontMethods.SetText = function(self, text) self.text = text end
fontMethods.GetText = function(self) return self.text or "" end
fontMethods.SetPoint = function(self, ...) self.points[#self.points + 1] = { ... } end
fontMethods.SetTextColor = function(self, r, g, b) self.color = { r, g, b } end
fontMethods.Hide = function(self) self.shown = false end
fontMethods.Show = function(self) self.shown = true end

frameMethods.SetScript = function(self, name, fn) self.scripts[name] = fn end
frameMethods.GetScript = function(self, name) return self.scripts[name] end
frameMethods.HookScript = function(self, name, fn)
    self.hooks[name] = self.hooks[name] or {}
    table.insert(self.hooks[name], fn)
end
frameMethods.SetText = function(self, text)
    self.text = text
    if self.kind == "EditBox" then fire(self, "OnTextChanged", false) end
end
frameMethods.GetText = function(self) return self.text or "" end
frameMethods.SetPoint = function(self, ...) self.points[#self.points + 1] = { ... } end
frameMethods.SetSize = function(self, w, h) self.width, self.height = w, h end
frameMethods.SetWidth = function(self, w) self.width = w end
frameMethods.SetHeight = function(self, h) self.height = h end
frameMethods.Show = function(self)
    self.shown = true
    fire(self, "OnShow")
end
frameMethods.Hide = function(self)
    if self.shown then
        self.shown = false
        fire(self, "OnHide")
    end
end
frameMethods.IsShown = function(self) return self.shown end
frameMethods.SetFocus = function(self) self.focused = true end
frameMethods.ClearFocus = function(self) self.focused = false end
frameMethods.HighlightText = function(self) self.highlighted = true end
frameMethods.SetMaxLetters = function(self, n) self.maxLetters = n end
frameMethods.SetMaxBytes = function(self, n) self.maxBytes = n end
frameMethods.GetFrameStrata = function(self) return self.strata end
frameMethods.SetFrameStrata = function(self, s) self.strata = s end
frameMethods.SetMovable = function(self, v) self.movable = v end
frameMethods.RegisterForDrag = function(self, ...) self.drag = { ... } end
frameMethods.StartMoving = function(self) self.moving = true end
frameMethods.StopMovingOrSizing = function(self) self.moving = false end
frameMethods.SetClampedToScreen = function(self, v) self.clamped = v end
frameMethods.SetBackdrop = function(self, t) self.backdrop = t end
frameMethods.SetFontObject = function(self, o) self.fontObject = o end
frameMethods.CreateFontString = function(self) return newFontString(self) end
frameMethods.CreateTexture = function(self) return newTexture(self) end
frameMethods.RegisterEvent = function(self, event)
    self.events = self.events or {}
    self.events[event] = true
end

local frameMeta = {
    __index = function(self, key)
        if frameMethods[key] then return frameMethods[key] end
        if noop[key] then return function(s) return s end end
        return nil
    end,
}

local function newFrame(kind, name, parent, template)
    local f = setmetatable(newObject(kind, name, parent), frameMeta)
    f.template = template
    if kind == "EditBox" then
        Env.editBox = f
    end
    Env.frames[#Env.frames + 1] = f
    return f
end

local KNOWN_TEMPLATES = {
    BasicFrameTemplateWithInset = true, InputScrollFrameTemplate = true, UIPanelButtonTemplate = true,
    BackdropTemplate = true, UIPanelScrollFrameTemplate = true,
}

function CreateFrame(kind, name, parent, template)
    if template then
        if Env.missingTemplates[template] or not KNOWN_TEMPLATES[template] then
            error("Couldn't find inherited node \"" .. tostring(template) .. "\"", 2)
        end
    end
    local f = newFrame(kind, name, parent, template)
    if template == "BasicFrameTemplateWithInset" then
        f.TitleText = newFontString(f)
        f.InsetBg = newTexture(f)
    elseif template == "InputScrollFrameTemplate" then
        f.EditBox = newFrame("EditBox", name and (name .. "EditBox") or nil, f)
        f.CharCount = newFontString(f)
    end
    return f
end

UIParent = CreateFrame("Frame")
UISpecialFrames = {}
tinsert = table.insert
SlashCmdList = {}
ChatFontNormal = {}
Env.now = 1792000000
time = function() return Env.now end
InCombatLockdown = function() return Env.combat end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, line) Env.chat[#Env.chat + 1] = line end }

-- Identity and client, the same in every scenario unless a script changes them.
UnitName = function() return "Thor" end
UnitClass = function() return "Warrior", "WARRIOR", 1 end
UnitRace = function() return "Night Elf", "NightElf", 4 end
UnitFactionGroup = function() return "Alliance", "Alliance" end
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

-- Sends an event to every frame that has an OnEvent script (and, like the game,
-- only to frames that registered for it: the addon's own frame does).
function Env.fire(event, ...)
    for _, f in ipairs(Env.frames) do
        if f.scripts.OnEvent and (f.events == nil or f.events[event]) then
            f.scripts.OnEvent(f, event, ...)
        end
    end
end

-- Loads the addon. The second argument stands in for the addon's namespace table
-- the client passes (the addon puts its helpers in it).
function Env.load()
    local chunk = assert(loadfile("toawowchar/toawowchar.lua"))
    chunk("toawowchar", Env.ns)
end

-- C_Timer.After for the debounce: callbacks wait in Env.timers until flushTimers().
-- Env.timerDelays[i] is the delay C_Timer.After was given for Env.timers[i].
function Env.useTimers()
    C_Timer = { After = function(delay, fn)
        Env.timers[#Env.timers + 1] = fn
        Env.timerDelays[#Env.timers] = delay
    end }
end

function Env.flushTimers()
    local run = Env.timers
    Env.timers = {}
    Env.timerDelays = {}
    for _, fn in ipairs(run) do fn() end
end

-- Containers. `world` is { slots = {[bag] = n}, items = {[bag] = {[slot] = itemId}},
-- bankBags = {[bag] = true} (readable only while world.open), enum = the table
-- for Enum.BagIndex, onInfo = optional function(bag, slot) called on every
-- slot read }. Bank bags answer nil for every slot while the bank is closed,
-- like the game does.
function Env.installContainers(world)
    Enum = Enum or {}
    Enum.BagIndex = world.enum or {}
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

-- A new play session: the addon is loaded again with the same saved variable
-- (toawowcharDB stays as it is), no frame of the first session hears events
-- any more, and the chat and window texts start empty. Call Env.load() after it.
function Env.relog()
    Env.frames = { UIParent }
    Env.fontStrings = {}
    Env.chat = {}
    Env.editBox = nil
    Env.timers = {}
    Env.timerDelays = {}
    Env.ns = {}
    SlashCmdList = {}
    UISpecialFrames = {}
end

-- Types a slash command the way the game does: "/toawowchar reset" runs the handler
-- of the SlashCmdList entry whose SLASH_<NAME>1, SLASH_<NAME>2, ... holds "/toawowchar".
-- Returns true when some command answered to that word.
function Env.slash(line)
    local word, rest = line:match("^(%S+)%s*(.*)$")
    for name, handler in pairs(SlashCmdList) do
        local n = 1
        while _G["SLASH_" .. name .. n] do
            if _G["SLASH_" .. name .. n]:lower() == word:lower() then
                handler(rest)
                return true
            end
            n = n + 1
        end
    end
    return false
end

-- Types /wowchar and returns the text now in the copy box.
function Env.run(arguments)
    SlashCmdList["WOWCHAR"](arguments)
    assert(Env.editBox, "the window was not made")
    return Env.editBox.text
end

-- What a player typing into the text box does: the text changes with userInput = true.
function Env.type(box, text)
    box.text = text
    fire(box, "OnTextChanged", true)
end

-- The words of the window: every font string's text in creation order.
function Env.windowText()
    local lines = {}
    for _, f in ipairs(Env.fontStrings) do
        if f.text and f.text ~= "" then lines[#lines + 1] = f.text end
    end
    return lines
end

-- The frame the addon made (by its global name), or nil.
function Env.frameNamed(name)
    for _, f in ipairs(Env.frames) do
        if f.name == name then return f end
    end
    return nil
end

return Env
