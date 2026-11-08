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

local first_tick_after_load = true -- plain local: resets on every load
local mod_on_tick = script.get_event_handler(defines.events.on_tick)

script.on_event(defines.events.on_tick, function(event)
  mod_on_tick(event)

  storage.test = storage.test or { transitions = 0 }
  local t = storage.test
  local player = game.get_player(1)
  local machine = storage.goal_machines and storage.goal_machines[1]
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
    if t.transitions <= MAX_TRANSITION_LINES then
      log("[test] t=" .. event.tick .. " goal -> " .. name .. " @ " .. pos(player.position))
    end
    t.last_goal = name
  end

  if event.tick % SNAPSHOT_EVERY == 0 then
    snapshot(event.tick, player, machine)
    if not check_storage(event.tick) then return end
  end
  if storage.goals_done and storage.goals_done[1] and not t.completed then
    t.completed = true
    local failed = storage.failed_goals and storage.failed_goals[1] or {}
    snapshot(event.tick, player, machine)
    if #failed > 0 then
      -- the goal list ran out, but some modules were given up on
      log("[test] GAVE UP at t=" .. event.tick .. " on: " .. table.concat(failed, ", "))
      script.finish_test(false)
    else
      log("[test] COMPLETED at t=" .. event.tick)
      if check_storage(event.tick) then script.finish_test(true) end
    end
  end
end)
