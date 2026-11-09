--[[
  Runs the unit tests in tests/unit/ inside Factorio. Not loaded by the mod
  itself: `tools/run-headless.ps1 -Unit` copies the mod to a temp folder,
  appends `require 'tests/unit_runner'` to the copy's control.lua and starts
  `factorio --test-scenario AIMod/AIPlay`. The bot is switched off, the tests
  run on the first tick and script.finish_test reports the result.

  To add a test file: create tests/unit/<name>_test.lua and list it below
  (Factorio's require can't list directories).
]]
local T = require 'tests/lib/testing'

require 'tests/unit/goal_machine_test'
require 'tests/unit/recipes_test'
require 'tests/unit/gather_craft_test'
require 'tests/unit/resource_manager_test'
require 'tests/unit/modules_test'
require 'tests/unit/build_test'
require 'tests/unit/movement_test'
require 'tests/unit/inventory_test'

-- shared state every test starts without
T.global_before[#T.global_before + 1] = function()
  storage.resource_managers = {}
  storage.goal_machines = {}
  storage.unreachable = nil
  storage.path_results = nil
  storage.failed_goals = nil
  storage.room_failed_at = nil
end

-- the bot must not play while the tests poke at the game
script.on_event(defines.events.on_tick, function(event)
  script.on_event(defines.events.on_tick, nil)
  local passed = T.run(function(line) log("[unit] " .. line) end)
  script.finish_test(passed)
end)
