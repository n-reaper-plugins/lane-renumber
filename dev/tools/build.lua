-- Build:  lua tools/build.lua        (run from the dev/ folder)
-- Output: dist/LaneRenumber.lua         the window (needs ReaImGui)
--         dist/LaneRenumber_Quick.lua   no window, last settings
-- Each output is ONE self-contained file: the modules are bundled through package.preload.
package.path = "./src/?.lua;" .. package.path
local Core = require("LaneRenumberCore")

local TARGETS = {
  { main = "LaneRenumber", modules = { "LaneRenumberCore", "LaneRenumberReaper", "LaneRenumberUI" } },
  { main = "LaneRenumber_Quick", modules = { "LaneRenumberCore", "LaneRenumberReaper" } },
}

local function read(p)
  local f = assert(io.open(p, "rb"), "cannot read " .. p)
  local s = f:read("*a"); f:close(); return s
end
local function write(p, s)
  local f = assert(io.open(p, "wb"), "cannot write " .. p)
  f:write(s); f:close()
end

os.execute("mkdir -p dist")
for _, t in ipairs(TARGETS) do
  -- split the leading comment header (kept at the very top for ReaPack/@version) from the body
  local main = read("src/" .. t.main .. ".lua"):gsub("@@VERSION@@", Core.VERSION)
  local header, body = {}, main
  while true do
    local line, rest = body:match("^([^\n]*)\n(.*)$")
    if line and line:match("^%-%-") then header[#header + 1] = line; body = rest else break end
  end
  local out = {}
  out[#out + 1] = table.concat(header, "\n")
  out[#out + 1] = "-- BUNDLED BUILD of Lane Renumber v" .. Core.VERSION .. " - edit the files in dev/src/, not this one."
  out[#out + 1] = "local __preload = package.preload"
  for _, m in ipairs(t.modules) do
    out[#out + 1] = string.format('__preload["%s"] = function(...)\n%s\nend', m, read("src/" .. m .. ".lua"))
  end
  out[#out + 1] = body
  write("dist/" .. t.main .. ".lua", table.concat(out, "\n") .. "\n")
  print(string.format("built dist/%s.lua v%s", t.main, Core.VERSION))
end
