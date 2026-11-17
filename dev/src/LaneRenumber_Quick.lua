-- @description Lane Renumber (quick): renumber markers and regions by ruler lane with the last settings, no window
-- @version @@VERSION@@
-- @about
--   Same as Lane Renumber, without the window: uses the settings and lane ticks last used in the window
--   (defaults: markers and regions, continuous across lanes, starting at 1). One undo step.
--   Does not need ReaImGui. Needs REAPER 7 with ruler lanes.

local r = reaper
local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = dir .. "?.lua;" .. package.path

local Reaper = require("LaneRenumberReaper")

if not Reaper.api_ok() then
  r.MB(Reaper.API_MSG, Reaper.SCRIPT_NAME, 0)
  return
end

local S = Reaper.load_settings()
local state = Reaper.new_state()
local RA = Reaper.new(S, state)
RA.refresh(true)
if state.plan.changes == 0 and not state.plan.blocking then return end   -- already in order: stay silent
RA.apply()
if state.err then r.MB(state.err, Reaper.SCRIPT_NAME, 0) end
