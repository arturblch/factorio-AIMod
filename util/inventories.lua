require 'util/recipes'

Inventories = {};

-- The quickbar stopped being a separate inventory in 0.17, so the character's
-- main inventory is the only place items live now.
local inventory_types = {
  defines.inventory.character_main
};

function Inventories.get_all_inventories(player)
  local result = {};
  for i, type in pairs(inventory_types) do
    result[#result + 1] = player.get_inventory(type);
  end
  return result;
end

function Inventories.total_craftable_count(player, item_type)
  local inventories = Inventories.get_all_inventories(player)
  local result = 0;
  for i, inventory in pairs(inventories) do
    result = result + inventory.get_item_count(item_type);
  end

  return result;
end

-- What is in the inventory plus what the hand-craft queue will still add.
function Inventories.count_with_queue(player, item_type)
  return Inventories.total_craftable_count(player, item_type) + Recipes.queued_count(player, item_type);
end

-- Whether one more `item_type` fits into the main inventory. With a full
-- inventory the character's mining bar keeps filling up but nothing is ever
-- mined or dropped, so the bot has to check before it mines.
function Inventories.has_room_for(player, item_type)
  return player.get_main_inventory().can_insert{name=item_type, count=1};
end

-- Whether all of `items` ({name=, count=} each) fit into the main inventory
-- at once. A rock drops stone and coal, and the game only mines it when
-- everything it drops fits: one free slot isn't enough even though either
-- item alone would fit. Stacks are assumed merged, which can only
-- underestimate the room left in them.
function Inventories.has_room_for_all(player, items)
  local inventory = player.get_main_inventory();
  local slots = 0;
  for i, item in ipairs(items) do
    local size = prototypes.item[item.name].stack_size;
    local partial = inventory.get_item_count(item.name) % size;
    local room_in_stacks = partial > 0 and (size - partial) or 0;
    slots = slots + math.ceil(math.max(0, item.count - room_in_stacks) / size);
  end
  return inventory.count_empty_stacks() >= slots;
end
