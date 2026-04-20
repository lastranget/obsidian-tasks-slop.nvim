--- Vault scanning via plenary.nvim.
---
--- Two scan modes:
---   * `M.scan(force)` — synchronous, uses `plenary.scandir` (fast C-loop scan
---     that respects .gitignore). This is the default path for `query.execute`.
---   * `M.scan_async(on_done)` — uses `rg --files` under `plenary.job`. Faster
---     than scandir on very large vaults (10k+ files) and non-blocking, but
---     needs ripgrep installed. Not wired into the default render pipeline;
---     exposed for callers who want it.
local config = require("nvim-tasks.config")
local task_mod = require("nvim-tasks.task")
local scandir = require("plenary.scandir")
local Job = require("plenary.job")
local Path = require("plenary.path")

local M = {}
M._cache = {}
M._cache_valid = false

-- Portable path join: use vim.fs.joinpath when available (Neovim 0.10+),
-- fall back to a manual join otherwise. Skips adding a separator if the
-- first part already ends with one, which matters on Windows and for paths
-- resolved from config that may or may not carry trailing slashes.
local function joinpath(a, b)
  if vim.fs and vim.fs.joinpath then return vim.fs.joinpath(a, b) end
  local last = a:sub(-1)
  if last == "/" or last == "\\" then return a .. b end
  return a .. "/" .. b
end

--- Find all markdown files using plenary.scandir (fast, respects gitignore patterns).
function M.find_files(paths)
  local files = {}
  for _, root in ipairs(paths) do
    local expanded = Path:new(vim.fn.expand(root)):absolute()
    local found = scandir.scan_dir(expanded, {
      hidden = false,
      depth = 20,
      search_pattern = "%.md$",
      respect_gitignore = true,
      silent = true,
    })
    vim.list_extend(files, found)
  end
  return files
end

--- Faster alternative: find files via ripgrep (non-blocking).
--- Returns immediately; calls on_done(files) when complete.
function M.find_files_rg(paths, on_done)
  local files = {}
  local pending = #paths
  if pending == 0 then on_done(files); return end

  for _, root in ipairs(paths) do
    local expanded = Path:new(vim.fn.expand(root)):absolute()
    Job:new({
      command = "rg",
      args = { "--files", "--glob", "*.md", "--no-hidden" },
      cwd = expanded,
      on_stdout = function(_, line)
        if line and line ~= "" then
          table.insert(files, joinpath(expanded, line))
        end
      end,
      on_exit = function()
        pending = pending - 1
        if pending == 0 then
          vim.schedule(function() on_done(files) end)
        end
      end,
    }):start()
  end
end

--- Parse all tasks from a file, tracking headings and skipping fenced code
--- blocks (including tasks query blocks).
function M.parse_file(file_path)
  local tasks = {}
  local p = Path:new(file_path)
  if not p:exists() then return tasks end
  local ok, lines = pcall(function() return p:readlines() end)
  if not ok or not lines then return tasks end

  local in_code_block = false
  local current_heading = nil
  for i, line in ipairs(lines) do
    if line:match("^%s*```") then in_code_block = not in_code_block end
    if not in_code_block then
      local heading = line:match("^#+%s+(.+)")
      if heading then current_heading = vim.trim(heading) end
      local t = task_mod.parse(line, file_path, i, current_heading)
      if t then table.insert(tasks, t) end
    end
  end
  return tasks
end

--- Scan all vault files synchronously (cached).
function M.scan(force)
  if M._cache_valid and not force then return M._cache end
  local paths = config.resolve_vault_paths()
  local files = M.find_files(paths)
  local all = {}
  for _, f in ipairs(files) do
    for _, t in ipairs(M.parse_file(f)) do table.insert(all, t) end
  end
  M._cache = all; M._cache_valid = true; return all
end

--- Async scan using ripgrep. Calls on_done(tasks) when complete.
function M.scan_async(on_done)
  local paths = config.resolve_vault_paths()
  M.find_files_rg(paths, function(files)
    local all = {}
    for _, f in ipairs(files) do
      for _, t in ipairs(M.parse_file(f)) do table.insert(all, t) end
    end
    M._cache = all; M._cache_valid = true
    on_done(all)
  end)
end

function M.invalidate() M._cache_valid = false end

function M.parse_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local tasks, in_code, heading = {}, false, nil
  for i, line in ipairs(lines) do
    if line:match("^%s*```") then in_code = not in_code end
    if not in_code then
      local h = line:match("^#+%s+(.+)")
      if h then heading = vim.trim(h) end
      local t = task_mod.parse(line, file_path, i, heading)
      if t then table.insert(tasks, t) end
    end
  end
  return tasks
end
return M
