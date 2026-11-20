require 'util'
require 'controllers/modules/library'

--[[
  SupplyChain (plan 2.6): what our modules make against what the base needs,
  item by item, so that growth adds a module where the shortage is and
  /aimod-chain can show why. It is the calculators' way (expand what is
  needed through the recipes down to what the modules make) with the theory
  of constraints on top: find the weakest link, but fix what feeds it first.

  A link is an item: each one a module of the library makes, and those the
  demand reaches (science packs, wood). Per link, a minute:
   - rate: what our working modules make of it at full work
     (BaseModule:productionRate), plus our assembling machines on a network;
   - demand, by what it is for:
      burn: fuel the modules burn (BaseModule:fuelUse), the planned module's too;
      build: the raw cost of the planned module (ModuleLibrary.report) and
        the fuel it is stocked with, spread over BUILD_MINUTES: the pace
        growth aims at, so its building materials keep up;
      research: what our labs take for the research under way: packs, and
        through their recipes the plates they are made of;
   - need: all of it;
   - stock: what is on hand: in the main inventory and in our modules'
     outputs. Shown, but not taken off the need as MRP would: a module is
     built for all the minutes it will run, not for the next module alone
     (tests/unit/chain_sequence_test.lua: with 200 stone on hand a stone
     drill early still pays; taking the stock off made growth 20 % worse in
     30 minutes, the coal the bot keeps for its next refuel round building
     3 coal rings instead of 5);
   - coverage: rate / need (math.huge with nothing needed);
   - made, used: what the force really made and used up of it, from the
     game's production statistics over the last WINDOW minutes, hand work
     included;
   - stopped: {reason = n} buildings of our modules making it that stand
     now (no fuel, output full, ore gone, no power);
   - inputs: {item = true} what it comes from: the fuel its module burns,
     or for a crafted item (packs) the raw items of its recipe;
   - producer: the module growth would build for it (ModuleLibrary.producer).
  Nothing of this is kept: it is worked out from the modules and the game
  each time.
]]
SupplyChain = {};

SupplyChain.BUILD_MINUTES = 3; -- growth aims at a new module this often (2: worse, 4: about the same)
SupplyChain.STOCK = 20;        -- fuel a burner the bot fuels is kept at (GrowthTask's refuel round)
SupplyChain.START = 5;         -- fuel a burner that feeds itself gets once (BaseModule:startTasks)
SupplyChain.SHORT = 1;         -- a link covered less than this is short
local WINDOW = 10;             -- minutes of production statistics

local STOPPED = {
  [defines.entity_status.no_fuel] = "no fuel",
  [defines.entity_status.full_output] = "output full",
  [defines.entity_status.waiting_for_space_in_destination] = "output full",
  [defines.entity_status.no_minable_resources] = "ore gone",
  [defines.entity_status.no_power] = "no power",
  [defines.entity_status.low_power] = "low power",
};

-- Every module registered with the player's resource manager; `working`:
-- only those that run (ModuleResourceSource:is_valid).
local function modules(player, working)
  local manager = storage.resource_managers and storage.resource_managers[player.index];
  local result = {};
  for i, source in ipairs(manager and manager.sources or {}) do
    if(source.module and (not working or source:is_valid())) then
      result[#result + 1] = source.module;
    end
  end
  return result;
end

-- The fuels modules of the library burn, sorted.
local function fuels()
  local set = {coal=true};
  for i, module in ipairs(ModuleLibrary.listed()) do
    for j, input in ipairs(module.inputs) do
      if(input.slot == "fuel") then set[input.type] = true; end
    end
  end
  local list = {};
  for item in pairs(set) do list[#list + 1] = item; end
  table.sort(list);
  return list;
end

local function link(chain, item)
  local l = chain.links[item];
  if(not l) then
    l = {item=item, rate=0, modules=0, demand={}, need=0, inputs={}, stopped={}, made=0, used=0};
    chain.links[item] = l;
  end
  return l;
end

local function add(chain, item, kind, amount)
  if(amount > 0) then
    local l = link(chain, item);
    l.demand[kind] = (l.demand[kind] or 0) + amount;
    l.need = l.need + amount;
  end
end

-- Units a minute our labs on a network research of `tech`, and the labs.
local function lab_speed(player, tech)
  local labs = player.surface.find_entities_filtered{force=player.force, type="lab"};
  local units, count = 0, 0;
  for i, lab in ipairs(labs) do
    if(lab.electric_network_id ~= nil) then
      count = count + 1;
      -- research_unit_energy is in ticks at speed 1
      units = units + lab.prototype.get_researching_speed() * (1 + player.force.laboratory_speed_modifier) *
        3600 / tech.research_unit_energy;
    end
  end
  return units, count;
end

-- {item = per minute} our assembling machines on a network make.
local function machines(player)
  local result = {};
  for i, machine in pairs(player.surface.find_entities_filtered{force=player.force, type="assembling-machine"}) do
    local recipe = machine.get_recipe();
    if(recipe and machine.electric_network_id ~= nil) then
      local crafts = machine.prototype.get_crafting_speed() / recipe.energy * 60;
      for j, product in pairs(recipe.products) do
        if(product.type == "item") then
          result[product.name] = (result[product.name] or 0) + crafts * (product.amount or 1);
        end
      end
    end
  end
  return result;
end

--[[
  The chain as it stands: {links = {item = link}, planned = module or nil,
  research = technology name or nil, labs = n, minutes = BUILD_MINUTES}.
  options:
   - planned: the module growth would build next if nothing were short; its
     cost and fuel are the build demand, its burning counts with the rest
   - research: the technology the labs work on, if the force has none under
     way (GrowthTask's next one)
]]
function SupplyChain.analyze(player, options)
  options = options or {};
  local chain = {links={}, planned=options.planned, minutes=SupplyChain.BUILD_MINUTES, labs=0};
  local fuel_list = fuels();

  -- what the modules make and burn
  for i, module in ipairs(ModuleLibrary.all()) do
    for j, output in ipairs(module.outputs) do
      link(chain, output.type);
    end
  end
  for i, module in ipairs(modules(player, true)) do
    for item, l in pairs(chain.links) do
      local rate = module:productionRate(item) * 60;
      if(rate > 0) then
        l.rate = l.rate + rate;
        l.modules = l.modules + 1;
      end
    end
    for j, fuel in ipairs(fuel_list) do
      add(chain, fuel, "burn", module:fuelUse(fuel) * 60);
    end
  end
  for item, rate in pairs(machines(player)) do
    local l = link(chain, item);
    l.rate = l.rate + rate;
  end

  -- the next module
  local planned = options.planned;
  if(planned) then
    for item, count in pairs(ModuleLibrary.report(planned).cost) do
      add(chain, item, "build", count / SupplyChain.BUILD_MINUTES);
    end
    for i, input in ipairs(planned.inputs) do
      if(input.slot == "fuel") then
        local stock = input.ongoing == false and SupplyChain.START or SupplyChain.STOCK;
        add(chain, input.type, "build", stock / SupplyChain.BUILD_MINUTES);
      end
    end
    for j, fuel in ipairs(fuel_list) do
      add(chain, fuel, "burn", planned:fuelUse(fuel) * 60);
    end
  end

  -- research
  local force = player.force;
  local tech = force.current_research;
  if(not tech and options.research) then
    local next_tech = force.technologies[options.research];
    tech = next_tech and not next_tech.researched and next_tech or nil;
  end
  if(tech and #tech.research_unit_ingredients > 0) then
    local units, labs = lab_speed(player, tech);
    chain.labs = labs;
    if(units > 0) then
      chain.research = tech.name;
      for i, ingredient in ipairs(tech.research_unit_ingredients) do
        local packs = units * ingredient.amount;
        add(chain, ingredient.name, "research", packs);
        for item, count in pairs(ModuleLibrary.raw_cost(ingredient.name, packs)) do
          if(item ~= ingredient.name) then
            add(chain, item, "research", count);
          end
        end
      end
    end
  end

  -- where each link comes from, what is on hand, what really happened, what stands
  local statistics = force.get_item_production_statistics(player.surface);
  local minutes = math.min(WINDOW, math.max(game.tick / 3600, 1 / 60));
  local all = modules(player, false);
  local inventory = player.get_main_inventory();
  for item, l in pairs(chain.links) do
    l.stock = prototypes.item[item] and inventory and inventory.get_item_count(item) or 0;
    for i, module in ipairs(all) do
      if(prototypes.item[item] and ModuleLibrary.makes(module, item)) then
        l.stock = l.stock + module:outputCount(item);
      end
    end
    local producer = ModuleLibrary.producer(player, item);
    l.producer = producer and producer.name or nil;
    for i, input in ipairs(producer and producer.inputs or {}) do
      if(input.slot == "fuel") then l.inputs[input.type] = true; end
    end
    if(not producer and prototypes.item[item]) then
      for raw in pairs(ModuleLibrary.raw_cost(item, 1)) do
        if(raw ~= item) then l.inputs[raw] = true; end
      end
    end
    l.coverage = l.need > 0 and l.rate / l.need or math.huge;
    if(prototypes.item[item]) then
      local precision = defines.flow_precision_index.ten_minutes;
      l.made = statistics.get_flow_count{name=item, category="input", precision_index=precision, count=true} / minutes;
      l.used = statistics.get_flow_count{name=item, category="output", precision_index=precision, count=true} / minutes;
    end
    for i, module in ipairs(all) do
      if(ModuleLibrary.makes(module, item)) then
        for j, building in ipairs(module.buildings) do
          local entity = module:entity(j);
          local reason = entity and STOPPED[entity.status];
          if(reason) then l.stopped[reason] = (l.stopped[reason] or 0) + 1; end
        end
      end
    end
  end
  return chain;
end

local function sorted_keys(map)
  local keys = {};
  for key in pairs(map) do keys[#keys + 1] = key; end
  table.sort(keys);
  return keys;
end

-- The short link a module should be added for, following `l` upstream
-- while what it comes from is short too; nil if none can be.
local function root(chain, l, seen)
  seen[l.item] = true;
  for i, item in ipairs(sorted_keys(l.inputs)) do
    local input = chain.links[item];
    if(input and not seen[item] and input.coverage < SupplyChain.SHORT) then
      local found = root(chain, input, seen);
      if(found) then return found; end
    end
  end
  return l.producer and l or nil;
end

-- The link growth should add a module for, or nil when nothing is short:
-- the least covered short link, unless what it comes from is short as well
-- (stone drills burn coal; packs are made of plates): then that. Also
-- returns the short link it started from.
function SupplyChain.constraint(chain)
  local short = {};
  for item, l in pairs(chain.links) do
    if(l.coverage < SupplyChain.SHORT) then short[#short + 1] = l; end
  end
  table.sort(short, function(a, b)
    if(a.coverage ~= b.coverage) then return a.coverage < b.coverage; end
    return a.item < b.item;
  end);
  for i, l in ipairs(short) do
    local found = root(chain, l, {});
    if(found) then return found, l; end
  end
  return nil;
end

-- The links that matter, least covered first.
function SupplyChain.ordered(chain)
  local list = {};
  for item, l in pairs(chain.links) do
    if(l.need > 0 or l.rate > 0) then list[#list + 1] = l; end
  end
  table.sort(list, function(a, b)
    if(a.coverage ~= b.coverage) then return a.coverage < b.coverage; end
    return a.item < b.item;
  end);
  return list;
end

local function coverage_text(l)
  return l.coverage == math.huge and "-" or string.format("%.2f", l.coverage);
end

-- One line per link for /aimod-chain.
function SupplyChain.lines(chain)
  local lines = {};
  local constraint = SupplyChain.constraint(chain);
  for i, l in ipairs(SupplyChain.ordered(chain)) do
    local parts = {};
    for j, kind in ipairs(sorted_keys(l.demand)) do
      parts[#parts + 1] = string.format("%s %.1f", kind, l.demand[kind]);
    end
    local stopped = {};
    for j, reason in ipairs(sorted_keys(l.stopped)) do
      stopped[#stopped + 1] = l.stopped[reason] .. " " .. reason;
    end
    lines[#lines + 1] = string.format("%s: makes %.1f/min (%s), needs %.1f%s, %d on hand, coverage %s%s; made %.1f, used %.1f a minute lately%s",
      l.item, l.rate, l.modules > 0 and (l.modules .. " modules") or (l.producer and "no module yet" or "no module for it"),
      l.need, #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or "", math.floor(l.stock), coverage_text(l),
      l == constraint and " <- least covered" or "", l.made, l.used,
      #stopped > 0 and ("; standing: " .. table.concat(stopped, ", ")) or "");
  end
  return lines;
end

-- One line for the scenario runs' reports: coverage per link.
function SupplyChain.summary(chain)
  local parts = {};
  for i, l in ipairs(SupplyChain.ordered(chain)) do
    parts[#parts + 1] = string.format("%s %s (%.1f of %.1f, made %.1f, used %.1f, %d on hand)", l.item, coverage_text(l),
      l.rate, l.need, l.made, l.used, math.floor(l.stock));
  end
  return "chain: " .. (#parts > 0 and table.concat(parts, ", ") or "nothing made or needed");
end

return SupplyChain;
