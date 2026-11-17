-- @description Lane Renumber: renumber markers and regions by ruler lane (consecutive numbers per lane)
-- @version 0.1.0
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
__preload["LaneRenumberUI"] = function(...)
-- LaneRenumberUI.lua
-- ReaImGui window: left = settings and the lane list, right = preview (old -> new for every marker/region).
-- Nothing here touches the project except through RA. Style follows the other _n_plugins (262 deg theme).

local Core = require("LaneRenumberCore")

local M = {}
local r = reaper

local COL_OK, COL_WARN, COL_ERR, COL_DIM, COL_HEAD = 0x5FE07FFF, 0xFFAA33FF, 0xFF5F5FFF, 0x999999FF, 0xFFCC44FF
local COL_NEW = 0x6FB7FFFF
local BG = 0x181A1AFF
local THEME = {
  { "WindowBg", BG }, { "PopupBg", BG }, { "ChildBg", BG },
  { "FrameBg", 0x47297A8A }, { "FrameBgHovered", 0x8542FA66 }, { "FrameBgActive", 0x8542FAAB },
  { "Button", 0x8542FA66 }, { "ButtonHovered", 0x8542FAFF }, { "ButtonActive", 0x650FFAFF },
  { "SliderGrab", 0x793DE0FF }, { "SliderGrabActive", 0x8542FAFF }, { "CheckMark", 0x8542FAFF },
  { "Header", 0x8542FA4F }, { "HeaderHovered", 0x8542FACC }, { "HeaderActive", 0x8542FAFF },
  { "TitleBgActive", 0x47297AFF },
}

-- pushes the theme, returns how many colours were pushed (names missing in an older ReaImGui are skipped)
local function push_theme(ctx)
  local n = 0
  for _, c in ipairs(THEME) do
    local get = r["ImGui_Col_" .. c[1]]
    if get then r.ImGui_PushStyleColor(ctx, get(), c[2]); n = n + 1 end
  end
  return n
end

local function fmt_pos(p)
  local ok, s = pcall(r.format_timestr_pos, p, "", -1)     -- -1 = project default time format
  return (ok and type(s) == "string" and s ~= "") and s or string.format("%.3f", p)
end

function M.lane_label(ln, idx)
  local s = "Lane " .. (idx + 1)
  if ln and ln.name ~= nil and ln.name ~= "" then s = s .. "  " .. ln.name end
  return s
end

function M.new(S, state, RA, title)
  local ui = {}
  local ctx = r.ImGui_CreateContext("Lane Renumber")

  local function changed() state.dirty = true end
  local function check(label, key)
    local ch, v = r.ImGui_Checkbox(ctx, label, S[key] ~= 0)
    if ch then S[key] = v and 1 or 0; changed() end
  end
  local function int_in(label, key, mn, mx)
    r.ImGui_SetNextItemWidth(ctx, 110)
    local ch, v = r.ImGui_InputInt(ctx, label, math.floor(S[key]))
    if ch then S[key] = Core.clamp(math.floor(v), mn, mx); changed() end
  end
  local function tip(t) if r.ImGui_IsItemHovered(ctx) and r.ImGui_SetTooltip then r.ImGui_SetTooltip(ctx, t) end end

  ------------------------------------------------------------------------------
  local function draw_lanes()
    r.ImGui_TextColored(ctx, COL_HEAD, "Ruler lanes")
    if #state.lane_list == 0 then r.ImGui_TextColored(ctx, COL_DIM, "No markers or regions in this project."); return end
    local cnt = {}
    for _, it in ipairs(state.items) do
      local c = cnt[it.lane] or { 0, 0 }
      if it.kind == "marker" then c[1] = c[1] + 1 else c[2] = c[2] + 1 end
      cnt[it.lane] = c
    end
    for _, idx in ipairs(state.lane_list) do
      local ln = state.lanes[idx]
      local c = cnt[idx] or { 0, 0 }
      local label = string.format("%s   (%d markers, %d regions)%s%s###lane%d", M.lane_label(ln, idx), c[1], c[2],
        ln.locked and "  [locked]" or "", ln.hidden and "  [hidden]" or "", idx)
      local ch, v = r.ImGui_Checkbox(ctx, label, not state.excluded[idx])
      if ch then RA.set_excluded(idx, not v) end
    end
    r.ImGui_TextColored(ctx, COL_DIM, "Unticked lanes keep their numbers (remembered per project).")
  end

  local function draw_settings()
    r.ImGui_TextColored(ctx, COL_HEAD, "Renumber")
    check("Markers", "do_markers"); r.ImGui_SameLine(ctx); check("Regions", "do_regions")
    r.ImGui_SetNextItemWidth(ctx, -1)
    local ch, v = r.ImGui_Combo(ctx, "##mode", math.floor(S.mode), table.concat(Core.MODES, "\0") .. "\0")
    if ch then S.mode = v; changed() end
    int_in("First number", "start", 0, 1000000)
    if S.mode == Core.MODE_BLOCK then
      int_in("Block size", "block", 1, 1000000)
      r.ImGui_TextColored(ctx, COL_DIM, string.format("lane 1 -> %d, lane 2 -> %d, lane 3 -> %d ...",
        S.start, S.start + S.block, S.start + 2 * S.block))
    end
    check("Skip numbers used by kept ones", "skip_kept")
    tip("A marker/region that keeps its number (lane unticked, locked, hidden ...) reserves it:\nthe renumbered ones jump over it, so nothing is doubled.")
    check("Locked lanes keep their numbers", "skip_locked")
    check("Hidden markers/regions keep their numbers", "skip_hidden")
    r.ImGui_Separator(ctx)
    draw_lanes()
  end

  local function draw_actions()
    local plan = state.plan
    if not plan then return end
    local nm, nr, nl = Core.summary(state.items, state.lanes)
    r.ImGui_Text(ctx, string.format("%d markers, %d regions on %d lane(s).  %d renumbered, %d change.",
      nm, nr, nl, plan.targets, plan.changes))
    local can = plan.changes > 0 and not plan.blocking
    if not can then r.ImGui_BeginDisabled(ctx) end
    if r.ImGui_Button(ctx, string.format("Renumber (%d)###apply", plan.changes)) then RA.apply() end
    if not can then r.ImGui_EndDisabled(ctx) end
    r.ImGui_SameLine(ctx)
    check("Show only changes", "only_changes")
    if plan.blocking then r.ImGui_TextColored(ctx, COL_ERR, plan.blocking) end
    for _, w in ipairs(plan.warnings) do r.ImGui_TextColored(ctx, COL_WARN, w) end
    if state.err then r.ImGui_TextColored(ctx, COL_ERR, state.err) end
    if state.msg then r.ImGui_TextColored(ctx, COL_OK, state.msg) end
  end

  local function draw_preview()
    local plan = state.plan
    if not plan or #plan.rows == 0 then return end
    local flags = r.ImGui_TableFlags_RowBg() | r.ImGui_TableFlags_ScrollY() | r.ImGui_TableFlags_BordersInnerV()
    if r.ImGui_BeginTable(ctx, "preview", 6, flags) then
      r.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
      r.ImGui_TableSetupColumn(ctx, "Lane")
      r.ImGui_TableSetupColumn(ctx, "Type")
      r.ImGui_TableSetupColumn(ctx, "Position")
      r.ImGui_TableSetupColumn(ctx, "Name", r.ImGui_TableColumnFlags_WidthStretch())
      r.ImGui_TableSetupColumn(ctx, "#")
      r.ImGui_TableSetupColumn(ctx, "New")
      r.ImGui_TableHeadersRow(ctx)
      for _, row in ipairs(plan.rows) do
        if S.only_changes == 0 or row.new ~= row.old then
          r.ImGui_TableNextRow(ctx)
          r.ImGui_TableSetColumnIndex(ctx, 0); r.ImGui_Text(ctx, tostring(row.lane + 1))
          r.ImGui_TableSetColumnIndex(ctx, 1); r.ImGui_Text(ctx, row.kind == "region" and "R" or "M")
          r.ImGui_TableSetColumnIndex(ctx, 2); r.ImGui_Text(ctx, fmt_pos(row.pos))
          r.ImGui_TableSetColumnIndex(ctx, 3); r.ImGui_Text(ctx, row.name or "")
          r.ImGui_TableSetColumnIndex(ctx, 4); r.ImGui_Text(ctx, tostring(row.old))
          r.ImGui_TableSetColumnIndex(ctx, 5)
          if row.keep then
            r.ImGui_TextColored(ctx, COL_DIM, "keep (" .. row.keep .. ")")
          elseif row.dup then
            r.ImGui_TextColored(ctx, row.kind == "region" and COL_ERR or COL_WARN, tostring(row.new) .. "  (twice)")
          elseif row.new ~= row.old then
            r.ImGui_TextColored(ctx, COL_NEW, tostring(row.new))
          else
            r.ImGui_TextColored(ctx, COL_DIM, tostring(row.new))
          end
        end
      end
      r.ImGui_EndTable(ctx)
    end
  end

  local function draw_ui()
    local flags = r.ImGui_TableFlags_Resizable() | r.ImGui_TableFlags_BordersInnerV()
    if r.ImGui_BeginTable(ctx, "layout", 2, flags) then
      r.ImGui_TableSetupColumn(ctx, "settings", r.ImGui_TableColumnFlags_WidthStretch(), 0.38)
      r.ImGui_TableSetupColumn(ctx, "preview", r.ImGui_TableColumnFlags_WidthStretch(), 0.62)
      r.ImGui_TableNextRow(ctx)
      r.ImGui_TableSetColumnIndex(ctx, 0)
      draw_settings()
      r.ImGui_TableSetColumnIndex(ctx, 1)
      draw_actions()
      r.ImGui_Separator(ctx)
      draw_preview()
      r.ImGui_EndTable(ctx)
    end
  end

  -- one frame of the window; returns false once it was closed
  function ui.frame()
    local n = push_theme(ctx)
    r.ImGui_SetNextWindowSize(ctx, 900, 520, r.ImGui_Cond_FirstUseEver())
    local visible, open = r.ImGui_Begin(ctx, title, true)
    if visible then
      local ok, e = pcall(draw_ui)
      if not ok then state.err = tostring(e) end
      r.ImGui_End(ctx)
    end
    if n > 0 then r.ImGui_PopStyleColor(ctx, n) end
    return open
  end

  return ui
end

return M

end

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

