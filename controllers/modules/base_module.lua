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

-- Every building of the module stands.
function BaseModule:allPlaced()
  for i, building in ipairs(self.buildings) do
    if(not self:entity(i)) then
      return false;
    end
  end
  return true;
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

-- Production rates. Everything is derived from prototypes, so a module's rate
-- follows the game's numbers (a burner drill mines 0.25 ore/s, a stone
-- furnace smelts a plate in 3.2 s) and needs no tuning in the module data.

local function average_amount(product)
  local amount = product.amount or ((product.amount_min or 0) + (product.amount_max or 0)) / 2;
  return amount * (product.independent_probability or product.probability or 1);
end

-- Items per second a drill building mines and which item, or 0, nil when the
-- building is no drill.
local function drill_rate(module, building)
  local drill = prototypes.entity[building.type];
  local resource = prototypes.entity[building.resource or module.resource or ""];
  if(not (drill and drill.type == "mining-drill" and resource)) then
    return 0, nil;
  end
  local mineable = resource.mineable_properties;
  for i, product in pairs(mineable.products or {}) do
    if(product.type == "item") then
      return drill.mining_speed / mineable.mining_time * average_amount(product), product.name;
    end
  end
  return 0, nil;
end

-- Items of `item` per second a building burns as fuel at full work, or 0.
local function fuel_burn_rate(building, item)
  local prototype = prototypes.entity[building.type];
  local burner = prototype and prototype.burner_prototype;
  local fuel = prototypes.item[item];
  if(not (burner and fuel and fuel.fuel_value > 0)) then
    return 0;
  end
  for i, category in pairs(fuel.fuel_categories or {}) do
    if(burner.fuel_categories[category]) then
      -- energy usage is per tick
      return prototype.get_max_energy_usage() * 60 / (fuel.fuel_value * burner.effectivity);
    end
  end
  return 0;
end

-- The recipe a crafting machine uses to make `product` out of one of the
-- `inputs` ({item = true}): recipe, ingredient, ingredient amount, product
-- amount. Cached: prototypes don't change while the game runs.
local recipe_cache = {};
local function machine_recipe(machine, product, inputs)
  for name, recipe in pairs(prototypes.recipe) do
    local made = 0;
    for i, result in pairs(recipe.products) do
      if(result.type == "item" and result.name == product) then
        made = average_amount(result);
      end
    end
    local category_fits = false;
    for category in pairs(machine.crafting_categories or {}) do
      if(recipe.has_category(category)) then
        category_fits = true;
      end
    end
    if(made > 0 and category_fits and #recipe.ingredients == 1 and inputs[recipe.ingredients[1].name]) then
      local ingredient = recipe.ingredients[1];
      return recipe, ingredient.name, ingredient.amount, made;
    end
  end
  return nil;
end

-- Items of `product` per second the module makes when it runs without a
-- break (fueled, output emptied in time), net of what it burns itself; 0 if
-- it doesn't make it.
-- - "output" outputs: the machines' crafting speed, or what the drills feed
--   them, whichever is less (a burner drill can't keep a stone furnace busy).
-- - "fuel" outputs: what the drills mine, less what the module's own
--   burners take of it (BurnerToBurner feeds itself from its own coal).
function BaseModule:productionRate(product)
  local mined = {};
  for i, building in ipairs(self.buildings) do
    local rate, item = drill_rate(self, building);
    if(item) then
      mined[item] = (mined[item] or 0) + rate;
    end
  end

  local inputs = {};
  for item in pairs(mined) do
    inputs[#inputs + 1] = item;
  end
  table.sort(inputs);
  local capacity, feed, fuel_output = 0, 0, false;
  for i, output in ipairs(self.outputs) do
    if(output.type == product) then
      if(output.slot == "fuel") then
        fuel_output = true;
      else
        local machine = prototypes.entity[self.buildings[output.building].type];
        local key = machine.name .. "|" .. product .. "|" .. table.concat(inputs, ",");
        local cached = recipe_cache[key];
        if(not cached) then
          local recipe, ingredient, needed, made = machine_recipe(machine, product, mined);
          cached = recipe and {energy=recipe.energy, ingredient=ingredient, needed=needed, made=made} or {};
          recipe_cache[key] = cached;
        end
        if(cached.energy) then
          capacity = capacity + machine.get_crafting_speed() / cached.energy * cached.made;
          feed = (mined[cached.ingredient] or 0) / cached.needed * cached.made;
        end
      end
    end
  end
  if(capacity > 0) then
    return math.min(capacity, feed);
  end
  if(fuel_output) then
    local burnt = 0;
    for i, building in ipairs(self.buildings) do
      burnt = burnt + fuel_burn_rate(building, product);
    end
    return math.max((mined[product] or 0) - burnt, 0);
  end
  return 0;
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

-- Fuel for one round of fueling every fuel input, {fuel = amount}.
function BaseModule:fuelNeeds()
  local totals = {};
  for i, input in ipairs(self.inputs) do
    if(input.slot == "fuel") then
      totals[input.type] = (totals[input.type] or 0) + FUEL_AMOUNT;
    end
  end
  return totals;
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
