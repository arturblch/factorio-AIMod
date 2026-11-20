local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'

local function top(machine) return Fakes.goals(machine)[1] end

T.describe("WaitForOutputTask: work while waiting", function()
  local machine, wait
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    machine = GoalMachine:new()
    wait = WaitForOutputTask:new{ module = BurnerToFurnaceModule:instantiate(), type = "iron-plate", qty = 10 }
  end)
  -- the wait on top, then `below`, top first
  local function stack(below)
    local tasks = { wait }
    for _, task in ipairs(below) do tasks[#tasks + 1] = task end
    machine:pushStart(tasks)
  end
  local function tick(player) wait:tick{ player = player, machine = machine } end

  T.it("fetches what a task below wants and the map has", function()
    Lab.patch("stone", 5, 5, 6, 6)
    local player = Fakes.player{ surface = Lab.surface() }
    stack{ GatherResourceTask:new{ type = "iron-plate", qty = 18 }, GatherResourceTask:new{ type = "stone", qty = 10 } }
    tick(player)
    local gather = top(machine)
    T.same({ getmetatable(gather) == GatherResourceTask, gather.type, gather.qty, gather.optional },
      { true, "stone", 10, true }, "gather")
  end)

  T.it("knows what a module still to be built will want", function()
    Lab.patch("coal", 5, 5, 6, 6)
    local player = Fakes.player{ surface = Lab.surface(), items = { ["burner-mining-drill"] = 2 } }
    stack{ BuildModuleTask:new{ module = BurnerToBurnerModule } }
    tick(player)
    T.same({ top(machine).type, top(machine).qty }, { "coal", 5 }, "fuel for it")
  end)

  T.it("stays put when the map doesn't have it", function()
    local player = Fakes.player{ surface = Lab.surface() }
    stack{ GatherResourceTask:new{ type = "stone", qty = 10 } }
    tick(player)
    T.eq(top(machine), wait, "top")
  end)

  T.it("stays put when it is already there", function()
    Lab.patch("stone", 5, 5, 6, 6)
    local player = Fakes.player{ surface = Lab.surface(), items = { stone = 10 } }
    stack{ GatherResourceTask:new{ type = "stone", qty = 10 } }
    tick(player)
    T.eq(top(machine), wait, "top")
  end)

  T.it("never fetches what it waits for for a task below", function()
    Lab.patch("coal", 5, 5, 6, 6)
    local player = Fakes.player{ surface = Lab.surface() }
    wait = WaitForOutputTask:new{ module = BurnerToBurnerModule:instantiate(), type = "coal", qty = 5 }
    stack{ GatherResourceTask:new{ type = "coal", qty = 10 } }
    tick(player)
    T.eq(top(machine), wait, "top")
  end)

  T.it("mines what it waits for by hand when the map has it, a few at a time", function()
    Lab.patch("stone", 5, 5, 6, 6)
    local player = Fakes.player{ surface = Lab.surface(), items = { stone = 3 } }
    -- the stone drill makes 15 a minute; hands mine 30
    wait = WaitForOutputTask:new{ module = ModuleLibrary.get("StoneToChest"):instantiate(), type = "stone", qty = 40, total = 40 }
    stack{}
    tick(player)
    local gather = top(machine)
    T.same({ getmetatable(gather) == GatherResourceTask, gather.type, gather.qty, gather.from_map },
      { true, "stone", 13, true }, "10 more from the map")
  end)

  T.it("doesn't mine plates or without a total", function()
    Lab.patch("stone", 5, 5, 6, 6)
    local player = Fakes.player{ surface = Lab.surface() }
    wait = WaitForOutputTask:new{ module = ModuleLibrary.get("StoneToChest"):instantiate(), type = "stone", qty = 40 }
    stack{}
    tick(player)
    T.eq(top(machine), wait, "no total: only the module counts")
  end)

  T.it("looks again only after a second", function()
    local player = Fakes.player{ surface = Lab.surface() }
    stack{ GatherResourceTask:new{ type = "stone", qty = 10 } }
    tick(player)
    Lab.patch("stone", 5, 5, 6, 6)
    tick(player) -- same tick
    T.eq(top(machine), wait, "top")
  end)
end)

T.describe("GatherResourceTask, from the map", function()
  T.it("mines by hand, and gives up when no ore is near", function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    local player = Fakes.player{ surface = Lab.surface() }
    local machine = GoalMachine:new()
    local task = GatherResourceTask:new{ type = "stone", qty = 10, from_map = true }
    machine:pushSingle(task)
    task:tick{ player = player, machine = machine }
    T.truthy(task:achieved{ player = player }, "nothing near: given up")
    T.same(player.printed, {}, "quietly")
    Lab.patch("stone", 5, 5, 6, 6)
    machine = GoalMachine:new()
    task = GatherResourceTask:new{ type = "stone", qty = 10, from_map = true }
    machine:pushSingle(task)
    task:tick{ player = player, machine = machine }
    local kinds = {}
    for _, t in ipairs(Fakes.goals(machine)) do
      local kind = getmetatable(t)
      kinds[#kinds + 1] = kind == MoveToPointTask and "move" or kind == MineResourceTask and "mine" or kind == GatherResourceTask and "gather" or "?"
    end
    T.same(kinds, { "move", "mine", "gather" }, "walks onto the ore and mines it")
    T.truthy(task.by_hand, "by hand")
  end)
end)

T.describe("GatherResourceTask, optional", function()
  T.it("gives up at once when nothing provides the item", function()
    storage.resource_managers[1] = { get_resources = function() return false end }
    local player = Fakes.player()
    local task = GatherResourceTask:new{ type = "stone", qty = 10, optional = true }
    task:tick{ player = player, machine = GoalMachine:new() }
    T.truthy(task:achieved{ player = player }, "achieved")
    T.same(player.printed, {}, "printed")
  end)
end)
