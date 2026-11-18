require 'resource_source';

require 'util/recipes'
require 'controllers/tasks/research_trigger_task'

--[[
  ResearchResourceSource
  For an item whose recipe is still locked: research the technology that
  unlocks it, when that takes research triggers only (no science packs).
  gather pushes a ResearchTriggerTask; once it is researched, the
  GatherResourceTask that asked finds the recipe as a CraftResourceSource.
   - player: LuaPlayer
]]
ResearchResourceSource = ResourceSource:new();

-- The technology, researchable by triggers now, that unlocks a recipe the
-- character can hand-craft `item` with, or nil. The first by name if
-- several do.
function ResearchResourceSource.technology_for(force, item)
  local names = {};
  for name, tech in pairs(force.technologies) do
    if(ResearchTriggerTask.researchable(tech)) then
      for i, effect in pairs(tech.prototype.effects or {}) do
        local recipe = effect.type == "unlock-recipe" and force.recipes[effect.recipe];
        if(recipe and Recipes.product_amount(recipe, item) > 0 and Recipes.is_handcraftable(recipe, true)) then
          names[#names + 1] = name;
          break;
        end
      end
    end
  end
  table.sort(names);
  return names[1];
end

function ResearchResourceSource:provides_type(type)
  return ResearchResourceSource.technology_for(self.player.force, type) ~= nil;
end

function ResearchResourceSource:is_valid()
  return true;
end

-- {type=type, qty=# wanted in inventory, player=player, machine=GoalMachine}
function ResearchResourceSource:gather(opts)
  local tech = ResearchResourceSource.technology_for(opts.player.force, opts.type);
  opts.machine:pushSingle(ResearchTriggerTask:new{tech=tech});
end
