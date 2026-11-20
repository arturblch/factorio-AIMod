require 'base_module'
require 'util/blueprint'
require 'util/production_score'
require 'util/inventories'

--[[
  ModuleLibrary: every module the bot knows how to build, best first, made
  from the blueprints listed in blueprints/library.lua (util/blueprint.lua)
  while control.lua loads. ProductionGoalTask and BuildModuleResourceSource
  take the first one that makes the item they want and hasn't been given
  up on. A listed module whose blueprint can't be read is left out, with a
  line in the game's log.
]]
ModuleLibrary = {};

local LIBRARY = require 'blueprints/library';

local listed = {};  -- every module in the list, in order, the `off` ones too
local by_name = {};
local checks = {};  -- name -> {errors=, warnings=, flows=} from Blueprint.module
for i, entry in ipairs(LIBRARY.modules) do
  local data, problem, check = Blueprint.module{
    name=entry.name,
    blueprint=LIBRARY.blueprints[entry.blueprint] or entry.blueprint,
    resource=entry.resource,
    product=entry.product,
  };
  if(data and #check.errors == 0) then
    local module = BaseModule:new(data);
    module.off = entry.off;
    listed[#listed + 1] = module;
    by_name[entry.name] = module;
    checks[entry.name] = check;
  else
    log("AIMod: module " .. tostring(entry.name) .. " left out of the library: " ..
      (problem or table.concat(check.errors, "; ")));
  end
end

-- the modules code and tests refer to by name
BurnerToFurnaceModule = by_name.BurnerToFurnace;
BurnerToFurnaceCopperModule = by_name.BurnerToFurnaceCopper;
BurnerToFurnaceStoneModule = by_name.BurnerToFurnaceStone;
BurnerToBurnerModule = by_name.BurnerToBurner;

function ModuleLibrary.get(name)
  return by_name[name];
end

-- Every listed module, the ones switched off too.
function ModuleLibrary.listed()
  return listed;
end

--[[
  What a module costs and gives, to compare variants (/aimod-modules, the
  "best" choice). Prices are the production score's (util/production_score.lua).
   - rates: {item = per minute}, BaseModule:productionRate
   - cost: {item = count} raw items its buildings are hand-crafted from
   - coal: coal a minute the bot has to bring (BaseModule:fuelUse)
   - refuel: buildings the bot fuels
   - buffer: minutes until the first output is full and the module stops
   - load: for smelting, what the drills feed over what the furnaces can
     smelt (1 = balanced)
   - score: (value made - value burnt) a minute / value it costs, i.e. how
     much of its cost it pays back a minute
   - warnings: Blueprint.module's, plus too many drills or furnaces
]]
local RAW_DEPTH = 8;
local function raw_cost(item, count, total, depth)
  local recipe = prototypes.recipe[item];
  local made = 0;
  for i, product in pairs(recipe and recipe.products or {}) do
    if(product.type == "item" and product.name == item) then
      made = product.amount or 1;
    end
  end
  if(depth > RAW_DEPTH or made == 0 or not recipe.has_category("crafting")) then
    total[item] = (total[item] or 0) + count;
    return;
  end
  for i, ingredient in pairs(recipe.ingredients) do
    if(ingredient.type == "item") then
      raw_cost(ingredient.name, ingredient.amount * count / made, total, depth + 1);
    end
  end
end

-- {item = count} raw items `count` x `item` are hand-crafted from: plates,
-- stone, wood, ... (an item with no hand-craft recipe is itself raw).
function ModuleLibrary.raw_cost(item, count)
  local total = {};
  raw_cost(item, count, total, 0);
  return total;
end

local reports = {};
function ModuleLibrary.report(module)
  if(reports[module.name]) then
    return reports[module.name];
  end
  local prices = ProductionScore.prices();
  local report = {rates={}, cost={}, buffer=math.huge, warnings={}};
  for i, warning in ipairs(checks[module.name] and checks[module.name].warnings or {}) do
    report.warnings[#report.warnings + 1] = warning;
  end
  local value = 0;
  local outlets = {};
  for i, output in ipairs(module.outputs) do
    outlets[output.type] = (outlets[output.type] or 0) + 1;
    if(not report.rates[output.type]) then
      report.rates[output.type] = module:productionRate(output.type) * 60;
      value = value + report.rates[output.type] * (prices[output.type] or 0);
    end
  end
  for i, output in ipairs(module.outputs) do
    local building = prototypes.entity[module.buildings[output.building].type];
    local stack = prototypes.item[output.type].stack_size;
    local room = stack - (output.keep or 0);
    if(building.type == "container") then
      room = building.get_inventory_size(defines.inventory.chest) * stack;
    end
    local per_output = report.rates[output.type] / outlets[output.type];
    if(per_output > 0) then
      report.buffer = math.min(report.buffer, room / per_output);
    end
  end
  for i, building in ipairs(module.buildings) do
    raw_cost(building.type, 1, report.cost, 0);
  end
  local cost = 0;
  for item, count in pairs(report.cost) do
    cost = cost + count * (prices[item] or 0);
  end
  report.coal = module:fuelUse("coal") * 60;
  report.refuel = 0;
  for i, input in ipairs(module.inputs) do
    if(input.ongoing ~= false) then report.refuel = report.refuel + 1; end
  end
  report.score = cost > 0 and (value - report.coal * (prices.coal or 0)) / cost or 0;
  report.cost_value = cost;
  report.load = module:smeltingLoad();
  if(report.load and report.load < 0.75) then
    report.warnings[#report.warnings + 1] = string.format("the furnaces stand idle %d%% of the time: fewer furnaces or more drills", math.floor((1 - report.load) * 100 + 0.5));
  elseif(report.load and report.load > 1.25) then
    report.warnings[#report.warnings + 1] = string.format("the drills mine %d%% more than the furnaces smelt: more furnaces or fewer drills", math.floor((report.load - 1) * 100 + 0.5));
  end
  reports[module.name] = report;
  return report;
end

-- The checks of a listed module: {errors=, warnings=, flows=}.
function ModuleLibrary.checks(name)
  return checks[name];
end

-- The modules the bot builds, best first: the player's choice (/aimod-use,
-- kept in storage.module_choice) if there is one - a list of names, or
-- "best": every listed module by ModuleLibrary.report's score -, else the
-- ones switched on in blueprints/library.lua, in its order.
function ModuleLibrary.all()
  local result = {};
  local choice = storage and storage.module_choice;
  if(choice == "best") then
    local order = {};
    for i, module in ipairs(listed) do
      result[i] = module;
      order[module] = i;
    end
    table.sort(result, function(a, b)
      local sa, sb = ModuleLibrary.report(a).score, ModuleLibrary.report(b).score;
      if(sa ~= sb) then return sa > sb; end
      return order[a] < order[b];
    end);
    return result;
  end
  if(choice) then
    for i, name in ipairs(choice) do
      result[#result + 1] = by_name[name];
    end
    return result;
  end
  for i, module in ipairs(listed) do
    if(not module.off) then
      result[#result + 1] = module;
    end
  end
  return result;
end

-- Makes the bot build the listed modules named in `names`, in that order,
-- switched off ones too; "best" ranks every listed module by its score; nil
-- goes back to blueprints/library.lua. Returns nil, or the first name that
-- isn't in the library.
function ModuleLibrary.choose(names)
  if(names == "best") then
    storage.module_choice = names;
    return nil;
  end
  for i, name in ipairs(names or {}) do
    if(not by_name[name]) then
      return name;
    end
  end
  storage.module_choice = names;
  return nil;
end

function ModuleLibrary.makes(module, item)
  for i, output in ipairs(module.outputs) do
    if(output.type == item) then
      return true;
    end
  end
  return false;
end

-- Modules with an output of `item`, best first.
function ModuleLibrary.producers(item)
  local result = {};
  for i, module in ipairs(ModuleLibrary.all()) do
    if(ModuleLibrary.makes(module, item)) then
      result[#result + 1] = module;
    end
  end
  return result;
end

-- How many of `item` building `module` takes beyond what the player carries:
-- buildings in the inventory (or the craft queue) count as built, then the
-- raw cost of the rest against the `item` in the inventory.
function ModuleLibrary.missingOwn(player, module, item)
  local wanted = {};
  for i, building in ipairs(module.buildings) do
    wanted[building.type] = (wanted[building.type] or 0) + 1;
  end
  local cost = {};
  for type, count in pairs(wanted) do
    local short = count - Inventories.count_with_queue(player, type);
    if(short > 0) then
      raw_cost(type, short, cost, 0);
    end
  end
  return math.max(0, (cost[item] or 0) - Inventories.total_craftable_count(player, item));
end

-- The first module making `item` that the player's bot hasn't given up on
-- (see BuildModuleTask:fail) and that isn't in `skip` ({name = true}), or nil.
-- With `needed` (items a minute a goal still lacks), unless the player chose
-- the modules by name: the cheapest module that makes that much on its own,
-- if one does - a goal of 10 iron plates a minute takes one drill and a
-- furnace, not the column of four the library lists first for growth; 0
-- (only the item is wanted, as by GatherResourceTask) takes the cheapest.
-- While no working module makes `item` yet, nothing could make what a
-- module built out of `item` still lacks of it (a belt line of 81 iron
-- plates making iron plates, with 8 in the inventory, waits forever): then
-- the first one the player can build with what it carries, else the one
-- lacking least.
function ModuleLibrary.producer(player, item, skip, needed)
  local failed = storage.failed_goals and storage.failed_goals[player.index] or {};
  local manager = storage.resource_managers and storage.resource_managers[player.index];
  local bootstrap = not (manager and manager:module_source(item, false));
  local fallback, fallback_missing = nil, math.huge;
  local candidates = ModuleLibrary.producers(item);
  local choice = storage.module_choice;
  if(needed and (choice == nil or choice == "best")) then
    local covering = {};
    for i, module in ipairs(candidates) do
      if((ModuleLibrary.report(module).rates[item] or 0) >= needed - 1e-6) then
        covering[#covering + 1] = module;
      end
    end
    table.sort(covering, function(a, b) return ModuleLibrary.report(a).cost_value < ModuleLibrary.report(b).cost_value; end);
    for i, module in ipairs(candidates) do
      if((ModuleLibrary.report(module).rates[item] or 0) < needed - 1e-6) then
        covering[#covering + 1] = module; -- then by score, as before
      end
    end
    candidates = covering;
  end
  for i, module in ipairs(candidates) do
    local given_up = skip and skip[module.name] or false;
    for j, name in ipairs(failed) do
      if(name == module.name) then
        given_up = true;
      end
    end
    if(not given_up) then
      local missing = bootstrap and ModuleLibrary.missingOwn(player, module, item) or 0;
      if(missing == 0) then
        return module;
      end
      if(missing < fallback_missing) then
        fallback, fallback_missing = module, missing;
      end
    end
  end
  return fallback;
end

-- Names of the modules a BuildModuleTask on `machine`'s stack is building,
-- and of every module making what one of them makes: building the pair of
-- drill and furnace for iron plates is no reason to start the column, which
-- needs more of the same plates.
function ModuleLibrary.being_built(machine)
  local names = {};
  local entry = machine and machine.goals;
  while(entry ~= nil) do
    if(getmetatable(entry.current) == BuildModuleTask) then
      local module = entry.current.module;
      names[module.name] = true;
      for i, output in ipairs(module.outputs) do
        for j, other in ipairs(listed) do
          if(ModuleLibrary.makes(other, output.type)) then
            names[other.name] = true;
          end
        end
      end
    end
    entry = entry.next;
  end
  return names;
end
