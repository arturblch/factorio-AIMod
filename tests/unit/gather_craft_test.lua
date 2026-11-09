local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'

-- A resource manager that records what it was asked for.
local function fake_manager(found)
  local manager = { calls = {} }
  function manager:get_resources(player, type, qty, machine)
    self.calls[#self.calls + 1] = { type = type, qty = qty }
    return found
  end
  return manager
end

T.describe("GatherResourceTask", function()
  T.it("is not achieved with fewer items than wanted (used to be inverted)", function()
    local task = GatherResourceTask:new{ type = "stone", qty = 10 }
    T.falsy(task:achieved{ player = Fakes.player{ items = { stone = 9 } } }, "9 of 10")
  end)

  T.it("is achieved with as many items as wanted or more", function()
    local task = GatherResourceTask:new{ type = "stone", qty = 10 }
    T.truthy(task:achieved{ player = Fakes.player{ items = { stone = 10 } } }, "10 of 10")
    T.truthy(task:achieved{ player = Fakes.player{ items = { stone = 25 } } }, "25 of 10")
  end)

  T.it("asks the resource manager for the total", function()
    local manager = fake_manager(true)
    storage.resource_managers[1] = manager
    local player = Fakes.player()
    GatherResourceTask:new{ type = "coal", qty = 5 }:tick{ player = player, machine = GoalMachine:new() }
    T.same(manager.calls, { { type = "coal", qty = 5 } }, "calls")
    T.same(player.printed, {}, "printed")
  end)

  T.it("reports a missing source once and doesn't search every tick", function()
    local manager = fake_manager(false)
    storage.resource_managers[1] = manager
    local player = Fakes.player()
    local task = GatherResourceTask:new{ type = "iron-plate", qty = 18 }
    for i = 1, 3 do task:tick{ player = player, machine = GoalMachine:new() } end
    T.eq(#manager.calls, 1, "searches")
    T.eq(#player.printed, 1, "messages")
  end)
end)

T.describe("CraftRecipeTask", function()
  T.it("gathers the missing raw items, as totals, before crafting", function()
    local player = Fakes.player{ items = { ["iron-plate"] = 8 } }
    local machine = GoalMachine:new()
    local task = CraftRecipeTask:new{ recipe = "burner-mining-drill", qty = 2 }
    task:tick{ player = player, machine = machine }

    local wanted = {}
    for _, goal in pairs(Fakes.goals(machine)) do wanted[goal.type] = goal.qty end
    T.same(wanted, { ["iron-plate"] = 18, stone = 10 }, "gather targets")
    T.same(player.crafted, {}, "crafted")
    T.falsy(task.started, "started")
  end)

  T.it("starts crafting when everything is there", function()
    local player = Fakes.player{ craftable = 2 }
    local task = CraftRecipeTask:new{ recipe = "burner-mining-drill", qty = 2 }
    task:tick{ player = player, machine = GoalMachine:new() }
    T.same(player.crafted, { { recipe = "burner-mining-drill", count = 2 } }, "crafted")
    T.truthy(task.started, "started")
    T.truthy(task:achieved{ player = player }, "achieved once the queue is empty")
  end)

  T.it("doesn't try to hand-craft smelting recipes", function()
    local player = Fakes.player{ craftable = 5 }
    local task = CraftRecipeTask:new{ recipe = "iron-plate", qty = 1 }
    task:tick{ player = player, machine = GoalMachine:new() }
    task:tick{ player = player, machine = GoalMachine:new() }
    T.same(player.crafted, {}, "crafted")
    T.falsy(task.started, "started")
  end)

  T.it("survives unknown recipes", function()
    local task = CraftRecipeTask:new{ recipe = "no-such-recipe", qty = 1 }
    task:tick{ player = Fakes.player(), machine = GoalMachine:new() }
    T.falsy(task.started, "started")
  end)
end)

T.describe("CraftRecipeTask with a full inventory", function()
  -- a finished craft waits for a free slot, so the bot makes room first
  T.it("makes room for the product first", function()
    local player = Fakes.player{ slots = 2, craftable = 1, items = { ["iron-plate"] = 100, ["stone-brick"] = 100 } }
    local machine = GoalMachine:new()
    local task = CraftRecipeTask:new{ recipe = "iron-gear-wheel", qty = 1 }
    task:tick{ player = player, machine = machine }
    local goal = Fakes.goals(machine)[1]
    T.eq(getmetatable(goal), MakeRoomTask, "task")
    T.eq(goal and goal.item, "iron-gear-wheel", "item")
    T.same(player.crafted, {}, "crafted")
  end)

  T.it("crafts when an ingredient is used up and frees its slot", function()
    local player = Fakes.player{ slots = 2, craftable = 1, items = { wood = 2, ["stone-brick"] = 100 } }
    local machine = GoalMachine:new()
    CraftRecipeTask:new{ recipe = "wooden-chest", qty = 1 }:tick{ player = player, machine = machine }
    T.same(Fakes.goals(machine), {}, "tasks")
    T.same(player.crafted, { { recipe = "wooden-chest", count = 1 } }, "crafted")
  end)
end)

T.describe("CraftResourceSource", function()
  T.it("crafts only what is missing", function()
    local player = Fakes.player{ items = { ["iron-gear-wheel"] = 2 } }
    local machine = GoalMachine:new()
    CraftResourceSource:new{ player = player }:gather{ type = "iron-gear-wheel", qty = 5, player = player, machine = machine }
    local goal = Fakes.goals(machine)[1]
    T.eq(goal.recipe, "iron-gear-wheel", "recipe")
    T.eq(goal.qty, 3, "crafts")
  end)
end)
