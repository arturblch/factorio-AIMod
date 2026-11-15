require 'resource_source';

require 'controllers/tasks/build_module_task'

--[[
  BuildModuleResourceSource
  ResourceManager's last resort: nothing on the map, in a built module or in
  a hand-craft gives the item, but a module from ModuleLibrary makes it (iron
  plates before any furnace stands, copper plates, stone bricks). gather
  builds that module; the GatherResourceTask that asked looks again when
  it's done and finds it as a ModuleResourceSource.
   - module: BaseModule; the definition to build
]]
BuildModuleResourceSource = ResourceSource:new();

function BuildModuleResourceSource:compute_types()
  local products = {};
  for i, output in ipairs(self.module.outputs) do
    products[#products + 1] = {type=output.type};
  end
  self.types = products;
end

function BuildModuleResourceSource:is_valid()
  return true;
end

function BuildModuleResourceSource:gather(opts)
  opts.machine:pushSingle(BuildModuleTask:new{module=self.module});
end
