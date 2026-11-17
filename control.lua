require 'util'
require 'util/logger'
require 'util/pathfinding_fringe'
require 'controllers/tasks/gatherResourcesTask'
require 'controllers/tasks/playerGatherResourcesTask'
require 'controllers/tasks/playerPlaceBuildingTask'
require 'controllers/tasks/placeBuildingTask'
require 'controllers/tasks/craftRecipeTask'
require 'controllers/tasks/moveToPointTask'
require 'controllers/tasks/pathfindToPointTask'
require 'controllers/tasks/build_module_task'
require 'controllers/tasks/mine_entity_task'
require 'controllers/tasks/clear_area_task'
require 'controllers/tasks/build_building_task'
require 'controllers/tasks/fuel_building_task'
require 'controllers/tasks/wait_for_output_task'
require 'controllers/tasks/hand_smelt_task'
require 'controllers/tasks/collect_module_output_task'
require 'controllers/tasks/take_from_chest_task'
require 'controllers/tasks/make_room_task'
require 'controllers/tasks/production_goal_task'
require 'controllers/tasks/research_trigger_task'
require 'controllers/tasks/growth_task'
require 'controllers/managers/chest_resource_source'
require 'controllers/managers/build_module_resource_source'
require 'controllers/managers/research_resource_source'
require 'controllers/modules/library'
require 'controllers/managers/manager'
require 'controllers/managers/resource_manager'
require 'controllers/goalMachine'

-- Every class whose instances end up in `storage` must be registered, otherwise
-- they come back from a save as plain tables without methods and the bot
-- crashes on the first tick after loading. `__index` is set up front because
-- `Class:new()` only sets it lazily, and that may not have happened yet in a
-- freshly loaded game.
local persistent_classes = {
  Task = Task,
  GoalMachine = GoalMachine,
  Manager = Manager,
  ResourceManager = ResourceManager,
  ResourceSource = ResourceSource,
  GroundResourceSource = GroundResourceSource,
  TreeResourceSource = TreeResourceSource,
  CraftResourceSource = CraftResourceSource,
  ModuleResourceSource = ModuleResourceSource,
  ChestResourceSource = ChestResourceSource,
  BuildModuleResourceSource = BuildModuleResourceSource,
  ResearchResourceSource = ResearchResourceSource,
  BaseModule = BaseModule,
  Fringe = Fringe,
  GatherResourceTask = GatherResourceTask,
  PlayerGatherResourcesTask = PlayerGatherResourcesTask,
  PlayerPlaceBuildingTask = PlayerPlaceBuildingTask,
  PlaceBuildingTask = PlaceBuildingTask,
  CraftRecipeTask = CraftRecipeTask,
  MoveToPointTask = MoveToPointTask,
  PathfindToPointTask = PathfindToPointTask,
  BuildModuleTask = BuildModuleTask,
  MineEntityTask = MineEntityTask,
  MineResourceTask = MineResourceTask,
  ClearAreaTask = ClearAreaTask,
  BuildBuildingTask = BuildBuildingTask,
  FuelBuildingTask = FuelBuildingTask,
  WaitForOutputTask = WaitForOutputTask,
  HandSmeltTask = HandSmeltTask,
  ResearchTriggerTask = ResearchTriggerTask,
  GrowthTask = GrowthTask,
  CollectModuleOutputTask = CollectModuleOutputTask,
  TakeFromChestTask = TakeFromChestTask,
  MakeRoomTask = MakeRoomTask,
  ProductionGoalTask = ProductionGoalTask,
}
for name, class in pairs(persistent_classes) do
  class.__index = class
  script.register_metatable(name, class)
end

-- Entry points shared by the event handlers below and by tests/harness.lua,
-- which drives the same bot headlessly with a character instead of a player.
AIMod = { classes = persistent_classes }

function AIMod.init_storage()
  storage.resource_managers = storage.resource_managers or {};
  storage.goal_machines = storage.goal_machines or {};
  -- per player: start position logged / "Completed goals" announced. Kept in
  -- storage rather than in Lua locals so every client agrees (no desyncs).
  storage.start_logged = storage.start_logged or {};
  storage.goals_done = storage.goals_done or {};
end

-- The goals a new bot starts with, as products. Each takes one module today:
-- BurnerToFurnace makes 15 iron plates a minute, BurnerToBurner ~25 coal.
function AIMod.default_goals()
  return {
    ProductionGoalTask:new{item="iron-plate", per_minute=10},
    ProductionGoalTask:new{item="coal", per_minute=20},
    -- then keep the modules going and add more, without end
    GrowthTask:new{}
  };
end

-- The goals are met (all of them, or those before GrowthTask): say so once.
function AIMod.goals_done(player)
  if(storage.goals_done[player.index]) then
    return;
  end
  storage.goals_done[player.index] = true;
  local failed = storage.failed_goals and storage.failed_goals[player.index];
  if(failed and #failed > 0) then
    player.print("Finished goals, could not build: " .. table.concat(failed, ", "));
  else
    player.print("Completed goals");
  end
end

function AIMod.setup_bot(player)
  local resource_manager = ResourceManager:new();
  resource_manager:initialize(player);

  local goal_machine = GoalMachine:new();
  goal_machine:pushStart(AIMod.default_goals());

  storage.resource_managers[player.index] = resource_manager;
  storage.goal_machines[player.index] = goal_machine;
end

function AIMod.tick_bot(player, machine)
  if(not storage.start_logged[player.index]) then
    Logger.log("player start position " .. player.position.x .. ", " .. player.position.y);
    storage.start_logged[player.index] = true;
  end

  if(not machine:achieved{ player=player }) then
    machine:tick{ player=player }
  else
    AIMod.goals_done(player);
  end
end

-- Lines describing the modules in blueprints/library.lua, for /aimod-modules.
function AIMod.module_list()
  local lines = {};
  for i, module in ipairs(ModuleLibrary.listed()) do
    local made, seen = {}, {};
    for j, output in ipairs(module.outputs) do
      if(not seen[output.type]) then
        seen[output.type] = true;
        made[#made + 1] = output.type;
      end
    end
    lines[#lines + 1] = string.format("%s%s: %s from %s, %d buildings", module.name, module.off and " (off)" or "",
      table.concat(made, ", "), module.resource, #module.buildings);
  end
  return lines;
end

-- Draws where the bot would build module `name` for a minute; returns what
-- to tell the player.
function AIMod.show_plan(player, name)
  local module = name and ModuleLibrary.get(name);
  if(not module) then
    return "AIMod: no module " .. tostring(name) .. ", /aimod-modules lists them";
  end
  local location = BuildModuleTask:new{module=module}:findLocation(player);
  if(not location) then
    return "AIMod: no spot for " .. name .. " near you";
  end
  ModulePlan.draw(module, location, player.surface, 3600);
  return string.format("AIMod: %s would go at [gps=%d,%d]", name, location.x, location.y);
end

commands.add_command("aimod-modules", "Lists the modules the AIMod bot builds (blueprints/library.lua).", function(command)
  local player = command.player_index and game.get_player(command.player_index);
  for i, line in ipairs(AIMod.module_list()) do
    if(player) then player.print(line) else log(line) end
  end
end)

-- /aimod-use: which modules the bot builds; returns what to tell the player.
function AIMod.use_modules(parameter)
  local names = {};
  for name in (parameter or ""):gmatch("[^%s,]+") do
    names[#names + 1] = name;
  end
  if(#names == 1 and names[1] == "default") then
    ModuleLibrary.choose(nil);
  elseif(#names > 0) then
    local unknown = ModuleLibrary.choose(names);
    if(unknown) then
      return "AIMod: no module " .. unknown .. ", /aimod-modules lists them";
    end
  end
  local using = {};
  for i, module in ipairs(ModuleLibrary.all()) do
    using[#using + 1] = module.name;
  end
  return "AIMod builds, best first: " .. table.concat(using, ", ") ..
    (storage.module_choice and " (your choice; /aimod-use default goes back to the library)" or " (blueprints/library.lua)");
end

commands.add_command("aimod-use", "[module ...] - which modules the AIMod bot builds, best first; default: as in blueprints/library.lua.", function(command)
  local message = AIMod.use_modules(command.parameter);
  local player = command.player_index and game.get_player(command.player_index);
  if(player) then player.print(message) else log(message) end
end)

commands.add_command("aimod-plan", "<module> - shows for a minute where the AIMod bot would build that module.", function(command)
  local player = command.player_index and game.get_player(command.player_index);
  if(player and player.character) then
    player.print(AIMod.show_plan(player, command.parameter and command.parameter:match("^%s*(%S+)")));
  end
end)

script.on_init(AIMod.init_storage)
script.on_configuration_changed(AIMod.init_storage)

-- start 229.7, 146.1
script.on_event(defines.events.on_player_created, function(event)
  AIMod.setup_bot(game.get_player(event.player_index));
end);

-- Answers to MoveToPointTask's pathfinder requests; the task picks its own up.
script.on_event(defines.events.on_script_path_request_finished, function(event)
  storage.path_results = storage.path_results or {};
  storage.path_results[event.id] = {path=event.path, try_again_later=event.try_again_later};
end)

script.on_event(defines.events.on_tick, function(event)
  for i, machine in pairs(storage.goal_machines) do
    local player = game.get_player(i);

    -- No character means the player is dead, in a cutscene or in map/editor
    -- mode: walking, mining and crafting are all impossible, so just wait.
    if(player and player.valid and player.character) then
      AIMod.tick_bot(player, machine)
    end
  end
end)

-- peninsula
--[[
>>>AAANABQAAAADAwYAAAAEAAAAY29hbAMDAwoAAABjb3BwZXItb3Jl
AwMDCQAAAGNydWRlLW9pbAMDAwoAAABlbmVteS1iYXNlAwMDCAAAAGl
yb24tb3JlAwMDBQAAAHN0b25lAwMDMbU1VICEHgCAhB4AAwFa9nHa<<
<
--]]

--peninsula with s-bend
--[[
>>>AAANABQAAAADAwYAAAAEAAAAY29hbAMDAwoAAABjb3BwZXItb3Jl
AwMDCQAAAGNydWRlLW9pbAMDAwoAAABlbmVteS1iYXNlAwMDCAAAAGl
yb24tb3JlAwMDBQAAAHN0b25lAwMDNqeYAYCEHgCAhB4AAwANu1Dz<<
<
--]]
