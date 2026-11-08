require 'task'
require 'util'
require 'util/logger'
require 'util/inventories'

--[[
  GatherResourceTask
  Causes the player to do whatever they need to do to get a given resource in a
  particular quantity
   - type: string; The thing the player needs
   - qty: number; How many of the thing the player should have in the
          inventory when the task is done (a total, not an amount to add)
]]
GatherResourceTask = Task:new{goalSet=false}
local log = Logger.makeLogger("GatherResourceTask");
local RETRY_TICKS = 300;

function GatherResourceTask:achieved (args)
  return Inventories.total_craftable_count(args.player, self.type) >= self.qty;
end

function GatherResourceTask:toString()
  return "GatherResourceTask - " .. self.type .. " up to " .. self.qty;
end

function GatherResourceTask:tick (args)
  local player = args.player;
  -- nothing known provides this item: don't search again every tick
  if(self.retry_at and game.tick < self.retry_at) then
    return;
  end

  local found = storage.resource_managers[player.index]:get_resources(player, self.type, self.qty, args.machine);
  if(found) then
    self.retry_at = nil;
  else
    if(not self.retry_at) then
      log("No known way to get " .. self.type .. ", will keep looking", "WARN");
      player.print("AIMod: no known way to get " .. self.type);
    end
    self.retry_at = game.tick + RETRY_TICKS;
  end
end
