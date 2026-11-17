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
