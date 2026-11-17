-- In-memory fake of the parts of the REAPER API that Lane Renumber uses: markers / regions with ruler lanes,
-- ruler lane info, ExtState / ProjExtState, undo, defer. It checks OUR logic, not REAPER's behaviour.
-- cfg.refuse_dup_regions (default true): setting I_NUMBER to a number another REGION already has is ignored,
--   which is what REAPER documents for SetProjectMarkerByIndex2.
-- cfg.old_api = true: no GetRegionOrMarker & co. (REAPER without ruler lanes)
local M = {}

function M.install(cfg)
  cfg = cfg or {}
  local S = {
    marks = {}, lanes = {}, deferred = {}, ext = {}, projext = {}, mb = {}, console = {}, undo = {},
    change = 0, proj = { name = "proj1" }, clock = 0, toggles = {}, guid_n = 0,
    refuse_dup_regions = cfg.refuse_dup_regions ~= false, sets = 0,
  }
  M.S = S
  local function new_guid() S.guid_n = S.guid_n + 1; return string.format("{00000000-0000-0000-0000-%012d}", S.guid_n) end
  local function bump() S.change = S.change + 1 end

  ---------------------------------------------------------------- scene helpers
  function M.lane(name, opt)
    opt = opt or {}
    bump()
    S.lanes[#S.lanes + 1] = { name = name or "", guid = new_guid(), hidden = opt.hidden and 1 or 0, locked = opt.locked and 1 or 0 }
    return #S.lanes - 1
  end
  function M.marker(lane, pos, num, name, opt)
    opt = opt or {}
    local m = { guid = new_guid(), isrgn = false, pos = pos, rend = pos, num = num, name = name or "", lane = lane,
                hidden = opt.hidden and 1 or 0 }
    S.marks[#S.marks + 1] = m
    bump()
    return m
  end
  function M.region(lane, pos, rend, num, name)
    local m = M.marker(lane, pos, num, name)
    m.isrgn, m.rend = true, rend
    return m
  end
  -- REAPER keeps markers sorted by position; the internal index follows that order
  local function sorted()
    local t = {}
    for i, m in ipairs(S.marks) do t[i] = m end
    table.sort(t, function(a, b) if a.pos ~= b.pos then return a.pos < b.pos end return a.guid < b.guid end)
    return t
  end
  function M.nums(kind)          -- "lane:num name" list in position order, for asserts
    local out = {}
    for _, m in ipairs(sorted()) do
      if (kind == "region") == m.isrgn then out[#out + 1] = m.lane .. ":" .. m.num end
    end
    return table.concat(out, " ")
  end

  ---------------------------------------------------------------- API
  local R = {}
  reaper = R
  R.time_precise = function() return S.clock end
  R.defer = function(f) S.deferred[#S.deferred + 1] = f end
  R.atexit = function(f) S.atexit = f end
  R.ShowConsoleMsg = function(s) S.console[#S.console + 1] = s end
  R.MB = function(msg) S.mb[#S.mb + 1] = msg; return 1 end
  R.GetExtState = function(sec, k) return S.ext[sec .. "/" .. k] or "" end
  R.SetExtState = function(sec, k, v) S.ext[sec .. "/" .. k] = v end
  R.GetProjExtState = function(_, sec, k) local v = S.projext[sec .. "/" .. k]; return v and 1 or 0, v or "" end
  R.SetProjExtState = function(_, sec, k, v) S.projext[sec .. "/" .. k] = v; bump() end   -- REAPER marks the project dirty
  R.Undo_BeginBlock2 = function() S.in_undo = true end
  R.Undo_EndBlock2 = function(_, name) S.in_undo = false; S.undo[#S.undo + 1] = name end
  R.PreventUIRefresh = function() end
  R.UpdateTimeline = function() end
  R.EnumProjects = function() return S.proj end
  R.GetProjectStateChangeCount = function() return S.change end
  R.get_action_context = function() return false, "", 0, 4242 end
  R.SetToggleCommandState = function(_, id, v) S.toggles[id] = v end
  R.RefreshToolbar2 = function() end
  R.format_timestr_pos = function(p) return string.format("%.2f", p) end

  R.GetSetProjectInfo = function(_, key, _, set)
    assert(not set, "the script never sets project info")
    if key == "RULER_LANE_COUNT" then return #S.lanes end
    local what, idx = key:match("^RULER_LANE_(%u+):(%d+)$")
    local ln = idx and S.lanes[tonumber(idx) + 1]
    if not ln then return 0 end
    if what == "HIDDEN" then return ln.hidden end
    if what == "LOCKED" then return ln.locked end
    return 0
  end
  R.GetSetProjectInfo_String = function(_, key, _, set)
    assert(not set)
    local what, idx = key:match("^RULER_LANE_(%u+):(%d+)$")
    local ln = idx and S.lanes[tonumber(idx) + 1]
    if not ln then return false, "" end
    if what == "NAME" then return true, ln.name end
    if what == "GUID" then return true, ln.guid end
    return false, ""
  end

  if not cfg.old_api then
    R.GetNumRegionsOrMarkers = function() return #S.marks end
    R.GetRegionOrMarker = function(_, idx, guid)
      if idx >= 0 then return sorted()[idx + 1] end
      for _, m in ipairs(S.marks) do if m.guid == guid then return m end end
      return nil
    end
    R.GetRegionOrMarkerInfo_Value = function(_, m, k)
      if k == "D_STARTPOS" then return m.pos end
      if k == "D_ENDPOS" then return m.rend end
      if k == "I_NUMBER" then return m.num end
      if k == "I_LANENUMBER" then return m.lane end
      if k == "B_ISREGION" then return m.isrgn and 1 or 0 end
      if k == "B_HIDDEN" then return m.hidden end
      error("unknown marker param " .. k)
    end
    R.SetRegionOrMarkerInfo_Value = function(_, m, k, v)
      assert(k == "I_NUMBER", "the script only sets I_NUMBER")
      assert(S.in_undo, "set outside an undo block")
      assert(math.type(v) == "integer" or v == math.floor(v), "non-integer number")
      S.sets = S.sets + 1
      if m.isrgn and S.refuse_dup_regions then
        for _, o in ipairs(S.marks) do if o ~= m and o.isrgn and o.num == v then return 0 end end
      end
      m.num = math.floor(v); bump()
      return 1
    end
    R.GetSetRegionOrMarkerInfo_String = function(_, m, k, _, set)
      assert(not set)
      if k == "GUID" then return true, m.guid end
      if k == "P_NAME" then return true, m.name end
      return false, ""
    end
  end
  return S
end

-- run the deferred callbacks n times
function M.pump(S, n)
  for _ = 1, n or 1 do
    local list = S.deferred
    S.deferred = {}
    for _, f in ipairs(list) do f() end
    S.clock = S.clock + 0.05
  end
end

return M
