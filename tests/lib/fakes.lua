--[[
  Stand-ins for game objects the bot talks to, for tests that need full
  control (inventory contents, reach, crafting) or have to record calls.
  Anything not faked here is the real game: force, recipes, prototypes,
  surfaces (see lab.lua).
]]
local Fakes = {}

--[[
  An inventory: get_item_count / insert / remove / get_contents / can_insert /
  count_empty_stacks / sort_and_merge. With `slots` it holds that many stacks
  (stack sizes from the item prototypes, always merged); without it never
  fills up. Records how often sort_and_merge was called in `merged`.
]]
function Fakes.inventory(items, slots)
  local inventory = { items = {}, merged = 0 }
  for name, count in pairs(items or {}) do inventory.items[name] = count end

  local function stacks_used()
    local used = 0
    for name, count in pairs(inventory.items) do used = used + math.ceil(count / prototypes.item[name].stack_size) end
    return used
  end
  local function room_for(name)
    if not slots then return math.huge end
    local size = prototypes.item[name].stack_size
    local partial = (inventory.items[name] or 0) % size
    return (partial > 0 and size - partial or 0) + (slots - stacks_used()) * size
  end
  function inventory.can_insert(stack) return room_for(stack.name) > 0 end
  function inventory.count_empty_stacks() return slots and (slots - stacks_used()) or 1000 end
  function inventory.sort_and_merge() inventory.merged = inventory.merged + 1 end

  function inventory.get_item_count(name)
    if name == nil then
      local total = 0
      for _, count in pairs(inventory.items) do total = total + count end
      return total
    end
    return inventory.items[name] or 0
  end
  function inventory.insert(stack)
    local count = math.min(stack.count, room_for(stack.name))
    if count > 0 then inventory.items[stack.name] = (inventory.items[stack.name] or 0) + count end
    return count
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
   - slots: size of the main inventory (default: unlimited)
   - crafting_queue: list of {recipe, count, prerequisite}
  Records: printed, crafted, selected_position, and walking_state /
  mining_state are plain fields.
]]
function Fakes.player(opts)
  opts = opts or {}
  local inventory = Fakes.inventory(opts.items, opts.slots)
  local player = {
    index = opts.index or 1,
    position = opts.position or { x = 0, y = 0 },
    surface = opts.surface or game.surfaces.nauvis,
    force = game.forces.player,
    character = { prototype = prototypes.entity["character"] },
    crafting_queue = opts.crafting_queue,
    crafting_queue_size = opts.crafting_queue and #opts.crafting_queue or 0,
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
  -- picks a real entity up: gone from the map, one item in the inventory
  player.mined = {}
  function player.mine_entity(entity, force)
    local name = entity.name
    entity.destroy()
    inventory.insert({ name = name, count = 1 })
    player.mined[#player.mined + 1] = name
    return true
  end
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
