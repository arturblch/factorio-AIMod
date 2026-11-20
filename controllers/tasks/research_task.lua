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
  carries them into a lab that has power. Where an assembling machine of
  ours with power makes the pack (a science module, blueprints/library.lua:
  its inserter takes the packs into a lab), the bot carries the machine its
  ingredients instead, and the packs it will make count as in the labs.
  Done as soon as the labs hold (or will get) every pack the rest of the
  research takes, or it is researched, so the bot goes on with other things
  while the labs work; whoever pushed it looks again later (GrowthTask).
  Prerequisites come first: trigger ones with ResearchTriggerTask, the
  others with a ResearchTask of their own.
   - tech: string; the technology
]]
ResearchTask = Task:new()
local log = Logger.makeLogger("ResearchTask");

local BATCH = 10; -- packs crafted and carried in one go
local MACHINE_BATCH = 50; -- packs an assembling machine gets the ingredients for in one go

-- Our assembling machines on an electric network making `pack`, nearest
-- the player first. (On a network, not "has power": the status only
-- follows on the next tick. The bot wires them to its power module.)
function ResearchTask.assemblers(player, pack)
  local result = {};
  for i, machine in pairs(player.surface.find_entities_filtered{force=player.force, type="assembling-machine"}) do
    local recipe = machine.get_recipe();
    if(recipe and recipe.name == pack and machine.electric_network_id ~= nil) then
      result[#result + 1] = machine;
    end
  end
  table.sort(result, function(a, b)
    return util.distance(player.position, a.position) < util.distance(player.position, b.position);
  end);
  return result;
end

-- The packs `machine` holds or will make from what it holds: its output,
-- the craft under way and as many crafts as its ingredients allow.
function ResearchTask.in_machine(machine, pack)
  local recipe = machine.get_recipe();
  local made = 1;
  for i, product in pairs(recipe.products) do
    if(product.name == pack) then made = product.amount or 1; end
  end
  local input = machine.get_inventory(defines.inventory.crafter_input);
  local crafts = math.huge;
  for i, ingredient in pairs(recipe.ingredients) do
    crafts = math.min(crafts, math.floor(input.get_item_count(ingredient.name) / ingredient.amount));
  end
  if(crafts == math.huge) then crafts = 0; end
  if(machine.is_crafting()) then crafts = crafts + 1; end
  return machine.get_inventory(defines.inventory.crafter_output).get_item_count(pack) + crafts * made;
end

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

-- What the labs still lack for the rest of the research, counting what our
-- assembling machines will make for them: {pack = count}.
function ResearchTask.missing(player, tech)
  local labs = ResearchTask.labs(player);
  local result = {};
  for item, count in pairs(ResearchTask.packs_left(player.force, tech)) do
    local short = count - ResearchTask.in_labs(labs, item);
    for i, machine in ipairs(ResearchTask.assemblers(player, item)) do
      short = short - ResearchTask.in_machine(machine, item);
    end
    if(short > 0) then result[item] = short; end
  end
  return result;
end

-- {item = count} of ingredients for `packs` packs of `machine`'s recipe.
local function ingredients_for(machine, pack, packs)
  local recipe = machine.get_recipe();
  local made = 1;
  for i, product in pairs(recipe.products) do
    if(product.name == pack) then made = product.amount or 1; end
  end
  local crafts = math.ceil(packs / made);
  local result = {};
  for i, ingredient in pairs(recipe.ingredients) do
    result[ingredient.name] = ingredient.amount * crafts;
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

-- The packs it carries to the labs, or the ingredients it carries to an
-- assembling machine making them.
function ResearchTask:needs (args)
  if(self.failed) then return nil; end
  local missing = ResearchTask.missing(args.player, args.player.force.technologies[self.tech]);
  local result = {};
  for item, count in pairs(missing) do
    local machine = ResearchTask.assemblers(args.player, item)[1];
    if(machine) then
      for name, amount in pairs(ingredients_for(machine, item, math.min(count, MACHINE_BATCH))) do
        result[name] = math.max(result[name] or 0, amount);
      end
    else
      result[item] = math.min(count, BATCH);
    end
  end
  return result;
end

-- Carries `machine` the ingredients for `packs` more packs: gathers what is
-- missing first, then walks there and puts them in.
function ResearchTask:feed(args, machine, pack, packs)
  local player = args.player;
  local wanted = ingredients_for(machine, pack, packs);
  local names = {};
  for name in pairs(wanted) do names[#names + 1] = name; end
  table.sort(names); -- same order on every run
  for i, name in ipairs(names) do
    if(Inventories.total_craftable_count(player, name) < wanted[name]) then
      args.machine:pushSingle(GatherResourceTask:new{type=name, qty=wanted[name]});
      return;
    end
  end
  if(not player.can_reach_entity(machine)) then
    args.machine:pushSingle(MoveToPointTask.next_to(machine));
    return;
  end
  local input = machine.get_inventory(defines.inventory.crafter_input);
  for i, name in ipairs(names) do
    local inserted = input.insert{name=name, count=wanted[name]};
    if(inserted > 0) then
      player.get_main_inventory().remove{name=name, count=inserted};
    else
      self:fail(player, machine.name .. " takes no " .. name);
      return;
    end
    log("Put " .. inserted .. " " .. name .. " into " .. machine.name .. " for " .. self.tech, "INFO");
  end
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
  local machine = ResearchTask.assemblers(player, item)[1];
  if(machine) then
    self:feed(args, machine, item, math.min(short, MACHINE_BATCH));
    return;
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
