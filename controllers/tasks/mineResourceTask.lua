require 'task'
require 'util'
require 'util/logger'
require 'util/inventories'
require 'util/unreachable'
require 'controllers/tasks/moveToPointTask'

--[[
  MineResourceTask
  Mines an ore tile by hand until the inventory holds enough.
   - target: LuaEntity; the resource entity to mine
   - type: string; the item that mining it gives
   - qty: number; how many of `type` the inventory should hold when done
]]
MineResourceTask = Task:new()
local log = Logger.makeLogger("MineResourceTask");

-- The character mines what is selected. Standing next to a tile rather than
-- on it (a tree in the way), the tile may not get selected at all, or a tree
-- over it gets selected instead. Then nothing is mined (rather than the
-- tree), and after this long the tile counts as unreachable and the gather
-- task above picks another one.
local UNSELECTABLE_TICKS = 120;

function MineResourceTask:achieved (args)
  local player = args.player;
  -- a depleted or unreachable tile ends the task; the gather task above
  -- will pick a new one
  local done = (not (self.target and self.target.valid))
    or Unreachable.is(self.target)
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

function MineResourceTask:needs (args)
  return {[self.type] = self.qty};
end

-- MakeRoomTask is used as a global, not required: it requires this file's
-- requirers (resource sources), and require can't go round in a circle.
function MineResourceTask:tick (args)
  local player = args.player;
  if(not Inventories.has_room_for(player, self.type)) then
    player.mining_state = {mining = false};
    args.machine:pushSingle(MakeRoomTask:new{item=self.type});
    return;
  end
  if(player.can_reach_entity(self.target)) then
    player.update_selected_entity(self.target.position)
    if(player.selected == self.target) then
      self.unselectable_since = nil;
      player.mining_state = { mining = true, position = self.target.position }
    else
      player.mining_state = {mining = false};
      self.unselectable_since = self.unselectable_since or game.tick;
      if(game.tick - self.unselectable_since >= UNSELECTABLE_TICKS) then
        local p = self.target.position;
        log("Can't select " .. self.target.name .. " at " .. p.x .. ", " .. p.y .. " to mine it, trying another one", "INFO");
        Unreachable.mark(self.target); -- achieved() ends the task
      end
    end
  else
    local position = self.target.position;
    args.machine:pushSingle(MoveToPointTask:new{x=position.x, y=position.y, entity=self.target});
  end
end
