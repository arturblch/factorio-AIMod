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

function Unreachable.is(entity)
  return storage.unreachable ~= nil and entity.valid and storage.unreachable[key(entity)] ~= nil;
end
