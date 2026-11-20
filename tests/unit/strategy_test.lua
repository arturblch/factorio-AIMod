local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'

local function m(name) return ModuleLibrary.get(name) end

T.describe("Strategy: the research roadmap", function()
  T.it("puts the prerequisites that take packs first, and leaves out what is done", function()
    local force = game.forces.player
    local roadmap = Strategy.roadmap(force, GrowthTask.RESEARCH)
    T.truthy(#roadmap >= 2, "something to research: " .. table.concat(roadmap, ", "))
    local at = {}
    for i, name in ipairs(roadmap) do at[name] = i end
    for i, name in ipairs(roadmap) do
      local tech = force.technologies[name]
      T.truthy(#tech.research_unit_ingredients > 0, name .. " takes packs")
      for prerequisite, p in pairs(tech.prerequisites) do
        if not p.researched and #p.research_unit_ingredients > 0 then
          T.truthy(at[prerequisite] and at[prerequisite] < i, prerequisite .. " before " .. name)
        end
      end
    end
    for _, goal in ipairs(GrowthTask.RESEARCH) do T.truthy(at[goal], goal .. " in it") end
    local tech = force.technologies.automation
    local was = tech.researched
    tech.researched = true
    local without = Strategy.roadmap(force, GrowthTask.RESEARCH)
    tech.researched = was
    for _, name in ipairs(without) do T.truthy(name ~= "automation", "researched: left out") end
  end)

  T.it("goes through the tree for a goal further on", function()
    local force = game.forces.player
    local goal = "logistic-science-pack"
    local roadmap = Strategy.roadmap(force, { goal })
    T.eq(roadmap[#roadmap], goal, "the goal last: " .. table.concat(roadmap, ", "))
  end)
end)

T.describe("Strategy: targets", function()
  T.it("scales the shares to the product furthest ahead and adds what research takes", function()
    local targets = Strategy.targets({ ["iron-plate"] = 2, ["copper-plate"] = 1 }, { ["iron-plate"] = 120, ["copper-plate"] = 30 },
      { ["copper-plate"] = 6, ["iron-plate"] = 12 })
    -- iron is ahead (120 for a share of 2): copper should come to 60
    T.same(targets, { ["iron-plate"] = 132, ["copper-plate"] = 66 }, "targets")
    T.same(Strategy.targets({ ["iron-plate"] = 2 }, {}, nil), { ["iron-plate"] = 2 }, "nothing made yet: the shares")
  end)
end)

T.describe("Tactics: the shortlist", function()
  T.it("keeps fuel and building materials, then the products furthest behind, up to the limit", function()
    local candidates = {
      { item = "coal", module = m("CoalRing4") }, { item = "stone", module = m("StoneToChest") },
      { item = "a", module = m("IronColumn4") }, { item = "b", module = m("IronColumn4") },
      { item = "c", module = m("IronColumn4") }, { item = "d", module = m("IronColumn4") },
    }
    local targets = { a = 10, b = 10, c = 10, d = 10 }
    local rates = { a = 9, b = 1, c = 5, d = 0 }
    local items = {}
    for _, candidate in ipairs(GrowthTask.shortlist(candidates, targets, rates)) do items[#items + 1] = candidate.item end
    T.same(items, { "coal", "stone", "d", "b", "c" }, "the 3 furthest behind")
  end)
end)

T.describe("Calibration", function()
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
  end)

  -- a module whose drills report `statuses`
  local function stub(template, statuses)
    local module = template:instantiate()
    local i = 0
    for _, building in ipairs(module.buildings) do
      local kind = prototypes.entity[building.type].type
      if kind == "mining-drill" then
        i = i + 1
        building.entity = { valid = true, type = kind, status = statuses[i] }
      end
    end
    return module
  end

  T.it("measures the share of drills at work, by rate", function()
    local working, waiting = defines.entity_status.working, defines.entity_status.waiting_for_space_in_destination
    local ring = stub(m("CoalRing4"), { working, working, waiting, waiting })
    local pair = stub(BurnerToBurnerModule, { working, working })
    local share = Calibration.availability({ ring, pair })
    local ring_rate, pair_rate = ring:productionRate("coal"), pair:productionRate("coal")
    T.near(share.coal, (ring_rate * 0.5 + pair_rate) / (ring_rate + pair_rate), 1e-9, "weighted by rate")
  end)

  T.it("counts a plate drill waiting for room as at work: nothing wants its plates yet", function()
    local working, waiting = defines.entity_status.working, defines.entity_status.waiting_for_space_in_destination
    local no_fuel = defines.entity_status.no_fuel
    local column = stub(m("IronColumn4"), { working, waiting, waiting, no_fuel })
    T.near(Calibration.availability({ column })["iron-plate"], 0.75, 1e-9, "3 of 4")
  end)

  T.it("gives the model only what has been sampled long enough", function()
    local player = Fakes.player{ surface = Lab.surface() }
    storage.calibration = { [1] = { availability = { coal = 0.8, stone = 0.1, ["iron-plate"] = 0.1 },
      samples = { coal = 20, stone = 3, ["iron-plate"] = 20 } } }
    T.same(Calibration.factors(player), { coal = 0.8, ["iron-plate"] = Calibration.FLOOR }, "stone not yet; at least FLOOR")
    storage.calibration = nil
    T.eq(Calibration.factors(player), nil, "nothing measured")
  end)
end)
