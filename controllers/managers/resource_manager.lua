require 'util/logger'
require 'util/unreachable'

require 'ground_resource_source'
require 'tree_resource_source'
require 'craft_resource_source'

--[[
  ResourceManager decides where an item comes from:
   1. a built module that has the item ready in its output,
   2. the nearest thing on the map that drops it when mined by hand
      (ore, trees, rocks),
   3. hand-crafting,
   4. a built module that first needs fuel / time to produce it.
  Natural sources are looked up on demand, so depleted ore and felled trees
  never linger in a list.
]]
ResourceManager = {}
function ResourceManager:new (o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  o.sources = {}; -- module sources, registered when a module gets built
  return o
end

local log = Logger.makeLogger("ResourceManager");

local SEARCH_RADII = {32, 100, 250};

-- item name -> names of entities that drop it when mined by hand. Derived
-- from prototypes only, so it is safe to keep outside of storage.
local natural_sources;
local function natural_sources_for(item)
  if(not natural_sources) then
    natural_sources = {};
    local candidates = prototypes.get_entity_filtered{
      {filter="type", type={"resource", "tree", "simple-entity"}}
    };
    for name, prototype in pairs(candidates) do
      local mineable = prototype.mineable_properties;
      if(mineable.minable and not mineable.required_fluid and mineable.products) then
        for i, product in pairs(mineable.products) do
          if(product.type == "item") then
            natural_sources[product.name] = natural_sources[product.name] or {};
            table.insert(natural_sources[product.name], name);
          end
        end
      end
    end
  end
  return natural_sources[item];
end

-- Ore under one of our own buildings can't be mined by hand: selecting that
-- spot would pick up the building instead.
local function is_covered(player, entity)
  if(entity.type ~= "resource") then
    return false;
  end
  for i, other in pairs(player.surface.find_entities_filtered{position=entity.position, force=player.force}) do
    if(other.type ~= "character") then
      return true;
    end
  end
  return false;
end

function ResourceManager:initialize(player)
  -- nothing to precompute any more, kept for callers
end

function ResourceManager:register_source(source)
  self.sources[#self.sources + 1] = source;
end

function ResourceManager:find_natural_source(player, type)
  local names = natural_sources_for(type);
  if(not names) then
    return nil;
  end
  local position = player.position;
  for i, radius in ipairs(SEARCH_RADII) do
    local found = player.surface.find_entities_filtered{name=names, position=position, radius=radius};
    if(#found > 0) then
      table.sort(found, function(a, b)
        return util.distance(position, a.position) < util.distance(position, b.position);
      end);
      for j, entity in ipairs(found) do
        if(not is_covered(player, entity) and not Unreachable.is(entity)) then
          if(entity.type == "resource") then
            return GroundResourceSource:new{entity=entity};
          end
          return TreeResourceSource:new{entity=entity};
        end
      end
    end
  end
  return nil;
end

function ResourceManager:module_source(type, ready_only)
  for i, source in ipairs(self.sources) do
    if(source:is_valid() and source:provides_type(type)) then
      if(not ready_only or source:has_output(type)) then
        return source;
      end
    end
  end
  return nil;
end

function ResourceManager:best_resource_source(player, type)
  local source = self:module_source(type, true)
    or self:find_natural_source(player, type);
  if(source) then
    return source;
  end
  local craft_source = CraftResourceSource:new{player=player}
  if(craft_source:provides_type(type)) then
    return craft_source;
  end
  return self:module_source(type, false);
end

-- Pushes the tasks to get `qty` of `type` in the inventory onto `machine`.
-- Returns false when nothing known can provide the item.
function ResourceManager:get_resources(player, type, qty, machine)
  local source = self:best_resource_source(player, type);
  if(not source) then
    return false;
  end
  source:gather{type=type, qty=qty, player=player, machine=machine}
  return true;
end
