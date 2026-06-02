--- Custom-function (`... by function`) support via an external JS engine.
---
--- The official Obsidian Tasks plugin evaluates `filter/sort/group by function`
--- expressions with the browser/Electron JavaScript engine (`new Function(...)`,
--- see obsidian-tasks `src/Scripting/Expression.ts`). Neovim has no JS engine,
--- so we shell out to one — Deno by default (a single sandboxed binary), with
--- Node and Bun also supported — running `js/harness.mjs`.
---
--- Design:
---   * One batched invocation per query block: all candidate tasks plus all
---     function expressions go to the engine at once, and per-task result arrays
---     come back. No per-task process spawning.
---   * Graceful degradation: if no engine is available, only `... by function`
---     instructions fail (with a clear message). Every other query is unaffected
---     because this module is only consulted when such an instruction is present.
---   * Safety: under Deno with no permission flags the harness cannot read files,
---     hit the network, or spawn processes, so expressions from notes are
---     contained by construction.
local config = require("nvim-tasks.config")
local task_mod = require("nvim-tasks.task")

local M = {}

-- Candidate engines in auto-detect priority order. Deno first for its sandbox.
local ENGINES = {
  deno = { "run", "-q", "--no-config" },
  bun  = {},
  node = {},
}
local AUTO_ORDER = { "deno", "bun", "node" }

-- ---------------------------------------------------------------------------
-- Engine discovery (cached). Override with config.js_engine = "node" etc.
-- ---------------------------------------------------------------------------

local _engine_cache = nil
local _engine_resolved = false

--- Return the absolute path to the bundled harness, derived from this file's
--- own location so it works regardless of where the plugin is installed.
function M.harness_path()
  local cfg = config.get()
  if cfg.js_harness_path and cfg.js_harness_path ~= "" then return cfg.js_harness_path end
  local src = debug.getinfo(1, "S").source:sub(2) -- strip leading '@'
  local root = src:gsub("[/\\]lua[/\\]nvim%-tasks[/\\]js%.lua$", "")
  return root .. "/js/harness.mjs"
end

local function executable(name)
  if vim and vim.fn and vim.fn.executable then
    return vim.fn.executable(name) == 1
  end
  return false
end

--- Resolve `{ name, cmd }` where cmd is the argv prefix (engine + run flags),
--- to which the harness path and then runtime args are appended. Returns nil
--- if no engine is available. Cached after first call.
function M.engine()
  if _engine_resolved then return _engine_cache end
  _engine_resolved = true
  local cfg = config.get()
  local function build(name)
    local flags = ENGINES[name]
    if not flags then flags = {} end
    local cmd = { name }
    for _, f in ipairs(flags) do cmd[#cmd + 1] = f end
    cmd[#cmd + 1] = M.harness_path()
    return { name = name, cmd = cmd }
  end
  if cfg.js_engine and cfg.js_engine ~= "" then
    if executable(cfg.js_engine) then
      _engine_cache = build(cfg.js_engine)
    end
    return _engine_cache
  end
  for _, name in ipairs(AUTO_ORDER) do
    if executable(name) then
      _engine_cache = build(name)
      return _engine_cache
    end
  end
  return nil
end

function M.available()
  return M.engine() ~= nil
end

--- Test hook: reset cached engine resolution.
function M._reset()
  _engine_cache = nil
  _engine_resolved = false
end

-- ---------------------------------------------------------------------------
-- Task serialization. We pre-compute the documented `task.*` property surface
-- in Lua (reusing existing helpers) so the harness can stay thin: scalars and
-- arrays are used as-is by JS, and only date fields get wrapped engine-side.
-- ---------------------------------------------------------------------------

local TAG_CLASS = "#[^%s!@#$%%^&*(),.?\":{}|<>]+"

local function description_without_tags(desc)
  if not desc or desc == "" then return desc or "" end
  local out = (" " .. desc):gsub("%s" .. TAG_CLASS, "")
  return vim.trim(out)
end

local function priority_number(task)
  return config.get().priority_order[task.priority or "none"] or 3
end

local function priority_name(task)
  local p = task.priority
  if not p or p == "none" then return "Normal" end
  return p:sub(1, 1):upper() .. p:sub(2)
end

-- Strip a configured vault_paths prefix to get the vault-relative path, matching
-- obsidian-tasks' `task.file.path` (which is vault-relative).
local function vault_relative(path)
  if not path then return nil end
  for _, vp in ipairs(config.get().vault_paths or {}) do
    local prefix = vp
    if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
    if path:sub(1, #prefix) == prefix then return path:sub(#prefix + 1) end
  end
  return path
end

local function file_object(path)
  local rel = vault_relative(path)
  if not rel or rel == "" then
    return { path = "", filename = "", filenameWithoutExtension = "",
      folder = "/", root = "/", pathWithoutExtension = "" }
  end
  local filename = rel:match("[^/]+$") or rel
  local without_ext = filename:gsub("%.md$", "")
  local folder = rel:match("^(.*)/[^/]+$")
  folder = folder and (folder .. "/") or "/"
  local parts = vim.split(rel, "/", { plain = true })
  local root = (#parts > 1) and (parts[1] .. "/") or "/"
  local path_without_ext = rel:gsub("%.md$", "")
  return {
    path = rel,
    filename = filename,
    filenameWithoutExtension = without_ext,
    folder = folder,
    root = root,
    pathWithoutExtension = path_without_ext,
  }
end

--- Build the plain JSON-able object the harness wraps into a task.
function M.serialize_task(task)
  local heading = (task.preceding_header and task.preceding_header ~= "") and task.preceding_header or nil
  return {
    description = task.description or "",
    descriptionWithoutTags = description_without_tags(task.description or ""),
    heading = heading,
    hasHeading = heading ~= nil,
    tags = task.tags or {},
    priorityName = priority_name(task),
    priorityNumber = priority_number(task),
    urgency = task_mod.urgency(task),
    isDone = task_mod.is_done(task),
    isRecurring = task.recurrence ~= nil,
    recurrenceRule = task.recurrence or "",
    id = task.id or "",
    dependsOn = task.depends_on or {},
    originalMarkdown = task.raw or "",
    lineNumber = task.line_number or 0,
    listMarker = vim.trim(task.list_marker or ""),
    status = {
      symbol = task.status_symbol or " ",
      name = config.status_name(task.status_symbol),
      type = config.status_type(task.status_symbol),
      nextSymbol = config.next_status(task.status_symbol),
    },
    file = file_object(task.file_path),
    -- Date fields as ISO strings (or nil); the harness wraps them in TasksDate.
    due = task.due,
    start = task.start_date,
    scheduled = task.scheduled,
    created = task.created,
    done = task.done_date,
    cancelled = task.cancelled_date,
  }
end

function M.serialize_query(query_ctx)
  query_ctx = query_ctx or {}
  return { file = file_object(query_ctx.file_path) }
end

-- ---------------------------------------------------------------------------
-- Batched evaluation.
-- ---------------------------------------------------------------------------

--- Run a JSON request table through the engine and return the decoded response
--- table, or (nil, err). Factored out so tests can stub the engine entirely.
--- Default implementation encodes to JSON, runs the harness via the engine,
--- and decodes the JSON response.
function M._run_json(request)
  local engine = M.engine()
  if not engine then return nil, "no JS engine available" end
  local payload = vim.json.encode(request)
  local out = vim.fn.system(engine.cmd, payload)
  if vim.v.shell_error ~= 0 then
    return nil, ("JS engine (%s) exited %d: %s"):format(engine.name, vim.v.shell_error, vim.trim(out or ""))
  end
  local ok, decoded = pcall(vim.json.decode, out)
  if not ok then
    return nil, "could not decode JS engine output: " .. tostring(out)
  end
  return decoded
end

--- Evaluate a list of instructions over a list of tasks.
---
--- @param instructions table  list of { id, kind, expr }
--- @param tasks table         list of task objects (Lua), evaluated in order
--- @param query_ctx table?    { file_path = ... }
--- @return table?  results map id -> per-task value array (1-indexed)
--- @return table   errors map id -> message (always a table; may be empty)
function M.evaluate(instructions, tasks, query_ctx)
  local serialized = {}
  for i, t in ipairs(tasks) do serialized[i] = M.serialize_task(t) end
  local request = {
    tasks = serialized,
    query = M.serialize_query(query_ctx),
    instructions = instructions,
  }
  local resp, err = M._run_json(request)
  if not resp then
    return nil, { _engine = err or "JS evaluation failed" }
  end
  -- vim.json.encode keys numbers as strings; normalize result/error keys to the
  -- integer instruction ids the caller used.
  local results = {}
  for _, ins in ipairs(instructions) do
    local raw = resp.results and (resp.results[tostring(ins.id)] or resp.results[ins.id])
    results[ins.id] = raw
  end
  local errors = {}
  if resp.errors then
    for _, ins in ipairs(instructions) do
      local e = resp.errors[tostring(ins.id)] or resp.errors[ins.id]
      if e then errors[ins.id] = e end
    end
    if resp.errors._fatal then errors._fatal = resp.errors._fatal end
  end
  return results, errors
end

return M
