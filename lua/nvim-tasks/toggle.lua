local config = require("nvim-tasks.config")
local task_mod = require("nvim-tasks.task")
local date_mod = require("nvim-tasks.date")
local recurrence = require("nvim-tasks.recurrence")
local M = {}

function M.toggle_done(bufnr, lnum)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum-1, lnum, false)[1]; if not line then return end
  local task = task_mod.parse(line)
  if task then M._toggle_task(bufnr, lnum, task); return end
  -- Plain checklist
  local _,_,symbol = line:match("^(%s*)([-*+]%s+)%[(.)]%s+")
  if not symbol then _,_,symbol = line:match("^(%s*)(%d+[.)]+%s+)%[(.)]%s+") end
  if symbol then
    local s = config.get_status(symbol); local ns = s and s.next or (symbol==" " and "x" or " ")
    vim.api.nvim_buf_set_lines(bufnr, lnum-1, lnum, false, { (line:gsub("%[.%]","["..ns.."]",1)) }); return
  end
  -- List item -> add checkbox
  local li = line:match("^(%s*[-*+]%s+)") or line:match("^(%s*%d+[.)]+%s+)")
  if li then vim.api.nvim_buf_set_lines(bufnr, lnum-1, lnum, false, { li.."[ ] "..line:sub(#li+1) }); return end
  -- Plain text -> checklist
  local ind = line:match("^(%s*)"); vim.api.nvim_buf_set_lines(bufnr, lnum-1, lnum, false, { ind.."- [ ] "..line:sub(#ind+1) })
end

function M._toggle_task(bufnr, lnum, task)
  local cfg = config.get(); local was = task_mod.is_done(task)
  if was then
    task.status_symbol=" "; task.done_date=nil; task.cancelled_date=nil
    vim.api.nvim_buf_set_lines(bufnr, lnum-1, lnum, false, { task_mod.serialize(task) })
  else
    local today = date_mod.today_str()
    if task.recurrence then
      task.status_symbol="x"; if cfg.auto_done_date then task.done_date=today end
      local done_line = task_mod.serialize(task)
      local next_task = recurrence.create_next_recurrence(task, today)
      local keep = task.on_completion ~= "delete"
      local lines = {}
      if next_task then local nl = task_mod.serialize(next_task)
        if cfg.recurrence_position == "above" then table.insert(lines, nl); if keep then table.insert(lines, done_line) end
        else if keep then table.insert(lines, done_line) end; table.insert(lines, nl) end
      else if keep then table.insert(lines, done_line) end end
      vim.api.nvim_buf_set_lines(bufnr, lnum-1, lnum, false, lines)
    else
      task.status_symbol="x"; if cfg.auto_done_date then task.done_date=today end
      if task.on_completion == "delete" then vim.api.nvim_buf_set_lines(bufnr, lnum-1, lnum, false, {}); require("nvim-tasks.vault").invalidate(); return end
      vim.api.nvim_buf_set_lines(bufnr, lnum-1, lnum, false, { task_mod.serialize(task) })
    end
  end
  require("nvim-tasks.vault").invalidate()
end

function M.cycle_status(bufnr, lnum)
  bufnr = bufnr or vim.api.nvim_get_current_buf(); lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum-1, lnum, false)[1]; if not line then return end
  local task = task_mod.parse(line); if not task then return end
  local od = config.is_done(task.status_symbol); task.status_symbol = config.next_status(task.status_symbol)
  local nd = config.is_done(task.status_symbol)
  if nd and not od and config.get().auto_done_date then task.done_date = date_mod.today_str()
  elseif od and not nd then task.done_date = nil end
  vim.api.nvim_buf_set_lines(bufnr, lnum-1, lnum, false, { task_mod.serialize(task) }); require("nvim-tasks.vault").invalidate()
end

function M.set_priority(bufnr, lnum, priority)
  bufnr = bufnr or vim.api.nvim_get_current_buf(); lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum-1, lnum, false)[1]; if not line then return end
  local task = task_mod.parse(line); if not task then return end
  task.priority = priority; vim.api.nvim_buf_set_lines(bufnr, lnum-1, lnum, false, { task_mod.serialize(task) })
end

function M.increase_priority(bufnr, lnum)
  bufnr = bufnr or vim.api.nvim_get_current_buf(); lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum-1, lnum, false)[1]; if not line then return end
  local task = task_mod.parse(line); if not task then return end
  local lvl = {"lowest","low",nil,"medium","high","highest"}; local idx=3
  for i,v in ipairs(lvl) do if v==task.priority then idx=i; break end end
  task.priority = lvl[math.min(idx+1,#lvl)]; vim.api.nvim_buf_set_lines(bufnr, lnum-1, lnum, false, { task_mod.serialize(task) })
end

function M.decrease_priority(bufnr, lnum)
  bufnr = bufnr or vim.api.nvim_get_current_buf(); lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum-1, lnum, false)[1]; if not line then return end
  local task = task_mod.parse(line); if not task then return end
  local lvl = {"lowest","low",nil,"medium","high","highest"}; local idx=3
  for i,v in ipairs(lvl) do if v==task.priority then idx=i; break end end
  task.priority = lvl[math.max(idx-1,1)]; vim.api.nvim_buf_set_lines(bufnr, lnum-1, lnum, false, { task_mod.serialize(task) })
end

function M.set_date(bufnr, lnum, field, value)
  bufnr = bufnr or vim.api.nvim_get_current_buf(); lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum-1, lnum, false)[1]; if not line then return end
  local task = task_mod.parse(line); if not task then return end
  task[field] = (value ~= "") and value or nil
  vim.api.nvim_buf_set_lines(bufnr, lnum-1, lnum, false, { task_mod.serialize(task) })
end
return M
