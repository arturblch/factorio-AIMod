local T = require 'tests/lib/testing'
local Lab = require 'tests/lib/lab'
require 'util/production_score'

local function price(name) return ProductionScore.prices()[name] end

-- A force of its own with empty statistics, so they hold only what a test puts there.
local function empty_force()
  local force = game.forces["aimod-score-test"] or game.create_force("aimod-score-test")
  for _, surface in pairs(game.surfaces) do
    force.get_item_production_statistics(surface).clear()
    force.get_fluid_production_statistics(surface).clear()
  end
  return force
end

T.describe("ProductionScore.prices", function()
  T.it("grow along the recipe chain", function()
    T.truthy(price("iron-ore") > 0, "ore has a price")
    T.truthy(price("iron-plate") > price("iron-ore"), "a plate is worth more than its ore")
    T.truthy(price("iron-gear-wheel") > 2 * price("iron-plate"), "a gear more than its 2 plates")
    T.truthy(price("stone-brick") > 2 * price("stone"), "a brick more than its 2 stone")
  end)

  T.it("are worked out once", function()
    T.eq(ProductionScore.prices(), ProductionScore.prices(), "same table")
  end)
end)

T.describe("ProductionScore.score", function()
  local force, items
  T.before_each(function()
    force = empty_force()
    items = force.get_item_production_statistics(Lab.surface())
  end)

  T.it("is 0 when nothing was made", function()
    T.eq(ProductionScore.score(force), 0, "score")
  end)

  T.it("counts what was made and never used", function()
    -- the game's own sum would skip these: it only counts what was also used up
    items.set_input_count("iron-plate", 10)
    T.eq(ProductionScore.score(force), math.floor(10 * price("iron-plate")), "10 plates")
  end)

  T.it("takes off what was used up", function()
    items.set_input_count("coal", 10)
    items.set_output_count("coal", 4)
    T.eq(ProductionScore.score(force), math.floor(6 * price("coal")), "6 coal left")
  end)

  T.it("adds up the surfaces", function()
    items.set_input_count("iron-plate", 10)
    force.get_item_production_statistics(game.surfaces.nauvis).set_input_count("iron-plate", 5)
    T.eq(ProductionScore.net_counts(force)["iron-plate"], 15, "plates")
  end)

  T.it("counts fluids", function()
    T.truthy(price("crude-oil") > 0, "crude oil has a price")
    force.get_fluid_production_statistics(Lab.surface()).set_input_count("crude-oil", 100)
    T.eq(ProductionScore.score(force), math.floor(100 * price("crude-oil")), "100 crude oil")
  end)
end)
