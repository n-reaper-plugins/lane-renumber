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
