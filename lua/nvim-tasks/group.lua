local date_mod = require("nvim-tasks.date")
local config = require("nvim-tasks.config")
local task_mod = require("nvim-tasks.task")
local M = {}

--- Parse a `group by ...` instruction into a grouper spec.
---
--- Returns one of:
---   * `{ fn = function(task) -> string|string[], reverse = bool }` for built-in
---     groupers. `fn` may return a list of strings to place the task in multiple
---     groups (used by custom-function grouping).
---   * `{ __js = "group", expr = <expr>, reverse = bool }` for
---     `group by function <expr>`, resolved later by query.execute via js.lua.
---   * nil if the instruction is unrecognised.
function M.parse_grouper(line)
  local raw = vim.trim(line)
  local l = raw:lower()
  local rest_l = l:match("^group by%s+(.+)$")
  if not rest_l then return nil end

  -- Custom JS grouper: `group by function [reverse] <expr>`. Detect before the
  -- trailing-`reverse` stripping; capture the expression from the original-case
  -- line (JS is case-sensitive).
  local fexpr_l = rest_l:match("^function%s+(.+)$")
  if fexpr_l then
    local fexpr_raw = raw:sub(#raw - #fexpr_l + 1)
    local reverse = false
    local r = fexpr_l:match("^reverse%s+(.+)$")
    if r then reverse = true; fexpr_raw = fexpr_raw:sub(#fexpr_raw - #r + 1) end
    return { __js = "group", expr = vim.trim(fexpr_raw), reverse = reverse }
  end

  -- A trailing `reverse` flips this level's group order (Tasks 3.7.0+).
  local field = rest_l
  local reverse = field:match("reverse%s*$") ~= nil
  if reverse then field = vim.trim(field:gsub("reverse%s*$", "")) end

  local G = {
    filename = function(t) return t.file_path and vim.fn.fnamemodify(t.file_path,":t:r") or "(no file)" end,
    folder = function(t) return t.file_path and (vim.fn.fnamemodify(t.file_path,":h").."/") or "(no folder)" end,
    root = function(t)
      if not t.file_path then return "/" end
      local rel = t.file_path
      for _, vp in ipairs(config.get().vault_paths or {}) do
        local prefix = vp
        if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
        if rel:sub(1, #prefix) == prefix then
          rel = rel:sub(#prefix + 1)
          break
        end
      end
      local parts = vim.split(rel, "/", { plain = true })
      if #parts <= 1 then return "/" end
      return (parts[1] or "") .. "/"
    end,
    path = function(t) return t.file_path or "(no path)" end,
    backlink = function(t)
      -- Matches obsidian-tasks BacklinkField.grouper() format exactly.
      if not t.file_path then return "Unknown Location" end
      local fn = vim.fn.fnamemodify(t.file_path, ":t:r")
      if fn == "" then return "Unknown Location" end
      local h = t.preceding_header
      if not h or h == "" then return "[[" .. fn .. "]]" end
      return "[[" .. fn .. "#" .. h .. "|" .. fn .. " > " .. h .. "]]"
    end,
    heading = function(t) return (t.preceding_header and t.preceding_header ~= "") and t.preceding_header or "(No heading)" end,
    priority = function(t) return t.priority and ("Priority: "..t.priority) or "Priority: none" end,
    status = function(t) return task_mod.is_done(t) and "Done" or "Todo" end,
    ["status.name"] = function(t) return config.status_name(t.status_symbol) end,
    ["status.type"] = function(t) return config.status_type(t.status_symbol) end,
    recurring = function(t) return t.recurrence and "Recurring" or "Not Recurring" end,
    recurrence = function(t) return t.recurrence or "None" end,
    tags = function(t) return (t.tags and #t.tags > 0) and table.concat(t.tags,", ") or "(No tags)" end,
    id = function(t) return t.id or "(No id)" end,
    urgency = function(t) return string.format("%.1f", task_mod.urgency(t)) end,
  }
  local dg = { due="due",["due date"]="due",scheduled="scheduled",start="start_date",
    created="created",done="done_date",cancelled="cancelled_date" }

  local fn
  if field == "happens" then
    fn = function(t)
      local d = t.due or t.scheduled or t.start_date
      if not d then return "No date" end
      local ts = date_mod.today_str()
      return d < ts and "Overdue" or (d == ts and "Today" or d)
    end
  elseif dg[field] then
    local f = dg[field]
    fn = function(t) return t[f] or ("No " .. field) end
  else
    fn = G[field]
  end
  if not fn then return nil end
  return { fn = fn, reverse = reverse }
end

--- Group tasks by a list of grouper specs (see parse_grouper).
---
--- Each grouper's `fn` returns either a single heading string or a list of
--- strings (multiple groups for one task, e.g. from custom-function grouping).
--- A grouper returning an empty list excludes the task from the results, matching
--- obsidian-tasks' "null group → task omitted" behaviour.
---
--- Groups are ordered by each level's first-appearance order, nesting inner
--- levels within outer ones, with per-grouper `reverse` flipping that level.
--- (For a single grouper this is exactly first-appearance order, reversed when
--- requested.)
function M.apply(tasks, groupers)
  if #groupers == 0 then return { { heading = nil, tasks = tasks } } end
  local n = #groupers

  -- Per-level first-appearance order, used to order groups deterministically.
  local level_order = {}
  for j = 1, n do level_order[j] = { map = {}, count = 0 } end
  local function order_index(j, val)
    local lo = level_order[j]
    if lo.map[val] == nil then lo.count = lo.count + 1; lo.map[val] = lo.count end
    return lo.map[val]
  end

  local function to_list(out)
    if type(out) == "table" then
      local r = {}
      for _, v in ipairs(out) do r[#r + 1] = tostring(v) end
      return r
    end
    return { tostring(out) }
  end

  local groups, group_order = {}, {}
  for _, t in ipairs(tasks) do
    -- Build the per-grouper list of headings; skip the task entirely if any
    -- grouper yields no group.
    local lists, skip = {}, false
    for j = 1, n do
      local lst = to_list(groupers[j].fn(t))
      if #lst == 0 then skip = true; break end
      lists[j] = lst
    end
    if not skip then
      -- Cartesian product across grouper levels → one tuple per resulting group.
      local tuples = { {} }
      for j = 1, n do
        local next_tuples = {}
        for _, tup in ipairs(tuples) do
          for _, val in ipairs(lists[j]) do
            local cp = {}
            for k, v in ipairs(tup) do cp[k] = v end
            cp[#cp + 1] = val
            next_tuples[#next_tuples + 1] = cp
          end
        end
        tuples = next_tuples
      end
      for _, tup in ipairs(tuples) do
        for j = 1, n do order_index(j, tup[j]) end
        local key = table.concat(tup, " > ")
        if not groups[key] then
          groups[key] = { heading = key, tasks = {}, parts = tup }
          table.insert(group_order, key)
        end
        table.insert(groups[key].tasks, t)
      end
    end
  end

  table.sort(group_order, function(a, b)
    local pa, pb = groups[a].parts, groups[b].parts
    for j = 1, n do
      local ia, ib = level_order[j].map[pa[j]], level_order[j].map[pb[j]]
      if ia ~= ib then
        if groupers[j].reverse then return ia > ib end
        return ia < ib
      end
    end
    return false
  end)

  local r = {}
  for _, key in ipairs(group_order) do table.insert(r, groups[key]) end
  return r
end

return M
