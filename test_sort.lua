-- Targeted unit tests for newly-added sort behaviors.
package.path = "/home/claude/work/nvim-tasks-fixed/lua/?.lua;" .. package.path

-- Stub vim for Lua 5.1.
_G.vim = _G.vim or {}
vim.trim = function(s) return s:match("^%s*(.-)%s*$") end
vim.deepcopy = function(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = vim.deepcopy(v) end
  return c
end
vim.fn = vim.fn or {}
vim.fn.fnamemodify = function(p, mod) return p end
vim.split = function(s, sep, opts)
  local r = {}
  local pat = opts and opts.plain and sep or sep
  for part in (s .. sep):gmatch("(.-)" .. sep) do table.insert(r, part) end
  return r
end

local sort = require("nvim-tasks.sort")

local passed, failed = 0, 0
local function check(name, got, want)
  if got == want then passed = passed + 1
  else failed = failed + 1; print(("FAIL %s\n  got:  %q\n  want: %q"):format(name, tostring(got), tostring(want))) end
end

-- Description cleaning
check("plain",              sort._clean_description("Plain"),               "plain")
check("**bold** at start",  sort._clean_description("**Bold** rest"),       "bold rest")
check("*italic* at start",  sort._clean_description("*Italic* rest"),       "italic rest")
check("==highlight== at start", sort._clean_description("==Hi== rest"),     "hi rest")
check("__bold__ at start",  sort._clean_description("__B__ rest"),          "b rest")
check("_italic_ at start",  sort._clean_description("_I_ rest"),            "i rest")
check("[[link]] at start",  sort._clean_description("[[Foo]] rest"),        "foo rest")
check("[[link|alias]]",     sort._clean_description("[[Target|Vis]] rest"), "vis rest")
-- Without leading markdown, unchanged
check("no leading",         sort._clean_description("just plain"),          "just plain")

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
