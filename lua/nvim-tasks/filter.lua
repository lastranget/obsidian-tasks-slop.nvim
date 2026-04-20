--- Query-language filter implementations.
---
--- Parses one filter instruction line (e.g. "priority is high", "due before tomorrow",
--- "(tag includes foo) AND NOT (priority is low)") and returns a predicate function
--- `(task, all_tasks) -> bool`. Returns nil if the line doesn't match any filter shape.
---
--- The grammar mirrors obsidian-tasks' FilterParser + BooleanField:
---   * Primitive filters are matched directly (done, priority, tag, date, regex, ...).
---   * Boolean expressions (containing AND/OR/XOR/NOT with parenthesized or quoted
---     atoms) are parsed via a recursive-descent expression parser that handles
---     arbitrary nesting, chaining, and NOT prefixes.
local date_mod = require("nvim-tasks.date")
local task_mod = require("nvim-tasks.task")
local config = require("nvim-tasks.config")
local M = {}

-- ---------------------------------------------------------------------------
-- Primitive helpers
-- ---------------------------------------------------------------------------

--- Check a date against an operator against a target.
local function date_cmp(d, op, target)
  if op == "ob" then return date_mod.on_or_before(d, target)
  elseif op == "oa" then return date_mod.on_or_after(d, target)
  elseif op == "b" then return date_mod.before(d, target)
  elseif op == "a" then return date_mod.after(d, target)
  elseif op == "e" then return date_mod.equal(d, target)
  end
  return false
end

--- Build a date filter for a single field.
---
--- @param ll string       Lowercased, trimmed instruction line.
--- @param kw string       Keyword used in the line (e.g. "due", "starts", "happens").
--- @param field? string   Task field name to read (used if getter is nil).
--- @param getter? fun(t)  Function returning a string date (single-date mode) or
---                         an array of date strings (any-of mode).
--- @param opts? table     { missing_default: bool, any_of: bool }
function M._date_filter(ll, kw, field, getter, opts)
  opts = opts or {}
  local missing = opts.missing_default and true or false
  local any_of = opts.any_of or false
  getter = getter or function(t) return t[field] end

  local function tp(s) return date_mod.parse_relative(s) or date_mod.parse(s) end

  local function mk(op, target)
    if any_of then
      return function(t)
        local vs = getter(t) or {}
        if #vs == 0 then return missing end
        for _, v in ipairs(vs) do
          local d = date_mod.parse(v)
          if d and date_cmp(d, op, target) then return true end
        end
        return false
      end
    end
    return function(t)
      local v = getter(t)
      if not v then return missing end
      local d = date_mod.parse(v)
      if not d then return false end
      return date_cmp(d, op, target)
    end
  end

  local oob = ll:match("^" .. kw .. " on or before (.+)")
    if oob then local t = tp(oob); if t then return mk("ob", t) end end
  local ooa = ll:match("^" .. kw .. " on or after (.+)")
    if ooa then local t = tp(ooa); if t then return mk("oa", t) end end
  -- 'in or before'/'in or after' are aliases for 'on or before'/'on or after'
  -- (matches obsidian-tasks DateField.filterRegExp).
  local iob = ll:match("^" .. kw .. " in or before (.+)")
    if iob then local t = tp(iob); if t then return mk("ob", t) end end
  local ioa = ll:match("^" .. kw .. " in or after (.+)")
    if ioa then local t = tp(ioa); if t then return mk("oa", t) end end
  local b   = ll:match("^" .. kw .. " before (.+)")
    if b then local t = tp(b); if t then return mk("b", t) end end
  local a   = ll:match("^" .. kw .. " after (.+)")
    if a then local t = tp(a); if t then return mk("a", t) end end
  local o   = ll:match("^" .. kw .. " on (.+)")
    if o then local t = tp(o); if t then return mk("e", t) end end
  local ir  = ll:match("^" .. kw .. " in (.+)")
  if ir then
    local range = M._date_range(ir)
    if range then
      if any_of then
        return function(t)
          local vs = getter(t) or {}
          if #vs == 0 then return missing end
          for _, v in ipairs(vs) do
            local d = date_mod.parse(v)
            if d and date_mod.on_or_after(d, range.start) and date_mod.on_or_before(d, range.finish) then
              return true
            end
          end
          return false
        end
      end
      return function(t)
        local v = getter(t)
        if not v then return missing end
        local d = date_mod.parse(v)
        return d and date_mod.on_or_after(d, range.start) and date_mod.on_or_before(d, range.finish) or false
      end
    end
  end
  -- Keyword-less form: "due 2026-04-20" == "due on 2026-04-20".
  -- Matches obsidian-tasks' DateField.filterRegExp which allows the keyword
  -- group to be empty. Only ISO dates are accepted here; relative/natural
  -- date parsing in Lua is too ambiguous to bind implicitly.
  local bare = ll:match("^" .. kw .. " (%d%d%d%d%-%d%d%-%d%d)$")
  if bare then local t = tp(bare); if t then return mk("e", t) end end
  return nil
end

function M._date_range(expr)
  local e = vim.trim(expr)
  local s1, s2 = e:match("^(%d%d%d%d%-%d%d%-%d%d)%s+(%d%d%d%d%-%d%d%-%d%d)$")
  if s1 and s2 then return { start = date_mod.parse(s1), finish = date_mod.parse(s2) } end
  for _, pair in ipairs({ { "last", -1 }, { "this", 0 }, { "next", 1 } }) do
    local rel, off = pair[1], pair[2]
    for _, uinfo in ipairs({ { "week", "w" }, { "month", "m" }, { "quarter", "q" }, { "year", "y" } }) do
      if e:match("^" .. rel .. "%s+" .. uinfo[1]) then
        local today = date_mod.today()
        local t = os.date("*t", date_mod.to_ts(today))
        if uinfo[2] == "w" then
          local wday = t.wday == 1 and 7 or (t.wday - 1)
          local mon = date_mod.add_days(today, -(wday - 1) + off * 7)
          return { start = mon, finish = date_mod.add_days(mon, 6) }
        elseif uinfo[2] == "m" then
          local m, y = t.month + off, t.year
          while m > 12 do m = m - 12; y = y + 1 end
          while m < 1 do m = m + 12; y = y - 1 end
          return {
            start = { year = y, month = m, day = 1 },
            finish = { year = y, month = m, day = date_mod.days_in_month(y, m) },
          }
        elseif uinfo[2] == "q" then
          local q, y = math.ceil(t.month / 3) + off, t.year
          while q > 4 do q = q - 4; y = y + 1 end
          while q < 1 do q = q + 4; y = y - 1 end
          local sm = (q - 1) * 3 + 1
          local em = sm + 2
          return {
            start = { year = y, month = sm, day = 1 },
            finish = { year = y, month = em, day = date_mod.days_in_month(y, em) },
          }
        elseif uinfo[2] == "y" then
          local y = t.year + off
          return {
            start = { year = y, month = 1, day = 1 },
            finish = { year = y, month = 12, day = 31 },
          }
        end
      end
    end
  end
  return nil
end

--- Parse a `/pattern/flags` regex expression into (pattern, flags).
--- If no slashes, returns (raw, ""). Only `i` flag is recognised.
---
--- Note: the pattern is a Lua pattern, not a JavaScript regex. Users writing
--- JS-style regex (`\d`, `\w`, `|`) will not get the results they expect.
--- The `includes` / `does not include` operators are strongly recommended
--- for case-insensitive substring searching.
local function parse_regex_literal(s)
  s = vim.trim(s)
  local pattern, flags = s:match("^/(.+)/([^/]*)$")
  if not pattern then
    -- No surrounding slashes: treat the whole string as a Lua pattern.
    return s, ""
  end
  return pattern, flags or ""
end

function M._text_filter(ll, l, name, getter)
  local function val(t) return getter(t) or "" end

  -- Find the keyword+operator prefix in the lowercased line (case-insensitive
  -- recognition), then pull the value from the original-case line so regex
  -- patterns and substring needles preserve casing.
  local function extract_value(op_pattern)
    local prefix = "^" .. name .. " " .. op_pattern .. " "
    local _, e = ll:find(prefix)
    if e then return vim.trim(l:sub(e + 1)) end
    return nil
  end

  local v
  v = extract_value("includes")
  if v then
    local needle = v:lower()
    return function(t) return val(t):lower():find(needle, 1, true) ~= nil end
  end
  v = extract_value("does not include")
  if v then
    local needle = v:lower()
    return function(t) return val(t):lower():find(needle, 1, true) == nil end
  end
  v = extract_value("regex matches")
  if v then
    local pat, flags = parse_regex_literal(v)
    local ci = flags:find("i") ~= nil
    if ci then
      local lpat = pat:lower()
      return function(t) return val(t):lower():match(lpat) ~= nil end
    end
    return function(t) return val(t):match(pat) ~= nil end
  end
  v = extract_value("regex does not match")
  if v then
    local pat, flags = parse_regex_literal(v)
    local ci = flags:find("i") ~= nil
    if ci then
      local lpat = pat:lower()
      return function(t) return val(t):lower():match(lpat) == nil end
    end
    return function(t) return val(t):match(pat) == nil end
  end
  return nil
end

--- Priority filter: matches the full grammar from obsidian-tasks' PriorityField
---    ^priority(\s+is)?(\s+(above|below|not))?(\s+(lowest|low|none|medium|high|highest))$
--- plus `has priority` / `no priority`.
function M._priority_filter(ll)
  if ll == "has priority" then return function(t) return t.priority ~= nil end end
  if ll == "no priority" then return function(t) return t.priority == nil end end

  -- Normalise by stripping an optional "is": "priority is above X" -> "priority above X".
  local norm = ll:gsub("^priority%s+is%s+", "priority ")

  local op, level
  op, level = norm:match("^priority%s+(above)%s+(%a+)%s*$")
  if not op then op, level = norm:match("^priority%s+(below)%s+(%a+)%s*$") end
  if not op then op, level = norm:match("^priority%s+(not)%s+(%a+)%s*$") end
  if not op then level = norm:match("^priority%s+(%a+)%s*$"); op = "eq" end
  if not level then return nil end

  local order = config.get().priority_order
  if order[level] == nil then return nil end  -- not a valid priority name
  local th = order[level]

  if op == "above" then
    return function(t) return (order[t.priority or "none"] or order.none) < th end
  elseif op == "below" then
    return function(t) return (order[t.priority or "none"] or order.none) > th end
  elseif op == "not" then
    if level == "none" then return function(t) return t.priority ~= nil end end
    return function(t) return (t.priority or "none") ~= level end
  else -- eq
    if level == "none" then return function(t) return t.priority == nil end end
    return function(t) return t.priority == level end
  end
end

-- ---------------------------------------------------------------------------
-- Boolean expression parser: arbitrary nesting of AND/OR/XOR/NOT
-- ---------------------------------------------------------------------------

-- Find the position of the matching `)`, respecting nesting and quoted strings.
local function find_matching_paren(line, start)
  local depth, i, n = 1, start + 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c == '"' then
      local e = line:find('"', i + 1, true)
      if not e then return nil end
      i = e + 1
    elseif c == "(" then
      depth = depth + 1; i = i + 1
    elseif c == ")" then
      depth = depth - 1
      if depth == 0 then return i end
      i = i + 1
    else
      i = i + 1
    end
  end
  return nil
end

-- Longest-match-first list of operator token sequences.
local BOOLEAN_OPERATORS = {
  { "AND", "NOT" }, { "OR", "NOT" },
  { "AND" }, { "OR" }, { "XOR" }, { "NOT" },
}

local function match_boolean_op(line, i)
  for _, words in ipairs(BOOLEAN_OPERATORS) do
    local pos = i
    local all = true
    for idx, word in ipairs(words) do
      if idx > 1 then
        local s, e = line:find("^%s+", pos)
        if not s then all = false; break end
        pos = e + 1
      end
      local wl = #word
      if line:sub(pos, pos + wl - 1) ~= word then all = false; break end
      pos = pos + wl
    end
    if all then
      -- Require a boundary character after the operator.
      local nc = line:sub(pos, pos)
      if nc == "" or nc:match("[%s%(\"']") then
        return table.concat(words, " "), pos
      end
    end
  end
  return nil
end

local function tokenize_boolean(line)
  local tokens = {}
  local i, n = 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c == "(" then
      local close = find_matching_paren(line, i)
      if not close then return nil, "unbalanced parens" end
      table.insert(tokens, { kind = "group", text = line:sub(i + 1, close - 1) })
      i = close + 1
    elseif c == '"' then
      local close = line:find('"', i + 1, true)
      if not close then return nil, "unclosed quote" end
      table.insert(tokens, { kind = "atom", text = line:sub(i + 1, close - 1) })
      i = close + 1
    elseif c == ")" then
      return nil, "unexpected ')'"
    else
      local op, new_i = match_boolean_op(line, i)
      if op then
        table.insert(tokens, { kind = "op", op = op })
        i = new_i
      else
        return nil, ("unexpected '%s' at col %d"):format(c, i)
      end
    end
  end
  return tokens
end

--- Parse a boolean expression line into a filter function.
--- Returns nil if the line is not a boolean expression or fails to parse.
---
--- Grammar (all binary ops are left-associative with equal precedence; users
--- should parenthesise explicitly when mixing):
---     expr  := unary (OP unary)*
---     unary := NOT unary | primary
---     primary := '(' expr ')' | '(' filter ')' | '"' filter '"'
function M._parse_boolean(line)
  local toks, _err = tokenize_boolean(line)
  if not toks then return nil end

  -- Must contain at least one operator to qualify.
  local has_op = false
  for _, t in ipairs(toks) do if t.kind == "op" then has_op = true; break end end
  if not has_op then return nil end

  local pos = 1
  local function peek() return toks[pos] end
  local function eat() local t = toks[pos]; pos = pos + 1; return t end

  local parse_unary

  local function parse_primary()
    local t = eat()
    if not t then return nil end
    if t.kind == "group" or t.kind == "atom" then
      local inner = vim.trim(t.text)
      -- Groups may themselves be boolean expressions; try that first.
      if t.kind == "group" then
        local sub = M._parse_boolean(inner)
        if sub then return sub end
      end
      -- Otherwise treat as a primitive filter.
      return M.parse_filter(inner)
    end
    return nil
  end

  parse_unary = function()
    local t = peek()
    if t and t.kind == "op" and t.op == "NOT" then
      eat()
      local inner = parse_unary()
      if not inner then return nil end
      return function(task, all) return not inner(task, all) end
    end
    return parse_primary()
  end

  local function parse_expr()
    local left = parse_unary()
    if not left then return nil end
    while true do
      local t = peek()
      if not t or t.kind ~= "op" then break end
      local op = t.op
      eat()
      local right = parse_unary()
      if not right then return nil end
      local lhs = left
      if op == "AND" then
        left = function(task, all) return lhs(task, all) and right(task, all) end
      elseif op == "OR" then
        left = function(task, all) return lhs(task, all) or right(task, all) end
      elseif op == "XOR" then
        left = function(task, all)
          local a, b = lhs(task, all), right(task, all)
          return (a and not b) or (not a and b)
        end
      elseif op == "AND NOT" then
        left = function(task, all) return lhs(task, all) and not right(task, all) end
      elseif op == "OR NOT" then
        left = function(task, all) return lhs(task, all) or not right(task, all) end
      end
    end
    return left
  end

  local f = parse_expr()
  if not f then return nil end
  if pos <= #toks then return nil end  -- trailing tokens, parse incomplete
  return f
end

-- ---------------------------------------------------------------------------
-- Top-level filter dispatcher
-- ---------------------------------------------------------------------------

function M.parse_filter(line)
  local l = vim.trim(line)
  local ll = l:lower()
  if ll == "" then return nil end

  if ll == "done" then return function(t) return task_mod.is_done(t) end end
  if ll == "not done" then return function(t) return not task_mod.is_done(t) end end

  -- status.type is/is not <TYPE>
  do
    local st_op, st_val = ll:match("^status%.type%s+(is%s+not)%s+(.+)$")
    if not st_op then st_op, st_val = ll:match("^status%.type%s+(is)%s+(.+)$") end
    if st_op and st_val then
      local neg = st_op:find("not") ~= nil
      local target = vim.trim(st_val):upper()
      return function(t)
        local tt = config.status_type(t.status_symbol)
        if neg then return tt ~= target end
        return tt == target
      end
    end
  end

  -- status.name text filter
  do
    local f = M._text_filter(ll, l, "status.name", function(t) return config.status_name(t.status_symbol) end)
    if f then return f end
  end

  -- Date filters. "starts" defaults to TRUE when start date is missing, matching
  -- obsidian-tasks' StartDateField.filterResultIfFieldMissing (a task with no
  -- start date is considered to have already started).
  local date_fields = {
    { kw = "due",       field = "due" },
    { kw = "scheduled", field = "scheduled" },
    { kw = "starts",    field = "start_date", missing_default = true },
    { kw = "created",   field = "created" },
    { kw = "done",      field = "done_date" },
    { kw = "cancelled", field = "cancelled_date" },
  }
  for _, df in ipairs(date_fields) do
    local f = M._date_filter(ll, df.kw, df.field, nil, { missing_default = df.missing_default })
    if f then return f end
  end

  -- happens: test due, scheduled, AND start; pass if ANY matches (matches
  -- HappensDateField.getFilter in obsidian-tasks, which iterates over all three).
  -- Build a dense array excluding nils so ipairs sees every date.
  do
    local f = M._date_filter(ll, "happens", nil,
      function(t)
        local dates = {}
        if t.due then dates[#dates + 1] = t.due end
        if t.scheduled then dates[#dates + 1] = t.scheduled end
        if t.start_date then dates[#dates + 1] = t.start_date end
        return dates
      end,
      { any_of = true })
    if f then return f end
  end

  -- has/no date
  for _, spec in ipairs({
    { "has due date", "due", true }, { "no due date", "due", false },
    { "has scheduled date", "scheduled", true }, { "no scheduled date", "scheduled", false },
    { "has start date", "start_date", true }, { "no start date", "start_date", false },
    { "has created date", "created", true }, { "no created date", "created", false },
    { "has done date", "done_date", true }, { "no done date", "done_date", false },
    { "has cancelled date", "cancelled_date", true }, { "no cancelled date", "cancelled_date", false },
    { "has happens date", nil, true }, { "no happens date", nil, false },
  }) do
    if ll == spec[1] then
      local field, has = spec[2], spec[3]
      return function(t)
        local v = field and t[field] or (t.due or t.scheduled or t.start_date)
        if has then return v ~= nil end
        return v == nil
      end
    end
  end

  -- date is invalid
  for _, df in ipairs({
    { "due", "due" }, { "scheduled", "scheduled" }, { "start", "start_date" },
    { "created", "created" }, { "done", "done_date" }, { "cancelled", "cancelled_date" },
  }) do
    if ll == df[1] .. " date is invalid" then
      return function(t)
        local v = t[df[2]]
        return v ~= nil and date_mod.parse(v) == nil
      end
    end
  end

  -- Priority
  do local f = M._priority_filter(ll); if f then return f end end

  -- Recurring
  if ll == "is recurring" then return function(t) return t.recurrence ~= nil end end
  if ll == "is not recurring" then return function(t) return t.recurrence == nil end end

  -- Text filters (description/path/filename/folder/root/heading/id/recurrence).
  for _, spec in ipairs({
    { "recurrence",  function(t) return t.recurrence or "" end },
    { "description", function(t) return t.description or "" end },
    { "path",        function(t) return t.file_path or "" end },
    { "filename",    function(t) return t.file_path and vim.fn.fnamemodify(t.file_path, ":t") or "" end },
    { "folder",      function(t) return t.file_path and vim.fn.fnamemodify(t.file_path, ":h") or "" end },
    { "root",        function(t)
                       if not t.file_path then return "" end
                       -- Strip any configured vault_paths prefix so the returned
                       -- root is the first segment RELATIVE to the vault (matches
                       -- obsidian-tasks' task.file.root). Without this, absolute
                       -- paths like '/vault/projects/a.md' return "" (leading slash).
                       local rel = t.file_path
                       for _, vp in ipairs(config.get().vault_paths or {}) do
                         local prefix = vp
                         if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
                         if rel:sub(1, #prefix) == prefix then
                           rel = rel:sub(#prefix + 1)
                           break
                         end
                       end
                       local parts = vim.split(rel, "/", { plain = true })
                       if #parts <= 1 then return "" end  -- file at vault root
                       return parts[1] or ""
                     end },
    { "heading",     function(t) return t.preceding_header or "" end },
    { "id",          function(t) return t.id or "" end },
  }) do
    local f = M._text_filter(ll, l, spec[1], spec[2])
    if f then return f end
  end

  -- Tags. The "tag[s] include[s] X" variant accepts X with or without a leading '#'.
  if ll == "has tags" or ll == "has tag" then
    return function(t) return t.tags and #t.tags > 0 end
  end
  if ll == "no tags" or ll == "no tag" then
    return function(t) return not t.tags or #t.tags == 0 end
  end
  do
    local ti = ll:match("^tags? includes? (.+)") or ll:match("^tags? include (.+)")
    if ti then
      local needle = vim.trim(ti):lower()
      return function(t)
        for _, tag in ipairs(t.tags or {}) do
          if tag:lower():find(needle, 1, true) then return true end
        end
        return false
      end
    end
    local te = ll:match("^tags? does? not include (.+)") or ll:match("^tags? do not include (.+)")
    if te then
      local needle = vim.trim(te):lower()
      return function(t)
        for _, tag in ipairs(t.tags or {}) do
          if tag:lower():find(needle, 1, true) then return false end
        end
        return true
      end
    end
  end

  -- ID has/no, depends on has/no
  if ll == "has id" then return function(t) return t.id and t.id ~= "" end end
  if ll == "no id" then return function(t) return not t.id or t.id == "" end end
  if ll == "has depends on" then return function(t) return t.depends_on and #t.depends_on > 0 end end
  if ll == "no depends on" then return function(t) return not t.depends_on or #t.depends_on == 0 end end

  -- Blocking/blocked. The negation variants reuse the positive filter closure
  -- rather than re-parsing on every task evaluation.
  if ll == "is blocking" then
    return function(t, all)
      if not t.id or t.id == "" or not all then return false end
      for _, o in ipairs(all) do
        if o.depends_on then
          for _, d in ipairs(o.depends_on) do
            if d == t.id and not task_mod.is_done(o) then return true end
          end
        end
      end
      return false
    end
  end
  if ll == "is not blocking" then
    local bf = M.parse_filter("is blocking")
    if not bf then return nil end
    return function(t, a) return not bf(t, a) end
  end
  if ll == "is blocked" then
    return function(t, all)
      if not t.depends_on or #t.depends_on == 0 or not all then return false end
      for _, did in ipairs(t.depends_on) do
        for _, o in ipairs(all) do
          if o.id == did and not task_mod.is_done(o) then return true end
        end
      end
      return false
    end
  end
  if ll == "is not blocked" then
    local bf = M.parse_filter("is blocked")
    if not bf then return nil end
    return function(t, a) return not bf(t, a) end
  end

  if ll == "exclude sub-items" then
    -- Matches obsidian-tasks ExcludeSubItemsField:
    --   - empty indent → top-level → pass
    --   - no `>` in indent → sub-item → fail
    --   - indent ends at the last `>` with ≤1 trailing space → still a
    --     top-level within a blockquote/callout → pass
    --   - otherwise (last `>` followed by 2+ spaces, or tabs) → sub-item → fail
    return function(t)
      local indent = t.indent or ""
      if indent == "" then return true end
      local last = 0
      for i = 1, #indent do if indent:sub(i, i) == ">" then last = i end end
      if last == 0 then return false end
      local tail = indent:sub(last + 1)
      return tail == "" or tail == " "
    end
  end

  -- Fallback: boolean expression
  local bf = M._parse_boolean(l)
  if bf then return bf end

  return nil
end

return M
