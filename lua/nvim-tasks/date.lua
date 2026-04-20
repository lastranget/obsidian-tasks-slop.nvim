local M = {}
function M.parse(s)
  if not s or s == "" then return nil end
  local y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then return nil end
  return { year = tonumber(y), month = tonumber(m), day = tonumber(d) }
end
function M.format(dt) return string.format("%04d-%02d-%02d", dt.year, dt.month, dt.day) end
function M.today() local t = os.date("*t"); return { year = t.year, month = t.month, day = t.day } end
function M.today_str() return M.format(M.today()) end
function M.to_ts(dt) return os.time({ year = dt.year, month = dt.month, day = dt.day, hour = 12 }) end
function M.from_ts(ts) local t = os.date("*t", ts); return { year = t.year, month = t.month, day = t.day } end
function M.add_days(dt, n) return M.from_ts(M.to_ts(dt) + n * 86400) end
function M.add_weeks(dt, n) return M.add_days(dt, n * 7) end
function M.add_months(dt, n)
  local m, y = dt.month + n, dt.year
  while m > 12 do m = m - 12; y = y + 1 end
  while m < 1 do m = m + 12; y = y - 1 end
  return { year = y, month = m, day = math.min(dt.day, M.days_in_month(y, m)) }
end
function M.add_years(dt, n)
  local y = dt.year + n
  return { year = y, month = dt.month, day = math.min(dt.day, M.days_in_month(y, dt.month)) }
end
function M.days_in_month(year, month)
  local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if month == 2 and M.is_leap(year) then return 29 end; return days[month]
end
function M.is_leap(year) return (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0) end
function M.compare(a, b)
  if not a and not b then return 0 end; if not a then return 1 end; if not b then return -1 end
  if a.year ~= b.year then return a.year < b.year and -1 or 1 end
  if a.month ~= b.month then return a.month < b.month and -1 or 1 end
  if a.day ~= b.day then return a.day < b.day and -1 or 1 end; return 0
end
function M.before(a, b) return M.compare(a, b) < 0 end
function M.after(a, b) return M.compare(a, b) > 0 end
function M.equal(a, b) return M.compare(a, b) == 0 end
function M.on_or_before(a, b) return M.compare(a, b) <= 0 end
function M.on_or_after(a, b) return M.compare(a, b) >= 0 end
function M.weekday(dt) return os.date("*t", M.to_ts(dt)).wday - 1 end
function M.is_weekday(dt) local wd = M.weekday(dt); return wd >= 1 and wd <= 5 end
function M.parse_relative(s)
  if not s then return nil end; s = vim.trim(s:lower())
  if s == "today" then return M.today() end
  if s == "tomorrow" then return M.add_days(M.today(), 1) end
  if s == "yesterday" then return M.add_days(M.today(), -1) end
  local offset, unit = s:match("^([+-]%d+)([dwmy])$")
  if offset and unit then
    local n = tonumber(offset)
    if unit == "d" then return M.add_days(M.today(), n) end
    if unit == "w" then return M.add_weeks(M.today(), n) end
    if unit == "m" then return M.add_months(M.today(), n) end
    if unit == "y" then return M.add_years(M.today(), n) end
  end
  return M.parse(s)
end
return M
