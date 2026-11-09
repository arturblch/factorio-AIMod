require 'resource_source';

require 'controllers/tasks/take_from_chest_task'

--[[
  ChestResourceSource
  A chest the bot put things into that it didn't need at the time (see
  MakeRoomTask). It provides whatever it holds, so those things are fetched
  from it again when some task wants them.
   - entity: LuaEntity; the chest
]]
ChestResourceSource = ResourceSource:new();

function ChestResourceSource:inventory()
  if(not self.entity.valid) then
    return nil;
  end
  return self.entity.get_inventory(defines.inventory.chest);
end

-- What a chest holds changes all the time, so unlike other sources it isn't
-- cached in `types`.
function ChestResourceSource:provides_type(type)
  local inventory = self:inventory();
  return inventory ~= nil and inventory.get_item_count(type) > 0;
end

function ChestResourceSource:has_output(type)
  return self:provides_type(type);
end

-- {type=type, qty=# wanted in inventory, player=player, machine=GoalMachine}
function ChestResourceSource:gather(opts)
  opts.machine:pushSingle(TakeFromChestTask:new{entity=self.entity, type=opts.type, qty=opts.qty});
end
