-- Window code with a stubbed ImGui and the fake REAPER. Run from dev/.
package.path = "./src/?.lua;./tools/?.lua;" .. package.path
for _, k in ipairs({ "sinh", "cosh", "tanh", "pow", "atan2", "log10", "ldexp", "frexp", "mod" }) do math[k] = nil end
local Mock = require("mock_reaper")
local Stub = require("imgui_stub")

local fails, n = 0, 0
local function check(name, cond, info)
  n = n + 1
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (info ~= nil and ("  [" .. tostring(info) .. "]") or "")) end
end

local S = Mock.install()
local G = {}
Stub.install(G)
local Reaper = require("LaneRenumberReaper")
local UI = require("LaneRenumberUI")
local a, b = Mock.lane("Song"), Mock.lane("Cues")
Mock.marker(a, 1, 1, "verse"); Mock.marker(b, 1.5, 2, "cue"); Mock.marker(a, 2, 3, "chorus")
Mock.region(a, 0, 4, 1, "part")

local set = Reaper.load_settings()
local state = Reaper.new_state()
local RA = Reaper.new(set, state)
local ui = UI.new(set, state, RA, "Lane Renumber###t")
local function frame() RA.refresh(); return ui.frame() end

print("first frame")
do
  check("window open", frame() == true)
  local txt = Stub.text(G)
  check("summary line", txt:find("3 markers, 1 regions on 2 lane(s)", 1, true) ~= nil, txt:sub(1, 200))
  check("lane label with name", G.checks["Lane 1  Song   (2 markers, 1 regions)"] == true)
  check("preview shows the new number of 'cue'", txt:find("cue", 1, true) ~= nil and txt:find("\n3\n", 1, true) ~= nil)
  check("balanced Begin/End and tables", G.depth == 0, G.depth)
  check("theme pushed and popped", G.styles == 0, G.styles)
  check("Renumber enabled", G.buttons["Renumber (2)"] and not G.buttons["Renumber (2)"].disabled)
end

print("mode change -> live preview")
do
  G.set["##mode"] = 1
  frame(); Stub.text(G); frame()
  local txt = Stub.text(G)
  check("block hint shown", txt:find("lane 2 -> 101", 1, true) ~= nil)
  check("cue -> 101", txt:find("\n101\n", 1, true) ~= nil or txt:find("\n101$", 1, false) ~= nil)
  G.set["##mode"] = 0
  frame(); Stub.text(G)
end

print("untick a lane")
do
  G.click = "Lane 2  Cues   (1 markers, 0 regions)"
  frame()
  check("lane 2 excluded", state.excluded[1] == true)
  frame()
  local txt = Stub.text(G)
  check("kept row shown", txt:find("keep (lane off)", 1, true) ~= nil)
  G.click = "Lane 2  Cues   (1 markers, 0 regions)"
  frame(); frame(); Stub.text(G)
  check("lane 2 back", not state.excluded[1])
end

print("apply")
do
  G.click = "Renumber (2)"
  frame()
  frame()
  local txt = Stub.text(G)
  check("numbers written", Mock.nums("marker") == "0:1 1:3 0:2", Mock.nums("marker"))
  check("success message", txt:find("Renumbered 2", 1, true) ~= nil, txt)
  check("button now disabled (nothing to do)", G.buttons["Renumber (0)"] and G.buttons["Renumber (0)"].disabled)
end

print("restart mode blocks with regions duplicated")
do
  Mock.region(b, 5, 6, 2, "other")
  G.set["##mode"] = 2
  frame(); frame()
  local txt = Stub.text(G)
  check("blocking message", txt:find("REAPER refuses duplicate region numbers", 1, true) ~= nil)
  local btn
  for k, v in pairs(G.buttons) do if k:match("^Renumber") then btn = v end end
  check("button disabled", btn and btn.disabled)
end

print("empty project")
do
  S.marks = {}; S.lanes = {}; S.change = S.change + 1
  frame()
  local txt = Stub.text(G)
  check("says so", txt:find("No markers or regions", 1, true) ~= nil)
  check("still balanced", G.depth == 0 and G.styles == 0)
end

print("closing")
do
  reaper.ImGui_Begin = function() return true, false end
  check("frame returns false", ui.frame() == false)
end

print(string.format("%d checks, %d failed", n, fails))
if fails > 0 then os.exit(1) end
