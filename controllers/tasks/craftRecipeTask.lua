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
]]
CraftRecipeTask = Task:new{goalSet=false}
local log = Logger.makeLogger("CraftRecipeTask");

function CraftRecipeTask:achieved (args)
  return self.started and args.player.crafting_queue_size == 0;
end

function CraftRecipeTask:toString()
  return "CraftRecipeTask - " .. self.qty .. " x " .. self.recipe;
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

  local numEnqueued = player.begin_crafting{count=self.qty, recipe=recipe, silent=true}
  if(numEnqueued > 0) then
    log("Crafting " .. numEnqueued .. " " .. self.recipe, "INFO");
    self.started = true
  end
end
