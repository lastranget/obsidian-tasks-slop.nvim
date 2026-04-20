--- Task parsing/serialization. Matches Obsidian Tasks Emoji Format exactly.
local config = require("nvim-tasks.config")
local M = {}
local _date_emojis, _priority_emojis

local function get_date_emojis()
  if _date_emojis then return _date_emojis end
  local e, a = config.get().emojis, config.get().emoji_aliases or {}
  _date_emojis = {
    { emojis = vim.list_extend({ e.due }, a.due or {}), field = "due" },
    { emojis = vim.list_extend({ e.scheduled }, a.scheduled or {}), field = "scheduled" },
    { emojis = { e.start }, field = "start_date" },
    { emojis = { e.created }, field = "created" },
    { emojis = { e.done }, field = "done_date" },
    { emojis = { e.cancelled }, field = "cancelled_date" },
  }
  return _date_emojis
end

local function get_priority_emojis()
  if _priority_emojis then return _priority_emojis end
  local e = config.get().emojis
  _priority_emojis = {
    { emoji = e.highest, name = "highest" }, { emoji = e.high, name = "high" },
    { emoji = e.medium, name = "medium" }, { emoji = e.low, name = "low" },
    { emoji = e.lowest, name = "lowest" },
  }
  return _priority_emojis
end

-- Single UTF-8 codepoint pattern. Matches obsidian-tasks' /\[(.)\]/u, where
-- `.` with the `u` flag is any single Unicode codepoint (1-4 bytes). Previously
-- we used `(.)` which captured only the first byte of a multi-byte symbol.
--   0x00-0x7F: ASCII         (1 byte)
--   0xC2-0xDF: 2-byte lead   + 1 continuation
--   0xE0-0xEF: 3-byte lead   + 2 continuations
--   0xF0-0xF4: 4-byte lead   + 3 continuations
-- Continuation bytes are [0x80-0xBF]. The greedy `*` on continuations is
-- bounded by the next literal `]` so it doesn't over-consume.
local UTF8_CP = "[%z\1-\127\194-\244][\128-\191]*"

function M.parse(line, file_path, line_number, preceding_header)
  -- Indent may contain `>` (Obsidian callouts) as well as whitespace.
  -- Numbered marker accepts a single `.` or `)` terminator (obsidian-tasks
  -- uses `[0-9]+[.)]` — NOT `+` — so `1..` is not a valid list item).
  local indent, marker, symbol, rest =
    line:match("^([%s>]*)([%-*+]%s+)%[(" .. UTF8_CP .. ")%]%s+(.*)")
  if not indent then
    indent, marker, symbol, rest =
      line:match("^([%s>]*)(%d+[.)]%s+)%[(" .. UTF8_CP .. ")%]%s+(.*)")
  end
  if not indent then return nil end
  local gf = config.get().global_filter
  if gf and gf ~= "" and not rest:find(gf, 1, true) then return nil end

  local task = {
    raw = line, indent = indent, list_marker = marker, status_symbol = symbol,
    description = "", priority = nil, due = nil, scheduled = nil, start_date = nil,
    created = nil, done_date = nil, cancelled_date = nil, recurrence = nil,
    id = nil, depends_on = {}, on_completion = nil, block_link = nil, tags = {},
    file_path = file_path, line_number = line_number,
    preceding_header = preceding_header, is_task = true,
  }
  -- Strip Variant Selector 16 (U+FE0F) up front. It's a cosmetic UTF-8 hint
  -- that tells renderers to display the preceding codepoint in emoji (rather
  -- than text) presentation, and carries no semantic meaning here. Removing
  -- it lets every pattern below match the bare emoji without fighting a
  -- 3-byte sequence that Lua patterns can't make optional as a group.
  -- (Using string.char so the literal is valid in Lua 5.1 as well as LuaJIT.)
  local VS16 = string.char(0xEF, 0xB8, 0x8F)
  local remaining = (rest:gsub(VS16, ""))
  -- Block link
  local bl = remaining:match("%s+(%^[a-zA-Z0-9%-]+)$")
  if bl then task.block_link = bl; remaining = remaining:gsub("%s+%^[a-zA-Z0-9%-]+$", "") end

  -- Iterative end-matching (matches original DefaultTaskSerializer.deserialize)
  local e = config.get().emojis
  local max_runs, runs, matched = 20, 0, true
  local trailing_tags = {} -- tags stripped from the end; will be re-added to the description
  while matched and runs < max_runs do
    matched = false; runs = runs + 1
    -- Priority
    for _, pe in ipairs(get_priority_emojis()) do
      local pat = "%s*" .. vim.pesc(pe.emoji) .. "%s*$"
      if remaining:match(pat) then
        task.priority = pe.name; remaining = remaining:gsub(pat, ""); matched = true
      end
    end
    -- Dates
    for _, de in ipairs(get_date_emojis()) do
      for _, em in ipairs(de.emojis) do
        local pat = vim.pesc(em) .. "%s*(%d%d%d%d%-%d%d%-%d%d)%s*$"
        local found = remaining:match(pat)
        if found then
          task[de.field] = found
          remaining = remaining:gsub(vim.pesc(em) .. "%s*%d%d%d%d%-%d%d%-%d%d%s*$", "")
          matched = true; break
        end
      end
    end
    -- Recurrence
    local rec_pat = vim.pesc(e.recurrence) .. "%s+([a-zA-Z0-9, !]+)%s*$"
    local rec = remaining:match(rec_pat)
    if rec then task.recurrence = vim.trim(rec); remaining = remaining:gsub(vim.pesc(e.recurrence) .. "%s+[a-zA-Z0-9, !]+%s*$", ""); matched = true end
    -- On completion
    local oc_pat = vim.pesc(e.on_completion) .. "%s+(%a+)%s*$"
    local oc = remaining:match(oc_pat)
    if oc then task.on_completion = oc:lower(); remaining = remaining:gsub(vim.pesc(e.on_completion) .. "%s+%a+%s*$", ""); matched = true end
    -- ID
    local id_pat = vim.pesc(e.id) .. "%s+([a-zA-Z0-9_%-]+)%s*$"
    local fid = remaining:match(id_pat)
    if fid then task.id = fid; remaining = remaining:gsub(vim.pesc(e.id) .. "%s+[a-zA-Z0-9_%-]+%s*$", ""); matched = true end
    -- Depends on
    local dep_pat = vim.pesc(e.depends_on) .. "%s+([a-zA-Z0-9_%-,% ]+)%s*$"
    local fdep = remaining:match(dep_pat)
    if fdep then
      task.depends_on = {}; for did in fdep:gmatch("[a-zA-Z0-9_%-]+") do table.insert(task.depends_on, did) end
      remaining = remaining:gsub(vim.pesc(e.depends_on) .. "%s+[a-zA-Z0-9_%-,% ]+%s*$", ""); matched = true
    end
    -- Trailing tags. Track separately so we can restore them to the description,
    -- matching DefaultTaskSerializer.deserialize (`trailingTags` handling).
    -- Tag class matches obsidian-tasks' TaskRegularExpressions.hashTags: '#' then
    -- one or more chars that are NOT space or any of ! @ # $ % ^ & * ( ) , . ? " : { } | < > .
    -- Lua byte-oriented matching passes UTF-8 continuation bytes (>=0x80) through the
    -- negated class since every excluded byte is ASCII, so non-English tags work.
    local ttag = remaining:match("%s+(#[^%s!@#$%%^&*(),.?\":{}|<>]+)%s*$")
    if ttag then table.insert(trailing_tags, 1, ttag); remaining = remaining:gsub("%s+#[^%s!@#$%%^&*(),.?\":{}|<>]+%s*$", ""); matched = true end
  end

  -- Re-append trailing tags so they appear in the final description (obsidian-tasks
  -- parity: users expect 'Do #a 📅 2026-01-01 #b' to keep description 'Do #a #b').
  -- Strip any trailing whitespace first — each field-removal gsub leaves a trailing
  -- space behind, and if we blindly appended `" " .. tags` we'd get `"Do  #a #b"`
  -- (double space). Matching obsidian-tasks DefaultTaskSerializer.deserialize which
  -- calls `state.line.replace(regex, '').trim()` on every match.
  if #trailing_tags > 0 then
    remaining = remaining:gsub("%s+$", "") .. " " .. table.concat(trailing_tags, " ")
  end

  -- Extract all hashtags from the (now complete) description into task.tags, dedup.
  -- Space-anchored via " "..remaining prefix so the first tag gets a preceding space;
  -- this mirrors obsidian-tasks' (^|\s)# requirement and keeps URL fragments
  -- ('example.com/page#section') out of the tag list.
  for tag in (" " .. remaining):gmatch("%s(#[^%s!@#$%%^&*(),.?\":{}|<>]+)") do
    local found = false; for _, t in ipairs(task.tags) do if t == tag then found = true; break end end
    if not found then table.insert(task.tags, tag) end
  end
  task.description = vim.trim(remaining)
  return task
end

function M.serialize(task)
  local e = config.get().emojis
  local parts = { task.description }
  if task.priority then local em = e[task.priority]; if em then table.insert(parts, em) end end
  if task.recurrence then table.insert(parts, e.recurrence .. " " .. task.recurrence) end
  if task.on_completion and task.on_completion ~= "" and task.on_completion ~= "ignore" then
    table.insert(parts, e.on_completion .. " " .. task.on_completion) end
  if task.start_date then table.insert(parts, e.start .. " " .. task.start_date) end
  if task.scheduled then table.insert(parts, e.scheduled .. " " .. task.scheduled) end
  if task.due then table.insert(parts, e.due .. " " .. task.due) end
  if task.created then table.insert(parts, e.created .. " " .. task.created) end
  if task.done_date then table.insert(parts, e.done .. " " .. task.done_date) end
  if task.cancelled_date then table.insert(parts, e.cancelled .. " " .. task.cancelled_date) end
  if task.depends_on and #task.depends_on > 0 then table.insert(parts, e.depends_on .. " " .. table.concat(task.depends_on, ",")) end
  if task.id then table.insert(parts, e.id .. " " .. task.id) end
  if task.block_link then table.insert(parts, task.block_link) end
  return task.indent .. task.list_marker .. "[" .. task.status_symbol .. "] " .. table.concat(parts, " ")
end

function M.is_done(task) return config.is_done(task.status_symbol) end
function M.is_cancelled(task) return config.is_cancelled(task.status_symbol) end
function M.priority_sort_value(task) return config.get().priority_order[task.priority or "none"] or 3 end

--- Urgency: exact coefficients from the original plugin's Urgency.ts.
---
--- Contributions are additive:
---   * due date        : up to +12.0 (sliding scale, capped below 0.2)
---   * scheduled date  : +5.0 if scheduled is today or in the past
---   * start date      : -3.0 if start is still in the future
---   * priority        : -0.3 to +1.5 × 6.0 = [-1.8 … +9.0]
function M.urgency(task)
  local dm = require("nvim-tasks.date")
  local today = dm.today()
  local today_ts = dm.to_ts(today)
  local u = 0.0

  -- Due date contributes the largest swing. Obsidian maps a 21-day window
  -- (from 14 days ahead to 7 days overdue) to the 0.2–1.0 multiplier range.
  if task.due then
    local d = dm.parse(task.due)
    if d then
      local days_overdue = math.floor((today_ts - dm.to_ts(d)) / 86400 + 0.5)
      local multiplier
      if days_overdue >= 7 then
        multiplier = 1.0
      elseif days_overdue >= -14 then
        multiplier = ((days_overdue + 14) * 0.8) / 21 + 0.2
      else
        multiplier = 0.2
      end
      u = u + multiplier * 12.0
    end
  end

  -- Scheduled on or before today contributes a fixed bump.
  if task.scheduled then
    local d = dm.parse(task.scheduled)
    if d and dm.on_or_before(d, today) then u = u + 5.0 end
  end

  -- Task not yet started gets a deduction (it's not actionable today).
  if task.start_date then
    local d = dm.parse(task.start_date)
    if d and dm.after(d, today) then u = u - 3.0 end
  end

  -- Priority is a fixed, table-driven contribution.
  local priority_multipliers = {
    highest = 1.5, high = 1.0, medium = 0.65,
    none    = 0.325, low = 0, lowest = -0.3,
  }
  local pm = priority_multipliers[task.priority or "none"] or 0.325
  u = u + pm * 6.0

  return u
end

--- Locate every ```tasks code block in a buffer.
---
--- Returns a list of `{ start, finish, query_lines }` tables with 0-indexed
--- line numbers for the opening and closing fences. Nested ``` fences are
--- not supported (same as obsidian-tasks and Obsidian itself).
function M.find_query_blocks(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = {}
  local in_block = false
  local block_start = nil
  local query_lines = nil

  for i, line in ipairs(lines) do
    if not in_block and line:match("^%s*```tasks") then
      in_block = true
      block_start = i - 1
      query_lines = {}
    elseif in_block and line:match("^%s*```%s*$") then
      table.insert(blocks, {
        start = block_start,
        finish = i - 1,
        query_lines = query_lines,
      })
      in_block = false
    elseif in_block then
      table.insert(query_lines, line)
    end
  end
  return blocks
end

return M
