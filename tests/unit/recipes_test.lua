local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'

-- Real 2.1 base recipes: burner-mining-drill = 3 gears + 1 stone furnace +
-- 3 iron plates; gear = 2 plates; stone furnace = 5 stone.
local function recipe(name) return game.forces.player.recipes[name] end

local function fake_recipe(fields)
  local r = {
    enabled = true,
    ingredients = {},
    products = {},
    category = "crafting",
  }
  for k, v in pairs(fields) do r[k] = v end
  function r.has_category(category) return category == r.category end
  return r
end

T.describe("Recipes.product_amount", function()
  T.it("is 1 gear per gear craft", function()
    T.eq(Recipes.product_amount(recipe("iron-gear-wheel"), "iron-gear-wheel"), 1, "gears")
  end)
  T.it("is 2 cables per cable craft", function()
    T.eq(Recipes.product_amount(recipe("copper-cable"), "copper-cable"), 2, "cables")
  end)
  T.it("is 0 for something the recipe doesn't make", function()
    T.eq(Recipes.product_amount(recipe("iron-gear-wheel"), "stone"), 0, "stone")
  end)
  T.it("averages ranged and probabilistic products", function()
    local r = fake_recipe{ products = { { type = "item", name = "x", amount_min = 2, amount_max = 4, probability = 0.5 } } }
    T.eq(Recipes.product_amount(r, "x"), 1.5, "amount")
  end)
end)

T.describe("Recipes.is_handcraftable", function()
  T.it("accepts gears", function()
    T.truthy(Recipes.is_handcraftable(recipe("iron-gear-wheel")), "gears")
  end)
  T.it("rejects smelting", function()
    T.falsy(Recipes.is_handcraftable(recipe("iron-plate")), "iron plate")
  end)
  T.it("rejects disabled recipes", function()
    T.falsy(Recipes.is_handcraftable(fake_recipe{ enabled = false }), "disabled")
  end)
  T.it("rejects fluid ingredients", function()
    local r = fake_recipe{ ingredients = { { type = "fluid", name = "water", amount = 10 } } }
    T.falsy(Recipes.is_handcraftable(r), "fluid")
  end)
end)

T.describe("Recipes.handcraft_recipe_for", function()
  T.it("finds the furnace recipe", function()
    T.eq(Recipes.handcraft_recipe_for(game.forces.player, "stone-furnace").name, "stone-furnace", "recipe")
  end)
  T.it("finds nothing for iron plates (they are smelted)", function()
    T.eq(Recipes.handcraft_recipe_for(game.forces.player, "iron-plate"), nil, "recipe")
  end)
end)

T.describe("Recipes.missing_raw", function()
  local function missing(items, name, crafts)
    return Recipes.missing_raw(Fakes.player{ items = items }, recipe(name), crafts)
  end

  T.it("expands two drills from the starting 8 plates", function()
    -- 2 drills = 6 gears (12 plates) + 2 furnaces (10 stone) + 6 plates
    T.same(missing({ ["iron-plate"] = 8 }, "burner-mining-drill", 2), { ["iron-plate"] = 10, stone = 10 }, "missing")
  end)
  T.it("is empty when every ingredient is there", function()
    local items = { ["iron-gear-wheel"] = 6, ["stone-furnace"] = 2, ["iron-plate"] = 6 }
    T.same(missing(items, "burner-mining-drill", 2), {}, "missing")
  end)
  T.it("uses intermediates before expanding them", function()
    -- 1 gear in stock, 2 more from 4 plates, + 3 plates; furnace from 5 stone
    T.same(missing({ ["iron-gear-wheel"] = 1 }, "burner-mining-drill", 1), { ["iron-plate"] = 7, stone = 5 }, "missing")
  end)
  T.it("doesn't count the same plates twice", function()
    -- 3 plates in stock cover the drill's own plates, gears need 6 more
    T.same(missing({ ["iron-plate"] = 3, ["stone-furnace"] = 1 }, "burner-mining-drill", 1), { ["iron-plate"] = 6 }, "missing")
  end)
end)
