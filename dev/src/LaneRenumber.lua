-- @description Lane Renumber: renumber markers and regions by ruler lane (consecutive numbers per lane)
-- @version @@VERSION@@
-- @about
--   Renumbers markers and regions lane by lane: the markers on lane 1 get consecutive numbers in time order,
--   no matter what other lanes have before or in between them; then lane 2, and so on.
--   Modes: continuous across lanes (1..N on lane 1, N+1.. on lane 2), a block per lane (1, 101, 201 ...),
--   or restart on every lane. Markers and regions are numbered separately, like REAPER does.
--   Untick a lane to keep its numbers (remembered per project); locked lanes and hidden markers can be kept too.
--   A live preview shows old -> new before anything changes; applying is one undo step.
--   Run the action again while the window is open to close it.
--   "LaneRenumber_Quick.lua" renumbers at once with the last settings (for a toolbar / shortcut).
--   Requires ReaImGui (ReaPack > ReaTeam Extensions) and REAPER 7 with ruler lanes.

local r = reaper
local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = dir .. "?.lua;" .. package.path

local SCRIPT_NAME = "Lane Renumber"

if not r.ImGui_CreateContext then
  r.MB("This script needs the ReaImGui extension.\n\nInstall it via ReaPack (Extensions > ReaPack > Browse packages > 'ReaImGui').", SCRIPT_NAME, 0)
  return
end

local Core = require("LaneRenumberCore")
local Reaper = require("LaneRenumberReaper")
local UI = require("LaneRenumberUI")

if not Reaper.api_ok() then
  r.MB(Reaper.API_MSG, SCRIPT_NAME, 0)
  return
end

local EXT = Reaper.EXT .. "App"

-- single instance: running the action a second time asks the running one to close
local hb_age = os.time() - (tonumber(r.GetExtState(EXT, "hb")) or 0)
if r.GetExtState(EXT, "running") == "1" and hb_age < 3 then
  r.SetExtState(EXT, "stop", "1", false)
  return
end
r.SetExtState(EXT, "running", "1", false)
r.SetExtState(EXT, "stop", "0", false)
r.SetExtState(EXT, "hb", tostring(os.time()), false)

local _, _, sec, cmdid = r.get_action_context()
local function set_toggle(on)
  if cmdid and cmdid ~= 0 then r.SetToggleCommandState(sec, cmdid, on and 1 or 0); r.RefreshToolbar2(sec, cmdid) end
end
set_toggle(true)

local S = Reaper.load_settings()
local state = Reaper.new_state()
local RA = Reaper.new(S, state)
local ui = UI.new(S, state, RA, SCRIPT_NAME .. " v" .. Core.VERSION .. "###lane_renumber_main")

local done = false
local function shutdown()
  if done then return end
  done = true
  RA.save_settings()
  set_toggle(false)
  r.SetExtState(EXT, "running", "0", false)
  r.SetExtState(EXT, "stop", "0", false)
end
r.atexit(shutdown)

local last_hb, last_err = 0, nil
local function loop()
  if r.GetExtState(EXT, "stop") == "1" then shutdown(); return end
  local now = r.time_precise()
  if now - last_hb > 1 then r.SetExtState(EXT, "hb", tostring(os.time()), false); last_hb = now end

  local ok, err = pcall(RA.refresh)
  if not ok and tostring(err) ~= last_err then
    last_err = tostring(err)
    state.err = "Error: " .. last_err
  end
  if ui.frame() then r.defer(loop) else shutdown() end
end

r.defer(loop)
