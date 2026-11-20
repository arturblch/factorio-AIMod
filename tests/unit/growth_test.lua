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

T.describe("Waiting on a module for more than it holds", function()
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
  end)

  T.it("waits only for what the outputs hold, the rest comes next round", function()
    -- refuelling a column of 8 burners asked a pair of coal drills for 94
    -- coal, and the bot stood there for the rest of the game
    local pair = built(BurnerToBurnerModule, "coal", 0)
    fuel_all(pair, 10)
    T.eq(pair:outputCapacity("coal"), 90, "2 drills x (50 - 5 kept)")
    local tasks = pair:generateTasksForOutput("coal", 94, 94)
    local wait = tasks[#tasks]
    T.same({ getmetatable(wait) == WaitForOutputTask, wait.qty }, { true, 90 }, "wait")
  end)

  T.it("a furnace holds a stack of plates", function()
    local module = built(BurnerToFurnaceModule, "iron-ore", 0)
    T.eq(module:outputCapacity("iron-plate"), 100, "one result slot")
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

  -- the iron pair, three coal pairs (76.5 coal a minute) and the stone drill
  local function base()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    for _, x in ipairs({ 10, 20, 30 }) do built(BurnerToBurnerModule, "coal", x) end
    built(ModuleLibrary.get("StoneToChest"), "stone", 40)
  end

  T.it("may build one module per product: plates, coal, and the stone they take", function()
    base() -- with no iron module yet the producer of plates would be the pair
    local names = {}
    for _, candidate in ipairs(GrowthTask.candidates(player)) do
      names[#names + 1] = candidate.item .. " " .. candidate.module.name
    end
    T.same(names, { "copper-plate CopperColumn4", "iron-plate IronColumn4", "coal CoalRing4", "stone StoneToChest" }, "candidates")
  end)

  T.it("builds the first of what the planner ranks best", function()
    base()
    local plan = GrowthTask.plan(player)
    T.eq(plan.reason, "plan", "planned")
    T.eq(#plan.ranking, 4, "every candidate ranked")
    T.same({ plan.item, plan.planned }, { plan.ranking[1].item, plan.ranking[1].module }, "the best")
    for i = 2, #plan.ranking do
      T.falsy(Economy.better(plan.ranking[i], plan.ranking[i - 1]), "best first")
    end
    T.eq(plan.ranking[1].order[1], plan.planned, "its order starts with it")
    T.truthy(GrowthTask.why(plan):find("^plan: " .. plan.planned.name), GrowthTask.why(plan))
  end)

  T.it("builds plates once stone and coal are plenty", function()
    base()
    player = Fakes.player{ surface = Lab.surface(), items = { stone = 2000, coal = 2000 } }
    local item = next_product()
    T.truthy(item == "copper-plate" or item == "iron-plate", "plates, not " .. tostring(item))
  end)

  T.it("counts buildings in the inventory as what they are made of", function()
    base()
    player = Fakes.player{ surface = Lab.surface(), items = { ["burner-mining-drill"] = 2, coal = 100 } }
    local state = Economy.state(player, { ModuleLibrary.get("IronColumn4") })
    T.same({ state.stock["iron-plate"], state.stock.stone, #state.built }, { 18, 10, 5 }, "2 drills: 18 plates, 10 stone")
    -- the iron pair's drill and furnace and the stone drill keep 20 each
    T.eq(state.stock.coal, 100 - 3 * 20, "the coal beyond what the burners keep")
  end)

  T.it("skips what it gave up on", function()
    base()
    storage.failed_goals = { [1] = { "CopperColumn4", "BurnerToFurnaceCopper" } }
    for _, candidate in ipairs(GrowthTask.candidates(player)) do
      T.truthy(candidate.item ~= "copper-plate", "no copper module left")
    end
    T.truthy(next_product() ~= "copper-plate", "no copper")
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

  T.it("fuels the nearest module first", function()
    local near = built(BurnerToFurnaceModule, "iron-ore", 0)
    local far = built(BurnerToFurnaceModule, "iron-ore", 40)
    player.position = { x = 40, y = 0 }
    local tasks = GrowthTask.upkeep(player)
    local order = {}
    for i = 2, 5 do
      order[#order + 1] = (tasks[i].building == far.buildings[1] or tasks[i].building == far.buildings[2]) and "far" or "near"
    end
    T.same(order, { "far", "far", "near", "near" }, "the far one is nearer the player, both in one round")
    T.eq(tasks[1].qty, 80, "coal for both")
  end)

  T.it("a round tops up every burner below half, with all the coal of the coal modules first", function()
    local low = built(BurnerToFurnaceModule, "iron-ore", 0)
    fuel_all(low, 2)
    local half = built(BurnerToFurnaceModule, "iron-ore", 10)
    fuel_all(half, 8)
    local full = built(BurnerToFurnaceModule, "iron-ore", 20)
    fuel_all(full, 15)
    local coal = built(BurnerToBurnerModule, "coal", 30)
    for i = 1, 2 do coal:entity(i).get_fuel_inventory().insert{ name = "coal", count = 30 } end
    local tasks = GrowthTask.upkeep(player)
    T.same({ getmetatable(tasks[1]), tasks[1].module, tasks[1].all }, { CollectModuleOutputTask, coal, true }, "all the coal first")
    T.same({ getmetatable(tasks[2]), tasks[2].type, tasks[2].qty }, { GatherResourceTask, "coal", 60 }, "then what is missing: 2 x 18 + 2 x 12")
    local fueled = {}
    for i = 3, #tasks do
      T.eq(getmetatable(tasks[i]), FuelBuildingTask, "fuel " .. i)
      fueled[tasks[i].building] = true
    end
    T.eq(#tasks, 6, "four burners")
    T.truthy(fueled[low.buildings[1]] and fueled[half.buildings[2]], "the low one and the one below half")
    T.falsy(fueled[full.buildings[1]], "not the one above half")
  end)

  T.it("needs no trip to the coal with enough in the inventory", function()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    player = Fakes.player{ surface = Lab.surface(), items = { coal = 100 } }
    local tasks = GrowthTask.upkeep(player)
    T.same({ #tasks, getmetatable(tasks[1]), getmetatable(tasks[2]) }, { 2, FuelBuildingTask, FuelBuildingTask }, "straight to the burners")
  end)

  T.it("waits for no round while every burner has enough", function()
    local module = built(BurnerToFurnaceModule, "iron-ore", 0)
    fuel_all(module, 6)
    T.eq(GrowthTask.fuel_round(player), nil, "6 of each: not yet")
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
    local every = {}
    for _, module in ipairs(ModuleLibrary.listed()) do every[#every + 1] = module.name end
    storage.failed_goals = { [1] = every }
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

T.describe("Bottleneck", function()
  local machine
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    storage.time_spent = nil
    machine = GoalMachine:new()
    machine:pushSingle(GrowthTask:new{})
  end)
  local function gather(type, by_hand)
    local task = GatherResourceTask:new{ type = type, qty = 10 }
    task.by_hand = by_hand
    return task
  end

  T.it("counts waiting for a module", function()
    machine:pushSingle(WaitForOutputTask:new{ type = "iron-plate", qty = 5 })
    T.eq(Bottleneck.item(machine), "iron-plate", "waiting")
  end)

  T.it("counts mining by hand, walking there too", function()
    machine:pushSingle(CraftRecipeTask:new{ recipe = "burner-mining-drill", qty = 1 })
    machine:pushSingle(gather("stone", true))
    machine:pushSingle(MoveToPointTask:new{ x = 5, y = 5 })
    T.eq(Bottleneck.item(machine), "stone", "stone by hand")
  end)

  T.it("counts the ore of a hand smelt for its plates", function()
    machine:pushSingle(HandSmeltTask:new{ item = "iron-plate", qty = 10 })
    machine:pushSingle(gather("iron-ore", true))
    T.eq(Bottleneck.item(machine), "iron-plate", "the smelt's product")
  end)

  T.it("doesn't count collecting from a module, building or a gather the modules serve", function()
    machine:pushSingle(gather("coal", false))
    machine:pushSingle(CollectModuleOutputTask:new{ type = "coal", qty = 10 })
    T.eq(Bottleneck.item(machine), nil, "collecting")
    local other = GoalMachine:new()
    other:pushSingle(gather("stone", true))
    other:pushSingle(PlaceBuildingTask:new{ type = "stone-furnace", position = { x = 0, y = 0 } })
    T.eq(Bottleneck.item(other), nil, "building")
    local third = GoalMachine:new()
    third:pushSingle(gather("iron-plate", false))
    T.eq(Bottleneck.item(third), nil, "from a module")
  end)

  T.it("adds up the ticks, and tells what was spent since a snapshot", function()
    local player = Fakes.player{ surface = Lab.surface() }
    machine:pushSingle(WaitForOutputTask:new{ type = "iron-plate", qty = 5 })
    Bottleneck.tick(player, machine)
    local before = Bottleneck.snapshot(player)
    Bottleneck.tick(player, machine)
    Bottleneck.tick(player, machine)
    T.same(Bottleneck.spent(player), { ["iron-plate"] = 3 }, "spent")
    T.same(Bottleneck.since(player, before), { ["iron-plate"] = 2 }, "since")
  end)

  T.it("knows a gather the map serves is by hand", function()
    Lab.ore("stone", 3, 0)
    local player = Fakes.player{ surface = Lab.surface() }
    local task = GatherResourceTask:new{ type = "stone", qty = 5 }
    machine:pushSingle(task)
    task:tick{ player = player, machine = machine }
    T.truthy(task.by_hand, "by hand")
  end)
end)

T.describe("GrowthTask and the time it spent", function()
  local player
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    player = Fakes.player{ surface = Lab.surface() }
    -- all fuelled, so no refuel round comes first
    fuel_all(built(BurnerToFurnaceModule, "iron-ore", 0), 10)
    for _, x in ipairs({ 10, 20, 30 }) do fuel_all(built(BurnerToBurnerModule, "coal", x), 10) end
    fuel_all(built(ModuleLibrary.get("StoneToChest"), "stone", 40), 10)
  end)

  -- the planner doesn't go by it; the log shows it
  T.it("counts it from its last module for the item on", function()
    storage.goals_done = { [1] = true }
    storage.failed_goals = { [1] = { "SteamPower" } } -- five modules: no power step first
    storage.time_spent = { [1] = { ["iron-plate"] = 4000, stone = 1000, coal = 500 } }
    local machine = GoalMachine:new()
    local growth = GrowthTask:new{}
    machine:pushSingle(growth)
    growth:tick{ player = player, machine = machine }
    -- the search runs as a task of its own first, a few plans a tick
    local plan_task = top(machine)
    T.eq(getmetatable(plan_task), PlanTask, "planning")
    local ticks = 0
    while not plan_task:achieved{ player = player, machine = machine } do
      plan_task:tick{ player = player, machine = machine }
      ticks = ticks + 1
    end
    T.truthy(ticks > 1, "over " .. ticks .. " ticks")
    machine:tick{ player = player } -- pops the done search
    growth:tick{ player = player, machine = machine }
    local item = top(machine).item
    T.eq(getmetatable(top(machine)), ProductionGoalTask, "then the module")
    T.same(growth.spent_before, { [item] = storage.time_spent[1][item] }, "remembered for " .. item)
    T.eq(Bottleneck.since(player, growth.spent_before)[item], nil, "nothing since for " .. item)
  end)
end)
