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

-- {type=type, qty=# wanted in inventory, player=player, machine=GoalMachine}
-- Tops up fuel, waits for the product if there isn't enough yet and picks it
-- up. GatherResourceTask repeats this until the inventory holds enough.
function ModuleResourceSource:gather(opts)
  local wanted = opts.qty - Inventories.total_craftable_count(opts.player, opts.type);
  local tasks = self.module:generateTasksForOutput(opts.type, wanted);
  tasks[#tasks + 1] = CollectModuleOutputTask:new{module=self.module, type=opts.type, qty=opts.qty};
  opts.machine:pushStart(tasks);
end
