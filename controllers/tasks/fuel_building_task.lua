require 'task'
require 'util'
require 'util/logger'
require 'util/inventories'
require 'controllers/tasks/moveToPointTask'
require 'controllers/tasks/gatherResourcesTask'

--[[
  FuelBuildingTask
  Walks to a burner building and puts fuel from the inventory into it.
   - building: table; a module building definition, its `entity` is the
               building to fuel (resolved when the task runs)
   - fuel: string; the fuel item, gathered first when the inventory has none
   - amount: number; how much fuel to put in
]]
FuelBuildingTask = Task:new()
local log = Logger.makeLogger("FuelBuildingTask");

local function target(self)
  local entity = self.building and self.building.entity;
  if(entity and entity.valid) then
    return entity;
  end
  return nil;
end

function FuelBuildingTask:achieved (args)
  return self.done or target(self) == nil;
end

function FuelBuildingTask:toString()
  local entity = target(self);
  return "FuelBuildingTask - " .. self.amount .. " " .. self.fuel .. " into " ..
    (entity and (entity.name .. " (" .. entity.position.x .. ", " .. entity.position.y .. ")") or "?");
end

function FuelBuildingTask:needs (args)
  if(self.done) then
    return nil;
  end
  return {[self.fuel] = self.amount};
end

function FuelBuildingTask:tick (args)
  local player = args.player;
  local entity = target(self);
  local fuel_inventory = entity.get_fuel_inventory();
  if(not fuel_inventory) then
    log(entity.name .. " has no fuel slot", "ERROR");
    self.done = true;
    return;
  end
  local missing = self.amount - fuel_inventory.get_item_count(self.fuel);
  if(missing <= 0) then
    self.done = true;
    return;
  end

  local have = Inventories.total_craftable_count(player, self.fuel);
  if(have == 0) then
    args.machine:pushSingle(GatherResourceTask:new{type=self.fuel, qty=missing});
    return;
  end
  if(not player.can_reach_entity(entity)) then
    args.machine:pushSingle(MoveToPointTask.next_to(entity));
    return;
  end

  local inserted = fuel_inventory.insert{name=self.fuel, count=math.min(missing, have)};
  if(inserted > 0) then
    player.get_main_inventory().remove{name=self.fuel, count=inserted};
  end
  log("Put " .. inserted .. " " .. self.fuel .. " into " .. entity.name, "INFO");
  self.done = true;
end
