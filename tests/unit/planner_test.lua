local T = require 'tests/lib/testing'
local Economy = require 'util/economy'

--[[
  How the planner (util/economy.lua) weighs plans, and why it builds iron
  or copper. Its goal is development - the plates a minute the base makes
  for good at the end of the horizon, every plate the same - then less
  shortage (minutes the bot spent on what it lacked), then the shares of
  GrowthTask.MIX. Points don't come into it: a copper plate is worth more
  in the production score than an iron one (copper ore 3.6, iron ore 3.1),
  and with points the planner built copper column after copper column.
]]
local function m(name) return ModuleLibrary.get(name) end
local function note(line) log("[unit] NOTE " .. line) end

local function candidates() return { m("IronColumn4"), m("CopperColumn4"), m("CoalRing4"), m("StoneToChest") } end
local ITEMS = { IronColumn4 = "iron-plate", CopperColumn4 = "copper-plate", CoalRing4 = "coal", StoneToChest = "stone" }
local function finals() return { { item = "iron-plate", module = m("IronColumn4") }, { item = "copper-plate", module = m("CopperColumn4") } } end
local function after() return Economy.carry_on(m("CoalRing4"), finals()) end
local function after_spec() return { fuel = m("CoalRing4"), finals = finals() } end

-- the ranking from `start`, logged, and each candidate's entry by name
local function rank(what, start)
  local ranking = Economy.rank(start, candidates(), after_spec(), ITEMS)
  local by_name, parts = {}, {}
  for _, entry in ipairs(ranking) do
    by_name[entry.module.name] = entry
    parts[#parts + 1] = string.format("%s %.0f/min short %.1f min", entry.module.name, entry.development, entry.shortage_total)
  end
  note(what .. ": " .. table.concat(parts, " > "))
  return ranking, by_name
end

T.describe("The planner's goal", function()
  T.it("is development: plates a minute for good, as far as the coal keeps the burners going", function()
    local _, sim = Economy.run({ built = { BurnerToFurnaceModule, m("CopperColumn4"), BurnerToBurnerModule }, stock = {} },
      Economy.fixed({}), 1)
    -- 75 plates a minute burning 18 coal; the coal pair delivers 25.5 x 0.75
    T.near(sim.development, 75 * math.min(1, 25.5 * Economy.COAL_DELIVERY / 18), 1e-6, "covered in part")
    T.truthy(sim.score > 0, "points still worked out")
  end)

  T.it("counts what the bot lacked, by item", function()
    local _, sim = Economy.run({ built = { BurnerToFurnaceModule, BurnerToBurnerModule }, stock = { coal = 200 } },
      Economy.fixed({ m("IronColumn4") }), 10)
    T.truthy(sim.shortage.stone > 1, "about 1.4 minutes mining stone: " .. sim.shortage.stone)
    T.truthy(sim.shortage["iron-plate"] > 0, "and some on plates")
    T.near(sim.shortage_total, sim.shortage.stone + sim.shortage["iron-plate"], 1e-6, "total")
  end)

  T.it("weighs more development first, then less shortage, then the share", function()
    local a = { development = 100, shortage_total = 5, share = 9 }
    T.truthy(Economy.better(a, { development = 90, shortage_total = 0, share = 0 }), "development")
    T.truthy(Economy.better(a, { development = 100.5, shortage_total = 6, share = 0 }), "near even: shortage")
    T.truthy(Economy.better({ development = 100, shortage_total = 5, share = 1 }, a), "near even again: share")
  end)
end)

T.describe("The planner on iron and copper", function()
  T.it("sees the columns cost and make the same", function()
    local iron, copper = Economy.data(m("IronColumn4")), Economy.data(m("CopperColumn4"))
    T.same({ iron.cost, iron.rates["iron-plate"], iron.burn, iron.seconds },
      { copper.cost, copper.rates["copper-plate"], copper.burn, copper.seconds }, "the same column")
  end)

  T.it("builds iron while building waits for iron plates", function()
    -- the start of growth: the iron pair makes 15 plates a minute, every
    -- column takes 36; stone and coal are plenty
    local start = { built = { BurnerToFurnaceModule, BurnerToBurnerModule, m("CoalRing4"), m("StoneToChest"), m("StoneToChest") },
      stock = { stone = 300, coal = 300 } }
    local ranking, by_name = rank("iron short", start)
    T.eq(ranking[1].module.name, "IronColumn4", "iron first")
    local iron, copper = by_name.IronColumn4, by_name.CopperColumn4
    T.truthy((copper.shortage["iron-plate"] or 0) > (iron.shortage["iron-plate"] or 0),
      string.format("copper first waits longer for plates: %.1f min against %.1f",
        copper.shortage["iron-plate"] or 0, iron.shortage["iron-plate"] or 0))
  end)

  T.it("keeps to the shares once iron piles up", function()
    -- one iron column, two copper ones: iron is behind its share of 2 to 1
    local start = { built = { BurnerToFurnaceModule, BurnerToBurnerModule, m("IronColumn4"), m("CopperColumn4"),
      m("CopperColumn4"), m("CoalRing4"), m("CoalRing4"), m("CoalRing4"), m("StoneToChest"), m("StoneToChest") },
      stock = { ["iron-plate"] = 700, coal = 200 } }
    local _, by_name = rank("iron plenty", start)
    local iron, copper = by_name.IronColumn4, by_name.CopperColumn4
    T.near(iron.development, copper.development, Economy.DEVELOPMENT_TIE, "the same development either way")
    T.truthy(Economy.better(iron, copper), "so iron, behind its share")
  end)
end)

-- start states the tests below share
local function states()
  return {
    { "growth starts", { built = { BurnerToFurnaceModule, BurnerToBurnerModule }, stock = {} } },
    { "iron short", { built = { BurnerToFurnaceModule, BurnerToBurnerModule, m("CoalRing4"), m("StoneToChest"),
      m("StoneToChest") }, stock = { stone = 300, coal = 300 } } },
    { "a bigger base", { built = { BurnerToFurnaceModule, BurnerToBurnerModule, m("IronColumn4"), m("CopperColumn4"),
      m("CopperColumn4"), m("CoalRing4"), m("CoalRing4"), m("StoneToChest") }, stock = { ["iron-plate"] = 100, coal = 100 } } },
  }
end

T.describe("The model goes from event to event", function()
  T.it("comes out as the model in steps of 6 s did", function()
    for _, case in ipairs(states()) do
      for _, first in ipairs(candidates()) do
        -- a fixed order: the same modules either way, so only the reckoning differs
        local choose = Economy.fixed({ first, m("IronColumn4"), m("CoalRing4"), m("StoneToChest"), m("CopperColumn4"),
          m("CoalRing4"), m("IronColumn4") })
        local _, events = Economy.run(case[2], choose, Economy.HORIZON)
        local _, steps = Economy.run_stepped(case[2], choose, Economy.HORIZON)
        local what = case[1] .. ", " .. first.name .. " first"
        T.same(events.order, steps.order, what .. ": the same modules")
        for i, minute in ipairs(events.built_at) do
          -- the stepped model sees a module ready and built a step late each (0.1 min), and that adds up
          T.near(minute, steps.built_at[i], 0.25 * i, what .. ": module " .. i .. " built")
        end
        T.near(events.development, steps.development, 1e-6, what .. ": development")
        T.near(events.shortage_total, steps.shortage_total, 0.5, what .. ": shortage")
        -- modules come a little sooner, so a little more is made
        for _, item in ipairs({ "iron-plate", "copper-plate", "coal" }) do
          T.near(events.made[item] or 0, steps.made[item] or 0, math.max(40, 0.08 * (steps.made[item] or 0)), what .. ": " .. item .. " made")
        end
      end
    end
  end)

  T.it("stops where the bot is free, and a copy goes on on its own", function()
    local sim = Economy.start({ built = { BurnerToFurnaceModule, BurnerToBurnerModule }, stock = { coal = 200, stone = 100 } })
    T.eq(Economy.advance(sim), "choice", "free at once")
    local copy = Economy.clone(sim)
    Economy.pick(sim, m("IronColumn4"))
    Economy.pick(copy, m("CoalRing4"))
    T.eq(Economy.advance(sim), "choice", "free again after the column")
    T.eq(Economy.advance(copy), "choice", "and after the ring")
    T.same({ sim.order, copy.order }, { { "IronColumn4" }, { "CoalRing4" } }, "each its own")
    T.truthy(sim.t ~= copy.t, "at its own time")
  end)

  T.it("takes far fewer runs to the end than steps", function()
    local profiler_events, profiler_steps
    local start = states()[3][2]
    local choose = Economy.fixed({}, after())
    profiler_events = helpers.create_profiler()
    for _ = 1, 20 do Economy.run(start, choose, Economy.HORIZON) end
    profiler_events.stop()
    profiler_steps = helpers.create_profiler()
    for _ = 1, 20 do Economy.run_stepped(start, choose, Economy.HORIZON) end
    profiler_steps.stop()
    log({ "", "[unit] NOTE 20 runs by events: ", profiler_events, "; by steps: ", profiler_steps })
  end)
end)

T.describe("The planner's search", function()
  T.it("finds with a beam what trying every order finds", function()
    for _, case in ipairs(states()) do
      local ranking, search = Economy.rank(case[2], candidates(), after_spec(), ITEMS)
      local _, best_sim, best_order = Economy.best(case[2], candidates(), Economy.DEPTH, Economy.HORIZON, after())
      note(string.format("%s: beam %s (%.0f/min, %d runs), every order %s (%.0f/min, %d runs)", case[1],
        ranking[1].module.name, ranking[1].development, search.runs, best_order[1].name, best_sim.development,
        (#candidates()) ^ Economy.DEPTH))
      T.truthy(ranking[1].development >= best_sim.development - Economy.DEVELOPMENT_TIE,
        case[1] .. ": as developed as the best order")
      T.truthy(search.runs < (#candidates()) ^ Economy.DEPTH / 3, case[1] .. ": in " .. search.runs .. " runs")
    end
  end)

  T.it("keeps its runs linear in the candidates", function()
    local search = Economy.search(states()[1][2], candidates(), after_spec(), ITEMS)
    Economy.search_step(search)
    -- every candidate first, then BEAM x candidates at each further depth
    T.eq(search.runs, #candidates() + (Economy.DEPTH - 1) * Economy.BEAM * #candidates(), "runs")
  end)

  T.it("can be run a few plans at a time, with the same result", function()
    local start = states()[2][2]
    local whole = Economy.rank(start, candidates(), after_spec(), ITEMS)
    local search = Economy.search(start, candidates(), after_spec(), ITEMS)
    local calls = 0
    while not Economy.search_step(search, 5) do
      calls = calls + 1
      T.truthy(search.runs <= calls * 5, "no more than 5 a call")
    end
    local parts = Economy.ranking(search)
    T.same({ parts[1].module.name, parts[1].development }, { whole[1].module.name, whole[1].development }, "same best")
  end)

  T.it("is plain data, fit for storage", function()
    local search = Economy.search(states()[3][2], candidates(), after_spec(), ITEMS)
    Economy.search_step(search, 7)
    local function check(value, path)
      local kind = type(value)
      T.truthy(kind ~= "function" and kind ~= "userdata", path .. " is " .. kind)
      if kind == "table" then
        T.eq(getmetatable(value), nil, path .. " has no metatable")
        for k, v in pairs(value) do check(v, path .. "." .. tostring(k)) end
      end
    end
    check(search, "search")
  end)

  T.it("spreads over ticks as a task", function()
    local start = states()[2][2]
    local task = PlanTask:new{ search = Economy.search(start, candidates(), after_spec(), ITEMS) }
    local ticks = 0
    while not task:achieved{} do
      task:tick{}
      ticks = ticks + 1
      T.truthy(task.search.runs <= ticks * PlanTask.RUNS_PER_TICK, "no more than RUNS_PER_TICK a tick")
    end
    T.truthy(ticks >= 3, ticks .. " ticks")
    T.eq(Economy.ranking(task.search)[1].module.name, Economy.rank(start, candidates(), after_spec(), ITEMS)[1].module.name, "the same choice")
  end)
end)

T.describe("Calibration in the model", function()
  T.it("takes the measured share of the coal modules", function()
    local start = { built = { BurnerToFurnaceModule, BurnerToBurnerModule }, stock = {} }
    local default = Economy.start(start)
    T.near(default.rates.coal, 25.5 * Economy.COAL_DELIVERY, 1e-6, "no calibration: COAL_DELIVERY")
    local calibrated = Economy.start({ built = start.built, stock = {}, factors = { coal = 0.9 } })
    T.near(calibrated.rates.coal, 25.5 * 0.9, 1e-6, "measured availability")
    T.near(calibrated.burn, 3.6, 1e-6, "burning as on paper")
    T.near(calibrated.rates["iron-plate"], 15, 1e-6, "items not measured: as on paper")
  end)
end)
