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
