--- Undo tracking for rendered-dispatch edits.
---
--- When the user runs a plugin command (`:TasksToggleDone`, etc.) with the
--- cursor on a rendered task line, the edit lands in the task's ORIGIN
--- source file — not the rendered buffer — via `toggle.commit_source_edit`.
--- Neovim's native `u` in the rendered buffer won't undo that cross-file
--- edit, so this module provides `:TasksUndo` to fill that gap.
---
--- Single-slot undo (not a stack). Only tracks dispatched edits; same-buffer
--- edits are left to Neovim's native undo. Per-Neovim-session only — no
--- persistence across restarts.
---
--- Captured state:
---   {
---     file_path     = <path to source file>,
---     line_start    = <0-indexed row the mutation began at>,
---     before_lines  = { <lines replaced> },     -- length ≥ 1
---     after_lines   = { <lines after mutation> }, -- can be 0 (delete), 1 (normal), or N (recurrence)
---   }

local M = {}

-- Single-slot last-mutation store. Set by `record_mutation`, consumed by
-- `undo_last`. Per-session only.
M._last_mutation = nil

--- Capture a mutation ready for future undo. Called by the dispatcher
--- (`toggle.lua`) after a source-file edit has been staged in the source
--- buffer but BEFORE `:write`.
---
--- @param file_path   string   absolute path to the source file
--- @param line_start  integer  0-indexed row where the mutation began
--- @param before_lines string[] lines that existed BEFORE the mutation
--- @param after_lines  string[] lines that exist AFTER the mutation (0..N)
function M.record_mutation(file_path, line_start, before_lines, after_lines)
  M._last_mutation = {
    file_path    = file_path,
    line_start   = line_start,
    before_lines = before_lines,
    after_lines  = after_lines,
  }
end

--- Clear the last-mutation slot, e.g. after the user has undone it.
function M.clear() M._last_mutation = nil end

--- Return the last mutation (read-only), or nil.
function M.peek() return M._last_mutation end

--- Notify helper (Snacks if available, else vim.notify).
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

--- Reverse the last dispatched mutation.
---
--- Load the source file (or reuse its loaded buffer), validate that the
--- line range still contains `after_lines` (i.e. the file hasn't changed
--- underneath us), replace with `before_lines`, save, refresh all
--- rendered buffers.
---
--- If no mutation is stashed: notify user, no-op.
--- If the source file has changed since: notify user, refuse, leave slot
--- intact (user can retry after checking).
function M.undo_last()
  local m = M._last_mutation
  if not m then
    notify("No plugin action to undo. Press `u` for buffer-level undo.", "warn")
    return
  end

  -- File must exist on disk.
  if vim.fn.filereadable(m.file_path) == 0 then
    notify("Source file is gone: " .. m.file_path, "error")
    return
  end

  -- Load or reuse the source buffer.
  local src_buf = vim.fn.bufnr(m.file_path)
  if src_buf == -1 or not vim.api.nvim_buf_is_loaded(src_buf) then
    src_buf = vim.fn.bufadd(m.file_path)
    vim.fn.bufload(src_buf)
  end

  -- If source buffer is currently rendered, clear it so we edit real source.
  local render = require("nvim-tasks.render")
  if render.is_rendered(src_buf) then render.clear_buffer(src_buf) end

  -- Validate: the current content at [line_start, line_start+#after_lines)
  -- should match `after_lines`. If it doesn't, the file has changed since
  -- the edit — refuse.
  local n_after = #m.after_lines
  local current = vim.api.nvim_buf_get_lines(src_buf, m.line_start, m.line_start + n_after, false)
  if #current ~= n_after then
    notify("Source file line range changed since edit; cannot undo safely.", "warn")
    return
  end
  for i = 1, n_after do
    if current[i] ~= m.after_lines[i] then
      notify("Source line has changed since edit; cannot undo safely.", "warn")
      return
    end
  end

  -- Replace post-state lines with pre-state lines.
  vim.api.nvim_buf_set_lines(src_buf, m.line_start, m.line_start + n_after, false, m.before_lines)

  -- Save silently, avoiding re-entry into save-protection autocmds.
  vim.api.nvim_buf_call(src_buf, function() vim.cmd("silent noautocmd write") end)

  -- Invalidate and refresh all rendered buffers.
  require("nvim-tasks.vault").invalidate()
  render.refresh_all()

  -- Consume the slot — second undo in a row is a no-op.
  M.clear()
  notify("Undid last task action", "info")
end

return M
