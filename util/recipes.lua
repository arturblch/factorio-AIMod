--[[
  Recipes: helpers for hand-crafting.

  The character can hand-craft recipes of the "crafting" category without
  fluids. When a recipe is queued with begin_crafting the game crafts the
  missing intermediates (gears, cables, ...) by itself, so the bot only has to
  make sure the raw, non-craftable items are in the inventory.
]]
Recipes = {};

local MAX_DEPTH = 8;

-- How many `item` one craft of `recipe` yields (0 if it doesn't).
function Recipes.product_amount(recipe, item)
  for i, product in pairs(recipe.products) do
    if(product.name == item and product.type == "item") then
      local amount = product.amount or ((product.amount_min + product.amount_max) / 2);
      return amount * (product.probability or 1);
    end
  end
  return 0;
end

function Recipes.is_handcraftable(recipe)
  if(not (recipe.enabled and recipe.has_category("crafting"))) then
    return false;
  end
  for i, ingredient in pairs(recipe.ingredients) do
    if(ingredient.type ~= "item") then
      return false;
    end
  end
  return true;
end

-- An enabled recipe the character can hand-craft that produces `item`, or nil.
function Recipes.handcraft_recipe_for(force, item)
  local recipe = force.recipes[item];
  if(recipe and Recipes.is_handcraftable(recipe) and Recipes.product_amount(recipe, item) > 0) then
    return recipe;
  end
  for name, candidate in pairs(force.recipes) do
    if(Recipes.is_handcraftable(candidate) and Recipes.product_amount(candidate, item) > 0) then
      return candidate;
    end
  end
  return nil;
end

--[[
  Raw items still missing to hand-craft `crafts` x `recipe` with what is in
  the player's main inventory. Intermediates are expanded recursively.
  Returns {item_name = missing_amount}.
]]
function Recipes.missing_raw(player, recipe, crafts)
  local inventory = player.get_main_inventory();
  local available = {};
  local missing = {};

  local function expand(current, count, depth)
    for i, ingredient in pairs(current.ingredients) do
      local name = ingredient.name;
      if(available[name] == nil) then
        available[name] = inventory.get_item_count(name);
      end
      local need = ingredient.amount * count;
      local used = math.min(available[name], need);
      available[name] = available[name] - used;
      need = need - used;
      if(need > 0) then
        local sub = depth < MAX_DEPTH and Recipes.handcraft_recipe_for(player.force, name);
        if(sub) then
          expand(sub, math.ceil(need / Recipes.product_amount(sub, name)), depth + 1);
        else
          missing[name] = (missing[name] or 0) + need;
        end
      end
    end
  end

  expand(recipe, crafts, 0);
  return missing;
end
