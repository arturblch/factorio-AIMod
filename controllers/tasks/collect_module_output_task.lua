require 'task'
require 'util'
require 'util/logger'
require 'util/inventories'
require 'controllers/tasks/moveToPointTask'

--[[
  CollectModuleOutputTask
  Takes a module's product into the inventory.
   - module: BaseModule
   - type: string; the product to collect
   - qty: number; how many the inventory should hold when done (a total)
]]
CollectModuleOutputTask = Task:new()
local log = Logger.makeLogger("CollectModuleOutputTask");

function CollectModuleOutputTask:achieved (args)
  return self.done;
end

function CollectModuleOutputTask:toString()
  return "CollectModuleOutputTask - " .. self.type .. " up to " .. self.qty;
end

function CollectModuleOutputTask:needs (args)
  return {[self.type] = self.qty};
end

function CollectModuleOutputTask:tick (args)
  local player = args.player;
  for i, output in ipairs(self.module:outputsForProduct(self.type)) do
    local wanted = self.qty - Inventories.total_craftable_count(player, self.type);
    if(wanted <= 0) then
      break;
    end
    if(output.available > 0) then
      if(not player.can_reach_entity(output.entity)) then
        args.machine:pushSingle(MoveToPointTask.next_to(output.entity));
        return;
      end
      if(not Inventories.has_room_for(player, self.type)) then
        args.machine:pushSingle(MakeRoomTask:new{item=self.type}); -- a global, see MineResourceTask:tick
        return;
      end
      local count = math.min(output.available, wanted);
      local inserted = player.insert{name=self.type, count=count};
      if(inserted > 0) then
        output.inventory.remove{name=self.type, count=inserted};
      end
      log("Collected " .. inserted .. " " .. self.type .. " from " .. output.entity.name, "INFO");
    end
  end
  -- whatever is still missing is the caller's (GatherResourceTask's) problem
  self.done = true;
end
