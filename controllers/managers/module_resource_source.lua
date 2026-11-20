require 'resource_source';

require 'util/inventories'
require 'controllers/tasks/collect_module_output_task'
--[[
  ModuleResourceSource
  Provides the interface between a module (piece of a factory) and the resource
  manager
   - module: Module; the module that this resource source represents
]]
ModuleResourceSource = ResourceSource:new();

function ModuleResourceSource:compute_types()
  --for each output of self.module, add the type
  local products = {};
  for i, output in ipairs(self.module.outputs) do
    products[#products + 1] = {type=output.type}
  end
  self.types = products;
end

function ModuleResourceSource:is_valid()
  return self.module:isOperational();
end

function ModuleResourceSource:has_output(type)
  return self.module:hasOutputAvailable(type);
end

-- Whether another module of the player's holds some `type` ready.
local function ready_elsewhere(self, player, type)
  local manager = storage.resource_managers and storage.resource_managers[player.index];
  for i, source in ipairs(manager and manager.sources or {}) do
    if(source ~= self and source.module and source:is_valid() and source:provides_type(type) and source:has_output(type)) then
      return true;
    end
  end
  return false;
end

-- {type=type, qty=# wanted in inventory, player=player, machine=GoalMachine}
-- Tops up fuel, waits for the product if there isn't enough yet and picks it
-- up. GatherResourceTask repeats this until the inventory holds enough.
-- With some ready here and some in another module, it only takes what is
-- here: the gather goes there for the rest rather than wait here (plan
-- 4.11: plates left in the furnaces). With none anywhere else it waits as
-- before, doing the work of the tasks below meanwhile (WaitForOutputTask).
function ModuleResourceSource:gather(opts)
  local wanted = opts.qty - Inventories.total_craftable_count(opts.player, opts.type);
  local tasks;
  if(self.module:outputCount(opts.type) > 0 and ready_elsewhere(self, opts.player, opts.type)) then
    tasks = self.module:fuelTasks();
  else
    tasks = self.module:generateTasksForOutput(opts.type, wanted, opts.qty);
  end
  tasks[#tasks + 1] = CollectModuleOutputTask:new{module=self.module, type=opts.type, qty=opts.qty};
  opts.machine:pushStart(tasks);
end
