local T = require 'tests/lib/testing'
local CATALOG = require 'blueprints/found/catalog'

--[[
  The community blueprints of blueprints/found/catalog.lua: what
  Blueprint.module makes of each for every resource below goes to
  script-output/found-checks.txt (`node tools/found-blueprints.js checks` puts
  it into the catalog), and the ones marked as fitting must still fit.
]]
local RESOURCES = { "iron-ore", "copper-ore", "coal", "stone" }

local function outputs_of(data)
  local seen, list = {}, {}
  for _, output in ipairs(data.outputs) do
    if(not seen[output.type]) then
      seen[output.type] = true
      list[#list + 1] = output.type
    end
  end
  table.sort(list)
  return table.concat(list, ",")
end

-- data, nil for a module with no errors, else nil and why not
local function check(entry, resource)
  local ok, data, problem, checks = pcall(Blueprint.module,
    { name = "Found:" .. entry.id .. ":" .. resource, blueprint = entry.blueprint, resource = resource })
  if(not ok) then return nil, "crashed: " .. tostring(data) end
  if(not data) then return nil, tostring(problem) end
  if(#checks.errors > 0) then return nil, table.concat(checks.errors, "; ") end
  return data
end

local function clean(text)
  return (text:gsub("[\t\r\n]", " "))
end

T.describe("Found blueprints (blueprints/found/catalog.lua)", function()
  T.it("every one is a blueprint string", function()
    for _, entry in ipairs(CATALOG) do
      T.truthy(Blueprint.decode(entry.blueprint), entry.id)
    end
  end)

  T.it("the checks are written out, and the fitting ones still fit", function()
    local lines = {}
    for _, entry in ipairs(CATALOG) do
      for _, resource in ipairs(RESOURCES) do
        local data, why = check(entry, resource)
        if(data) then
          local ok, report = pcall(ModuleLibrary.report, BaseModule:new(data))
          local score = ok and report.score or 0
          lines[#lines + 1] = table.concat({ entry.id, resource, "OK", string.format("%.4f", score), outputs_of(data) }, "\t")
        else
          lines[#lines + 1] = table.concat({ entry.id, resource, "ERR", clean(why) }, "\t")
        end
        if(entry.fits[resource]) then
          T.truthy(data, entry.id .. " fits " .. resource .. ": " .. tostring(why))
        end
      end
    end
    helpers.write_file("found-checks.txt", table.concat(lines, "\n") .. "\n")
  end)
end)
