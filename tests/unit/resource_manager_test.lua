local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'

-- A module source stand-in.
local function fake_module_source(type, has_output)
  local source = { fake = true }
  function source:is_valid() return true end
  function source:provides_type(t) return t == type end
  function source:has_output(t) return has_output end
  return source
end

T.describe("ResourceManager", function()
  local manager, player
  T.before_each(function()
    Lab.reset()
    manager = ResourceManager:new()
    player = Fakes.player{ surface = Lab.surface(), position = { x = 0.5, y = 0.5 } }
  end)

  T.it("picks the nearest thing that drops the item", function()
    Lab.ore("coal", 10, 0)
    local rock = Lab.entity("huge-rock", { 5.5, 0.5 }, "neutral")
    local source = manager:best_resource_source(player, "coal")
    T.eq(getmetatable(source), TreeResourceSource, "source class")
    T.eq(source.entity, rock, "entity")
  end)

  T.it("mines ore when it is the nearest", function()
    Lab.ore("stone", 3, 0)
    local source = manager:best_resource_source(player, "stone")
    T.eq(getmetatable(source), GroundResourceSource, "source class")
    T.eq(source.entity.position.x, 3.5, "x")
  end)

  T.it("finds ore further than the first search radius", function()
    Lab.ore("iron-ore", 35, 0)
    local source = manager:best_resource_source(player, "iron-ore")
    T.truthy(source, "source")
    T.eq(source.entity.position.x, 35.5, "x")
  end)

  T.it("skips targets the bot couldn't get to", function()
    Lab.ore("coal", 10, 0)
    Unreachable.mark(Lab.entity("huge-rock", { 5.5, 0.5 }, "neutral"))
    local source = manager:best_resource_source(player, "coal")
    T.eq(getmetatable(source), GroundResourceSource, "source class")
  end)

  T.it("skips ore under our own buildings", function()
    Lab.ore("stone", 3, 0)
    Lab.entity("stone-furnace", { 4, 1 }) -- covers tiles 3..4 x 0..1
    Lab.ore("stone", 8, 0)
    local source = manager:best_resource_source(player, "stone")
    T.eq(source.entity.position.x, 8.5, "x")
  end)

  T.it("prefers a module with the item ready over the map", function()
    Lab.ore("coal", 2, 0)
    local module_source = fake_module_source("coal", true)
    manager:register_source(module_source)
    T.eq(manager:best_resource_source(player, "coal"), module_source, "source")
  end)

  T.it("hand-crafts what can't be found on the map", function()
    T.eq(getmetatable(manager:best_resource_source(player, "stone-furnace")), CraftResourceSource, "source class")
  end)

  T.it("uses a module that still has to produce as the last resort", function()
    local module_source = fake_module_source("iron-plate", false)
    manager:register_source(module_source)
    T.eq(manager:best_resource_source(player, "iron-plate"), module_source, "source")
  end)

  T.it("has nothing for iron plates without a module", function()
    T.eq(manager:best_resource_source(player, "iron-plate"), nil, "source")
    T.falsy(manager:get_resources(player, "iron-plate", 10, GoalMachine:new()), "get_resources")
  end)
end)
