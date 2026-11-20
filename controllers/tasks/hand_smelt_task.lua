require 'task'
require 'util'
require 'util/logger'
require 'util/inventories'
require 'util/recipes'
require 'controllers/tasks/moveToPointTask'
require 'controllers/tasks/gatherResourcesTask'
require 'controllers/tasks/build_building_task'

--[[
  HandSmeltTask
  Smelts hand-mined ore in a stone furnace of the bot's own, the way a player
  does before any drill runs: mine one ore, put it in, mine the next one while
  the furnace works, take the products out. Hand mining (0.5 ore/s) keeps a
  stone furnace (a plate per 3.2 s) busy, which a burner drill (0.25 ore/s)
  can't.

  The furnace is placed by the ore the first time and used again after that:
  one per ingredient, in storage.hand_furnaces[player index][ingredient].
  Fuel is put in one piece at a time (a coal lasts ~14 plates).
   - item: string; the product (iron-plate, copper-plate, stone-brick)
   - qty: number; how many the inventory should hold when done (a total)
   - module: BaseModule; (optional) a module the bot is waiting for: what
             waits in its outputs counts as well
   - keep: {name = count}; (optional) what the tasks below need: that much
           stone, fuel, furnaces and ore stays in the inventory
]]
HandSmeltTask = Task:new()
local log = Logger.makeLogger("HandSmeltTask");

HandSmeltTask.FURNACE = "stone-furnace";
local FUELS = {"coal", "wood"}; -- the first one the inventory has is used
local SPOT_RADIUS = 10; -- around the ore, where the furnace may go
local MAX_FURNACE_GATHERS = 3; -- tries to get the furnace or what it is made of

-- How the furnace makes `item` from something the map drops, or nil.
function HandSmeltTask.recipe(player, item)
  local recipe = Recipes.furnace_recipe(player.force, HandSmeltTask.FURNACE, item);
  if(recipe and ResourceManager.drops(recipe.ingredient)) then
    return recipe;
  end
  return nil;
end

-- The furnace for `ingredient`: the one remembered, else the one a task
-- had built (storage.hand_furnace_builds: its building table, whose entity
-- PlaceBuildingTask sets). The task that placed it may be gone by then:
-- done once the module it waited for made enough, before it looked at the
-- furnace again - and the next task put down a furnace of its own.
local function placed_furnace(player, ingredient)
  local furnaces = storage.hand_furnaces and storage.hand_furnaces[player.index];
  local furnace = furnaces and furnaces[ingredient];
  if(furnace and furnace.valid) then
    return furnace;
  end
  local builds = storage.hand_furnace_builds and storage.hand_furnace_builds[player.index];
  local built = builds and builds[ingredient] and builds[ingredient].entity;
  if(built and built.valid) then
    storage.hand_furnaces = storage.hand_furnaces or {};
    storage.hand_furnaces[player.index] = storage.hand_furnaces[player.index] or {};
    storage.hand_furnaces[player.index][ingredient] = built;
    builds[ingredient] = nil;
    return built;
  end
  return nil;
end

-- How many of `name` the inventory has beyond what `keep` holds back.
local function spare(player, keep, name, with_queue)
  local count = with_queue and Inventories.count_with_queue(player, name) or Inventories.total_craftable_count(player, name);
  return count - ((keep or {})[name] or 0);
end

local function spare_fuel(player, keep)
  for i, fuel in ipairs(FUELS) do
    if(spare(player, keep, fuel) > 0) then
      return fuel;
    end
  end
  return nil;
end

-- {name=, amount=} the furnace is crafted from
local function furnace_ingredients(player)
  local recipe = player.force.recipes[HandSmeltTask.FURNACE];
  return recipe and recipe.ingredients or {};
end

-- Whether the bot can smelt `item` by hand now: the map has the ore, there is
-- spare fuel in the inventory, and a furnace placed or carried, or what it is
-- made of in the inventory or on the map. `keep`: see HandSmeltTask.
function HandSmeltTask.possible(player, item, keep)
  local recipe = HandSmeltTask.recipe(player, item);
  if(not (recipe and spare_fuel(player, keep))) then
    return false;
  end
  local manager = storage.resource_managers[player.index];
  if(not manager:find_natural_source(player, recipe.ingredient)) then
    return false;
  end
  if(placed_furnace(player, recipe.ingredient) or spare(player, keep, HandSmeltTask.FURNACE, true) > 0) then
    return true;
  end
  for i, ingredient in pairs(furnace_ingredients(player)) do
    if(spare(player, keep, ingredient.name) < ingredient.amount and not manager:find_natural_source(player, ingredient.name)) then
      return false;
    end
  end
  return true;
end

-- What the inventory and the module's outputs hold.
function HandSmeltTask:count(player)
  local count = Inventories.total_craftable_count(player, self.item);
  if(self.module) then
    count = count + self.module:outputCount(self.item);
  end
  return count;
end

function HandSmeltTask:achieved (args)
  return self.failed or self:count(args.player) >= self.qty;
end

function HandSmeltTask:toString()
  return "HandSmeltTask - " .. self.item .. " up to " .. self.qty;
end

function HandSmeltTask:needs (args)
  if(self.failed) then
    return nil;
  end
  local needs = {[self.item] = self.qty};
  if(self.recipe_data) then
    needs[self.recipe_data.ingredient] = self.recipe_data.amount;
  end
  return needs;
end

function HandSmeltTask:fail(reason)
  log("Can't smelt " .. self.item .. " by hand: " .. reason, "INFO");
  self.failed = true;
end

-- Pushes the tasks that put a furnace next to the ore.
function HandSmeltTask:placeFurnace(args)
  local player = args.player;
  if(self.building) then
    -- the last attempt didn't leave a furnace there
    self:fail("couldn't place a " .. HandSmeltTask.FURNACE);
    return;
  end
  if(spare(player, self.keep, HandSmeltTask.FURNACE, true) < 1) then
    self.furnace_gathers = (self.furnace_gathers or 0) + 1;
    if(self.furnace_gathers > MAX_FURNACE_GATHERS) then
      self:fail("couldn't get a " .. HandSmeltTask.FURNACE);
      return;
    end
    -- what the furnace is made of comes on top of what the tasks below need,
    -- or the craft would take their stone
    local keep = self.keep or {};
    for i, ingredient in pairs(furnace_ingredients(player)) do
      if(spare(player, keep, ingredient.name) < ingredient.amount) then
        args.machine:pushSingle(GatherResourceTask:new{type=ingredient.name, qty=(keep[ingredient.name] or 0) + ingredient.amount, optional=true});
        return;
      end
    end
    args.machine:pushSingle(GatherResourceTask:new{type=HandSmeltTask.FURNACE, qty=(keep[HandSmeltTask.FURNACE] or 0) + 1});
    return;
  end
  local source = storage.resource_managers[player.index]:find_natural_source(player, self.recipe_data.ingredient);
  if(not source) then
    self:fail("no " .. self.recipe_data.ingredient .. " around");
    return;
  end
  -- a 2x2 building goes on tile corners
  local near = {x=math.floor(source.entity.position.x + 0.5), y=math.floor(source.entity.position.y + 0.5)};
  local spot = player.surface.find_non_colliding_position(HandSmeltTask.FURNACE, near, SPOT_RADIUS, 1);
  if(not spot) then
    self:fail("no free spot by the " .. self.recipe_data.ingredient);
    return;
  end
  log("Placing a " .. HandSmeltTask.FURNACE .. " for " .. self.item .. " at " .. spot.x .. ", " .. spot.y, "INFO");
  self.building = {type=HandSmeltTask.FURNACE};
  -- remembered at once, for whichever task comes next (see placed_furnace)
  storage.hand_furnace_builds = storage.hand_furnace_builds or {};
  storage.hand_furnace_builds[player.index] = storage.hand_furnace_builds[player.index] or {};
  storage.hand_furnace_builds[player.index][self.recipe_data.ingredient] = self.building;
  args.machine:pushSingle(BuildBuildingTask:new{type=HandSmeltTask.FURNACE, position=spot, building=self.building});
end

-- The furnace, once placed; remembered for the next HandSmeltTask.
function HandSmeltTask:furnace(player)
  local ingredient = self.recipe_data.ingredient;
  local entity = self.building and self.building.entity;
  if(entity and entity.valid) then
    storage.hand_furnaces = storage.hand_furnaces or {};
    storage.hand_furnaces[player.index] = storage.hand_furnaces[player.index] or {};
    storage.hand_furnaces[player.index][ingredient] = entity;
    self.building = nil;
    local builds = storage.hand_furnace_builds and storage.hand_furnace_builds[player.index];
    if(builds) then builds[ingredient] = nil; end
  end
  return placed_furnace(player, ingredient);
end

function HandSmeltTask:tick (args)
  local player = args.player;
  self.recipe_data = self.recipe_data or HandSmeltTask.recipe(player, self.item);
  local recipe = self.recipe_data;
  if(not recipe) then
    self:fail("no furnace recipe from something the map has");
    return;
  end
  local furnace = self:furnace(player);
  if(not furnace) then
    self:placeFurnace(args);
    return;
  end
  local in_reach = player.can_reach_entity(furnace);

  -- take out what is done
  local output = furnace.get_output_inventory();
  local done = output.get_item_count(self.item);
  if(done > 0) then
    if(not in_reach) then
      args.machine:pushSingle(MoveToPointTask.next_to(furnace));
    elseif(not Inventories.has_room_for(player, self.item)) then
      args.machine:pushSingle(MakeRoomTask:new{item=self.item}); -- a global, see MineResourceTask:tick
    else
      local taken = player.insert{name=self.item, count=done};
      if(taken > 0) then
        output.remove{name=self.item, count=taken};
      end
    end
    return;
  end

  -- what is still missing once the furnace has done what it holds
  local source = furnace.get_inventory(defines.inventory.crafter_input);
  local crafts = math.floor(source.get_item_count(recipe.ingredient) / recipe.amount) + (furnace.is_crafting() and 1 or 0);
  local missing = self.qty - self:count(player) - crafts * recipe.made;

  local fuel_inventory = furnace.get_fuel_inventory();
  if((crafts > 0 or missing > 0) and fuel_inventory.is_empty()) then
    local fuel = spare_fuel(player, self.keep);
    if(fuel) then
      if(not in_reach) then
        args.machine:pushSingle(MoveToPointTask.next_to(furnace));
      else
        fuel_inventory.insert{name=fuel, count=1};
        player.get_main_inventory().remove{name=fuel, count=1};
      end
      return;
    end
    -- an empty slot only means the last piece is burning now: go on with it
    if(furnace.burner.remaining_burning_fuel <= 0) then
      self:fail("no spare fuel");
      return;
    end
  end

  if(missing <= 0) then
    -- the furnace holds enough: wait by it
    if(not in_reach) then
      args.machine:pushSingle(MoveToPointTask.next_to(furnace));
    end
    return;
  end

  local ore = spare(player, self.keep, recipe.ingredient);
  if(ore >= recipe.amount) then
    if(not in_reach) then
      args.machine:pushSingle(MoveToPointTask.next_to(furnace));
      return;
    end
    local wanted = math.min(ore, math.ceil(missing / recipe.made) * recipe.amount);
    local inserted = source.insert{name=recipe.ingredient, count=wanted};
    if(inserted > 0) then
      player.get_main_inventory().remove{name=recipe.ingredient, count=inserted};
    end
    -- nothing went in: the input slot is full, the next tick takes products out
    return;
  end

  -- mine one craft's worth
  if(not storage.resource_managers[player.index]:find_natural_source(player, recipe.ingredient)) then
    self:fail("no " .. recipe.ingredient .. " left to mine");
    return;
  end
  local keep = self.keep and self.keep[recipe.ingredient] or 0;
  args.machine:pushSingle(GatherResourceTask:new{type=recipe.ingredient, qty=keep + recipe.amount});
end
