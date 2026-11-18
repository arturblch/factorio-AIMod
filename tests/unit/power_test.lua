local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'
local LIBRARY = require 'blueprints/library'

local function steam_power()
  return Blueprint.module{ name = "SteamPower", blueprint = LIBRARY.blueprints["steam-power"], resource = "water" }
end

-- A lake at x 10..20, y -10..10, land elsewhere.
local function lake()
  local tiles = {}
  for x = 10, 20 do
    for y = -10, 10 do tiles[#tiles + 1] = { name = "water", position = { x, y } } end
  end
  Lab.surface().set_tiles(tiles)
end

-- The module's buildings placed at `location` the way BuildModuleTask does.
local function place(module, location)
  local corner = { x = math.floor(location.x), y = math.floor(location.y) }
  local placed = {}
  for i, building in ipairs(module.buildings) do
    local entity = Lab.surface().create_entity{ name = building.type, force = game.forces.player,
      position = { corner.x + building.position.x, corner.y + building.position.y },
      direction = building.direction or defines.direction.north }
    building.entity = entity
    placed[building.type] = entity
  end
  return placed
end

local function neighbour_names(entity)
  local names = {}
  for _, box in ipairs(entity.fluidbox_neighbours or {}) do
    for _, other in ipairs(box) do names[other.name] = true end
  end
  return names
end

T.describe("A power module from a blueprint", function()
  T.it("needs water in front of its pump, fuels the boiler and makes no items", function()
    local data, problem, checks = steam_power()
    T.truthy(data, tostring(problem))
    T.same(checks.errors, {}, "errors")
    T.same(checks.warnings, {}, "warnings")
    T.truthy(data.power, "a power module")
    T.same(data.outputs, {}, "no outputs")
    T.same(data.inputs, { { building = 1, type = "coal", slot = "fuel", ongoing = true } }, "the boiler's coal")
    local water, shore = 0, 0
    for _, tile in ipairs(data.geometry) do
      if tile.tile == "water" then water = water + 1 end
      if tile.shore then shore = shore + 1 end
    end
    T.truthy(water >= 1, "water tiles: " .. water)
    T.truthy(shore >= 1, "the pump's tiles: " .. shore)
  end)

  T.it("isn't a producer of anything", function()
    T.eq(ModuleLibrary.get("SteamPower").power, true, "in the library")
    for _, item in ipairs({ "iron-plate", "coal", "copper-plate" }) do
      for _, module in ipairs(ModuleLibrary.producers(item)) do
        T.falsy(module.power, item)
      end
    end
  end)
end)

T.describe("Building power by the water", function()
  local player
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    lake()
    player = Fakes.player{ surface = Lab.surface(), position = { x = 0, y = 0 } }
  end)

  T.it("finds a spot on the shore, and the game connects pump, boiler and engine", function()
    local module = ModuleLibrary.get("SteamPower"):instantiate()
    local location = BuildModuleTask:new{ module = module }:findLocation(player)
    T.truthy(location, "a spot")
    local placed = place(module, location)
    for _, building in ipairs(module.buildings) do T.truthy(building.entity, building.type .. " placed") end
    T.truthy(neighbour_names(placed["offshore-pump"])["boiler"], "pump -> boiler")
    T.truthy(neighbour_names(placed["boiler"])["steam-engine"], "boiler -> engine")
    local id = placed["small-electric-pole"].electric_network_id
    T.truthy(id, "a network")
    T.eq(placed["steam-engine"].electric_network_id, id, "the engine on it")
    T.eq(placed["lab"].electric_network_id, id, "the lab on it")
  end)

  T.it("reports the network and the boiler", function()
    local module = ModuleLibrary.get("SteamPower"):instantiate()
    place(module, BuildModuleTask:new{ module = module }:findLocation(player))
    local text = table.concat(Power.lines(player), "\n")
    T.truthy(text:find("0 kW used of 900 kW"), text)
    T.truthy(text:find("steam%-engine 1"), text)
    T.truthy(text:find("lab 1"), text)
    T.truthy(text:find("boilers: 1"), text)
    T.truthy(Power.summary(player):find("^power: 1 networks"), Power.summary(player))
    T.eq(module:fuelUse("coal"), 0, "no coal while nothing draws power")
  end)

  T.it("says when there is no network", function()
    T.same(Power.lines(player), { "no electric network yet" }, "lines")
  end)
end)

T.describe("ResearchTask", function()
  local force, saved
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    force = game.forces.player
    saved = {}
    for _, name in ipairs({ "steam-power", "electronics", "automation-science-pack" }) do
      saved[name] = force.technologies[name].researched
      force.technologies[name].researched = true
    end
  end)
  local function restore()
    force.cancel_current_research()
    force.research_queue = {}
    for name, researched in pairs(saved) do force.technologies[name].researched = researched end
  end

  T.it("knows the packs the electric mining drill takes", function()
    T.same(ResearchTask.packs_left(force, force.technologies["electric-mining-drill"]),
      { ["automation-science-pack"] = 25 }, "packs")
    restore()
  end)

  T.it("queues the research and carries packs into the lab", function()
    local lab = Lab.entity("lab", { 3, 3 })
    local player = Fakes.player{ surface = Lab.surface(), items = { ["automation-science-pack"] = 10 } }
    local machine = GoalMachine:new()
    local task = ResearchTask:new{ tech = "electric-mining-drill" }
    machine:pushSingle(task)
    task:tick{ player = player, machine = machine }
    local queued = force.current_research and force.current_research.name
    T.eq(queued, "electric-mining-drill", "being researched")
    T.eq(lab.get_inventory(defines.inventory.lab_input).get_item_count("automation-science-pack"), 10, "in the lab")
    T.eq(player.get_main_inventory().get_item_count("automation-science-pack"), 0, "out of the inventory")
    T.falsy(task:achieved{ player = player }, "15 more to bring")
    restore()
  end)

  T.it("crafts packs when it has too few", function()
    Lab.entity("lab", { 3, 3 })
    local player = Fakes.player{ surface = Lab.surface() }
    local machine = GoalMachine:new()
    local task = ResearchTask:new{ tech = "electric-mining-drill" }
    machine:pushSingle(task)
    task:tick{ player = player, machine = machine }
    local top = Fakes.goals(machine)[1]
    T.same({ getmetatable(top) == GatherResourceTask, top.type, top.qty }, { true, "automation-science-pack", 10 }, "a batch")
    restore()
  end)
end)

T.describe("GrowthTask and electricity", function()
  local player
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    player = Fakes.player{ surface = Lab.surface() }
  end)
  local function built(count)
    for i = 1, count do
      local x = (i - 1) * 6
      Lab.patch("iron-ore", x, 0, x + 1, 1)
      local module = BurnerToFurnaceModule:instantiate()
      for _, building in ipairs(module.buildings) do
        building.entity = Lab.entity(building.type, { x + building.position.x, building.position.y })
      end
      storage.resource_managers[1]:register_source(ModuleResourceSource:new{ module = module })
    end
  end

  T.it("builds power once the burner base has enough modules", function()
    built(GrowthTask.ELECTRICITY_AFTER - 1)
    T.eq(GrowthTask.electricity(player), nil, "not yet")
    built(1)
    local tasks = GrowthTask.electricity(player)
    T.truthy(tasks and getmetatable(tasks[1]) == BuildModuleTask and tasks[1].module.name == "SteamPower", "power")
  end)

  T.it("leaves power alone once it gave up on it", function()
    built(GrowthTask.ELECTRICITY_AFTER)
    storage.failed_goals = { [1] = { "SteamPower" } }
    T.eq(GrowthTask.electricity(player), nil, "given up")
  end)
end)
