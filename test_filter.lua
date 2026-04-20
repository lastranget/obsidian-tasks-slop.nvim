-- Integration test for the rewritten filter.lua.
-- Stubs plenary.nvim (not used by filter.lua) and mocks the vim global.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

-- Minimal vim global so the plugin loads under plain Lua.
_G.vim = {
  trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
  pesc = function(s)
    return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
  end,
  deepcopy = function(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = _G.vim.deepcopy(v) end
    return c
  end,
  tbl_deep_extend = function(_behavior, dst, src)
    for k, v in pairs(src or {}) do
      if type(v) == "table" and type(dst[k]) == "table" then
        dst[k] = _G.vim.tbl_deep_extend(_behavior, dst[k], v)
      else
        dst[k] = v
      end
    end
    return dst
  end,
  split = function(s, sep)
    local out = {}
    local pat = "([^" .. sep:sub(1, 1) .. "]+)"
    for w in s:gmatch(pat) do table.insert(out, w) end
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
  },
}

-- Silence require of 'plenary.*' by making it load benign stubs.
-- (filter.lua doesn't use plenary, but task.lua doesn't either.)

local filter = require("nvim-tasks.filter")

-- Build a test task. Unset fields stay nil.
local function task(overrides)
  local t = {
    description = "",
    priority = nil,
    due = nil, scheduled = nil, start_date = nil,
    created = nil, done_date = nil, cancelled_date = nil,
    recurrence = nil, id = nil, depends_on = {}, tags = {},
    status_symbol = " ",
    file_path = nil, line_number = nil, preceding_header = nil,
  }
  for k, v in pairs(overrides or {}) do t[k] = v end
  return t
end

local function eval(line, t, all)
  local f = filter.parse_filter(line)
  assert(f, "parse failed for: " .. line)
  return f(t, all or { t })
end

local passed, failed = 0, 0
local function check(name, got, want)
  if got == want then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print(("FAIL %s: got %s, want %s"):format(name, tostring(got), tostring(want)))
  end
end

-- ---------------------------------------------------------------------------
-- Priority
-- ---------------------------------------------------------------------------
check("priority is high (match)",         eval("priority is high", task{priority="high"}),      true)
check("priority is high (miss)",          eval("priority is high", task{priority="medium"}),    false)
check("priority high (no 'is')",          eval("priority high", task{priority="high"}),         true)
check("priority is above high",           eval("priority is above high", task{priority="highest"}), true)
check("priority above high",              eval("priority above high", task{priority="highest"}), true)
check("priority is above high (miss)",    eval("priority is above high", task{priority="high"}), false)
check("priority is below medium",         eval("priority is below medium", task{priority="low"}),true)
check("priority below medium",            eval("priority below medium", task{priority="low"}),   true)
check("priority not low",                 eval("priority not low", task{priority="high"}),       true)
check("priority is not low",              eval("priority is not low", task{priority="low"}),     false)
check("priority is none (unset)",         eval("priority is none", task{}),                      true)
check("priority is none (set)",           eval("priority is none", task{priority="high"}),       false)
check("has priority",                     eval("has priority", task{priority="high"}),           true)
check("no priority",                      eval("no priority", task{}),                           true)

-- ---------------------------------------------------------------------------
-- Dates (verify starts-missing-default and happens-any-of)
-- ---------------------------------------------------------------------------
-- Pick a far-future "target" so comparisons are deterministic regardless of today.
check("starts before 2030-01-01 (missing -> true)", eval("starts before 2030-01-01", task{}), true)
check("due before 2030-01-01 (missing -> false)",   eval("due before 2030-01-01", task{}), false)
check("starts before 2030-01-01 (present, earlier)",
  eval("starts before 2030-01-01", task{start_date="2020-01-01"}), true)
check("starts before 2030-01-01 (present, later)",
  eval("starts before 2030-01-01", task{start_date="2099-01-01"}), false)

-- happens: any of due/scheduled/start
check("happens before 2030-01-01 (due earlier)",
  eval("happens before 2030-01-01", task{due="2020-01-01"}), true)
check("happens before 2030-01-01 (scheduled earlier, others nil)",
  eval("happens before 2030-01-01", task{scheduled="2020-01-01"}), true)
check("happens before 2030-01-01 (start_date earlier, others nil)",
  eval("happens before 2030-01-01", task{start_date="2020-01-01"}), true)
check("happens before 2030-01-01 (all later)",
  eval("happens before 2030-01-01", task{due="2099-01-01", scheduled="2099-01-01", start_date="2099-01-01"}), false)
check("happens before 2030-01-01 (all missing)",
  eval("happens before 2030-01-01", task{}), false)

-- ---------------------------------------------------------------------------
-- Regex with flags
-- ---------------------------------------------------------------------------
check("regex case-sensitive match",
  eval("description regex matches /^Foo/", task{description="Foo bar"}), true)
check("regex case-sensitive miss",
  eval("description regex matches /^Foo/", task{description="foo bar"}), false)
check("regex case-insensitive match via /i",
  eval("description regex matches /^foo/i", task{description="Foo bar"}), true)
check("regex does not match case-insensitive",
  eval("description regex does not match /^bar/i", task{description="Foo bar"}), true)

-- ---------------------------------------------------------------------------
-- Text filters
-- ---------------------------------------------------------------------------
check("description includes substring",
  eval("description includes milk", task{description="Buy milk"}), true)
check("description does not include",
  eval("description does not include wine", task{description="Buy milk"}), true)
check("description includes case-insensitive",
  eval("description includes MILK", task{description="Buy milk"}), true)

-- ---------------------------------------------------------------------------
-- Tags
-- ---------------------------------------------------------------------------
check("has tags",      eval("has tags", task{tags={"#a"}}),                true)
check("no tags",       eval("no tags", task{}),                            true)
check("tag includes",  eval("tag includes urgent", task{tags={"#urgent"}}), true)
check("tags include",  eval("tags include urgent", task{tags={"#urgent"}}), true)
check("tag does not include",
  eval("tag does not include urgent", task{tags={"#chill"}}), true)

-- ---------------------------------------------------------------------------
-- Boolean expressions
-- ---------------------------------------------------------------------------
check("boolean AND",
  eval("(priority is high) AND (has tags)",
    task{priority="high", tags={"#a"}}), true)
check("boolean AND (one miss)",
  eval("(priority is high) AND (has tags)",
    task{priority="high"}), false)
check("boolean OR",
  eval("(priority is high) OR (has tags)",
    task{tags={"#a"}}), true)
check("boolean AND NOT",
  eval("(priority is high) AND NOT (has tags)",
    task{priority="high"}), true)
check("boolean NOT prefix",
  eval("NOT (priority is high)",
    task{priority="low"}), true)
check("boolean chained (a) AND (b) AND (c)",
  eval("(priority is high) AND (has tags) AND (has priority)",
    task{priority="high", tags={"#x"}}), true)
check("boolean nested ((a) OR (b)) AND (c)",
  eval("((priority is high) OR (priority is medium)) AND (has tags)",
    task{priority="medium", tags={"#x"}}), true)
check("boolean chained OR with miss",
  eval("(priority is high) OR (priority is low)",
    task{priority="medium"}), false)
check("boolean double NOT",
  eval("NOT NOT (priority is high)",
    task{priority="high"}), true)

-- ---------------------------------------------------------------------------
-- Basic recurring / exclude sub-items / done
-- ---------------------------------------------------------------------------
check("is recurring",     eval("is recurring", task{recurrence="every week"}), true)
check("is not recurring", eval("is not recurring", task{}),                    true)
check("exclude sub-items (top-level)",
  eval("exclude sub-items", task{indent=""}),   true)
check("exclude sub-items (indented)",
  eval("exclude sub-items", task{indent="  "}), false)

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------
check("status.type is TODO (default symbol ' ')",
  eval("status.type is TODO", task{status_symbol=" "}), true)
check("status.type is DONE (symbol 'x')",
  eval("status.type is DONE", task{status_symbol="x"}), true)
check("status.type is not DONE (symbol ' ')",
  eval("status.type is not DONE", task{status_symbol=" "}), true)
check("done (symbol 'x')",     eval("done", task{status_symbol="x"}),     true)
check("not done (symbol ' ')", eval("not done", task{status_symbol=" "}), true)

-- ---------------------------------------------------------------------------
-- Blocking
-- ---------------------------------------------------------------------------
local t_a = task{id="a", status_symbol=" "}
local t_b = task{id="b", status_symbol=" ", depends_on={"a"}}
local t_b_done = task{id="b", status_symbol="x", depends_on={"a"}}
local all1 = {t_a, t_b}
local all2 = {t_a, t_b_done}
check("is blocking (a blocks b)",     eval("is blocking", t_a, all1), true)
check("is not blocking (b done)",     eval("is blocking", t_a, all2), false)
check("is blocked (b depends on a)",  eval("is blocked", t_b, all1), true)

-- ---------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
