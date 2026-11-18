require 'task'
require 'util/logger'
require 'controllers/tasks/build_module_task'
require 'controllers/modules/library'

--[[
  ProductionGoalTask
  A goal stated as a product: make at least `per_minute` of `item`. Done once
  the bot's working modules make that much (BaseModule:productionRate);
  until then it builds the first module from ModuleLibrary that makes the
  item, then looks again, so a goal larger than one module builds several.
   - item: string; what to make
   - per_minute: number; how much
   - growth: boolean; (optional) set by GrowthTask: with /aimod-use best the
     module with the best score, not the cheapest that covers the goal
]]
ProductionGoalTask = Task:new()
local log = Logger.makeLogger("ProductionGoalTask");

local EPSILON = 1e-6;

-- Items per minute the player's working modules make of `item`.
function ProductionGoalTask.rate(player, item)
  local manager = storage.resource_managers and storage.resource_managers[player.index];
  local total = 0;
  for i, source in ipairs(manager and manager.sources or {}) do
    if(source.module and source:is_valid()) then
      total = total + source.module:productionRate(item) * 60;
    end
  end
  return total;
end

function ProductionGoalTask:achieved(args)
  return self.failed or ProductionGoalTask.rate(args.player, self.item) >= self.per_minute - EPSILON;
end

function ProductionGoalTask:toString()
  return "ProductionGoalTask - " .. self.item .. " " .. self.per_minute .. "/min";
end

function ProductionGoalTask:fail(player, message)
  log(message, "WARN");
  player.print("AIMod: " .. message);
  storage.failed_goals = storage.failed_goals or {};
  local list = storage.failed_goals[player.index] or {};
  list[#list + 1] = self.item .. " " .. self.per_minute .. "/min";
  storage.failed_goals[player.index] = list;
  self.failed = true;
end

-- What building the next module takes, so that tasks above (fetching things
-- while a module works, making room in the inventory) plan for it before
-- this goal's turn comes.
function ProductionGoalTask:needs(args)
  if(self.failed or self.building or self:achieved(args)) then
    return nil;
  end
  local module = ModuleLibrary.producer(args.player, self.item, nil, self:shortfall(args.player));
  return module and BuildModuleTask:new{module=module}:needs(args) or nil;
end

-- Items a minute still missing, for ModuleLibrary.producer; nil for growth.
function ProductionGoalTask:shortfall(player)
  if(self.growth) then
    return nil;
  end
  return self.per_minute - ProductionGoalTask.rate(player, self.item);
end

function ProductionGoalTask:tick(args)
  local player = args.player;
  local rate = ProductionGoalTask.rate(player, self.item);
  if(self.building) then
    -- the module asked for last time is built (or was given up on)
    local built = not self.building.failed;
    self.building = nil;
    if(built and rate <= (self.rate_before or 0) + EPSILON) then
      self:fail(player, "a new module made no more " .. self.item .. ", stopping at " ..
        string.format("%.1f", rate) .. " of " .. self.per_minute .. "/min");
      return;
    end
  end
  local module = ModuleLibrary.producer(player, self.item, nil, self.per_minute - rate > EPSILON and not self.growth and self.per_minute - rate or nil);
  if(not module) then
    self:fail(player, "no module to make " .. self.item .. " (" .. string.format("%.1f", rate) ..
      " of " .. self.per_minute .. "/min)");
    return;
  end
  log(self.item .. ": " .. string.format("%.1f", rate) .. " of " .. self.per_minute .. "/min, building " ..
    module.name, "INFO");
  self.rate_before = rate;
  self.building = BuildModuleTask:new{module=module};
  args.machine:pushSingle(self.building);
end
