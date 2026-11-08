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
require 'controllers/tasks/collect_module_output_task'
require 'controllers/modules/burner_to_furnace'
require 'controllers/modules/burner_to_burner'
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
  CollectModuleOutputTask = CollectModuleOutputTask,
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

function AIMod.setup_bot(player)
  local resource_manager = ResourceManager:new();
  resource_manager:initialize(player);

  local goal_machine = GoalMachine:new();
  goal_machine:pushStart({
    BuildModuleTask:new{module=BurnerToFurnaceModule},
    BuildModuleTask:new{module=BurnerToBurnerModule}
  });

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
  elseif(not storage.goals_done[player.index]) then
    storage.goals_done[player.index] = true
    local failed = storage.failed_goals and storage.failed_goals[player.index]
    if(failed and #failed > 0) then
      player.print("Finished goals, could not build: " .. table.concat(failed, ", "))
    else
      player.print("Completed goals")
    end
  end
end

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
