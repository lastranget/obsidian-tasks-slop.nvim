package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
_G.vim = {
  trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
  pesc = function(s) return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")) end,
  deepcopy = function(t) if type(t)~="table" then return t end local c={} for k,v in pairs(t) do c[k]=_G.vim.deepcopy(v) end return c end,
  tbl_deep_extend = function(_b,dst,src) for k,v in pairs(src or {}) do if type(v)=="table" and type(dst[k])=="table" then dst[k]=_G.vim.tbl_deep_extend(_b,dst[k],v) else dst[k]=v end end return dst end,
  list_extend = function(dst,src) for _,v in ipairs(src or {}) do table.insert(dst,v) end return dst end,
}
local task = require("nvim-tasks.task")

local literal_emoji = "⏫"  -- as stored by the editor
local byte_emoji = "\xE2\x8F\xAB"
print("literal bytes:", #literal_emoji, literal_emoji:byte(1), literal_emoji:byte(2), literal_emoji:byte(3))
print("escape bytes: ", #byte_emoji, byte_emoji:byte(1), byte_emoji:byte(2), byte_emoji:byte(3))
print("equal:", literal_emoji == byte_emoji)

local line1 = "- [ ] Task " .. literal_emoji
local line2 = "- [ ] Task " .. byte_emoji
print("\nline1 last 10 bytes:")
for i = math.max(1, #line1-9), #line1 do print("  ", i, line1:byte(i)) end
print("line2 last 10 bytes:")
for i = math.max(1, #line2-9), #line2 do print("  ", i, line2:byte(i)) end

local t1 = task.parse(line1)
print("\nparse literal:", t1 and t1.priority)
local t2 = task.parse(line2)
print("parse bytes:  ", t2 and t2.priority)

-- Test with VS16 too
local line3 = "- [ ] Task " .. literal_emoji .. "\xEF\xB8\x8F"
print("\nparse literal+VS16:", task.parse(line3).priority)
