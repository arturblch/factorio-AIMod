require 'task'
require 'util'

require 'controllers/tasks/moveToPointTask'
require 'util/unreachable'
require 'util/inventories'

-- Reach comes from the game (can_reach_entity), not from a constant.
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
    local y = self.entity.position.y + self.entity.prototype.collision_box.left_top.y;
    player.update_selected_entity({x=self.entity.position.x, y=y});
    player.mining_state = { mining = true, position = {x=self.entity.position.x, y=y} }
  else
    args.machine:pushSingle(MoveToPointTask:new{x=self.entity.position.x, y=self.entity.position.y, entity=self.entity, reach=true});
  end
end
