--[[
  Unreachable: entities the bot failed to walk to (water, cliffs, ...).
  Remembered in storage so resource lookups pick something else instead of
  trying the same spot forever.
]]
Unreachable = {};

local function key(entity)
  return entity.name .. "@" .. entity.position.x .. "," .. entity.position.y;
end

function Unreachable.mark(entity)
  storage.unreachable = storage.unreachable or {};
  storage.unreachable[key(entity)] = game.tick;
end

-- `max_age` (ticks, optional): only a mark at most this old counts. For our
-- own buildings, which the bot may get to after all once it has got unstuck.
function Unreachable.is(entity, max_age)
  local marked = storage.unreachable ~= nil and entity.valid and storage.unreachable[key(entity)];
  if(not marked) then
    return false;
  end
  return max_age == nil or game.tick - marked <= max_age;
end

-- How long a building of ours counts as unreachable.
Unreachable.BUILDING_TICKS = 3600;
