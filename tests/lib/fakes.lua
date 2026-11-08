--[[
  Stand-ins for game objects the bot talks to, for tests that need full
  control (inventory contents, reach, crafting) or have to record calls.
  Anything not faked here is the real game: force, recipes, prototypes,
  surfaces (see lab.lua).
]]
local Fakes = {}

-- An inventory: get_item_count / insert / remove / get_contents.
function Fakes.inventory(items)
  local inventory = { items = {} }
  for name, count in pairs(items or {}) do inventory.items[name] = count end

  function inventory.get_item_count(name)
    if name == nil then
      local total = 0
      for _, count in pairs(inventory.items) do total = total + count end
      return total
    end
    return inventory.items[name] or 0
  end
  function inventory.insert(stack)
    inventory.items[stack.name] = (inventory.items[stack.name] or 0) + stack.count
    return stack.count
  end
  function inventory.remove(stack)
    local have = inventory.items[stack.name] or 0
    local removed = math.min(have, stack.count)
    inventory.items[stack.name] = (have - removed > 0) and (have - removed) or nil
    return removed
  end
  function inventory.get_contents()
    local result = {}
    for name, count in pairs(inventory.items) do result[#result + 1] = { name = name, count = count } end
    return result
  end
  return inventory
end

--[[
  A player. opts:
   - items: {name = count} in the main inventory
   - position, surface (default nauvis), index (default 1)
   - can_reach: function(entity) -> bool (default: everything is in reach)
   - craftable: number returned by get_craftable_count (default 0)
  Records: printed, crafted, selected_position, and walking_state /
  mining_state are plain fields.
]]
function Fakes.player(opts)
  opts = opts or {}
  local inventory = Fakes.inventory(opts.items)
  local player = {
    index = opts.index or 1,
    position = opts.position or { x = 0, y = 0 },
    surface = opts.surface or game.surfaces.nauvis,
    force = game.forces.player,
    character = { prototype = prototypes.entity["character"] },
    crafting_queue_size = 0,
    inventory = inventory,
    printed = {},
    crafted = {},
  }
  function player.get_main_inventory() return inventory end
  function player.get_inventory(index) return inventory end
  function player.insert(stack) return inventory.insert(stack) end
  function player.print(message) player.printed[#player.printed + 1] = message end
  function player.can_reach_entity(entity)
    if opts.can_reach then return opts.can_reach(entity) end
    return true
  end
  function player.get_craftable_count(recipe) return opts.craftable or 0 end
  function player.begin_crafting(args)
    local name = type(args.recipe) == "string" and args.recipe or args.recipe.name
    player.crafted[#player.crafted + 1] = { recipe = name, count = args.count }
    return args.count
  end
  function player.update_selected_entity(position) player.selected_position = position end
  return player
end

-- A surface that only answers request_path, recording the request.
function Fakes.pathfinding_surface(request_id)
  local surface = { requests = {} }
  function surface.request_path(args)
    surface.requests[#surface.requests + 1] = args
    return request_id or 1
  end
  return surface
end

-- The goals of a GoalMachine, top first.
function Fakes.goals(machine)
  local goals, g = {}, machine.goals
  while g do
    goals[#goals + 1] = g.current
    g = g.next
  end
  return goals
end

-- Class names of the goals of a GoalMachine, top first.
function Fakes.goal_classes(machine)
  local names = {}
  for class_name, class in pairs(AIMod.classes) do names[class] = class_name end
  local result = {}
  for i, goal in ipairs(Fakes.goals(machine)) do result[i] = names[getmetatable(goal)] or "?" end
  return result
end

return Fakes
