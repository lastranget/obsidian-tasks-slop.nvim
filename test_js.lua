-- Pure-Lua tests for the custom-function (`... by function`) pipeline.
--
-- These exercise everything EXCEPT the external JS engine itself: sentinel
-- parsing, task serialization, group `reverse` / multi-group expansion, and the
-- batched query.execute integration (with the engine stubbed). The harness's
-- own JS logic is tested separately in js/harness.test.mjs.
--
-- Run: lua test_js.lua

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

-- `sort.lua` requires LuaJIT's `bit`; shim it with Lua 5.4 native bitwise ops.
package.preload["bit"] = function()
  return {
    bxor = function(a, b) return a ~ b end,
    band = function(a, b) return a & b end,
    rshift = function(a, b) return a >> b end,
  }
end

-- `query` requires `vault`, which requires plenary. We always pass tasks
-- explicitly (so vault.scan is never called), so a benign stub suffices.
package.preload["plenary.scandir"] = function() return { scan_dir = function() return {} end } end
package.preload["plenary.job"] = function() return {} end
package.preload["plenary.path"] = function() return {} end

_G.vim = {
  trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
  pesc = function(s) return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")) end,
  NIL = setmetatable({}, { __tostring = function() return "vim.NIL" end }),
  deepcopy = function(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = _G.vim.deepcopy(v) end
    return c
  end,
  tbl_deep_extend = function(_b, dst, src)
    for k, v in pairs(src or {}) do
      if type(v) == "table" and type(dst[k]) == "table" then
        dst[k] = _G.vim.tbl_deep_extend(_b, dst[k], v)
      else dst[k] = v end
    end
    return dst
  end,
  list_extend = function(dst, src)
    for _, v in ipairs(src or {}) do table.insert(dst, v) end
    return dst
  end,
  split = function(s, sep, opts)
    local plain = opts and opts.plain
    local out = {}
    local i = 1
    while true do
      local a, b = s:find(sep, i, plain)
      if not a then table.insert(out, s:sub(i)); break end
      table.insert(out, s:sub(i, a - 1)); i = b + 1
    end
    return out
  end,
  fn = {
    getcwd = function() return "/tmp" end,
    fnamemodify = function(path, mods)
      if mods == ":t" then return path:match("([^/]+)$") or path end
      if mods == ":h" then return path:match("(.+)/[^/]+$") or path end
      if mods == ":t:r" then
        local base = path:match("([^/]+)$") or path
        return base:match("(.+)%..+$") or base
      end
      return path
    end,
    executable = function() return 0 end,
  },
}

local config = require("nvim-tasks.config")
local filter = require("nvim-tasks.filter")
local sort   = require("nvim-tasks.sort")
local group  = require("nvim-tasks.group")
local js     = require("nvim-tasks.js")
local query  = require("nvim-tasks.query")

local passed, failed = 0, 0
local function check(name, got, want)
  if got == want then
    passed = passed + 1; print("PASS " .. name)
  else
    failed = failed + 1
    print(("FAIL %s: got %s, want %s"):format(name, tostring(got), tostring(want)))
  end
end

local function task(o)
  local t = {
    raw = "- [ ] x", indent = "", list_marker = "- ", status_symbol = " ",
    description = "", priority = nil, due = nil, scheduled = nil, start_date = nil,
    created = nil, done_date = nil, cancelled_date = nil, recurrence = nil,
    id = nil, depends_on = {}, tags = {}, file_path = nil, line_number = 0,
    preceding_header = nil,
  }
  for k, v in pairs(o or {}) do t[k] = v end
  return t
end

-- ---------------------------------------------------------------------------
-- 1. Sentinel parsing
-- ---------------------------------------------------------------------------
do
  local f = filter.parse_filter("filter by function task.tags.length > 1")
  check("filter sentinel kind", type(f) == "table" and f.__js, "filter")
  check("filter sentinel expr (case preserved)", f and f.expr, "task.tags.length > 1")

  local s = sort.parse_sorter("sort by function task.urgency")
  check("sort sentinel kind", type(s) == "table" and s.__js, "sort")
  check("sort sentinel not reversed", s and s.reverse, false)

  local sr = sort.parse_sorter("sort by function reverse task.urgency")
  check("sort sentinel reverse expr", sr and sr.expr, "task.urgency")
  check("sort sentinel reverse flag", sr and sr.reverse, true)

  local g = group.parse_grouper("group by function task.file.folder")
  check("group sentinel kind", type(g) == "table" and g.__js, "group")
  check("group sentinel expr", g and g.expr, "task.file.folder")

  local gr = group.parse_grouper("group by function reverse task.priorityNumber")
  check("group sentinel reverse expr", gr and gr.expr, "task.priorityNumber")
  check("group sentinel reverse flag", gr and gr.reverse, true)

  -- Case sensitivity: JS identifiers must survive verbatim.
  local fc = filter.parse_filter("filter by function task.descriptionWithoutTags.includes('X')")
  check("filter sentinel preserves camelCase + arg case",
    fc and fc.expr, "task.descriptionWithoutTags.includes('X')")
end

-- ---------------------------------------------------------------------------
-- 2. group by reverse (built-in, non-JS) + multi-grouper nesting
-- ---------------------------------------------------------------------------
do
  local spec = group.parse_grouper("group by priority reverse")
  check("group reverse: spec is not a sentinel", spec.__js, nil)
  check("group reverse: flag set", spec.reverse, true)

  -- Tasks appear in insertion order high, low. Forward → [high, low]; reverse → [low, high].
  local tasks = { task{ priority = "high", description = "a" }, task{ priority = "low", description = "b" } }
  local fwd = group.apply(tasks, { group.parse_grouper("group by priority") })
  check("group forward order [1]", fwd[1].heading, "Priority: high")
  check("group forward order [2]", fwd[2].heading, "Priority: low")

  local rev = group.apply(tasks, { spec })
  check("group reverse order [1]", rev[1].heading, "Priority: low")
  check("group reverse order [2]", rev[2].heading, "Priority: high")

  -- Single-grouper ordering is unchanged from first-appearance (no regression).
  check("single grouper count", #fwd, 2)
end

-- ---------------------------------------------------------------------------
-- 3. group.apply multi-group arrays (one task → many groups) + null → omitted
-- ---------------------------------------------------------------------------
do
  -- Simulate a resolved JS grouper whose fn returns a list of headings.
  local t1 = task{ description = "multi" }
  local t2 = task{ description = "single" }
  local t3 = task{ description = "none" }
  local grouper = {
    reverse = false,
    fn = function(t)
      if t.description == "multi" then return { "A", "B" } end
      if t.description == "single" then return { "A" } end
      return {} -- null group → omitted
    end,
  }
  local groups = group.apply({ t1, t2, t3 }, { grouper })
  -- Groups A and B. A has t1 + t2; B has t1.
  local byname = {}
  for _, g in ipairs(groups) do byname[g.heading] = g end
  check("multi-group: group A exists", byname["A"] ~= nil, true)
  check("multi-group: group B exists", byname["B"] ~= nil, true)
  check("multi-group: A has 2 tasks", byname["A"] and #byname["A"].tasks, 2)
  check("multi-group: B has 1 task", byname["B"] and #byname["B"].tasks, 1)
  check("multi-group: t3 omitted (no extra group)", #groups, 2)
end

-- ---------------------------------------------------------------------------
-- 4. Task serialization surface
-- ---------------------------------------------------------------------------
do
  config.setup({ vault_paths = { "/vault" } })
  local t = task{
    description = "Email boss #work #urgent",
    priority = "high",
    due = "2026-06-15",
    tags = { "#work", "#urgent" },
    id = "abc",
    file_path = "/vault/Work/Projects/plan.md",
    preceding_header = "Tasks",
    status_symbol = "/",
    list_marker = "- ",
    line_number = 4,
  }
  local s = js.serialize_task(t)
  check("serialize: priorityName", s.priorityName, "High")
  check("serialize: priorityNumber", s.priorityNumber, 1)
  check("serialize: descriptionWithoutTags", s.descriptionWithoutTags, "Email boss")
  check("serialize: due iso passthrough", s.due, "2026-06-15")
  check("serialize: status.type", s.status.type, "IN_PROGRESS")
  check("serialize: status.name", s.status.name, "In Progress")
  check("serialize: file.path is vault-relative", s.file.path, "Work/Projects/plan.md")
  check("serialize: file.filename", s.file.filename, "plan.md")
  check("serialize: file.filenameWithoutExtension", s.file.filenameWithoutExtension, "plan")
  check("serialize: file.folder", s.file.folder, "Work/Projects/")
  check("serialize: file.root", s.file.root, "Work/")
  check("serialize: heading", s.heading, "Tasks")
  check("serialize: hasHeading", s.hasHeading, true)
  check("serialize: listMarker trimmed", s.listMarker, "-")
  check("serialize: isDone false for in-progress", s.isDone, false)
  config.setup({}) -- reset
end

-- ---------------------------------------------------------------------------
-- 5. query.execute integration with a stubbed engine
-- ---------------------------------------------------------------------------
-- Stub the engine: evaluate each instruction's expr against an in-test table of
-- behaviors, so we test the Lua plumbing (memo, indexing, degradation) without
-- a real JS engine.
local TESTFN = {}
local function with_engine(available, fn)
  local orig_av, orig_ev = js.available, js.evaluate
  js.available = function() return available end
  js.evaluate = function(instructions, tasks, _ctx)
    local results = {}
    for _, ins in ipairs(instructions) do
      local impl = TESTFN[ins.expr]
      local arr = {}
      for i, t in ipairs(tasks) do arr[i] = impl(t) end
      results[ins.id] = arr
    end
    return results, {}
  end
  local okp, err = pcall(fn)
  js.available, js.evaluate = orig_av, orig_ev
  if not okp then error(err) end
end

-- filter by function
do
  TESTFN["task.priorityNumber === 1"] = function(t) return t.priority == "high" end
  local tasks = {
    task{ description = "a", priority = "high", status_symbol = " " },
    task{ description = "b", priority = "low", status_symbol = " " },
    task{ description = "c", priority = "high", status_symbol = " " },
  }
  with_engine(true, function()
    local r = query.run({ "filter by function task.priorityNumber === 1" }, tasks, {})
    check("js filter: total_count", r.total_count, 2)
    check("js filter: no errors", #r.error_messages, 0)
  end)
end

-- sort by function (+ reverse)
do
  TESTFN["task.urgency"] = function(t) return t.__key end
  local tasks = {
    task{ description = "mid", status_symbol = " " }, -- key 2
    task{ description = "low", status_symbol = " " }, -- key 1
    task{ description = "high", status_symbol = " " }, -- key 3
  }
  tasks[1].__key = 2; tasks[2].__key = 1; tasks[3].__key = 3
  with_engine(true, function()
    local r = query.run({ "sort by function task.urgency" }, tasks, {})
    local g = r.groups[1].tasks
    check("js sort asc [1]", g[1].description, "low")
    check("js sort asc [2]", g[2].description, "mid")
    check("js sort asc [3]", g[3].description, "high")

    local rr = query.run({ "sort by function reverse task.urgency" }, tasks, {})
    local gr = rr.groups[1].tasks
    check("js sort reverse [1]", gr[1].description, "high")
    check("js sort reverse [3]", gr[3].description, "low")
  end)
end

-- group by function (single + multi-group array)
do
  TESTFN["task.status.type"] = function(t) return ({ [" "] = "TODO", x = "DONE" })[t.status_symbol] end
  TESTFN["task.tags"] = function(t) return t.tags end
  local tasks = {
    task{ description = "a", status_symbol = " " },
    task{ description = "b", status_symbol = "x" },
    task{ description = "c", status_symbol = " " },
  }
  with_engine(true, function()
    local r = query.run({ "group by function task.status.type" }, tasks, {})
    local byname = {}
    for _, gg in ipairs(r.groups) do byname[gg.heading] = #gg.tasks end
    check("js group: TODO count", byname["TODO"], 2)
    check("js group: DONE count", byname["DONE"], 1)
  end)

  local mtasks = {
    task{ description = "x", tags = { "#a", "#b" }, status_symbol = " " },
    task{ description = "y", tags = { "#a" }, status_symbol = " " },
  }
  with_engine(true, function()
    local r = query.run({ "group by function task.tags" }, mtasks, {})
    local byname = {}
    for _, gg in ipairs(r.groups) do byname[gg.heading] = #gg.tasks end
    check("js group multi: #a has 2", byname["#a"], 2)
    check("js group multi: #b has 1", byname["#b"], 1)
  end)
end

-- graceful degradation when no engine
do
  TESTFN["task.priorityNumber === 1"] = function(t) return t.priority == "high" end
  local tasks = {
    task{ description = "a", priority = "high", status_symbol = " " },
    task{ description = "b", priority = "low", status_symbol = " " },
  }
  with_engine(false, function()
    local r = query.run({ "filter by function task.priorityNumber === 1" }, tasks, {})
    check("degrade: filter matches nothing", r.total_count, 0)
    check("degrade: error recorded", #r.error_messages >= 1, true)
    check("degrade: warns to install an engine",
      r.error_messages[1]:find("JavaScript", 1, true) ~= nil, true)
  end)

  -- Scoping: a query WITHOUT any `… by function` instruction must NOT emit the
  -- engine warning, even when no engine is installed (the engine is never
  -- consulted). This is the "only warn when JS would actually be used" rule.
  with_engine(false, function()
    local r = query.run({ "not done", "sort by priority" }, tasks, {})
    check("scoping: no engine warning for non-JS query", #r.error_messages, 0)
    check("scoping: non-JS query still returns tasks", r.total_count >= 1, true)
  end)
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
