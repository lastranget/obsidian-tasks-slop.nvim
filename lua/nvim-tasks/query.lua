--- Query parsing and execution.
---
--- A query is a list of lines from a ```tasks``` block. Each line is one
--- of: a comment (`#...`), a layout directive (`short mode`, `hide <field>`,
--- `limit N`, `explain`, `ignore global query`), a sorter (`sort by ...`),
--- a grouper (`group by ...`), or a filter. Unrecognised non-empty lines
--- produce an error entry that renders with a ⚠ prefix.
---
--- `parse_line` dispatches each already-continuated line and returns whether
--- it was handled (always true unless empty/comment — unknown instructions
--- still count as "handled" because an error has been recorded).
local filter_mod = require("nvim-tasks.filter")
local sort_mod   = require("nvim-tasks.sort")
local group_mod  = require("nvim-tasks.group")
local vault      = require("nvim-tasks.vault")
local config     = require("nvim-tasks.config")
local M = {}

-- ---------------------------------------------------------------------------
-- Line continuation (Scanner semantics from obsidian-tasks)
-- ---------------------------------------------------------------------------
--
-- Rules:
--   * A line ending in a single `\` is a continuation — join with a space.
--   * A line ending in `\\` is a literal trailing `\` (not a continuation).
--     We unescape `\\` → `\` and emit the line.
--   * Otherwise, emit the line as-is.
local function join_continuations(lines)
  local out = {}
  local buf = ""
  for _, line in ipairs(lines) do
    if buf ~= "" then
      buf = buf .. " " .. vim.trim(line)
    else
      buf = line
    end
    if buf:match("\\\\%s*$") then
      buf = buf:gsub("\\\\(%s*)$", "\\%1")
      table.insert(out, buf); buf = ""
    elseif buf:match("\\%s*$") then
      buf = buf:gsub("\\%s*$", "")
      -- do not emit yet — next line extends this one
    else
      table.insert(out, buf); buf = ""
    end
  end
  if buf ~= "" then table.insert(out, buf) end
  return out
end

-- ---------------------------------------------------------------------------
-- Per-line dispatch
-- ---------------------------------------------------------------------------

-- Each handler returns `true` iff it consumed the line; the dispatcher tries
-- them in order. Layout directives match exact strings or lowercased prefixes;
-- sort/group are keyword-prefixed so we can cheaply early-reject; filters are
-- the fallback.
local function try_layout_flags(q, l)
  if l == "short mode" or l == "short" then q.short_mode = true;  return true end
  if l == "full mode"  or l == "full"  then q.short_mode = false; return true end
  if l == "explain"                    then q.explain = true;     return true end
  if l:match("^ignore global query")   then q.ignore_global_query = true; return true end
  return false
end

local function try_limits(q, l)
  local g = l:match("^limit%s+groups%s+to%s+(%d+)")
         or l:match("^limit%s+groups%s+(%d+)")
  if g then q.group_limit = tonumber(g); return true end
  local n = l:match("^limit%s+to%s+(%d+)") or l:match("^limit%s+(%d+)")
  if n then q.limit = tonumber(n); return true end
  return false
end

local function try_hide_show(q, l)
  local hf = l:match("^hide%s+(.+)")
  if hf then q.hide_fields[vim.trim(hf)] = true; return true end
  local sf = l:match("^show%s+(.+)")
  if sf then q.show_fields[vim.trim(sf)] = true; return true end
  return false
end

local function try_sort(q, line, l)
  if not l:match("^sort by") then return false end
  local s = sort_mod.parse_sorter(line)
  if s then
    table.insert(q.sorters, s)
  else
    table.insert(q.errors, "Unknown sort: " .. line)
  end
  return true
end

local function try_group(q, line, l)
  if not l:match("^group by") then return false end
  local g = group_mod.parse_grouper(line)
  if g then
    table.insert(q.groupers, g)
  else
    table.insert(q.errors, "Unknown group: " .. line)
  end
  return true
end

local function try_filter(q, line)
  local f = filter_mod.parse_filter(line)
  if f then
    table.insert(q.filters, f)
  else
    table.insert(q.errors, "Unknown instruction: " .. line)
  end
  return true  -- always "handled" — even errors count as consumed
end

local function parse_line(q, raw)
  local line = vim.trim(raw)
  if line == "" or line:match("^#") then return end
  local l = line:lower()
  if try_layout_flags(q, l) then return end
  if try_limits(q, l)       then return end
  if try_hide_show(q, l)    then return end
  if try_sort(q, line, l)   then return end
  if try_group(q, line, l)  then return end
  try_filter(q, line)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.parse(lines)
  local q = {
    filters = {}, sorters = {}, groupers = {},
    limit = nil, group_limit = nil,
    short_mode = false, show_fields = {}, hide_fields = {},
    explain = false, ignore_global_query = false,
    errors = {}, raw_lines = lines,
  }
  for _, raw in ipairs(join_continuations(lines)) do
    parse_line(q, raw)
  end
  return q
end

-- Apply query.limit to a sorted list. Returns sorted[1..limit] or sorted
-- unchanged if the limit isn't exceeded.
local function apply_limit(sorted, limit)
  if not limit or limit >= #sorted then return sorted end
  local capped = {}
  for i = 1, limit do capped[i] = sorted[i] end
  return capped
end

-- Apply query.group_limit to each group's task list, in place.
local function apply_group_limit(groups, group_limit)
  if not group_limit then return end
  for _, g in ipairs(groups) do
    if #g.tasks > group_limit then
      local capped = {}
      for i = 1, group_limit do capped[i] = g.tasks[i] end
      g.tasks = capped
    end
  end
end

function M.execute(query, tasks)
  tasks = tasks or vault.scan()
  local cfg = config.get()

  -- Merge in the global query (prepended filters; sort/group borrowed if empty).
  if not query.ignore_global_query and cfg.global_query and cfg.global_query ~= "" then
    local gq = M.parse(vim.split(cfg.global_query, "\n"))
    query.filters = vim.list_extend(vim.deepcopy(gq.filters), query.filters)
    if #query.sorters  == 0 then query.sorters  = gq.sorters  end
    if #query.groupers == 0 then query.groupers = gq.groupers end
  end

  -- Filter. Each predicate receives (task, all_tasks) so dependency/blocking
  -- filters can reach into the full population.
  local filtered = {}
  for _, t in ipairs(tasks) do
    local pass = true
    for _, f in ipairs(query.filters) do
      if not f(t, tasks) then pass = false; break end
    end
    if pass then table.insert(filtered, t) end
  end

  local sorted = sort_mod.apply(filtered, query.sorters)
  sorted = apply_limit(sorted, query.limit)
  local groups = group_mod.apply(sorted, query.groupers)
  apply_group_limit(groups, query.group_limit)

  return {
    groups = groups,
    total_count = #filtered,
    error_messages = query.errors,
    query = query,
  }
end

function M.run(lines, tasks)
  return M.execute(M.parse(lines), tasks)
end

return M
