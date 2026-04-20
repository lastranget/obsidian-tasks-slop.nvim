-- Round-trip and Unicode-tag tests for task.lua.
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
  list_extend = function(dst, src)
    for _, v in ipairs(src or {}) do table.insert(dst, v) end
    return dst
  end,
}

local task = require("nvim-tasks.task")

local passed, failed = 0, 0
local function check(name, got, want)
  if got == want then
    passed = passed + 1; print("PASS " .. name)
  else
    failed = failed + 1
    print(("FAIL %s\n  got:  %s\n  want: %s"):format(name, tostring(got), tostring(want)))
  end
end

-- Round-trip: parse then serialize should give back the same string (modulo canonical order).
local function roundtrip_equal(name, line, expected_serialized)
  local t = task.parse(line)
  if not t then failed = failed + 1; print("FAIL " .. name .. ": parse returned nil"); return end
  local s = task.serialize(t)
  check(name, s, expected_serialized or line)
end

-- Basic tests
do
  local t = task.parse("- [ ] Buy milk")
  check("basic parse: description", t.description, "Buy milk")
  check("basic parse: status",      t.status_symbol, " ")
  check("basic parse: priority",    t.priority, nil)
end

do
  local t = task.parse("- [ ] Buy milk ⏫ 📅 2026-04-20")
  check("priority parsed", t.priority, "high")
  check("due parsed",      t.due,      "2026-04-20")
  check("desc after strip", t.description, "Buy milk")
end

-- THE KEY BUG FIX: trailing tags must survive round-trip
do
  local t = task.parse("- [ ] Buy milk #urgent #shopping")
  check("trailing tags: count", #t.tags, 2)
  -- Tags preserved in order left-to-right
  check("trailing tags: first", t.tags[1], "#urgent")
  check("trailing tags: second", t.tags[2], "#shopping")
  check("trailing tags: description includes them",
    t.description, "Buy milk #urgent #shopping")
end

-- Mixed tags + date fields (the obsidian-tasks example)
do
  local t = task.parse("- [ ] Do something #tag1 📅 2026-01-01 #tag2")
  check("mixed: due",  t.due, "2026-01-01")
  check("mixed: tags count", #t.tags, 2)
  check("mixed: tag1 present", t.tags[1] == "#tag1" or t.tags[2] == "#tag1", true)
  check("mixed: tag2 present", t.tags[1] == "#tag2" or t.tags[2] == "#tag2", true)
  -- Description should be "Do something #tag1 #tag2" (trailing tags re-appended,
  -- inline tag preserved)
  check("mixed: description",
    t.description, "Do something #tag1 #tag2")
end

-- Unicode tags
do
  local t = task.parse("- [ ] 買い物 #緊急")
  check("unicode: tag count", #t.tags, 1)
  check("unicode: tag",       t.tags[1], "#緊急")
end

-- URL fragment must not become a tag
do
  local t = task.parse("- [ ] See http://example.com/page#section and #realtag")
  local has_section = false
  local has_realtag = false
  for _, tag in ipairs(t.tags) do
    if tag == "#section" then has_section = true end
    if tag == "#realtag" then has_realtag = true end
  end
  check("url: no #section tag",  has_section, false)
  check("url: has #realtag tag", has_realtag, true)
end

-- Status symbols for done variants
do
  local t = task.parse("- [x] Done task")
  check("done symbol", t.status_symbol, "x")
  check("is_done(task.is_done)", task.is_done(t), true)
end

-- Round-trip: simple
roundtrip_equal("roundtrip: plain",
  "- [ ] Buy milk", "- [ ] Buy milk")

-- Round-trip: priority + due (canonical order: desc, priority, recurrence, oc,
-- start, scheduled, due, created, done, cancelled, depends_on, id, block_link)
roundtrip_equal("roundtrip: priority+due",
  "- [ ] Buy milk ⏫ 📅 2026-04-20", "- [ ] Buy milk ⏫ 📅 2026-04-20")

-- Round-trip preserves trailing tags (the bug fix)
do
  local t = task.parse("- [ ] Buy milk #urgent #shopping")
  local s = task.serialize(t)
  -- Tags are re-appended to description in order; serialize emits desc unchanged.
  check("roundtrip: trailing tags",
    s, "- [ ] Buy milk #urgent #shopping")
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
