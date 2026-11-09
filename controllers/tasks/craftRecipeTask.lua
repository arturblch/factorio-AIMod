require 'task'
require 'util'
require 'util/logger'
require 'util/inventories'
require 'util/recipes'
require 'controllers/tasks/gatherResourcesTask'
--[[
  CraftRecipeTask
  Causes the player to craft the given recipe. Missing raw ingredients are
  gathered first; intermediates are left to the game's hand-craft queue.
   - recipe: string; The name of the recipe to craft
   - qty: number; How many times to craft the recipe
   - background: boolean; (Optional) done as soon as the crafts are queued:
                 the game crafts while the bot walks on, and whoever uses
                 the items waits for them (see PlaceBuildingTask). Without
                 it the bot stands still until the queue is empty.
]]
CraftRecipeTask = Task:new{goalSet=false}
local log = Logger.makeLogger("CraftRecipeTask");

function CraftRecipeTask:achieved (args)
  return self.started and (self.background or args.player.crafting_queue_size == 0);
end

function CraftRecipeTask:toString()
  return "CraftRecipeTask - " .. self.qty .. " x " .. self.recipe;
end

-- A product of `crafts` x `recipe` that won't fit into the inventory, or nil.
-- A finished hand-craft waits until its product has a slot, and the whole
-- queue stalls behind it. Queueing takes the ingredients out right away, so
-- the product also fits when an ingredient is used up completely.
local function product_without_room(player, recipe, crafts)
  for i, product in pairs(recipe.products) do
    if(product.type == "item" and not Inventories.has_room_for(player, product.name)) then
      local missing, used = Recipes.requirements(player, recipe, crafts);
      for name, amount in pairs(used) do
        if(amount >= Inventories.total_craftable_count(player, name)) then
          return nil;
        end
      end
      return product.name;
    end
  end
  return nil;
end

-- Before crafting starts: the ingredients, as totals (see Task:needs).
function CraftRecipeTask:needs (args)
  local recipe = args.player.force.recipes[self.recipe];
  if(self.started or not recipe) then
    return nil;
  end
  return Recipes.needed_totals(args.player, recipe, self.qty);
end

function CraftRecipeTask:tick (args)
  local player = args.player;
  if(self.started) then
    return;
  end

  local recipe = player.force.recipes[self.recipe]
  if((not recipe) or (not Recipes.is_handcraftable(recipe))) then
    if(not self.reported) then
      local reason;
      if(not recipe) then
        reason = "there is no such recipe";
      elseif(not recipe.enabled) then
        reason = "the recipe is not enabled (needs tech?)";
      else
        reason = "it can't be crafted by hand";
      end
      log("Unable to craft " .. self.recipe .. ", " .. reason, "ERROR");
      self.reported = true;
    end
    return
  end

  if(player.get_craftable_count(recipe) < self.qty) then
    local missing = Recipes.missing_raw(player, recipe, self.qty);
    local gathering = false;
    for name, amount in pairs(missing) do
      -- GatherResourceTask's qty is the total wanted in the inventory
      local target = Inventories.total_craftable_count(player, name) + amount;
      log("Need " .. amount .. " more " .. name .. " to craft " .. self.qty .. " " .. self.recipe, "INFO");
      args.machine:pushSingle(GatherResourceTask:new{type=name, qty=target});
      gathering = true;
    end
    if(not gathering and not self.reported) then
      log("Have everything for " .. self.recipe .. " but the game says it can't be crafted yet", "WARN");
      self.reported = true;
    end
    return;
  end

  local no_room = product_without_room(player, recipe, self.qty);
  if(no_room) then
    -- MakeRoomTask is a global here: it requires this file
    args.machine:pushSingle(MakeRoomTask:new{item=no_room});
    return;
  end

  local numEnqueued = player.begin_crafting{count=self.qty, recipe=recipe, silent=true}
  if(numEnqueued > 0) then
    log("Crafting " .. numEnqueued .. " " .. self.recipe, "INFO");
    self.started = true
  end
end
