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
   - optional: boolean; (Optional) give up at once when nothing provides
               the item, instead of looking again every few seconds (for
               fetching things early, see WaitForOutputTask)
   - from_map: boolean; (Optional) only from the map (ore, trees, rocks),
               by hand, and give up at once when the map has none near: a
               WaitForOutputTask mining its own item meanwhile, which a
               module source would only send back to the wait
]]
GatherResourceTask = Task:new{goalSet=false}
local log = Logger.makeLogger("GatherResourceTask");
local RETRY_TICKS = 300;

function GatherResourceTask:achieved (args)
  return self.gave_up or Inventories.total_craftable_count(args.player, self.type) >= self.qty;
end

function GatherResourceTask:toString()
  return "GatherResourceTask - " .. self.type .. " up to " .. self.qty;
end

function GatherResourceTask:needs (args)
  return {[self.type] = self.qty};
end

function GatherResourceTask:tick (args)
  local player = args.player;
  -- nothing known provides this item: don't search again every tick
  if(self.retry_at and game.tick < self.retry_at) then
    return;
  end

  local manager = storage.resource_managers[player.index];
  if(self.from_map) then
    local natural = manager:find_natural_source(player, self.type);
    if(natural) then
      natural:gather{type=self.type, qty=self.qty, player=player, machine=args.machine};
      self.by_hand = true;
    else
      self.gave_up = true;
    end
    return;
  end
  local found, source = manager:get_resources(player, self.type, self.qty, args.machine, self.optional);
  if(found) then
    self.retry_at = nil;
    -- the bot's own hands: mined from the map or smelted by hand (Bottleneck counts that time)
    local kind = getmetatable(source);
    self.by_hand = kind == GroundResourceSource or kind == TreeResourceSource or kind == HandSmeltResourceSource;
  elseif(self.optional) then
    self.gave_up = true;
  else
    if(not self.retry_at) then
      log("No known way to get " .. self.type .. ", will keep looking", "WARN");
      player.print("AIMod: no known way to get " .. self.type);
    end
    self.retry_at = game.tick + RETRY_TICKS;
  end
end
