require 'task'
require 'util'
require 'util/logger'
require 'util/inventories'
require 'controllers/tasks/production_goal_task'
require 'controllers/tasks/fuel_building_task'
require 'controllers/tasks/collect_module_output_task'
require 'controllers/tasks/gatherResourcesTask'
require 'controllers/modules/library'

--[[
  GrowthTask
  The bot's last goal: when the goals before it are met it doesn't stop.
   - Upkeep first: the nearest module that is low on fuel gets refueled, or
     whose output is half full gets emptied. Burner modules stop within
     minutes otherwise, and more of them would make nothing.
   - Then one more module: coal when the modules would burn more than the
     coal modules make (with a margin), otherwise the product furthest behind
     its share in MIX. A ProductionGoalTask just above the current rate
     builds exactly one module.
  Achieved only once no module can be added any more (every producer given
  up on). The first time it runs, the goals before it count as done.
]]
GrowthTask = Task:new()
local log = Logger.makeLogger("GrowthTask");

-- share of each product, per minute
-- (no bricks: at the start of 2.1 nothing takes them, every recipe that
-- does - wall, steel furnace, concrete - waits behind lab research)
GrowthTask.MIX = {["iron-plate"] = 2, ["copper-plate"] = 1};
GrowthTask.FUEL = "coal";
local COAL_MARGIN = 1.25; -- coal made per coal burnt
local LOW_FUEL = 5;       -- refuel below this many (a burner drill burns 2.25 coal a minute)
local FUEL_AMOUNT = 20;   -- and top up to this many

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

-- Tasks that keep `module` going, or nil when it needs nothing.
local function upkeep(player, module)
  local refuel = {};
  local fuel_wanted = 0;
  for i, input in ipairs(module.inputs) do
    local entity = module:entity(input.building);
    local inventory = entity and input.slot == "fuel" and input.ongoing ~= false and entity.get_fuel_inventory();
    if(inventory and inventory.get_item_count(input.type) < LOW_FUEL) then
      refuel[#refuel + 1] = FuelBuildingTask:new{building=module.buildings[input.building], fuel=input.type, amount=FUEL_AMOUNT};
      fuel_wanted = fuel_wanted + FUEL_AMOUNT - inventory.get_item_count(input.type);
    end
  end
  if(#refuel > 0) then
    -- one trip for the fuel of the whole module
    local fuel = refuel[1].fuel;
    table.insert(refuel, 1, GatherResourceTask:new{type=fuel, qty=Inventories.total_craftable_count(player, fuel) + fuel_wanted});
    return refuel;
  end
  for i, output in ipairs(module.outputs) do
    local half = prototypes.item[output.type].stack_size / 2;
    for j, found in ipairs(module:outputsForProduct(output.type)) do
      if(found.available >= half) then
        local qty = Inventories.total_craftable_count(player, output.type) + found.available;
        return {CollectModuleOutputTask:new{module=module, type=output.type, qty=qty}};
      end
    end
  end
  return nil;
end

-- The upkeep tasks of the nearest module that needs any, or nil.
function GrowthTask.upkeep(player)
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

-- The product to build the next module for, or nil when no module can be added.
function GrowthTask.next_product(player)
  local fuel = GrowthTask.FUEL;
  local burnt = 0;
  for i, module in ipairs(modules(player)) do
    burnt = burnt + module:fuelUse(fuel) * 60;
  end
  if(ModuleLibrary.producer(player, fuel) and ProductionGoalTask.rate(player, fuel) < burnt * COAL_MARGIN) then
    return fuel;
  end
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

  local tasks = GrowthTask.upkeep(player);
  if(tasks) then
    args.machine:pushStart(tasks);
    return;
  end

  local item = GrowthTask.next_product(player);
  if(not item) then
    log("No module left to build, stopping", "INFO");
    self.stopped = true;
    return;
  end
  local rate = ProductionGoalTask.rate(player, item);
  log("Growing: one more module for " .. item .. " (" .. rate .. "/min now)", "INFO");
  args.machine:pushSingle(ProductionGoalTask:new{item=item, per_minute=rate + 1, growth=true});
end
