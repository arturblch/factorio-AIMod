local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'
local LIBRARY = require 'blueprints/library'

local PACK = "automation-science-pack"

local function red_science()
  return Blueprint.module{ name = "RedScience", blueprint = LIBRARY.blueprints["red-science"] }
end

-- The module's buildings placed at `location` the way BuildModuleTask and
-- PlaceBuildingTask do, recipe included.
local function place(module, location)
  local corner = { x = math.floor(location.x), y = math.floor(location.y) }
  local placed = {}
  for _, building in ipairs(module.buildings) do
    local entity = Lab.surface().create_entity{ name = building.type, force = game.forces.player,
      position = { corner.x + building.position.x, corner.y + building.position.y },
      direction = building.direction or defines.direction.north, recipe = building.recipe }
    building.entity = entity
    placed[building.type] = entity
  end
  return placed
end

local function inside(entity, position)
  local box = entity.bounding_box
  return position.x > box.left_top.x and position.x < box.right_bottom.x and
    position.y > box.left_top.y and position.y < box.right_bottom.y
end

-- Researched for the test, put back by the returned function.
local function researched(names)
  local force = game.forces.player
  local saved = {}
  for _, name in ipairs(names) do
    saved[name] = force.technologies[name].researched
    force.technologies[name].researched = true
  end
  return function()
    force.cancel_current_research()
    force.research_queue = {}
    for name, value in pairs(saved) do force.technologies[name].researched = value end
  end
end

T.describe("A science module from a blueprint", function()
  T.it("makes red packs for its lab from what the bot brings, on our power", function()
    local data, problem, checks = red_science()
    T.truthy(data, tostring(problem))
    T.same(checks.errors, {}, "errors")
    T.same(checks.warnings, {}, "warnings")
    T.truthy(data.powered, "runs on our power")
    T.falsy(data.power, "makes none")
    T.eq(data.resource, nil, "needs no ore")
    T.same(data.packs, { PACK }, "the lab's packs")
    T.same(data.outputs, {}, "nothing for the bot to take")
    T.same(data.inputs, {
      { building = 1, type = "copper-plate", slot = "input" },
      { building = 1, type = "iron-gear-wheel", slot = "input" },
    }, "the machine's ingredients")
    T.eq(data.buildings[1].recipe, PACK, "the machine's recipe")
    T.truthy(table.concat(checks.flows, "; "):find("inserter 2: assembling%-machine%-1 1 %-> lab 3"), table.concat(checks.flows, "; "))
  end)

  T.it("is in the library, a producer of nothing", function()
    local module = ModuleLibrary.get("RedScience")
    T.truthy(module and module.powered, "listed")
    T.same(ModuleLibrary.producers(PACK), {}, "packs go to the lab, not to the bot")
  end)

  T.it("a module making nothing anyone takes is still an error", function()
    local text = Blueprint.decode(LIBRARY.blueprints["red-science"])
    text.entities[3] = nil -- no lab: the inserter drops nowhere, nothing ends anywhere
    local json = helpers.table_to_json({ blueprint = text })
    local _, _, checks = Blueprint.module{ name = "x", blueprint = "0" .. helpers.encode_string(json) }
    T.truthy(#checks.errors > 0, "errors")
  end)
end)

T.describe("Building a science module by our network", function()
  local player, pole
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    pole = Lab.entity("small-electric-pole", { 0.5, 0.5 })
    player = Fakes.player{ surface = Lab.surface(), position = { x = 0, y = 0 } }
  end)

  T.it("puts its pole in wire reach of ours, and the inserter between machine and lab", function()
    local module = ModuleLibrary.get("RedScience"):instantiate()
    local location = BuildModuleTask:new{ module = module }:findLocation(player)
    T.truthy(location, "a spot")
    local placed = place(module, location)
    for _, building in ipairs(module.buildings) do T.truthy(building.entity, building.type .. " placed") end
    local new_pole = placed["small-electric-pole"]
    T.truthy(util.distance(new_pole.position, pole.position) <= 7.5, "in wire reach")
    T.eq(new_pole.electric_network_id, pole.electric_network_id, "wired to ours")
    local machine, inserter, lab = placed["assembling-machine-1"], placed["inserter"], placed["lab"]
    T.eq(machine.electric_network_id, pole.electric_network_id, "the machine on it")
    T.eq(lab.electric_network_id, pole.electric_network_id, "the lab on it")
    T.eq(machine.get_recipe().name, PACK, "making red packs")
    T.truthy(inside(machine, inserter.pickup_position), "the inserter takes from the machine")
    T.truthy(inside(lab, inserter.drop_position), "and puts into the lab")
  end)

  T.it("keeps off ore", function()
    Lab.patch("iron-ore", -12, -12, 12, 3)
    local module = ModuleLibrary.get("RedScience"):instantiate()
    local location = BuildModuleTask:new{ module = module }:findLocation(player)
    T.truthy(location, "a spot")
    local corner = { x = math.floor(location.x), y = math.floor(location.y) }
    local area = { { corner.x, corner.y }, { corner.x + 7, corner.y + 3 } }
    T.eq(Lab.surface().count_entities_filtered{ area = area, type = "resource" }, 0, "no ore under it")
  end)

  T.it("takes over the power module's lab when there is room by it", function()
    pole.destroy()
    -- the power module's pole and lab, as blueprints/library.lua has them
    local station_pole = Lab.entity("small-electric-pole", { 2.5, 2.5 })
    local lab = Lab.entity("lab", { 1.5, 4.5 })
    local module = ModuleLibrary.get("RedScience"):instantiate()
    local task = BuildModuleTask:new{ module = module }
    local location = task:findLocation(player)
    T.truthy(location, "a spot")
    T.eq(task.reuse and task.reuse[3], lab, "the lab is ours already")
    local corner = { x = math.floor(location.x), y = math.floor(location.y) }
    T.same({ corner.x + module.buildings[3].position.x, corner.y + module.buildings[3].position.y },
      { lab.position.x, lab.position.y }, "the module's lab on it")
    T.eq(task:needs{ player = player }.lab, nil, "no lab to make")
    -- the buildings: all but the lab
    player = Fakes.player{ surface = Lab.surface(), position = { x = 0, y = 0 },
      items = { ["assembling-machine-1"] = 1, inserter = 1, ["small-electric-pole"] = 1 } }
    local machine = GoalMachine:new()
    machine:pushSingle(task)
    task.location = location
    task:tick{ player = player, machine = machine }
    local types = {}
    for _, goal in ipairs(Fakes.goals(machine)) do
      if getmetatable(goal) == BuildBuildingTask then types[#types + 1] = goal.type end
    end
    table.sort(types)
    T.same(types, { "assembling-machine-1", "inserter", "small-electric-pole" }, "no second lab")
    T.eq(task.built.buildings[3].entity, lab, "linked to the lab")
    -- placed, the inserter feeds that lab and the pole joins our network
    local placed = {}
    for i, building in ipairs(task.built.buildings) do
      if i ~= 3 then
        placed[building.type] = Lab.surface().create_entity{ name = building.type, force = "player",
          position = { corner.x + building.position.x, corner.y + building.position.y },
          direction = building.direction or defines.direction.north, recipe = building.recipe }
      end
    end
    T.truthy(inside(lab, placed["inserter"].drop_position), "into the power module's lab")
    T.eq(placed["small-electric-pole"].electric_network_id, station_pole.electric_network_id, "wired to the station")
  end)

  T.it("finds no spot without a network", function()
    pole.destroy()
    local module = ModuleLibrary.get("RedScience"):instantiate()
    T.eq(BuildModuleTask:new{ module = module }:findLocation(player), nil, "no spot")
  end)
end)

T.describe("ResearchTask with an assembling machine", function()
  local player, machine, restore
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    restore = researched({ "steam-power", "electronics", "automation-science-pack", "automation" })
    Lab.entity("small-electric-pole", { 3.5, 0.5 })
    machine = Lab.surface().create_entity{ name = "assembling-machine-1", position = { 1.5, 1.5 }, force = "player", recipe = PACK }
    Lab.entity("lab", { 5.5, 1.5 })
  end)

  T.it("carries the machine the ingredients instead of crafting packs", function()
    player = Fakes.player{ surface = Lab.surface(), items = { ["copper-plate"] = 30, ["iron-gear-wheel"] = 30 } }
    local goals = GoalMachine:new()
    local task = ResearchTask:new{ tech = "electric-mining-drill" }
    goals:pushSingle(task)
    task:tick{ player = player, machine = goals }
    local input = machine.get_inventory(defines.inventory.crafter_input)
    T.eq(input.get_item_count("copper-plate"), 25, "copper for 25 packs")
    T.eq(input.get_item_count("iron-gear-wheel"), 25, "gears for 25 packs")
    T.eq(player.get_main_inventory().get_item_count("copper-plate"), 5, "out of the inventory")
    T.same(ResearchTask.missing(player, game.forces.player.technologies["electric-mining-drill"]), {}, "the machine makes the rest")
    T.truthy(task:achieved{ player = player }, "done while the machine works")
    restore()
  end)

  T.it("gathers the ingredients first", function()
    player = Fakes.player{ surface = Lab.surface() }
    local goals = GoalMachine:new()
    local task = ResearchTask:new{ tech = "electric-mining-drill" }
    goals:pushSingle(task)
    T.same(task:needs{ player = player }, { ["copper-plate"] = 25, ["iron-gear-wheel"] = 25 }, "needs")
    task:tick{ player = player, machine = goals }
    local top = Fakes.goals(goals)[1]
    T.same({ getmetatable(top) == GatherResourceTask, top.type, top.qty }, { true, "copper-plate", 25 }, "copper first")
    restore()
  end)
end)

T.describe("GrowthTask and science", function()
  local player, restore
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    player = Fakes.player{ surface = Lab.surface() }
  end)
  -- a module of ours that counts as built and working
  local function have(name, extra)
    local module = { name = name }
    for k, v in pairs(extra or {}) do module[k] = v end
    local sources = storage.resource_managers[1].sources
    sources[#sources + 1] = { module = module, is_valid = function() return true end }
  end
  local function first(tasks)
    local task = tasks and tasks[1]
    if not task then return nil end
    return (getmetatable(task) == BuildModuleTask and ("build " .. task.module.name)) or
      (getmetatable(task) == ResearchTask and ("research " .. task.tech)) or "?"
  end

  T.it("researches automation by hand before anything else", function()
    restore = researched({ "steam-power", "electronics", "automation-science-pack" })
    have("SteamPower", { power = true })
    Lab.entity("lab", { 3, 3 })
    T.eq(first(GrowthTask.electricity(player)), "research automation", "automation first")
    restore()
  end)

  T.it("then builds the science module, then researches with it", function()
    restore = researched({ "steam-power", "electronics", "automation-science-pack", "automation" })
    have("SteamPower", { power = true })
    T.eq(first(GrowthTask.electricity(player)), "build RedScience", "the module once automation is done")
    have("RedScience", { powered = true, packs = { PACK } })
    T.eq(first(GrowthTask.electricity(player)), "research electric-mining-drill", "then the drill")
    restore()
  end)

  T.it("researches by hand when it gave up on the modules", function()
    restore = researched({ "steam-power", "electronics", "automation-science-pack", "automation" })
    have("SteamPower", { power = true })
    storage.failed_goals = { [1] = { "RedScience" } }
    local without_first = first(GrowthTask.electricity(player))
    storage.failed_goals = { [1] = { "RedScience", "RedScience2" } }
    local without_both = first(GrowthTask.electricity(player))
    restore()
    T.eq(without_first, "build RedScience2", "the other one instead")
    T.eq(without_both, "research electric-mining-drill", "by hand")
  end)
end)

T.describe("BuildModuleTask with a locked building", function()
  local player
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    player = Fakes.player{ surface = Lab.surface() }
  end)
  local function tick(module)
    local machine = GoalMachine:new()
    local task = BuildModuleTask:new{ module = module:instantiate() }
    task.location = { x = 0.5, y = 0.5 }
    machine:pushSingle(task)
    task:tick{ player = player, machine = machine }
    return task, Fakes.goals(machine)[1]
  end

  T.it("researches what unlocks it by its trigger first", function()
    local force = game.forces.player
    T.falsy(force.recipes["small-electric-pole"].enabled, "the pole is locked")
    local _, top = tick(ModuleLibrary.get("SteamPower"))
    T.eq(getmetatable(top), ResearchTriggerTask, "a trigger research")
    T.truthy(top.tech == "electronics" or top.tech == "steam-power", top.tech)
  end)

  T.it("gives up when only packs unlock it", function()
    local force = game.forces.player
    local saved = {}
    for _, name in ipairs({ "steam-power", "electronics", "automation-science-pack" }) do
      saved[name] = force.technologies[name].researched
      force.technologies[name].researched = true
    end
    local task = tick(ModuleLibrary.get("RedScience")) -- the assembling machine waits for automation
    T.truthy(task.failed, "given up, not waiting for ever")
    for name, value in pairs(saved) do force.technologies[name].researched = value end
  end)
end)

T.describe("A second red science machine (plan 3.14)", function()
  local player, restore
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    restore = researched({ "steam-power", "electronics", "automation-science-pack", "automation" })
    player = Fakes.player{ surface = Lab.surface(), position = { x = 0, y = 0 } }
  end)
  local function machine_at(position)
    return Lab.surface().create_entity{ name = "assembling-machine-1", position = position, force = "player", recipe = PACK }
  end

  T.it("is in the library: red packs into a lab, on our power", function()
    local data, problem, checks = Blueprint.module{ name = "RedScience2", blueprint = LIBRARY.blueprints["red-science-south"] }
    T.truthy(data, tostring(problem))
    T.same(checks.errors, {}, "errors")
    T.same(data.packs, { PACK }, "the lab's packs")
    T.truthy(data.powered, "runs on our power")
    T.truthy(ModuleLibrary.get("RedScience2"), "listed")
    restore()
  end)

  T.it("goes on the power module's lab, south of it, next to the first machine", function()
    -- the power module's pole and lab, and the first red machine west of the lab
    local station_pole = Lab.entity("small-electric-pole", { 2.5, 2.5 })
    local lab = Lab.entity("lab", { 1.5, 4.5 })
    machine_at({ -2.5, 4.5 })
    Lab.surface().create_entity{ name = "inserter", position = { -0.5, 4.5 }, force = "player", direction = defines.direction.west }
    Lab.entity("small-electric-pole", { -0.5, 3.5 })
    local module = ModuleLibrary.get("RedScience2"):instantiate()
    local task = BuildModuleTask:new{ module = module }
    local location = task:findLocation(player)
    T.truthy(location, "a spot")
    T.eq(task.reuse and task.reuse[1], lab, "the lab is ours already")
    local corner = { x = math.floor(location.x), y = math.floor(location.y) }
    local placed = {}
    for i, building in ipairs(module.buildings) do
      if i ~= 1 then
        placed[building.type] = Lab.surface().create_entity{ name = building.type, force = "player",
          position = { corner.x + building.position.x, corner.y + building.position.y },
          direction = building.direction or defines.direction.north, recipe = building.recipe }
      end
    end
    T.truthy(inside(lab, placed["inserter"].drop_position), "into the power module's lab")
    T.truthy(inside(placed["assembling-machine-1"], placed["inserter"].pickup_position), "from its machine")
    T.truthy(placed["assembling-machine-1"].position.y > lab.position.y, "south of the lab")
    T.eq(placed["small-electric-pole"].electric_network_id, station_pole.electric_network_id, "wired to the station")
    restore()
  end)

  T.it("a machine makes 6 packs a minute; a lab takes 6 at 10 s a unit, 12 at 5 s", function()
    Lab.entity("small-electric-pole", { 3.5, 0.5 })
    machine_at({ 1.5, 1.5 })
    Lab.entity("lab", { 5.5, 1.5 })
    local force = game.forces.player
    local made, taken = GrowthTask.pack_pace(player, force.technologies["electric-mining-drill"], PACK)
    T.near(made, 6, 1e-6, "made")
    T.near(taken, 6, 1e-6, "electric mining drill")
    made, taken = GrowthTask.pack_pace(player, force.technologies["logistic-science-pack"], PACK)
    T.near(taken, 12, 1e-6, "green packs")
    restore()
  end)

  T.it("growth builds it only when the labs take more than the machines make", function()
    Lab.entity("small-electric-pole", { 3.5, 0.5 })
    machine_at({ 1.5, 1.5 })
    Lab.entity("lab", { 5.5, 1.5 })
    local sources = storage.resource_managers[1].sources
    sources[#sources + 1] = { module = { name = "RedScience", packs = { PACK }, powered = true }, is_valid = function() return true end }
    local force = game.forces.player
    T.eq(GrowthTask.science_module(player, force.technologies["electric-mining-drill"]), nil, "one is enough at 10 s")
    local module = GrowthTask.science_module(player, force.technologies["logistic-science-pack"])
    T.eq(module and module.name, "RedScience2", "a second one at 5 s")
    restore()
  end)

  T.it("the research gives each machine an even share", function()
    Lab.entity("small-electric-pole", { 3.5, 0.5 })
    local near, far = machine_at({ 1.5, 1.5 }), machine_at({ 1.5, 5.5 })
    Lab.entity("small-electric-pole", { 3.5, 4.5 })
    Lab.entity("lab", { 5.5, 1.5 })
    player = Fakes.player{ surface = Lab.surface(), position = { x = 0, y = 0 },
      items = { ["copper-plate"] = 200, ["iron-gear-wheel"] = 200 } }
    local goals = GoalMachine:new()
    local task = ResearchTask:new{ tech = "logistic-science-pack" }
    goals:pushSingle(task)
    task:tick{ player = player, machine = goals }
    task:tick{ player = player, machine = goals }
    local function copper(machine) return machine.get_inventory(defines.inventory.crafter_input).get_item_count("copper-plate") end
    T.same({ copper(near), copper(far) }, { 38, 37 }, "75 packs, half each")
    T.same(ResearchTask.missing(player, game.forces.player.technologies["logistic-science-pack"]), {}, "the machines make the rest")
    restore()
  end)
end)
