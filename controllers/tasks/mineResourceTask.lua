require 'task'
require 'util'
require 'util/inventories'
require 'controllers/tasks/moveToPointTask'

--[[
  MineResourceTask
  Mines an ore tile by hand until the inventory holds enough.
   - target: LuaEntity; the resource entity to mine
   - type: string; the item that mining it gives
   - qty: number; how many of `type` the inventory should hold when done
]]
MineResourceTask = Task:new()

function MineResourceTask:achieved (args)
  local player = args.player;
  -- a depleted tile ends the task; the gather task above will pick a new one
  local done = (not (self.target and self.target.valid))
    or Inventories.total_craftable_count(player, self.type) >= self.qty;
  if(done) then
    -- a mining_state set by script sticks until it is changed
    player.mining_state = {mining = false};
  end
  return done;
end

function MineResourceTask:toString()
  return "MineResourceTask - " .. tostring(self.type) .. " up to " .. tostring(self.qty);
end

function MineResourceTask:tick (args)
  local player = args.player;
  if(player.can_reach_entity(self.target)) then
    player.update_selected_entity(self.target.position)
    player.mining_state = { mining = true, position = self.target.position }
  else
    local position = self.target.position;
    args.machine:pushSingle(MoveToPointTask:new{x=position.x, y=position.y});
  end
end
