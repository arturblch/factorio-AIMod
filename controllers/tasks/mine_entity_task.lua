require 'task'
require 'util'

require 'controllers/tasks/moveToPointTask'
require 'util/unreachable'

local range = 4; -- Approx player reach range
MineEntityTask = Task:new()

function MineEntityTask:achieved (args)
  -- gone, or the way to it is blocked (the gather task will pick another one)
  local done = (not self.entity.valid) or Unreachable.is(self.entity);
  if(done) then
    -- a mining_state set by script sticks until it is changed
    args.player.mining_state = {mining = false};
  end
  return done;
end

function MineEntityTask:toString()
  if(not self.entity.valid) then
    return "MineEntityTask - <gone>";
  end
  return "MineEntityTask - " .. self.entity.name .. " (" .. self.entity.position.x .. ", " .. self.entity.position.y .. ")";
end

function MineEntityTask:tick (args)
  local player = args.player;
  local reachable = player.can_reach_entity(self.entity)
  if(reachable) then
    local y = self.entity.position.y + self.entity.prototype.collision_box.left_top.y;
    player.update_selected_entity({x=self.entity.position.x, y=y});
    player.mining_state = { mining = true, position = {x=self.entity.position.x, y=y} }
  else
    args.machine:pushSingle(MoveToPointTask:new{x=self.entity.position.x, y=self.entity.position.y, entity=self.entity, reach=true});
  end
end
