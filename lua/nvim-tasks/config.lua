--- Configuration. Integrates with obsidian.nvim for vault path auto-detection.
local M = {}
M.defaults = {
  vault_paths = {},          -- empty = auto-detect from obsidian.nvim, fallback to cwd
  global_filter = "",
  global_query = "",
  file_patterns = { "*.md" },
  -- Default statuses mirror Obsidian Tasks' built-ins so vaults round-trip unchanged.
  -- Override freely via setup() if you use different conventions (e.g. '>' for deferred).
  statuses = {
    { symbol = " ", name = "Todo",        next = "x", type = "TODO" },
    { symbol = "x", name = "Done",        next = " ", type = "DONE" },
    { symbol = "X", name = "Done",        next = " ", type = "DONE" },
    { symbol = "/", name = "In Progress", next = "x", type = "IN_PROGRESS" },
    { symbol = "-", name = "Cancelled",   next = " ", type = "CANCELLED" },
    { symbol = "h", name = "On Hold",     next = " ", type = "ON_HOLD" },
    { symbol = "Q", name = "Non-Task",    next = "A", type = "NON_TASK" },
  },
  emojis = {
    due = "📅", scheduled = "⏳", start = "🛫", created = "➕",
    done = "✅", cancelled = "❌", recurrence = "🔁",
    highest = "🔺", high = "⏫", medium = "🔼", low = "🔽", lowest = "⏬",
    id = "🆔", depends_on = "⛔", on_completion = "🏁",
  },
  emoji_aliases = { due = { "📆", "🗓" }, scheduled = { "⌛" } },
  priority_order = { highest = 0, high = 1, medium = 2, none = 3, low = 4, lowest = 5 },
  recurrence_position = "above",  -- matches obsidian-tasks' default; set to "below" for old behavior
  remove_scheduled_on_recurrence = false,
  auto_created_date = true,
  auto_done_date = true,
  render_on_load = true,
  keymaps = {
    toggle_done = "<C-CR>", toggle_render = "<leader>otr", create_task = "<leader>otc",
    set_priority = "<leader>otp", set_due_date = "<leader>otd", set_scheduled = "<leader>ots",
    set_start_date = "<leader>otS", cycle_status = "<leader>otx",
    increase_priority = "<leader>ot+", decrease_priority = "<leader>ot-",
    search_tasks = "<leader>otF",
    goto_source = "<leader>otg", goto_source_split = "<leader>otG",
    undo_last = "<leader>otu",
  },
  highlights = {
    overdue = "DiagnosticError", due_today = "DiagnosticWarn", done = "Comment",
    priority_highest = "DiagnosticError", priority_high = "DiagnosticWarn",
    priority_medium = "DiagnosticInfo", priority_low = "DiagnosticHint",
    priority_lowest = "Comment", group_heading = "Title", query_border = "FloatBorder",
  },
  ns_name = "nvim_tasks",
}
M.config = vim.deepcopy(M.defaults)

function M.setup(opts) M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {}) end
function M.get() return M.config end

--- Resolve vault paths: explicit user config > obsidian.nvim vault root > cwd.
---
--- obsidian.nvim sets a global `Obsidian` table during setup. The vault root lives
--- at either `Obsidian.dir` or `Obsidian.workspace.root`; `Obsidian.workspace.path`
--- is the workspace path which may be a *subdirectory* of the vault. We want the
--- root so tasks anywhere in the vault are discoverable. All three are obsidian.Path
--- objects, so tostring() is required.
function M.resolve_vault_paths()
  local cfg = M.config
  if cfg.vault_paths and #cfg.vault_paths > 0 then return cfg.vault_paths end
  local obs = rawget(_G, "Obsidian")
  if obs then
    -- Prefer the vault root; fall back to workspace.path if .root is unavailable.
    if obs.dir then return { tostring(obs.dir) } end
    local ws = obs.workspace
    if ws then
      if ws.root then return { tostring(ws.root) } end
      if ws.path then return { tostring(ws.path) } end
    end
  end
  return { vim.fn.getcwd() }
end

function M.get_status(symbol)
  for _, s in ipairs(M.config.statuses) do if s.symbol == symbol then return s end end
  return nil
end
function M.is_done(symbol)
  local s = M.get_status(symbol)
  if not s then return symbol == "x" or symbol == "X" end
  return s.type == "DONE" or s.type == "CANCELLED" or s.type == "NON_TASK"
end
function M.is_cancelled(symbol)
  local s = M.get_status(symbol); return s and s.type == "CANCELLED"
end
function M.status_type(symbol)
  local s = M.get_status(symbol); return s and s.type or "TODO"
end
function M.status_name(symbol)
  local s = M.get_status(symbol); return s and s.name or "Unknown"
end
function M.next_status(symbol)
  local s = M.get_status(symbol); return s and s.next or "x"
end
return M
