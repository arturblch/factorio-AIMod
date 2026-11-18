require 'task'
require 'util'
require 'util/logger'
require 'util/inventories'
require 'controllers/tasks/moveToPointTask'
require 'controllers/tasks/gatherResourcesTask'
require 'controllers/tasks/research_trigger_task'

--[[
  ResearchTask
  Researches a technology that costs science packs, in our labs: puts it in
  the force's research queue, hand-crafts the packs a batch at a time and
  carries them into a lab that has power. Done as soon as the labs hold
  every pack the rest of the research takes (or it is researched), so the
  bot goes on with other things while the lab works; whoever pushed it
  looks again later (GrowthTask). Prerequisites come first: trigger ones
  with ResearchTriggerTask, the others with a ResearchTask of their own.
   - tech: string; the technology
]]
ResearchTask = Task:new()
local log = Logger.makeLogger("ResearchTask");

local BATCH = 10; -- packs crafted and carried in one go

-- Our labs on the player's surface, those with power first.
function ResearchTask.labs(player)
  local labs = player.surface.find_entities_filtered{force=player.force, type="lab"};
  local powered = {};
  for i, lab in ipairs(labs) do
    if(lab.status ~= defines.entity_status.no_power) then
      powered[#powered + 1] = lab;
    end
  end
  for i, lab in ipairs(labs) do
    if(lab.status == defines.entity_status.no_power) then
      powered[#powered + 1] = lab;
    end
  end
  return powered;
end

-- {pack = count} the rest of `tech`'s research takes.
function ResearchTask.packs_left(force, tech)
  local progress = 0;
  if(force.current_research and force.current_research.name == tech.name) then
    progress = force.research_progress;
  else
    progress = tech.saved_progress or 0;
  end
  local units = math.ceil(tech.research_unit_count * (1 - progress) - 1e-9);
  local result = {};
  for i, ingredient in ipairs(tech.research_unit_ingredients) do
    result[ingredient.name] = units * ingredient.amount;
  end
  return result;
end

-- How many of `item` our labs hold.
function ResearchTask.in_labs(labs, item)
  local total = 0;
  for i, lab in ipairs(labs) do
    total = total + lab.get_inventory(defines.inventory.lab_input).get_item_count(item);
  end
  return total;
end

-- Whether `tech` is in the force's research queue (or being researched).
local function queued(force, tech)
  for i, t in ipairs(force.research_queue or {}) do
    if(t.name == tech.name) then return true; end
  end
  return force.current_research ~= nil and force.current_research.name == tech.name;
end

-- What the labs still lack for the rest of the research: {pack = count}.
function ResearchTask.missing(player, tech)
  local labs = ResearchTask.labs(player);
  local result = {};
  for item, count in pairs(ResearchTask.packs_left(player.force, tech)) do
    local short = count - ResearchTask.in_labs(labs, item);
    if(short > 0) then result[item] = short; end
  end
  return result;
end

function ResearchTask:achieved (args)
  local tech = args.player.force.technologies[self.tech];
  if(self.failed or tech.researched) then
    return true;
  end
  return queued(args.player.force, tech) and next(ResearchTask.missing(args.player, tech)) == nil;
end

function ResearchTask:toString()
  return "ResearchTask - " .. self.tech;
end

-- Gives up, and remembers it (storage.failed_goals, as "research <tech>") so
-- GrowthTask doesn't ask again every tick.
function ResearchTask:fail(player, reason)
  log("Can't research " .. self.tech .. ": " .. reason, "WARN");
  self.failed = true;
  storage.failed_goals = storage.failed_goals or {};
  local list = storage.failed_goals[player.index] or {};
  list[#list + 1] = "research " .. self.tech;
  storage.failed_goals[player.index] = list;
end

-- The packs it carries to the labs.
function ResearchTask:needs (args)
  if(self.failed) then return nil; end
  local missing = ResearchTask.missing(args.player, args.player.force.technologies[self.tech]);
  for item, count in pairs(missing) do
    missing[item] = math.min(count, BATCH);
  end
  return missing;
end

function ResearchTask:tick (args)
  local player = args.player;
  local force = player.force;
  local tech = force.technologies[self.tech];

  -- prerequisites first, in name order so runs repeat
  local names = {};
  for name, prerequisite in pairs(tech.prerequisites) do
    if(not prerequisite.researched) then names[#names + 1] = name; end
  end
  table.sort(names);
  if(#names > 0) then
    local prerequisite = tech.prerequisites[names[1]];
    if(ResearchTriggerTask.researchable(prerequisite)) then
      args.machine:pushSingle(ResearchTriggerTask:new{tech=names[1]});
    else
      args.machine:pushSingle(ResearchTask:new{tech=names[1]});
    end
    return;
  end

  if(not queued(force, tech)) then
    if(not force.add_research(tech)) then
      self:fail(player, "the game won't queue it");
      return;
    end
    log("Researching " .. self.tech, "INFO");
  end

  local labs = ResearchTask.labs(player);
  if(#labs == 0) then
    self:fail(player, "no lab");
    return;
  end
  local item, short = next(ResearchTask.missing(player, tech));
  if(not item) then
    return; -- achieved() takes it from here
  end
  local batch = math.min(short, BATCH);
  local have = Inventories.total_craftable_count(player, item);
  if(have < batch) then
    args.machine:pushSingle(GatherResourceTask:new{type=item, qty=batch});
    return;
  end
  local lab = labs[1];
  if(not player.can_reach_entity(lab)) then
    args.machine:pushSingle(MoveToPointTask.next_to(lab));
    return;
  end
  local inserted = lab.get_inventory(defines.inventory.lab_input).insert{name=item, count=math.min(have, short)};
  if(inserted > 0) then
    player.get_main_inventory().remove{name=item, count=inserted};
    log("Put " .. inserted .. " " .. item .. " into the lab for " .. self.tech, "INFO");
  else
    self:fail(player, "the lab takes no " .. item);
  end
end
