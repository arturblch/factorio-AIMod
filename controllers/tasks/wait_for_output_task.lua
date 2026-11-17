require 'task'
require 'util'
require 'util/logger'
require 'util/inventories'
require 'controllers/tasks/gatherResourcesTask'
require 'controllers/tasks/hand_smelt_task'

--[[
  WaitForOutputTask
  Waits until a module has produced enough. Gives up as soon as the module
  runs out of fuel or ore, so the task that asked can re-plan (refuel, or
  pick another source).

  Meanwhile it doesn't just stand there: what the tasks further down the
  stack will want and the map provides (coal, stone, wood, ore) is fetched
  now, one item at a time, instead of after the wait. When there is nothing
  left to fetch and the module needs a while yet, it smelts the product by
  hand (HandSmeltTask), once per wait: a burner drill can't keep a stone
  furnace busy, hand mining can. What the tasks below need stays in the
  inventory for them.
   - module: BaseModule
   - type: string; the product to wait for
   - qty: number; how many should be waiting in the module's outputs
   - total: number; (optional) how many the inventory should hold in the
            end; what gets into the inventory meanwhile (smelted by hand)
            shortens the wait. Without it there is no hand smelting.
]]
WaitForOutputTask = Task:new()
local log = Logger.makeLogger("WaitForOutputTask");

local SIDE_WORK_EVERY = 60; -- ticks between looks for something to do
-- Hand smelting takes a few seconds to get going (craft and place a furnace,
-- mine the first ore, smelt it); not worth it when the module is nearly done.
local MIN_SMELT_SECONDS = 10;

function WaitForOutputTask:achieved (args)
  local waiting = self.module:outputCount(self.type);
  if(waiting >= self.qty) then
    return true;
  end
  if(self.total and waiting + Inventories.total_craftable_count(args.player, self.type) >= self.total) then
    return true;
  end
  if(self.started and (self.module:isStarved() or not self.module:isOperational())) then
    log("Module stopped while waiting for " .. self.type, "INFO");
    return true;
  end
  return false;
end

-- Seconds until the module has made what is still missing, at its rate.
function WaitForOutputTask:secondsLeft(player)
  local rate = self.module:productionRate(self.type);
  local wanted = self.qty;
  if(self.total) then
    wanted = math.min(wanted, self.total - Inventories.total_craftable_count(player, self.type));
  end
  local missing = wanted - self.module:outputCount(self.type);
  if(missing <= 0) then
    return 0;
  end
  return rate > 0 and missing / rate or math.huge;
end

function WaitForOutputTask:toString()
  return "WaitForOutputTask - " .. self.qty .. " " .. self.type;
end

-- A GatherResourceTask for something the tasks below will want and the map
-- has, or else a HandSmeltTask for the product itself, or nil. Optional:
-- when the item can't be found it is skipped rather than waited for.
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
  if(self.total and not self.smelt_considered) then
    -- decided once, when there is nothing else to fetch any more
    self.smelt_considered = true;
    if(self:secondsLeft(player) >= MIN_SMELT_SECONDS and HandSmeltTask.possible(player, self.type, needs)) then
      return HandSmeltTask:new{item=self.type, qty=self.total, module=self.module, keep=needs};
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
    log("While waiting for " .. self.type .. ": " .. task:toString(), "INFO");
    args.machine:pushSingle(task);
  end
end
