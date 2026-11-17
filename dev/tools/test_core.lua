-- Offline tests for LaneRenumberCore.lua (pure logic). Run from dev/:  lua tools/test_core.lua
package.path = "./src/?.lua;./tools/?.lua;" .. package.path
-- REAPER's Lua has no deprecated math functions; make sure we do not rely on them
for _, k in ipairs({ "sinh", "cosh", "tanh", "pow", "atan2", "log10", "ldexp", "frexp", "mod" }) do math[k] = nil end
local Core = require("LaneRenumberCore")

local fails, n = 0, 0
local function check(name, cond, info)
  n = n + 1
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (info ~= nil and ("  [" .. tostring(info) .. "]") or "")) end
end
local function copy(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end

local G = 0
local function mk(kind, lane, pos, num, name, rend, hidden)
  G = G + 1
  return { guid = string.format("{%04d}", G), kind = kind, lane = lane, pos = pos, rend = rend or pos,
           num = num, name = name or (kind .. num), hidden = hidden or false }
end
local function M_(lane, pos, num, name) return mk("marker", lane, pos, num, name) end
local function R_(lane, pos, rend, num, name) return mk("region", lane, pos, num, name, rend) end

-- "name=new" for every row of a kind (in display order), e.g. "a=1 b=2"
local function result(plan, kind)
  local t = {}
  for _, row in ipairs(plan.rows) do if row.kind == kind then t[#t + 1] = row.name .. "=" .. row.new end end
  return table.concat(t, " ")
end
local function lanes(n, opt)
  local t = {}
  for i = 0, n - 1 do t[i] = { index = i, name = "", guid = "L" .. i, hidden = false, locked = false } end
  for i, o in pairs(opt or {}) do for k, v in pairs(o) do t[i][k] = v end end
  return t
end

-- the user's case: lane 1 markers interleaved with lane 2 markers in time
local function scene()
  return {
    M_(0, 1.0, 1, "a"), M_(1, 1.5, 2, "x"), M_(0, 2.0, 3, "b"), M_(1, 2.5, 4, "y"), M_(0, 3.0, 5, "c"),
  }
end

print("continuous (default)")
do
  local p = Core.plan(scene(), lanes(2), Core.DEFAULTS)
  check("lane 1 first, consecutive", result(p, "marker") == "a=1 b=2 c=3 x=4 y=5", result(p, "marker"))
  check("4 changes", p.changes == 4, p.changes)
  check("no blocking, no warnings", p.blocking == nil and #p.warnings == 0)
end

print("time order inside a lane, not old number")
do
  local items = { M_(0, 5, 1, "late"), M_(0, 1, 9, "early"), M_(0, 3, 4, "mid") }
  local p = Core.plan(items, lanes(1), Core.DEFAULTS)
  check("sorted by position", result(p, "marker") == "early=1 mid=2 late=3", result(p, "marker"))
end

print("ties: same position -> end, then old number")
do
  local items = { R_(0, 1, 9, 7, "long"), R_(0, 1, 4, 8, "short"), M_(0, 2, 6, "m1"), M_(0, 2, 2, "m2") }
  local p = Core.plan(items, lanes(1), Core.DEFAULTS)
  check("regions: shorter first at same start", result(p, "region") == "short=1 long=2", result(p, "region"))
  check("markers: lower old number first", result(p, "marker") == "m2=1 m1=2", result(p, "marker"))
end

print("markers and regions are separate series")
do
  local items = { R_(0, 0, 4, 3, "r1"), M_(0, 1, 1, "m1"), R_(1, 2, 6, 1, "r2"), M_(1, 3, 2, "m2") }
  local p = Core.plan(items, lanes(2), Core.DEFAULTS)
  check("markers 1,2", result(p, "marker") == "m1=1 m2=2", result(p, "marker"))
  check("regions 1,2", result(p, "region") == "r1=1 r2=2", result(p, "region"))
end

print("block per lane")
do
  local S = copy(Core.DEFAULTS); S.mode = Core.MODE_BLOCK
  local p = Core.plan(scene(), lanes(2), S)
  check("lane 1 -> 1.., lane 2 -> 101..", result(p, "marker") == "a=1 b=2 c=3 x=101 y=102", result(p, "marker"))
  S.start, S.block = 10, 10
  p = Core.plan(scene(), lanes(2), S)
  check("start 10, block 10", result(p, "marker") == "a=10 b=11 c=12 x=20 y=21", result(p, "marker"))
  S.block = 2
  p = Core.plan(scene(), lanes(2), S)
  check("overflow warned for lane 1 only", p.warnings[1]:find("Lane 1", 1, true) ~= nil
    and not table.concat(p.warnings, "|"):find("Lane 2", 1, true), table.concat(p.warnings, "|"))
  check("overflow makes duplicates -> marker warning", p.n_dup_markers > 0)
end

print("block mode uses the lane INDEX (empty lanes keep their block)")
do
  local items = { M_(0, 1, 5, "a"), M_(2, 2, 6, "z") }
  local S = copy(Core.DEFAULTS); S.mode = Core.MODE_BLOCK
  local p = Core.plan(items, lanes(3), S)
  check("lane 3 starts at 201", result(p, "marker") == "a=1 z=201", result(p, "marker"))
end

print("restart on every lane")
do
  local S = copy(Core.DEFAULTS); S.mode = Core.MODE_RESTART
  local p = Core.plan(scene(), lanes(2), S)
  check("each lane from 1", result(p, "marker") == "a=1 b=2 c=3 x=1 y=2", result(p, "marker"))
  check("markers duplicated -> warning, not blocking", p.n_dup_markers == 2 and p.blocking == nil, p.n_dup_markers)
  local items = { R_(0, 0, 1, 1, "r1"), R_(1, 2, 3, 2, "r2") }
  p = Core.plan(items, lanes(2), S)
  check("regions duplicated -> blocking", p.blocking ~= nil and p.n_dup_regions == 1)
end

print("excluded lane keeps numbers, others skip them")
do
  local p = Core.plan(scene(), lanes(2), Core.DEFAULTS, { [1] = true })
  check("lane 2 kept, lane 1 jumps over 2 and 4", result(p, "marker") == "a=1 b=3 c=5 x=2 y=4", result(p, "marker"))
  check("nothing changes here", p.changes == 0, p.changes)
  local items = { M_(0, 1, 7, "a"), M_(0, 2, 8, "b"), M_(1, 0, 1, "k") }
  p = Core.plan(items, lanes(2), Core.DEFAULTS, { [1] = true })
  check("skips the kept 1", result(p, "marker") == "a=2 b=3 k=1", result(p, "marker"))
  local S = copy(Core.DEFAULTS); S.skip_kept = 0
  p = Core.plan(items, lanes(2), S, { [1] = true })
  check("skip off -> duplicate 1 warned", result(p, "marker") == "a=1 b=2 k=1" and p.n_dup_markers == 1, result(p, "marker"))
  check("kept row says why", p.rows[#p.rows].keep == "lane off", p.rows[#p.rows].keep)
end

print("locked lanes and hidden markers")
do
  local items = { M_(0, 1, 9, "a"), M_(1, 2, 1, "locked"), M_(0, 3, 8, "b") }
  items[#items + 1] = mk("marker", 0, 4, 2, "hid", nil, true)
  local L = lanes(2, { [1] = { locked = true } })
  local p = Core.plan(items, L, Core.DEFAULTS)
  check("locked lane kept by default, hidden renumbered", result(p, "marker") == "a=2 b=3 hid=4 locked=1", result(p, "marker"))
  local S = copy(Core.DEFAULTS); S.skip_locked = 0; S.skip_hidden = 1
  p = Core.plan(items, L, S)
  check("locked renumbered, hidden kept", result(p, "marker") == "a=1 b=3 hid=2 locked=4", result(p, "marker"))
end

print("markers / regions off")
do
  local items = { R_(0, 0, 1, 5, "r"), M_(0, 1, 5, "m") }
  local S = copy(Core.DEFAULTS); S.do_regions = 0
  local p = Core.plan(items, lanes(1), S)
  check("regions untouched", result(p, "region") == "r=5" and result(p, "marker") == "m=1")
  S.do_regions, S.do_markers = 1, 0
  p = Core.plan(items, lanes(1), S)
  check("markers untouched", result(p, "region") == "r=1" and result(p, "marker") == "m=5")
end

print("already in order")
do
  local items = { M_(0, 1, 1, "a"), M_(0, 2, 2, "b"), M_(1, 3, 3, "c") }
  local p = Core.plan(items, lanes(2), Core.DEFAULTS)
  check("no changes", p.changes == 0 and #Core.write_steps(p) == 0)
end

print("write steps")
do
  local p = Core.plan(scene(), lanes(2), Core.DEFAULTS)
  local steps = Core.write_steps(p)
  check("one step per change", #steps == p.changes, #steps)
  local used = {}
  for _, it in ipairs(scene()) do used[it.num] = true end
  local ok = true
  for _, s in ipairs(steps) do if used[s.tmp] or s.tmp <= 5 then ok = false end end
  check("temporary numbers are free and above everything", ok)
  local tmps = {}
  for _, s in ipairs(steps) do if tmps[s.tmp] then ok = false end tmps[s.tmp] = true end
  check("temporary numbers unique", ok)
end

print("params are sanitised")
do
  local P = Core.params({ mode = 9, start = -5, block = 0, do_markers = "1" })
  check("clamped", P.mode == 2 and P.start == 0 and P.block == 1 and P.do_markers == 1)
  local p = Core.plan({}, {}, Core.DEFAULTS)
  check("empty project", #p.rows == 0 and p.changes == 0)
end

print("display order: lane, regions before markers, position")
do
  local items = { M_(1, 0, 1, "m2"), R_(0, 5, 6, 1, "r1"), M_(0, 1, 2, "m1") }
  local p = Core.plan(items, lanes(2), Core.DEFAULTS)
  local order = {}
  for _, row in ipairs(p.rows) do order[#order + 1] = row.name end
  check("order", table.concat(order, ",") == "r1,m1,m2", table.concat(order, ","))
end

print(string.format("%d checks, %d failed", n, fails))
if fails > 0 then os.exit(1) end
