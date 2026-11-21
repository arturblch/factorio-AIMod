--[[
  Pickup (plan 4.13): what the bot's modules have made and the character
  can reach goes into its inventory on the way, so that the next craft or
  building finds it on hand instead of sending the bot back to the furnaces
  for a few plates. A gather takes only what it lacks (plan 4.11), so
  without this the bot walked to a column for the 10 copper plates of a
  batch of red packs, and back again for the plates of the next module.

  It costs no walking: AIMod.tick_bot looks every EVERY ticks (walking past
  a column, fuelling it, waiting by it), and CollectModuleOutputTask looks
  once it has what it came for. Of each item the inventory keeps no more
  than STACKS stacks, and FREE_SLOTS slots stay empty, so the bot doesn't
  end up making room (MakeRoomTask) for plates it took on the way. Not what
  plan 4.11 dropped: there GrowthTask walked to every half full output to
  empty it, 41 % of the bot's time after the tenth minute.

  What it took, by item, is counted in storage.pickup[player index] for
  /aimod-evaluation and the scenario runs.
]]
Pickup = {};

Pickup.EVERY = 10;      -- ticks between looks around
Pickup.STACKS = 2;      -- of each item, at most, in the inventory
Pickup.FREE_SLOTS = 10; -- empty slots left alone
-- modules whose first building is further away are skipped without a look
-- at their outputs (a module is a few tiles across, the reach 10 tiles)
local NEAR = 40;

-- How many more of `item` the inventory takes on the way.
function Pickup.room(player, item)
  local inventory = player.get_main_inventory();
  if(not inventory) then
    return 0;
  end
  local stack = prototypes.item[item].stack_size;
  local have = inventory.get_item_count(item);
  local partial = (stack - have % stack) % stack; -- what fits on the last stack
  local free = math.max(inventory.count_empty_stacks() - Pickup.FREE_SLOTS, 0);
  return math.max(0, math.min(Pickup.STACKS * stack - have, partial + free * stack));
end

local function near(player, module)
  local entity = module:entity(1);
  if(not entity) then
    return true;
  end
  local dx, dy = entity.position.x - player.position.x, entity.position.y - player.position.y;
  return dx * dx + dy * dy <= NEAR * NEAR;
end

-- Takes into the inventory what the outputs of the player's modules within
-- reach hold, up to Pickup.room of each item. Returns {item = count} taken.
function Pickup.sweep(player)
  local taken = {};
  local manager = storage.resource_managers and storage.resource_managers[player.index];
  if(not manager or not player.character) then
    return taken;
  end
  for i, source in ipairs(manager.sources or {}) do
    local module = source.module;
    if(module and source:is_valid() and near(player, module)) then
      local seen = {};
      for j, output in ipairs(module.outputs) do
        if(not seen[output.type]) then
          seen[output.type] = true;
          for k, found in ipairs(module:outputsForProduct(output.type)) do
            if(found.available > 0 and player.can_reach_entity(found.entity)) then
              local count = math.min(found.available, Pickup.room(player, output.type));
              local inserted = count > 0 and player.insert{name=output.type, count=count} or 0;
              if(inserted > 0) then
                found.inventory.remove{name=output.type, count=inserted};
                taken[output.type] = (taken[output.type] or 0) + inserted;
              end
            end
          end
        end
      end
    end
  end
  if(next(taken)) then
    storage.pickup = storage.pickup or {};
    local total = storage.pickup[player.index] or {};
    storage.pickup[player.index] = total;
    for item, count in pairs(taken) do
      total[item] = (total[item] or 0) + count;
    end
  end
  return taken;
end

function Pickup.tick(player)
  if(game.tick % Pickup.EVERY == 0) then
    Pickup.sweep(player);
  end
end

-- What was taken on the way so far, in a line.
function Pickup.line(player)
  local total = storage.pickup and storage.pickup[player.index] or {};
  local names = {};
  for name in pairs(total) do
    names[#names + 1] = name;
  end
  table.sort(names);
  local parts = {};
  for i, name in ipairs(names) do
    parts[#parts + 1] = name .. " " .. total[name];
  end
  return "picked up on the way: " .. (#parts > 0 and table.concat(parts, ", ") or "nothing");
end

return Pickup;
