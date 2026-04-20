-- Unit tests for recurrence.lua.
-- Covers parse_rule and next_occurrence against a fixed reference date.
package.path = "/home/claude/work/nvim-tasks-fixed/lua/?.lua;" .. package.path

_G.vim = _G.vim or {}
vim.trim = function(s) return s:match("^%s*(.-)%s*$") end
vim.deepcopy = function(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = vim.deepcopy(v) end
  return c
end

-- Stub config so require chain works without Neovim APIs.
package.loaded["nvim-tasks.config"] = {
  get = function() return { remove_scheduled_on_recurrence = false } end,
}

local R = require("nvim-tasks.recurrence")

local passed, failed = 0, 0
local function check(name, got, want)
  if got == want then passed = passed + 1
  else failed = failed + 1; print(("FAIL %s\n  got:  %q\n  want: %q"):format(name, tostring(got), tostring(want))) end
end

-- parse_rule ----------------------------------------------------------------
local r

r = R.parse_rule("every day")
check("every day: unit",     r.unit,     "day")
check("every day: interval", r.interval, 1)

r = R.parse_rule("every 3 days")
check("every 3 days: interval", r.interval, 3)
check("every 3 days: unit",     r.unit,     "day")

r = R.parse_rule("every week")
check("every week: unit", r.unit, "week")

r = R.parse_rule("every Monday")
check("every Monday: unit",     r.unit,     "week")
check("every Monday: weekday",  r.weekdays[1], 1)

r = R.parse_rule("every January 15")
check("every January 15: unit",  r.unit,         "year")
check("every January 15: month", r.month,        1)
check("every January 15: day",   r.day_of_month, 15)

r = R.parse_rule("every weekday")
check("every weekday: unit", r.unit, "weekday")

r = R.parse_rule("every month when done")
check("when done: unit",       r.unit,      "month")
check("when done: when_done",  r.when_done, true)

check("empty rule",      R.parse_rule(""),   nil)
check("nil rule",        R.parse_rule(nil),  nil)

-- next_occurrence against a fixed reference date --------------------------
check("every day from 2026-04-20",
  R.next_occurrence("every day", "2026-04-20"),
  "2026-04-21")

check("every 3 days from 2026-04-20",
  R.next_occurrence("every 3 days", "2026-04-20"),
  "2026-04-23")

check("every week from 2026-04-20",
  R.next_occurrence("every week", "2026-04-20"),
  "2026-04-27")

check("every month from 2026-04-20",
  R.next_occurrence("every month", "2026-04-20"),
  "2026-05-20")

check("every year from 2026-04-20",
  R.next_occurrence("every year", "2026-04-20"),
  "2027-04-20")

-- 2026-04-20 is a Monday. "Every Monday" should go to next Monday.
check("every Monday from 2026-04-20 Monday",
  R.next_occurrence("every Monday", "2026-04-20"),
  "2026-04-27")

-- From Monday, "every Wednesday" should jump to Wednesday of the same week.
check("every Wednesday from 2026-04-20 Monday",
  R.next_occurrence("every Wednesday", "2026-04-20"),
  "2026-04-22")

-- Weekday recurrence: from Friday, next weekday is Monday (skip Sat/Sun).
-- 2026-04-24 is a Friday.
check("every weekday from Friday",
  R.next_occurrence("every weekday", "2026-04-24"),
  "2026-04-27")

-- Yearly with month+day: from 2026-04-20, "every January 15" → 2027-01-15.
check("every January 15 from 2026-04-20",
  R.next_occurrence("every January 15", "2026-04-20"),
  "2027-01-15")

-- Yearly with month+day where the day hasn't yet passed in this year.
-- From 2026-04-20, "every December 15" → same year (2026-12-15).
check("every December 15 from 2026-04-20",
  R.next_occurrence("every December 15", "2026-04-20"),
  "2026-12-15")

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
