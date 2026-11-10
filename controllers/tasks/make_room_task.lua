require 'task'
require 'util'
require 'util/logger'
require 'util/inventories'
require 'controllers/tasks/moveToPointTask'
require 'controllers/tasks/placeBuildingTask'
require 'controllers/tasks/craftRecipeTask'
require 'controllers/managers/chest_resource_source'

--[[
  MakeRoomTask
  Frees space in a full main inventory so that what is about to be mined,
  taken or crafted fits again.

  With a full inventory the character's mining bar keeps filling up but
  nothing is ever mined, and a hand-craft finishes but waits until its
  product has a slot, so those tasks push this one first. It merges stacks,
  then puts away the surplus: everything beyond what the tasks on the stack
  still need (GoalMachine:needs) and a round of fuel for the bot's modules.

  The surplus goes into a stash chest within STASH_DISTANCE. If there is none
  with space, a chest from the inventory is placed next to the player and
  becomes one; a chest is crafted first if need be, from wood if there is
  some (fetched from a tree nearby if need be) and only then from iron
  plates, which the bot usually still needs. Stash chests are resource
  sources, so what was put away is fetched again when some task wants it.

  Only when no chest can be had is surplus dropped on the ground, one stack
  at a time until there is room. A MakeRoomTask that runs inside another one
  (making room for that one's chest) never goes for a chest itself.
   - items: list of {name=, count=}; what has to fit all at once
   - item: string; shorthand for items = {{name=item, count=1}}
]]
MakeRoomTask = Task:new()
local log = Logger.makeLogger("MakeRoomTask");

local CHESTS = {"wooden-chest", "iron-chest"}; -- cheapest first
local STASH_DISTANCE = 32;
local WOOD_DISTANCE = 32; -- how far to go for wood for a wooden chest
local MAX_PLACE_ATTEMPTS = 3;
-- after giving up (everything is needed), don't try again before this, so
-- tasks that keep asking don't spin or flood the chat
local RETRY_TICKS = 600;

-- Ends from tick(), never just because there is room again: a chest placed
-- on the way still has to become a stash.
function MakeRoomTask:achieved (args)
  return self.done;
end

function MakeRoomTask:wanted()
  return self.items or {{name=self.item, count=1}};
end

function MakeRoomTask:toString()
  local names = {};
  for i, item in ipairs(self:wanted()) do names[i] = item.name end
  return "MakeRoomTask - for " .. table.concat(names, ", ");
end

-- What it makes room for must not be put away by a MakeRoomTask above it.
function MakeRoomTask:needs (args)
  local totals = {};
  for i, item in ipairs(self:wanted()) do
    totals[item.name] = Inventories.total_craftable_count(args.player, item.name) + item.count;
  end
  return totals;
end

local function manager(player)
  return storage.resource_managers[player.index];
end

-- How much of each item to keep: what the stack needs, a round of fuel for
-- every module, and all of what there must be room for.
function MakeRoomTask:keep(args)
  local keep = args.machine:needs(args);
  for i, source in ipairs(manager(args.player).sources) do
    if(source.module) then
      for name, amount in pairs(source.module:fuelNeeds()) do
        keep[name] = (keep[name] or 0) + amount;
      end
    end
  end
  for i, item in ipairs(self:wanted()) do
    keep[item.name] = math.huge;
  end
  return keep;
end

-- {name, count, quality} of everything beyond what to keep, biggest first.
function MakeRoomTask:surplus(args)
  local keep = self:keep(args);
  local result = {};
  for i, item in ipairs(args.player.get_main_inventory().get_contents()) do
    local excess = item.count - (keep[item.name] or 0);
    if(excess > 0) then
      result[#result + 1] = {name=item.name, count=excess, quality=item.quality};
      keep[item.name] = 0; -- the next quality of the same item is all surplus
    else
      keep[item.name] = -excess;
    end
  end
  table.sort(result, function(a, b) return a.count > b.count end);
  return result;
end

-- Whether another MakeRoomTask is further down the stack.
function MakeRoomTask:isNested(machine)
  local entry = machine:entryBelow(self);
  while(entry ~= nil) do
    if(getmetatable(entry.current) == MakeRoomTask) then
      return true;
    end
    entry = entry.next;
  end
  return false;
end

-- The nearest stash chest that takes some of the surplus, or nil.
function MakeRoomTask:nearestStash(player, surplus)
  local best, best_distance;
  for i, source in ipairs(manager(player).sources) do
    local inventory = getmetatable(source) == ChestResourceSource and source:inventory();
    if(inventory) then
      local distance = util.distance(player.position, source.entity.position);
      local fits = false;
      for j, item in ipairs(surplus) do
        if(inventory.can_insert{name=item.name, count=1, quality=item.quality}) then
          fits = true;
          break;
        end
      end
      if(fits and distance <= STASH_DISTANCE and (not best or distance < best_distance)) then
        best, best_distance = source.entity, distance;
      end
    end
  end
  return best;
end

-- A free tile near the player for a chest, off ore so it never covers any.
local function stash_spot(player, chest)
  local surface = player.surface;
  local px, py = math.floor(player.position.x), math.floor(player.position.y);
  for radius = 2, 6 do
    for dx = -radius, radius do
      for dy = -radius, radius do
        if(math.max(math.abs(dx), math.abs(dy)) == radius) then
          local position = {x=px + dx + 0.5, y=py + dy + 0.5};
          if(surface.count_entities_filtered{position=position, type="resource", limit=1} == 0 and
             surface.can_place_entity{name=chest, position=position, force=player.force}) then
            return position;
          end
        end
      end
    end
  end
  return nil;
end

function MakeRoomTask:putAway(player, chest, surplus)
  local inventory = player.get_main_inventory();
  local chest_inventory = chest.get_inventory(defines.inventory.chest);
  for i, item in ipairs(surplus) do
    local moved = chest_inventory.insert(item);
    if(moved > 0) then
      inventory.remove{name=item.name, count=moved, quality=item.quality};
      log("Put " .. moved .. " " .. item.name .. " into a chest", "INFO");
    end
  end
end

-- Drops surplus, a stack at a time from the most plentiful, until what is
-- wanted fits.
function MakeRoomTask:dropOnGround(player, surplus)
  local inventory = player.get_main_inventory();
  for i, item in ipairs(surplus) do
    local left = item.count;
    while(left > 0 and not Inventories.has_room_for_all(player, self:wanted())) do
      local count = math.min(left, prototypes.item[item.name].stack_size);
      local stack = {name=item.name, count=count, quality=item.quality};
      player.surface.spill_item_stack{position=player.position, stack=stack, drop_full_stack=true, allow_belts=false};
      inventory.remove(stack);
      left = left - count;
      log("No chest to put " .. count .. " " .. item.name .. " into, dropped it", "WARN");
    end
  end
end

function MakeRoomTask:giveUp(player, message)
  storage.room_failed_at = storage.room_failed_at or {};
  storage.room_failed_at[player.index] = game.tick;
  log(message, "WARN");
  player.print("AIMod: " .. message);
  self.done = true;
end

local function craftable(player, name)
  local recipe = player.force.recipes[name];
  return recipe and recipe.enabled and player.get_craftable_count(recipe) > 0;
end

-- Pushes the tasks that end with a chest in the inventory (or with wood for
-- one); false when there is no way to get a chest. Crafting makes room for
-- the chest itself first (see CraftRecipeTask).
function MakeRoomTask:getChest(args)
  local player = args.player;
  if(not self.crafting and craftable(player, "wooden-chest")) then
    self.crafting = true;
    args.machine:pushSingle(CraftRecipeTask:new{recipe="wooden-chest", qty=1});
    return true;
  end
  -- wood from a tree nearby, if it fits (a tree drops 4)
  local recipe = player.force.recipes["wooden-chest"];
  if(not self.fetched_wood and recipe and recipe.enabled and
     Inventories.has_room_for_all(player, {{name="wood", count=4}})) then
    local tree = manager(player):find_natural_source(player, "wood");
    if(tree and util.distance(player.position, tree.entity.position) <= WOOD_DISTANCE) then
      self.fetched_wood = true;
      args.machine:pushSingle(GatherResourceTask:new{
        type="wood", qty=Inventories.total_craftable_count(player, "wood") + 2});
      return true;
    end
  end
  if(not self.crafting and craftable(player, "iron-chest")) then
    self.crafting = true;
    args.machine:pushSingle(CraftRecipeTask:new{recipe="iron-chest", qty=1});
    return true;
  end
  return false;
end

function MakeRoomTask:tick (args)
  local player = args.player;
  local failed_at = storage.room_failed_at and storage.room_failed_at[player.index];
  if(failed_at and game.tick - failed_at < RETRY_TICKS) then
    self.done = true;
    return;
  end
  if(not self.merged) then
    self.merged = true;
    player.get_main_inventory().sort_and_merge();
    return;
  end

  -- a chest placed for us on an earlier tick becomes a stash, and gets the
  -- surplus right away even if placing it already freed a slot
  local just_placed = false;
  if(self.placing) then
    local entity = self.placing.entity;
    self.placing = nil;
    if(entity and entity.valid) then
      manager(player):register_source(ChestResourceSource:new{entity=entity});
      just_placed = true;
    end
  end
  local room = Inventories.has_room_for_all(player, self:wanted());
  if(room and not just_placed) then
    self.done = true;
    return;
  end

  local surplus = self:surplus(args);
  if(#surplus == 0) then
    if(room) then
      self.done = true;
    else
      self:giveUp(player, "the inventory is full of things that are still needed");
    end
    return;
  end

  local chest = self:nearestStash(player, surplus);
  if(chest) then
    if(not player.can_reach_entity(chest)) then
      args.machine:pushSingle(MoveToPointTask.next_to(chest));
      return;
    end
    -- if the chest fills up before there is room, the next tick finds another
    self:putAway(player, chest, surplus);
    return;
  end

  if(not self:isNested(args.machine)) then
    for i, name in ipairs(CHESTS) do
      if(Inventories.total_craftable_count(player, name) > 0) then
        local position = stash_spot(player, name);
        self.place_attempts = (self.place_attempts or 0) + 1;
        if(position and self.place_attempts <= MAX_PLACE_ATTEMPTS) then
          self.placing = {type=name};
          args.machine:pushSingle(PlaceBuildingTask:new{type=name, position=position, building=self.placing});
          return;
        end
      end
    end
    if(self:getChest(args)) then
      return;
    end
  end
  self:dropOnGround(player, surplus);
  self.done = true;
end
