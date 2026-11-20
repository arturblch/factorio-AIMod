local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'
local Economy = require 'util/economy'

--[[
  Is the order in which growth builds its modules a good one for what the
  base has on hand? From the start of growth (the iron pair and the coal
  pair of the goals) with a given stock, the planner picks the next COUNT
  modules one at a time (GrowthTask.plan, with the base and the stock of
  that moment put on the lab), and the economy model (util/economy.lua)
  runs the base for HORIZON minutes with them, the same simple way on after
  them (Economy.carry_on: coal rings as the burners need, else the plate
  column furthest behind its share), so that what an early module saves
  later counts. Every order of COUNT out of the modules growth builds (4^4
  = 256) runs the same way; the planner's order has to reach at least RATIO
  of the best one's development (plates a minute for good at the end). The
  planner looks from each state at the same model, so this mostly checks
  that it is wired to the bot's real state and candidates (it sees the coal
  the burners keep as spoken for, the brute force doesn't), and how close
  re-planning gets to one fixed best order. Each case logs both orders
  ("[unit] NOTE" lines, shown by run-headless.ps1 -Unit without -Brief).
]]
local RATIO = 0.9
-- later than the planner's own 25: each of its choices looks 25 minutes on from
-- when it is made, the last of the four some minutes in
local HORIZON = 30 -- minutes
local COUNT = 4    -- modules chosen, before Economy.carry_on

local CANDIDATES = { "IronColumn4", "CopperColumn4", "CoalRing4", "StoneToChest" }
local ORE = {
  IronColumn4 = "iron-ore", CopperColumn4 = "copper-ore", CoalRing4 = "coal", StoneToChest = "stone",
  BurnerToFurnace = "iron-ore", BurnerToFurnaceCopper = "copper-ore", BurnerToBurner = "coal",
}

local function note(line) log("[unit] NOTE " .. line) end

-- The sim's base on the lab, every module standing on its ore and
-- registered, and a player holding the sim's stock.
local function stage(sim)
  Lab.reset()
  storage.resource_managers[1] = ResourceManager:new()
  for i, m in ipairs(sim.built) do
    local x, y = -38 + ((i - 1) % 7) * 11, -36 + math.floor((i - 1) / 7) * 8
    Lab.patch(ORE[m.name], x, y, x + 8, y + 4)
    local module = m.module:instantiate()
    for _, building in ipairs(module.buildings) do
      building.entity = Lab.entity(building.type, { x + building.position.x, y + building.position.y })
    end
    storage.resource_managers[1]:register_source(ModuleResourceSource:new{ module = module })
  end
  local items = {}
  for item, count in pairs(sim.stock) do
    if count >= 1 and prototypes.item[item] then items[item] = math.floor(count) end
  end
  return Fakes.player{ surface = Lab.surface(), items = items }
end

-- What growth builds next from the sim's state: the producer of the item
-- GrowthTask.plan picks, as ProductionGoalTask does for a growth goal.
-- `before`: the sim's spent ticks per item when growth last built for it.
local function chain_choice(sim, before)
  local player = stage(sim)
  local since = {}
  for item, ticks in pairs(sim.spent) do
    if ticks - (before[item] or 0) > 0 then since[item] = ticks - (before[item] or 0) end
  end
  local plan = GrowthTask.plan(player, since)
  if not plan then return nil end
  before[plan.item] = sim.spent[plan.item]
  return ModuleLibrary.producer(player, plan.item)
end

local function names(order)
  local list = {}
  for i, entry in ipairs(order) do list[i] = type(entry) == "string" and entry or entry.name end
  return table.concat(list, ", ")
end

local function compare(what, stock)
  local start = { built = { BurnerToFurnaceModule, BurnerToBurnerModule }, stock = stock }
  local candidates = {}
  for i, name in ipairs(CANDIDATES) do candidates[i] = ModuleLibrary.get(name) end
  -- the planner goes on the same way: coal rings as the burners need, else
  -- the plate column furthest behind its share
  local finals = { { item = "iron-plate", module = ModuleLibrary.get("IronColumn4") },
    { item = "copper-plate", module = ModuleLibrary.get("CopperColumn4") } }
  local after = Economy.carry_on(ModuleLibrary.get("CoalRing4"), finals)
  local best, best_sim, best_order = Economy.best(start, candidates, COUNT, HORIZON, after)
  local chosen, before = 0, {}
  local value, sim = Economy.run(start, function(s)
    if chosen >= COUNT then return after(s) end
    chosen = chosen + 1
    return chain_choice(s, before)
  end, HORIZON)
  note(string.format("%s: planner %s = %.0f/min (built at %s min); best %s = %.0f/min (built at %s min)", what,
    names(sim.order), value, names((function()
      local t = {}; for i, m in ipairs(sim.built_at) do t[i] = string.format("%.1f", m) end; return t end)()),
    names(best_order), best, names((function()
      local t = {}; for i, m in ipairs(best_sim.built_at) do t[i] = string.format("%.1f", m) end; return t end)())))
  T.truthy(value >= RATIO * best, string.format("%s: planner %s %.0f/min, %s %.0f/min", what, names(sim.order), value,
    names(best_order), best))
  return value, best, sim, best_order
end

T.describe("The order of growth modules for what is on hand", function()
  T.before_each(function()
    storage.failed_goals = nil
  end)

  T.it("with nothing on hand", function() compare("nothing on hand", {}) end)
  T.it("with stone on hand", function() compare("200 stone", { stone = 200 }) end)
  T.it("with coal on hand", function() compare("400 coal", { coal = 400 }) end)
  T.it("with plates and stone on hand", function()
    compare("150 iron plates, 100 stone", { ["iron-plate"] = 150, stone = 100 })
  end)
end)

T.describe("The economy model", function()
  T.it("makes what the modules make and builds when it has the cost", function()
    local start = { built = { BurnerToFurnaceModule }, stock = { coal = 100 } }
    local value, sim = Economy.run(start, Economy.fixed({}), 10)
    T.near(sim.made["iron-plate"], 150, 1e-6, "15 plates a minute")
    T.near(sim.burnt, 36, 1e-6, "3.6 coal a minute")
    T.truthy(sim.score > 0, "worth points")
    T.eq(value, 0, "but no coal module keeps it going: no development")
    value = Economy.run({ built = { BurnerToFurnaceModule, BurnerToBurnerModule }, stock = {} }, Economy.fixed({}), 10)
    T.near(value, 15, 1e-6, "with the coal pair: 15 plates a minute for good")
    -- a column: 36 plates, 40 stone, 160 coal; 1.3 minutes mining the stone,
    -- 20 plates from the pair meanwhile, the rest smelted by hand alongside
    -- it in half a minute, then 70 s building
    local _, built = Economy.run({ built = { BurnerToFurnaceModule }, stock = { coal = 200 } },
      Economy.fixed({ ModuleLibrary.get("IronColumn4") }), 10)
    T.same(built.order, { "IronColumn4" }, "built")
    T.near(built.built_at[1], 40 / 30 + 16 / 30 + 70 / 60, 0.25, "built")
    T.truthy(built.spent.stone > 0 and built.spent["iron-plate"] > 0, "time on stone and on plates")
  end)

  T.it("stops the burners without coal", function()
    local _, sim = Economy.run({ built = { BurnerToFurnaceModule }, stock = { coal = 18 } }, Economy.fixed({}), 10)
    T.near(sim.made["iron-plate"], 75, 0.5, "5 minutes of coal")
  end)
end)
