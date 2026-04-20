--- Task-mutation commands: toggle done, cycle status, set priority, dates.
---
--- Each command reads the task line at the cursor, mutates it, and writes
--- back. Two call paths:
---
---   1. Normal buffer (source-mode markdown file): mutate the line in the
---      current buffer and continue.
---
---   2. Rendered buffer (see `render.lua`): the current line is a rendered
---      projection of a task whose real source lives in some OTHER file.
---      We detect this via `render.origin_at_line()`, load the origin file
---      (invisibly if not already open), apply the mutation there, save it,
---      and trigger a re-render of every open rendered buffer so the change
---      propagates everywhere.
---
--- The actual task-serialization logic is shared between both paths —
--- dispatch happens at the top of each public function.

local config     = require("nvim-tasks.config")
local task_mod   = require("nvim-tasks.task")
local date_mod   = require("nvim-tasks.date")
local recurrence = require("nvim-tasks.recurrence")

local M = {}

-- ---------------------------------------------------------------------------
-- Source-file dispatch for rendered buffers
-- ---------------------------------------------------------------------------

--- If `(bufnr, lnum)` points at a rendered task, resolve to the real
--- `{ source_bufnr, source_lnum }` so callers can mutate the source file
--- instead of the rendered projection.
---
--- Loads the source file into a buffer if it isn't already loaded (via
--- `bufadd` + `bufload`, both invisible — no window switch).
---
--- Returns `(source_bufnr, source_lnum)` when dispatch is needed, or nil
--- when `(bufnr, lnum)` is already a real task line (or not a task at all).
local function resolve_rendered_origin(bufnr, lnum)
  local ok, render = pcall(require, "nvim-tasks.render")
  if not ok then return nil end
  if not render.is_rendered(bufnr) then return nil end
  local origin = render.origin_at_line(bufnr, lnum)
  if not origin or not origin.file_path or not origin.line_number then return nil end

  -- Find an existing buffer for this file, else load it.
  local src_buf = vim.fn.bufnr(origin.file_path)
  if src_buf == -1 or not vim.api.nvim_buf_is_loaded(src_buf) then
    src_buf = vim.fn.bufadd(origin.file_path)
    vim.fn.bufload(src_buf)
  end

  -- If the source buffer itself is in rendered state, we'd be mutating a
  -- rendered projection of the same task — clear that buffer first so the
  -- edit lands on the real source, then re-render at the end.
  if render.is_rendered(src_buf) then
    render.clear_buffer(src_buf)
  end

  return src_buf, origin.line_number
end

--- After mutating a source file's line, save the file and refresh all
--- rendered buffers so changes propagate.
local function commit_source_edit(src_buf)
  -- Save. Use silent + noautocmd so we don't re-enter BufWritePre/Post and
  -- cause recursive clear/render cycles.
  vim.api.nvim_buf_call(src_buf, function()
    vim.cmd("silent noautocmd write")
  end)
  require("nvim-tasks.vault").invalidate()
  require("nvim-tasks.render").refresh_all()
end

--- Like `commit_source_edit`, but ALSO records undo state so `:TasksUndo`
--- can reverse this edit. Caller provides the pre-edit and post-edit line
--- ranges so the undo module can validate the file hasn't changed and
--- restore the original lines on undo.
---
--- @param src_buf      integer    source buffer number (already mutated)
--- @param line_start   integer    0-indexed row where mutation began
--- @param before_lines string[]   lines BEFORE the mutation
--- @param after_lines  string[]   lines AFTER the mutation (0..N)
local function dispatch_commit_with_undo(src_buf, line_start, before_lines, after_lines)
  local undo = require("nvim-tasks.undo")
  local file_path = vim.api.nvim_buf_get_name(src_buf)
  undo.record_mutation(file_path, line_start, before_lines, after_lines)
  commit_source_edit(src_buf)
end

-- ---------------------------------------------------------------------------
-- Public commands — each checks for rendered dispatch first
-- ---------------------------------------------------------------------------

--- Resolve (bufnr, lnum) to either the given buffer (normal) or the source
--- buffer (rendered). Returns `(target_bufnr, target_lnum, is_rendered)`.
local function resolve(bufnr, lnum)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  lnum  = lnum  or vim.api.nvim_win_get_cursor(0)[1]
  local src_buf, src_lnum = resolve_rendered_origin(bufnr, lnum)
  if src_buf then return src_buf, src_lnum, true end
  return bufnr, lnum, false
end

-- ---------------------------------------------------------------------------
-- toggle_done
-- ---------------------------------------------------------------------------

function M.toggle_done(bufnr, lnum)
  local tb, tl, dispatched = resolve(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(tb, tl - 1, tl, false)[1]
  if not line then return end

  local task = task_mod.parse(line)
  if task then
    local after_lines = M._toggle_task(tb, tl, task)
    if dispatched then
      dispatch_commit_with_undo(tb, tl - 1, { line }, after_lines or {})
    end
    return
  end

  -- Below this point: not a parseable task. Only meaningful in non-rendered
  -- buffers (rendered task lines always parse). If we were dispatched to a
  -- source file and the line isn't a task, fall through to checklist-like
  -- manipulations on the source file.
  local _, _, symbol = line:match("^(%s*)([-*+]%s+)%[(.)]%s+")
  if not symbol then _, _, symbol = line:match("^(%s*)(%d+[.)]+%s+)%[(.)]%s+") end
  if symbol then
    local s = config.get_status(symbol)
    local ns = s and s.next or (symbol == " " and "x" or " ")
    local new_line = line:gsub("%[.%]", "[" .. ns .. "]", 1)
    vim.api.nvim_buf_set_lines(tb, tl - 1, tl, false, { new_line })
    if dispatched then dispatch_commit_with_undo(tb, tl - 1, { line }, { new_line }) end
    return
  end
  local li = line:match("^(%s*[-*+]%s+)") or line:match("^(%s*%d+[.)]+%s+)")
  if li then
    local new_line = li .. "[ ] " .. line:sub(#li + 1)
    vim.api.nvim_buf_set_lines(tb, tl - 1, tl, false, { new_line })
    if dispatched then dispatch_commit_with_undo(tb, tl - 1, { line }, { new_line }) end
    return
  end
  local ind = line:match("^(%s*)")
  local new_line = ind .. "- [ ] " .. line:sub(#ind + 1)
  vim.api.nvim_buf_set_lines(tb, tl - 1, tl, false, { new_line })
  if dispatched then dispatch_commit_with_undo(tb, tl - 1, { line }, { new_line }) end
end

function M._toggle_task(bufnr, lnum, task)
  local cfg = config.get()
  local was = task_mod.is_done(task)
  local after_lines
  if was then
    task.status_symbol  = " "
    task.done_date      = nil
    task.cancelled_date = nil
    after_lines = { task_mod.serialize(task) }
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, after_lines)
  else
    local today = date_mod.today_str()
    if task.recurrence then
      task.status_symbol = "x"
      if cfg.auto_done_date then task.done_date = today end
      local done_line = task_mod.serialize(task)
      local next_task = recurrence.create_next_recurrence(task, today)
      local keep = task.on_completion ~= "delete"
      local lines = {}
      if next_task then
        local nl = task_mod.serialize(next_task)
        if cfg.recurrence_position == "above" then
          table.insert(lines, nl)
          if keep then table.insert(lines, done_line) end
        else
          if keep then table.insert(lines, done_line) end
          table.insert(lines, nl)
        end
      else
        if keep then table.insert(lines, done_line) end
      end
      after_lines = lines
      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, after_lines)
    else
      task.status_symbol = "x"
      if cfg.auto_done_date then task.done_date = today end
      if task.on_completion == "delete" then
        after_lines = {}
        vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, after_lines)
        require("nvim-tasks.vault").invalidate()
        return after_lines
      end
      after_lines = { task_mod.serialize(task) }
      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, after_lines)
    end
  end
  require("nvim-tasks.vault").invalidate()
  return after_lines
end

-- ---------------------------------------------------------------------------
-- cycle_status
-- ---------------------------------------------------------------------------

function M.cycle_status(bufnr, lnum)
  local tb, tl, dispatched = resolve(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(tb, tl - 1, tl, false)[1]
  if not line then return end
  local task = task_mod.parse(line)
  if not task then return end

  local old_done = config.is_done(task.status_symbol)
  task.status_symbol = config.next_status(task.status_symbol)
  local new_done = config.is_done(task.status_symbol)
  if new_done and not old_done and config.get().auto_done_date then
    task.done_date = date_mod.today_str()
  elseif old_done and not new_done then
    task.done_date = nil
  end
  local new_line = task_mod.serialize(task)
  vim.api.nvim_buf_set_lines(tb, tl - 1, tl, false, { new_line })

  if dispatched then
    dispatch_commit_with_undo(tb, tl - 1, { line }, { new_line })
  else
    require("nvim-tasks.vault").invalidate()
  end
end

-- ---------------------------------------------------------------------------
-- set_priority / increase_priority / decrease_priority
-- ---------------------------------------------------------------------------

local PRIORITY_LEVELS = { "lowest", "low", nil, "medium", "high", "highest" }
local PRIORITY_NONE_IDX = 3

local function current_priority_idx(task)
  for i, v in ipairs(PRIORITY_LEVELS) do
    if v == task.priority then return i end
  end
  return PRIORITY_NONE_IDX
end

local function mutate_priority(bufnr, lnum, mutator)
  local tb, tl, dispatched = resolve(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(tb, tl - 1, tl, false)[1]
  if not line then return end
  local task = task_mod.parse(line)
  if not task then return end
  mutator(task)
  local new_line = task_mod.serialize(task)
  vim.api.nvim_buf_set_lines(tb, tl - 1, tl, false, { new_line })
  if dispatched then dispatch_commit_with_undo(tb, tl - 1, { line }, { new_line }) end
end

function M.set_priority(bufnr, lnum, priority)
  mutate_priority(bufnr, lnum, function(t) t.priority = priority end)
end

function M.increase_priority(bufnr, lnum)
  mutate_priority(bufnr, lnum, function(t)
    local idx = current_priority_idx(t)
    t.priority = PRIORITY_LEVELS[math.min(idx + 1, #PRIORITY_LEVELS)]
  end)
end

function M.decrease_priority(bufnr, lnum)
  mutate_priority(bufnr, lnum, function(t)
    local idx = current_priority_idx(t)
    t.priority = PRIORITY_LEVELS[math.max(idx - 1, 1)]
  end)
end

-- ---------------------------------------------------------------------------
-- set_date
-- ---------------------------------------------------------------------------

function M.set_date(bufnr, lnum, field, value)
  local tb, tl, dispatched = resolve(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(tb, tl - 1, tl, false)[1]
  if not line then return end
  local task = task_mod.parse(line)
  if not task then return end
  task[field] = (value ~= "") and value or nil
  local new_line = task_mod.serialize(task)
  vim.api.nvim_buf_set_lines(tb, tl - 1, tl, false, { new_line })
  if dispatched then dispatch_commit_with_undo(tb, tl - 1, { line }, { new_line }) end
end

return M
