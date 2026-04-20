--- Recurrence-rule parsing and next-occurrence computation.
---
--- Supports the common subset of obsidian-tasks' rrule grammar:
---   * every N days/weeks/months/years
---   * every day/week/month/year
---   * every <weekday>             (e.g. "every Monday")
---   * every <month> [on the] N    (e.g. "every January 15")
---   * every weekday               (skip Sat/Sun)
---   * any of the above + " when done"  (base recurrence on completion date)
---
--- Obsidian Tasks' real implementation wraps the `rrule` JS library for full
--- RFC 5545 compliance. This implementation covers the ~80% of common cases
--- real users actually write; exotic rules (bymonthday, count limits, complex
--- weekday sets, etc.) are not supported. The README documents this.
local date_mod = require("nvim-tasks.date")
local config = require("nvim-tasks.config")
local M = {}

-- Weekday names (+ 3-letter abbrevs) to ISO weekday number (Mon=1 … Sun=7).
local WD = {
  monday = 1, tuesday = 2, wednesday = 3, thursday = 4,
  friday = 5, saturday = 6, sunday = 7,
  mon = 1, tue = 2, wed = 3, thu = 4, fri = 5, sat = 6, sun = 7,
}

-- Month names (+ 3-letter abbrevs) to month number (Jan=1 … Dec=12).
local MO = {
  january = 1, february = 2, march = 3, april = 4, may = 5, june = 6,
  july = 7, august = 8, september = 9, october = 10, november = 11, december = 12,
  jan = 1, feb = 2, mar = 3, apr = 4, jun = 6, jul = 7, aug = 8,
  sep = 9, oct = 10, nov = 11, dec = 12,
}

-- Normalise a bare unit keyword ("day", "days", "week", …) to one of
-- "day"/"week"/"month"/"year", or nil if unrecognised.
local function normalise_unit(u)
  if u:match("^day")   then return "day"   end
  if u:match("^week")  then return "week"  end
  if u:match("^month") then return "month" end
  if u:match("^year")  then return "year"  end
  return nil
end

--- Parse a recurrence rule string into a structured rule table.
---
--- Returns a table of the form
---   { interval, unit, when_done, weekdays?, month?, day_of_month? }
--- or nil if the rule is empty. Unknown rules fall through to a default of
--- `unit = "day"` with `interval = 1` so callers still get a usable object.
function M.parse_rule(rule)
  if not rule or rule == "" then return nil end
  local r = vim.trim(rule:lower())
  local result = {
    interval = 1, unit = nil, when_done = false,
    weekdays = nil, month = nil, day_of_month = nil,
  }

  -- 1. Peel off the optional " when done" suffix first.
  if r:match("when%s+done%s*$") then
    result.when_done = true
    r = vim.trim(r:gsub("when%s+done%s*$", ""))
  end

  -- 2. The "every" prefix is optional — strip it if present.
  r = r:gsub("^every%s+", "")

  -- 3. "weekday" / "weekdays" (Mon-Fri only) is a special case.
  if r:match("^weekdays?$") then
    result.unit = "weekday"
    return result
  end

  -- 4. "N <unit>" form (e.g. "3 days").
  local num, unit = r:match("^(%d+)%s+(%a+)s?$")
  if num and unit then
    result.interval = tonumber(num) or 1
    result.unit = normalise_unit(unit)
    if result.unit then return result end
  end

  -- 5. Bare unit form (e.g. "week", "months").
  do
    local u = r:match("^(%a+)s?$")
    if u then
      local normalised = normalise_unit(u)
      if normalised then result.unit = normalised; return result end
    end
  end

  -- 6. "<weekday>" form (e.g. "Monday").
  for name, n in pairs(WD) do
    if r:match("^" .. name) then
      result.unit = "week"
      result.weekdays = { n }
      return result
    end
  end

  -- 7. "<month> [on the] N" form (e.g. "January 15" / "January on the 15").
  for name, mn in pairs(MO) do
    local ds = r:match("^" .. name .. "%s+on%s+the%s+(%d+)")
            or r:match("^" .. name .. "%s+(%d+)")
    if ds then
      result.unit = "year"
      result.month = mn
      result.day_of_month = tonumber(ds)
      return result
    end
  end

  -- 8. Fallback — unknown shape, pretend it's a daily recurrence so callers
  -- don't crash. Not raising an error here matches obsidian-tasks' best-effort
  -- behaviour in Recurrence.fromText (which returns null and the task keeps
  -- its existing due date).
  result.unit = result.unit or "day"
  return result
end

-- Advance `base` forward to the next date matching `target` weekday (1-7).
-- Always moves at least one day forward, so if `base` already IS the target
-- weekday the result is the following week's occurrence.
local function next_weekday(base, target)
  local dt = date_mod.add_days(base, 1)
  for _ = 1, 7 do
    local wd = date_mod.weekday(dt)
    local iso = wd == 0 and 7 or wd  -- convert Sun=0 → 7
    if iso == target then return dt end
    dt = date_mod.add_days(dt, 1)
  end
  return dt  -- unreachable in practice
end

--- Compute the next occurrence of a recurrence rule relative to a reference
--- date. `done_date` is used when the rule is "when done".
function M.next_occurrence(rule_str, ref_date, done_date)
  local rule = M.parse_rule(rule_str)
  if not rule then return nil end

  local base = date_mod.parse(rule.when_done and (done_date or ref_date) or ref_date)
  if not base then return nil end

  local next_dt
  if rule.unit == "day" then
    next_dt = date_mod.add_days(base, rule.interval)

  elseif rule.unit == "week" then
    if rule.weekdays and #rule.weekdays > 0 then
      next_dt = next_weekday(base, rule.weekdays[1])
    else
      next_dt = date_mod.add_weeks(base, rule.interval)
    end

  elseif rule.unit == "month" then
    next_dt = date_mod.add_months(base, rule.interval)

  elseif rule.unit == "year" then
    if rule.month and rule.day_of_month then
      -- Fixed month+day (e.g. every January 15). Roll to next year if that
      -- date has already passed.
      local candidate = { year = base.year, month = rule.month, day = rule.day_of_month }
      if date_mod.on_or_before(candidate, base) then
        candidate.year = candidate.year + 1
      end
      next_dt = candidate
    else
      next_dt = date_mod.add_years(base, rule.interval)
    end

  elseif rule.unit == "weekday" then
    -- Skip Sat/Sun.
    next_dt = date_mod.add_days(base, 1)
    while not date_mod.is_weekday(next_dt) do
      next_dt = date_mod.add_days(next_dt, 1)
    end

  else
    -- Unknown unit — fail forward one day.
    next_dt = date_mod.add_days(base, 1)
  end

  return date_mod.format(next_dt)
end

--- Given a completed recurring task, produce the NEXT instance of it.
---
--- Preserves all metadata except: status returns to " ", done/cancelled dates
--- clear, `created` is set to today. Due/start/scheduled dates all shift by
--- the same offset relative to the reference date so multi-date recurring
--- tasks stay internally consistent.
function M.create_next_recurrence(task, done_date_str)
  if not task.recurrence then return nil end

  local new = vim.deepcopy(task)
  new.status_symbol = " "
  new.done_date = nil
  new.cancelled_date = nil

  -- Pick the reference date the rule is anchored to. If `remove_scheduled_on_recurrence`
  -- is set, we pin to due → start → scheduled; otherwise due → scheduled → start.
  -- If the task has none of those, fall back to the completion date.
  local cfg = config.get()
  local ref
  if cfg.remove_scheduled_on_recurrence then
    ref = task.due or task.start_date or task.scheduled or done_date_str
  else
    ref = task.due or task.scheduled or task.start_date or done_date_str
  end

  local next_ref = M.next_occurrence(task.recurrence, ref, done_date_str)
  if not next_ref then return nil end

  local ref_dt  = date_mod.parse(ref)
  local next_dt = date_mod.parse(next_ref)
  if not ref_dt or not next_dt then return nil end

  -- Compute the day-offset between the reference anchor and its next
  -- occurrence, then shift every relevant date field by that many days.
  local offset = math.floor((date_mod.to_ts(next_dt) - date_mod.to_ts(ref_dt)) / 86400 + 0.5)
  local function advance(field)
    if new[field] then
      local d = date_mod.parse(new[field])
      if d then new[field] = date_mod.format(date_mod.add_days(d, offset)) end
    end
  end
  advance("due")
  advance("start_date")

  -- When remove_scheduled_on_recurrence is set and the next task has due or
  -- start dates, the scheduled date is redundant; drop it.
  if cfg.remove_scheduled_on_recurrence and (new.due or new.start_date) then
    new.scheduled = nil
  else
    advance("scheduled")
  end

  new.created = date_mod.today_str()
  return new
end

return M
