--- nvim-tasks.lib — editor-independent library facade.
---
--- This is the supported entry point for using the query engine OUTSIDE the
--- interactive plugin: headless `nvim -l` scripts, status lines, cron jobs,
--- dashboards, etc. It touches only the engine modules (config, task, vault,
--- query) — never render/toggle/ui — so it needs plenary but NOT snacks, and
--- never registers commands, keymaps, or autocmds.
---
--- It does not call `require("nvim-tasks").setup()`; requiring this module has
--- no effect on the interactive plugin, and vice versa.
---
--- Typical headless use:
---
---   vim.opt.runtimepath:prepend(plugin_dir)   -- and plenary's dir
---   vim.opt.runtimepath:prepend(plenary_dir)
---   local lib = require("nvim-tasks.lib").setup({ vault_paths = { vault } })
---   local lines = vim.fn.readfile(note)
---   local first = lib.find_blocks(lines)[1]
---   local count = lib.count(first.query_lines)               -- one scan
---   local hits  = lib.tasks("(path includes x) AND (tag includes #y)")
---
--- All functions accept a query as either a list of instruction lines or a
--- single string (split on newlines). `opts` is optional everywhere:
---   opts.tasks       — pre-scanned task list to query against (avoids re-scan)
---   opts.file_path   — value exposed to `query.file.*` placeholders / ctx
---   opts.force_scan  — pass true to bypass vault.scan's cache

local M = {}

--- Configure the engine (vault root(s), statuses, emojis, …). Same options as
--- `require("nvim-tasks").setup`, but without the editor wiring. Returns M for
--- chaining.
function M.setup(opts)
  require("nvim-tasks.config").setup(opts)
  return M
end

--- Synchronous full-vault scan. Returns the list of parsed task objects. Cached
--- per process; pass `force = true` to rescan.
function M.scan(force)
  return require("nvim-tasks.vault").scan(force)
end

--- Locate ```tasks blocks. `source` may be a buffer number or a list of lines.
--- Returns blocks in document order: `{ { start, finish, query_lines }, … }`
--- (index 1 is the first block).
function M.find_blocks(source)
  local task = require("nvim-tasks.task")
  if type(source) == "number" then
    return task.find_query_blocks(source)
  end
  return task.find_query_blocks_in_lines(source)
end

local function to_lines(query)
  if type(query) == "table" then return query end
  return vim.split(query, "\n", { plain = true })
end

--- Run a query. Returns the raw engine result:
---   `{ groups, total_count, error_messages, query }`
--- `total_count` is the number of matching tasks (the figure the rendered
--- "*── N tasks ──*" banner shows).
function M.run(query, opts)
  opts = opts or {}
  local tasks = opts.tasks or M.scan(opts.force_scan)
  return require("nvim-tasks.query").run(to_lines(query), tasks, { file_path = opts.file_path })
end

--- Convenience: number of tasks matching `query`.
function M.count(query, opts)
  return M.run(query, opts).total_count
end

--- Convenience: flat, de-duplicated list of the task objects matching `query`
--- (in the query's sort order). Grouping is flattened; a task that would appear
--- under multiple group headings is returned once. Also returns the raw result
--- as a second value.
function M.tasks(query, opts)
  local result = M.run(query, opts)
  local out, seen = {}, {}
  for _, grp in ipairs(result.groups) do
    for _, t in ipairs(grp.tasks) do
      local key = (t.file_path or "") .. "\0" .. tostring(t.line_number or "")
      if not seen[key] then
        seen[key] = true
        table.insert(out, t)
      end
    end
  end
  return out, result
end

return M
