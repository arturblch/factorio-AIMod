require 'util'
require 'controllers/tasks/fuel_building_task'
require 'controllers/tasks/wait_for_output_task'
require 'controllers/tasks/gatherResourcesTask'

--[[
  BaseModule: a small fixed layout of buildings (see burner_to_furnace.lua).
   - buildings[i].entity is set by PlaceBuildingTask once the building stands
   - inputs: {building=i, type="coal", slot="fuel"} - fuel the bot keeps topped up
   - outputs: {building=i, type="iron-plate", slot="output"|"fuel", keep=n}
       slot "output" (default) is the building's result inventory; slot
       "fuel" takes surplus fuel, leaving `keep` items behind
]]
BaseModule = {}

local LOW_FUEL = 2; -- refuel when fewer items than this are left
local FUEL_AMOUNT = 5;

function BaseModule:new(o)
  o = o or {};
  setmetatable(o, self);
  self.__index = self;
  return o;
end

-- A private copy of a module definition, so every built module (and every
-- player) keeps its own building -> entity links.
function BaseModule:instantiate()
  return util.table.deepcopy(self);
end

function BaseModule:entity(index)
  local building = self.buildings[index];
  local entity = building and building.entity;
  if(entity and entity.valid) then
    return entity;
  end
  return nil;
end

-- All buildings stand and none of them ran out of ore to mine.
function BaseModule:isOperational()
  for i, building in ipairs(self.buildings) do
    local entity = self:entity(i);
    if(not entity) then
      return false;
    end
    if(entity.status == defines.entity_status.no_minable_resources) then
      return false;
    end
  end
  return true;
end

local function output_inventory(entity, output)
  if(output.slot == "fuel") then
    return entity.get_fuel_inventory();
  end
  return entity.get_output_inventory();
end

-- {entity=, inventory=, available=} for every output that gives `product`
function BaseModule:outputsForProduct(product)
  local result = {};
  for i, output in ipairs(self.outputs) do
    local entity = self:entity(output.building);
    if(output.type == product and entity) then
      local inventory = output_inventory(entity, output);
      if(inventory) then
        local available = inventory.get_item_count(product) - (output.keep or 0);
        result[#result + 1] = {entity=entity, inventory=inventory, available=math.max(available, 0)};
      end
    end
  end
  return result;
end

function BaseModule:outputCount(product)
  local total = 0;
  for i, output in ipairs(self:outputsForProduct(product)) do
    total = total + output.available;
  end
  return total;
end

function BaseModule:hasOutputAvailable(product)
  return self:outputCount(product) > 0;
end

-- A fuel input that has burnt out: nothing in the slot, nothing burning.
function BaseModule:isStarved()
  for i, input in ipairs(self.inputs) do
    local entity = self:entity(input.building);
    local burner = entity and entity.burner;
    if(input.slot == "fuel" and burner and burner.inventory.is_empty() and burner.remaining_burning_fuel <= 0) then
      return true;
    end
  end
  return false;
end

-- Prefix fuel tasks with one GatherResourceTask per fuel type, so the bot
-- fetches fuel for the whole module in one trip instead of one per building.
local function gather_fuel_first(fuel_tasks)
  local totals = {};
  for i, task in ipairs(fuel_tasks) do
    totals[task.fuel] = (totals[task.fuel] or 0) + task.amount;
  end
  local tasks = {};
  for fuel, amount in pairs(totals) do
    tasks[#tasks + 1] = GatherResourceTask:new{type=fuel, qty=amount};
  end
  for i, task in ipairs(fuel_tasks) do
    tasks[#tasks + 1] = task;
  end
  return tasks;
end

-- FuelBuildingTasks for every fuel input that is running low.
function BaseModule:fuelTasks()
  local tasks = {};
  for i, input in ipairs(self.inputs) do
    local entity = self:entity(input.building);
    if(input.slot == "fuel" and entity) then
      local fuel = entity.get_fuel_inventory();
      if(fuel and fuel.get_item_count() < LOW_FUEL) then
        tasks[#tasks + 1] = FuelBuildingTask:new{building=self.buildings[input.building], fuel=input.type, amount=FUEL_AMOUNT};
      end
    end
  end
  return gather_fuel_first(tasks);
end

-- Fuel every fuel input once, right after the module is built. The buildings
-- don't exist yet when these tasks are created; FuelBuildingTask resolves
-- the entity when it runs.
function BaseModule:startTasks()
  local tasks = {};
  for i, input in ipairs(self.inputs) do
    if(input.slot == "fuel") then
      tasks[#tasks + 1] = FuelBuildingTask:new{building=self.buildings[input.building], fuel=input.type, amount=FUEL_AMOUNT};
    end
  end
  return gather_fuel_first(tasks);
end

-- Tasks that end with at least `qty` of `product` waiting in the outputs
-- (or with the module out of fuel, so the caller can re-plan).
function BaseModule:generateTasksForOutput(product, qty)
  local tasks = self:fuelTasks();
  if(self:outputCount(product) < qty) then
    tasks[#tasks + 1] = WaitForOutputTask:new{module=self, type=product, qty=qty};
  end
  return tasks;
end
