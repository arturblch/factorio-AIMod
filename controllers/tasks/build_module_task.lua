require 'task'
require 'util'
require 'util/logger'
require 'controllers/tasks/build_building_task'
require 'controllers/tasks/craftRecipeTask'
require 'controllers/managers/module_resource_source'
require 'util/inventories'

--[[
  BuildModuleTask
  Finds a spot for a module (a small fixed layout of buildings), makes sure
  the buildings are in the inventory and then builds them. If a building
  couldn't be placed, the ones that were are picked up again and the module
  is tried at another spot, MAX_ATTEMPTS times in all.
   - module: BaseModule; the module to build
]]
BuildModuleTask = Task:new()
local log = Logger.makeLogger("BuildModuleTask");

local MAX_ATTEMPTS = 3;
local BAD_SPOT_RADIUS = 8; -- don't retry closer than this to a spot that failed

-- Done once every building of the module stands, or when it gave up.
-- (Only checked when this task is on top again, i.e. after the build tasks.)
function BuildModuleTask:achieved (args)
  if(self.failed) then
    return true;
  end
  return self.built ~= nil and self.built:allPlaced();
end

-- Remembers a module that couldn't be built, for the final message.
local function record_failure(player, name)
  storage.failed_goals = storage.failed_goals or {};
  local list = storage.failed_goals[player.index] or {};
  list[#list + 1] = name;
  storage.failed_goals[player.index] = list;
end

function BuildModuleTask:fail(player, message)
  log(message, "WARN");
  player.print("AIMod: " .. message);
  record_failure(player, self.module.name);
  self.failed = true;
end

-- Called when the build tasks are done but a building is missing.
function BuildModuleTask:retryElsewhere(player)
  local missing = {};
  for i, building in ipairs(self.built.buildings) do
    local entity = building.entity;
    if(entity and entity.valid) then
      player.mine_entity(entity, true); -- back into the inventory, fuel included
    else
      missing[#missing + 1] = building.type;
    end
  end
  storage.resource_managers[player.index]:unregister_source(self.source);
  self.bad_spots = self.bad_spots or {};
  self.bad_spots[#self.bad_spots + 1] = self.location;
  self.attempts = (self.attempts or 0) + 1;
  log(self.module.name .. " at " .. self.location.x .. ", " .. self.location.y .. " is missing " ..
    table.concat(missing, ", ") .. " (attempt " .. self.attempts .. ")", "WARN");
  self.location, self.built, self.source, self.goal_set = nil, nil, nil, false;
  if(self.attempts >= MAX_ATTEMPTS) then
    self:fail(player, "could not build " .. self.module.name .. " after " .. self.attempts .. " attempts");
  end
end

function BuildModuleTask:isBadSpot(position)
  for i, spot in ipairs(self.bad_spots or {}) do
    if(util.distance(spot, position) < BAD_SPOT_RADIUS) then
      return true;
    end
  end
  return false;
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
  --  d) no cliff runs through it (cliffs can't be cleared by hand)
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
    local tile_area = {{offsetPosition.x - 0.5, offsetPosition.y - 0.5}, {offsetPosition.x + 0.5, offsetPosition.y + 0.5}};
    if(player.surface.count_entities_filtered{area=tile_area, type="cliff", limit=1} > 0) then
      return false;
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
      if(not self:isBadSpot(position) and self:canBuildAtPosition(player, position)) then
        return {x=position.x, y=position.y};
      end
    end
  end
  return nil;
end

function BuildModuleTask:tick (args)
  local player = args.player;

  if(self.built) then
    -- the build tasks are done but achieved() said a building is missing
    self:retryElsewhere(player);
    return;
  end

  if(not self.location) then
    if(self.module.resource == nil) then
      self:fail(player, "don't know where to put " .. self.module.name .. ": it needs no resource");
      return;
    end
    self.location = self:findLocation(player);
    if(not self.location) then
      self:fail(player, "no place to build " .. self.module.name .. ": no suitable " ..
        self.module.resource .. " spot within " .. SEARCH_RADII[#SEARCH_RADII] .. " tiles");
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
  local module = self.module:instantiate();
  local corner = {x=math.floor(self.location.x), y=math.floor(self.location.y)};
  local tasks = {};
  for i, building in pairs(module.buildings) do
    local building_position = {x=corner.x + building.position.x, y=corner.y + building.position.y};
    tasks[#tasks + 1] = BuildBuildingTask:new{type=building.type,
                                              building=building,
                                              position=building_position,
                                              direction=building.direction or defines.direction.north}
  end
  -- light it up right away so it produces while the bot does other things
  for i, task in ipairs(module:startTasks()) do
    tasks[#tasks + 1] = task;
  end
  args.machine:pushStart(tasks);
  -- not usable until every building stands (see ModuleResourceSource:is_valid)
  self.source = ModuleResourceSource:new{module=module};
  storage.resource_managers[player.index]:register_source(self.source);
  self.built = module;
  self.goal_set = true;
end
