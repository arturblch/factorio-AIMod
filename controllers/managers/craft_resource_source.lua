require 'resource_source';

require 'util/logger'
require 'util/inventories'
require 'util/recipes'
require 'controllers/tasks/craftRecipeTask'

--must be constructed with player
CraftResourceSource = ResourceSource:new();

function CraftResourceSource:find_recipe(type)
  return Recipes.handcraft_recipe_for(self.player.force, type);
end

function CraftResourceSource:provides_type(type)
  return self:find_recipe(type) ~= nil;
end

function CraftResourceSource:is_valid()
  return true;
end

-- {type=type, qty=# wanted in inventory, player=player, machine=GoalMachine}
function CraftResourceSource:gather(opts)
  local recipe = self:find_recipe(opts.type);
  local have = Inventories.total_craftable_count(opts.player, opts.type);
  local crafts = math.ceil((opts.qty - have) / Recipes.product_amount(recipe, opts.type));
  opts.machine:pushSingle(CraftRecipeTask:new{recipe=recipe.name, qty=math.max(crafts, 1)});
end
