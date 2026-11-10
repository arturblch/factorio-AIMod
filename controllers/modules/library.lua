require 'burner_to_furnace'
require 'burner_to_burner'

--[[
  ModuleLibrary: every module the bot knows how to build, best first.
  ProductionGoalTask and BuildModuleResourceSource take the first one that
  makes the item they want and hasn't been given up on.
]]
ModuleLibrary = {};

function ModuleLibrary.all()
  return {
    BurnerToFurnaceModule,
    BurnerToFurnaceCopperModule,
    BurnerToFurnaceStoneModule,
    BurnerToBurnerModule
  };
end

function ModuleLibrary.makes(module, item)
  for i, output in ipairs(module.outputs) do
    if(output.type == item) then
      return true;
    end
  end
  return false;
end

-- Modules with an output of `item`, best first.
function ModuleLibrary.producers(item)
  local result = {};
  for i, module in ipairs(ModuleLibrary.all()) do
    if(ModuleLibrary.makes(module, item)) then
      result[#result + 1] = module;
    end
  end
  return result;
end

-- The first module making `item` that the player's bot hasn't given up on
-- (see BuildModuleTask:fail) and that isn't in `skip` ({name = true}), or nil.
function ModuleLibrary.producer(player, item, skip)
  local failed = storage.failed_goals and storage.failed_goals[player.index] or {};
  for i, module in ipairs(ModuleLibrary.producers(item)) do
    local given_up = skip and skip[module.name] or false;
    for j, name in ipairs(failed) do
      if(name == module.name) then
        given_up = true;
      end
    end
    if(not given_up) then
      return module;
    end
  end
  return nil;
end

-- Names of the modules a BuildModuleTask on `machine`'s stack is building.
function ModuleLibrary.being_built(machine)
  local names = {};
  local entry = machine and machine.goals;
  while(entry ~= nil) do
    if(getmetatable(entry.current) == BuildModuleTask) then
      names[entry.current.module.name] = true;
    end
    entry = entry.next;
  end
  return names;
end
