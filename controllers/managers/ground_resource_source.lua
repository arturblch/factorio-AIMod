require 'resource_source';

require 'controllers/tasks/moveToPointTask'
require 'controllers/tasks/mineResourceTask'

-- An ore tile (resource entity) that the player mines by hand.
GroundResourceSource = ResourceSource:new();

function GroundResourceSource:compute_types()
  self.types = {
    {type=self.entity.name}
  };
end

-- {type=type, qty=# wanted in inventory, player=player, machine=GoalMachine}
function GroundResourceSource:gather(opts)
  local position = self.entity.position;
  opts.machine:pushStart({
    MoveToPointTask:new{x=position.x, y=position.y},
    MineResourceTask:new{target=self.entity, type=opts.type, qty=opts.qty}
  });
end
