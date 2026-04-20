local date_mod = require("nvim-tasks.date")
local config = require("nvim-tasks.config")
local task_mod = require("nvim-tasks.task")
local M = {}

function M.parse_grouper(line)
  local l = vim.trim(line):lower(); local field = l:match("^group by (.+)"); if not field then return nil end; field = vim.trim(field)
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
  if field == "happens" then return function(t) local d = t.due or t.scheduled or t.start_date
    if not d then return "No date" end; local ts = date_mod.today_str()
    return d < ts and "Overdue" or (d == ts and "Today" or d) end end
  if dg[field] then local f=dg[field]; return function(t) return t[f] or "No "..field end end
  return G[field]
end

function M.apply(tasks, groupers)
  if #groupers == 0 then return { { heading = nil, tasks = tasks } } end
  local function mk(t) local p={}; for _,g in ipairs(groupers) do table.insert(p,g(t)) end; return table.concat(p," > ") end
  local groups, order = {}, {}
  for _, t in ipairs(tasks) do local k = mk(t)
    if not groups[k] then groups[k] = { heading=k, tasks={} }; table.insert(order,k) end
    table.insert(groups[k].tasks, t) end
  local r = {}; for _,k in ipairs(order) do table.insert(r, groups[k]) end; return r
end
return M
