require 'task'
require 'util'
require 'util/logger'
require 'util/inventories'
require 'controllers/tasks/gatherResourcesTask'

--[[
  WaitForOutputTask
  Waits until a module has produced enough. Gives up as soon as the module
  runs out of fuel or ore, so the task that asked can re-plan (refuel, or
  pick another source).

  Meanwhile it doesn't just stand there: what the tasks further down the
  stack will want and the map provides (coal, stone, wood, ore) is fetched
  now, one item at a time, instead of after the wait.
   - module: BaseModule
   - type: string; the product to wait for
   - qty: number; how many should be waiting in the module's outputs
]]
WaitForOutputTask = Task:new()
local log = Logger.makeLogger("WaitForOutputTask");

local SIDE_WORK_EVERY = 60; -- ticks between looks for something to do

function WaitForOutputTask:achieved (args)
  if(self.module:outputCount(self.type) >= self.qty) then
    return true;
  end
  if(self.started and (self.module:isStarved() or not self.module:isOperational())) then
    log("Module stopped while waiting for " .. self.type, "INFO");
    return true;
  end
  return false;
end

function WaitForOutputTask:toString()
  return "WaitForOutputTask - " .. self.qty .. " " .. self.type;
end

-- A GatherResourceTask for something the tasks below will want and the map
-- has, or nil. Optional: when the item can't be found it is skipped rather
-- than waited for.
function WaitForOutputTask:sideWork(args)
  local player = args.player;
  local needs = args.machine:needs(args, args.machine:entryBelow(self));
  local names = {};
  for name, total in pairs(needs) do
    if(name ~= self.type and Inventories.total_craftable_count(player, name) < total) then
      names[#names + 1] = name;
    end
  end
  table.sort(names); -- same choice on every run
  local manager = storage.resource_managers[player.index];
  for i, name in ipairs(names) do
    if(manager:find_natural_source(player, name)) then
      return GatherResourceTask:new{type=name, qty=needs[name], optional=true};
    end
  end
  return nil;
end

function WaitForOutputTask:tick (args)
  -- the very first check happens before freshly added fuel has been lit
  self.started = true;
  if(self.side_work_at and game.tick < self.side_work_at) then
    return;
  end
  self.side_work_at = game.tick + SIDE_WORK_EVERY;
  local task = self:sideWork(args);
  if(task) then
    log("While waiting for " .. self.type .. ": getting " .. task.type .. " up to " .. task.qty, "INFO");
    args.machine:pushSingle(task);
  end
end
