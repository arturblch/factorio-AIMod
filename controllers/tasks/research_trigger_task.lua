require 'task'
require 'util/logger'
require 'util/inventories'
require 'controllers/tasks/gatherResourcesTask'

--[[
  ResearchTriggerTask
  Researches a technology that is unlocked by doing something instead of by
  science packs (a research trigger). In 2.1 the tree starts with three:
  steam-power (make 50 iron plates), electronics (10 copper plates) and,
  after both, automation-science-pack (a lab). For a craft-item trigger the
  bot makes the item, a batch at a time, until the game marks the
  technology researched; prerequisites that are trigger technologies too
  come first.
   - tech: string; the technology
]]
ResearchTriggerTask = Task:new()
local log = Logger.makeLogger("ResearchTriggerTask");

-- made this many times what the trigger asks and still not researched: the
-- trigger counts something else, stop rather than make items forever
local GIVE_UP_FACTOR = 3;

-- The item a craft-item trigger asks for, how many, or nil.
function ResearchTriggerTask.trigger(tech)
  local trigger = tech.prototype.research_trigger;
  if(not (trigger and trigger.type == "craft-item")) then
    return nil;
  end
  local item = trigger.item;
  if(type(item) == "table") then
    item = item.name;
  end
  return item, trigger.count or 1;
end

-- Whether the force can get `tech` by triggers alone: it, and each of its
-- prerequisites not researched yet, has a craft-item trigger.
function ResearchTriggerTask.researchable(tech)
  if(not tech.enabled or tech.researched or not ResearchTriggerTask.trigger(tech)) then
    return false;
  end
  for name, prerequisite in pairs(tech.prerequisites) do
    if(not prerequisite.researched and not ResearchTriggerTask.researchable(prerequisite)) then
      return false;
    end
  end
  return true;
end

-- How many of `item` the force has made so far, over all surfaces.
function ResearchTriggerTask.made(force, item)
  local total = 0;
  for _, surface in pairs(game.surfaces) do
    total = total + force.get_item_production_statistics(surface).get_input_count(item);
  end
  return total;
end

function ResearchTriggerTask:achieved (args)
  return self.failed or args.player.force.technologies[self.tech].researched;
end

function ResearchTriggerTask:toString()
  return "ResearchTriggerTask - " .. self.tech;
end

function ResearchTriggerTask:fail(reason)
  log("Can't research " .. self.tech .. ": " .. reason, "WARN");
  self.failed = true;
end

function ResearchTriggerTask:tick (args)
  local player = args.player;
  local tech = player.force.technologies[self.tech];
  -- prerequisites first, in name order so runs repeat
  local names = {};
  for name, prerequisite in pairs(tech.prerequisites) do
    if(not prerequisite.researched) then
      names[#names + 1] = name;
    end
  end
  table.sort(names);
  if(#names > 0) then
    if(not ResearchTriggerTask.researchable(tech.prerequisites[names[1]])) then
      self:fail(names[1] .. " needs science packs");
      return;
    end
    args.machine:pushSingle(ResearchTriggerTask:new{tech=names[1]});
    return;
  end

  local item, count = ResearchTriggerTask.trigger(tech);
  if(not item) then
    self:fail("no craft-item trigger");
    return;
  end
  local made = ResearchTriggerTask.made(player.force, item);
  if(made >= count * GIVE_UP_FACTOR) then
    self:fail(made .. " " .. item .. " made, the trigger asks for " .. count);
    return;
  end
  local batch = math.max(count - made, 1);
  log("Researching " .. self.tech .. ": making " .. batch .. " more " .. item .. " (" .. made .. " of " .. count .. ")", "INFO");
  args.machine:pushSingle(GatherResourceTask:new{type=item, qty=Inventories.total_craftable_count(player, item) + batch});
end
