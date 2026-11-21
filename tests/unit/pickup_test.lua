local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'

-- A module of `template` on a patch of `ore` at tiles x..x+3, 0..1, its
-- buildings standing, registered with player 1's resource manager.
local function built(template, ore, x)
  Lab.patch(ore, x, 0, x + 3, 1)
  local module = template:instantiate()
  for _, building in ipairs(module.buildings) do
    building.entity = Lab.entity(building.type, { x + building.position.x, building.position.y })
  end
  storage.resource_managers[1]:register_source(ModuleResourceSource:new{ module = module })
  return module
end

local function furnace_output(module) return module:entity(2).get_output_inventory() end

T.describe("Pickup", function()
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
  end)

  T.it("takes what the outputs within reach hold, up to two stacks of an item", function()
    local module = built(BurnerToFurnaceModule, "iron-ore", 0)
    furnace_output(module).insert{ name = "iron-plate", count = 80 }
    local player = Fakes.player{ surface = Lab.surface(), items = { ["iron-plate"] = 150 } }
    T.same(Pickup.sweep(player), { ["iron-plate"] = 50 }, "taken")
    T.eq(player.inventory.get_item_count("iron-plate"), 200, "two stacks on hand")
    T.eq(furnace_output(module).get_item_count("iron-plate"), 30, "the rest stays in the furnace")
    T.eq(storage.pickup[1]["iron-plate"], 50, "counted")
    T.truthy(Pickup.line(player):find("iron%-plate 50"), Pickup.line(player))
  end)

  T.it("leaves what the character can't reach", function()
    local module = built(BurnerToFurnaceModule, "iron-ore", 0)
    furnace_output(module).insert{ name = "iron-plate", count = 80 }
    local player = Fakes.player{ surface = Lab.surface(), can_reach = function() return false end }
    T.same(Pickup.sweep(player), {}, "nothing")
    T.eq(furnace_output(module).get_item_count("iron-plate"), 80, "still in the furnace")
  end)

  T.it("keeps the last free slots empty", function()
    local module = built(BurnerToFurnaceModule, "iron-ore", 0)
    furnace_output(module).insert{ name = "iron-plate", count = 100 }
    -- 2 of 12 slots hold stone: 10 empty, all of them kept free
    local player = Fakes.player{ surface = Lab.surface(), items = { stone = 100 }, slots = 12 }
    T.same(Pickup.sweep(player), {}, "no room on the way")
    player = Fakes.player{ surface = Lab.surface(), items = { stone = 100, ["iron-plate"] = 30 }, slots = 13 }
    T.same(Pickup.sweep(player), { ["iron-plate"] = 70 }, "only the rest of the started stack")
    player = Fakes.player{ surface = Lab.surface(), items = { stone = 100 }, slots = 13 }
    T.same(Pickup.sweep(player), { ["iron-plate"] = 30 }, "one slot beyond the free ones")
  end)

  T.it("leaves the coal a coal module keeps for its drills", function()
    local pair = built(BurnerToBurnerModule, "coal", 0)
    for i = 1, 2 do pair:entity(i).get_fuel_inventory().insert{ name = "coal", count = 30 } end
    local player = Fakes.player{ surface = Lab.surface() }
    local taken = Pickup.sweep(player)
    T.eq(taken.coal, 2 * (30 - 5), "all but what each drill keeps")
    T.eq(pair:entity(1).get_fuel_inventory().get_item_count("coal"), 5, "kept")
  end)

  T.it("a collect takes what it came for and what else is within reach", function()
    local iron = built(BurnerToFurnaceModule, "iron-ore", 0)
    local copper = built(BurnerToFurnaceCopperModule, "copper-ore", 6)
    furnace_output(iron).insert{ name = "iron-plate", count = 40 }
    furnace_output(copper).insert{ name = "copper-plate", count = 25 }
    local player = Fakes.player{ surface = Lab.surface() }
    local machine = GoalMachine:new()
    local task = CollectModuleOutputTask:new{ module = iron, type = "iron-plate", qty = 10 }
    task:tick{ player = player, machine = machine }
    T.truthy(task.done, "done")
    T.same({ player.inventory.get_item_count("iron-plate"), player.inventory.get_item_count("copper-plate") }, { 40, 25 }, "both")
  end)
end)
