--[[
  ProductionScore: what a force has made so far, as one number. Every item and
  fluid it produced, minus what it used up, at a price derived from recipes:
  raw resources are cheap, each recipe step adds the value of its ingredients
  and a little for the crafting time.

  The prices come from the game's own core/lualib/production-score.lua (the
  PvP scenario's score; the Factorio Learning Environment uses a copy of it).
  Its own sum isn't used: it only counts items that were also used up
  somewhere, so plates piling up in a furnace would be worth nothing.

  Not used by the bot yet; scenario runs print it with run-headless.ps1 -Score.
]]
local GameScore = require 'production-score'

ProductionScore = {}

-- derived from prototypes only, so it is safe to keep outside of storage
local price_list;

-- item or fluid name -> price
function ProductionScore.prices()
  price_list = price_list or GameScore.generate_price_list();
  return price_list;
end

local function add_net(sum, statistics)
  for name, count in pairs(statistics.input_counts) do
    sum[name] = (sum[name] or 0) + count;
  end
  for name, count in pairs(statistics.output_counts) do
    sum[name] = (sum[name] or 0) - count;
  end
end

-- name -> produced minus used up, over all surfaces: items, fluids
function ProductionScore.net_counts(force)
  local items, fluids = {}, {};
  for _, surface in pairs(game.surfaces) do
    add_net(items, force.get_item_production_statistics(surface));
    add_net(fluids, force.get_fluid_production_statistics(surface));
  end
  return items, fluids;
end

function ProductionScore.score(force)
  local prices = ProductionScore.prices();
  local score = 0;
  for _, counts in pairs({ProductionScore.net_counts(force)}) do
    for name, count in pairs(counts) do
      score = score + (prices[name] or 0) * count;
    end
  end
  return math.floor(score);
end

return ProductionScore;
