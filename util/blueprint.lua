--[[
  Blueprint: a Factorio blueprint string turned into module data
  (see controllers/modules/base_module.lua), so modules can be drawn in the
  game's own editor or taken from anywhere blueprints are shared instead of
  being written out tile by tile. blueprints/library.lua lists the ones the
  bot builds; tools/blueprint.js shows and makes strings outside the game.

  A string is "0" + base64(zlib(JSON)); helpers.decode_string and
  helpers.json_to_table read it (both work while control.lua loads).

  What the module data needs and the blueprint doesn't say is worked out
  from prototypes:
   - geometry: every tile the buildings cover, and the mining area of each
     drill, which has to be `resource` (nothing else, see 1.6);
   - who hands what to whom: a drill drops into whatever is at its drop
     position, an inserter moves from its pickup to its drop position;
   - outputs, where the bot takes the product: a furnace's result slot (or
     the chest an inserter empties it into), a chest a drill fills, or the
     fuel slots of drills that feed each other coal (keeping a few);
   - inputs: every burner the bot keeps fueled; of drills that fuel each
     other, only the first gets fuel to start with.
]]
Blueprint = {};

local FUEL = "coal";
local KEEP_FUEL = 5; -- what fuel outputs leave in a drill fed by another

-- The blueprint table inside `text`, or nil and why not.
function Blueprint.decode(text)
  text = (text or ""):gsub("%s", "");
  if(text:sub(1, 1) ~= "0") then
    return nil, "not a blueprint string (they start with 0)";
  end
  local json = helpers.decode_string(text:sub(2));
  local data = json and helpers.json_to_table(json);
  if(not data) then
    return nil, "can't decode it";
  end
  if(not data.blueprint) then
    return nil, "not a single blueprint (a book?)";
  end
  return data.blueprint;
end

-- `v` turned by `direction` (a defines.direction, 16 to a full turn).
local function rotate(v, direction)
  local x, y = v.x or v[1], v.y or v[2];
  for i = 1, math.floor((direction or 0) / 4) % 4 do
    x, y = -y, x;
  end
  return {x=x, y=y};
end

local function size(prototype, direction)
  local w, h = prototype.tile_width, prototype.tile_height;
  if(direction == defines.direction.east or direction == defines.direction.west) then
    w, h = h, w;
  end
  return w, h;
end

-- Tiles x0..x1, y0..y1 an entity at `position` covers.
function Blueprint.footprint(prototype, position, direction)
  local w, h = size(prototype, direction);
  local x0 = math.floor(position.x - w / 2 + 0.5);
  local y0 = math.floor(position.y - h / 2 + 0.5);
  return {x0=x0, y0=y0, x1=x0 + w - 1, y1=y0 + h - 1};
end

local function mining_area(prototype, position)
  local r = prototype.mining_drill_radius;
  return {x0=math.floor(position.x - r), y0=math.floor(position.y - r),
          x1=math.ceil(position.x + r) - 1, y1=math.ceil(position.y + r) - 1};
end

-- The item mining `resource` gives.
local function mined_item(resource)
  local prototype = prototypes.entity[resource];
  for i, product in pairs(prototype and prototype.mineable_properties.products or {}) do
    if(product.type == "item") then
      return product.name;
    end
  end
  return nil;
end

-- What a furnace makes of `item`, or nil.
local function smelted(furnace, item)
  for name, recipe in pairs(prototypes.recipe) do
    local ingredient = recipe.ingredients[1];
    if(#recipe.ingredients == 1 and ingredient.type == "item" and ingredient.name == item) then
      for category in pairs(furnace.crafting_categories or {}) do
        if(recipe.has_category(category)) then
          for j, product in pairs(recipe.products) do
            if(product.type == "item") then
              return product.name;
            end
          end
        end
      end
    end
  end
  return nil;
end

local function is_fuel(item)
  local prototype = prototypes.item[item];
  return prototype ~= nil and prototype.fuel_value > 0;
end

--[[
  Module data from `spec`:
   - name: string; the module's name
   - blueprint: string; a blueprint string
   - resource: string; what the drills mine (iron-ore, coal, stone, ...)
   - product: string; (optional) checked to be among the outputs
  Returns the data for BaseModule:new, or nil and why not.
]]
function Blueprint.module(spec)
  local blueprint, problem = Blueprint.decode(spec.blueprint);
  if(not blueprint) then
    return nil, problem;
  end
  local entities = {};
  for i, entity in pairs(blueprint.entities or {}) do
    entities[#entities + 1] = entity;
  end
  table.sort(entities, function(a, b) return a.entity_number < b.entity_number; end);
  if(#entities == 0) then
    return nil, "the blueprint has no entities";
  end

  -- where everything is, before moving the top left tile to 0, 0
  local parts = {};
  local x0, y0 = math.huge, math.huge;
  for i, entity in ipairs(entities) do
    local prototype = prototypes.entity[entity.name];
    if(not prototype) then
      return nil, "unknown entity " .. entity.name;
    end
    local part = {prototype=prototype, position=entity.position, direction=entity.direction or defines.direction.north};
    part.tiles = Blueprint.footprint(prototype, part.position, part.direction);
    if(prototype.type == "mining-drill") then
      part.mines = mining_area(prototype, part.position);
    end
    for j, area in ipairs({part.tiles, part.mines}) do
      x0, y0 = math.min(x0, area.x0), math.min(y0, area.y0);
    end
    parts[i] = part;
  end

  local tile_owner = {}; -- "x,y" -> index of the building on that tile
  local geometry = {};   -- "x,y" -> geometry entry
  local function key(x, y) return x .. "," .. y; end
  local function tile(x, y, resource)
    local k = key(x - x0, y - y0);
    local entry = geometry[k] or {position={x=x - x0, y=y - y0}};
    entry.resource = entry.resource or resource;
    geometry[k] = entry;
  end
  local buildings = {};
  for i, part in ipairs(parts) do
    local t = part.tiles;
    for x = t.x0, t.x1 do
      for y = t.y0, t.y1 do
        tile(x, y, nil);
        tile_owner[key(x, y)] = i;
      end
    end
    if(part.mines) then
      for x = part.mines.x0, part.mines.x1 do
        for y = part.mines.y0, part.mines.y1 do
          tile(x, y, spec.resource);
        end
      end
    end
    local building = {type=part.prototype.name, position={x=part.position.x - x0, y=part.position.y - y0}};
    if(part.direction ~= defines.direction.north) then
      building.direction = part.direction;
    end
    buildings[i] = building;
  end
  local function at(position)
    return tile_owner[key(math.floor(position.x), math.floor(position.y))];
  end
  local function offset(part, vector)
    local v = rotate(vector, part.direction);
    return {x=part.position.x + v.x, y=part.position.y + v.y};
  end

  -- who hands what to whom
  local ore = mined_item(spec.resource);
  if(not ore) then
    return nil, "nothing to mine in " .. tostring(spec.resource);
  end
  local receives = {}; -- index -> {item = true} delivered by the module itself
  local made = {};     -- index -> item the building makes (furnaces)
  local moved = {};    -- index of a building an inserter empties -> index of where it goes
  for i, part in ipairs(parts) do
    if(part.mines) then
      local j = at(offset(part, part.prototype.vector_to_place_result));
      if(j and j ~= i) then
        receives[j] = receives[j] or {};
        receives[j][ore] = true;
      end
    end
  end
  for j, items in pairs(receives) do
    if(parts[j].prototype.type == "furnace") then
      for item in pairs(items) do
        made[j] = made[j] or smelted(parts[j].prototype, item);
      end
    end
  end
  for i, part in ipairs(parts) do
    if(part.prototype.type == "inserter") then
      local from = at(offset(part, part.prototype.inserter_pickup_position));
      local to = at(offset(part, part.prototype.inserter_drop_position));
      if(from and to and from ~= to) then
        moved[from] = to;
      end
    end
  end

  local outputs, fed = {}, {};
  for i, part in ipairs(parts) do
    local p = part.prototype;
    local items = receives[i] or {};
    if(made[i]) then
      outputs[#outputs + 1] = {building=moved[i] or i, type=made[i], slot="output"};
    elseif(p.type == "container") then
      for item in pairs(items) do
        outputs[#outputs + 1] = {building=i, type=item, slot="output"};
      end
    elseif(p.burner_prototype and items[FUEL] and is_fuel(FUEL)) then
      fed[i] = true;
      outputs[#outputs + 1] = {building=i, type=FUEL, slot="fuel", keep=KEEP_FUEL};
    end
  end
  table.sort(outputs, function(a, b) return a.building < b.building; end);

  local inputs = {};
  local started = false;
  for i, part in ipairs(parts) do
    if(part.prototype.burner_prototype) then
      if(not fed[i]) then
        inputs[#inputs + 1] = {building=i, type=FUEL, slot="fuel", ongoing=true};
      elseif(not started) then
        -- the module fuels the others from it once it runs
        started = true;
        inputs[#inputs + 1] = {building=i, type=FUEL, slot="fuel", ongoing=false};
      end
    end
  end

  local tiles = {};
  for k, entry in pairs(geometry) do
    tiles[#tiles + 1] = entry;
  end
  table.sort(tiles, function(a, b)
    if(a.position.x ~= b.position.x) then return a.position.x < b.position.x; end
    return a.position.y < b.position.y;
  end);

  if(spec.product) then
    local found = false;
    for i, output in ipairs(outputs) do
      found = found or output.type == spec.product;
    end
    if(not found) then
      return nil, "it makes no " .. spec.product;
    end
  end
  return {name=spec.name, resource=spec.resource, geometry=tiles, buildings=buildings, inputs=inputs, outputs=outputs,
          label=blueprint.label};
end

return Blueprint;
