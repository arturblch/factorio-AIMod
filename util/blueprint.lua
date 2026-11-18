--[[
  Blueprint: a Factorio blueprint string turned into module data
  (see controllers/modules/base_module.lua), so modules can be drawn in the
  game's own editor or taken from anywhere blueprints are shared instead of
  being written out tile by tile. blueprints/library.lua lists the ones the
  bot builds; tools/blueprint.js shows and makes strings outside the game.

  A string is "0" + base64(zlib(JSON)); helpers.decode_string and
  helpers.json_to_table read it (both work while control.lua loads).

  What the module data needs and the blueprint doesn't say is worked out
  from prototypes, by following the items:
   - a drill mines `resource` from its mining area (those tiles must be
     that ore, and only that, see 1.6) and drops it on whatever is at its
     drop position: a building, a belt, or the ground;
   - a belt carries what is on it to the belt in front (straight on or
     from the side), an underground belt to its exit, a splitter to both
     belts in front of it; a belt hands nothing to a building by itself;
   - an inserter takes from its pickup position (a belt, a furnace's
     result, a chest) and puts into its drop position; a burner inserter
     carrying fuel fuels itself from it;
   - a furnace smelts what it gets (fuel goes to its fuel slot);
   - outputs, where the bot takes the product: a furnace result no inserter
     takes away, a chest that gets something, or the fuel slots of drills
     fed coal by the module (keeping a few);
   - inputs: every burner the bot keeps fueled, i.e. that gets no fuel
     from the module; of those that do, the first gets fuel to start with.
  It also checks the layout (Blueprint.module's third result): errors make
  a blueprint useless as a module, warnings point at a weak layout.
]]
Blueprint = {};

local FUEL = "coal";
local KEEP_FUEL = 5; -- what fuel outputs leave in a drill fed by another
local BELTS = {["transport-belt"] = true, ["underground-belt"] = true, ["splitter"] = true};

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

-- The bounding box `area` (left_top / right_bottom, or an array of two
-- points) as numbers.
local function box(area)
  local a, b = area.left_top or area[1], area.right_bottom or area[2];
  return {x=a.x or a[1], y=a.y or a[2]}, {x=b.x or b[1], y=b.y or b[2]};
end

-- Tiles a building needs water on, as {x=, y=}: the areas of its tile
-- buildability rules that require water (an offshore pump: in front of it).
-- Without such a rule, the tile it faces.
local function water_tiles(prototype, position, direction)
  local result = {};
  for i, rule in pairs(prototype.tile_buildability_rules or {}) do
    local required = rule.required_tiles and rule.required_tiles.layers or {};
    if(required["water_tile"]) then
      local lt, rb = box(rule.area);
      local a, b = rotate(lt, direction), rotate(rb, direction);
      local x0, x1 = math.min(a.x, b.x), math.max(a.x, b.x);
      local y0, y1 = math.min(a.y, b.y), math.max(a.y, b.y);
      for x = math.floor(position.x + x0 + 0.01), math.ceil(position.x + x1 - 0.01) - 1 do
        for y = math.floor(position.y + y0 + 0.01), math.ceil(position.y + y1 - 0.01) - 1 do
          result[#result + 1] = {x=x, y=y};
        end
      end
    end
  end
  if(#result == 0) then
    local ahead = rotate({0, -1}, direction);
    result[1] = {x=math.floor(position.x + ahead.x), y=math.floor(position.y + ahead.y)};
  end
  return result;
end

-- Whether the building runs on the electric network: a consumer, or a
-- generator feeding it.
local function on_network(prototype)
  return prototype.electric_energy_source_prototype ~= nil or prototype.type == "generator";
end

local function names(set)
  local list = {};
  for name in pairs(set) do list[#list + 1] = name; end
  table.sort(list);
  return table.concat(list, ", ");
end

--[[
  Module data from `spec`:
   - name: string; the module's name
   - blueprint: string; a blueprint string
   - resource: string; what the drills mine (iron-ore, coal, stone, ...), or
     "water" for a power module: an offshore pump (geometry tiles it needs
     water on are marked `tile = "water"`, its own `shore = true`), boilers
     the bot fuels, generators and consumers on poles. It makes no items
     (`power = true`, no outputs).
   - product: string; (optional) checked to be among the outputs
  Returns the data for BaseModule:new and the checks {errors=, warnings=,
  flows=} (lists of strings), or nil and why not.
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
  local power = spec.resource == "water";
  local ore = not power and mined_item(spec.resource);
  if(not power and not ore) then
    return nil, "nothing to mine in " .. tostring(spec.resource);
  end

  -- where everything is, before moving the top left tile to 0, 0
  local parts = {};
  local x0, y0 = math.huge, math.huge;
  for i, entity in ipairs(entities) do
    local prototype = prototypes.entity[entity.name];
    if(not prototype) then
      return nil, "unknown entity " .. entity.name;
    end
    local part = {prototype=prototype, kind=prototype.type, position=entity.position,
                  direction=entity.direction or defines.direction.north, belt_end=entity.type};
    part.tiles = Blueprint.footprint(prototype, part.position, part.direction);
    if(part.kind == "mining-drill") then
      part.mines = mining_area(prototype, part.position);
    elseif(part.kind == "offshore-pump") then
      part.water = water_tiles(prototype, part.position, part.direction);
    end
    for j, area in ipairs({part.tiles, part.mines}) do
      x0, y0 = math.min(x0, area.x0), math.min(y0, area.y0);
    end
    for j, t in ipairs(part.water or {}) do
      x0, y0 = math.min(x0, t.x), math.min(y0, t.y);
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
    if(part.water) then
      -- the pump stands on the shore (its tiles may be water or land), with
      -- water in front of it
      for x = t.x0, t.x1 do
        for y = t.y0, t.y1 do
          geometry[key(x - x0, y - y0)].shore = true;
        end
      end
      for j, w in ipairs(part.water) do
        tile(w.x, w.y, nil);
        geometry[key(w.x - x0, w.y - y0)].tile = "water";
      end
    end
    local building = {type=part.prototype.name, position={x=part.position.x - x0, y=part.position.y - y0}};
    if(part.direction ~= defines.direction.north) then
      building.direction = part.direction;
    end
    if(part.belt_end) then
      building.belt_end = part.belt_end; -- underground belt: "input" or "output"
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
  local function label(i)
    return parts[i].prototype.name .. " " .. i;
  end

  local errors, warnings, flows = {}, {}, {};

  -- belts: where each one hands its items on
  for i, part in ipairs(parts) do
    if(BELTS[part.kind]) then
      local ahead = rotate({0, -1}, part.direction);
      part.next = {};
      local function onto(position)
        local j = at(position);
        if(j and j ~= i and BELTS[parts[j].kind]) then
          part.next[#part.next + 1] = j;
        end
      end
      if(part.kind == "underground-belt" and part.belt_end == "input") then
        for d = 1, (part.prototype.max_underground_distance or 5) + 1 do
          local j = at({x=part.position.x + ahead.x * d, y=part.position.y + ahead.y * d});
          if(j and parts[j].kind == "underground-belt" and parts[j].belt_end == "output" and parts[j].direction == part.direction) then
            part.next[#part.next + 1] = j;
            break;
          end
        end
      elseif(part.kind == "splitter") then
        local side = rotate({1, 0}, part.direction);
        for s = -0.5, 0.5, 1 do
          onto({x=part.position.x + side.x * s + ahead.x, y=part.position.y + side.y * s + ahead.y});
        end
      else
        onto({x=part.position.x + ahead.x, y=part.position.y + ahead.y});
      end
    end
  end

  -- follow the items until nothing changes
  local carries = {};  -- belt index -> {item = true}
  local receives = {}; -- building index -> {item = true}
  local taken_from = {}; -- building index -> true when an inserter takes from it
  local function add(set_of, i, item)
    set_of[i] = set_of[i] or {};
    if(set_of[i][item]) then return false; end
    set_of[i][item] = true;
    return true;
  end
  -- what an inserter can take out of building i
  local function available(i)
    local part, result = parts[i], {};
    if(BELTS[part.kind]) then
      for item in pairs(carries[i] or {}) do result[item] = true; end
    elseif(part.kind == "furnace") then
      for item in pairs(receives[i] or {}) do
        local product = smelted(part.prototype, item);
        if(product) then result[product] = true; end
      end
    elseif(part.kind == "container") then
      for item in pairs(receives[i] or {}) do result[item] = true; end
    end
    return result;
  end
  local function deliver(i, item)
    if(BELTS[parts[i].kind]) then
      return add(carries, i, item);
    end
    return add(receives, i, item);
  end

  for i, part in ipairs(parts) do
    if(part.kind == "mining-drill" and power) then
      errors[#errors + 1] = label(i) .. ": a power module mines nothing";
    elseif(part.kind == "mining-drill") then
      local j = at(offset(part, part.prototype.vector_to_place_result));
      part.drops_into = j;
      if(not j or j == i) then
        errors[#errors + 1] = label(i) .. " drops its " .. ore .. " on the ground";
      else
        flows[#flows + 1] = label(i) .. " -> " .. label(j);
      end
    elseif(part.kind == "inserter") then
      part.from = at(offset(part, part.prototype.inserter_pickup_position));
      part.to = at(offset(part, part.prototype.inserter_drop_position));
      if(not part.from or part.from == i) then
        errors[#errors + 1] = label(i) .. " has nothing to take from";
      elseif(not part.to or part.to == i) then
        errors[#errors + 1] = label(i) .. " has nowhere to put things";
      else
        taken_from[part.from] = true;
        flows[#flows + 1] = label(i) .. ": " .. label(part.from) .. " -> " .. label(part.to);
      end
    end
  end
  local changed, rounds = true, 0;
  while(changed and rounds < 100) do
    changed, rounds = false, rounds + 1;
    for i, part in ipairs(parts) do
      if(part.kind == "mining-drill" and part.drops_into and part.drops_into ~= i) then
        changed = deliver(part.drops_into, ore) or changed;
      elseif(part.kind == "inserter" and part.from and part.to and part.from ~= part.to) then
        for item in pairs(available(part.from)) do
          changed = deliver(part.to, item) or changed;
          if(is_fuel(item)) then
            changed = add(receives, i, item) or changed; -- a burner inserter fuels itself from what it carries
          end
        end
      elseif(part.next) then
        for item in pairs(carries[i] or {}) do
          for k, j in ipairs(part.next) do
            changed = add(carries, j, item) or changed;
          end
        end
      end
    end
  end

  -- outputs: where the bot takes the product
  local outputs, fed = {}, {};
  for i, part in ipairs(parts) do
    local items = receives[i] or {};
    if(part.kind == "furnace") then
      local made = {};
      for item in pairs(items) do
        local product = smelted(part.prototype, item);
        if(product) then made[product] = true; end
      end
      if(not next(made)) then
        warnings[#warnings + 1] = label(i) .. " gets nothing to smelt";
      elseif(not taken_from[i]) then
        for product in pairs(made) do
          outputs[#outputs + 1] = {building=i, type=product, slot="output"};
        end
      end
    elseif(part.kind == "container") then
      for item in pairs(items) do
        outputs[#outputs + 1] = {building=i, type=item, slot="output"};
      end
    elseif(part.kind == "mining-drill" and part.prototype.burner_prototype and items[FUEL]) then
      outputs[#outputs + 1] = {building=i, type=FUEL, slot="fuel", keep=KEEP_FUEL};
    end
    if(part.prototype.burner_prototype and items[FUEL]) then
      fed[i] = true;
    end
  end
  table.sort(outputs, function(a, b)
    if(a.building ~= b.building) then return a.building < b.building; end
    return a.type < b.type;
  end);

  -- belts: carrying nothing, or ending with no one taking from them
  for i, part in ipairs(parts) do
    if(part.next) then
      if(not carries[i]) then
        warnings[#warnings + 1] = label(i) .. " carries nothing";
      elseif(#part.next == 0) then
        local someone = false;
        -- an inserter anywhere along the way takes from this line?
        for j, other in ipairs(parts) do
          if(other.kind == "inserter" and other.from and parts[other.from].next and carries[other.from]) then
            for item in pairs(carries[i]) do
              someone = someone or carries[other.from][item];
            end
          end
        end
        if(not someone) then
          warnings[#warnings + 1] = label(i) .. " ends with " .. names(carries[i]) .. " that no inserter takes";
        end
      end
    end
  end

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

  if(power) then
    -- water in, power out: a pump, something that makes power, poles reaching
    -- every generator and consumer
    local kinds = {};
    for i, part in ipairs(parts) do kinds[part.kind] = true; end
    if(not kinds["offshore-pump"]) then
      errors[#errors + 1] = "a power module needs an offshore pump";
    end
    if(not kinds["generator"]) then
      errors[#errors + 1] = "a power module needs a generator (a steam engine)";
    end
    for i, part in ipairs(parts) do
      if(on_network(part.prototype)) then
        local covered = false;
        for j, pole in ipairs(parts) do
          if(pole.kind == "electric-pole") then
            local d = pole.prototype.get_supply_area_distance();
            covered = covered or (part.tiles.x0 < pole.position.x + d and part.tiles.x1 + 1 > pole.position.x - d and
                                  part.tiles.y0 < pole.position.y + d and part.tiles.y1 + 1 > pole.position.y - d);
          end
        end
        if(not covered) then
          warnings[#warnings + 1] = label(i) .. " is out of reach of the poles";
        end
      end
    end
  elseif(#outputs == 0) then
    errors[#errors + 1] = "nothing ends where the bot can take it (a furnace's result, a chest)";
  end
  if(spec.product) then
    local found = false;
    for i, output in ipairs(outputs) do
      found = found or output.type == spec.product;
    end
    if(not found) then
      return nil, "it makes no " .. spec.product, {errors=errors, warnings=warnings, flows=flows};
    end
  end
  return {name=spec.name, resource=spec.resource, geometry=tiles, buildings=buildings, inputs=inputs, outputs=outputs,
          power=power or nil, label=blueprint.label}, nil, {errors=errors, warnings=warnings, flows=flows};
end

return Blueprint;
