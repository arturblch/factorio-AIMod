local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'

-- BurnerToFurnace needs iron ore on geometry tiles (0..1, 0..1) and any dry
-- land on (2..3, 0..1); the drill sits at corner + (1, 1), the furnace at
-- corner + (3, 1).
local function iron_spot(x, y)
  Lab.patch("iron-ore", x, y, x + 1, y + 1)
  return { x = x + 0.5, y = y + 0.5 }
end

T.describe("BuildModuleTask:canBuildAtPosition", function()
  local player, task
  T.before_each(function()
    Lab.reset()
    player = Fakes.player{ surface = Lab.surface() }
    task = BuildModuleTask:new{ module = BurnerToFurnaceModule }
  end)

  T.it("accepts a full ore patch on dry land", function()
    T.truthy(task:canBuildAtPosition(player, iron_spot(10, 10)), "can build")
  end)

  T.it("rejects a spot with a required ore tile missing", function()
    Lab.patch("iron-ore", 10, 10, 11, 10) -- only the top row
    T.falsy(task:canBuildAtPosition(player, { x = 10.5, y = 10.5 }), "can build")
  end)

  T.it("rejects water", function()
    local spot = iron_spot(10, 10)
    Lab.water(13, 11)
    T.falsy(task:canBuildAtPosition(player, spot), "can build")
  end)

  T.it("rejects a spot taken by our buildings", function()
    local spot = iron_spot(10, 10)
    Lab.entity("wooden-chest", { 12.5, 10.5 })
    T.falsy(task:canBuildAtPosition(player, spot), "can build")
  end)

  T.it("rejects a spot with a cliff in it", function()
    local spot = iron_spot(10, 10)
    Lab.surface().create_entity{ name = "cliff", position = { 13, 10 }, cliff_orientation = "west-to-east" }
    T.falsy(task:canBuildAtPosition(player, spot), "can build")
  end)
end)

T.describe("BuildModuleTask:tick", function()
  local player, manager
  T.before_each(function()
    Lab.reset()
    manager = ResourceManager:new()
    storage.resource_managers[1] = manager
  end)

  T.it("picks the nearest spot", function()
    iron_spot(20, 0)
    iron_spot(5, 0)
    player = Fakes.player{ surface = Lab.surface(), items = { ["burner-mining-drill"] = 1, ["stone-furnace"] = 1 } }
    local task = BuildModuleTask:new{ module = BurnerToFurnaceModule }
    task:tick{ player = player, machine = GoalMachine:new() }
    T.same(task.location, { x = 5.5, y = 0.5 }, "location")
  end)

  T.it("builds on the grid, then fuels the module and registers it", function()
    iron_spot(10, 20)
    player = Fakes.player{ surface = Lab.surface(), position = { x = 10, y = 18 },
      items = { ["burner-mining-drill"] = 1, ["stone-furnace"] = 1 } }
    local machine = GoalMachine:new()
    local task = BuildModuleTask:new{ module = BurnerToFurnaceModule }
    task:tick{ player = player, machine = machine }

    T.same(Fakes.goal_classes(machine),
      { "BuildBuildingTask", "BuildBuildingTask", "GatherResourceTask", "FuelBuildingTask", "FuelBuildingTask" }, "tasks")
    local goals = Fakes.goals(machine)
    T.same({ goals[1].type, goals[1].position, goals[1].direction },
      { "burner-mining-drill", { x = 11, y = 21 }, defines.direction.east }, "drill")
    T.same({ goals[2].type, goals[2].position }, { "stone-furnace", { x = 13, y = 21 } }, "furnace")
    T.same({ goals[3].type, goals[3].qty }, { "coal", 10 }, "one fuel trip for both buildings")

    T.eq(#manager.sources, 1, "registered sources")
    T.eq(getmetatable(manager.sources[1]), ModuleResourceSource, "source class")
    T.truthy(manager.sources[1].module ~= BurnerToFurnaceModule, "the module is a private copy")
    T.falsy(task:achieved{ player = player }, "achieved before the buildings stand")
    task.built.buildings[1].entity = Lab.entity("burner-mining-drill", { 11, 21 })
    task.built.buildings[2].entity = Lab.entity("stone-furnace", { 13, 21 })
    T.truthy(task:achieved{ player = player }, "achieved once every building stands")
  end)

  T.it("picks up what was built and tries another spot when a building is missing", function()
    iron_spot(5, 0)
    iron_spot(20, 0)
    player = Fakes.player{ surface = Lab.surface(), items = { ["burner-mining-drill"] = 1, ["stone-furnace"] = 1 } }
    local task = BuildModuleTask:new{ module = BurnerToFurnaceModule }
    task:tick{ player = player, machine = GoalMachine:new() }
    T.same(task.location, { x = 5.5, y = 0.5 }, "first spot")
    -- the drill went up, the furnace didn't
    task.built.buildings[1].entity = Lab.entity("burner-mining-drill", { 6, 1 })
    player.inventory.remove{ name = "burner-mining-drill", count = 1 }
    T.falsy(task:achieved{ player = player }, "achieved with a building missing")

    task:tick{ player = player, machine = GoalMachine:new() }
    T.same(player.mined, { "burner-mining-drill" }, "picked up")
    T.eq(player.inventory.get_item_count("burner-mining-drill"), 1, "drill back in the inventory")
    T.eq(#manager.sources, 0, "module source dropped")
    T.falsy(task.failed, "failed")

    task:tick{ player = player, machine = GoalMachine:new() }
    T.same(task.location, { x = 20.5, y = 0.5 }, "second spot, away from the first")
  end)

  T.it("gives up after three spots and says so at the end", function()
    for _, x in ipairs({ 5, 18, 31 }) do iron_spot(x, 0) end
    player = Fakes.player{ surface = Lab.surface(), items = { ["burner-mining-drill"] = 1, ["stone-furnace"] = 1 } }
    local task = BuildModuleTask:new{ module = BurnerToFurnaceModule }
    for attempt = 1, 3 do
      task:tick{ player = player, machine = GoalMachine:new() } -- queues the build at a new spot
      T.truthy(task.built, "built queued, attempt " .. attempt)
      task:tick{ player = player, machine = GoalMachine:new() } -- nothing stood up: retry
    end
    T.truthy(task.failed, "failed")
    T.truthy(task:achieved{ player = player }, "achieved (gave up)")
    T.same(storage.failed_goals[1], { "BurnerToFurnace" }, "recorded for the final message")
    T.eq(#player.printed, 1, "one message")
  end)

  T.it("crafts missing buildings first and keeps the spot", function()
    iron_spot(10, 20)
    player = Fakes.player{ surface = Lab.surface(), items = { ["stone-furnace"] = 1 } }
    local machine = GoalMachine:new()
    local task = BuildModuleTask:new{ module = BurnerToFurnaceModule }
    task:tick{ player = player, machine = machine }
    T.same(Fakes.goal_classes(machine), { "CraftRecipeTask" }, "tasks")
    T.eq(Fakes.goals(machine)[1].recipe, "burner-mining-drill", "recipe")
    T.truthy(task.location, "spot kept")
    T.falsy(task:achieved{ player = player }, "achieved")
  end)

  T.it("gives up with a message when there is no spot", function()
    player = Fakes.player{ surface = Lab.surface() }
    local task = BuildModuleTask:new{ module = BurnerToFurnaceModule }
    task:tick{ player = player, machine = GoalMachine:new() }
    T.truthy(task:achieved{ player = player }, "achieved (failed)")
    T.truthy(task.failed, "failed")
    T.eq(#player.printed, 1, "messages")
  end)
end)

T.describe("BaseModule", function()
  T.before_each(function() Lab.reset() end)

  -- BurnerToFurnace with real entities: drill on iron ore, furnace next to it
  local function built_furnace_module()
    iron_spot(0, 0)
    local module = BurnerToFurnaceModule:instantiate()
    module.buildings[1].entity = Lab.entity("burner-mining-drill", { 1, 1 })
    module.buildings[2].entity = Lab.entity("stone-furnace", { 3, 1 })
    return module
  end

  T.it("instantiate makes independent copies", function()
    local a, b = BurnerToFurnaceModule:instantiate(), BurnerToFurnaceModule:instantiate()
    a.buildings[1].entity = "x"
    T.eq(b.buildings[1].entity, nil, "other copy")
    T.eq(BurnerToFurnaceModule.buildings[1].entity, nil, "definition")
    T.eq(getmetatable(a), BaseModule, "class")
  end)

  T.it("is operational only when every building stands", function()
    local module = built_furnace_module()
    T.truthy(module:isOperational(), "all built")
    module.buildings[2].entity.destroy()
    T.falsy(module:isOperational(), "furnace gone")
  end)

  T.it("counts the furnace's output", function()
    local module = built_furnace_module()
    module.buildings[2].entity.get_output_inventory().insert{ name = "iron-plate", count = 7 }
    T.eq(module:outputCount("iron-plate"), 7, "plates")
    T.truthy(module:hasOutputAvailable("iron-plate"), "available")
    T.eq(module:outputCount("copper-plate"), 0, "copper")
  end)

  T.it("only offers surplus fuel from fuel-slot outputs", function()
    Lab.patch("coal", 0, 0, 3, 1)
    local module = BurnerToBurnerModule:instantiate()
    module.buildings[1].entity = Lab.entity("burner-mining-drill", { 1, 1 })
    module.buildings[2].entity = Lab.entity("burner-mining-drill", { 3, 1 })
    module.buildings[1].entity.get_fuel_inventory().insert{ name = "coal", count = 9 }
    module.buildings[2].entity.get_fuel_inventory().insert{ name = "coal", count = 3 }
    T.eq(module:outputCount("coal"), 4, "9 - 5 kept, 3 - 5 kept counts as 0")
  end)

  T.it("is starved without fuel and fine with it", function()
    local module = built_furnace_module()
    T.truthy(module:isStarved(), "no fuel")
    for i = 1, 2 do module.buildings[i].entity.get_fuel_inventory().insert{ name = "coal", count = 5 } end
    T.falsy(module:isStarved(), "fueled")
  end)

  T.it("asks for fuel only where it runs low, gathered in one trip", function()
    local module = built_furnace_module()
    local tasks = module:fuelTasks()
    T.eq(#tasks, 3, "gather + 2 fuel tasks")
    T.same({ tasks[1].type, tasks[1].qty }, { "coal", 10 }, "gather")
    module.buildings[1].entity.get_fuel_inventory().insert{ name = "coal", count = 5 }
    tasks = module:fuelTasks()
    T.eq(#tasks, 2, "gather + 1 fuel task")
    T.eq(tasks[1].qty, 5, "coal for the furnace only")
  end)
end)
