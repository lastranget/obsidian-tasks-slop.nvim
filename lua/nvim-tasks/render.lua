--- Buffer-replacement rendering for `tasks` query blocks.
---
--- When a buffer is "rendered", each ```tasks ... ``` block in the buffer
--- is REPLACED with real markdown text — the query's rendered output lives
--- as actual buffer lines rather than virt_lines.
---
--- Why buffer replacement rather than virt_lines?
---
---   * Cursor navigation works naturally — j/k move through rendered tasks.
---   * Plugins like render-markdown.nvim style the rendered lines the same
---     way they style every other task line in the buffer, so the visual
---     is consistent.
---   * `:TasksToggleDone` etc. can dispatch to the source file via an
---     origin extmark attached to each rendered task line.
---   * Fold-expr + treesitter picks up the ### group headings we emit, so
---     group sections fold naturally.
---
--- Rendered output format:
---
---   ```tasks            ←───── this block (source lines)
---   not done                   are replaced with the below
---   group by priority   ←─────
---   ```
---
---   becomes:
---
---   *── 218 tasks ──*                            ← count banner (italic)
---
---   #### Priority: high                          ← group heading (fold-able)
---   - [ ] Task desc ⏫ 📅 2026-04-20 [[src#Top]]  ← real task line + wiki-link
---   - [ ] Another task ⏫ [[other-file]]
---
---   #### Priority: medium
---   - [ ] Task desc 🔼 [[src]]
---
---   *── end ──*
---
--- State lives in `vim.b[bufnr]._nvim_tasks_state`:
---
---     {
---       rendered = true,
---       blocks = {
---         {
---           anchor_extmark = <id>,       -- tracks rendered-block start line
---           source_lines   = {...},      -- original fenced block lines
---           rendered_count = <int>,      -- how many lines the render produced
---           task_origins   = {           -- offset (1-indexed in block) -> origin
---             [offset] = { file_path, line_number }, ...
---           },
---         }, ...
---       },
---     }

local task_mod  = require("nvim-tasks.task")
local query_mod = require("nvim-tasks.query")
local config    = require("nvim-tasks.config")

local M = {}

local _ns = nil
local function get_ns()
  if not _ns then _ns = vim.api.nvim_create_namespace(config.get().ns_name) end
  return _ns
end

-- ---------------------------------------------------------------------------
-- render-markdown coordination — unchanged from session 10.
-- ---------------------------------------------------------------------------

M._render_md_warned = false

local function inspect_render_markdown()
  local ok, rm_state = pcall(require, "render-markdown.state")
  if not ok then return "unknown" end
  if not rm_state.config then return "unknown" end
  local code = rm_state.config.code
  if not code then return "enabled" end
  local disable = code.disable
  if disable == true then return "disabled" end
  if type(disable) == "table" then
    for _, v in ipairs(disable) do
      if v == "tasks" then return "disabled" end
    end
  end
  return "enabled"
end

function M.check_render_markdown()
  if M._render_md_warned then return end
  local status = inspect_render_markdown()
  if status ~= "enabled" then return end
  M._render_md_warned = true
  local msg = "render-markdown.nvim will render ```tasks blocks, which conflicts with "
    .. "nvim-tasks's output. Add 'tasks' to render-markdown's code.disable list:\n\n"
    .. "  require('render-markdown').setup({\n"
    .. "    code = { disable = { 'tasks' } },\n"
    .. "  })"
  local sok, Snacks = pcall(require, "snacks")
  if sok and Snacks and Snacks.notify then
    Snacks.notify(msg, { level = "warn", title = "nvim-tasks", timeout = 10000 })
  else
    vim.notify("[nvim-tasks] " .. msg, vim.log.levels.WARN)
  end
end

-- ---------------------------------------------------------------------------
-- Task line formatting: produce a real markdown task line
-- ---------------------------------------------------------------------------

--- Format a task as a clickable, parseable markdown task line.
---
--- Output: `- [status] description emoji-metadata [[file#heading]]`
---
--- The wiki-link at the end is real text — `gf`, obsidian.nvim, or any
--- Markdown-aware navigation picks it up and jumps to source.
local function format_task_line(task, query_obj)
  local cfg = config.get()
  local e   = cfg.emojis
  local hide = query_obj and query_obj.hide_fields or {}
  local show = query_obj and query_obj.show_fields or {}
  local short = query_obj and query_obj.short_mode or false

  local parts = { "- [" .. (task.status_symbol or " ") .. "]", task.description }

  if task.priority and not hide["priority"] then
    local em = e[task.priority]; if em then table.insert(parts, em) end
  end
  if task.recurrence and not hide["recurrence rule"] and not hide["recurrence"] then
    table.insert(parts, short and e.recurrence or (e.recurrence .. " " .. task.recurrence))
  end
  if task.on_completion and task.on_completion ~= "" and task.on_completion ~= "ignore" and not hide["on completion"] then
    table.insert(parts, e.on_completion .. " " .. task.on_completion)
  end
  local function add(field, emoji, hide_key)
    if task[field] and not hide[hide_key] then
      table.insert(parts, short and emoji or (emoji .. " " .. task[field]))
    end
  end
  add("start_date",     e.start,     "start date")
  add("scheduled",      e.scheduled, "scheduled date")
  add("due",            e.due,       "due date")
  add("created",        e.created,   "created date")
  add("done_date",      e.done,      "done date")
  add("cancelled_date", e.cancelled, "cancelled date")

  if task.id and not hide["id"] then
    table.insert(parts, e.id .. " " .. task.id)
  end
  if task.depends_on and #task.depends_on > 0 and not hide["depends on"] then
    table.insert(parts, e.depends_on .. " " .. table.concat(task.depends_on, ","))
  end
  if show["urgency"] then
    table.insert(parts, string.format("⚡%.1f", task_mod.urgency(task)))
  end

  -- Backlink as an Obsidian wiki-link — real clickable text. `gf` jumps to
  -- the file; obsidian.nvim's follow-link also handles the #heading part.
  if not hide["backlink"] and not hide["path"] and task.file_path and not short then
    local fn = vim.fn.fnamemodify(task.file_path, ":t:r")
    if fn and fn ~= "" then
      if task.preceding_header and task.preceding_header ~= "" then
        table.insert(parts, "[[" .. fn .. "#" .. task.preceding_header .. "]]")
      else
        table.insert(parts, "[[" .. fn .. "]]")
      end
    end
  end

  return table.concat(parts, " ")
end

-- ---------------------------------------------------------------------------
-- Build the replacement text for one block
-- ---------------------------------------------------------------------------

--- Returns `(lines, task_origins)` where `lines` is the list of real buffer
--- lines the block becomes, and `task_origins` is a table keyed by 1-indexed
--- line offset within the block → `{ file_path, line_number }` for lines that
--- represent tasks.
local function build_block_output(result)
  local lines = {}
  local task_origins = {}
  local hide = result.query and result.query.hide_fields or {}

  -- Errors as blockquote lines (render-markdown styles these).
  for _, err in ipairs(result.error_messages) do
    table.insert(lines, "> ⚠ " .. err)
  end

  -- Explain: echo query source as a quoted block.
  if result.query and result.query.explain then
    table.insert(lines, "*── Query ──*")
    for _, ql in ipairs(result.query.raw_lines or {}) do
      local tr = vim.trim(ql)
      if tr ~= "" and not tr:match("^#") then
        table.insert(lines, "> " .. tr)
      end
    end
    table.insert(lines, "")
  end

  -- Count banner — italicised so render-markdown styles it distinctly.
  if not hide["task count"] then
    table.insert(lines, string.format("*── %d task%s ──*",
      result.total_count, result.total_count == 1 and "" or "s"))
    table.insert(lines, "")
  end

  for _, grp in ipairs(result.groups) do
    if grp.heading then
      -- Level-4 heading — deep enough that most notes don't use it, so
      -- treesitter fold-expr folds each group cleanly without disturbing
      -- the document's own heading hierarchy.
      table.insert(lines, "#### " .. grp.heading)
    end
    for _, t in ipairs(grp.tasks) do
      table.insert(lines, format_task_line(t, result.query))
      task_origins[#lines] = {
        file_path   = t.file_path,
        line_number = t.line_number,
      }
    end
    table.insert(lines, "")
  end

  if result.total_count == 0 then
    table.insert(lines, "*(no matching tasks)*")
  end
  table.insert(lines, "*── end ──*")

  return lines, task_origins
end

-- ---------------------------------------------------------------------------
-- State accessors
-- ---------------------------------------------------------------------------
--
-- State lives in a module-level table keyed by bufnr rather than a buffer
-- variable. Reason: task_origins is a sparse table (most output lines aren't
-- tasks) and nvim_buf_set_var serializes through msgpack, which rejects
-- sparse tables with the error "Cannot convert given lua table". Module-
-- level storage also lets us hold arbitrary Lua values without worrying
-- about serialization constraints.
M._state = {}

local function get_state(bufnr)
  return M._state[bufnr]
end

local function set_state(bufnr, state)
  M._state[bufnr] = state
end

local function clear_state(bufnr)
  M._state[bufnr] = nil
end

-- Clean up state when a buffer is wiped out.
vim.api.nvim_create_autocmd("BufWipeout", {
  callback = function(ev) M._state[ev.buf] = nil end,
})

-- ---------------------------------------------------------------------------
-- Save protection
-- ---------------------------------------------------------------------------
--
-- These autocmds are self-registering at module load so save protection
-- works even if a caller loads render.lua without going through the full
-- plugin setup(). The file on disk must ALWAYS contain the original source
-- (```tasks...``` fenced block), never the rendered output.
--
--   BufWritePre  — if rendered, clear (restore source) and set a flag.
--   BufWritePost — if was-rendered, re-render; invalidate vault cache.
--
-- A module-level flag keyed by bufnr tracks the "was rendered at Pre time"
-- state across the Pre/Post pair, since clear_buffer removes it from
-- M._state and is_rendered() returns false at Post time otherwise.

M._was_rendered_for_save = {}

local _save_augroup = vim.api.nvim_create_augroup("NvimTasksRenderSave", { clear = true })

vim.api.nvim_create_autocmd("BufWritePre", {
  group = _save_augroup, pattern = "*.md",
  callback = function(ev)
    if M.is_rendered(ev.buf) then
      M._was_rendered_for_save[ev.buf] = true
      M.clear_buffer(ev.buf)
    end
  end,
})

vim.api.nvim_create_autocmd("BufWritePost", {
  group = _save_augroup, pattern = "*.md",
  callback = function(ev)
    -- Invalidate vault cache on every markdown save — even from a buffer
    -- that wasn't rendered, since its tasks may now be visible in other
    -- rendered buffers.
    pcall(function() require("nvim-tasks.vault").invalidate() end)

    if M._was_rendered_for_save[ev.buf] then
      M._was_rendered_for_save[ev.buf] = nil
      if vim.api.nvim_buf_is_valid(ev.buf) then M.render_buffer(ev.buf) end
      -- Other open rendered buffers may reference tasks from this file;
      -- refresh them too.
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if b ~= ev.buf and vim.api.nvim_buf_is_loaded(b) and M.is_rendered(b) then
          M.refresh(b)
        end
      end
    end
  end,
})

-- ---------------------------------------------------------------------------
-- Render: replace each block's source lines with rendered output
-- ---------------------------------------------------------------------------

function M.render_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  M.check_render_markdown()

  -- Idempotency: if already rendered, clear first so we don't double-render.
  if get_state(bufnr) then M.clear_buffer(bufnr) end

  local ns = get_ns()
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local blocks = task_mod.find_query_blocks(bufnr)
  if #blocks == 0 then return end

  local vault = require("nvim-tasks.vault")
  local all_tasks = vault.scan()

  -- Process blocks bottom-up so earlier replacements don't shift later block
  -- indices. Buffer mutations always affect line numbers at and below the
  -- edit, not above — so working from the last block upward keeps every
  -- block's stored {start, finish} valid.
  table.sort(blocks, function(a, b) return a.start > b.start end)

  local blocks_state = {}

  for _, block in ipairs(blocks) do
    local result = query_mod.run(block.query_lines, all_tasks)
    local output_lines, task_origins = build_block_output(result)

    -- Save original source before replacing.
    local source_lines = vim.api.nvim_buf_get_lines(bufnr, block.start, block.finish + 1, false)

    -- Replace the block's source with the rendered output.
    vim.api.nvim_buf_set_lines(bufnr, block.start, block.finish + 1, false, output_lines)

    -- Anchor extmark at the start of the rendered region so we can locate
    -- the block later even after edits elsewhere in the buffer.
    local anchor = vim.api.nvim_buf_set_extmark(bufnr, ns, block.start, 0, {
      right_gravity = false,
    })

    -- Blocks are processed bottom-up, so we PREPEND to keep buffer-order.
    table.insert(blocks_state, 1, {
      anchor_extmark = anchor,
      source_lines   = source_lines,
      rendered_count = #output_lines,
      task_origins   = task_origins,
    })
  end

  set_state(bufnr, { rendered = true, blocks = blocks_state })
end

-- ---------------------------------------------------------------------------
-- Clear: restore source lines
-- ---------------------------------------------------------------------------

function M.clear_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = get_state(bufnr)
  if not state or not state.rendered then
    vim.api.nvim_buf_clear_namespace(bufnr, get_ns(), 0, -1)
    clear_state(bufnr)
    return
  end

  local ns = get_ns()

  -- Collect each block's current start line via its anchor extmark, then
  -- sort top-to-bottom-reversed so restoration doesn't shift later blocks.
  local blocks = {}
  for _, b in ipairs(state.blocks) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, b.anchor_extmark, {})
    if pos and pos[1] then
      b._start = pos[1]
      table.insert(blocks, b)
    end
  end
  table.sort(blocks, function(a, b) return a._start > b._start end)

  for _, b in ipairs(blocks) do
    local start_line = b._start
    local end_line   = start_line + b.rendered_count
    vim.api.nvim_buf_set_lines(bufnr, start_line, end_line, false, b.source_lines)
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  clear_state(bufnr)
end

-- ---------------------------------------------------------------------------
-- Origin lookup — used by toggle / ui dispatchers
-- ---------------------------------------------------------------------------

--- Given a buffer and a 1-indexed line number, return the origin of the
--- task on that line if it's a rendered task line, else nil.
---
--- @return table? { file_path, line_number } or nil
function M.origin_at_line(bufnr, lnum_1indexed)
  local state = get_state(bufnr)
  if not state or not state.rendered then return nil end
  local ns = get_ns()
  for _, b in ipairs(state.blocks) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, b.anchor_extmark, {})
    if pos and pos[1] then
      local block_start = pos[1]
      -- Offset within block is 1-indexed.
      local offset = lnum_1indexed - block_start
      if offset >= 1 and offset <= b.rendered_count then
        local origin = b.task_origins[offset]
        if origin then return origin end
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Goto source: jump from a rendered task line to its origin in the source
-- ---------------------------------------------------------------------------

--- Notify helper that prefers Snacks.notify, falling back to vim.notify.
local function notify(msg, level)
  local sok, Snacks = pcall(require, "snacks")
  if sok and Snacks and Snacks.notify then
    Snacks.notify(msg, { level = level or "info", title = "nvim-tasks" })
  else
    local lvl = level == "warn" and vim.log.levels.WARN
      or (level == "error" and vim.log.levels.ERROR)
      or vim.log.levels.INFO
    vim.notify("[nvim-tasks] " .. msg, lvl)
  end
end

--- Internal: resolve the origin at the cursor or return nil with a notice.
---
--- Returns the origin table `{ file_path, line_number }` for the task on
--- the current (or specified) line, or nil if the cursor isn't on a
--- rendered task line. When nil, notifies the user so the command doesn't
--- silently do nothing.
local function resolve_origin_at(bufnr, lnum)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  lnum  = lnum  or vim.api.nvim_win_get_cursor(0)[1]
  if not M.is_rendered(bufnr) then
    notify("Not a rendered view — cursor is not on a rendered task", "warn")
    return nil
  end
  local origin = M.origin_at_line(bufnr, lnum)
  if not origin or not origin.file_path then
    notify("No task on this line", "warn")
    return nil
  end
  return origin
end

--- Jump to a task's source file and exact line, replacing the current
--- window's buffer.
---
--- The cursor lands on column 0 of the task's line and the view is
--- centered (`zz`). If the source file isn't already loaded, it's
--- opened via `:edit`.
function M.goto_source(bufnr, lnum)
  local origin = resolve_origin_at(bufnr, lnum)
  if not origin then return end
  -- Use :edit so the command goes through normal buffer-load autocmds
  -- (filetype detection, treesitter, etc.).
  vim.cmd("edit " .. vim.fn.fnameescape(origin.file_path))
  -- Clamp line_number to the buffer's actual length in case the file
  -- changed since we rendered. Defensive but cheap.
  local last = vim.api.nvim_buf_line_count(0)
  local target = math.min(math.max(origin.line_number, 1), last)
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  vim.cmd("normal! zz")
end

--- Like `goto_source` but opens the source in a horizontal split below,
--- leaving the rendered dashboard visible in the original window.
function M.goto_source_split(bufnr, lnum)
  local origin = resolve_origin_at(bufnr, lnum)
  if not origin then return end
  -- `split <file>` creates the split and loads the file in one step.
  -- `belowright` places the new window below the current one, which is
  -- what most users expect (and matches vim's default for `:split`).
  vim.cmd("belowright split " .. vim.fn.fnameescape(origin.file_path))
  local last = vim.api.nvim_buf_line_count(0)
  local target = math.min(math.max(origin.line_number, 1), last)
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  vim.cmd("normal! zz")
end

-- ---------------------------------------------------------------------------
-- Toggle, refresh, state queries
-- ---------------------------------------------------------------------------

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.is_rendered(bufnr) then
    M.clear_buffer(bufnr)
    notify("Rendering OFF (edit mode)", "info")
  else
    M.render_buffer(bufnr)
    notify("Rendering ON", "info")
  end
end

function M.is_rendered(bufnr)
  local state = get_state(bufnr)
  return state ~= nil and state.rendered == true
end

function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.is_rendered(bufnr) then
    M.clear_buffer(bufnr)
    M.render_buffer(bufnr)
  end
end

--- Refresh every loaded buffer currently in rendered state. Called after a
--- source-file edit so all open rendered views reflect the change.
function M.refresh_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and M.is_rendered(buf) then
      M.refresh(buf)
    end
  end
end

return M
