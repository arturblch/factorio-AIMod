local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'

local function top(machine) return Fakes.goals(machine)[1] end

-- A module of `template` on a patch of `ore` at tiles x..x+3, 0..1, its
-- buildings standing (no fuel), registered with player 1's resource manager.
local function built(template, ore, x)
  Lab.patch(ore, x, 0, x + 3, 1)
  local module = template:instantiate()
  for _, building in ipairs(module.buildings) do
    building.entity = Lab.entity(building.type, { x + building.position.x, building.position.y })
  end
  storage.resource_managers[1]:register_source(ModuleResourceSource:new{ module = module })
  return module
end

local function fuel_all(module, count)
  for _, input in ipairs(module.inputs) do
    module:entity(input.building).get_fuel_inventory().insert{ name = "coal", count = count }
  end
end

T.describe("BaseModule:fuelUse", function()
  T.it("is what the bot has to bring", function()
    -- burner drill 150 kW + stone furnace 90 kW, of 4 MJ coal
    T.near(BurnerToFurnaceModule:fuelUse("coal") * 60, 3.6, 1e-6, "furnace module")
    T.eq(BurnerToBurnerModule:fuelUse("coal"), 0, "coal module feeds itself")
  end)
end)

T.describe("GrowthTask", function()
  local machine, player
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    machine = GoalMachine:new()
    player = Fakes.player{ surface = Lab.surface() }
  end)
  local function next_product() return GrowthTask.next_product(player) end

  T.it("starts with iron", function()
    T.eq(next_product(), "iron-plate", "the largest share when nothing is built")
  end)

  T.it("adds coal when the modules would burn more than it makes", function()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    T.eq(next_product(), "coal", "3.6 coal a minute burnt, none made")
  end)

  T.it("then the product furthest behind its share", function()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    built(BurnerToBurnerModule, "coal", 10)
    T.eq(next_product(), "copper-plate", "copper 0 of 1 before bricks 0 of 0.5")
  end)

  T.it("skips what it gave up on", function()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    built(BurnerToBurnerModule, "coal", 10)
    storage.failed_goals = { [1] = { "BurnerToFurnaceCopper" } }
    T.eq(next_product(), "stone-brick", "bricks")
  end)

  T.it("refuels a module first, both buildings in one trip", function()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    local tasks = GrowthTask.upkeep(player)
    T.same({ getmetatable(tasks[1]) == GatherResourceTask, tasks[1].type, tasks[1].qty }, { true, "coal", 40 }, "coal")
    T.same({ getmetatable(tasks[2]), tasks[2].amount, getmetatable(tasks[3]) }, { FuelBuildingTask, 20, FuelBuildingTask }, "fuel")
  end)

  T.it("empties a half full output", function()
    local module = built(BurnerToFurnaceModule, "iron-ore", 0)
    fuel_all(module, 10)
    T.eq(GrowthTask.upkeep(player), nil, "nothing to do")
    module:entity(2).get_output_inventory().insert{ name = "iron-plate", count = 50 }
    local tasks = GrowthTask.upkeep(player)
    T.same({ getmetatable(tasks[1]), tasks[1].type, tasks[1].qty }, { CollectModuleOutputTask, "iron-plate", 50 }, "collect")
  end)

  T.it("looks after the nearest module", function()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    local far = built(BurnerToFurnaceModule, "iron-ore", 40)
    player.position = { x = 40, y = 0 }
    local tasks = GrowthTask.upkeep(player)
    T.eq(tasks[2].building, far.buildings[1], "the far one is nearer the player")
  end)

  T.it("builds one more module and counts the goals before it as done", function()
    storage.goals_done = {}
    local growth = GrowthTask:new{}
    machine:pushSingle(growth)
    growth:tick{ player = player, machine = machine }
    T.same({ getmetatable(top(machine)), top(machine).item, top(machine).per_minute },
      { ProductionGoalTask, "iron-plate", 1 }, "goal")
    T.truthy(storage.goals_done[1], "goals done")
    T.same(player.printed, { "Completed goals" }, "said so")
  end)

  T.it("stops when no module can be added", function()
    storage.goals_done = { [1] = true }
    storage.failed_goals = { [1] = { "BurnerToFurnace", "BurnerToFurnaceCopper", "StonePairFurnace", "BurnerToFurnaceStone", "BurnerToBurner" } }
    local growth = GrowthTask:new{}
    machine:pushSingle(growth)
    growth:tick{ player = player, machine = machine }
    T.truthy(growth:achieved{ player = player }, "stopped")
    T.eq(top(machine), growth, "nothing pushed")
  end)
end)

T.describe("A module the bot just failed to walk to", function()
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
  end)

  T.it("isn't a source for a minute", function()
    local module = built(BurnerToFurnaceModule, "iron-ore", 0)
    local manager = storage.resource_managers[1]
    T.truthy(manager:module_source("iron-plate", false), "before")
    Unreachable.mark(module:entity(1))
    T.eq(manager:module_source("iron-plate", false), nil, "just marked")
    for key in pairs(storage.unreachable) do storage.unreachable[key] = game.tick - Unreachable.BUILDING_TICKS - 1 end
    T.truthy(manager:module_source("iron-plate", false), "a minute later")
  end)

  T.it("isn't walked to for its output", function()
    local module = built(BurnerToFurnaceModule, "iron-ore", 0)
    module:entity(2).get_output_inventory().insert{ name = "iron-plate", count = 10 }
    Unreachable.mark(module:entity(2))
    local player = Fakes.player{ surface = Lab.surface(), can_reach = function() return false end }
    local machine = GoalMachine:new()
    local task = CollectModuleOutputTask:new{ module = module, type = "iron-plate", qty = 10 }
    machine:pushSingle(task)
    task:tick{ player = player, machine = machine }
    T.truthy(task:achieved{ player = player }, "done, the gather task looks elsewhere")
    T.eq(top(machine), task, "no walk pushed")
  end)
end)
