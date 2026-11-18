local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'

local function top(machine) return Fakes.goals(machine)[1] end
local function force() return game.forces.player end
local function technology_for(item) return ResearchResourceSource.technology_for(force(), item) end

-- Runs `fn` with technology `name` researched, then puts it and its recipes back.
local function with_researched(name, fn)
  local tech = force().technologies[name]
  tech.researched = true
  local ok, err = pcall(fn)
  tech.researched = false
  for _, effect in pairs(tech.prototype.effects) do
    if effect.type == "unlock-recipe" then force().recipes[effect.recipe].enabled = false end
  end
  if not ok then error(err, 0) end
end

T.describe("ResearchResourceSource.technology_for", function()
  T.it("knows which trigger technology unlocks a recipe", function()
    T.eq(technology_for("pipe"), "steam-power", "pipe")
    T.eq(technology_for("copper-cable"), "electronics", "copper cable")
    T.eq(technology_for("lab"), "electronics", "lab")
    T.eq(technology_for("automation-science-pack"), "automation-science-pack", "red science, after its prerequisites")
  end)

  T.it("knows nothing for unlocked recipes or science-pack research", function()
    T.eq(technology_for("iron-gear-wheel"), nil, "gears, unlocked")
    T.eq(technology_for("iron-plate"), nil, "plates, smelted")
    T.eq(technology_for("electric-mining-drill"), nil, "needs science packs")
  end)

  T.it("knows nothing once it is researched", function()
    with_researched("steam-power", function()
      T.eq(technology_for("pipe"), nil, "pipe")
    end)
  end)
end)

T.describe("ResearchTriggerTask", function()
  local machine, player
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    machine = GoalMachine:new()
    player = Fakes.player{ surface = Lab.surface(), items = { ["iron-plate"] = 8 } }
  end)
  local function research(name)
    local task = ResearchTriggerTask:new{ tech = name }
    machine:pushSingle(task)
    task:tick{ player = player, machine = machine }
    return task
  end
  local function made(item, count)
    local statistics = force().get_item_production_statistics(Lab.surface())
    statistics.clear()
    statistics.set_input_count(item, count)
    return statistics
  end

  T.it("makes what the trigger asks for", function()
    research("steam-power")
    T.same({ getmetatable(top(machine)) == GatherResourceTask, top(machine).type, top(machine).qty },
      { true, "iron-plate", 58 }, "50 more plates")
  end)

  T.it("counts what was made already", function()
    local statistics = made("iron-plate", 30)
    research("steam-power")
    statistics.clear()
    T.eq(top(machine).qty, 28, "20 more plates")
  end)

  T.it("researches trigger prerequisites first", function()
    research("automation-science-pack")
    T.same({ getmetatable(top(machine)) == ResearchTriggerTask, top(machine).tech }, { true, "electronics" }, "electronics")
  end)

  T.it("is done once researched", function()
    local task = ResearchTriggerTask:new{ tech = "steam-power" }
    T.falsy(task:achieved{ player = player }, "before")
    with_researched("steam-power", function()
      T.truthy(task:achieved{ player = player }, "after")
    end)
  end)

  T.it("gives up when making more doesn't research it", function()
    local statistics = made("iron-plate", 150)
    local task = research("steam-power")
    statistics.clear()
    T.truthy(task.failed, "failed")
    T.eq(top(machine), task, "nothing pushed")
  end)
end)

T.describe("Researching for a locked recipe", function()
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
  end)

  T.it("is where pipes come from at the start", function()
    local player = Fakes.player{ surface = Lab.surface() }
    local manager = storage.resource_managers[1]
    T.eq(getmetatable(manager:best_resource_source(player, "pipe", false, GoalMachine:new())), ResearchResourceSource, "source")
    T.eq(manager:best_resource_source(player, "pipe", true, GoalMachine:new()), nil, "not for an optional gather")
  end)

  T.it("pushes the research", function()
    local player = Fakes.player{ surface = Lab.surface() }
    local machine = GoalMachine:new()
    storage.resource_managers[1]:get_resources(player, "copper-cable", 10, machine)
    T.same({ getmetatable(top(machine)) == ResearchTriggerTask, top(machine).tech }, { true, "electronics" }, "task")
  end)
end)
