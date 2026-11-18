require 'util/blueprint'

--[[
  ModulePlan: draws a module where it is going to stand, so a player can see
  what the bot is about to build. BuildModuleTask draws it once it has picked
  the spot and removes it when the module stands or the spot is given up;
  /aimod-plan draws one for a minute (control.lua).

  On the ground: the ore tiles the drills need, in the ore's map colour;
  over them each building as a translucent box with its icon, a line for the
  way drills and inserters face, an outline round the module and its name.
  Only rendering objects: nothing on the map changes.
]]
ModulePlan = {};

local BUILDING_COLOR = {r=0.3, g=0.8, b=1, a=0.3};
local OUTLINE_COLOR = {r=0.3, g=0.8, b=1, a=0.9};
local ORE_ALPHA = 0.35;

-- The ore's map colour, translucent. map_color comes in 0..255, and a colour
-- with any part above 1 is read that way whole, alpha too: scale it down.
local function ore_color(resource)
  local prototype = prototypes.entity[resource or ""];
  local color = prototype and prototype.map_color or {r=128, g=128, b=128};
  local scale = (color.r > 1 or color.g > 1 or color.b > 1) and 255 or 1;
  local r, g, b = color.r / scale, color.g / scale, color.b / scale;
  if(r + g + b < 0.3) then
    r, g, b = 0.25, 0.25, 0.25; -- coal is black on the map, lighter here or it can't be seen
  end
  return {r=r, g=g, b=b, a=ORE_ALPHA};
end

-- The way an entity facing `direction` looks, as a unit vector.
local function facing(direction)
  local x, y = 0, -1;
  for i = 1, math.floor((direction or 0) / 4) % 4 do
    x, y = -y, x;
  end
  return x, y;
end

-- Draws `module` with its tile (0, 0) at `location` on `surface`. Returns the
-- rendering objects; `time_to_live` (ticks, optional) removes them by itself.
function ModulePlan.draw(module, location, surface, time_to_live)
  local corner = {x=math.floor(location.x), y=math.floor(location.y)};
  local objects = {};
  local function add(object) objects[#objects + 1] = object; end
  local common = {surface=surface, time_to_live=time_to_live};
  local function with(fields)
    for k, v in pairs(common) do fields[k] = v; end
    return fields;
  end

  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge;
  for i, tile in ipairs(module.geometry) do
    local x, y = corner.x + tile.position.x, corner.y + tile.position.y;
    x0, y0, x1, y1 = math.min(x0, x), math.min(y0, y), math.max(x1, x + 1), math.max(y1, y + 1);
    if(tile.resource) then
      add(rendering.draw_rectangle(with{color=ore_color(tile.resource), filled=true, draw_on_ground=true,
        left_top={x, y}, right_bottom={x + 1, y + 1}}));
    end
  end
  for i, building in ipairs(module.buildings) do
    local prototype = prototypes.entity[building.type];
    local center = {x=corner.x + building.position.x, y=corner.y + building.position.y};
    local tiles = Blueprint.footprint(prototype, center, building.direction or defines.direction.north);
    add(rendering.draw_rectangle(with{color=BUILDING_COLOR, filled=true,
      left_top={tiles.x0 + 0.05, tiles.y0 + 0.05}, right_bottom={tiles.x1 + 0.95, tiles.y1 + 0.95}}));
    add(rendering.draw_sprite(with{sprite="entity/" .. building.type, target=center, x_scale=0.6, y_scale=0.6}));
    if(prototype.type == "mining-drill" or prototype.type == "inserter") then
      local dx, dy = facing(building.direction);
      add(rendering.draw_line(with{color=OUTLINE_COLOR, width=3, from=center,
        to={x=center.x + dx * 0.8, y=center.y + dy * 0.8}}));
    end
  end
  add(rendering.draw_rectangle(with{color=OUTLINE_COLOR, width=2, filled=false,
    left_top={x0, y0}, right_bottom={x1, y1}}));
  add(rendering.draw_text(with{text=module.name, color=OUTLINE_COLOR, target={x=(x0 + x1) / 2, y=y0 - 0.8},
    alignment="center", scale=1.2}));
  return objects;
end

function ModulePlan.clear(objects)
  for i, object in ipairs(objects or {}) do
    if(object.valid) then
      object.destroy();
    end
  end
end

return ModulePlan;
