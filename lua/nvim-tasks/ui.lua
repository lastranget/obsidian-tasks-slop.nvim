--- UI module: snacks.nvim-powered pickers, inputs, notifications, and a
--- sequential wizard for creating/editing tasks.
---
--- Design decisions:
---   * Lazy-load snacks.nvim on first use rather than at module load.
---     require("nvim-tasks.ui") won't fail even if snacks isn't installed or
---     hasn't finished loading; the first call that needs snacks will either
---     use it or fall back to `vim.ui.select` / `vim.ui.input` / `vim.notify`.
---   * The wizard uses Snacks.picker for every selection step (priority,
---     status) so the experience is consistent across steps and matches the
---     inline pickers. Earlier versions mixed `vim.ui.select` and Snacks.
---   * `Snacks.notify` is called as `(msg, opts)` with `level` inside opts —
---     that is the documented signature. The older `(msg, level, opts)`
---     form in this plugin was silently losing both the level and the title.
local config = require("nvim-tasks.config")
local task_mod = require("nvim-tasks.task")
local date_mod = require("nvim-tasks.date")
local toggle = require("nvim-tasks.toggle")

local M = {}

-- Lazy snacks accessor. Returns the module or nil.
local function snacks()
  local ok, s = pcall(require, "snacks")
  if ok then return s end
  return nil
end

--- Notify helper. Prefers Snacks.notify when available; falls back to vim.notify.
function M.notify(msg, level)
  level = level or "info"
  local s = snacks()
  if s and s.notify then
    s.notify(msg, { level = level, title = "nvim-tasks" })
    return
  end
  local lvl = vim.log.levels.INFO
  if level == "warn" then lvl = vim.log.levels.WARN
  elseif level == "error" then lvl = vim.log.levels.ERROR end
  vim.notify("[nvim-tasks] " .. msg, lvl)
end

-- vim.ui.select fallback when snacks is not available.
local function select_with_fallback(items, opts, on_choice)
  local s = snacks()
  if s and s.picker then
    s.picker({
      title = opts.prompt or "Select",
      items = items,
      format = function(item) return { { item.text, "Normal" } } end,
      confirm = function(picker, item)
        picker:close()
        on_choice(item)
      end,
      layout = opts.layout or { preset = "select" },
    })
    return
  end
  local labels = {}
  for i, it in ipairs(items) do labels[i] = it.text end
  vim.ui.select(labels, { prompt = opts.prompt }, function(_, idx)
    on_choice(idx and items[idx] or nil)
  end)
end

-- vim.ui.input fallback when snacks is not available.
local function input_with_fallback(opts, on_confirm)
  local s = snacks()
  if s and s.input then
    -- snacks.input module has __call metatable → Snacks.input(opts, cb) works.
    s.input(opts, on_confirm)
    return
  end
  vim.ui.input({ prompt = opts.prompt, default = opts.default }, on_confirm)
end

--- Smart date parser: YYYY-MM-DD, today, tomorrow, yesterday, +3d, -1w, +2m.
local function parse_date_input(input)
  if not input or input == "" then return nil end
  local dt = date_mod.parse_relative(input)
  if dt then return date_mod.format(dt) end
  return nil
end

-- Build the priority-picker items once (emojis don't change mid-session).
local function priority_items()
  local e = config.get().emojis
  return {
    { text = e.highest .. " Highest", item = "highest" },
    { text = e.high    .. " High",    item = "high" },
    { text = e.medium  .. " Medium",  item = "medium" },
    { text = "  None",                item = "__none__" },
    { text = e.low     .. " Low",     item = "low" },
    { text = e.lowest  .. " Lowest",  item = "lowest" },
  }
end

--- Priority picker.
function M.pick_priority(bufnr, lnum)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  select_with_fallback(priority_items(), { prompt = "Set Priority" }, function(item)
    if not item then return end
    local pri = item.item ~= "__none__" and item.item or nil
    toggle.set_priority(bufnr, lnum, pri)
    M.notify("Priority: " .. (pri or "none"))
  end)
end

--- Date prompt.
function M.prompt_date(bufnr, lnum, field, label)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]

  input_with_fallback({
    prompt = label .. " (YYYY-MM-DD, today, tomorrow, +3d, or empty to clear): ",
  }, function(input)
    if input == nil then return end -- cancelled
    input = vim.trim(input)
    if input == "" then
      toggle.set_date(bufnr, lnum, field, "")
      M.notify(label .. " cleared")
      return
    end
    local parsed = parse_date_input(input)
    if parsed then
      toggle.set_date(bufnr, lnum, field, parsed)
      M.notify(label .. ": " .. parsed)
    else
      M.notify("Invalid date: " .. input, "error")
    end
  end)
end

--- Status picker.
function M.pick_status(bufnr, lnum)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]

  local items = {}
  for _, s in ipairs(config.get().statuses) do
    table.insert(items, {
      text = "[" .. s.symbol .. "] " .. s.name .. " (" .. s.type .. ")",
      item = s.symbol,
    })
  end

  select_with_fallback(items, { prompt = "Set Status" }, function(choice)
    if not choice then return end
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    if not line then return end
    local task = task_mod.parse(line)
    if not task then return end
    local old_done = config.is_done(task.status_symbol)
    task.status_symbol = choice.item
    local new_done = config.is_done(choice.item)
    if new_done and not old_done and config.get().auto_done_date then
      task.done_date = date_mod.today_str()
    elseif old_done and not new_done then
      task.done_date = nil
    end
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { task_mod.serialize(task) })
    require("nvim-tasks.vault").invalidate()
  end)
end

-- Parse tags from a free-form input string. Each whitespace-separated "word"
-- becomes one tag; a leading '#' is added if missing; invalid characters end
-- the tag (matching the hash-tag character class used by task.lua's parser,
-- which follows obsidian-tasks' TaskRegularExpressions.hashTags). Words that
-- contain no valid tag character are dropped.
local function parse_tags_input(s)
  local out = {}
  if not s then return out end
  for word in s:gmatch("%S+") do
    if word:sub(1, 1) ~= "#" then word = "#" .. word end
    local tag = word:match("^#[^%s!@#$%%^&*(),.?\":{}|<>]+")
    if tag then table.insert(out, tag) end
  end
  return out
end

--- Sequential wizard for creating or editing a task.
---
--- All steps are optional after Description; pressing <Esc> to cancel a step
--- keeps whatever value was already set on the task. Finalization happens
--- only after the tags step; cancelling the description aborts entirely.
function M.create_or_edit(bufnr, lnum)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]

  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  local existing = task_mod.parse(line or "")
  local is_new = existing == nil

  local task = existing or {
    indent = "", list_marker = "- ", status_symbol = " ",
    description = "", priority = nil, due = nil, scheduled = nil,
    start_date = nil, created = nil, done_date = nil, cancelled_date = nil,
    recurrence = nil, id = nil, depends_on = {}, on_completion = nil,
    block_link = nil, tags = {},
  }

  local title = is_new and "Create Task" or "Edit Task"

  local function finalize()
    if is_new and config.get().auto_created_date then
      task.created = date_mod.today_str()
    end
    local new_line = task_mod.serialize(task)
    if is_new then
      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum - 1, false, { new_line })
    else
      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_line })
    end
    require("nvim-tasks.vault").invalidate()
    require("nvim-tasks.render").refresh(bufnr)
    M.notify(is_new and "Task created" or "Task updated")
  end

  local function step_tags()
    input_with_fallback({
      prompt = title .. " — Tags (space-separated, '#' optional, or empty): ",
      default = table.concat(task.tags or {}, " "),
    }, function(tags_input)
      if tags_input ~= nil then task.tags = parse_tags_input(tags_input) end
      finalize()
    end)
  end

  local function step_recurrence()
    input_with_fallback({
      prompt = title .. " — Recurrence (e.g. 'every week', or empty): ",
      default = task.recurrence or "",
    }, function(rec_input)
      if rec_input ~= nil then
        task.recurrence = rec_input ~= "" and rec_input or nil
      end
      step_tags()
    end)
  end

  local function step_scheduled()
    input_with_fallback({
      prompt = title .. " — Scheduled date (or empty): ",
      default = task.scheduled or "",
    }, function(sched_input)
      if sched_input ~= nil then
        if sched_input == "" then
          task.scheduled = nil
        else
          task.scheduled = parse_date_input(sched_input) or task.scheduled
        end
      end
      step_recurrence()
    end)
  end

  local function step_due()
    input_with_fallback({
      prompt = title .. " — Due date (YYYY-MM-DD, today, +3d, or empty): ",
      default = task.due or "",
    }, function(due_input)
      if due_input ~= nil then
        if due_input == "" then
          task.due = nil
        else
          task.due = parse_date_input(due_input) or task.due
        end
      end
      step_scheduled()
    end)
  end

  local function step_priority()
    -- Build a picker entry for the priority currently set, so the user can
    -- bypass with a single keystroke and keep the existing value.
    local items = priority_items()
    table.insert(items, 1, { text = "(keep current: " .. (task.priority or "none") .. ")", item = "__keep__" })
    select_with_fallback(items, { prompt = title .. " — Priority" }, function(choice)
      if choice and choice.item ~= "__keep__" then
        task.priority = choice.item ~= "__none__" and choice.item or nil
      end
      step_due()
    end)
  end

  -- Step 1: Description (required; cancelling here aborts the whole wizard).
  input_with_fallback({
    prompt = title .. " — Description: ",
    default = task.description or "",
  }, function(desc)
    if not desc or desc == "" then return end
    task.description = desc
    step_priority()
  end)
end

--- Search all vault tasks.
function M.search_tasks()
  local vault = require("nvim-tasks.vault")
  local tasks = vault.scan()
  local e = config.get().emojis

  -- Build items. `text` drives fuzzy-matching; `format` drives display.
  local items = {}
  for _, t in ipairs(tasks) do
    local status = task_mod.is_done(t) and "[x]" or "[ ]"
    local pri_icon = t.priority and e[t.priority] or ""
    local due_str = t.due and (" " .. e.due .. " " .. t.due) or ""
    local fname = t.file_path and vim.fn.fnamemodify(t.file_path, ":t:r") or ""

    table.insert(items, {
      text = status .. " " .. pri_icon .. " " .. t.description .. due_str .. "  (" .. fname .. ")",
      file = t.file_path,
      lnum = t.line_number,
      task = t,
    })
  end

  local s = snacks()
  if not s or not s.picker then
    -- Fallback to a simple vim.ui.select over plain strings.
    local labels = {}
    for i, it in ipairs(items) do labels[i] = it.text end
    vim.ui.select(labels, { prompt = "Search Tasks" }, function(_, idx)
      if not idx then return end
      local item = items[idx]
      if item and item.file and item.lnum then
        vim.cmd("edit " .. vim.fn.fnameescape(item.file))
        vim.api.nvim_win_set_cursor(0, { item.lnum, 0 })
      end
    end)
    return
  end

  s.picker({
    title = "Search Tasks",
    items = items,
    format = function(item)
      local t = item.task
      local parts = {}
      if task_mod.is_done(t) then
        table.insert(parts, { "✓ ", "Comment" })
      else
        table.insert(parts, { "○ ", "Normal" })
      end
      if t.priority then
        local hl = config.get().highlights["priority_" .. t.priority] or "Normal"
        table.insert(parts, { (e[t.priority] or "") .. " ", hl })
      end
      table.insert(parts, { t.description, task_mod.is_done(t) and "Comment" or "Normal" })
      if t.due then
        local today_str = date_mod.today_str()
        local hl = t.due < today_str and "DiagnosticError"
          or (t.due == today_str and "DiagnosticWarn" or "Comment")
        table.insert(parts, { " " .. e.due .. " " .. t.due, hl })
      end
      if t.file_path then
        table.insert(parts, { "  " .. vim.fn.fnamemodify(t.file_path, ":t:r"), "Comment" })
      end
      return parts
    end,
    preview = "file",
    confirm = function(picker, item)
      picker:close()
      if item and item.file and item.lnum then
        vim.cmd("edit " .. vim.fn.fnameescape(item.file))
        vim.api.nvim_win_set_cursor(0, { item.lnum, 0 })
      end
    end,
  })
end

return M
