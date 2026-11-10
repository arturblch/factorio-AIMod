--[[
  A separate surface for tests that need real terrain and entities. Lab.reset()
  turns the area around the origin into flat grass with nothing on it; tests
  then place exactly the ore, water and buildings they need.
]]
local Lab = {}
local NAME = "aimod-lab"
local HALF = 40 -- the managed area is [-HALF, HALF) on both axes

function Lab.surface()
  local surface = game.surfaces[NAME]
  if not surface then
    -- a small map with no ore, trees, rocks, cliffs or enemies anywhere, so
    -- searches that look far beyond the managed area find nothing either
    local settings = game.surfaces.nauvis.map_gen_settings
    settings.width = 2 * HALF + 32
    settings.height = 2 * HALF + 32
    settings.autoplace_settings = {
      entity = { treat_missing_as_default = false, settings = {} },
      decorative = { treat_missing_as_default = false, settings = {} },
    }
    settings.cliff_settings.richness = 0
    settings.no_enemies_mode = true
    surface = game.create_surface(NAME, settings)
    surface.request_to_generate_chunks({ 0, 0 }, 2)
    surface.force_generate_chunk_requests()
  end
  return surface
end

function Lab.reset()
  local surface = Lab.surface()
  for _, entity in pairs(surface.find_entities({ { -HALF - 16, -HALF - 16 }, { HALF + 16, HALF + 16 } })) do
    if entity.valid then entity.destroy() end
  end
  local tiles = {}
  for x = -HALF, HALF - 1 do
    for y = -HALF, HALF - 1 do
      tiles[#tiles + 1] = { name = "grass-1", position = { x, y } }
    end
  end
  surface.set_tiles(tiles)
  return surface
end

-- Ore on tile (x, y), i.e. centered on (x + 0.5, y + 0.5).
function Lab.ore(name, x, y)
  return Lab.surface().create_entity{ name = name, position = { x + 0.5, y + 0.5 }, amount = 1000 }
end

-- Ore on every tile of the rectangle (x1, y1) .. (x2, y2), inclusive.
function Lab.patch(name, x1, y1, x2, y2)
  for x = x1, x2 do
    for y = y1, y2 do Lab.ore(name, x, y) end
  end
end

function Lab.water(x, y)
  Lab.surface().set_tiles({ { name = "water", position = { x, y } } })
end

function Lab.entity(name, position, force)
  return Lab.surface().create_entity{ name = name, position = position, force = force or "player" }
end

return Lab
