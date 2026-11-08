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

local done = false;
local once = true;

local function init_storage()
  storage.resource_managers = storage.resource_managers or {};
  storage.goal_machines = storage.goal_machines or {};
end

script.on_init(init_storage)
script.on_configuration_changed(init_storage)

-- start 229.7, 146.1
script.on_event(defines.events.on_player_created, function(event)
  local player = game.get_player(event.player_index);
  local resource_manager = ResourceManager:new();
  resource_manager:initialize(player);

  local goal_machine = GoalMachine:new();
  goal_machine:pushStart({
    BuildModuleTask:new{module=BurnerToFurnaceModule},
    BuildModuleTask:new{module=BurnerToBurnerModule}
  });

  storage.resource_managers[player.index] = resource_manager;
  storage.goal_machines[player.index] = goal_machine;
end);

script.on_event(defines.events.on_tick, function(event)
  for i, machine in pairs(storage.goal_machines) do
    local player = game.get_player(i);

    -- No character means the player is dead, in a cutscene or in map/editor
    -- mode: walking, mining and crafting are all impossible, so just wait.
    if(player and player.valid and player.character) then
      if(once) then
        Logger.log("player start position " .. player.position.x .. ", " .. player.position.y);
        once = false;
      end

      if(not machine:achieved{ player=player }) then
        machine:tick{ player=player }
      elseif(not done) then
        done = true
        player.print("Completed goals")
      end
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
