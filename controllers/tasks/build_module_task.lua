require 'task'
require 'util'
require 'util/logger'
require 'controllers/tasks/build_building_task'
require 'controllers/tasks/craftRecipeTask'
require 'controllers/managers/module_resource_source'
require 'controllers/managers/research_resource_source'
require 'controllers/tasks/research_trigger_task'
require 'util/inventories'
require 'util/recipes'
require 'controllers/modules/library'
require 'controllers/modules/plan'

--[[
  BuildModuleTask
  Finds a spot for a module (a small fixed layout of buildings), makes sure
  the buildings are in the inventory and then builds them. A module that the
  buildings' materials depend on comes first (see foundation). If a building
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
  local done = self.built ~= nil and self.built:allPlaced();
  if(done and self.plan) then
    ModulePlan.clear(self.plan);
    self.plan = nil;
  end
  return done;
end

-- Remembers a module that couldn't be built, for the final message.
local function record_failure(player, name)
  storage.failed_goals = storage.failed_goals or {};
  local list = storage.failed_goals[player.index] or {};
  list[#list + 1] = name;
  storage.failed_goals[player.index] = list;
end

function BuildModuleTask:fail(player, message)
  ModulePlan.clear(self.plan);
  self.plan = nil;
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
    if(self.reuse and self.reuse[i]) then
      -- not ours to pick up: it belongs to another module
    elseif(entity and entity.valid) then
      player.mine_entity(entity, true); -- back into the inventory, fuel included
    else
      missing[#missing + 1] = building.type;
    end
  end
  storage.resource_managers[player.index]:unregister_source(self.source);
  ModulePlan.clear(self.plan);
  self.plan = nil;
  self.bad_spots = self.bad_spots or {};
  self.bad_spots[#self.bad_spots + 1] = self.location;
  self.attempts = (self.attempts or 0) + 1;
  log(self.module.name .. " at " .. self.location.x .. ", " .. self.location.y .. " is missing " ..
    table.concat(missing, ", ") .. " (attempt " .. self.attempts .. ")", "WARN");
  self.location, self.built, self.source, self.goal_set, self.reuse = nil, nil, nil, false, nil;
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

-- Until the build tasks are queued: the buildings (and what crafting the
-- missing ones takes) and the first round of fuel.
function BuildModuleTask:needs (args)
  if(self.failed or self.built) then
    return nil;
  end
  local player = args.player;
  local totals = {};
  local function add(name, amount)
    totals[name] = (totals[name] or 0) + amount;
  end
  local counts = {};
  for i, building in pairs(self.module.buildings) do
    if(not (self.reuse and self.reuse[i])) then
      counts[building.type] = (counts[building.type] or 0) + 1;
    end
  end
  for type, count in pairs(counts) do
    add(type, count);
    local missing = count - Inventories.count_with_queue(player, type);
    local recipe = player.force.recipes[type];
    if(missing > 0 and recipe) then
      for name, amount in pairs(Recipes.needed_totals(player, recipe, missing)) do
        add(name, amount);
      end
    end
  end
  for name, amount in pairs(self.module:fuelNeeds()) do
    add(name, amount);
  end
  return totals;
end

-- The module to build before this one, or nil: one that makes a raw material
-- of this module's buildings which only a module can make (iron plates for
-- drills) while no working module of ours makes it yet. Otherwise building
-- this module first would use up the drill and furnace that module takes:
-- the start has one of each and 8 iron plates, one short of a second drill.
-- Each is tried once; if it was given up on, this module goes ahead anyway.
function BuildModuleTask:foundation(player)
  local manager = storage.resource_managers[player.index];
  local seen = {};
  for i, building in pairs(self.module.buildings) do
    local recipe = not seen[building.type] and Recipes.handcraft_recipe_for(player.force, building.type);
    seen[building.type] = true;
    for item in pairs(recipe and Recipes.raw_items(player.force, recipe) or {}) do
      if(not ModuleLibrary.makes(self.module, item) and not ResourceManager.drops(item)
          and not manager:module_source(item, false)) then
        local producer = ModuleLibrary.producer(player, item);
        if(producer and not (self.foundations_tried or {})[producer.name]) then
          return producer;
        end
      end
    end
  end
  return nil;
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

-- Resources a drill of `prototype` standing at `center` would mine: those in
-- its mining area (which can be larger than the drill itself) whose category
-- it can mine.
local function resources_in_mining_area(surface, prototype, center)
  local radius = prototype.get_mining_drill_radius();
  local area = {{center.x - radius, center.y - radius}, {center.x + radius, center.y + radius}};
  local categories = prototype.resource_categories or {};
  local result = {};
  for i, resource in pairs(surface.find_entities_filtered{area=area, type="resource"}) do
    if(categories[resource.prototype.resource_category]) then
      result[#result + 1] = resource;
    end
  end
  return result;
end

-- A drill mines whatever lies in its mining area, one tile after another, so
-- a second resource type would end up in whatever the drill feeds (a furnace
-- with iron ore can't take stone; a drill can't burn iron ore) and stop the
-- module. Every drill of the module must have its own resource (the
-- building's `resource`, or the module's) under it and nothing else.
function BuildModuleTask:drillsMineOnlyTheirResource(surface, corner)
  for i, building in pairs(self.module.buildings) do
    local prototype = prototypes.entity[building.type];
    if(prototype and prototype.type == "mining-drill") then
      local expected = building.resource or self.module.resource;
      local center = {x=corner.x + building.position.x, y=corner.y + building.position.y};
      local resources = resources_in_mining_area(surface, prototype, center);
      if(#resources == 0) then
        return false;
      end
      for j, resource in ipairs(resources) do
        if(resource.name ~= expected) then
          return false;
        end
      end
    end
  end
  return true;
end

-- Whether a tile is water (or off the generated map: nothing to build on).
local function is_water(tile)
  return not tile.valid or tile.collides_with("water_tile");
end

function BuildModuleTask:canBuildAtPosition(player, position)
  --for each item in the geometry, verify
  --  a) it's dry land - or water where the module needs water (in front of
  --     an offshore pump), or either on the shore under the pump
  --  b) it has the resource it needs (if it need one)
  --  c) none of our buildings is already there
  --  d) no cliff runs through it (cliffs can't be cleared by hand)
  --then that no drill would mine a second kind of resource, and that the
  --game itself would take an offshore pump there
  for i, item in pairs(self.module.geometry) do
    local offset = item.position;
    local offsetPosition = {x=position.x + offset.x + TILE_OFFSET, y=position.y + offset.y + TILE_OFFSET};
    local tile = player.surface.get_tile(offsetPosition.x, offsetPosition.y);
    if(not tile.valid or tile.prototype.name == impassibleTiles[1]) then
      return false;
    end
    local water = is_water(tile);
    if(item.tile == "water") then
      if(not water) then return false end
    elseif(water and not item.shore) then
      return false;
    end
    for i, entity in pairs(player.surface.find_entities_filtered{position=offsetPosition, force=player.force}) do
      -- (a building of ours the module takes over stands where its own would)
      if(entity.type ~= "character" and not (self.reusing and self.reusing[entity.unit_number])) then
        return false;
      end
    end
    local tile_area = {{offsetPosition.x - 0.5, offsetPosition.y - 0.5}, {offsetPosition.x + 0.5, offsetPosition.y + 0.5}};
    if(player.surface.count_entities_filtered{area=tile_area, type="cliff", limit=1} > 0) then
      return false;
    end
    -- a module that mines nothing keeps off ore, which later modules mine
    if(self.module.resource == nil and player.surface.count_entities_filtered{area=tile_area, type="resource", limit=1} > 0) then
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
  -- same corner as in tick(): position is the center of geometry tile (0, 0)
  local corner = {x=math.floor(position.x), y=math.floor(position.y)};
  for i, building in pairs(self.module.buildings) do
    if(prototypes.entity[building.type].type == "offshore-pump") then
      -- the game's own rules for where a pump may stand (manual: as a player
      -- would place it, tile rules included)
      local at = {x=corner.x + building.position.x, y=corner.y + building.position.y};
      if(not player.surface.can_place_entity{name=building.type, position=at, force=player.force,
          direction=building.direction or defines.direction.north, build_check_type=defines.build_check_type.manual}) then
        return false;
      end
    end
  end
  return self:drillsMineOnlyTheirResource(player.surface, corner);
end

-- The module's first ore tile (top row first), relative to geometry tile
-- (0, 0): a found ore tile is tried as this one, so only the drills have to
-- stand on ore. A module whose corner is a furnace (the column FF|DDDD|FF)
-- otherwise needed ore two tiles wider than its drills.
function BuildModuleTask.anchor(module)
  local best;
  for i, tile in ipairs(module.geometry) do
    local p = tile.position;
    -- a power module's anchor is the water in front of its pump
    local wanted = module.power and tile.tile == "water" or (not module.power and tile.resource);
    if(wanted and (not best or p.y < best.y or (p.y == best.y and p.x < best.x))) then
      best = p;
    end
  end
  return best or {x=0, y=0};
end

-- Where to look for a spot: next to the nearest module of ours on the same
-- resource, so that modules go in rows along the patch instead of wherever
-- the player stands (shorter rounds to fuel and empty them); else around the
-- player.
function BuildModuleTask:searchOrigin(player)
  local manager = storage.resource_managers[player.index];
  local best, best_distance;
  for i, source in ipairs(manager and manager.sources or {}) do
    local module = source.module;
    -- a power module goes near the base: next to any module of ours
    local entity = module and (self.module.power or module.resource == self.module.resource) and module:entity(1);
    if(entity) then
      local distance = util.distance(player.position, entity.position);
      if(not best_distance or distance < best_distance) then
        best, best_distance = entity.position, distance;
      end
    end
  end
  return best or player.position;
end

-- Names of the tiles that are water.
local water_names;
local function water_tile_names()
  if(not water_names) then
    water_names = {};
    for name, tile in pairs(prototypes.tile) do
      if(tile.collision_mask.layers["water_tile"]) then
        water_names[#water_names + 1] = name;
      end
    end
  end
  return water_names;
end

-- Water tiles with land next to them, nearest `origin` first, as centers.
local function shore_tiles(surface, origin, radius)
  local result = {};
  for i, tile in pairs(surface.find_tiles_filtered{position=origin, radius=radius, name=water_tile_names()}) do
    local p = tile.position;
    for j, d in ipairs({{0, -1}, {1, 0}, {0, 1}, {-1, 0}}) do
      if(not is_water(surface.get_tile(p.x + d[1], p.y + d[2]))) then
        result[#result + 1] = {x=p.x + 0.5, y=p.y + 0.5};
        break;
      end
    end
  end
  table.sort(result, function(a, b) return util.distance(origin, a) < util.distance(origin, b); end);
  return result;
end

-- The module's first electric pole: its building index and prototype.
local function first_pole(module)
  for i, building in ipairs(module.buildings) do
    local prototype = prototypes.entity[building.type];
    if(prototype and prototype.type == "electric-pole") then
      return i, prototype;
    end
  end
  return nil;
end

-- A science module (module.packs) whose lab can be one of ours: the spot
-- where its own lab would stand on a lab we have (the power module's), so
-- the module's inserter feeds that one and its lab isn't built (self.reuse:
-- building index -> entity), with the module's pole in wire reach of one of
-- `poles`. Nil when no lab of ours has room around it.
function BuildModuleTask:findAtOurLab(player, poles, pole_offset, pole_prototype)
  if(not self.module.packs) then
    return nil;
  end
  local lab_index;
  for i, building in ipairs(self.module.buildings) do
    if(prototypes.entity[building.type].type == "lab") then lab_index = i; end
  end
  if(not lab_index) then
    return nil;
  end
  local lab_offset = self.module.buildings[lab_index].position;
  local labs = player.surface.find_entities_filtered{force=player.force, name=self.module.buildings[lab_index].type};
  table.sort(labs, function(a, b)
    return util.distance(player.position, a.position) < util.distance(player.position, b.position);
  end);
  for i, lab in ipairs(labs) do
    local corner = {x=math.floor(lab.position.x - lab_offset.x + 0.5), y=math.floor(lab.position.y - lab_offset.y + 0.5)};
    local position = {x=corner.x + 0.5, y=corner.y + 0.5};
    local pole_at = {x=corner.x + pole_offset.x, y=corner.y + pole_offset.y};
    local wired = false;
    for j, pole in ipairs(poles) do
      local reach = math.min(pole.prototype.get_max_wire_distance(), pole_prototype.get_max_wire_distance());
      wired = wired or util.distance(pole.position, pole_at) <= reach - 0.01;
    end
    self.reusing = {[lab.unit_number] = true};
    local fits = wired and not self:isBadSpot(position) and self:canBuildAtPosition(player, position);
    self.reusing = nil;
    if(fits) then
      self.reuse = {[lab_index] = lab};
      return position;
    end
  end
  return nil;
end

-- For a module that runs on our power (module.powered): the spot where its
-- first pole is as close as it can be to a pole of ours on a network, yet
-- within the wire reach of both, so the game wires them together. Our poles
-- nearest the player first.
function BuildModuleTask:findPoweredLocation(player)
  local index, prototype = first_pole(self.module);
  if(not index) then
    return nil;
  end
  local offset = self.module.buildings[index].position;
  local poles = {};
  for i, pole in pairs(player.surface.find_entities_filtered{force=player.force, type="electric-pole"}) do
    if(pole.electric_network_id) then poles[#poles + 1] = pole; end
  end
  table.sort(poles, function(a, b)
    return util.distance(player.position, a.position) < util.distance(player.position, b.position);
  end);
  local reused = self:findAtOurLab(player, poles, offset, prototype);
  if(reused) then
    return reused;
  end
  for i, pole in ipairs(poles) do
    local reach = math.min(pole.prototype.get_max_wire_distance(), prototype.get_max_wire_distance());
    local center = {x=math.floor(pole.position.x) + 0.5, y=math.floor(pole.position.y) + 0.5};
    local candidates = {};
    local r = math.floor(reach);
    for dx = -r, r do
      for dy = -r, r do
        local at = {x=center.x + dx, y=center.y + dy};
        local distance = util.distance(pole.position, at);
        if((dx ~= 0 or dy ~= 0) and distance <= reach - 0.01) then
          candidates[#candidates + 1] = {at=at, distance=distance};
        end
      end
    end
    table.sort(candidates, function(a, b)
      if(a.distance ~= b.distance) then return a.distance < b.distance; end
      if(a.at.y ~= b.at.y) then return a.at.y < b.at.y; end
      return a.at.x < b.at.x;
    end);
    for j, candidate in ipairs(candidates) do
      -- the pole's tile is corner + offset, the location the center of tile (0, 0)
      local position = {x=math.floor(candidate.at.x - offset.x) + 0.5, y=math.floor(candidate.at.y - offset.y) + 0.5};
      if(not self:isBadSpot(position) and self:canBuildAtPosition(player, position)) then
        return position;
      end
    end
  end
  return nil;
end

-- Center of the module's geometry tile (0, 0), or nil: the spot nearest the
-- search origin where it fits.
function BuildModuleTask:findLocation(player)
  if(self.module.powered and self.module.resource == nil) then
    return self:findPoweredLocation(player);
  end
  local origin = self:searchOrigin(player);
  local anchor = BuildModuleTask.anchor(self.module);
  if(self.module.power) then
    for i, radius in ipairs(SEARCH_RADII) do
      for j, water in ipairs(shore_tiles(player.surface, origin, radius)) do
        local position = {x=water.x - anchor.x, y=water.y - anchor.y};
        if(not self:isBadSpot(position) and self:canBuildAtPosition(player, position)) then
          return position;
        end
      end
    end
    return nil;
  end
  for i, radius in ipairs(SEARCH_RADII) do
    local resources = player.surface.find_entities_filtered{position=origin, radius=radius, name=self.module.resource}
    table.sort(resources, function(a, b)
      return util.distance(origin, a.position) < util.distance(origin, b.position);
    end)
    for j, resource in ipairs(resources) do
      local position = {x=resource.position.x - anchor.x, y=resource.position.y - anchor.y};
      if(not self:isBadSpot(position) and self:canBuildAtPosition(player, position)) then
        return position;
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
    local first = self:foundation(player);
    if(first) then
      log("Building " .. first.name .. " first: " .. self.module.name .. "'s buildings need what it makes", "INFO");
      self.foundations_tried = self.foundations_tried or {};
      self.foundations_tried[first.name] = true;
      args.machine:pushSingle(BuildModuleTask:new{module=first});
      return;
    end
    if(self.module.resource == nil and not self.module.powered) then
      self:fail(player, "don't know where to put " .. self.module.name .. ": it needs no resource");
      return;
    end
    self.location = self:findLocation(player);
    if(not self.location) then
      local where = self.module.resource and (self.module.resource .. " spot within " .. SEARCH_RADII[#SEARCH_RADII] .. " tiles")
        or "spot in wire reach of our poles";
      self:fail(player, "no place to build " .. self.module.name .. ": no suitable " .. where);
      return;
    end
    log("Building " .. self.module.name .. " at " .. self.location.x .. ", " .. self.location.y, "INFO");
    -- show the player what is about to stand there
    self.plan = ModulePlan.draw(self.module, self.location, player.surface);
  end

  -- get the buildings first, the spot is reserved in self.location
  local required_buildings = {};
  for i, building in pairs(self.module.buildings) do
    if(not (self.reuse and self.reuse[i])) then -- one of ours stands there already
      required_buildings[building.type] = (required_buildings[building.type] or 0) + 1;
    end
  end
  -- what is still in the hand-craft queue counts: it is crafted on the way
  -- to the spot, and PlaceBuildingTask waits for it if need be
  local missing = false;
  for type, count in pairs(required_buildings) do
    local inv_count = Inventories.count_with_queue(player, type);
    local recipe = player.force.recipes[type];
    if(inv_count < count and recipe and not recipe.enabled) then
      -- a locked recipe (the lab and the pole wait for electronics, which 10
      -- copper plates unlock): research it first, or CraftRecipeTask would
      -- wait for ever
      local tech = ResearchResourceSource.technology_for(player.force, type);
      if(not tech) then
        self:fail(player, "can't build " .. self.module.name .. ": the recipe of " .. type .. " is locked behind research");
        return;
      end
      log("Researching " .. tech .. " first: " .. self.module.name .. " needs " .. type, "INFO");
      args.machine:pushSingle(ResearchTriggerTask:new{tech=tech});
      return;
    end
    if(inv_count < count) then
      local required_count = count - inv_count;
      log("We require " .. required_count .. " more " .. type .. " for this module", "INFO");
      -- qty counts crafts: a belt craft makes two
      local recipe = prototypes.recipe[type];
      local per_craft = recipe and Recipes.product_amount(recipe, type) or 1;
      local crafts = math.ceil(required_count / math.max(per_craft, 1));
      args.machine:pushSingle(CraftRecipeTask:new{recipe=type, qty=crafts, background=true});
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
    local reused = self.reuse and self.reuse[i];
    if(reused and reused.valid) then
      building.entity = reused; -- ours already (the power module's lab)
    else
      local building_position = {x=corner.x + building.position.x, y=corner.y + building.position.y};
      tasks[#tasks + 1] = BuildBuildingTask:new{type=building.type,
                                                building=building,
                                                position=building_position,
                                                direction=building.direction or defines.direction.north}
    end
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
