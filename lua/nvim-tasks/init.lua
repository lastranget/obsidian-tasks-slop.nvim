--- nvim-tasks: Obsidian Tasks plugin for Neovim.
--- Dependencies: plenary.nvim, snacks.nvim
--- Optional integrations: obsidian.nvim (vault path auto-detection), render-markdown.nvim
local M = {}

--- Verify hard dependencies are available.
local function check_deps()
  local ok_plenary, _ = pcall(require, "plenary")
  if not ok_plenary then
    error("[nvim-tasks] Required dependency 'plenary.nvim' not found. Install: https://github.com/nvim-lua/plenary.nvim")
  end
  local ok_snacks, _ = pcall(require, "snacks")
  if not ok_snacks then
    error("[nvim-tasks] Required dependency 'snacks.nvim' not found. Install: https://github.com/folke/snacks.nvim")
  end
end

function M.setup(opts)
  check_deps()

  -- Configuration must load first; other modules read from it on demand.
  require("nvim-tasks.config").setup(opts)

  -- Render-markdown coordination is now checked lazily on each render call
  -- (so it can see render-markdown's config even if render-markdown is set
  -- up after nvim-tasks). No need to invoke it here.

  M._setup_commands()
  M._setup_keymaps()
  M._setup_autocmds()
end

function M._setup_commands()
  local toggle = require("nvim-tasks.toggle")
  local ui = require("nvim-tasks.ui")
  local render = require("nvim-tasks.render")
  local vault = require("nvim-tasks.vault")
  local config = require("nvim-tasks.config")

  local cmd = vim.api.nvim_create_user_command
  cmd("TasksToggleDone", function() toggle.toggle_done() end, { desc = "Toggle task done" })
  cmd("TasksCycleStatus", function() toggle.cycle_status() end, { desc = "Cycle task status" })
  cmd("TasksCreate", function() ui.create_or_edit() end, { desc = "Create/edit task (wizard)" })
  cmd("TasksSetPriority", function() ui.pick_priority() end, { desc = "Set task priority" })
  cmd("TasksSetDueDate", function() ui.prompt_date(nil, nil, "due", "Due Date") end, { desc = "Set due date" })
  cmd("TasksSetScheduled", function() ui.prompt_date(nil, nil, "scheduled", "Scheduled Date") end, { desc = "Set scheduled date" })
  cmd("TasksSetStartDate", function() ui.prompt_date(nil, nil, "start_date", "Start Date") end, { desc = "Set start date" })
  cmd("TasksSetStatus", function() ui.pick_status() end, { desc = "Pick task status" })
  cmd("TasksToggleRender", function() render.toggle() end, { desc = "Toggle query rendering" })
  cmd("TasksRender", function() render.render_buffer() end, { desc = "Render query blocks" })
  cmd("TasksClearRender", function() render.clear_buffer() end, { desc = "Clear rendered output" })
  cmd("TasksRefresh", function() vault.invalidate(); render.refresh(vim.api.nvim_get_current_buf()) end, { desc = "Refresh cache + re-render" })
  cmd("TasksIncreasePriority", function() toggle.increase_priority() end, { desc = "Increase priority" })
  cmd("TasksDecreasePriority", function() toggle.decrease_priority() end, { desc = "Decrease priority" })
  cmd("TasksSearch", function() ui.search_tasks() end, { desc = "Search vault tasks (Snacks picker)" })
  cmd("TasksQuery", function(args) M._run_query(args.args) end, { desc = "Run ad-hoc query", nargs = "+" })
end

function M._setup_keymaps()
  local cfg = require("nvim-tasks.config").get()
  local km = cfg.keymaps
  if not km then return end

  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("NvimTasksKeymaps", { clear = true }),
    pattern = { "markdown", "md" },
    callback = function(ev)
      local buf = ev.buf
      local function map(lhs, rhs, desc)
        if lhs and lhs ~= false then
          vim.keymap.set("n", lhs, rhs, { buffer = buf, noremap = true, silent = true, desc = desc })
        end
      end
      map(km.toggle_done, "<cmd>TasksToggleDone<cr>", "Tasks: Toggle Done")
      map(km.toggle_render, "<cmd>TasksToggleRender<cr>", "Tasks: Toggle Render")
      map(km.create_task, "<cmd>TasksCreate<cr>", "Tasks: Create/Edit")
      map(km.set_priority, "<cmd>TasksSetPriority<cr>", "Tasks: Set Priority")
      map(km.set_due_date, "<cmd>TasksSetDueDate<cr>", "Tasks: Set Due Date")
      map(km.set_scheduled, "<cmd>TasksSetScheduled<cr>", "Tasks: Set Scheduled")
      map(km.set_start_date, "<cmd>TasksSetStartDate<cr>", "Tasks: Set Start Date")
      map(km.cycle_status, "<cmd>TasksCycleStatus<cr>", "Tasks: Cycle Status")
      map(km.increase_priority, "<cmd>TasksIncreasePriority<cr>", "Tasks: Increase Priority")
      map(km.decrease_priority, "<cmd>TasksDecreasePriority<cr>", "Tasks: Decrease Priority")
      map(km.search_tasks, "<cmd>TasksSearch<cr>", "Tasks: Search Vault")
    end,
  })
end

function M._setup_autocmds()
  local config = require("nvim-tasks.config")
  local render = require("nvim-tasks.render")
  local vault = require("nvim-tasks.vault")
  local group = vim.api.nvim_create_augroup("NvimTasksRender", { clear = true })

  if config.get().render_on_load then
    vim.api.nvim_create_autocmd({ "BufRead", "BufEnter" }, {
      group = group, pattern = "*.md",
      callback = function(ev)
        vim.defer_fn(function()
          if not vim.api.nvim_buf_is_valid(ev.buf) then return end
          for _, l in ipairs(vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)) do
            if l:match("^%s*```tasks") then render.render_buffer(ev.buf); return end
          end
        end, 100)
      end,
    })
  end

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group, pattern = "*.md",
    callback = function(ev)
      vault.invalidate()
      if render.is_rendered(ev.buf) then
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then render.render_buffer(ev.buf) end
        end, 50)
      end
    end,
  })
end

function M._run_query(query_str)
  local query = require("nvim-tasks.query")
  local vault = require("nvim-tasks.vault")
  local task_mod = require("nvim-tasks.task")
  local config = require("nvim-tasks.config")
  vault.invalidate()
  local lines = vim.split(query_str, ";")
  local result = query.run(lines)
  local e = config.get().emojis
  local output = {}
  for _, err in ipairs(result.error_messages) do table.insert(output, "⚠ " .. err) end
  table.insert(output, string.format("── %d task%s found ──", result.total_count, result.total_count == 1 and "" or "s"))
  table.insert(output, "")
  for _, grp in ipairs(result.groups) do
    if grp.heading then table.insert(output, "### " .. grp.heading) end
    for _, t in ipairs(grp.tasks) do
      local p = { task_mod.is_done(t) and "- [x]" or "- [ ]", t.description }
      if t.priority then local em = e[t.priority]; if em then table.insert(p, em) end end
      if t.due then table.insert(p, e.due .. " " .. t.due) end
      if t.file_path then table.insert(p, "(" .. vim.fn.fnamemodify(t.file_path, ":t:r") .. ")") end
      table.insert(output, table.concat(p, " "))
    end
    table.insert(output, "")
  end
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"; vim.bo[buf].bufhidden = "wipe"; vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, output); vim.bo[buf].modifiable = false
end

return M
