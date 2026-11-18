local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'

local function top(machine) return Fakes.goals(machine)[1] end
local function source(furnace) return furnace.get_inventory(defines.inventory.crafter_input) end

T.describe("Recipes.furnace_recipe", function()
  local function recipe(item) return Recipes.furnace_recipe(game.forces.player, "stone-furnace", item) end

  T.it("knows plates and bricks", function()
    T.same(recipe("iron-plate"), { recipe = "iron-plate", ingredient = "iron-ore", amount = 1, made = 1 }, "iron")
    T.same(recipe("stone-brick"), { recipe = "stone-brick", ingredient = "stone", amount = 2, made = 1 }, "bricks")
  end)

  T.it("knows nothing a furnace doesn't make or the force hasn't unlocked", function()
    T.eq(recipe("iron-gear-wheel"), nil, "gears")
    T.eq(recipe("steel-plate"), nil, "steel before research")
  end)
end)

T.describe("HandSmeltTask", function()
  local machine
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    machine = GoalMachine:new()
  end)
  local function smelt(qty)
    local task = HandSmeltTask:new{ item = "iron-plate", qty = qty }
    machine:pushSingle(task)
    return task
  end
  local function tick(task, player) task:tick{ player = player, machine = machine } end
  local function player_with(items) return Fakes.player{ surface = Lab.surface(), items = items } end
  -- a fueled furnace the bot placed before, by an iron ore patch
  local function own_furnace()
    Lab.patch("iron-ore", 10, 10, 11, 11)
    local furnace = Lab.entity("stone-furnace", { 14, 10 })
    furnace.get_fuel_inventory().insert{ name = "coal", count = 1 }
    storage.hand_furnaces = { [1] = { ["iron-ore"] = furnace } }
    return furnace
  end

  T.it("puts a furnace by the ore", function()
    Lab.patch("iron-ore", 10, 10, 11, 11)
    local task = smelt(5)
    tick(task, player_with{ ["stone-furnace"] = 1, coal = 5 })
    local build = top(machine)
    T.same({ getmetatable(build) == BuildBuildingTask, build.type }, { true, "stone-furnace" }, "build")
    T.truthy(util.distance(build.position, { x = 11, y = 11 }) <= 10, "by the ore")
  end)

  T.it("crafts a furnace first when it carries none", function()
    Lab.patch("iron-ore", 10, 10, 11, 11)
    tick(smelt(5), player_with{ coal = 5, stone = 5 })
    T.same({ top(machine).type, top(machine).qty }, { "stone-furnace", 1 }, "gather")
  end)

  T.it("leaves the stone the tasks below need", function()
    Lab.patch("iron-ore", 10, 10, 11, 11)
    local task = smelt(5)
    task.keep = { stone = 10, ["stone-furnace"] = 1 }
    tick(task, player_with{ coal = 5, stone = 10, ["stone-furnace"] = 1 })
    T.same({ top(machine).type, top(machine).qty }, { "stone", 15 }, "5 more stone")
  end)

  T.it("burns spare fuel only", function()
    local furnace = own_furnace()
    furnace.get_fuel_inventory().clear()
    local player = player_with{ coal = 5, wood = 1 }
    local task = smelt(5)
    task.keep = { coal = 5 }
    tick(task, player)
    T.same({ furnace.get_fuel_inventory().get_item_count("wood"), player.inventory.get_item_count("coal") },
      { 1, 5 }, "wood in, coal kept")
  end)

  T.it("fuels the furnace it placed and keeps it for next time", function()
    Lab.patch("iron-ore", 10, 10, 11, 11)
    local player = player_with{ ["stone-furnace"] = 1, coal = 5 }
    local task = smelt(5)
    tick(task, player)
    local furnace = Lab.entity("stone-furnace", { 14, 10 })
    task.building.entity = furnace -- what PlaceBuildingTask does
    machine.goals = machine.goals.next
    tick(task, player)
    T.eq(furnace.get_fuel_inventory().get_item_count("coal"), 1, "fuel")
    T.eq(player.inventory.get_item_count("coal"), 4, "coal left")
    T.eq(storage.hand_furnaces[1]["iron-ore"], furnace, "remembered")
    T.eq(top(machine), task, "nothing pushed")
    local next_time = smelt(5)
    tick(next_time, player)
    T.falsy(getmetatable(top(machine)) == BuildBuildingTask, "no second furnace")
  end)

  T.it("goes on with the fuel that is still burning", function()
    local furnace = own_furnace()
    furnace.get_fuel_inventory().clear()
    furnace.burner.currently_burning = "wood"
    furnace.burner.remaining_burning_fuel = 1000000
    local task = smelt(5)
    task.keep = { coal = 5 } -- the coal is for the tasks below
    tick(task, player_with{ coal = 5 })
    T.falsy(task.failed, "failed")
    T.eq(top(machine).type, "iron-ore", "mines")
  end)

  T.it("gives up when nothing burns and there is no spare fuel", function()
    local furnace = own_furnace()
    furnace.get_fuel_inventory().clear()
    local task = smelt(5)
    task.keep = { coal = 5 }
    tick(task, player_with{ coal = 5 })
    T.truthy(task.failed, "failed")
  end)

  T.it("puts in as much ore as plates are missing", function()
    local furnace = own_furnace()
    local player = player_with{ ["iron-ore"] = 10, ["iron-plate"] = 2, coal = 5 }
    tick(smelt(5), player)
    T.eq(source(furnace).get_item_count("iron-ore"), 3, "ore in")
    T.eq(player.inventory.get_item_count("iron-ore"), 7, "ore left")
  end)

  T.it("mines ore when it has none", function()
    own_furnace()
    tick(smelt(5), player_with{ coal = 5 })
    T.same({ getmetatable(top(machine)) == GatherResourceTask, top(machine).type, top(machine).qty },
      { true, "iron-ore", 1 }, "gather")
  end)

  T.it("mines no more once the furnace holds enough", function()
    local furnace = own_furnace()
    source(furnace).insert{ name = "iron-ore", count = 3 }
    local task = smelt(5)
    tick(task, player_with{ ["iron-plate"] = 2, coal = 5 })
    T.eq(top(machine), task, "waits")
  end)

  T.it("takes the plates out", function()
    local furnace = own_furnace()
    furnace.get_output_inventory().insert{ name = "iron-plate", count = 3 }
    local player = player_with{ coal = 5 }
    tick(smelt(5), player)
    T.eq(player.inventory.get_item_count("iron-plate"), 3, "taken")
    T.eq(furnace.get_output_inventory().get_item_count("iron-plate"), 0, "furnace empty")
  end)

  T.it("counts what waits in the module", function()
    local module = BurnerToFurnaceModule:instantiate()
    module.buildings[2].entity = Lab.entity("stone-furnace", { 20, 20 })
    module.buildings[2].entity.get_output_inventory().insert{ name = "iron-plate", count = 4 }
    local player = player_with{ ["iron-plate"] = 2 }
    T.truthy(HandSmeltTask:new{ item = "iron-plate", qty = 6, module = module }:achieved{ player = player }, "6 of 6")
    T.falsy(HandSmeltTask:new{ item = "iron-plate", qty = 7, module = module }:achieved{ player = player }, "6 of 7")
  end)

  T.it("gives up when there is no ore left", function()
    local furnace = Lab.entity("stone-furnace", { 14, 10 })
    furnace.get_fuel_inventory().insert{ name = "coal", count = 1 }
    storage.hand_furnaces = { [1] = { ["iron-ore"] = furnace } }
    local player = player_with{ coal = 5 }
    local task = smelt(5)
    tick(task, player)
    T.truthy(task:achieved{ player = player }, "off the stack")
    T.eq(top(machine), task, "nothing pushed")
  end)

  T.it("is possible with ore on the map, fuel, and stone for a furnace", function()
    Lab.patch("iron-ore", 10, 10, 11, 11)
    T.truthy(HandSmeltTask.possible(player_with{ coal = 1, stone = 5 }, "iron-plate"), "all there")
    T.falsy(HandSmeltTask.possible(player_with{ stone = 5 }, "iron-plate"), "no fuel")
    T.falsy(HandSmeltTask.possible(player_with{ coal = 1 }, "iron-plate"), "no stone")
    T.falsy(HandSmeltTask.possible(player_with{ coal = 1, stone = 5 }, "copper-plate"), "no copper ore")
    T.falsy(HandSmeltTask.possible(player_with{ coal = 1, stone = 5 }, "iron-gear-wheel"), "not smelted")
    T.falsy(HandSmeltTask.possible(player_with{ coal = 1, stone = 5 }, "iron-plate", { stone = 5 }), "stone kept")
    T.falsy(HandSmeltTask.possible(player_with{ coal = 1, stone = 5 }, "iron-plate", { coal = 1 }), "fuel kept")
  end)
end)

T.describe("WaitForOutputTask: smelting by hand", function()
  local machine, player
  T.before_each(function()
    Lab.reset()
    Lab.patch("iron-ore", 10, 10, 11, 11)
    storage.resource_managers[1] = ResourceManager:new()
    machine = GoalMachine:new()
    player = Fakes.player{ surface = Lab.surface(), items = { coal = 5, ["stone-furnace"] = 1 } }
  end)
  local function wait_for(total)
    local wait = WaitForOutputTask:new{ module = BurnerToFurnaceModule:instantiate(), type = "iron-plate", qty = 10, total = total }
    machine:pushSingle(wait)
    return wait
  end
  local function tick(wait) wait:tick{ player = player, machine = machine } end

  T.it("smelts the product when there is nothing to fetch", function()
    tick(wait_for(18))
    local smelt = top(machine)
    T.same({ getmetatable(smelt) == HandSmeltTask, smelt.item, smelt.qty }, { true, "iron-plate", 18 }, "smelt")
  end)

  T.it("does it once per wait", function()
    local wait = wait_for(18)
    tick(wait)
    machine.goals = machine.goals.next -- the smelting is over
    wait.side_work_at = nil
    tick(wait)
    T.eq(top(machine), wait, "top")
  end)

  T.it("doesn't when the module is nearly done", function()
    local wait = wait_for(18)
    wait.module.buildings[2].entity = Lab.entity("stone-furnace", { 20, 20 })
    wait.module.buildings[2].entity.get_output_inventory().insert{ name = "iron-plate", count = 8 }
    tick(wait) -- 2 plates to go, 8 s at 15 a minute
    T.eq(top(machine), wait, "top")
  end)

  T.it("doesn't when it isn't told the total", function()
    local wait = wait_for(nil)
    tick(wait)
    T.eq(top(machine), wait, "top")
  end)

  T.it("is over once the inventory and the module hold the total", function()
    local wait = wait_for(18)
    wait.module.buildings[2].entity = Lab.entity("stone-furnace", { 20, 20 })
    wait.module.buildings[2].entity.get_output_inventory().insert{ name = "iron-plate", count = 4 }
    T.falsy(wait:achieved{ player = Fakes.player{ items = { ["iron-plate"] = 13 } } }, "17 of 18")
    T.truthy(wait:achieved{ player = Fakes.player{ items = { ["iron-plate"] = 14 } } }, "18 of 18")
  end)
end)
