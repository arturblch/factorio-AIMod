
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
