--[[
  End-to-end test with a real player. Not loaded by the mod itself:
  tools/run-headless.ps1 copies the mod to a temp folder, appends
  `require 'tests/scenario_test'` to the copy's control.lua and starts
  Factorio with `--test-scenario AIMod/AIPlay` (headless, with a player).

  The mod's own handlers run unchanged; this file only wraps on_tick to
  report progress, check that storage can be saved, and end the test with
  script.finish_test once the bot has completed its goals.

  Saving isn't possible in test mode, so instead of a save/load round trip
  every snapshot audits storage: tables with an unregistered metatable would
  come back from a save without their methods, functions can't be saved.

  Everything goes to the Factorio log with a "[test]" tag.
]]

require 'util/production_score'

local SNAPSHOT_EVERY = 1800 -- ticks (30 s of game time)
local MAX_TRANSITION_LINES = 400

local class_names = {}
for name, class in pairs(AIMod.classes) do class_names[class] = name end
local status_names = {}
for name, value in pairs(defines.entity_status) do status_names[value] = name end

local function goal_name(goal)
  if goal.toString then return goal:toString() end
  return class_names[getmetatable(goal)] or "?"
end

local function describe_stack(machine)
  local names, g = {}, machine and machine.goals
  while g do
    names[#names + 1] = class_names[getmetatable(g.current)] or "?"
    g = g.next
  end
  return table.concat(names, " < ")
end

local function pos(p) return string.format("(%.1f, %.1f)", p.x, p.y) end

local function contents(inv)
  local parts = {}
  for _, item in pairs(inv.get_contents()) do parts[#parts + 1] = item.name .. "=" .. item.count end
  table.sort(parts)
  return table.concat(parts, " ")
end

-- Problems that would break saving/loading storage, as "storage.path: what".
local function audit_storage()
  local problems, seen = {}, {}
  local function visit(value, path)
    if #problems >= 5 then return end
    if type(value) == "function" then
      problems[#problems + 1] = path .. ": function (can't be saved)"
    elseif type(value) == "table" and not seen[value] then
      seen[value] = true
      local mt = getmetatable(value)
      if mt and not class_names[mt] then
        problems[#problems + 1] = path .. ": metatable not registered with script.register_metatable"
      end
      for k, v in pairs(value) do visit(v, path .. "." .. tostring(k)) end
    end
  end
  visit(storage, "storage")
  return problems
end

local function check_storage(tick)
  local problems = audit_storage()
  if #problems == 0 then return true end
  for _, problem in pairs(problems) do log("[test] STORAGE PROBLEM at t=" .. tick .. ": " .. problem) end
  script.finish_test(false)
  return false
end

local function snapshot(tick, player, machine)
  local inv = player.character and player.get_main_inventory()
  log("[test] t=" .. tick .. " pos=" .. pos(player.position) ..
    " inv={" .. (inv and contents(inv) or "no character") .. "}" ..
    " stack=[" .. describe_stack(machine) .. "]" ..
    " transitions=" .. (storage.test.transitions or 0))
  -- what's around: helps to tell why the bot doesn't move
  local around = {}
  for _, e in pairs(player.surface.find_entities_filtered{position = player.position, radius = 2.5}) do
    if e.type ~= "resource" and e.type ~= "character" then around[#around + 1] = e.type .. ":" .. e.name end
  end
  local tiles = {}
  for _, d in pairs({{0, -1.5}, {1.5, 0}, {0, 1.5}, {-1.5, 0}}) do
    local tile = player.surface.get_tile(player.position.x + d[1], player.position.y + d[2])
    tiles[#tiles + 1] = tile.name
  end
  log("[test]   around: " .. table.concat(around, " ") .. " | tiles N/E/S/W: " .. table.concat(tiles, " "))
  local built = player.surface.find_entities_filtered{
    name = {"burner-mining-drill", "stone-furnace"}, force = player.force}
  for _, e in pairs(built) do
    local fuel = e.get_fuel_inventory()
    local src = e.type == "furnace" and e.get_inventory(defines.inventory.crafter_input)
    local out = e.type == "furnace" and e.get_output_inventory()
    log("[test]   " .. e.name .. " " .. pos(e.position) .. " dir=" .. e.direction ..
      " status=" .. tostring(status_names[e.status]) ..
      " fuel={" .. (fuel and contents(fuel) or "") .. "}" ..
      (src and (" in={" .. contents(src) .. "}") or "") ..
      (out and (" out={" .. contents(out) .. "}") or ""))
  end
end

--[[
  Other goals (`--test-arg goal:copper-plate:10,have:copper-cable:20`,
  run-headless.ps1 -Goals): replace the bot's goal list before it starts.
  goal:<item>:<n> is a ProductionGoalTask (n per minute), have:<item>:<n> a
  GatherResourceTask (n in the inventory), kept in the given order.
]]
--[[
  Growth (`--test-arg grow:<tick>`, run-headless.ps1 -Grow): the bot plays on
  after its goals (GrowthTask, appended to goals given with -Goals) and the
  run ends at <tick>, with the modules built, their rates and the score.
]]
local grow_until = tonumber((script.test_arg or ""):match("grow:(%d+)"))

local function module_summary(player)
  local counts, parts, rates = {}, {}, {}
  local manager = storage.resource_managers and storage.resource_managers[1]
  for _, source in ipairs(manager and manager.sources or {}) do
    if source.module then
      local name = source.module.name .. (source:is_valid() and "" or "(broken)")
      counts[name] = (counts[name] or 0) + 1
    end
  end
  for name, n in pairs(counts) do parts[#parts + 1] = name .. "=" .. n end
  table.sort(parts)
  for _, item in ipairs({ "iron-plate", "copper-plate", "stone-brick", "coal" }) do
    rates[#rates + 1] = item .. "=" .. string.format("%.1f", ProductionGoalTask.rate(player, item))
  end
  return "modules: " .. table.concat(parts, " ") .. " | per minute: " .. table.concat(rates, " ")
end

-- The electric networks (util/power.lua) and how far GrowthTask.RESEARCH got.
local function power_summary(player)
  local research = {}
  for _, name in ipairs(GrowthTask.RESEARCH) do
    local tech = player.force.technologies[name]
    local state = tech.researched and "done"
      or (player.force.current_research and player.force.current_research.name == name
          and string.format("%.0f %%", player.force.research_progress * 100))
      or "not started"
    research[#research + 1] = name .. " " .. state
  end
  return Power.summary(player) .. " | research: " .. table.concat(research, ", ")
end

local function goal_flags()
  local goals = {}
  for kind, item, n in (script.test_arg or ""):gmatch("(%a+):([%w%-]+):([%d%.]+)") do
    if kind == "goal" then
      goals[#goals + 1] = ProductionGoalTask:new{ item = item, per_minute = tonumber(n) }
    elseif kind == "have" then
      goals[#goals + 1] = GatherResourceTask:new{ type = item, qty = tonumber(n) }
    end
  end
  return goals
end

--[[
  Cursor noise (`--test-arg cursor-noise`, run-headless.ps1 -CursorNoise):
  a player moving the mouse over other entities changes their selection, and
  a character mines whatever is selected. Input is applied at the start of a
  tick, before on_tick, so before the bot runs each tick the selection is
  moved to some nearby tree, rock, ore tile or building other than the bot's
  target, a different one every tick. The bot must still mine only what its
  current task targets: anything else mined counts as unintended.
]]
-- `--test-arg` holds a comma separated list of flags
local function test_flag(name)
  return (script.test_arg or ""):find(name, 1, true) ~= nil
end
local function noise_enabled() return test_flag("cursor-noise") end

-- `score` (run-headless.ps1 -Score): the production score after each snapshot;
-- the last one logged is the run's result
local function log_score(player)
  if test_flag("score") then log("[test]   score " .. ProductionScore.score(player.force)) end
end

local function current_target(machine)
  local top = machine.goals and machine.goals.current
  return top and (top.target or top.entity), top
end

local function cursor_noise(player, machine, tick, t)
  if not player.character then return end
  local target = current_target(machine)
  local choices = {}
  for _, e in pairs(player.surface.find_entities_filtered{position = player.position, radius = 8,
      type = {"tree", "simple-entity", "resource", "mining-drill", "furnace"}}) do
    if e ~= target then choices[#choices + 1] = e end
  end
  if #choices == 0 then return end
  player.update_selected_entity(choices[(tick % #choices) + 1].position)
  t.noise_ticks = (t.noise_ticks or 0) + 1
end

--[[
  Full inventory (`--test-arg full-inventory`, run-headless.ps1
  -FullInventory): the first time the bot is about to mine something, every
  empty slot of its main inventory is filled with stone bricks, which no
  task needs. With a full inventory the character can't mine at all, so the
  bot has to put the bricks away (MakeRoomTask) before it can go on.
]]
local MINING_TASKS = { MineResourceTask = true, MineEntityTask = true }

local function fill_inventory(player, tick, t)
  local inventory = player.get_main_inventory()
  local filled = 0
  for i = 1, #inventory do
    if not inventory[i].valid_for_read then
      inventory[i].set_stack{ name = "stone-brick", count = 100 }
      filled = filled + 1
    end
  end
  t.filled = filled
  log("[test] filled " .. filled .. " empty slots with stone bricks at t=" .. tick)
end

local function full_inventory_summary(player, t)
  local stashes, stored = 0, 0
  for _, source in pairs(storage.resource_managers[player.index].sources) do
    if getmetatable(source) == ChestResourceSource and source.entity.valid then
      stashes = stashes + 1
      stored = stored + source:inventory().get_item_count("stone-brick")
    end
  end
  local dropped = 0
  for _, e in pairs(player.surface.find_entities_filtered{ type = "item-entity" }) do
    if e.stack.name == "stone-brick" then dropped = dropped + e.stack.count end
  end
  return "full inventory: filled " .. (t.filled or 0) .. " slots, MakeRoomTask ran " .. (t.make_room or 0) ..
    " times, " .. stashes .. " stash chests with " .. stored .. " bricks, " .. dropped .. " bricks dropped, " ..
    player.get_main_inventory().get_item_count("stone-brick") .. " still carried"
end

script.on_event(defines.events.on_player_mined_entity, function(event)
  local machine = storage.goal_machines and storage.goal_machines[1]
  local t = storage.test
  if not (machine and t) then return end
  local target, top = current_target(machine)
  -- BuildModuleTask picks its own buildings up again when it retries
  local intended = event.entity == target or (top and getmetatable(top) == BuildModuleTask)
  if not intended then
    t.unintended = (t.unintended or 0) + 1
    log("[test] UNINTENDED mining at t=" .. event.tick .. ": " .. event.entity.name .. " " ..
      pos(event.entity.position) .. " while the task was " .. (top and goal_name(top) or "<none>"))
  end
end)

-- The character can die (biters, mostly) and respawn without its inventory;
-- the bot then carries on, so this would go unnoticed otherwise.
script.on_event(defines.events.on_player_died, function(event)
  local t = storage.test
  if not t then return end
  t.deaths = (t.deaths or 0) + 1
  local player = game.get_player(event.player_index)
  log("[test] DIED at t=" .. event.tick .. " " .. pos(player.position) ..
    " killed by " .. (event.cause and event.cause.valid and event.cause.name or "?"))
end)

local first_tick_after_load = true -- plain local: resets on every load
local mod_on_tick = script.get_event_handler(defines.events.on_tick)

script.on_event(defines.events.on_tick, function(event)
  storage.test = storage.test or { transitions = 0 }
  local t = storage.test
  local player = game.get_player(1)
  local machine = storage.goal_machines and storage.goal_machines[1]
  if machine and not t.goals_checked then
    t.goals_checked = true
    -- `peaceful` (run-headless.ps1 -Peaceful): biters attack only when attacked,
    -- to measure long growth runs apart from defence (plan item 1.5)
    -- `modules:A+B` (run-headless.ps1 -Modules "A,B"): the modules the bot builds, as /aimod-use
    local chosen = (script.test_arg or ""):match("modules:([%w%-%+]+)")
    if chosen then
      local names = {}
      for name in chosen:gmatch("[^+]+") do names[#names + 1] = name end
      if chosen == "best" then names = "best" end
      local unknown = ModuleLibrary.choose(names)
      local using = {}
      for _, module in ipairs(ModuleLibrary.all()) do using[#using + 1] = module.name end
      log("[test] modules: " .. (unknown and ("NO MODULE " .. unknown) or table.concat(using, ", ")))
    end
    if test_flag("peaceful") then
      for _, surface in pairs(game.surfaces) do surface.peaceful_mode = true end
      log("[test] peaceful mode")
    end
    local goals = goal_flags()
    if #goals > 0 then
      if grow_until then goals[#goals + 1] = GrowthTask:new{} end
      machine.goals = nil
      machine:pushStart(goals)
      log("[test] goals replaced: " .. describe_stack(machine))
    end
  end
  if player and machine and noise_enabled() then
    cursor_noise(player, machine, event.tick, t)
  end
  if player and player.character and machine and machine.goals and not t.filled and test_flag("full-inventory")
      and MINING_TASKS[class_names[getmetatable(machine.goals.current)]] then
    fill_inventory(player, event.tick, t)
  end

  mod_on_tick(event)

  machine = storage.goal_machines and storage.goal_machines[1]
  if not (player and machine) then return end

  if first_tick_after_load then
    first_tick_after_load = false
    log("[test] running at t=" .. event.tick .. ", player " .. player.name ..
      " controller=" .. player.controller_type .. ", machine.tick is " .. type(machine.tick) ..
      ", stack=[" .. describe_stack(machine) .. "]")
  end

  local name = machine.goals and goal_name(machine.goals.current) or "<done>"
  if name ~= t.last_goal then
    t.transitions = t.transitions + 1
    if name:find("^MakeRoomTask") then t.make_room = (t.make_room or 0) + 1 end
    if t.transitions <= MAX_TRANSITION_LINES then
      log("[test] t=" .. event.tick .. " goal -> " .. name .. " @ " .. pos(player.position))
    end
    t.last_goal = name
  end

  if event.tick % SNAPSHOT_EVERY == 0 then
    snapshot(event.tick, player, machine)
    log_score(player)
    if grow_until then
      log("[test]   " .. module_summary(player))
      log("[test]   " .. power_summary(player))
    end
    if not check_storage(event.tick) then return end
  end
  if grow_until and event.tick >= grow_until and not t.completed then
    t.completed = true
    snapshot(event.tick, player, machine)
    log_score(player)
    log("[test] " .. module_summary(player))
    log("[test] " .. power_summary(player))
    local failed = storage.failed_goals and storage.failed_goals[1] or {}
    if #failed > 0 then log("[test]   gave up on: " .. table.concat(failed, ", ")) end
    if (t.deaths or 0) > 0 then
      log("[test] DIED " .. t.deaths .. " times")
      script.finish_test(false)
    elseif (t.unintended or 0) > 0 then
      log("[test] MINED THE WRONG THING " .. t.unintended .. " times (cursor noise)")
      script.finish_test(false)
    else
      log("[test] COMPLETED at t=" .. event.tick)
      if check_storage(event.tick) then script.finish_test(true) end
    end
  end
  if not grow_until and storage.goals_done and storage.goals_done[1] and not t.completed then
    t.completed = true
    local failed = storage.failed_goals and storage.failed_goals[1] or {}
    snapshot(event.tick, player, machine)
    log_score(player)
    if noise_enabled() then
      log("[test] cursor noise: decoy selected on " .. (t.noise_ticks or 0) .. " ticks, " ..
        (t.unintended or 0) .. " unintended entities mined")
    end
    local full_inventory = test_flag("full-inventory")
    if full_inventory then log("[test] " .. full_inventory_summary(player, t)) end
    if #failed > 0 then
      -- the goal list ran out, but some modules were given up on
      log("[test] GAVE UP at t=" .. event.tick .. " on: " .. table.concat(failed, ", "))
      script.finish_test(false)
    elseif (t.deaths or 0) > 0 then
      log("[test] DIED " .. t.deaths .. " times")
      script.finish_test(false)
    elseif full_inventory and (t.make_room or 0) == 0 then
      log("[test] FULL INVENTORY NOT EXERCISED: the bot never had to make room")
      script.finish_test(false)
    elseif (t.unintended or 0) > 0 then
      log("[test] MINED THE WRONG THING " .. t.unintended .. " times (cursor noise)")
      script.finish_test(false)
    else
      log("[test] COMPLETED at t=" .. event.tick)
      if check_storage(event.tick) then script.finish_test(true) end
    end
  end
end)
