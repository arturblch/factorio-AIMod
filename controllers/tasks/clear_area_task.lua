require 'task'
require 'util'
require 'util/logger'
require 'util/unreachable'

require 'controllers/tasks/mine_entity_task'

--[[
  ClearAreaTask
  Mines the trees and rocks in an area (they block building placement).
   - area: BoundingBox
  Obstacles the bot can't get to are skipped; placing the building will then
  fail and report it.
]]
ClearAreaTask = Task:new()
local log = Logger.makeLogger("ClearAreaTask");

function ClearAreaTask:achieved (args)
  return (self.entity_list ~= nil and #self.entity_list == 0)
end

function ClearAreaTask:toString()
  return "ClearAreaTask";
end

function ClearAreaTask:tick (args)
  local player = args.player;
  self.entity_list = {};
  for i, entity in pairs(player.surface.find_entities_filtered{area=self.area, type={"tree", "simple-entity"}}) do
    if(Unreachable.is(entity)) then
      log("Skipping " .. entity.name .. " at " .. entity.position.x .. ", " .. entity.position.y .. ": can't get to it", "WARN");
    else
      self.entity_list[#self.entity_list + 1] = entity;
    end
  end
  table.sort(self.entity_list, function(a, b)
    return util.distance(player.position, a.position) < util.distance(player.position, b.position);
  end)
  if(#self.entity_list > 0) then
    args.machine:pushSingle(MineEntityTask:new{entity = self.entity_list[1]});
  end
end
