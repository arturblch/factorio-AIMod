--[[
  Strategy (plan 2.8): the slow level of growth's planning, what it is
  aiming at, worked out from the game rather than written down:
   - Strategy.roadmap: the technologies to research with science packs, in
     order, for the technologies growth wants (GrowthTask.RESEARCH):
     prerequisites first, through the tree of the game;
   - Strategy.targets: what each final product should come to a minute: its
     share of GrowthTask.MIX, scaled up to the product furthest ahead of its
     share (the others should catch up), plus what the labs take of it for
     the research under way (the supply chain's research demand: packs
     through their recipes).
  The tactical level (util/economy.lua) takes the targets as the final
  products to develop and to keep in proportion.
]]
Strategy = {};

local function sorted_keys(map)
  local keys = {};
  for key in pairs(map or {}) do keys[#keys + 1] = key; end
  table.sort(keys);
  return keys;
end

-- The technologies to research with packs for `goals` (names), in order,
-- prerequisites first; researched ones and those that research triggers
-- unlock (ResearchTriggerTask's) are left out, but their prerequisites come in.
function Strategy.roadmap(force, goals)
  local order, seen = {}, {};
  local function visit(name)
    if(seen[name]) then return; end
    seen[name] = true;
    local tech = force.technologies[name];
    if(not tech or tech.researched) then return; end
    for i, prerequisite in ipairs(sorted_keys(tech.prerequisites)) do
      visit(prerequisite);
    end
    if(#tech.research_unit_ingredients > 0) then
      order[#order + 1] = name;
    end
  end
  for i, goal in ipairs(goals or {}) do visit(goal); end
  return order;
end

-- Targets a minute for the products of `shares` ({item = share}): `rates`
-- ({item = per minute} made now) set the scale - the product furthest ahead
-- of its share -, `research` ({item = per minute}) is added on top.
function Strategy.targets(shares, rates, research)
  local scale = 0;
  for item, share in pairs(shares) do
    scale = math.max(scale, (rates[item] or 0) / share);
  end
  if(scale <= 0) then scale = 1; end
  local targets = {};
  for item, share in pairs(shares) do
    targets[item] = share * scale + ((research or {})[item] or 0);
  end
  return targets;
end

return Strategy;
