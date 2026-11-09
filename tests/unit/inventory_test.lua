local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'

local function top(machine) return Fakes.goals(machine)[1] end

T.describe("Inventories", function()
  T.it("has room while a stack of the item isn't full, or a slot is free", function()
    T.falsy(Inventories.has_room_for(Fakes.player{ slots = 1, items = { stone = 50 } }, "stone"), "one full stack")
    T.truthy(Inventories.has_room_for(Fakes.player{ slots = 1, items = { stone = 49 } }, "stone"), "one short")
    T.falsy(Inventories.has_room_for(Fakes.player{ slots = 1, items = { stone = 49 } }, "coal"), "other item")
    T.truthy(Inventories.has_room_for(Fakes.player{ slots = 2, items = { stone = 50 } }, "coal"), "free slot")
  end)

  T.it("counts what the craft queue will add, but not its intermediates", function()
    local player = Fakes.player{ items = { ["burner-mining-drill"] = 1, ["iron-gear-wheel"] = 2 }, crafting_queue = {
      { recipe = "iron-gear-wheel", count = 6, prerequisite = true },
      { recipe = "burner-mining-drill", count = 2, prerequisite = false },
    } }
    T.eq(Inventories.count_with_queue(player, "burner-mining-drill"), 3, "drills")
    T.eq(Inventories.count_with_queue(player, "iron-gear-wheel"), 2, "gears")
  end)
end)

T.describe("GoalMachine:needs", function()
  T.it("takes the largest total per item over the whole stack", function()
    local player = Fakes.player{ items = { ["iron-plate"] = 8 } }
    local machine = GoalMachine:new()
    machine:pushStart({
      GatherResourceTask:new{ type = "stone", qty = 10 },
      CraftRecipeTask:new{ recipe = "burner-mining-drill", qty = 2 },
      FuelBuildingTask:new{ building = {}, fuel = "coal", amount = 5 },
    })
    T.same(machine:needs{ player = player, machine = machine }, { stone = 10, ["iron-plate"] = 18, coal = 5 }, "needs")
  end)

  T.it("can start below a given task", function()
    local player = Fakes.player()
    local machine = GoalMachine:new()
    local gather = GatherResourceTask:new{ type = "stone", qty = 10 }
    local wait = Task:new()
    machine:pushStart({ wait, gather })
    T.same(machine:needs({ player = player, machine = machine }, machine:entryBelow(wait)), { stone = 10 }, "below")
    T.eq(machine:entryBelow(gather), nil, "below the last")
  end)

  T.it("knows what a module still needs before it is built", function()
    local player = Fakes.player{ items = { ["iron-plate"] = 8 } }
    local needs = BuildModuleTask:new{ module = BurnerToBurnerModule }:needs{ player = player }
    T.same(needs, { ["burner-mining-drill"] = 2, ["iron-plate"] = 18, stone = 10, coal = 5 }, "needs")
  end)
end)

T.describe("Mining with a full inventory", function()
  T.before_each(function() Lab.reset() end)

  T.it("makes room before mining ore", function()
    local player = Fakes.player{ surface = Lab.surface(), slots = 1, items = { ["stone-brick"] = 100 } }
    player.mining_state = { mining = true }
    local machine = GoalMachine:new()
    MineResourceTask:new{ target = Lab.ore("iron-ore", 0, 0), type = "iron-ore", qty = 5 }:tick{ player = player, machine = machine }
    T.eq(getmetatable(top(machine)), MakeRoomTask, "task")
    T.eq(top(machine).item, "iron-ore", "item")
    T.falsy(player.mining_state.mining, "stopped mining")
  end)

  T.it("makes room before felling a tree", function()
    local player = Fakes.player{ surface = Lab.surface(), slots = 1, items = { ["stone-brick"] = 100 } }
    local machine = GoalMachine:new()
    MineEntityTask:new{ entity = Lab.entity("tree-01", { 2.5, 2.5 }, "neutral") }:tick{ player = player, machine = machine }
    T.eq(getmetatable(top(machine)), MakeRoomTask, "task")
    T.same(top(machine).items, { { name = "wood", count = 4 } }, "items")
  end)

  T.it("needs room for everything a rock drops at once", function()
    local rock = Lab.entity("huge-rock", { 4.5, 4.5 }, "neutral")
    -- one free slot: stone alone or coal alone would fit, both don't
    local player = Fakes.player{ surface = Lab.surface(), slots = 2, items = { ["stone-brick"] = 100 } }
    local machine = GoalMachine:new()
    MineEntityTask:new{ entity = rock }:tick{ player = player, machine = machine }
    T.eq(getmetatable(top(machine)), MakeRoomTask, "with one free slot")
    player = Fakes.player{ surface = Lab.surface(), slots = 3, items = { ["stone-brick"] = 100 } }
    machine = GoalMachine:new()
    MineEntityTask:new{ entity = rock }:tick{ player = player, machine = machine }
    T.falsy(getmetatable(top(machine)) == MakeRoomTask, "with two free slots")
  end)

  T.it("mines as usual while a stack of the item has room", function()
    local player = Fakes.player{ surface = Lab.surface(), slots = 1, items = { ["iron-ore"] = 10 } }
    local machine = GoalMachine:new()
    MineResourceTask:new{ target = Lab.ore("iron-ore", 0, 0), type = "iron-ore", qty = 20 }:tick{ player = player, machine = machine }
    T.same(Fakes.goals(machine), {}, "tasks")
    T.truthy(player.mining_state.mining, "mining")
  end)
end)

T.describe("MakeRoomTask", function()
  local manager, machine
  T.before_each(function()
    Lab.reset()
    manager = ResourceManager:new()
    storage.resource_managers[1] = manager
    storage.room_failed_at = nil
    machine = GoalMachine:new()
  end)
  -- 3 slots: 2 of bricks nobody needs, 1 of coal of which 10 are wanted
  local function full_player(extra)
    local opts = { surface = Lab.surface(), slots = 3, items = { ["stone-brick"] = 200, coal = 50 } }
    for k, v in pairs(extra or {}) do opts[k] = v end
    local player = Fakes.player(opts)
    machine:pushSingle(GatherResourceTask:new{ type = "coal", qty = 10 })
    return player
  end
  local function stash_at(position)
    local chest = Lab.entity("wooden-chest", position)
    manager:register_source(ChestResourceSource:new{ entity = chest })
    return chest
  end
  local function run(task, player, ticks)
    for i = 1, ticks or 1 do
      if task:achieved{ player = player, machine = machine } then return end
      task:tick{ player = player, machine = machine }
    end
  end

  T.it("merges stacks first", function()
    local player = full_player()
    local task = MakeRoomTask:new{ item = "iron-ore" }
    run(task, player)
    T.eq(player.inventory.merged, 1, "merged")
    T.falsy(task:achieved{ player = player, machine = machine }, "achieved")
  end)

  T.it("puts what no task needs into a stash chest", function()
    local player = full_player()
    local chest = stash_at({ 2.5, 0.5 })
    local task = MakeRoomTask:new{ item = "iron-ore" }
    run(task, player, 3)
    local stored = chest.get_inventory(defines.inventory.chest)
    T.eq(stored.get_item_count("stone-brick"), 200, "bricks stored")
    T.eq(stored.get_item_count("coal"), 40, "surplus coal stored")
    T.eq(player.inventory.get_item_count("coal"), 10, "coal kept for the gather task")
    T.truthy(task:achieved{ player = player, machine = machine }, "room for iron ore")
  end)

  T.it("keeps a round of fuel for the bot's modules", function()
    local player = full_player()
    manager:register_source(ModuleResourceSource:new{ module = BurnerToFurnaceModule:instantiate() })
    local chest = stash_at({ 2.5, 0.5 })
    run(MakeRoomTask:new{ item = "iron-ore" }, player, 2)
    T.eq(player.inventory.get_item_count("coal"), 20, "10 for the gather + 10 for the module")
  end)

  T.it("walks to a stash chest out of reach", function()
    local player = full_player{ can_reach = function() return false end }
    stash_at({ 10.5, 0.5 })
    local task = MakeRoomTask:new{ item = "iron-ore" }
    run(task, player, 2)
    T.eq(getmetatable(top(machine)), MoveToPointTask, "walks")
  end)

  T.it("places a chest from the inventory when there is no stash nearby", function()
    Lab.patch("iron-ore", -2, -2, 1, 1) -- the player stands on ore
    local player = full_player{ items = { ["stone-brick"] = 100, coal = 50, ["wooden-chest"] = 1 } }
    stash_at({ 35.5, 0.5 }) -- too far
    local task = MakeRoomTask:new{ item = "iron-ore" }
    run(task, player, 2)
    local place = top(machine)
    T.eq(getmetatable(place), PlaceBuildingTask, "places")
    T.eq(place.type, "wooden-chest", "a chest")
    T.eq(Lab.surface().count_entities_filtered{ position = place.position, type = "resource" }, 0, "not on ore")

    -- the chest stands (and its slot is free now): it still becomes a stash
    -- and takes the surplus
    machine.goals = machine.goals.next
    place.building.entity = Lab.entity("wooden-chest", place.position)
    player.inventory.remove{ name = "wooden-chest", count = 1 }
    T.truthy(Inventories.has_room_for(player, "iron-ore"), "placing it made room")
    run(task, player)
    T.eq(#manager.sources, 2, "registered")
    T.eq(place.building.entity.get_inventory(defines.inventory.chest).get_item_count("stone-brick"), 100, "bricks stored")
  end)

  T.it("crafts a chest when it has what it takes", function()
    local player = full_player{ craftable = 1 }
    local task = MakeRoomTask:new{ item = "iron-ore" }
    run(task, player, 2)
    T.eq(getmetatable(top(machine)), CraftRecipeTask, "crafts")
    T.eq(top(machine).recipe, "wooden-chest", "recipe")
  end)

  T.it("fetches wood for a chest from a tree nearby", function()
    Lab.entity("tree-01", { 6.5, 6.5 }, "neutral")
    local player = full_player{ items = { ["stone-brick"] = 200, wood = 1 } }
    local task = MakeRoomTask:new{ item = "iron-ore" }
    run(task, player, 2)
    local gather = top(machine)
    T.same({ getmetatable(gather) == GatherResourceTask, gather.type, gather.qty }, { true, "wood", 3 }, "2 more wood")
  end)

  T.it("doesn't go for a chest when it makes room for another one's chest", function()
    local player = full_player{ items = { ["stone-brick"] = 100, coal = 50, ["wooden-chest"] = 1 } }
    machine:pushSingle(MakeRoomTask:new{ item = "stone" })
    local task = MakeRoomTask:new{ item = "iron-chest" }
    machine:pushSingle(task)
    run(task, player, 2)
    T.truthy(task.done, "done")
    T.eq(top(machine), task, "nothing pushed")
    T.eq(player.inventory.get_item_count("stone-brick"), 0, "bricks dropped instead")
  end)

  T.it("drops just enough when no chest can be had", function()
    local player = full_player()
    local task = MakeRoomTask:new{ item = "iron-ore" }
    run(task, player, 2)
    T.truthy(task:achieved{ player = player, machine = machine }, "achieved")
    T.eq(player.inventory.get_item_count("stone-brick"), 100, "bricks still carried")
    local dropped = 0
    for _, e in pairs(Lab.surface().find_entities_filtered{ type = "item-entity" }) do
      if e.stack.name == "stone-brick" then dropped = dropped + e.stack.count end
    end
    T.eq(dropped, 100, "one stack on the ground")
    T.truthy(Inventories.has_room_for(player, "iron-ore"), "room")
  end)

  T.it("gives up once when everything is still needed", function()
    local player = Fakes.player{ surface = Lab.surface(), slots = 3, items = { coal = 150 } }
    machine:pushSingle(GatherResourceTask:new{ type = "coal", qty = 200 })
    local task = MakeRoomTask:new{ item = "iron-ore" }
    run(task, player, 2)
    T.truthy(task.done, "done")
    T.eq(#player.printed, 1, "reported")
    T.eq(player.inventory.get_item_count("coal"), 150, "kept")
    local again = MakeRoomTask:new{ item = "iron-ore" }
    run(again, player, 2)
    T.truthy(again.done, "done right away")
    T.eq(#player.printed, 1, "not reported again")
  end)
end)

T.describe("Stash chests", function()
  local manager
  T.before_each(function()
    Lab.reset()
    manager = ResourceManager:new()
    storage.resource_managers[1] = manager
  end)

  T.it("provide what they hold, ahead of the map", function()
    local chest = Lab.entity("wooden-chest", { 2.5, 0.5 })
    chest.get_inventory(defines.inventory.chest).insert{ name = "stone", count = 30 }
    Lab.ore("stone", 1, 1)
    manager:register_source(ChestResourceSource:new{ entity = chest })
    local player = Fakes.player{ surface = Lab.surface() }
    T.eq(getmetatable(manager:best_resource_source(player, "stone")), ChestResourceSource, "stone")
    T.eq(getmetatable(manager:best_resource_source(player, "coal")), nil, "coal")
  end)

  T.it("give what is missing", function()
    local chest = Lab.entity("wooden-chest", { 2.5, 0.5 })
    chest.get_inventory(defines.inventory.chest).insert{ name = "stone", count = 30 }
    local player = Fakes.player{ surface = Lab.surface(), items = { stone = 4 } }
    local task = TakeFromChestTask:new{ entity = chest, type = "stone", qty = 10 }
    task:tick{ player = player, machine = GoalMachine:new() }
    T.eq(player.inventory.get_item_count("stone"), 10, "inventory")
    T.eq(chest.get_inventory(defines.inventory.chest).get_item_count("stone"), 24, "chest")
    T.truthy(task:achieved{ player = player }, "achieved")
  end)
end)
