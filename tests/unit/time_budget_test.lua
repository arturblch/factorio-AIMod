local T = require 'tests/lib/testing'

-- a stack of tasks, top first, as GoalMachine keeps it
local function stack(...)
  local machine, below = {}, nil
  local tasks = { ... }
  for i = #tasks, 1, -1 do
    below = { current = tasks[i], next = below }
  end
  machine.goals = below
  return machine
end

T.describe("TimeBudget: what the bot spends its time on", function()
  T.it("tells growth's job by the task right above GrowthTask", function()
    local growth = GrowthTask:new()
    local round = stack(MoveToPointTask:new{}, CollectModuleOutputTask:new{ all = true }, growth)
    T.same({ TimeBudget.job(round), TimeBudget.doing(round) }, { "fuel", "walk" }, "the coal for a refuel round")
    local empty = stack(CollectModuleOutputTask:new{}, growth)
    T.same({ TimeBudget.job(empty), TimeBudget.doing(empty) }, { "collect", "take" }, "emptying an output")
    local fuel = stack(FuelBuildingTask:new{}, growth)
    T.same({ TimeBudget.job(fuel), TimeBudget.doing(fuel) }, { "fuel", "fuel" }, "fuelling")
    local build = stack(MineResourceTask:new{}, GatherResourceTask:new{}, HandSmeltTask:new{}, WaitForOutputTask:new{},
      CollectModuleOutputTask:new{}, CraftRecipeTask:new{}, BuildModuleTask:new{}, ProductionGoalTask:new{}, growth)
    T.same({ TimeBudget.job(build), TimeBudget.doing(build) }, { "build", "mine" },
      "a module's buildings: mining the ore of a hand smelt while waiting")
    local smelt = stack(HandSmeltTask:new{}, WaitForOutputTask:new{}, ResearchTask:new{}, growth)
    T.same({ TimeBudget.job(smelt), TimeBudget.doing(smelt) }, { "research", "smelt" }, "research, at the hand furnace")
    T.same({ TimeBudget.job(stack(growth)), TimeBudget.doing(stack(growth)) }, { "idle", "other" }, "growth on top")
    local goals = stack(CraftRecipeTask:new{}, BuildModuleTask:new{}, ProductionGoalTask:new{})
    T.same({ TimeBudget.job(goals), TimeBudget.doing(goals) }, { "goals", "craft" }, "before growth: the goals")
    T.same({ TimeBudget.job(stack()), TimeBudget.doing(stack()) }, { "idle", "other" }, "nothing at all")
  end)

  T.it("counts each tick in the first minutes or after them", function()
    local player = { index = 1 }
    local growth = GrowthTask:new()
    local round = stack(FuelBuildingTask:new{}, growth)
    local empty = stack(MoveToPointTask:new{}, CollectModuleOutputTask:new{}, growth)
    TimeBudget.tick(player, round)
    TimeBudget.tick(player, round)
    TimeBudget.tick(player, empty)
    local d = storage.time_budget[1]
    T.same(d.early.job, { fuel = 2, collect = 1 }, "early ticks")
    T.same(d.late.job, {}, "none later yet")
    d.start = game.tick - TimeBudget.EARLY * 3600 -- the first minutes are over
    TimeBudget.tick(player, empty)
    T.same(d.late.doing, { walk = 1 }, "a later tick")
    local r = TimeBudget.report(player)
    T.near(r.early.job.fuel, 2 / 3, 1e-9, "shares")
    T.near(r.all.job.collect, 0.5, 1e-9, "both periods together")
    T.near(r.early.minutes, 3 / 3600, 1e-12, "minutes counted")
  end)

  T.it("writes a line for people and keys for the run script", function()
    local r = TimeBudget.summary({
      early = { job = { build = 3 * 3600, fuel = 3600 }, doing = { walk = 2 * 3600, mine = 2 * 3600 } },
      late = { job = { collect = 6 * 3600, fuel = 4 * 3600 }, doing = { walk = 10 * 3600 } } })
    local line = TimeBudget.line(r)
    T.truthy(line:find("early 4.0 min: job build 75 %, fuel 25 %", 1, true), line)
    T.truthy(line:find("late 10.0 min: job collect 60 %, fuel 40 %; doing walk 100 %", 1, true), line)
    T.eq(TimeBudget.key(r), "time-key late_job_collect=0.6000 late_job_fuel=0.4000 late_doing_walk=1.0000", "keys")
  end)
end)
