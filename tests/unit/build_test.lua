local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'

-- A burner drill (2x2) to be placed centered on (10, 10), i.e. on tiles 9..10.
local SPOT = { x = 10, y = 10 }
local function place_drill(fields)
  local task = PlaceBuildingTask:new{ type = "burner-mining-drill", position = SPOT, direction = defines.direction.north }
  for k, v in pairs(fields or {}) do task[k] = v end
  return task
end

local function only_goal(machine)
  local goals = Fakes.goals(machine)
  return #goals == 1 and goals[1] or nil
end

T.describe("PlaceBuildingTask", function()
  T.before_each(function() Lab.reset() end)

  T.it("walks closer first when too far away", function()
    local player = Fakes.player{ surface = Lab.surface(), position = { x = -20, y = 10 }, items = { ["burner-mining-drill"] = 1 } }
    local machine = GoalMachine:new()
    place_drill():tick{ player = player, machine = machine }
    T.same(Fakes.goal_classes(machine), { "MoveToPointTask" }, "tasks")
  end)

  T.it("steps off the spot instead of building on itself", function()
    local player = Fakes.player{ surface = Lab.surface(), position = { x = 10, y = 10 }, items = { ["burner-mining-drill"] = 1 } }
    local machine = GoalMachine:new()
    place_drill():tick{ player = player, machine = machine }
    local walk = only_goal(machine)
    T.truthy(walk, "one walk task")
    T.truthy(walk.y < SPOT.y - 2, "stands above the building, y=" .. tostring(walk and walk.y))
  end)

  T.it("places the building and takes it from the inventory", function()
    Lab.patch("iron-ore", 9, 9, 10, 10)
    local player = Fakes.player{ surface = Lab.surface(), position = { x = 10, y = 7 }, items = { ["burner-mining-drill"] = 1 } }
    local building = {}
    local task = place_drill{ building = building }
    task:tick{ player = player, machine = GoalMachine:new() }
    T.truthy(task.placed and task.placed.valid, "placed")
    T.eq(task.placed.name, "burner-mining-drill", "entity")
    T.eq(building.entity, task.placed, "linked to the module building")
    T.eq(player.inventory.get_item_count("burner-mining-drill"), 0, "item used")
    T.truthy(task:achieved{ player = player }, "achieved")
  end)

  T.it("gives up after five walks that don't get it there", function()
    local player = Fakes.player{ surface = Lab.surface(), position = { x = -20, y = 10 }, items = { ["burner-mining-drill"] = 1 } }
    local task = place_drill()
    for i = 1, 6 do task:tick{ player = player, machine = GoalMachine:new() } end
    T.truthy(task.failed, "failed")
    T.truthy(task:achieved{ player = player }, "achieved (gave up)")
  end)

  T.it("gives up when the spot stays blocked, without using the item", function()
    Lab.entity("wooden-chest", { 9.5, 9.5 })
    local player = Fakes.player{ surface = Lab.surface(), position = { x = 10, y = 7 }, items = { ["burner-mining-drill"] = 1 } }
    local task = place_drill()
    task:tick{ player = player, machine = GoalMachine:new() }
    T.falsy(task.failed, "failed right away")
    T.eq(#player.printed, 1, "reported")
    task.blocked_since = game.tick - 1000 -- pretend it has been blocked for a while
    task:tick{ player = player, machine = GoalMachine:new() }
    T.truthy(task.failed, "failed")
    T.eq(#player.printed, 1, "reported once")
    T.eq(player.inventory.get_item_count("burner-mining-drill"), 1, "item kept")
  end)

  T.it("gives up when the item isn't in the inventory", function()
    local player = Fakes.player{ surface = Lab.surface(), position = { x = 10, y = 7 } }
    local task = place_drill()
    task:tick{ player = player, machine = GoalMachine:new() }
    T.truthy(task.failed, "failed")
  end)
end)

T.describe("Picking a building up again (real character)", function()
  T.before_each(function() Lab.reset() end)

  -- BuildModuleTask's retry relies on mine_entity returning the building
  -- and its fuel to the inventory; the fake player only pretends to.
  T.it("mine_entity puts the building and its fuel back into the inventory", function()
    local character = Lab.entity("character", { 0.5, 0.5 })
    local drill = Lab.entity("burner-mining-drill", { 4, 4 })
    drill.get_fuel_inventory().insert{ name = "coal", count = 3 }
    T.truthy(character.mine_entity(drill, true), "mined")
    T.falsy(drill.valid, "drill gone")
    local inventory = character.get_main_inventory()
    T.eq(inventory.get_item_count("burner-mining-drill"), 1, "drill in the inventory")
    T.eq(inventory.get_item_count("coal"), 3, "fuel in the inventory")
  end)
end)

T.describe("ClearAreaTask", function()
  local AREA = { left_top = { x = 0, y = 0 }, right_bottom = { x = 10, y = 10 } }
  T.before_each(function() Lab.reset() end)

  T.it("mines the nearest tree or rock first", function()
    Lab.entity("tree-01", { 8.5, 8.5 }, "neutral")
    local rock = Lab.entity("big-rock", { 2.5, 2.5 }, "neutral")
    local player = Fakes.player{ surface = Lab.surface(), position = { x = 0, y = 0 } }
    local machine = GoalMachine:new()
    local task = ClearAreaTask:new{ area = AREA }
    task:tick{ player = player, machine = machine }
    local goal = only_goal(machine)
    T.eq(getmetatable(goal), MineEntityTask, "task")
    T.eq(goal.entity, rock, "nearest first")
    T.falsy(task:achieved{ player = player }, "achieved")
  end)

  T.it("ignores what is outside the area", function()
    Lab.entity("tree-01", { 15.5, 15.5 }, "neutral")
    local player = Fakes.player{ surface = Lab.surface() }
    local machine = GoalMachine:new()
    local task = ClearAreaTask:new{ area = AREA }
    task:tick{ player = player, machine = machine }
    T.same(Fakes.goals(machine), {}, "tasks")
    T.truthy(task:achieved{ player = player }, "achieved")
  end)

  T.it("skips obstacles the bot can't get to instead of looping on them", function()
    Unreachable.mark(Lab.entity("tree-01", { 5.5, 5.5 }, "neutral"))
    local player = Fakes.player{ surface = Lab.surface() }
    local machine = GoalMachine:new()
    local task = ClearAreaTask:new{ area = AREA }
    task:tick{ player = player, machine = machine }
    T.same(Fakes.goals(machine), {}, "tasks")
    T.truthy(task:achieved{ player = player }, "achieved")
  end)
end)
