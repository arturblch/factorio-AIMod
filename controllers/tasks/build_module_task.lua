require 'task'
require 'util'
require 'util/logger'
require 'controllers/tasks/build_building_task'
require 'controllers/tasks/craftRecipeTask'
require 'util/inventories'

--[[
  BuildModuleTask
  Finds a spot for a module (a small fixed layout of buildings), makes sure
  the buildings are in the inventory and then builds them.
   - module: BaseModule; the module to build
]]
BuildModuleTask = Task:new()
local log = Logger.makeLogger("BuildModuleTask");

function BuildModuleTask:achieved (args)
  return self.goal_set or self.failed;
end

function BuildModuleTask:toString()
  return "BuildModuleTask - " .. self.module.name;
end

local SEARCH_RADII = {100, 250};
local impassibleTiles = {
  "out-of-map",
  "deepwater",
  "deepwater-green",
  "water",
  "water-green"
};
local TILE_OFFSET = 0;
function BuildModuleTask:canBuildAtPosition(player, position)
  --for each item in the geometry, verify
  --  a) it's not water (unless it should be)
  --  b) it has the resource it needs (if it need one)
  --  c) none of our buildings is already there
  for i, item in pairs(self.module.geometry) do
    local offset = item.position;
    local offsetPosition = {x=position.x + offset.x + TILE_OFFSET, y=position.y + offset.y + TILE_OFFSET};
    local tile = player.surface.get_tile(offsetPosition.x, offsetPosition.y);
    for i, tileName in pairs(impassibleTiles) do
      if(tile.prototype.name == tileName) then
        if(i == 1) then return false end
        if(item.tile and item.tile == "water") then
          --continue
        else
          return false;
        end
      end
    end
    for i, entity in pairs(player.surface.find_entities_filtered{position=offsetPosition, force=player.force}) do
      if(entity.type ~= "character") then
        return false;
      end
    end
    if(item.resource ~= nil) then
      local entities = player.surface.find_entities_filtered{position=offsetPosition, type="resource"}
      local foundResource = false;
      for i, entity in pairs(entities) do
        if(entity.prototype.name == item.resource) then
          foundResource = true;
          break;
        elseif(entity.prototype.type == "resource") then
          return false;
        end
      end
      if(not foundResource) then
        return false;
      end
    end
  end
  return true;
end

-- Center of the module's geometry tile (0, 0), or nil.
function BuildModuleTask:findLocation(player)
  local origin = player.position;
  for i, radius in ipairs(SEARCH_RADII) do
    local resources = player.surface.find_entities_filtered{position=origin, radius=radius, name=self.module.resource}
    table.sort(resources, function(a, b)
      return util.distance(origin, a.position) < util.distance(origin, b.position);
    end)
    for j, resource in ipairs(resources) do
      local position = resource.position;
      if(self:canBuildAtPosition(player, position)) then
        return {x=position.x, y=position.y};
      end
    end
  end
  return nil;
end

function BuildModuleTask:tick (args)
  local player = args.player;

  if(not self.location) then
    if(self.module.resource == nil) then
      log("Don't know where to put " .. self.module.name .. ": it needs no resource", "ERROR");
      self.failed = true;
      return;
    end
    self.location = self:findLocation(player);
    if(not self.location) then
      log("Cannot build " .. self.module.name .. ": no suitable " .. self.module.resource ..
        " spot within " .. SEARCH_RADII[#SEARCH_RADII] .. " tiles", "WARN");
      player.print("AIMod: no place to build " .. self.module.name);
      self.failed = true;
      return;
    end
    log("Building " .. self.module.name .. " at " .. self.location.x .. ", " .. self.location.y, "INFO");
  end

  -- get the buildings first, the spot is reserved in self.location
  local required_buildings = {};
  for i, building in pairs(self.module.buildings) do
    required_buildings[building.type] = (required_buildings[building.type] or 0) + 1;
  end
  local missing = false;
  for type, count in pairs(required_buildings) do
    local inv_count = Inventories.total_craftable_count(player, type);
    if(inv_count < count) then
      local required_count = count - inv_count;
      log("We require " .. required_count .. " more " .. type .. " for this module", "INFO");
      args.machine:pushSingle(CraftRecipeTask:new{recipe=type, qty=required_count});
      missing = true;
    end
  end
  if(missing) then
    return;
  end

  -- Geometry offsets are tile centers relative to tile (0, 0); building
  -- offsets are entity centers relative to that tile's top-left corner, so a
  -- 2x2 building at {x=1, y=1} covers geometry tiles 0..1 x 0..1.
  local corner = {x=math.floor(self.location.x), y=math.floor(self.location.y)};
  local tasks = {};
  for i, building in pairs(self.module.buildings) do
    local building_position = {x=corner.x + building.position.x, y=corner.y + building.position.y};
    tasks[#tasks + 1] = BuildBuildingTask:new{type=building.type,
                                              building=building,
                                              position=building_position,
                                              direction=building.direction or defines.direction.north}
  end
  args.machine:pushStart(tasks);
  self.goal_set = true;
end
