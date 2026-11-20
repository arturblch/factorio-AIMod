require 'util'
require 'controllers/modules/library'
require 'util/production_score'
require 'util/supply_chain'

--[[
  Economy (plan 2.7, 2.9, 2.10, 2.12): a small model of the burner base, so
  that growth can plan which module to build next from where the base
  stands - what the modules make and burn, what is in stock - with no tuned
  pace or timer: it runs the base forward for candidate plans and builds the
  first module of the best one (Economy.rank, GrowthTask.plan, PlanTask).

  The model goes from event to event (plan 2.10): between two events every
  flow is constant, so the time to the next one is worked out, not stepped
  through. Events: a module is built, something the bot lacks is there, the
  coal runs out, the horizon. Every built module makes what
  ModuleLibrary.report says (BaseModule:productionRate, a minute) times its
  calibration (plan 2.12: how much of it the modules really make,
  util/calibration.lua) into one common stock and burns what
  BaseModule:fuelUse says out of its coal; with the coal gone the burners
  work as far as the coal coming in keeps them. The bot builds the modules
  it is given one after another: for each it needs the module's raw cost
  (ModuleLibrary.report) and the fuel its burners are stocked with
  (SupplyChain.STOCK, START) in the stock; while it lacks something that
  can be mined (stone, coal, wood) it mines that by hand at HAND a minute,
  else while it lacks plates it smelts them by hand at HAND_SMELT a minute
  (HandSmeltTask: a stone furnace by the ore, fed one ore at a time),
  otherwise it waits; then building takes BUILD_SECONDS. Every module the
  bot fuels or empties takes SERVICE_SECONDS of its time a minute (walks to
  refuel and to empty outputs), which slows the hand work and the building.
  A run can stop where the bot is free to choose (Economy.advance without a
  chooser) and be copied there (Economy.clone).

  What a plan is worth is not points but where it leaves the base:
   - development: the plates a minute (of the final products, every plate
     the same) the modules make at the end of the horizon, as far as the
     coal modules keep the burners going (what they make over what the
     burners burn);
   - shortage: the minutes the bot spent on what it lacked - waiting for a
     module to make it, mining or smelting it by hand - by item.
  The more developed plan wins; within DEVELOPMENT_TIE plates a minute the
  one with less shortage, within SHORTAGE_TIE minutes the one whose first
  module is for the product furthest behind its target. The production
  score of what was made is still worked out (sim.score), for comparing.

  Plans are searched with a beam (plan 2.9, Economy.search): every
  candidate first, then for the BEAM best plans so far one more candidate
  each, DEPTH deep, each plan valued by running it to the horizon and going
  on the simple way after it (Economy.carry_on). The search is plain data,
  so PlanTask can keep it in storage and do a few runs a tick. Nothing else
  is kept: modules are looked up by name.
]]
Economy = {};

Economy.HORIZON = 25;      -- minutes a plan looks ahead
Economy.DEPTH = 4;         -- modules a plan chooses before going on the simple way
Economy.BEAM = 4;          -- plans kept at each depth of the search
-- a minute by hand: the character mines 0.5/s of anything with mining time 1
Economy.HAND = {stone = 30, coal = 30, wood = 60};
-- a stone furnace smelts 18.75 plates a minute, less the walks to it
Economy.HAND_SMELT = {["iron-plate"] = 15, ["copper-plate"] = 15};
Economy.BUILD_SECONDS = {module = 30, building = 5};
Economy.SERVICE_SECONDS = 2;
-- What the coal modules make that reaches the burners, until calibration
-- (util/calibration.lua) has measured it: their buffers are small (a ring
-- holds 180), so they stand full between refuel rounds, hand furnaces burn
-- some and new modules are stocked. With the model's coal made just
-- covering the burning, growth on 4 maps spent its last 15 minutes waiting
-- for coal and mining it by hand (150 038 in 30 minutes against 238 392
-- with the coal the supply chain built, about 1.4 times the burning).
Economy.COAL_DELIVERY = 0.75;
-- what growth is for, and the share of each (GrowthTask.MIX; util/strategy.lua
-- turns them into targets)
Economy.FINAL = {["iron-plate"] = 2, ["copper-plate"] = 1};
Economy.DEVELOPMENT_TIE = 1;  -- plates a minute
Economy.SHORTAGE_TIE = 0.1;   -- minutes
Economy.DT = 0.1;             -- minutes a step of the stepped model (Economy.run_stepped)

local FUEL = "coal";
local EPSILON = 1e-9;
local MAX_EVENTS = 100000;    -- a run never takes this many; guards against a loop

local function copy(map)
  local result = {};
  for key, value in pairs(map or {}) do result[key] = value; end
  return result;
end

local function sorted_keys(map)
  local keys = {};
  for key in pairs(map) do keys[#keys + 1] = key; end
  table.sort(keys);
  return keys;
end

local static = {};
-- What the model needs of `module` (or of the module named so): {module=,
-- name=, rates=, burn=, cost=, cost_keys=, seconds=, serviced=}. Rates are
-- at full work, before calibration. A power module's burning is what its
-- engines deliver now, so it is read each time.
function Economy.data(module)
  if(type(module) == "string") then module = ModuleLibrary.get(module); end
  local data = static[module.name];
  if(not data) then
    local report = ModuleLibrary.report(module);
    local cost = copy(report.cost);
    local serviced = #module.outputs > 0;
    for i, input in ipairs(module.inputs) do
      if(input.slot == "fuel") then
        cost[input.type] = (cost[input.type] or 0) + (input.ongoing == false and SupplyChain.START or SupplyChain.STOCK);
        serviced = serviced or input.ongoing ~= false;
      end
    end
    data = {
      module = module,
      name = module.name,
      rates = copy(report.rates),
      burn = module:fuelUse(FUEL) * 60,
      cost = cost,
      cost_keys = sorted_keys(cost),
      seconds = Economy.BUILD_SECONDS.module + Economy.BUILD_SECONDS.building * #module.buildings,
      serviced = serviced,
    };
    static[module.name] = data;
  end
  if(module.power) then
    local live = copy(data);
    live.module, live.burn = module, module:fuelUse(FUEL) * 60;
    return live;
  end
  return data;
end

-- What the modules really make of `item` for each one at full work: the
-- start's calibration (util/calibration.lua), else COAL_DELIVERY for coal
-- and all of it for the rest.
local function factor(sim, item)
  local measured = sim.factors and sim.factors[item];
  if(measured) then return measured; end
  return item == FUEL and Economy.COAL_DELIVERY or 1;
end

local function add(sim, m, burn)
  burn = burn or m.burn;
  sim.built[#sim.built + 1] = m;
  local into = burn > 0 and sim.burning or sim.own;
  for item, rate in pairs(m.rates) do
    local real = rate * factor(sim, item);
    into[item] = (into[item] or 0) + real;
    sim.rates[item] = (sim.rates[item] or 0) + real;
  end
  sim.burn = sim.burn + burn;
  if(m.serviced) then sim.serviced = sim.serviced + 1; end
end

--[[
  A run of the base from `start` for `horizon` minutes, not yet going.
   - start: {built = {module or {name=, burn=}, ...}, stock = {item = count},
     factors = {item = share} (calibration; optional)}
   - final: {item = target} what development counts (default FINAL)
  The sim: {t=, horizon=, stock=, built={data, ...}, order={name, ...},
  built_at={minute, ...}, made={item = count}, burnt=, spent={item =
  ticks} (what the bot spent on each item as util/bottleneck.lua counts it:
  waiting for it or getting it by hand), rates={item = per minute} the
  modules make at full work (calibrated), own=, burning= (the same, of
  modules that feed themselves / that burn our coal), burn=, serviced=,
  bot={target=, busy_until=, done=}, final=}.
]]
function Economy.start(start, horizon, final)
  local sim = {t=0, horizon=horizon or Economy.HORIZON, stock=copy(start.stock), built={}, order={}, built_at={},
    made={}, burnt=0, spent={}, rates={}, own={}, burning={}, burn=0, serviced=0, bot={},
    factors=start.factors, final=final or Economy.FINAL};
  for i, entry in ipairs(start.built or {}) do
    if(entry.buildings) then
      add(sim, Economy.data(entry));
    else
      add(sim, Economy.data(entry.name), entry.burn);
    end
  end
  return sim;
end

-- A copy of `sim` that goes on on its own (the module data is shared).
function Economy.clone(sim)
  local c = copy(sim);
  for i, key in ipairs({"stock", "made", "spent", "rates", "own", "burning", "built", "order", "built_at", "bot"}) do
    c[key] = copy(sim[key]);
  end
  return c;
end

-- Sets what the bot builds next, where Economy.advance stopped for a choice.
function Economy.pick(sim, module)
  if(module) then
    sim.bot.target = Economy.data(module);
  else
    sim.bot.done = true;
  end
end

-- What the bot lacks of its target: the first item short, and the first
-- short one it can mine by hand.
local function lacking(sim)
  local target = sim.bot.target;
  local first, by_hand;
  for i, item in ipairs(target.cost_keys) do
    if((sim.stock[item] or 0) < target.cost[item] - EPSILON) then
      first = first or item;
      if(Economy.HAND[item] and not by_hand) then by_hand = item; end
    end
  end
  return first, by_hand;
end

--[[
  Runs `sim` on, event to event. Where the bot is free to start a module it
  asks `choose(sim)` (a module, or nil for nothing more); without `choose`
  it stops there and returns "choice" (Economy.pick, then advance again).
  Returns "end" at the horizon.
]]
function Economy.advance(sim, choose)
  local bot = sim.bot;
  local stalls = 0;
  for n = 1, MAX_EVENTS do
    if(sim.t >= sim.horizon - EPSILON) then
      return "end";
    end
    -- what happens at this very moment
    if(bot.busy_until and sim.t >= bot.busy_until - EPSILON) then
      add(sim, bot.target);
      sim.order[#sim.order + 1] = bot.target.name;
      sim.built_at[#sim.built_at + 1] = sim.t;
      bot.target, bot.busy_until = nil, nil;
    end
    if(not bot.busy_until and not bot.done and not bot.target) then
      if(not choose) then
        return "choice";
      end
      Economy.pick(sim, choose(sim));
    end
    local free = math.max(0.2, 1 - Economy.SERVICE_SECONDS * sim.serviced / 60);
    local short, by_hand;
    if(bot.target and not bot.busy_until) then
      short, by_hand = lacking(sim);
      if(not short) then
        for item, count in pairs(bot.target.cost) do sim.stock[item] = sim.stock[item] - count; end
        bot.busy_until = sim.t + bot.target.seconds / 60 / free;
      end
    end
    -- the flows until the next event
    local hand_item, hand_rate;
    if(short) then
      hand_item = by_hand or short;
      hand_rate = (by_hand and Economy.HAND[by_hand] or Economy.HAND_SMELT[short] or 0) * free;
    end
    local coal = sim.stock[FUEL] or 0;
    local coal_in = (sim.own[FUEL] or 0) + (hand_item == FUEL and hand_rate or 0);
    local share = 1;
    if(sim.burn > 0 and coal <= EPSILON and coal_in < sim.burn) then
      share = coal_in / sim.burn; -- out of coal: the burners take what comes in
    end
    local made = {};
    for item, rate in pairs(sim.own) do made[item] = rate; end
    for item, rate in pairs(sim.burning) do made[item] = (made[item] or 0) + rate * share; end
    if(hand_item and hand_rate > 0) then made[hand_item] = (made[hand_item] or 0) + hand_rate; end
    local function net(item)
      return (made[item] or 0) - (item == FUEL and sim.burn * share or 0);
    end
    local dt = sim.horizon - sim.t;
    if(bot.busy_until) then dt = math.min(dt, bot.busy_until - sim.t); end
    if(short) then
      for i, item in ipairs(bot.target.cost_keys) do
        local missing = bot.target.cost[item] - (sim.stock[item] or 0);
        local rate = net(item);
        if(missing > EPSILON and rate > EPSILON) then dt = math.min(dt, missing / rate); end
      end
    end
    if(sim.burn > 0 and share == 1 and coal > EPSILON and net(FUEL) < -EPSILON) then
      dt = math.min(dt, coal / -net(FUEL));
    end
    dt = math.max(dt, 0);
    -- and on to it
    for item, rate in pairs(made) do
      sim.made[item] = (sim.made[item] or 0) + rate * dt;
      sim.stock[item] = (sim.stock[item] or 0) + rate * dt;
    end
    if(sim.burn > 0) then
      sim.stock[FUEL] = math.max(0, (sim.stock[FUEL] or 0) - sim.burn * share * dt);
      sim.burnt = sim.burnt + sim.burn * share * dt;
    end
    if(short) then sim.spent[hand_item] = (sim.spent[hand_item] or 0) + dt * 3600; end
    sim.t = sim.t + dt;
    stalls = dt <= EPSILON and stalls + 1 or 0;
    if(stalls > 3) then
      -- nothing moves any more: on to the horizon as things are
      if(short) then sim.spent[hand_item] = (sim.spent[hand_item] or 0) + (sim.horizon - sim.t) * 3600; end
      sim.t = sim.horizon;
    end
  end
  error("Economy.advance: too many events");
end

-- Works out what `sim` is worth, at its end: development, shortage, score.
function Economy.finish(sim)
  local prices = ProductionScore.prices();
  sim.score = -sim.burnt * (prices[FUEL] or 0);
  for item, count in pairs(sim.made) do sim.score = sim.score + count * (prices[item] or 0); end
  -- development: what the base makes for good, its burners kept going by
  -- the coal modules as far as they can
  local cover = 1;
  if(sim.burn > 0) then cover = math.min(1, (sim.own[FUEL] or 0) / sim.burn); end
  sim.development = 0;
  for item in pairs(sim.final) do
    sim.development = sim.development + (sim.own[item] or 0) + (sim.burning[item] or 0) * cover;
  end
  sim.shortage, sim.shortage_total = {}, 0;
  for item, ticks in pairs(sim.spent) do
    sim.shortage[item] = ticks / 3600;
    sim.shortage_total = sim.shortage_total + ticks / 3600;
  end
  return sim;
end

--[[
  Runs the base for `horizon` minutes from `start` (see Economy.start),
  asking `choose(sim)` what to build whenever the bot is free (nil: nothing
  more). Returns the development and the finished sim.
]]
function Economy.run(start, choose, horizon, final)
  local sim = Economy.start(start, horizon, final);
  Economy.advance(sim, choose);
  Economy.finish(sim);
  return sim.development, sim;
end

--[[
  The same run in steps of DT minutes, as the model was first written: kept
  to check the event model against (tests/unit/planner_test.lua).
]]
function Economy.run_stepped(start, choose, horizon, final)
  local sim = Economy.start(start, horizon, final);
  local bot = sim.bot;
  local dt = Economy.DT;
  while(sim.t < sim.horizon - EPSILON) do
    local share = 1;
    if(sim.burn > 0) then share = math.min(1, math.max(0, sim.stock[FUEL] or 0) / (sim.burn * dt)); end
    for item, rate in pairs(sim.own) do
      sim.stock[item] = (sim.stock[item] or 0) + rate * dt;
      sim.made[item] = (sim.made[item] or 0) + rate * dt;
    end
    for item, rate in pairs(sim.burning) do
      sim.stock[item] = (sim.stock[item] or 0) + rate * dt * share;
      sim.made[item] = (sim.made[item] or 0) + rate * dt * share;
    end
    if(sim.burn > 0) then
      sim.stock[FUEL] = (sim.stock[FUEL] or 0) - sim.burn * dt * share;
      sim.burnt = sim.burnt + sim.burn * dt * share;
    end
    local free = math.max(0.2, 1 - Economy.SERVICE_SECONDS * sim.serviced / 60);
    if(bot.busy_until) then
      if(sim.t >= bot.busy_until - EPSILON) then
        add(sim, bot.target);
        sim.order[#sim.order + 1] = bot.target.name;
        sim.built_at[#sim.built_at + 1] = sim.t;
        bot.target, bot.busy_until = nil, nil;
      end
    elseif(not bot.done) then
      if(not bot.target) then Economy.pick(sim, choose(sim)); end
      if(bot.target) then
        local short, by_hand = lacking(sim);
        if(not short) then
          for item, count in pairs(bot.target.cost) do sim.stock[item] = sim.stock[item] - count; end
          bot.busy_until = sim.t + bot.target.seconds / 60 / free;
        else
          local item = by_hand or short;
          local rate = (by_hand and Economy.HAND[by_hand] or Economy.HAND_SMELT[short] or 0) * free;
          sim.stock[item] = (sim.stock[item] or 0) + rate * dt;
          sim.made[item] = (sim.made[item] or 0) + rate * dt;
          sim.spent[item] = (sim.spent[item] or 0) + dt * 3600;
        end
      end
    end
    sim.t = sim.t + dt;
  end
  Economy.finish(sim);
  return sim.development, sim;
end

-- Whether plan `a` ({development=, shortage_total=, share=}) beats `b`:
-- more development; near even, less shortage; near even again, the lower
-- share (the product further behind its target); else neither.
function Economy.better(a, b)
  if(math.abs(a.development - b.development) > Economy.DEVELOPMENT_TIE) then
    return a.development > b.development;
  end
  if(math.abs(a.shortage_total - b.shortage_total) > Economy.SHORTAGE_TIE) then
    return a.shortage_total < b.shortage_total;
  end
  return (a.share or math.huge) < (b.share or math.huge);
end

-- A chooser that builds `modules` in that order, then what `after(sim)`
-- says (nil: nothing).
function Economy.fixed(modules, after)
  return function(sim) return modules[#sim.order + 1] or (after and after(sim)); end
end

-- The simple way to go on after a plan, the same for every plan compared:
-- `fuel_module` (nil: none) while the fuel modules make less than the
-- burners burn with one more plate module or the stock lacks the fuel to
-- stock it, else the module of `finals` ({{item=, module=}, ...}) whose
-- product is furthest behind its target in `final` (default the sim's).
function Economy.carry_on(fuel_module, finals, final)
  return function(sim)
    local targets = final or sim.final;
    local best, best_share;
    for i, entry in ipairs(finals) do
      local share = (sim.rates[entry.item] or 0) / (targets[entry.item] or 1);
      if(not best_share or share < best_share - EPSILON) then best, best_share = entry.module, share; end
    end
    local f = best and Economy.data(best);
    if(fuel_module and f and ((sim.rates[FUEL] or 0) < sim.burn + f.burn or (sim.stock[FUEL] or 0) < (f.cost[FUEL] or 0))) then
      return fuel_module;
    end
    return best or fuel_module;
  end
end

-- Every order of `count` modules out of `candidates` (repeats allowed).
function Economy.orders(candidates, count)
  local result = {{}};
  for n = 1, count do
    local longer = {};
    for i, order in ipairs(result) do
      for j, module in ipairs(candidates) do
        local next_order = {};
        for k, m in ipairs(order) do next_order[k] = m; end
        next_order[#next_order + 1] = module;
        longer[#longer + 1] = next_order;
      end
    end
    result = longer;
  end
  return result;
end

-- The best order of `count` modules out of `candidates` from `start`, then
-- going on with `after` (a function, Economy.carry_on), by Economy.better
-- with no shares: its development, sim and the order. Every order is run:
-- the brute force the search is checked against.
function Economy.best(start, candidates, count, horizon, after, final)
  local best_sim, best_order;
  for i, order in ipairs(Economy.orders(candidates, count)) do
    local value, sim = Economy.run(start, Economy.fixed(order, after), horizon, final);
    if(not best_sim or Economy.better(sim, best_sim)) then
      best_sim, best_order = sim, order;
    end
  end
  return best_sim.development, best_sim, best_order;
end

-- `start` as plain data for storage: modules by name, a power module with
-- the burning it has now.
function Economy.snapshot(start)
  local built = {};
  for i, entry in ipairs(start.built or {}) do
    if(entry.buildings) then
      built[i] = {name=entry.name, burn=entry.power and entry:fuelUse(FUEL) * 60 or nil};
    else
      built[i] = {name=entry.name, burn=entry.burn};
    end
  end
  return {built=built, stock=copy(start.stock), factors=copy(start.factors)};
end

local function names(list)
  local result = {};
  for i, module in ipairs(list) do result[i] = type(module) == "string" and module or module.name; end
  return result;
end

--[[
  A search for the next module, as plain data (it can live in storage):
   - start: what Economy.start takes (snapshotted)
   - candidates: modules (kept by name)
   - after: {fuel = module or nil, finals = {{item=, module=}, ...}}, the
     simple way on (Economy.carry_on)
   - items: {module name = item} what each candidate is for (the tie on shares)
   - final: {item = target}
   - depth, beam, horizon: default DEPTH, BEAM, HORIZON
  Economy.search_step runs it a few plans at a time; Economy.ranking reads
  the result.
]]
function Economy.search(start, candidates, after, items, final, depth, beam, horizon)
  local finals = {};
  for i, entry in ipairs(after.finals or {}) do
    finals[i] = {item=entry.item, name=type(entry.module) == "string" and entry.module or entry.module.name};
  end
  local search = {start=Economy.snapshot(start), candidates=names(candidates),
    fuel=after.fuel and (type(after.fuel) == "string" and after.fuel or after.fuel.name) or nil, finals=finals,
    items=copy(items), final=copy(final or Economy.FINAL), depth=depth or Economy.DEPTH, beam=beam or Economy.BEAM,
    horizon=horizon or Economy.HORIZON, level=1, queue={}, results={}, done=false, runs=0};
  for i = 1, #search.candidates do search.queue[#search.queue + 1] = {i}; end
  return search;
end

local function key(order) return table.concat(order, ","); end

-- The value of one plan of `search` ({index, ...}): its run to the horizon,
-- then the simple way on.
local function evaluate(search, order)
  local modules = {};
  for i, index in ipairs(order) do modules[i] = ModuleLibrary.get(search.candidates[index]); end
  local finals = {};
  for i, entry in ipairs(search.finals) do finals[i] = {item=entry.item, module=ModuleLibrary.get(entry.name)}; end
  local after = Economy.carry_on(search.fuel and ModuleLibrary.get(search.fuel), finals);
  local value, sim = Economy.run(search.start, Economy.fixed(modules, after), search.horizon, search.final);
  return {order=order, development=sim.development, shortage=sim.shortage, shortage_total=sim.shortage_total,
    score=sim.score, built=#sim.order};
end

-- Runs up to `budget` plans of `search` (nil: all of it); returns whether
-- the search is done.
function Economy.search_step(search, budget)
  budget = budget or math.huge;
  while(not search.done and budget > 0) do
    if(#search.queue > 0) then
      local order = table.remove(search.queue, 1);
      search.results[key(order)] = evaluate(search, order);
      search.runs = search.runs + 1;
      budget = budget - 1;
    elseif(search.level >= search.depth) then
      search.done = true;
    else
      -- the BEAM best plans of this depth go one module deeper
      local level = {};
      for k, result in pairs(search.results) do
        if(#result.order == search.level) then level[#level + 1] = result; end
      end
      table.sort(level, function(a, b)
        if(Economy.better(a, b)) then return true; end
        if(Economy.better(b, a)) then return false; end
        return key(a.order) < key(b.order);
      end);
      for i = 1, math.min(search.beam, #level) do
        for j = 1, #search.candidates do
          local order = {};
          for k, index in ipairs(level[i].order) do order[k] = index; end
          order[#order + 1] = j;
          search.queue[#search.queue + 1] = order;
        end
      end
      search.level = search.level + 1;
    end
  end
  return search.done;
end

-- What a done search found: the candidates ranked by the best plan that
-- starts with each, {{module=, item=, development=, shortage={item =
-- minutes}, shortage_total=, score=, order={module, ...}}, ...}, best first.
function Economy.ranking(search)
  local sim = Economy.start(search.start, 0, search.final);
  local best = {};
  for k, result in pairs(search.results) do
    local first = result.order[1];
    if(not best[first] or Economy.better(result, best[first])) then best[first] = result; end
  end
  local ranking = {};
  for i, name in ipairs(search.candidates) do
    local result = best[i];
    if(result) then
      local item = search.items[name];
      local order = {};
      for j, index in ipairs(result.order) do order[j] = ModuleLibrary.get(search.candidates[index]); end
      ranking[#ranking + 1] = {module=ModuleLibrary.get(name), item=item, development=result.development,
        shortage=result.shortage, shortage_total=result.shortage_total, score=result.score, order=order, index=i,
        share=search.final[item] and (sim.rates[item] or 0) / search.final[item] or nil};
    end
  end
  table.sort(ranking, function(a, b)
    if(Economy.better(a, b)) then return true; end
    if(Economy.better(b, a)) then return false; end
    return a.index < b.index;
  end);
  return ranking;
end

-- The whole search at once: the ranking (see Economy.search, Economy.ranking).
function Economy.rank(start, candidates, after, items, final, depth, beam, horizon)
  local search = Economy.search(start, candidates, after, items, final, depth, beam, horizon);
  Economy.search_step(search);
  return Economy.ranking(search), search;
end

--[[
  The player's base as the model sees it: {built = {module, ...}, stock =
  {item = count}, factors = {item = share}}. Built: the working modules
  registered with the resource manager. Stock: the main inventory, what the
  modules' outputs hold and the fuel in their burners, less
  SupplyChain.STOCK of fuel for every burner the bot keeps fuelled (that
  much is spoken for); the buildings of `candidates` in the inventory count
  as what they are crafted from, as the model builds from raw items.
  Factors: the calibration (util/calibration.lua), if there is one.
]]
function Economy.state(player, candidates)
  local state = {built={}, stock={}, factors=Calibration and Calibration.factors(player) or nil};
  local buildings, reserved = {}, {};
  for i, module in ipairs(candidates or {}) do
    for j, building in ipairs(module.buildings) do buildings[building.type] = true; end
  end
  local inventory = player.get_main_inventory();
  for i, item in ipairs(inventory and inventory.get_contents() or {}) do
    if(buildings[item.name]) then
      for raw, count in pairs(ModuleLibrary.raw_cost(item.name, item.count)) do
        state.stock[raw] = (state.stock[raw] or 0) + count;
      end
    else
      state.stock[item.name] = (state.stock[item.name] or 0) + item.count;
    end
  end
  local manager = storage.resource_managers and storage.resource_managers[player.index];
  for i, source in ipairs(manager and manager.sources or {}) do
    local module = source.module;
    if(module and source:is_valid()) then
      state.built[#state.built + 1] = module;
      local counted = {};
      for j, output in ipairs(module.outputs) do
        if(not counted[output.type]) then
          counted[output.type] = true;
          state.stock[output.type] = (state.stock[output.type] or 0) + module:outputCount(output.type);
        end
      end
      for j, input in ipairs(module.inputs) do
        local entity = input.slot == "fuel" and module:entity(input.building);
        local fuel = entity and entity.get_fuel_inventory();
        if(fuel and not (counted[input.type] and ModuleLibrary.makes(module, input.type))) then
          state.stock[input.type] = (state.stock[input.type] or 0) + fuel.get_item_count(input.type);
        end
        if(input.slot == "fuel" and input.ongoing ~= false) then
          reserved[input.type] = (reserved[input.type] or 0) + SupplyChain.STOCK;
        end
      end
    end
  end
  -- the burners keep theirs: refuel rounds top every one up to STOCK, and
  -- the bot carries the coal for the next round (counting it free left
  -- growth waiting for coal at the rings with 745 on hand)
  for item, count in pairs(reserved) do
    state.stock[item] = math.max(0, (state.stock[item] or 0) - count);
  end
  return state;
end

return Economy;
