require 'task'
require 'util'
require 'util/logger'
require 'util/inventories'
require 'controllers/tasks/production_goal_task'
require 'controllers/tasks/fuel_building_task'
require 'controllers/tasks/collect_module_output_task'
require 'controllers/tasks/gatherResourcesTask'
require 'controllers/tasks/build_module_task'
require 'controllers/tasks/research_task'
require 'controllers/modules/library'
require 'util/supply_chain'
require 'util/economy'
require 'util/strategy'
require 'controllers/tasks/plan_task'

--[[
  GrowthTask
  The bot's last goal: when the goals before it are met it doesn't stop.
   - Upkeep first: once a burner is low on fuel, a round that tops up every
     burner below half (all the coal of the coal modules collected in one
     trip, see fuel_round); else emptying the nearest coal module whose
     output is half full. Burner modules stop within minutes otherwise, and
     more of them would make nothing. Plates and stone wait in their modules
     until something takes them (plan 4.11).
   - Then one more module (GrowthTask.plan): the planner (util/economy.lua)
     runs a model of the base forward from where it stands - what the
     modules make and burn, what is in stock - for each order of the next
     few modules it could build (one per product: plates, coal, and the
     stone their buildings take) and builds the first module of the order
     that makes the most. A ProductionGoalTask just above the current rate
     builds exactly one module.
  Achieved only once no module can be added any more (every producer given
  up on). The first time it runs, the goals before it count as done.
]]
GrowthTask = Task:new()
local log = Logger.makeLogger("GrowthTask");

-- what growth is for, and the share of each for the very first module, a
-- minute (no bricks: at the start of 2.1 nothing takes them, every recipe
-- that does - wall, steel furnace, concrete - waits behind lab research)
GrowthTask.MIX = {["iron-plate"] = 2, ["copper-plate"] = 1};
GrowthTask.FUEL = "coal";

-- Electricity (plan 3.4): once the burner base has this many modules, a
-- power module (steam engine and a lab, blueprints/library.lua), then the
-- labs research these, one after another: automation unlocks the
-- assembling machine, which makes the packs of the next ones.
GrowthTask.POWER_MODULE = "SteamPower";
GrowthTask.ELECTRICITY_AFTER = 4;
-- The technologies growth wants; Strategy.roadmap puts their prerequisites
-- that take packs first (plan 2.8).
GrowthTask.RESEARCH = {"automation", "electric-mining-drill"};
-- The most modules the planner weighs (plan 2.9): the fuel and the raw items
-- of the buildings always, then the final products furthest behind their
-- targets; what more there is waits for a later plan.
GrowthTask.MAX_CANDIDATES = 5;
-- Modules that make science packs for our labs (plan 3.5), built before a
-- research that takes their packs once the force can make their buildings.
GrowthTask.SCIENCE_MODULES = {"RedScience"};
local LOW_FUEL = 5;       -- refuel below this many (a burner drill burns 2.25 coal a minute)
local FUEL_AMOUNT = 20;   -- and top up to this many
local REFUEL_BELOW = 10;  -- in that round, every burner below this many too

function GrowthTask:achieved (args)
  return self.stopped == true;
end

function GrowthTask:toString()
  return "GrowthTask";
end

local function modules(player)
  local manager = storage.resource_managers[player.index];
  local result = {};
  for i, source in ipairs(manager and manager.sources or {}) do
    if(source.module and source:is_valid()) then
      result[#result + 1] = source.module;
    end
  end
  return result;
end

-- The refuel round (plan 4.7) as tasks, or nil while every burner the bot
-- fuels has LOW_FUEL or more. Once one is below, every one below
-- REFUEL_BELOW is topped up to FUEL_AMOUNT in the same round: unless the
-- inventory holds that much already, the bot first takes all the coal
-- waiting in our modules (nearest first), gathers what is still missing,
-- then goes from burner to burner, always to the nearest one left. The
-- rest of the coal stays in the inventory for the next round, which then
-- needs no trip to the coal at all.
function GrowthTask.fuel_round(player)
  local fuel = GrowthTask.FUEL;
  local stops, due, wanted = {}, false, 0;
  for i, module in ipairs(modules(player)) do
    for j, input in ipairs(module.inputs) do
      local entity = module:entity(input.building);
      local inventory = entity and input.slot == "fuel" and input.type == fuel and input.ongoing ~= false and entity.get_fuel_inventory();
      if(inventory) then
        local count = inventory.get_item_count(fuel);
        due = due or count < LOW_FUEL;
        if(count < REFUEL_BELOW) then
          stops[#stops + 1] = {building=module.buildings[input.building], position=entity.position};
          wanted = wanted + FUEL_AMOUNT - count;
        end
      end
    end
  end
  if(not due) then
    return nil;
  end
  local tasks = {};
  local at = player.position;
  if(Inventories.total_craftable_count(player, fuel) < wanted) then
    local sources = {};
    for i, module in ipairs(modules(player)) do
      local outputs = module:outputsForProduct(fuel);
      if(module:outputCount(fuel) > 0) then
        sources[#sources + 1] = {module=module, position=outputs[1].entity.position};
      end
    end
    table.sort(sources, function(a, b) return util.distance(at, a.position) < util.distance(at, b.position); end);
    for i, source in ipairs(sources) do
      tasks[#tasks + 1] = CollectModuleOutputTask:new{module=source.module, type=fuel, qty=wanted, all=true};
      at = source.position;
    end
    -- what the coal modules didn't have
    tasks[#tasks + 1] = GatherResourceTask:new{type=fuel, qty=wanted};
  end
  while(#stops > 0) do
    local best, best_distance;
    for i, stop in ipairs(stops) do
      local distance = util.distance(at, stop.position);
      if(not best_distance or distance < best_distance) then
        best, best_distance = i, distance;
      end
    end
    local stop = table.remove(stops, best);
    tasks[#tasks + 1] = FuelBuildingTask:new{building=stop.building, fuel=fuel, amount=FUEL_AMOUNT};
    at = stop.position;
  end
  return tasks;
end

-- Tasks that empty `module`'s output of the fuel, or nil when it needs
-- nothing. Only the fuel (plan 4.11): emptying every half full output, the
-- bot spent 41 % of its time after the tenth minute carrying plates about
-- (1 500 iron and 1 250 copper in its inventory) that nothing used. Plates
-- and stone wait in their modules until a gather takes them; a module
-- standing full burns nothing meanwhile.
local function upkeep(player, module)
  for i, output in ipairs(module.outputs) do
    local half = prototypes.item[output.type].stack_size / 2;
    for j, found in ipairs(output.type == GrowthTask.FUEL and module:outputsForProduct(output.type) or {}) do
      if(found.available >= half) then
        local qty = Inventories.total_craftable_count(player, output.type) + found.available;
        return {CollectModuleOutputTask:new{module=module, type=output.type, qty=qty}};
      end
    end
  end
  return nil;
end

-- The upkeep due now, or nil: the refuel round, else emptying the nearest
-- coal module whose output is half full.
function GrowthTask.upkeep(player)
  local round = GrowthTask.fuel_round(player);
  if(round) then
    return round;
  end
  local best, best_distance;
  for i, module in ipairs(modules(player)) do
    local tasks = upkeep(player, module);
    local entity = module:entity(1);
    if(tasks and entity) then
      local distance = util.distance(player.position, entity.position);
      if(not best_distance or distance < best_distance) then
        best, best_distance = tasks, distance;
      end
    end
  end
  return best;
end

local function given_up(player, name)
  for i, failed in ipairs(storage.failed_goals and storage.failed_goals[player.index] or {}) do
    if(failed == name) then return true; end
  end
  return false;
end

-- Whether every building of `module` can be crafted now (an assembling
-- machine waits for automation).
local function can_make(player, module)
  for i, building in ipairs(module.buildings) do
    local recipe = player.force.recipes[building.type];
    if(not (recipe and recipe.enabled)) then
      return false;
    end
  end
  return true;
end

-- A module of SCIENCE_MODULES to build before researching `tech`, or nil:
-- one making packs `tech` takes that we don't have yet, didn't give up on
-- and can make the buildings of.
function GrowthTask.science_module(player, tech)
  local have = {};
  for i, module in ipairs(modules(player)) do
    have[module.name] = true;
  end
  local takes = {};
  for i, ingredient in ipairs(tech.research_unit_ingredients) do
    takes[ingredient.name] = true;
  end
  for i, name in ipairs(GrowthTask.SCIENCE_MODULES) do
    local module = ModuleLibrary.get(name);
    local useful = false;
    for j, pack in ipairs(module and module.packs or {}) do
      useful = useful or takes[pack] == true;
    end
    if(useful and not have[name] and not given_up(player, name) and can_make(player, module)) then
      return module;
    end
  end
  return nil;
end

-- The electricity step due now, as tasks, or nil: the power module once
-- there are ELECTRICITY_AFTER modules, then the research of RESEARCH in
-- order, each once the one before is done: first a science module for its
-- packs if one can be built, then the research while the labs lack packs
-- for it.
function GrowthTask.electricity(player)
  local power = ModuleLibrary.get(GrowthTask.POWER_MODULE);
  if(not power or given_up(player, power.name)) then
    return nil;
  end
  -- only modules making plates or fuel count: a stone drill early on is
  -- no reason to start on power with a single iron pair
  local count, built = 0, false;
  for i, module in ipairs(modules(player)) do
    if(module.power) then
      built = true;
    else
      local counts = false;
      for j, output in ipairs(module.outputs or {}) do
        counts = counts or GrowthTask.MIX[output.type] ~= nil or output.type == GrowthTask.FUEL;
      end
      if(counts) then count = count + 1; end
    end
  end
  if(not built) then
    if(count >= GrowthTask.ELECTRICITY_AFTER) then
      log("Growing: power, with " .. count .. " modules running", "INFO");
      return {BuildModuleTask:new{module=power}};
    end
    return nil;
  end
  for i, name in ipairs(Strategy.roadmap(player.force, GrowthTask.RESEARCH)) do
    local tech = player.force.technologies[name];
    if(tech and not tech.researched and not given_up(player, "research " .. name)) then
      local science = GrowthTask.science_module(player, tech);
      if(science) then
        log("Growing: " .. science.name .. " for the packs of " .. name, "INFO");
        return {BuildModuleTask:new{module=science}};
      end
      local task = ResearchTask:new{tech=name};
      if(not task:achieved{player=player}) then
        return {task};
      end
      return nil; -- the labs are on it; the next research waits for this one
    end
  end
  return nil;
end

-- The first technology of RESEARCH not researched yet and not given up on, or nil.
function GrowthTask.next_research(player)
  for i, name in ipairs(Strategy.roadmap(player.force, GrowthTask.RESEARCH)) do
    local tech = player.force.technologies[name];
    if(tech and not tech.researched and not given_up(player, "research " .. name)) then
      return name;
    end
  end
  return nil;
end

-- The modules growth may build, one per item, in a fixed order: the
-- producer (ModuleLibrary.producer) of each product of MIX, of the fuel, and
-- of each raw item their buildings take that a module makes (stone).
-- {{item=, module=}, ...}; no module twice.
function GrowthTask.candidates(player)
  local items = {};
  for item in pairs(GrowthTask.MIX) do items[#items + 1] = item; end
  table.sort(items);
  items[#items + 1] = GrowthTask.FUEL;
  local seen, result, taken = {}, {}, {};
  local i = 1;
  while(i <= #items) do
    local item = items[i];
    local module = not seen[item] and ModuleLibrary.producer(player, item);
    seen[item] = true;
    if(module and not taken[module.name]) then
      taken[module.name] = true;
      result[#result + 1] = {item=item, module=module};
      local raws = {};
      for raw in pairs(ModuleLibrary.report(module).cost) do raws[#raws + 1] = raw; end
      table.sort(raws);
      for j, raw in ipairs(raws) do
        if(not seen[raw]) then items[#items + 1] = raw; end
      end
    end
    i = i + 1;
  end
  return result;
end

-- The candidates the planner weighs (plan 2.9): every one that isn't for a
-- final product (the fuel, the stone their buildings take), then the final
-- products furthest behind their `targets` first, up to MAX_CANDIDATES.
function GrowthTask.shortlist(candidates, targets, rates)
  local result, finals = {}, {};
  for i, candidate in ipairs(candidates) do
    if(targets[candidate.item]) then
      finals[#finals + 1] = candidate;
    else
      result[#result + 1] = candidate;
    end
  end
  table.sort(finals, function(a, b)
    local sa, sb = (rates[a.item] or 0) / targets[a.item], (rates[b.item] or 0) / targets[b.item];
    if(math.abs(sa - sb) > 1e-9) then return sa < sb; end
    return a.item < b.item;
  end);
  for i, candidate in ipairs(finals) do
    if(#result < GrowthTask.MAX_CANDIDATES or i == 1) then result[#result + 1] = candidate; end
  end
  return result;
end

--[[
  What the planner needs from the game, or a decision when there is nothing
  to plan: {decided = plan or false} with no module to build or nothing
  running yet (the first module is for the largest share, reason "shares"),
  else {search = Economy.search(...), research=, targets=}.
  Strategy (plan 2.8): the targets of the final products - their MIX
  shares scaled to the one furthest ahead, plus what the labs take of them.
  Tactics (plan 2.9): the shortlist of candidates, searched with a beam
  from the base as it stands (Economy.state).
]]
function GrowthTask.prepare(player)
  local candidates = GrowthTask.candidates(player);
  if(#candidates == 0) then
    return {decided=false};
  end
  local research = GrowthTask.next_research(player);
  if(#modules(player) == 0) then
    local item = GrowthTask.next_share(player);
    local planned = item and ModuleLibrary.producer(player, item);
    if(not planned) then return {decided=false}; end
    return {decided={item=item, reason="shares", planned=planned,
      chain=SupplyChain.analyze(player, {planned=planned, research=research})}};
  end
  local chain = SupplyChain.analyze(player, {research=research});
  local rates, demand = {}, {};
  for item, link in pairs(chain.links) do
    rates[item] = link.rate;
    demand[item] = link.demand.research;
  end
  local targets = Strategy.targets(GrowthTask.MIX, rates, demand);
  local shortlist = GrowthTask.shortlist(candidates, targets, rates);
  local item_of, list, finals, fuel = {}, {}, {}, nil;
  for i, candidate in ipairs(shortlist) do
    item_of[candidate.module.name] = candidate.item;
    list[#list + 1] = candidate.module;
    if(targets[candidate.item]) then finals[#finals + 1] = candidate; end
    if(candidate.item == GrowthTask.FUEL) then fuel = candidate.module; end
  end
  local search = Economy.search(Economy.state(player, list), list, {fuel=fuel, finals=finals}, item_of, targets);
  return {search=search, research=research, targets=targets};
end

-- The plan from a done `search` (GrowthTask.prepare): {item=, reason="plan",
-- planned=, ranking=, targets=, chain=}.
function GrowthTask.decide(player, prepared)
  local ranking = Economy.ranking(prepared.search);
  local best = ranking[1];
  return {item=best.item, reason="plan", planned=best.module, ranking=ranking, targets=prepared.targets,
    runs=prepared.search.runs, factors=prepared.search.start.factors, chain=SupplyChain.analyze(player, {planned=best.module, research=prepared.research})};
end

--[[
  What to build the next module for, or nil when no module can be added:
  {item=, reason=, planned=, chain=, ranking=, targets=}, all at once (the
  growth task itself spreads the search over ticks with PlanTask).
  The planner ranks the shortlisted candidates by where the base stands
  after Economy.HORIZON minutes when it builds that one next, then the best
  few more (a beam), then goes on the simple way (Economy.carry_on: the
  fuel module while the burners would run short, else the module of the
  final product furthest behind its target): development first (the
  plates a minute it makes for good), then shortage (the minutes the bot
  spent on what it lacked), then the targets; growth builds the best
  (reason "plan"). With no module running there is nothing to plan from:
  the first one is for the largest share (reason "shares"). `chain`: the
  supply chain with the planned module, for /aimod-chain and the logs.
]]
function GrowthTask.plan(player, spent)
  local prepared = GrowthTask.prepare(player);
  if(prepared.decided ~= nil) then
    return prepared.decided or nil;
  end
  Economy.search_step(prepared.search);
  return GrowthTask.decide(player, prepared);
end

-- What the bot lacked in a plan, the longest first: "stone 3.2 min, iron-plate 0.5 min".
function GrowthTask.shortage_text(shortage)
  local items = {};
  for item, minutes in pairs(shortage or {}) do
    if(minutes >= 0.05) then items[#items + 1] = item; end
  end
  table.sort(items, function(a, b) return shortage[a] > shortage[b]; end);
  local parts = {};
  for i, item in ipairs(items) do parts[#parts + 1] = string.format("%s %.1f min", item, shortage[item]); end
  return #parts > 0 and table.concat(parts, ", ") or "nothing";
end

-- Why `plan` (GrowthTask.plan) builds what it does, in a few words: the
-- planner's ranking by development (plates a minute in Economy.HORIZON
-- minutes) and shortage, "IronColumn4 315/min short 1.2 min > ...".
function GrowthTask.why(plan)
  if(not plan.ranking) then
    return plan.reason;
  end
  local parts = {};
  for i, entry in ipairs(plan.ranking) do
    parts[#parts + 1] = string.format("%s %d/min short %.1f min", entry.module.name, math.floor(entry.development + 0.5),
      entry.shortage_total);
  end
  local measured = {};
  for k, value in pairs(plan.factors or {}) do measured[#measured + 1] = string.format("%s %.2f", k, value); end
  table.sort(measured);
  return "plan: " .. table.concat(parts, " > ") .. "; lacking " .. GrowthTask.shortage_text(plan.ranking[1].shortage) ..
    "; " .. (plan.runs or 0) .. " runs" .. (#measured > 0 and ("; calibrated " .. table.concat(measured, ", ")) or "");
end

-- The product to build the next module for (GrowthTask.plan), or nil.
function GrowthTask.next_product(player, spent)
  local plan = GrowthTask.plan(player, spent);
  return plan and plan.item or nil;
end

-- The product of GrowthTask.MIX furthest behind its share that a module can
-- still be added for, or nil.
function GrowthTask.next_share(player)
  local names = {};
  for item in pairs(GrowthTask.MIX) do
    names[#names + 1] = item;
  end
  table.sort(names); -- same choice on every run
  local best, best_share;
  for i, item in ipairs(names) do
    if(ModuleLibrary.producer(player, item)) then
      local share = ProductionGoalTask.rate(player, item) / GrowthTask.MIX[item];
      if(not best_share or share < best_share or (share == best_share and GrowthTask.MIX[item] > GrowthTask.MIX[best])) then
        best, best_share = item, share;
      end
    end
  end
  return best;
end

function GrowthTask:tick (args)
  local player = args.player;
  if(not self.started) then
    self.started = true;
    AIMod.goals_done(player);
  end

  local tasks = GrowthTask.upkeep(player) or GrowthTask.electricity(player);
  if(tasks) then
    args.machine:pushStart(tasks);
    return;
  end

  -- the search runs as a task of its own, a few plans a tick (plan 2.11)
  local plan;
  if(self.planning) then
    local prepared = self.planning;
    self.planning = nil;
    plan = GrowthTask.decide(player, prepared);
  else
    local prepared = GrowthTask.prepare(player);
    if(prepared.decided == nil) then
      self.planning = prepared;
      args.machine:pushSingle(PlanTask:new{search=prepared.search});
      return;
    end
    plan = prepared.decided or nil;
  end
  local spent = Bottleneck.since(player, self.spent_before);
  if(not plan) then
    log("No module left to build, stopping", "INFO");
    self.stopped = true;
    return;
  end
  local item = plan.item;
  -- the time on this item counts again from now; on the others it goes on
  self.spent_before = self.spent_before or {};
  self.spent_before[item] = Bottleneck.spent(player)[item];
  local rate = ProductionGoalTask.rate(player, item);
  log("Growing: one more module for " .. item .. " (" .. GrowthTask.why(plan) .. "; " .. string.format("%.1f", rate) .. "/min now, " ..
    math.floor((spent[item] or 0) / 60) .. " s spent on it since its last one)", "INFO");
  args.machine:pushSingle(ProductionGoalTask:new{item=item, per_minute=rate + 1, growth=true});
end
