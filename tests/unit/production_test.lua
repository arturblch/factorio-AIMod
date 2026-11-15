local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'

local function per_minute(module, item) return module:productionRate(item) * 60 end

-- A working module of `template` on a 2x2 patch of `ore` at tiles (x..x+1, 0..1),
-- registered with player 1's resource manager.
local function built(template, ore, x)
  Lab.patch(ore, x, 0, x + 1, 1)
  local module = template:instantiate()
  for i, building in ipairs(module.buildings) do
    building.entity = Lab.entity(building.type, { x + building.position.x, building.position.y })
  end
  storage.resource_managers[1]:register_source(ModuleResourceSource:new{ module = module })
  return module
end

T.describe("Furnace modules", function()
  local cases = {
    { BurnerToFurnaceModule, "iron-ore", "iron-plate" },
    { BurnerToFurnaceCopperModule, "copper-ore", "copper-plate" },
    { BurnerToFurnaceStoneModule, "stone", "stone-brick" },
  }

  T.it("share one layout, with their own ore and product", function()
    for _, case in ipairs(cases) do
      local module, ore, product = case[1], case[2], case[3]
      T.eq(module.resource, ore, module.name .. " resource")
      T.same({ module.geometry[1].resource, module.geometry[4].resource, module.geometry[5].resource },
        { ore, ore, nil }, module.name .. " geometry")
      T.same(module.outputs, { { building = 2, type = product, slot = "output" } }, module.name .. " output")
      T.same(module.buildings, BurnerToFurnaceModule.buildings, module.name .. " buildings")
    end
  end)

  T.it("go on their own ore only", function()
    Lab.reset()
    local player = Fakes.player{ surface = Lab.surface() }
    Lab.patch("copper-ore", 10, 10, 11, 11)
    local function can_build(module)
      return BuildModuleTask:new{ module = module }:canBuildAtPosition(player, { x = 10.5, y = 10.5 })
    end
    T.truthy(can_build(BurnerToFurnaceCopperModule), "copper module on copper")
    T.falsy(can_build(BurnerToFurnaceModule), "iron module on copper")
    T.falsy(can_build(BurnerToFurnaceStoneModule), "stone module on copper")
  end)
end)

T.describe("BaseModule:productionRate", function()
  T.it("is what the drill mines when the furnace could do more", function()
    -- burner drill: 0.25 ore/s; stone furnace: a plate per 3.2 s = 0.3125/s
    T.near(per_minute(BurnerToFurnaceModule, "iron-plate"), 15, 1e-6, "iron plates")
    T.near(per_minute(BurnerToFurnaceCopperModule, "copper-plate"), 15, 1e-6, "copper plates")
  end)

  T.it("takes the recipe's ingredient count into account", function()
    -- a brick takes 2 stone
    T.near(per_minute(BurnerToFurnaceStoneModule, "stone-brick"), 7.5, 1e-6, "bricks")
  end)

  T.it("counts what a coal module burns itself", function()
    -- 2 drills x 0.25 coal/s = 30/min, each burns 150 kW of 4 MJ coal = 2.25/min
    T.near(per_minute(BurnerToBurnerModule, "coal"), 25.5, 1e-6, "coal")
  end)

  T.it("is 0 for what the module doesn't make", function()
    T.eq(per_minute(BurnerToFurnaceModule, "copper-plate"), 0, "copper from iron")
    T.eq(per_minute(BurnerToFurnaceModule, "iron-ore"), 0, "ore isn't an output")
    T.eq(per_minute(BurnerToBurnerModule, "iron-plate"), 0, "plates from coal")
  end)
end)

T.describe("ModuleLibrary", function()
  T.it("knows which module makes what", function()
    T.same(ModuleLibrary.producers("iron-plate"), { BurnerToFurnaceModule }, "iron plates")
    T.same(ModuleLibrary.producers("stone-brick"), { BurnerToFurnaceStoneModule }, "bricks")
    T.same(ModuleLibrary.producers("coal"), { BurnerToBurnerModule }, "coal")
    T.same(ModuleLibrary.producers("wood"), {}, "wood")
  end)

  T.it("skips modules the bot gave up on", function()
    local player = Fakes.player{}
    T.eq(ModuleLibrary.producer(player, "coal"), BurnerToBurnerModule, "before")
    storage.failed_goals = { [1] = { "BurnerToBurner" } }
    T.eq(ModuleLibrary.producer(player, "coal"), nil, "after")
  end)
end)

T.describe("ProductionGoalTask", function()
  local player, machine
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    machine = GoalMachine:new()
    player = Fakes.player{ surface = Lab.surface() }
  end)
  local function goal(item, rate)
    local task = ProductionGoalTask:new{ item = item, per_minute = rate }
    machine:pushSingle(task)
    return task
  end
  local function tick(task) task:tick{ player = player, machine = machine } end

  T.it("builds the module that makes the item", function()
    local task = goal("iron-plate", 10)
    T.falsy(task:achieved{ player = player }, "achieved")
    tick(task)
    local top = machine.goals.current
    T.eq(getmetatable(top), BuildModuleTask, "pushed")
    T.eq(top.module, BurnerToFurnaceModule, "module")
    T.eq(task.building, top, "remembered")
  end)

  T.it("is done once working modules make enough", function()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    T.truthy(goal("iron-plate", 15):achieved{ player = player }, "15 of 15")
    T.falsy(goal("iron-plate", 20):achieved{ player = player }, "15 of 20")
    T.falsy(goal("copper-plate", 1):achieved{ player = player }, "copper")
  end)

  T.it("counts only modules that work", function()
    local module = built(BurnerToFurnaceModule, "iron-ore", 0)
    module.buildings[2].entity.destroy()
    T.eq(ProductionGoalTask.rate(player, "iron-plate"), 0, "rate")
  end)

  T.it("builds another module while short", function()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    local task = goal("iron-plate", 20)
    task.building, task.rate_before = BuildModuleTask:new{ module = BurnerToFurnaceModule }, 0
    tick(task)
    T.falsy(task.failed, "failed")
    T.eq(getmetatable(machine.goals.current), BuildModuleTask, "second module")
  end)

  T.it("gives up when a new module adds nothing", function()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    local task = goal("iron-plate", 30)
    task.building, task.rate_before = BuildModuleTask:new{ module = BurnerToFurnaceModule }, 15
    tick(task)
    T.truthy(task.failed, "failed")
    T.truthy(task:achieved{ player = player }, "off the stack")
    T.same(storage.failed_goals[1], { "iron-plate 30/min" }, "recorded for the final message")
  end)

  T.it("gives up when the module was given up on", function()
    local task = goal("iron-plate", 10)
    task.building = BuildModuleTask:new{ module = BurnerToFurnaceModule }
    task.building.failed = true
    storage.failed_goals = { [1] = { "BurnerToFurnace" } }
    tick(task)
    T.truthy(task.failed, "failed")
    T.same(storage.failed_goals[1], { "BurnerToFurnace", "iron-plate 10/min" }, "both recorded")
  end)

  T.it("gives up at once on what no module makes", function()
    local task = goal("wood", 5)
    tick(task)
    T.truthy(task.failed, "failed")
    T.eq(machine.goals.current, task, "nothing pushed")
  end)

  T.it("says what its next module will need", function()
    local needs = goal("coal", 20):needs{ player = player }
    T.eq(needs["burner-mining-drill"], 2, "drills")
    T.eq(needs.coal, 5, "first fuel")
    built(BurnerToFurnaceModule, "iron-ore", 0)
    T.eq(goal("iron-plate", 10):needs{ player = player }, nil, "nothing once achieved")
  end)
end)

T.describe("Modules that others depend on", function()
  local player, machine
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    machine = GoalMachine:new()
    player = Fakes.player{ surface = Lab.surface(), items = { ["burner-mining-drill"] = 1, ["stone-furnace"] = 1 } }
  end)
  local function tick(task)
    machine:pushSingle(task)
    task:tick{ player = player, machine = machine }
  end

  T.it("a drill is made of iron plates and stone in the end", function()
    T.same(Recipes.raw_items(player.force, player.force.recipes["burner-mining-drill"]),
      { ["iron-plate"] = true, stone = true }, "raw")
  end)

  T.it("the iron module comes before any other", function()
    Lab.patch("copper-ore", 10, 10, 11, 11)
    local copper = BuildModuleTask:new{ module = BurnerToFurnaceCopperModule }
    tick(copper)
    local top = machine.goals.current
    T.same({ getmetatable(top) == BuildModuleTask, top.module }, { true, BurnerToFurnaceModule }, "iron first")
    T.eq(copper.location, nil, "no spot taken yet")
  end)

  T.it("goes ahead once a module makes iron plates", function()
    built(BurnerToFurnaceModule, "iron-ore", -20)
    Lab.patch("copper-ore", 10, 10, 11, 11)
    local copper = BuildModuleTask:new{ module = BurnerToFurnaceCopperModule }
    tick(copper)
    T.truthy(copper.location, "spot found")
  end)

  T.it("tries the iron module once only", function()
    Lab.patch("copper-ore", 10, 10, 11, 11)
    local copper = BuildModuleTask:new{ module = BurnerToFurnaceCopperModule }
    tick(copper)
    machine.goals = machine.goals.next -- the iron module didn't work out
    copper:tick{ player = player, machine = machine }
    T.truthy(copper.location, "went ahead")
  end)

  T.it("the iron module itself needs nothing first", function()
    Lab.patch("iron-ore", 10, 10, 11, 11)
    local iron = BuildModuleTask:new{ module = BurnerToFurnaceModule }
    tick(iron)
    T.truthy(iron.location, "spot found")
  end)

  T.it("a module being built isn't started again for its own materials", function()
    machine:pushSingle(BuildModuleTask:new{ module = BurnerToFurnaceModule })
    local manager = storage.resource_managers[1]
    T.eq(manager:best_resource_source(player, "iron-plate", false, machine), nil, "iron plates")
    T.eq(manager:best_resource_source(player, "copper-plate", false, machine).module, BurnerToFurnaceCopperModule,
      "copper plates")
  end)
end)
