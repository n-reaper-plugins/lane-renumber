-- Offline tests for LaneRenumberReaper.lua against the in-memory fake REAPER. Run from dev/.
package.path = "./src/?.lua;./tools/?.lua;" .. package.path
for _, k in ipairs({ "sinh", "cosh", "tanh", "pow", "atan2", "log10", "ldexp", "frexp", "mod" }) do math[k] = nil end
local Mock = require("mock_reaper")

local fails, n = 0, 0
local function check(name, cond, info)
  n = n + 1
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (info ~= nil and ("  [" .. tostring(info) .. "]") or "")) end
end

local function fresh(cfg)
  local S = Mock.install(cfg)
  package.loaded["LaneRenumberReaper"] = nil
  package.loaded["LaneRenumberCore"] = nil
  local Reaper = require("LaneRenumberReaper")
  local set = Reaper.load_settings()
  local state = Reaper.new_state()
  return S, Reaper, set, state, Reaper.new(set, state)
end

print("read the project")
do
  local S, Reaper = fresh()
  local l1, l2 = Mock.lane("Song"), Mock.lane("Cues", { locked = true })
  Mock.marker(l1, 1, 1, "a"); Mock.region(l2, 0, 4, 1, "intro"); Mock.marker(l2, 2, 2, "x", { hidden = true })
  local p = Reaper.read_project()
  check("3 items", #p.items == 3)
  check("lanes with name / guid / locked", p.lanes[0].name == "Song" and p.lanes[1].locked and p.lanes[1].guid ~= "")
  local reg
  for _, it in ipairs(p.items) do if it.kind == "region" then reg = it end end
  check("region with end and lane", reg and reg.rend == 4 and reg.lane == 1 and reg.name == "intro")
  local hid
  for _, it in ipairs(p.items) do if it.name == "x" then hid = it end end
  check("hidden flag read", hid and hid.hidden)
  check("lane_list sorted", table.concat(p.lane_list, ",") == "0,1")
end

print("lane used by a marker but beyond RULER_LANE_COUNT still shows up")
do
  local _, Reaper = fresh()
  Mock.marker(3, 1, 1, "far")
  local p = Reaper.read_project()
  check("lane 3 listed", p.lanes[3] ~= nil and p.lane_list[1] == 3)
end

print("the user's case: lane 1 consecutive, other lane in between")
do
  local S, _, _, state, RA = fresh()
  local a, b = Mock.lane(), Mock.lane()
  Mock.marker(a, 1.0, 1); Mock.marker(b, 1.5, 2); Mock.marker(a, 2.0, 3); Mock.marker(b, 2.5, 4); Mock.marker(a, 3.0, 5)
  RA.refresh()
  check("plan has 4 changes", state.plan.changes == 4, state.plan.changes)
  local ok = RA.apply()
  check("apply ok", ok, state.err)
  check("lane 1 -> 1 2 3, lane 2 -> 4 5", Mock.nums("marker") == "0:1 1:4 0:2 1:5 0:3", Mock.nums("marker"))
  check("one undo step", #S.undo == 1 and S.undo[1]:find("ruler lane", 1, true) ~= nil, S.undo[1])
  check("message", state.msg and state.msg:find("4", 1, true) ~= nil, state.msg)
  check("re-read after apply: nothing left to do", state.plan.changes == 0, state.plan.changes)
end

print("regions: swapping numbers needs the two-phase write")
do
  local S, _, _, state, RA = fresh()
  local a, b = Mock.lane(), Mock.lane()
  -- lane 1 regions currently 2 and 3, lane 2 region is 1 -> lane 1 must become 1,2 and lane 2 -> 3
  Mock.region(a, 0, 1, 2, "A1"); Mock.region(b, 0.5, 1, 1, "B1"); Mock.region(a, 2, 3, 3, "A2")
  RA.refresh()
  local ok = RA.apply()
  check("apply ok even though REAPER refuses duplicate region numbers", ok, state.err)
  check("regions 1,3,2 by position", Mock.nums("region") == "0:1 1:3 0:2", Mock.nums("region"))
end

print("a refused number is reported and never left at a temporary value")
do
  local S, Reaper, set, state, RA = fresh()
  local a = Mock.lane()
  Mock.marker(a, 1, 5); Mock.marker(a, 2, 6)
  RA.refresh()
  local real = reaper.SetRegionOrMarkerInfo_Value
  reaper.SetRegionOrMarkerInfo_Value = function(p, m, k, v)        -- refuses the final number 1
    if v == 1 then return 0 end
    return real(p, m, k, v)
  end
  local ok = RA.apply()
  reaper.SetRegionOrMarkerInfo_Value = real
  check("apply reports failure", not ok and state.err and state.err:find("did not accept 1", 1, true) ~= nil, state.err)
  check("refused one is back at its old number", Mock.nums("marker") == "0:5 0:2", Mock.nums("marker"))
end

print("excluded lane: remembered per project by lane GUID")
do
  local S, Reaper, set, state, RA = fresh()
  local a, b = Mock.lane("A"), Mock.lane("B")
  Mock.marker(a, 1, 7); Mock.marker(b, 2, 1); Mock.marker(a, 3, 8)
  RA.refresh()
  RA.set_excluded(1, true)
  RA.refresh()
  check("saved as lane GUID", S.projext["LaneRenumber/excluded"] == S.lanes[2].guid, S.projext["LaneRenumber/excluded"])
  check("ExtState write does not count as a project change", state.dirty == false and state.plan ~= nil)
  RA.apply()
  check("lane 2 kept at 1, lane 1 skips it", Mock.nums("marker") == "0:2 1:1 0:3", Mock.nums("marker"))
  -- a new session reads the exclusion back
  local state2 = Reaper.new_state()
  local RA2 = Reaper.new(set, state2)
  RA2.refresh()
  check("exclusion restored", state2.excluded[1] == true)
  RA2.set_excluded(1, false)
  check("cleared", S.projext["LaneRenumber/excluded"] == "")
end

print("blocking plan is not written")
do
  local S, Reaper, set, state, RA = fresh()
  local a, b = Mock.lane(), Mock.lane()
  Mock.region(a, 0, 1, 1); Mock.region(b, 2, 3, 2)
  set.mode = 2; state.dirty = true
  RA.refresh()
  local before = S.sets
  check("restart mode with regions is blocked", state.plan.blocking ~= nil)
  check("apply refuses", RA.apply() == false and S.sets == before and #S.undo == 0)
end

print("settings round trip")
do
  local S, Reaper, set = fresh()
  set.mode, set.start = 1, 10
  Reaper.save_settings(set)
  local s2 = Reaper.load_settings()
  check("saved and loaded", s2.mode == 1 and s2.start == 10 and s2.block == 100)
end

print("project tab switch rescans")
do
  local S, _, _, state, RA = fresh()
  local a = Mock.lane(); Mock.marker(a, 1, 3)
  RA.refresh()
  local p1 = state.plan
  S.proj = { name = "proj2" }
  RA.refresh()
  check("new plan for the other tab", state.plan ~= p1)
  local p2 = state.plan
  RA.refresh()
  check("no rescan when nothing changed", state.plan == p2)
end

print("old REAPER")
do
  local _, Reaper = fresh({ old_api = true })
  check("api_ok false", not Reaper.api_ok())
end

print(string.format("%d checks, %d failed", n, fails))
if fails > 0 then os.exit(1) end
