local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'

local function m(name) return ModuleLibrary.get(name) end

T.describe("Evaluation: the parts", function()
  T.it("adds up milestones, what was used, surplus, idle and shortage", function()
    local r = Evaluation.summary(
      { { name = "power", minute = 8 }, { name = "automation", minute = 12 }, { name = "electric-mining-drill" } },
      30,
      { ["iron-plate"] = 3000, ["copper-plate"] = 1000, stone = 600 },
      { ["iron-plate"] = 300, ["copper-plate"] = 0, stone = 900 },
      { working = 60, ["no fuel"] = 25, ["output full"] = 15 },
      { stone = 2, ["iron-plate"] = 1.5 })
    T.same({ r.reached, r.of }, { 2, 3 }, "two of three")
    T.near(r.minutes, 8 + 12 + 30, 1e-9, "the one not reached counts as the whole run")
    -- stone used beyond what was made (from the start kit) counts as made
    T.near(r.used, (300 + 0 + 600) / 30, 1e-9, "used a minute")
    T.near(r.used_items["iron-plate"], 10, 1e-9, "iron a minute")
    T.near(r.surplus, (4600 - 900) / 4600, 1e-9, "surplus")
    T.same({ r.surplus_items["iron-plate"], r.surplus_items["copper-plate"], r.surplus_items.stone }, { 0.9, 1, 0 }, "by item")
    T.near(r.idle, 0.4, 1e-9, "idle drills")
    T.same(r.idle_reasons, { ["no fuel"] = 0.25, ["output full"] = 0.15 }, "why")
    T.near(r.short, 3.5, 1e-9, "bot short")
    local line = Evaluation.line(r)
    T.truthy(line:find("milestones 2 of 3", 1, true) and line:find("electric-mining-drill -", 1, true), line)
    T.truthy(Evaluation.key(r):find("reached=2 of=3 minutes=50.00 used=30.00", 1, true), Evaluation.key(r))
  end)

  T.it("compares milestones first, then what was used, then surplus and idle", function()
    local base = { reached = 3, minutes = 40, used = 30, surplus = 0.5, idle = 0.2 }
    local function with(changes)
      local r = {}
      for k, v in pairs(base) do r[k] = v end
      for k, v in pairs(changes) do r[k] = v end
      return r
    end
    T.truthy(Evaluation.better(with{ reached = 4, minutes = 90 }, base), "more milestones")
    T.truthy(Evaluation.better(with{ minutes = 35, used = 1 }, base), "sooner")
    T.truthy(Evaluation.better(with{ minutes = 40.3, used = 40 }, base), "near even: more used")
    T.truthy(Evaluation.better(with{ used = 30.3, surplus = 0.4 }, base), "near even again: less surplus")
    T.truthy(Evaluation.better(with{ idle = 0.1 }, base), "then less idle")
    T.falsy(Evaluation.better(base, base), "not better than itself")
  end)
end)

T.describe("Evaluation: watching the base", function()
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    storage.evaluation = nil
  end)

  T.it("sorts the drills by why they stand", function()
    local s = defines.entity_status
    local module = m("CoalRing4"):instantiate()
    local statuses = { s.working, s.no_fuel, s.waiting_for_space_in_destination, s.no_minable_resources }
    local i = 0
    for _, building in ipairs(module.buildings) do
      i = i + 1
      building.entity = { valid = true, type = "mining-drill", status = statuses[i] }
    end
    T.same(Evaluation.drills({ module }), { working = 1, ["no fuel"] = 1, ["output full"] = 1, ["ore gone"] = 1 }, "categories")
  end)

  T.it("notes when a milestone is reached, once", function()
    local player = Fakes.player{ surface = Lab.surface() }
    Evaluation.look(player)
    local names = storage.evaluation[1].names
    T.same({ names[1], names[2] }, { "power", "science" }, "the modules first")
    T.truthy(#names >= 4, "then the research: " .. table.concat(names, ", "))
    T.eq(storage.evaluation[1].milestones.power, nil, "no power yet")
    local sources = storage.resource_managers[1].sources
    sources[#sources + 1] = { module = { name = "SteamPower", power = true, buildings = {}, outputs = {} }, is_valid = function() return true end }
    Evaluation.look(player)
    local at = storage.evaluation[1].milestones.power
    T.eq(at, game.tick, "power now")
    Evaluation.look(player)
    T.eq(storage.evaluation[1].milestones.power, at, "kept")
    local report = Evaluation.report(player)
    T.same({ report.reached, report.milestones[1].minute }, { 1, 0 }, "in the report")
  end)
end)
