-- @description Lane Renumber (quick): renumber markers and regions by ruler lane with the last settings, no window
-- @version 0.1.0
-- @about
--   Same as Lane Renumber, without the window: uses the settings and lane ticks last used in the window
--   (defaults: markers and regions, continuous across lanes, starting at 1). One undo step.
--   Does not need ReaImGui. Needs REAPER 7 with ruler lanes.
-- BUNDLED BUILD of Lane Renumber v0.1.0 - edit the files in dev/src/, not this one.
local __preload = package.preload
__preload["LaneRenumberCore"] = function(...)
-- LaneRenumberCore.lua
-- Pure logic, no REAPER calls: given the markers / regions of a project (with their ruler lane) and the
-- settings, work out the new number of every one of them. The adapter (LaneRenumberReaper.lua) reads the
-- project into this shape and writes the plan back.
--
-- Item shape (one per marker or region):
--   { guid = "{...}", kind = "marker" | "region", lane = 0-based ruler lane, pos = s, rend = s (= pos for markers),
--     num = displayed number, name = "", hidden = bool }
-- Lane shape (lanes[lane] = ...):
--   { index = 0-based lane, name = "", guid = "", hidden = bool, locked = bool }
--
-- Markers and regions are numbered independently (REAPER keeps two separate number series).

local M = {}

M.VERSION = "0.1.0"

M.MODES = { "Continuous: lane 1 first, then lane 2 ...", "Block per lane: lane N starts at start + (N-1) x block",
            "Restart on every lane (duplicate numbers across lanes)" }
M.MODE_CONT, M.MODE_BLOCK, M.MODE_RESTART = 0, 1, 2

M.DEFAULTS = {
  do_markers = 1,    -- renumber markers
  do_regions = 1,    -- renumber regions
  mode = 0,          -- see MODES
  start = 1,         -- first number
  block = 100,       -- block size for MODE_BLOCK
  skip_kept = 1,     -- never hand out a number that a KEPT marker/region (excluded lane, hidden ...) already uses
  skip_hidden = 0,   -- hidden markers/regions keep their number
  skip_locked = 1,   -- markers/regions on locked lanes keep their number
  only_changes = 0,  -- UI: preview shows only what changes
}

function M.clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

local function int(v, d) v = tonumber(v); if not v then return d end return math.floor(v + 0.5) end

-- sanitised copy of the numeric settings
function M.params(S)
  local P = {}
  for k, v in pairs(M.DEFAULTS) do P[k] = int(S and S[k], v) end
  P.mode = M.clamp(P.mode, 0, 2)
  P.start = M.clamp(P.start, 0, 1000000)
  P.block = M.clamp(P.block, 1, 1000000)
  return P
end

-- order inside a lane: position, then end, then the old number, then GUID (fully deterministic)
function M.cmp(a, b)
  if a.pos ~= b.pos then return a.pos < b.pos end
  if a.rend ~= b.rend then return a.rend < b.rend end
  if a.num ~= b.num then return a.num < b.num end
  return a.guid < b.guid
end

-- why an item keeps its number (nil = it is renumbered)
-- excluded[lane] = true for lanes the user unticked
function M.keep_reason(it, lanes, P, excluded)
  if it.kind == "marker" and P.do_markers == 0 then return "markers off" end
  if it.kind == "region" and P.do_regions == 0 then return "regions off" end
  if excluded and excluded[it.lane] then return "lane off" end
  local ln = lanes and lanes[it.lane]
  if P.skip_locked ~= 0 and ln and ln.locked then return "lane locked" end
  if P.skip_hidden ~= 0 and it.hidden then return "hidden" end
  return nil
end

--------------------------------------------------------------------------------
-- The plan.
-- Returns {
--   rows      = every item, in display order (lane, kind, position) with .new (number after) and .keep (reason or nil),
--   changes   = number of items whose number changes,
--   targets   = number of items that are renumbered (changed or not),
--   dups      = { marker = {num = count>1}, region = {...} } numbers that will exist more than once afterwards,
--   n_dup_markers, n_dup_regions,
--   blocking  = text or nil: why applying is not allowed (REAPER refuses duplicate REGION numbers),
--   warnings  = { text, ... },
-- }
--------------------------------------------------------------------------------
function M.plan(items, lanes, S, excluded)
  local P = M.params(S)
  local plan = { rows = {}, changes = 0, targets = 0, dups = { marker = {}, region = {} }, warnings = {},
                 n_dup_markers = 0, n_dup_regions = 0 }

  for _, kind in ipairs({ "marker", "region" }) do
    local targets, reserved, by_lane, lane_list = {}, {}, {}, {}
    for _, it in ipairs(items) do
      if it.kind == kind then
        local row = { item = it, guid = it.guid, kind = kind, lane = it.lane, pos = it.pos, rend = it.rend,
                      name = it.name, old = it.num, new = it.num, hidden = it.hidden }
        row.keep = M.keep_reason(it, lanes, P, excluded)
        plan.rows[#plan.rows + 1] = row
        if row.keep then
          reserved[it.num] = true
        else
          targets[#targets + 1] = row
          if not by_lane[it.lane] then by_lane[it.lane] = {}; lane_list[#lane_list + 1] = it.lane end
          local g = by_lane[it.lane]
          g[#g + 1] = row
        end
      end
    end
    table.sort(lane_list)
    if P.skip_kept == 0 then reserved = {} end

    local n = P.start
    for _, lane in ipairs(lane_list) do
      local g = by_lane[lane]
      table.sort(g, function(a, b) return M.cmp(a.item, b.item) end)
      if P.mode == M.MODE_BLOCK then n = P.start + lane * P.block
      elseif P.mode == M.MODE_RESTART then n = P.start end
      local first = n
      for _, row in ipairs(g) do
        while reserved[n] do n = n + 1 end
        row.new = n
        n = n + 1
      end
      if P.mode == M.MODE_BLOCK and n - first > P.block then
        plan.warnings[#plan.warnings + 1] = string.format(
          "Lane %d: %d %ss run past the block of %d into the next lane's numbers.", lane + 1, #g, kind, P.block)
      end
    end
    plan.targets = plan.targets + #targets

    -- duplicates after the change (renumbered + kept, same kind)
    local count = {}
    for _, row in ipairs(plan.rows) do
      if row.kind == kind then count[row.new] = (count[row.new] or 0) + 1 end
    end
    local nd = 0
    for num, c in pairs(count) do if c > 1 then plan.dups[kind][num] = c; nd = nd + 1 end end
    if kind == "marker" then plan.n_dup_markers = nd else plan.n_dup_regions = nd end
  end

  for _, row in ipairs(plan.rows) do
    row.dup = plan.dups[row.kind][row.new] ~= nil
    if row.new ~= row.old then plan.changes = plan.changes + 1 end
  end

  table.sort(plan.rows, function(a, b)
    if a.lane ~= b.lane then return a.lane < b.lane end
    if a.kind ~= b.kind then return a.kind == "region" end      -- regions first, like the ruler
    return M.cmp(a.item, b.item)
  end)

  if plan.n_dup_regions > 0 then
    plan.blocking = string.format("%d region number(s) would exist twice. REAPER refuses duplicate region numbers: "
      .. "use Continuous or Block mode, or tick 'Skip numbers used by kept ones'.", plan.n_dup_regions)
  end
  if plan.n_dup_markers > 0 then
    plan.warnings[#plan.warnings + 1] = string.format("%d marker number(s) will exist more than once.", plan.n_dup_markers)
  end
  return plan
end

-- the numbers to write, in a collision-free order: first every changed item goes to a temporary number above
-- everything in use, then to its final number. Returns { {guid, kind, tmp, new}, ... } or {} when nothing changes.
function M.write_steps(plan)
  local maxn = { marker = 0, region = 0 }
  for _, row in ipairs(plan.rows) do
    maxn[row.kind] = math.max(maxn[row.kind], row.old, row.new)
  end
  local steps, k = {}, { marker = 0, region = 0 }
  for _, row in ipairs(plan.rows) do
    if row.new ~= row.old then
      k[row.kind] = k[row.kind] + 1
      steps[#steps + 1] = { guid = row.guid, kind = row.kind, old = row.old, new = row.new,
                            tmp = maxn[row.kind] + 1000 + k[row.kind] }
    end
  end
  return steps
end

-- short counts for the header line
function M.summary(items, lanes)
  local nm, nr, used = 0, 0, {}
  for _, it in ipairs(items) do
    if it.kind == "marker" then nm = nm + 1 else nr = nr + 1 end
    used[it.lane] = true
  end
  local nl = 0
  for _ in pairs(used) do nl = nl + 1 end
  return nm, nr, nl
end

return M

end
__preload["LaneRenumberReaper"] = function(...)
-- LaneRenumberReaper.lua
-- Everything that talks to REAPER except the window: settings, reading markers / regions and ruler lanes,
-- per-project lane exclusions, and writing the numbers (one undo step, verified by reading back).
-- The numbering logic lives in LaneRenumberCore.lua.
--
-- API used (REAPER 7 ruler lanes):
--   GetNumRegionsOrMarkers / GetRegionOrMarker / GetRegionOrMarkerInfo_Value / SetRegionOrMarkerInfo_Value
--     (D_STARTPOS, D_ENDPOS, I_NUMBER, I_LANENUMBER, B_ISREGION, B_HIDDEN)
--   GetSetRegionOrMarkerInfo_String (GUID, P_NAME)
--   GetSetProjectInfo RULER_LANE_COUNT / RULER_LANE_HIDDEN:X / RULER_LANE_LOCKED:X
--   GetSetProjectInfo_String RULER_LANE_NAME:X / RULER_LANE_GUID:X

local Core = require("LaneRenumberCore")

local M = {}
local r = reaper
local EXT = "LaneRenumber"
local SCRIPT_NAME = "Lane Renumber"
M.EXT, M.SCRIPT_NAME = EXT, SCRIPT_NAME
M.UNDO_NAME = "Renumber markers/regions by ruler lane"

-- true when this REAPER has the marker/region object API with lanes
function M.api_ok()
  return r.GetNumRegionsOrMarkers ~= nil and r.GetRegionOrMarker ~= nil
     and r.GetRegionOrMarkerInfo_Value ~= nil and r.SetRegionOrMarkerInfo_Value ~= nil
end
M.API_MSG = "This REAPER has no ruler-lane marker API (GetRegionOrMarker / I_LANENUMBER).\n"
  .. "Update to a REAPER 7 version with ruler lanes."

function M.load_settings()
  local S = {}
  for k, v in pairs(Core.DEFAULTS) do S[k] = tonumber(r.GetExtState(EXT, k)) or v end
  return S
end

function M.save_settings(S)
  for k, _ in pairs(Core.DEFAULTS) do r.SetExtState(EXT, k, tostring(S[k]), true) end
end

function M.new_state()
  return {
    proj = nil, change = -1,       -- what the cached scan belongs to
    items = {}, lanes = {}, lane_list = {}, excluded = {},
    plan = nil, dirty = true,
    err = nil, msg = nil, warn = nil,
  }
end

--------------------------------------------------------------------------------
-- reading
--------------------------------------------------------------------------------
local function pval(key, d)
  local ok, v = pcall(r.GetSetProjectInfo, 0, key, 0, false)
  if ok and type(v) == "number" then return v end
  return d
end
local function pstr(key)
  if not r.GetSetProjectInfo_String then return "" end
  local ok, a, b = pcall(r.GetSetProjectInfo_String, 0, key, "", false)
  if ok and a and type(b) == "string" then return b end
  return ""
end
local function mval(m, key) return r.GetRegionOrMarkerInfo_Value(0, m, key) end
local function mstr(m, key)
  local ok, s = r.GetSetRegionOrMarkerInfo_String(0, m, key, "", false)
  return ok and s or ""
end

-- { items = {...}, lanes = { [idx] = {...} }, lane_list = { idx, ... } } of the current project
function M.read_project()
  local items, lanes = {}, {}
  local n = r.GetNumRegionsOrMarkers(0)
  for i = 0, n - 1 do
    local m = r.GetRegionOrMarker(0, i, "")
    if m then
      local isrgn = mval(m, "B_ISREGION") ~= 0
      local pos = mval(m, "D_STARTPOS")
      items[#items + 1] = {
        guid = mstr(m, "GUID"), kind = isrgn and "region" or "marker",
        lane = math.floor(mval(m, "I_LANENUMBER") + 0.5),
        pos = pos, rend = isrgn and mval(m, "D_ENDPOS") or pos,
        num = math.floor(mval(m, "I_NUMBER") + 0.5),
        name = mstr(m, "P_NAME"), hidden = mval(m, "B_HIDDEN") ~= 0,
      }
    end
  end
  local count = math.floor(pval("RULER_LANE_COUNT", 0) + 0.5)
  local function lane(idx)
    if not lanes[idx] then
      lanes[idx] = {
        index = idx, name = pstr("RULER_LANE_NAME:" .. idx), guid = pstr("RULER_LANE_GUID:" .. idx),
        hidden = pval("RULER_LANE_HIDDEN:" .. idx, 0) ~= 0, locked = pval("RULER_LANE_LOCKED:" .. idx, 0) ~= 0,
      }
    end
    return lanes[idx]
  end
  for i = 0, count - 1 do lane(i) end
  for _, it in ipairs(items) do lane(it.lane) end
  local lane_list = {}
  for idx in pairs(lanes) do lane_list[#lane_list + 1] = idx end
  table.sort(lane_list)
  return { items = items, lanes = lanes, lane_list = lane_list }
end

-- lanes are remembered by their GUID (survives re-ordering lanes); "#<idx>" when REAPER gives no GUID
local function lane_key(ln) return (ln.guid ~= nil and ln.guid ~= "") and ln.guid or ("#" .. ln.index) end

function M.load_excluded(lanes)
  local _, s = r.GetProjExtState(0, EXT, "excluded")
  local set = {}
  for k in tostring(s or ""):gmatch("[^;]+") do set[k] = true end
  local ex = {}
  for idx, ln in pairs(lanes) do if set[lane_key(ln)] then ex[idx] = true end end
  return ex
end

function M.save_excluded(lanes, excluded)
  local keys = {}
  for idx in pairs(excluded) do if lanes[idx] then keys[#keys + 1] = lane_key(lanes[idx]) end end
  table.sort(keys)
  r.SetProjExtState(0, EXT, "excluded", table.concat(keys, ";"))
end

--------------------------------------------------------------------------------
-- writing
--------------------------------------------------------------------------------
local function by_guid(guid) return r.GetRegionOrMarker(0, -1, guid) end

-- writes a plan; returns ok, message, failures ({ {row-ish}, ... })
function M.write_plan(plan)
  local steps = Core.write_steps(plan)
  if #steps == 0 then return true, "Nothing to change.", {} end
  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)
  -- phase 1: everything that changes moves out of the way, so no final number is taken mid-way
  for _, s in ipairs(steps) do
    local m = by_guid(s.guid)
    if m then r.SetRegionOrMarkerInfo_Value(0, m, "I_NUMBER", s.tmp) end
  end
  -- phase 2: final numbers
  for _, s in ipairs(steps) do
    local m = by_guid(s.guid)
    if m then r.SetRegionOrMarkerInfo_Value(0, m, "I_NUMBER", s.new) end
  end
  -- read back: REAPER may refuse a number (duplicates); never leave a temporary number behind
  local fails = {}
  for _, s in ipairs(steps) do
    local m = by_guid(s.guid)
    local got = m and math.floor(r.GetRegionOrMarkerInfo_Value(0, m, "I_NUMBER") + 0.5)
    if got ~= s.new then
      if m and got == s.tmp then r.SetRegionOrMarkerInfo_Value(0, m, "I_NUMBER", s.old) end
      s.got = m and math.floor(r.GetRegionOrMarkerInfo_Value(0, m, "I_NUMBER") + 0.5) or nil
      fails[#fails + 1] = s
    end
  end
  r.PreventUIRefresh(-1)
  if r.UpdateTimeline then r.UpdateTimeline() end
  r.Undo_EndBlock2(0, M.UNDO_NAME, -1)
  local done = #steps - #fails
  if #fails == 0 then
    return true, string.format("Renumbered %d marker(s)/region(s).", done), fails
  end
  local f = fails[1]
  return false, string.format("Renumbered %d, but REAPER did not accept %d (e.g. %s %d -> %d, now %s). Undo restores everything.",
    done, #fails, f.kind, f.old, f.new, tostring(f.got)), fails
end

--------------------------------------------------------------------------------
-- the object the window and the entry point use
--------------------------------------------------------------------------------
function M.new(S, state)
  local RA = {}

  function RA.save_settings() M.save_settings(S) end

  -- re-read when the project (tab) or anything in it changed; recompute the plan when settings changed
  function RA.refresh(force)
    local proj = r.EnumProjects(-1)
    local change = r.GetProjectStateChangeCount(proj)
    if force or proj ~= state.proj or change ~= state.change then
      local ok, res = pcall(M.read_project)
      if not ok then state.err = "Could not read markers: " .. tostring(res); return end
      state.items, state.lanes, state.lane_list = res.items, res.lanes, res.lane_list
      state.excluded = M.load_excluded(state.lanes)
      state.proj, state.change = proj, r.GetProjectStateChangeCount(proj)
      state.dirty = true
    end
    if state.dirty then
      state.plan = Core.plan(state.items, state.lanes, S, state.excluded)
      state.dirty = false
    end
  end

  function RA.set_excluded(idx, on)
    state.excluded[idx] = on or nil
    M.save_excluded(state.lanes, state.excluded)
    state.change = r.GetProjectStateChangeCount(r.EnumProjects(-1))   -- our own ExtState write is not a project edit
    state.dirty = true
  end

  function RA.apply()
    RA.refresh(true)
    local plan = state.plan
    state.err, state.msg = nil, nil
    if plan.blocking then state.err = plan.blocking; return false end
    local ok, msg = M.write_plan(plan)
    if ok then state.msg = msg else state.err = msg end
    RA.refresh(true)
    return ok
  end

  return RA
end

return M

end

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

