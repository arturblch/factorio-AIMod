require 'task'
require 'util'

require 'controllers/tasks/moveToPointTask'
require 'util/logger'
require 'util/unreachable'
require 'util/inventories'

-- Reach comes from the game (can_reach_entity), not from a constant.
MineEntityTask = Task:new()
local log = Logger.makeLogger("MineEntityTask");

-- The character mines whatever is selected. Selecting by position is
-- ambiguous: tree selection boxes are tall and overlap, and where two overlap
-- the game selects the tree in front, so a point on the target can select
-- (and fell) its neighbour. So the task assigns the entity itself as the
-- selection. One that still doesn't get selected is not mined, and after
-- this long counts as unreachable so the gather task picks another one.
local UNSELECTABLE_TICKS = 120;

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

-- The most of each item the entity can drop, as {name=, count=} items.
local function products_of(entity)
  local items = {};
  for i, product in pairs(entity.prototype.mineable_properties.products or {}) do
    if(product.type == "item") then
      items[#items + 1] = {name=product.name, count=product.amount or product.amount_max};
    end
  end
  return items;
end

-- MakeRoomTask is used as a global, see MineResourceTask:tick.
function MineEntityTask:tick (args)
  local player = args.player;
  local products = products_of(self.entity);
  if(not Inventories.has_room_for_all(player, products)) then
    player.mining_state = {mining = false};
    args.machine:pushSingle(MakeRoomTask:new{items=products});
    return;
  end
  local reachable = player.can_reach_entity(self.entity)
  if(reachable) then
    -- re-selected every tick: a moving mouse changes the selection
    if(player.selected ~= self.entity) then
      player.selected = self.entity;
    end
    if(player.selected == self.entity) then
      self.unselectable_since = nil;
      player.mining_state = { mining = true, position = self.entity.position }
    else
      player.mining_state = {mining = false};
      self.unselectable_since = self.unselectable_since or game.tick;
      if(game.tick - self.unselectable_since >= UNSELECTABLE_TICKS) then
        local p = self.entity.position;
        log("Can't select " .. self.entity.name .. " at " .. p.x .. ", " .. p.y .. " to mine it, trying another one", "INFO");
        Unreachable.mark(self.entity); -- achieved() ends the task
      end
    end
  else
    args.machine:pushSingle(MoveToPointTask:new{x=self.entity.position.x, y=self.entity.position.y, entity=self.entity, reach=true});
  end
end
