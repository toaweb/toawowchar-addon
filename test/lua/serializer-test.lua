-- Runs the addon's JSON writer on fixed cases and prints one line per case:
--   <label>\t<json>        or        <label>\tERROR
-- test/addon-lua.test.mjs parses each json with JSON.parse and compares. Run from the
-- repository root: lua test/lua/serializer-test.lua
local Env = dofile("test/lua/wow-env.lua")
Env.load()
local Serialize = assert(Env.ns.Serialize, "the addon did not export Serialize")

local function show(label, value)
    local ok, result = pcall(Serialize, value)
    print(label .. "\t" .. (ok and result or "ERROR"))
end

show("quote", 'say "hi"')
show("backslash", "back\\slash and \\u0041")
show("pipe", "a|cff00ff00|Hitem:1|h[x]|h|r||")
show("nonascii", "Zo\195\171 \230\151\165\230\156\172\232\170\158 \195\188")
show("control", "\0\1\8\9\10\13\27\31\127 end")
show("empty-string", "")
show("empty-list", {})
show("nested", { a = { 1, 2, { b = true, c = { 3 } } }, d = {}, e = { { x = 1 }, { y = 2 } }, f = false })
show("key-order", { b = 1, a = 2, ab = 3, B = 4 })
show("nil-value-key-left-out", { a = 1, b = nil })
show("numbers", { 0, 42, -7, 2147483647, 1.5, 0 / 0, 1 / 0, -1 / 0, 9007199254740991, 1e300 })
show("pipe-in-key", { ["a|b"] = 1 })
show("bool", true)
show("number-top", 5)

-- Same data, same text.
local data = { z = { 3, 2, 1 }, y = "x|y", a = { q = 1, p = 2 } }
print("deterministic\t" .. ((Serialize(data) == Serialize(data)) and "yes" or "no"))

-- Refused: functions, cycles, mixed keys, holes, too deep.
local cycle = {}
cycle.self = cycle
local deep = {}
local node = deep
for _ = 1, 20 do node.next = {}; node = node.next end
show("err-function", { f = print })
show("err-cycle", cycle)
show("err-mixed", { 1, 2, a = 3 })
show("err-hole", { [1] = "a", [3] = "c" })
show("err-number-key", { [1.5] = "a" })
show("err-deep", deep)
