-- Loads the BUILT dist/*.lua under the fake REAPER and drives their own defer loop. Run from dev/.
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
local function read(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local MAIN = assert(read("dist/LaneRenumber.lua"), "run tools/build.lua first")
local QUICK = assert(read("dist/LaneRenumber_Quick.lua"), "run tools/build.lua first")

local function scene(cfg)
  -- the bundle must not find the dev modules: clear what earlier requires cached and hide ./src
  for k in pairs(package.loaded) do if k:match("^LaneRenumber") then package.loaded[k] = nil end end
  for k in pairs(package.preload) do package.preload[k] = nil end
  package.path = "./tools/?.lua"
  local S = Mock.install(cfg)
  local a, b = Mock.lane("A"), Mock.lane("B")
  Mock.marker(a, 1, 1); Mock.marker(b, 1.5, 2); Mock.marker(a, 2, 3)
  return S
end
local function run(src, name)
  local fn, err = load(src, "@/scripts/" .. name)
  assert(fn, err)
  return pcall(fn)
end

print("headers")
for _, src in ipairs({ MAIN, QUICK }) do
  local ver = src:match("^%-%- @description[^\n]*\n%-%- @version ([%d%.]+)")
  check("@version on line 2", ver ~= nil, src:sub(1, 100))
  check("no unreplaced placeholder", not src:find("@@VERSION@@", 1, true))
end

print("window: without ReaImGui")
do
  local S = scene()
  local ok, err = run(MAIN, "LaneRenumber.lua")
  check("returns cleanly", ok, err)
  check("user told about ReaImGui", S.mb[1] and S.mb[1]:find("ReaImGui", 1, true) ~= nil)
  check("no loop registered", #S.deferred == 0)
end

print("window: old REAPER")
do
  local S = scene({ old_api = true })
  local G = {}; Stub.install(G)
  local ok = run(MAIN, "LaneRenumber.lua")
  check("tells about ruler lanes", ok and S.mb[1] and S.mb[1]:find("ruler", 1, true) ~= nil)
end

print("window: full run")
do
  local S = scene()
  local G = {}; Stub.install(G)
  local ok, err = run(MAIN, "LaneRenumber.lua")
  check("loads and starts", ok, err)
  check("one deferred callback", #S.deferred == 1)
  check("toolbar toggle on", S.toggles[4242] == 1)
  Mock.pump(S, 2)
  check("title carries version", G.title and G.title:match("v%d+%.%d+%.%d+") ~= nil, G.title)
  G.click = "Renumber (2)"
  Mock.pump(S, 2)
  check("renumbered inside the bundle", Mock.nums("marker") == "0:1 1:3 0:2", Mock.nums("marker"))
  check("no console errors", #S.console == 0, S.console[1])
  -- second run of the action closes the first
  run(MAIN, "LaneRenumber.lua")
  Mock.pump(S, 2)
  check("second run stops the loop", #S.deferred == 0)
  check("toggle off", S.toggles[4242] == 0)
  check("settings saved", S.ext["LaneRenumber/mode"] ~= nil)
  S.atexit()
  check("atexit is harmless after shutdown", true)
end

print("window: closing")
do
  local S = scene()
  local G = {}; Stub.install(G)
  S.ext["LaneRenumberApp/running"] = "0"
  run(MAIN, "LaneRenumber.lua")
  Mock.pump(S, 1)
  reaper.ImGui_Begin = function() return true, false end
  Mock.pump(S, 2)
  check("closing stops the loop", #S.deferred == 0 and S.ext["LaneRenumberApp/running"] == "0")
end

print("quick action")
do
  local S = scene()
  local ok, err = run(QUICK, "LaneRenumber_Quick.lua")
  check("runs without ReaImGui", ok, err)
  check("renumbered", Mock.nums("marker") == "0:1 1:3 0:2", Mock.nums("marker"))
  check("one undo step", #S.undo == 1)
  run(QUICK, "LaneRenumber_Quick.lua")
  check("second run: nothing to do, no extra undo, no dialog", #S.undo == 1 and #S.mb == 0)
  S.ext["LaneRenumber/mode"] = "1"
  run(QUICK, "LaneRenumber_Quick.lua")
  check("uses saved settings (block mode)", Mock.nums("marker") == "0:1 1:101 0:2", Mock.nums("marker"))
end

print(string.format("%d checks, %d failed", n, fails))
if fails > 0 then os.exit(1) end
