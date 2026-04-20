-- Expanded round-trip tests for every parsed field in task.lua.
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

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
}

local task = require("nvim-tasks.task")

local passed, failed = 0, 0
local function check(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    print(("FAIL %s\n  got:  %q\n  want: %q"):format(name, tostring(got), tostring(want)))
  end
end
local function assert_parse(line, expect)
  local t = task.parse(line)
  if not t then failed = failed + 1; print("FAIL parse nil: " .. line); return end
  for k, v in pairs(expect) do check("parse " .. line .. " -> ." .. k, t[k], v) end
end
local function assert_roundtrip(line, expected)
  local t = task.parse(line)
  if not t then failed = failed + 1; print("FAIL parse nil: " .. line); return end
  local out = task.serialize(t)
  check("roundtrip: " .. line, out, expected or line)
end

-- Every single field, in isolation
assert_parse("- [ ] Task 🔺",           { priority = "highest" })
assert_parse("- [ ] Task ⏫",            { priority = "high" })
assert_parse("- [ ] Task 🔼",           { priority = "medium" })
assert_parse("- [ ] Task 🔽",           { priority = "low" })
assert_parse("- [ ] Task ⏬",            { priority = "lowest" })
assert_parse("- [ ] Task 📅 2026-01-02", { due = "2026-01-02" })
assert_parse("- [ ] Task 📆 2026-01-02", { due = "2026-01-02" })  -- alias
assert_parse("- [ ] Task 🗓 2026-01-02", { due = "2026-01-02" })  -- alias
assert_parse("- [ ] Task ⏳ 2026-01-02", { scheduled = "2026-01-02" })
assert_parse("- [ ] Task ⌛ 2026-01-02", { scheduled = "2026-01-02" })  -- alias
assert_parse("- [ ] Task 🛫 2026-01-02", { start_date = "2026-01-02" })
assert_parse("- [ ] Task ➕ 2026-01-02", { created = "2026-01-02" })
assert_parse("- [x] Task ✅ 2026-01-02", { done_date = "2026-01-02" })
assert_parse("- [-] Task ❌ 2026-01-02", { cancelled_date = "2026-01-02" })
assert_parse("- [ ] Task 🔁 every week", { recurrence = "every week" })
assert_parse("- [ ] Task 🆔 abc-123",    { id = "abc-123" })
assert_parse("- [x] Task 🏁 delete",     { on_completion = "delete" })

-- Depends-on stores a list
do
  local t = task.parse("- [ ] Task ⛔ a,b,c")
  check("depends_on count", #t.depends_on, 3)
  check("depends_on [1]",   t.depends_on[1], "a")
  check("depends_on [2]",   t.depends_on[2], "b")
  check("depends_on [3]",   t.depends_on[3], "c")
end

-- Block link
do
  local t = task.parse("- [ ] Task ^block-id-1")
  check("block_link", t.block_link, "^block-id-1")
end

-- Variant Selector 16: the strip-up-front fix means emojis with or without
-- VS16 now parse identically. (Using literal UTF-8 since Lua 5.1 lacks \xNN.)
do
  local t = task.parse("- [ ] Task ⏫\239\184\143")  -- ⏫ + VS16 via decimal bytes
  check("VS16-suffixed priority parses",    t.priority, "high")
  local t2 = task.parse("- [ ] Task ⏫")  -- ⏫ alone
  check("no-VS16 priority parses",          t2.priority, "high")
end

-- Round-trip: serialization order matches the implementation's canonical order
-- (description, priority, recurrence, on_completion, start, scheduled, due,
-- created, done, cancelled, depends_on, id, block_link)
assert_roundtrip("- [ ] Buy milk ⏫ 🔁 every week 🏁 keep 🛫 2026-01-01 ⏳ 2026-01-10 📅 2026-01-15 ➕ 2026-01-01")

-- Multiple status symbols
assert_parse("- [/] In progress task", { status_symbol = "/" })
assert_parse("- [-] Cancelled task",   { status_symbol = "-" })

-- Indented task (sub-item)
do
  local t = task.parse("  - [ ] Sub-item ⏫")
  check("indent preserved", t.indent, "  ")
  check("sub-item priority", t.priority, "high")
end

-- Numbered list task
do
  local t = task.parse("1. [ ] Numbered task")
  if not t then failed = failed + 1; print("FAIL: numbered task parse returned nil")
  else
    check("numbered marker",     t.list_marker, "1. ")
    check("numbered description", t.description, "Numbered task")
  end
end

-- Unicode description round-trips
assert_roundtrip("- [ ] 日本語タスク ⏫ 📅 2026-04-20")

-- The fabled URL+tag case
do
  local t = task.parse("- [ ] See https://example.com/page#anchor and plan #work")
  local has_anchor, has_work = false, false
  for _, tag in ipairs(t.tags) do
    if tag == "#anchor" then has_anchor = true end
    if tag == "#work" then has_work = true end
  end
  check("url#anchor not a tag", has_anchor, false)
  check("real #work is a tag",  has_work,   true)
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
