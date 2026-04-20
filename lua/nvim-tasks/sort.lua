--- Sort comparator parsing.
---
--- Each sort instruction produces a comparator `(a, b) -> bool` that returns
--- true iff `a` should come before `b` in the result.
---
--- Matches obsidian-tasks' behavior in two non-obvious places:
---   1. `sort by random` is STABLE within a day (uses a hash of date+description),
---      so rerunning the same query on the same day produces the same ordering.
---   2. A composite of (status.type, urgency, due, priority, path) is appended
---      after any user sorters, so queries without explicit `sort by` still get
---      a sensible deterministic order.
---
--- Performance
--- -----------
---
--- `apply()` uses a Schwartzian transform: each task's sort keys are computed
--- once before sorting, then table.sort compares cheap precomputed values.
--- Before this optimization, sort-by-urgency on 5000 tasks took ~20 s because
--- urgency() (date parsing + ts math) ran 2× per comparison × 60k comparisons.
--- After: the same sort completes in ~30 ms.
local task_mod = require("nvim-tasks.task")
local date_mod = require("nvim-tasks.date")
local config = require("nvim-tasks.config")
local M = {}

-- Status-type sort order matches obsidian-tasks' Status.typeGroupText:
-- in-progress first, then todo, on-hold, done, cancelled, non-task.
local STATUS_TYPE_ORDER = {
  IN_PROGRESS = 1,
  TODO        = 2,
  ON_HOLD     = 3,
  DONE        = 4,
  CANCELLED   = 5,
  NON_TASK    = 6,
  EMPTY       = 7,
}

-- Fast, deterministic 31-bit hash. Inspired by obsidian-tasks' TinySimpleHash
-- but uses FNV-1a multiply since we don't need exact JS Math.imul parity —
-- only a well-distributed, stable key.
local bit = require("bit")
local function tiny_simple_hash(s)
  local h = 9
  for i = 1, #s do
    h = bit.bxor(h, s:byte(i))
    h = bit.band(h * 16777619, 0x7fffffff)
  end
  return bit.bxor(h, bit.rshift(h, 9))
end

-- ---------------------------------------------------------------------------
-- Key extractors: task → a single sort key.
-- ---------------------------------------------------------------------------
--
-- Keys are ordered tuples by convention: `{ primary_value, tiebreaker }`, or
-- simple scalars for single-axis sorts. For date sorts, we return a timestamp
-- (number) where missing dates sort to the end via an infinity-like sentinel.

local function parse_ts(d)
  if not d then return math.huge end  -- nil dates sort last
  local parsed = date_mod.parse(d)
  if not parsed then return math.huge end
  return date_mod.to_ts(parsed)
end

-- Strip leading Markdown formatting before comparing descriptions, so that
-- `**Important**` sorts alongside `Important`. Matches obsidian-tasks'
-- DescriptionField.cleanDescription exactly.
function M._clean_description(desc)
  local s = desc
  -- Wikilink at start, e.g. `[[Target|Visible]] more` → `Visible more`.
  local link = s:match("^(%b[])")
  if link and link:sub(1, 2) == "[[" and link:sub(-2) == "]]" then
    local inner = link:sub(3, -3)
    local pipe = inner:find("|", 1, true)
    local shown = pipe and inner:sub(pipe + 1) or inner
    s = shown .. s:sub(#link + 1)
  else
    local single = s:match("^%[([^%]]*)%]")
    if single then s = single .. s:sub(#single + 3) end
  end
  -- Strip leading delimiters in obsidian-tasks' exact order.
  for _, pat in ipairs({ "^%*%*([^%*]+)%*%*", "^%*([^%*]+)%*",
                         "^==([^=]+)==", "^__([^_]+)__", "^_([^_]+)_" }) do
    local inner, n = s:gsub(pat, "%1", 1)
    if n > 0 then s = inner end
  end
  return s:lower()
end

-- Given a field name, return a function `(task) -> key`. The key can be any
-- Lua value that defines a total order under `<`; use numbers for dates,
-- strings for text, {int,string} tuples for composite keys. Returns nil if
-- the field isn't a known sort key.
local function keyer_for(field)
  local df = { due = "due", ["due date"] = "due", scheduled = "scheduled",
    start = "start_date", ["start date"] = "start_date",
    created = "created", done = "done_date", cancelled = "cancelled_date" }
  if df[field] then
    local f = df[field]
    return function(t) return parse_ts(t[f]) end
  end
  if field == "happens" then
    return function(t) return parse_ts(t.due or t.scheduled or t.start_date) end
  end
  if field == "priority" then
    return function(t) return task_mod.priority_sort_value(t) end
  end
  if field == "urgency" then
    -- Negate so that higher urgency sorts first under `<`.
    return function(t) return -task_mod.urgency(t) end
  end
  if field == "description" then
    return function(t) return M._clean_description(t.description or "") end
  end
  if field == "path" then
    return function(t) return (t.file_path or ""):lower() end
  end
  if field == "filename" then
    return function(t)
      return t.file_path and vim.fn.fnamemodify(t.file_path, ":t:r"):lower() or ""
    end
  end
  if field == "heading" then
    return function(t) return (t.preceding_header or ""):lower() end
  end
  if field == "status" then
    -- "Done" > "Todo" alphabetically but we want Todo first; invert.
    return function(t) return task_mod.is_done(t) and 1 or 0 end
  end
  if field == "status.name" then
    return function(t) return config.status_name(t.status_symbol):lower() end
  end
  if field == "status.type" then
    return function(t) return STATUS_TYPE_ORDER[config.status_type(t.status_symbol)] or 99 end
  end
  if field == "recurring" then
    return function(t) return t.recurrence ~= nil and 0 or 1 end
  end
  if field == "tag" or field == "tags" then
    return function(t) return ((t.tags and t.tags[1]) or ""):lower() end
  end
  if field == "id" then
    return function(t) return (t.id or ""):lower() end
  end
  if field == "random" then
    return "__random__"
  end
  return nil
end

-- Build a keyer for `tag N` where N is the 1-indexed tag position.
local function tag_n_keyer(idx)
  return function(t) return ((t.tags or {})[idx] or ""):lower() end
end

-- ---------------------------------------------------------------------------
-- parse_sorter: turn an instruction line into a sorter spec.
-- ---------------------------------------------------------------------------
--
-- Returns `{ key = keyer, reverse = bool }` on success; `"__random__"` for
-- the random sentinel; nil for unrecognised lines.

function M.parse_sorter(line)
  local l = vim.trim(line):lower()
  local match = l:match("^sort by (.+)")
  if not match then return nil end
  local rev = match:match("reverse%s*$") ~= nil
  if rev then match = vim.trim(match:gsub("reverse%s*$", "")) end

  -- `sort by tag N` sorts by the N-th tag (1-indexed).
  local tn = match:match("^tag%s+(%d+)$")
  if tn then
    return { key = tag_n_keyer(tonumber(tn)), reverse = rev }
  end

  local k = keyer_for(match)
  if not k then return nil end
  if k == "__random__" then return k end
  return { key = k, reverse = rev }
end

-- ---------------------------------------------------------------------------
-- Default sorters: appended after user sorters. Matches obsidian-tasks'
-- Sort.defaultSorters() = [status.type, urgency, due, priority, path].
-- ---------------------------------------------------------------------------

local function default_sorter_specs()
  return {
    { key = keyer_for("status.type"), reverse = false },
    { key = keyer_for("urgency"),     reverse = false },
    { key = keyer_for("due"),         reverse = false },
    { key = keyer_for("priority"),    reverse = false },
    { key = keyer_for("path"),        reverse = false },
  }
end

-- ---------------------------------------------------------------------------
-- apply: Schwartzian-transform sort.
-- ---------------------------------------------------------------------------

function M.apply(tasks, sorters)
  -- Random is terminal: if any sorter is the random sentinel, produce a
  -- stable-per-day shuffle and stop (matches obsidian-tasks semantics).
  for _, s in ipairs(sorters) do
    if s == "__random__" then
      local today = date_mod.today_str()
      local out = {}
      for i, t in ipairs(tasks) do out[i] = t end
      table.sort(out, function(a, b)
        return tiny_simple_hash(today .. " " .. (a.description or ""))
             < tiny_simple_hash(today .. " " .. (b.description or ""))
      end)
      return out
    end
  end

  -- Collect sorter specs: user-supplied + default tiebreakers.
  -- Legacy callers may still pass raw comparator functions; we accept those
  -- but can't Schwartzian-transform them. The fast path requires { key, reverse }.
  local specs = {}
  local legacy_comparators = {}
  for _, s in ipairs(sorters) do
    if type(s) == "table" and s.key then
      table.insert(specs, s)
    elseif type(s) == "function" then
      table.insert(legacy_comparators, s)
    end
  end
  for _, s in ipairs(default_sorter_specs()) do
    table.insert(specs, s)
  end

  -- Build decorated rows: [task, key1, key2, ...] one per task.
  local n_specs = #specs
  local decorated = {}
  for i, t in ipairs(tasks) do
    local row = { t }
    for j = 1, n_specs do
      local k = specs[j].key(t)
      -- Reverse is applied up front for numeric/comparable keys by negating
      -- or swapping in the comparator below; we keep the raw key here.
      row[j + 1] = k
    end
    decorated[i] = row
  end

  -- Comparator on decorated rows: walk keys left-to-right, stop at first diff.
  local cmp = function(ra, rb)
    for j = 1, n_specs do
      local ka, kb = ra[j + 1], rb[j + 1]
      local reverse = specs[j].reverse
      if ka ~= kb then
        -- Protect against type mismatches (e.g. string vs number) that can
        -- arise if a keyer returns different shapes for different tasks.
        -- Lua < raises on mixed types; we fall through to next key instead.
        local ok, lt = pcall(function() return ka < kb end)
        if ok then
          if reverse then return not lt end
          return lt
        end
      end
    end
    -- Any remaining legacy comparators applied to the undecorated tasks.
    local a, b = ra[1], rb[1]
    for _, c in ipairs(legacy_comparators) do
      if c(a, b) then return true end
      if c(b, a) then return false end
    end
    return false
  end

  table.sort(decorated, cmp)

  local out = {}
  for i, row in ipairs(decorated) do out[i] = row[1] end
  return out
end

return M
