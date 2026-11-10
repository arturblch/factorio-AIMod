require 'task'
require 'util'
require 'util/logger'
require 'util/inventories'
require 'controllers/tasks/moveToPointTask'

--[[
  TakeFromChestTask
  Walks to a chest and takes items out of it.
   - entity: LuaEntity; the chest
   - type: string; the item to take
   - qty: number; how many the inventory should hold when done (a total)
]]
TakeFromChestTask = Task:new()
local log = Logger.makeLogger("TakeFromChestTask");

function TakeFromChestTask:achieved (args)
  return self.done or not self.entity.valid;
end

function TakeFromChestTask:toString()
  return "TakeFromChestTask - " .. self.type .. " up to " .. self.qty;
end

function TakeFromChestTask:needs (args)
  return {[self.type] = self.qty};
end

function TakeFromChestTask:tick (args)
  local player = args.player;
  local wanted = self.qty - Inventories.total_craftable_count(player, self.type);
  if(wanted <= 0) then
    self.done = true;
    return;
  end
  if(not player.can_reach_entity(self.entity)) then
    args.machine:pushSingle(MoveToPointTask.next_to(self.entity));
    return;
  end
  if(not Inventories.has_room_for(player, self.type)) then
    args.machine:pushSingle(MakeRoomTask:new{item=self.type});
    return;
  end
  local chest = self.entity.get_inventory(defines.inventory.chest);
  local count = math.min(chest.get_item_count(self.type), wanted);
  local inserted = count > 0 and player.insert{name=self.type, count=count} or 0;
  if(inserted > 0) then
    chest.remove{name=self.type, count=inserted};
  end
  log("Took " .. inserted .. " " .. self.type .. " from a chest", "INFO");
  -- whatever is still missing is the caller's (GatherResourceTask's) problem
  self.done = true;
end
