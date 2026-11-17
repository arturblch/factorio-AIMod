require 'base_module'
require 'util/blueprint'

--[[
  ModuleLibrary: every module the bot knows how to build, best first, made
  from the blueprints listed in blueprints/library.lua (util/blueprint.lua)
  while control.lua loads. ProductionGoalTask and BuildModuleResourceSource
  take the first one that makes the item they want and hasn't been given
  up on. A listed module whose blueprint can't be read is left out, with a
  line in the game's log.
]]
ModuleLibrary = {};

local LIBRARY = require 'blueprints/library';

local listed = {};  -- every module in the list, in order, the `off` ones too
local by_name = {};
for i, entry in ipairs(LIBRARY.modules) do
  local data, problem = Blueprint.module{
    name=entry.name,
    blueprint=LIBRARY.blueprints[entry.blueprint] or entry.blueprint,
    resource=entry.resource,
    product=entry.product,
  };
  if(data) then
    local module = BaseModule:new(data);
    module.off = entry.off;
    listed[#listed + 1] = module;
    by_name[entry.name] = module;
  else
    log("AIMod: module " .. tostring(entry.name) .. " left out of the library: " .. problem);
  end
end

-- the modules code and tests refer to by name
BurnerToFurnaceModule = by_name.BurnerToFurnace;
BurnerToFurnaceCopperModule = by_name.BurnerToFurnaceCopper;
BurnerToFurnaceStoneModule = by_name.BurnerToFurnaceStone;
BurnerToBurnerModule = by_name.BurnerToBurner;

function ModuleLibrary.get(name)
  return by_name[name];
end

-- Every listed module, the ones switched off too.
function ModuleLibrary.listed()
  return listed;
end

-- The modules the bot builds, best first: the player's choice (/aimod-use,
-- kept in storage.module_choice) if there is one, else the ones switched on
-- in blueprints/library.lua, in its order.
function ModuleLibrary.all()
  local result = {};
  local choice = storage and storage.module_choice;
  if(choice) then
    for i, name in ipairs(choice) do
      result[#result + 1] = by_name[name];
    end
    return result;
  end
  for i, module in ipairs(listed) do
    if(not module.off) then
      result[#result + 1] = module;
    end
  end
  return result;
end

-- Makes the bot build the listed modules named in `names`, in that order,
-- switched off ones too; nil goes back to blueprints/library.lua. Returns
-- nil, or the first name that isn't in the library.
function ModuleLibrary.choose(names)
  for i, name in ipairs(names or {}) do
    if(not by_name[name]) then
      return name;
    end
  end
  storage.module_choice = names;
  return nil;
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
