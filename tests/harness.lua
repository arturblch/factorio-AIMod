--[[
  Headless test harness. Not loaded by the mod itself: tools/run-headless.ps1
  copies the mod to a temp folder, appends `require 'tests/harness'` to the
  copy's control.lua and runs Factorio with --create and --benchmark.

  Headless runs have no LuaPlayer, so a character entity wrapped in a proxy
  plays the role of `player`. The bot is set up in on_init, which means the
  save written by --create already holds the bot in storage and --benchmark
  has to restore it (this checks script.register_metatable).

  Everything interesting goes to factorio-current.log with a "[harness]" tag.
]]

local MAX_TRANSITION_LINES = 400
local SNAPSHOT_EVERY = 1800 -- ticks (30 s of game time)

local class_names = {}
for name, class in pairs(AIMod.classes) do class_names[class] = name end
local status_names = {}
for name, value in pairs(defines.entity_status) do status_names[value] = name end

local function make_player(character)
  local extra = {
    index = 1,
    character = character,
    valid = true,
    print = function(msg) log("[harness] player.print: " .. serpent.line(msg)) end,
    set_goal_description = function() end,
  }
  return setmetatable({}, {
    __index = function(_, k)
      if extra[k] ~= nil then return extra[k] end
      return character[k]
    end,
    __newindex = function(_, k, v) character[k] = v end,
  })
end

local function goal_name(goal)
  if goal.toString then return goal:toString() end
  return class_names[getmetatable(goal)] or "?"
end

local function describe_stack(machine)
  local names, g = {}, machine.goals
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

local function snapshot(tick, character, machine)
  log("[harness] t=" .. tick .. " pos=" .. pos(character.position) ..
    " inv={" .. contents(character.get_main_inventory()) .. "}" ..
    " stack=[" .. describe_stack(machine) .. "]" ..
    " transitions=" .. storage.harness.transitions)
  local built = character.surface.find_entities_filtered{
    name = {"burner-mining-drill", "stone-furnace"}, force = character.force}
  for _, e in pairs(built) do
    local fuel = e.get_fuel_inventory()
    local out = e.get_output_inventory()
    local src = e.type == "furnace" and e.get_inventory(defines.inventory.crafter_input)
    log("[harness]   " .. e.name .. " " .. pos(e.position) .. " dir=" .. e.direction ..
      " status=" .. tostring(status_names[e.status]) ..
      " fuel={" .. (fuel and contents(fuel) or "") .. "}" ..
      (src and (" in={" .. contents(src) .. "}") or "") ..
      (out and (" out={" .. contents(out) .. "}") or ""))
  end
end

script.on_init(function()
  AIMod.init_storage()
  storage.harness = { transitions = 0 }

  local surface = game.surfaces.nauvis
  surface.request_to_generate_chunks({0, 0}, 8)
  surface.force_generate_chunk_requests()
  local start = surface.find_non_colliding_position("character", {0, 0}, 50, 0.5)
  local character = surface.create_entity{name = "character", position = start, force = "player"}
  -- same starting items as 2.1 freeplay
  for _, stack in pairs({
    {name = "iron-plate", count = 8}, {name = "wood", count = 1},
    {name = "burner-mining-drill", count = 1}, {name = "stone-furnace", count = 1},
  }) do character.insert(stack) end
  storage.harness.character = character

  AIMod.setup_bot(make_player(character))
  log("[harness] bot set up, character at " .. pos(character.position))
end)

script.on_event(defines.events.on_tick, function(event)
  local h = storage.harness
  local character = h.character
  if not (character and character.valid) then
    if not h.reported_dead then log("[harness] character is gone") h.reported_dead = true end
    return
  end
  local machine = storage.goal_machines[1]
  if event.tick == 0 then
    log("[harness] after load: machine.tick is " .. type(machine.tick))
  end

  -- A real player's walking_state only lasts one tick unless the script sets
  -- it again; a player-less character would keep walking forever.
  character.walking_state = {walking = false, direction = defines.direction.north}

  AIMod.tick_bot(make_player(character), machine)

  local name = machine.goals and goal_name(machine.goals.current) or "<done>"
  if name ~= h.last_goal then
    h.transitions = h.transitions + 1
    if h.transitions <= MAX_TRANSITION_LINES then
      log("[harness] t=" .. event.tick .. " goal -> " .. name .. " @ " .. pos(character.position))
    end
    h.last_goal = name
  end
  if storage.goals_done[1] and not h.reported_done then
    h.reported_done = true
    log("[harness] COMPLETED at t=" .. event.tick)
    snapshot(event.tick, character, machine)
  end
  if event.tick % SNAPSHOT_EVERY == 0 then
    snapshot(event.tick, character, machine)
  end
end)
