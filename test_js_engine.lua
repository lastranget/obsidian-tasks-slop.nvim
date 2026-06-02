-- End-to-end test of the real JS engine round-trip (Lua → engine → Lua).
--
-- Requires Neovim (uses vim.fn.system + vim.json) and an installed engine.
-- Run:  nvim -l test_js_engine.lua
-- If no engine is found it prints SKIP and exits 0, so it is safe in CI without
-- a JS runtime. Only js.lua is exercised (no vault/plenary/bit dependency).

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local js = require("nvim-tasks.js")
local config = require("nvim-tasks.config")
config.setup({ vault_paths = { vim.fn.getcwd() } })

if not js.available() then
  print("SKIP: no JS engine found. Install Deno (recommended) and re-run.")
  print("      auto-detect order: deno > bun > node; or set js_engine in setup().")
  return
end

print("engine: " .. js.engine().name .. "  harness: " .. js.harness_path())

local passed, failed = 0, 0
local function check(name, got, want)
  if got == want then passed = passed + 1; print("PASS " .. name)
  else failed = failed + 1; print(("FAIL %s: got %s want %s"):format(name, tostring(got), tostring(want))) end
end

local function task(o)
  local t = {
    raw = "- [ ] x", indent = "", list_marker = "- ", status_symbol = " ",
    description = "", tags = {}, depends_on = {}, priority = nil,
    due = nil, scheduled = nil, start_date = nil, created = nil,
    done_date = nil, cancelled_date = nil, recurrence = nil, id = nil,
    file_path = vim.fn.getcwd() .. "/Work/plan.md", line_number = 0, preceding_header = nil,
  }
  for k, v in pairs(o or {}) do t[k] = v end
  return t
end

local tasks = {
  task{ description = "a", tags = { "#x", "#y" }, priority = "high", due = "2026-06-15", status_symbol = " " },
  task{ description = "b", tags = { "#x" }, priority = "low", status_symbol = "x" },
}

local instructions = {
  { id = 1, kind = "filter", expr = "task.tags.length > 1" },
  { id = 2, kind = "sort",   expr = "task.priorityNumber" },
  { id = 3, kind = "group",  expr = "task.status.type" },
  { id = 4, kind = "group",  expr = "task.due.format('YYYY-MM-DD', 'none')" },
}

local results, errors = js.evaluate(instructions, tasks, { file_path = vim.fn.getcwd() .. "/Dashboard.md" })

if not results then
  print("FAIL: js.evaluate returned no results: " .. (errors and errors._engine or "?"))
  os.exit(1)
end

check("filter tags.length>1 [1]", results[1][1], true)
check("filter tags.length>1 [2]", results[1][2], false)
check("sort priorityNumber [1] (high=1)", results[2][1], 1)
check("sort priorityNumber [2] (low=4)", results[2][2], 4)
check("group status.type [1]", results[3][1][1], "TODO")
check("group status.type [2]", results[3][2][1], "DONE")
check("group due.format [1]", results[4][1][1], "2026-06-15")
check("group due.format [2] fallback", results[4][2][1], "none")

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
