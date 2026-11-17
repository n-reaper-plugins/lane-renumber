-- A generic stub of ReaImGui for offline tests: every unknown ImGui_ function returns false, constants
-- (ImGui_*Flags_*, ImGui_Col_*, ImGui_Cond_*) return numbers, and the calls the scripts branch on are scripted.
-- G.click = label of the button/checkbox to "press" once; G.set[label] = value a Combo/InputInt reports once.
-- Labels are matched without their "###id" / "##id" suffix, and also with it.
local M = {}

local function bare(label) return (tostring(label):gsub("##.*$", "")) end
local function hit(G, label) return G.click ~= nil and (G.click == label or G.click == bare(label)) end

function M.install(G)
  G.click, G.set, G.calls, G.text, G.depth, G.disabled, G.styles = nil, G.set or {}, 0, {}, 0, 0, 0
  G.buttons, G.checks = {}, {}
  local n = 0
  setmetatable(reaper, { __index = function(_, k)
    if type(k) == "string" and (k:match("^ImGui_%w*Flags_") or k:match("^ImGui_Col_") or k:match("^ImGui_Cond_")) then
      n = n + 1; local v = 1 << (n % 30); return function() return v end
    end
    if type(k) == "string" and k:match("^ImGui_") then return function() G.calls = G.calls + 1; return false end end
  end })
  local R = reaper
  R.ImGui_CreateContext = function() return {} end
  R.ImGui_Begin = function(_, title) G.title = title; G.depth = G.depth + 1; return true, true end
  R.ImGui_End = function() G.depth = G.depth - 1 end
  R.ImGui_BeginTable = function() G.depth = G.depth + 1; return true end
  R.ImGui_EndTable = function() G.depth = G.depth - 1 end
  R.ImGui_BeginDisabled = function() G.disabled = G.disabled + 1 end
  R.ImGui_EndDisabled = function() G.disabled = G.disabled - 1 end
  R.ImGui_PushStyleColor = function() G.styles = G.styles + 1 end
  R.ImGui_PopStyleColor = function(_, k) G.styles = G.styles - (k or 1) end
  R.ImGui_Text = function(_, t) G.text[#G.text + 1] = t end
  R.ImGui_TextColored = function(_, _, t) G.text[#G.text + 1] = t end
  R.ImGui_TextWrapped = function(_, t) G.text[#G.text + 1] = t end
  R.ImGui_Button = function(_, label)
    G.buttons[bare(label)] = { disabled = G.disabled > 0 }
    local c = hit(G, label) and G.disabled == 0
    if c then G.click = nil end
    return c
  end
  R.ImGui_Checkbox = function(_, label, v)
    G.checks[bare(label)] = v
    if hit(G, label) then G.click = nil; return true, not v end
    return false, v
  end
  R.ImGui_Combo = function(_, label, idx)
    local v = G.set[label] or G.set[bare(label)]
    if v ~= nil then G.set[label], G.set[bare(label)] = nil, nil; return true, v end
    return false, idx
  end
  R.ImGui_InputInt = R.ImGui_Combo
end

-- everything that was printed since the last call, one line each
function M.text(G) local s = table.concat(G.text, "\n"); G.text = {}; return s end

return M
