--- Virtual-text rendering for Tasks query blocks.
---
--- Given a markdown buffer containing fenced ```tasks blocks, this module:
---   * Runs each block's query against the vault,
---   * Renders the matched tasks as `virt_lines` below the block,
---   * Conceals the original ```tasks ... ``` source lines so the rendered
---     output visually replaces the query source.
---
--- Concealment strategy depends on Neovim version:
---   * Neovim 0.11+ with `conceallevel >= 2`: use the `conceal_lines` extmark
---     property (PR #31324) which hides whole lines cleanly.
---   * Older Neovim: fall back to overlaying a styled border on the fence
---     lines and leaving the query body visible. The rendered output still
---     appears, so the UX degrades gracefully.
---
--- Also coordinates with render-markdown.nvim: if both plugins render the
--- same `tasks` block, the output overlaps. We check render-markdown's runtime
--- config and emit a one-time warning (via Snacks.notify if available) only
--- when `tasks` is not in its `code.disable` list.
local task_mod = require("nvim-tasks.task")
local query_mod = require("nvim-tasks.query")
local config = require("nvim-tasks.config")
local date_mod = require("nvim-tasks.date")

local M = {}
M._rendered = {}
M._render_md_warned = false

local _ns = nil
local function get_ns()
  if not _ns then _ns = vim.api.nvim_create_namespace(config.get().ns_name) end
  return _ns
end

-- Whether this Neovim supports the `conceal_lines` extmark property.
-- Memoised because vim.version() reads from an env struct on every call.
local _supports_conceal_lines = nil
local function supports_conceal_lines()
  if _supports_conceal_lines ~= nil then return _supports_conceal_lines end
  local v = vim.version and vim.version()
  _supports_conceal_lines = v and (v.major > 0 or (v.major == 0 and v.minor >= 11)) or false
  return _supports_conceal_lines
end

-- Read render-markdown's runtime config (not its setup opts) to see whether
-- `tasks` is in the code.disable list. Returns one of:
--   "disabled"  – render-markdown will not render ```tasks blocks (no conflict)
--   "enabled"   – render-markdown WILL render ```tasks blocks (conflict)
--   "unknown"   – render-markdown not installed or not yet initialised
local function inspect_render_markdown()
  local ok, rm_state = pcall(require, "render-markdown.state")
  if not ok then return "unknown" end
  if not rm_state.config then return "unknown" end  -- not yet setup()
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

--- Check render-markdown coordination. Safe to call repeatedly — warns at
--- most once per session, and only when we're sure `tasks` is not disabled.
function M.check_render_markdown()
  if M._render_md_warned then return end
  local status = inspect_render_markdown()
  if status ~= "enabled" then return end  -- nothing to warn about

  M._render_md_warned = true
  local msg = "render-markdown.nvim will render ```tasks blocks, which conflicts with "
    .. "nvim-tasks's output. Add 'tasks' to render-markdown's code.disable list:\n\n"
    .. "  require('render-markdown').setup({\n"
    .. "    code = { disable = { 'tasks' } },\n"
    .. "  })"
  local sok, Snacks = pcall(require, "snacks")
  if sok and Snacks and Snacks.notify then
    -- Correct Snacks.notify signature: (msg, opts) where level goes in opts.
    Snacks.notify(msg, { level = "warn", title = "nvim-tasks", timeout = 10000 })
  else
    vim.notify("[nvim-tasks] " .. msg, vim.log.levels.WARN)
  end
end

--- Format a single task for rendered display. Returns (text, highlight_group).
function M._format_task(task, query_obj)
  local cfg = config.get()
  local e = cfg.emojis
  local parts = {}
  local hl = "Normal"
  local sc = task.status_symbol

  -- Show the actual status symbol from the source rather than mapping through
  -- a hardcoded table. This preserves information for users with custom
  -- status configurations and keeps the rendered view faithful to the file.
  table.insert(parts, "[" .. (sc or " ") .. "]")
  if config.is_done(sc) or config.is_cancelled(sc) then hl = cfg.highlights.done end

  table.insert(parts, task.description)
  local hide = query_obj and query_obj.hide_fields or {}
  local show = query_obj and query_obj.show_fields or {}
  local short = query_obj and query_obj.short_mode or false

  if task.priority and not hide["priority"] then
    local em = e[task.priority]; if em then table.insert(parts, em) end
    if not config.is_done(sc) then local ph = cfg.highlights["priority_"..task.priority]; if ph then hl = ph end end
  end
  if task.recurrence and not hide["recurrence rule"] and not hide["recurrence"] then
    table.insert(parts, short and e.recurrence or (e.recurrence.." "..task.recurrence)) end
  if task.on_completion and task.on_completion ~= "" and task.on_completion ~= "ignore" and not hide["on completion"] then
    table.insert(parts, e.on_completion.." "..task.on_completion) end

  local function ad(f, em, hk) if task[f] and not hide[hk] then
    table.insert(parts, short and em or (em.." "..task[f])) end end
  ad("start_date", e.start, "start date"); ad("scheduled", e.scheduled, "scheduled date")
  ad("due", e.due, "due date"); ad("created", e.created, "created date")
  ad("done_date", e.done, "done date"); ad("cancelled_date", e.cancelled, "cancelled date")

  if task.id and not hide["id"] then table.insert(parts, e.id.." "..task.id) end
  if task.depends_on and #task.depends_on > 0 and not hide["depends on"] then
    table.insert(parts, e.depends_on.." "..table.concat(task.depends_on,",")) end
  if show["urgency"] then table.insert(parts, string.format("⚡%.1f", task_mod.urgency(task))) end

  -- Overdue highlight overrides priority
  if not config.is_done(sc) and task.due then
    local today = date_mod.today(); local dd = date_mod.parse(task.due)
    if dd then
      if date_mod.before(dd, today) then hl = cfg.highlights.overdue
      elseif date_mod.equal(dd, today) then hl = cfg.highlights.due_today end
    end
  end

  -- Backlink
  if not hide["backlink"] and not hide["path"] and task.file_path and not short then
    local fn = vim.fn.fnamemodify(task.file_path, ":t:r")
    table.insert(parts, "(" .. (task.preceding_header and (fn.." > "..task.preceding_header) or fn) .. ")")
  end

  return table.concat(parts, " "), hl
end

-- Build the list of virtual-line segments for a single query block.
local function build_virt_lines(result, block)
  local virt = {}
  local hide = result.query and result.query.hide_fields or {}
  local hl = config.get().highlights

  for _, err in ipairs(result.error_messages) do
    table.insert(virt, { { "⚠ " .. err, "DiagnosticWarn" } })
  end

  if result.query and result.query.explain then
    table.insert(virt, { { "── Query Explanation ──", hl.query_border } })
    for _, ql in ipairs(block.query_lines) do
      local tr = vim.trim(ql)
      if tr ~= "" and not tr:match("^#") then
        table.insert(virt, { { "  " .. tr, "Comment" } })
      end
    end
    table.insert(virt, { { "", "Normal" } })
  end

  if not hide["task count"] then
    table.insert(virt, {
      { string.format("── %d task%s ──", result.total_count,
        result.total_count == 1 and "" or "s"), hl.query_border },
    })
  end

  for _, grp in ipairs(result.groups) do
    if grp.heading then
      table.insert(virt, { { "", "Normal" } })
      table.insert(virt, { { "▸ " .. grp.heading, hl.group_heading } })
    end
    for _, t in ipairs(grp.tasks) do
      local text, hlg = M._format_task(t, result.query)
      table.insert(virt, { { "  " .. text, hlg } })
    end
  end

  if result.total_count == 0 then
    table.insert(virt, { { "  (no matching tasks)", "Comment" } })
  end
  table.insert(virt, { { "── end ──", hl.query_border } })

  return virt
end

function M.render_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  -- Check render-markdown coordination lazily on each render so we catch the
  -- case where render-markdown is set up after nvim-tasks.setup().
  M.check_render_markdown()

  local ns = get_ns()
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local blocks = task_mod.find_query_blocks(bufnr)
  if #blocks == 0 then return end

  local vault = require("nvim-tasks.vault")
  local all_tasks = vault.scan()

  -- Two rendering strategies:
  --
  --   "inline"  (default): virt_lines below the block, source stays visible.
  --             Works on every Neovim version. Cursor navigation is natural —
  --             you can move through and edit the query source.
  --
  --   "conceal" (opt-in on 0.11+): hide the block entirely via `conceal_lines`
  --             and render output ABOVE the block. Prettier when looking but
  --             fragile: Neovim reveals concealed lines when the cursor is on
  --             them (by default), so the rendered output flickers as you
  --             navigate. Requires `conceallevel >= 2` to function at all.
  --
  -- The old default was "conceal" but it had too many rough edges (cursor-
  -- reveal, virt_lines + conceal interaction bugs on 0.11.x — see nvim
  -- issues #32744 / #33033). Default is now "inline".
  local cfg = config.get()
  local strategy = cfg.render_strategy or "inline"
  local use_conceal = strategy == "conceal"
    and supports_conceal_lines()
    and vim.wo.conceallevel >= 2
  local hl = cfg.highlights

  for _, block in ipairs(blocks) do
    local result = query_mod.run(block.query_lines, all_tasks)
    local virt = build_virt_lines(result, block)

    if use_conceal then
      -- Conceal the entire block (opening fence, query body, closing fence).
      -- The virt_lines attached to block.start take its visual place.
      for i = block.start, block.finish do
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, i, 0, {
          conceal_lines = "",
        })
      end
      if #virt > 0 then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, block.start, 0, {
          virt_lines = virt,
          virt_lines_above = true,
        })
      end
    else
      -- Inline: keep the query source visible; place the rendered output
      -- as virt_lines below the closing fence. Draw a subtle border on the
      -- fence lines so the user can see where the plugin is contributing
      -- virtual content.
      if #virt > 0 then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, block.finish, 0, {
          virt_lines = virt, virt_lines_above = false,
        })
      end
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, block.start, 0, {
        virt_text = { { "╭─ Tasks Query", hl.query_border } },
        virt_text_pos = "overlay",
      })
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, block.finish, 0, {
        virt_text = { { "╰─────────────", hl.query_border } },
        virt_text_pos = "overlay",
      })
    end
  end
  M._rendered[bufnr] = true
end

function M.clear_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(bufnr, get_ns(), 0, -1)
  M._rendered[bufnr] = false
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local sok, Snacks = pcall(require, "snacks")
  local function notify(msg, level)
    if sok and Snacks and Snacks.notify then
      Snacks.notify(msg, { level = level, title = "nvim-tasks" })
    else
      local lvl = level == "warn" and vim.log.levels.WARN
        or (level == "error" and vim.log.levels.ERROR)
        or vim.log.levels.INFO
      vim.notify("[nvim-tasks] " .. msg, lvl)
    end
  end
  if M._rendered[bufnr] then
    M.clear_buffer(bufnr)
    notify("Rendering OFF (edit mode)", "info")
  else
    M.render_buffer(bufnr)
    notify("Rendering ON", "info")
  end
end

function M.is_rendered(bufnr) return M._rendered[bufnr] == true end
function M.refresh(bufnr) if M._rendered[bufnr] then M.render_buffer(bufnr) end end
return M
