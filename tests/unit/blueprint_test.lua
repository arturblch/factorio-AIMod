local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'
local LIBRARY = require 'blueprints/library'

local function string_of(key) return LIBRARY.blueprints[key] end
local function module_of(key, resource, product)
  return Blueprint.module{ name = key, blueprint = string_of(key), resource = resource, product = product }
end
-- a blueprint string made in game from `blueprint` (a table)
local function encode(blueprint)
  return "0" .. helpers.encode_string(helpers.table_to_json{ blueprint = blueprint })
end
local function sorted(list, by)
  local copy = {}
  for i, v in ipairs(list) do copy[i] = v end
  table.sort(copy, by)
  return copy
end

T.describe("Blueprint.decode", function()
  T.it("reads a blueprint string", function()
    local blueprint = Blueprint.decode(string_of("burner-furnace"))
    T.eq(#blueprint.entities, 2, "entities")
    T.eq(blueprint.entities[1].name, "burner-mining-drill", "first")
  end)

  T.it("says what is wrong with anything else", function()
    local blueprint, problem = Blueprint.decode("hello")
    T.eq(blueprint, nil, "blueprint")
    T.truthy(problem:find("not a blueprint string"), problem)
    T.eq(Blueprint.decode("0" .. helpers.encode_string('{"blueprint_book": {}}')), nil, "a book")
  end)

  T.it("the game takes every string in the library", function()
    local inventory = game.create_inventory(1)
    for key, text in pairs(LIBRARY.blueprints) do
      inventory[1].set_stack{ name = "blueprint" }
      T.eq(inventory[1].import_stack(text), 0, key .. " imported")
      T.eq(#inventory[1].get_blueprint_entities(), #Blueprint.decode(text).entities, key .. " entities")
    end
    inventory.destroy()
  end)
end)

T.describe("Blueprint.module", function()
  T.it("makes the same furnace module as the old hand-written one", function()
    local module = module_of("burner-furnace", "iron-ore", "iron-plate")
    local ore, free = {}, {}
    for _, tile in ipairs(module.geometry) do
      local list = tile.resource and ore or free
      list[#list + 1] = tile.position.x .. "," .. tile.position.y .. (tile.resource and (":" .. tile.resource) or "")
    end
    T.same(ore, { "0,0:iron-ore", "0,1:iron-ore", "1,0:iron-ore", "1,1:iron-ore" }, "ore tiles")
    T.same(free, { "2,0", "2,1", "3,0", "3,1" }, "free tiles")
    T.same(module.buildings, {
      { type = "burner-mining-drill", position = { x = 1, y = 1 }, direction = defines.direction.east },
      { type = "stone-furnace", position = { x = 3, y = 1 } },
    }, "buildings")
    T.same(module.inputs, {
      { building = 1, type = "coal", slot = "fuel", ongoing = true },
      { building = 2, type = "coal", slot = "fuel", ongoing = true },
    }, "inputs")
    T.same(module.outputs, { { building = 2, type = "iron-plate", slot = "output" } }, "outputs")
  end)

  T.it("makes the same coal module as the old hand-written one", function()
    local module = module_of("coal-pair", "coal", "coal")
    T.eq(#module.geometry, 8, "tiles")
    for _, tile in ipairs(module.geometry) do T.eq(tile.resource, "coal", "all coal") end
    T.same(module.buildings, {
      { type = "burner-mining-drill", position = { x = 1, y = 1 }, direction = defines.direction.east },
      { type = "burner-mining-drill", position = { x = 3, y = 1 }, direction = defines.direction.west },
    }, "buildings")
    T.same(module.inputs, { { building = 1, type = "coal", slot = "fuel", ongoing = false } }, "only the first is fueled to start")
    T.same(module.outputs, {
      { building = 1, type = "coal", slot = "fuel", keep = 5 },
      { building = 2, type = "coal", slot = "fuel", keep = 5 },
    }, "outputs")
  end)

  T.it("a ring of coal drills is fueled once, to start", function()
    local module = module_of("coal-ring4", "coal", "coal")
    T.eq(#module.geometry, 16, "a 4x4 patch")
    for _, tile in ipairs(module.geometry) do T.eq(tile.resource, "coal", "all coal") end
    T.same(module.inputs, { { building = 1, type = "coal", slot = "fuel", ongoing = false } }, "only the first")
    T.eq(#module.outputs, 4, "every drill's fuel")
    for _, output in ipairs(module.outputs) do T.eq(output.slot, "fuel", "fuel slot") end
    local ring = BaseModule:new(module):productionRate("coal")
    local pair = BaseModule:new(module_of("coal-pair", "coal", "coal")):productionRate("coal")
    T.near(ring, 2 * pair, 1e-9, "twice a pair")
  end)

  T.it("a column is pairs of drill and furnace", function()
    local column = BaseModule:new(module_of("furnace-column4", "iron-ore", "iron-plate"))
    local pair = BaseModule:new(module_of("burner-furnace", "iron-ore", "iron-plate"))
    T.near(column:productionRate("iron-plate"), 4 * pair:productionRate("iron-plate"), 1e-9, "four pairs")
    T.eq(#column.inputs, 8, "every building fueled")
    T.eq(#column.outputs, 4, "a furnace each")
    local ore = 0
    for _, tile in ipairs(column.geometry) do
      if(tile.resource) then ore = ore + 1 end
    end
    T.eq(ore, 16, "ore only under the drills")
    T.eq(#column.geometry, 32, "8x4 tiles")
    local eight = BaseModule:new(module_of("furnace-column8", "copper-ore", "copper-plate"))
    T.near(eight:productionRate("copper-plate"), 8 * pair:productionRate("iron-plate"), 1e-9, "eight pairs")
  end)

  T.it("follows an inserter from the furnace into a chest", function()
    local module = module_of("furnace-chest", "iron-ore", "iron-plate")
    T.same(module.outputs, { { building = 4, type = "iron-plate", slot = "output" } }, "the chest")
    T.same(sorted(module.inputs, function(a, b) return a.building < b.building end), {
      { building = 1, type = "coal", slot = "fuel", ongoing = true },
      { building = 2, type = "coal", slot = "fuel", ongoing = true },
      { building = 3, type = "coal", slot = "fuel", ongoing = true },
    }, "drill, furnace and inserter are fueled")
    T.eq(#module.geometry, 10, "tiles")
    T.near(BaseModule:new(module):productionRate("iron-plate") * 60, 15, 1e-6, "per minute")
  end)

  T.it("takes what a drill puts into a chest", function()
    local module = module_of("burner-chest", "stone", "stone")
    T.same(module.outputs, { { building = 2, type = "stone", slot = "output" } }, "the chest")
    T.near(BaseModule:new(module):productionRate("stone") * 60, 15, 1e-6, "per minute")
  end)

  T.it("doesn't care where the blueprint was drawn", function()
    local blueprint = Blueprint.decode(string_of("burner-furnace"))
    for _, entity in ipairs(blueprint.entities) do
      entity.position = { x = entity.position.x + 10, y = entity.position.y - 7 }
    end
    local moved = Blueprint.module{ name = "moved", blueprint = encode(blueprint), resource = "copper-ore" }
    T.same(moved.buildings, module_of("burner-furnace", "copper-ore").buildings, "buildings")
  end)

  T.it("says when a blueprint doesn't make the product", function()
    local module, problem = module_of("burner-furnace", "iron-ore", "copper-plate")
    T.eq(module, nil, "module")
    T.truthy(problem:find("copper%-plate"), problem)
  end)
end)

T.describe("ModuleLibrary from blueprints", function()
  T.it("has every listed module", function()
    T.eq(#ModuleLibrary.listed(), #LIBRARY.modules, "none left out")
    T.eq(ModuleLibrary.get("BurnerToFurnace"), BurnerToFurnaceModule, "by name")
  end)

  T.it("builds only the ones switched on", function()
    local names = {}
    for _, module in ipairs(ModuleLibrary.all()) do names[#names + 1] = module.name end
    T.same(names, { "IronColumn4", "BurnerToFurnace", "CopperColumn4", "BurnerToFurnaceCopper", "BurnerToFurnaceStone",
      "CoalRing4", "BurnerToBurner" }, "names")
  end)
end)

T.describe("ModulePlan", function()
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
  end)

  T.it("draws the ore, the buildings, an outline and the name, and takes them away", function()
    local objects = ModulePlan.draw(BurnerToFurnaceModule, { x = 10.5, y = 4.5 }, Lab.surface())
    -- 4 ore tiles; per building a box and an icon; the drill's facing; outline; name
    T.eq(#objects, 4 + 2 * 2 + 1 + 1 + 1, "objects")
    ModulePlan.clear(objects)
    for _, object in ipairs(objects) do T.falsy(object.valid, "gone") end
  end)

  T.it("is drawn while a module is built and gone when the bot gives up", function()
    Lab.patch("iron-ore", 10, 10, 11, 11)
    local player = Fakes.player{ surface = Lab.surface(), items = { ["burner-mining-drill"] = 1, ["stone-furnace"] = 1 } }
    local machine = GoalMachine:new()
    local task = BuildModuleTask:new{ module = BurnerToFurnaceModule }
    machine:pushSingle(task)
    task:tick{ player = player, machine = machine }
    T.truthy(task.location and task.plan and #task.plan > 0, "drawn at the spot")
    local objects = task.plan
    task:fail(player, "test")
    T.eq(task.plan, nil, "plan")
    T.falsy(objects[1].valid, "gone")
  end)
end)

T.describe("Console commands", function()
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
  end)

  T.it("/aimod-modules lists the library", function()
    local lines = AIMod.module_list()
    T.truthy(#lines >= #ModuleLibrary.listed(), "a line each, and warnings")
    local plain
    for _, line in ipairs(lines) do
      if(line:find("^BurnerToFurnace: ")) then plain = line end
    end
    T.truthy(plain and plain:find("^BurnerToFurnace: iron%-plate 15%.0/min from iron%-ore; 2 buildings costing iron%-plate 9, stone 10; 3%.6 coal/min into 2; full in 7 min; score "), tostring(plain))
    T.truthy(lines[#lines]:find("%(off%)"), lines[#lines])
  end)

  T.it("/aimod-plan shows where a module would go", function()
    Lab.patch("iron-ore", 10, 10, 11, 11)
    local player = Fakes.player{ surface = Lab.surface() }
    T.truthy(AIMod.show_plan(player, "BurnerToFurnace"):find("would go at %[gps="), "found a spot")
    T.truthy(AIMod.show_plan(player, "BurnerToFurnaceCopper"):find("no spot"), "no copper")
    T.truthy(AIMod.show_plan(player, "Nope"):find("no module Nope"), "unknown")
  end)
end)

T.describe("Choosing the modules", function()
  local function names()
    local list = {}
    for _, module in ipairs(ModuleLibrary.all()) do list[#list + 1] = module.name end
    return list
  end

  T.it("puts the chosen ones first and only them, switched off ones too", function()
    T.eq(ModuleLibrary.choose{ "IronToChest", "BurnerToBurner" }, nil, "all known")
    T.same(names(), { "IronToChest", "BurnerToBurner" }, "chosen")
    T.eq(ModuleLibrary.producer(Fakes.player{}, "iron-plate"), IronToChestModule or ModuleLibrary.get("IronToChest"), "iron from the chest module")
    ModuleLibrary.choose(nil)
    T.eq(names()[1], "IronColumn4", "back to the library")
  end)

  T.it("refuses a name it doesn't know", function()
    T.eq(ModuleLibrary.choose{ "IronToChest", "Nope" }, "Nope", "unknown")
    T.eq(storage.module_choice, nil, "nothing changed")
  end)

  T.it("/aimod-use sets, shows and resets the choice", function()
    T.truthy(AIMod.use_modules("IronToChest, BurnerToBurner"):find("IronToChest, BurnerToBurner %(your choice"), "set")
    T.truthy(AIMod.use_modules(""):find("IronToChest, BurnerToBurner"), "shown")
    T.truthy(AIMod.use_modules("default"):find("^AIMod builds, best first: IronColumn4, BurnerToFurnace"), "reset")
    T.truthy(AIMod.use_modules("Nope"):find("no module Nope"), "unknown")
  end)
end)

-- A blueprint string of `entities`, numbered in order.
local function blueprint_of(entities)
  for i, entity in ipairs(entities) do entity.entity_number = i end
  return encode{ item = "blueprint", entities = entities }
end
local function drill(x, y, direction) return { name = "burner-mining-drill", position = { x = x, y = y }, direction = direction } end
local function belt(x, y, direction) return { name = "transport-belt", position = { x = x + 0.5, y = y + 0.5 }, direction = direction } end
local function inserter(x, y, direction) return { name = "burner-inserter", position = { x = x + 0.5, y = y + 0.5 }, direction = direction } end
local function chest(x, y) return { name = "wooden-chest", position = { x = x + 0.5, y = y + 0.5 } } end
local function check(entities, resource)
  return Blueprint.module{ name = "test", blueprint = blueprint_of(entities), resource = resource or "iron-ore" }
end
local E, S, W = defines.direction.east, defines.direction.south, defines.direction.west

T.describe("Belts in blueprints", function()
  T.it("a belt line feeds four furnaces through inserters", function()
    local module, problem, checks = module_of("belt-line", "iron-ore", "iron-plate")
    T.same(checks.errors, {}, "errors")
    T.same(checks.warnings, {}, "warnings")
    local fed = {}
    for _, output in ipairs(module.outputs) do fed[#fed + 1] = module.buildings[output.building].type .. ":" .. output.type end
    T.same(fed, { "stone-furnace:iron-plate", "stone-furnace:iron-plate", "stone-furnace:iron-plate", "stone-furnace:iron-plate" }, "outputs")
    T.eq(#module.inputs, 13, "the bot fuels 5 drills, 4 inserters, 4 furnaces")
    local line = BaseModule:new(module)
    T.near(line:productionRate("iron-plate") * 60, 75, 1e-6, "per minute")
    T.near(line:smeltingLoad(), 1, 1e-6, "5 drills feed 4 furnaces exactly")
  end)

  T.it("follows an underground belt and a splitter", function()
    -- drill drops at (1, 2); belt east, underground in at 2, out at 5, splitter at 6/7, two inserters, two chests
    local _, _, checks = check{
      drill(1, 1, S), belt(1, 2, E),
      { name = "underground-belt", position = { x = 2.5, y = 2.5 }, direction = E, type = "input" },
      { name = "underground-belt", position = { x = 5.5, y = 2.5 }, direction = E, type = "output" },
      { name = "splitter", position = { x = 6.5, y = 3 }, direction = E },
      belt(7, 2, E), belt(7, 3, E),
      inserter(8, 2, W), inserter(8, 3, W), chest(9, 2), chest(9, 3),
    }
    T.same(checks.errors, {}, "errors")
    local module = check{
      drill(1, 1, S), belt(1, 2, E),
      { name = "underground-belt", position = { x = 2.5, y = 2.5 }, direction = E, type = "input" },
      { name = "underground-belt", position = { x = 5.5, y = 2.5 }, direction = E, type = "output" },
      { name = "splitter", position = { x = 6.5, y = 3 }, direction = E },
      belt(7, 2, E), belt(7, 3, E),
      inserter(8, 2, W), inserter(8, 3, W), chest(9, 2), chest(9, 3),
    }
    local chests = 0
    for _, output in ipairs(module.outputs) do
      if module.buildings[output.building].type == "wooden-chest" and output.type == "iron-ore" then chests = chests + 1 end
    end
    T.eq(chests, 2, "ore reaches both chests")
  end)

  T.it("coal carried by a burner inserter fuels it", function()
    local module = check({ drill(1, 1, S), belt(1, 2, E), inserter(2, 2, W), chest(3, 2) }, "coal")
    T.same(module.inputs, {
      { building = 1, type = "coal", slot = "fuel", ongoing = true },
      { building = 3, type = "coal", slot = "fuel", ongoing = false },
    }, "the bot fuels the drill; the inserter only to start")
  end)
end)

T.describe("Blueprint checks", function()
  T.it("a drill dropping on the ground is an error", function()
    local _, _, checks = check{ drill(1, 1, E) }
    T.truthy(checks.errors[1]:find("drops its iron%-ore on the ground"), checks.errors[1])
  end)

  T.it("an inserter with nothing on either side is an error", function()
    local _, _, checks = check{ drill(1, 1, E), chest(2, 0), inserter(5, 5, W) }
    T.truthy(checks.errors[1]:find("has nothing to take from"), checks.errors[1])
  end)

  T.it("nothing the bot can take is an error", function()
    local _, _, checks = check{ drill(1, 1, S), belt(1, 2, E) }
    T.truthy(table.concat(checks.errors, "; "):find("nothing ends where the bot can take it"), table.concat(checks.errors, "; "))
  end)

  T.it("a belt nobody takes from, and one carrying nothing, are warnings", function()
    local _, _, checks = check{ drill(1, 1, E), chest(2, 0), drill(5, 1, S), belt(5, 2, E), belt(9, 9, E) }
    local text = table.concat(checks.warnings, "; ")
    T.truthy(text:find("transport%-belt 4 ends with iron%-ore that no inserter takes"), text)
    T.truthy(text:find("transport%-belt 5 carries nothing"), text)
  end)

  T.it("too many drills for a furnace is a warning in the report", function()
    -- two drills facing one furnace from both sides
    local data = check{ drill(1, 1, E), { name = "stone-furnace", position = { x = 3, y = 1 } }, drill(5, 1, W) }
    data.name = "TwoDrillsOneFurnace"
    local report = ModuleLibrary.report(BaseModule:new(data))
    T.near(report.load, 1.6, 1e-6, "0.5 ore a second for 0.3125")
    T.truthy(table.concat(report.warnings, "; "):find("the drills mine 60%% more"), table.concat(report.warnings, "; "))
  end)

  T.it("a library entry with errors is left out", function()
    for _, module in ipairs(ModuleLibrary.listed()) do
      T.same(ModuleLibrary.checks(module.name).errors, {}, module.name)
    end
  end)
end)

T.describe("Choosing by score", function()
  T.it("costs and upkeep tell the plain module from the bigger ones", function()
    local plain = ModuleLibrary.report(BurnerToFurnaceModule)
    local chest = ModuleLibrary.report(ModuleLibrary.get("IronToChest"))
    local line = ModuleLibrary.report(ModuleLibrary.get("IronBeltLine"))
    T.same({ plain.refuel, chest.refuel, line.refuel }, { 2, 3, 13 }, "buildings to fuel")
    T.truthy(plain.score > chest.score and plain.score > line.score, string.format("%.3f %.3f %.3f", plain.score, chest.score, line.score))
    T.truthy(chest.buffer > plain.buffer, "the chest holds more")
  end)

  T.it("best puts the highest score first", function()
    ModuleLibrary.choose("best")
    local all = ModuleLibrary.all()
    for i = 2, #all do
      T.truthy(ModuleLibrary.report(all[i - 1]).score >= ModuleLibrary.report(all[i]).score, all[i - 1].name .. " before " .. all[i].name)
    end
    T.eq(ModuleLibrary.producer(Fakes.player{}, "iron-plate"), BurnerToFurnaceModule, "iron: the plain module")
    T.truthy(AIMod.use_modules(""):find("best score first"), "said so")
    ModuleLibrary.choose(nil)
  end)

  T.it("crafts belts two to a craft", function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    Lab.patch("iron-ore", 0, 0, 9, 1)
    local player = Fakes.player{ surface = Lab.surface(), items = { ["burner-mining-drill"] = 5, ["stone-furnace"] = 4, ["burner-inserter"] = 4 } }
    local machine = GoalMachine:new()
    local task = BuildModuleTask:new{ module = ModuleLibrary.get("IronBeltLine") }
    machine:pushSingle(task)
    task:tick{ player = player, machine = machine }
    local craft = Fakes.goals(machine)[1]
    T.same({ craft.recipe, craft.qty }, { "transport-belt", 8 }, "8 crafts for 16 belts")
  end)
end)

T.describe("The first module for a product", function()
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
  end)

  T.it("is one the bot can build from what it carries", function()
    ModuleLibrary.choose{ "IronBeltLine", "BurnerToFurnace" }
    local start = Fakes.player{ surface = Lab.surface(), items = { ["burner-mining-drill"] = 1, ["stone-furnace"] = 1, ["iron-plate"] = 8 } }
    T.eq(ModuleLibrary.missingOwn(start, ModuleLibrary.get("IronBeltLine"), "iron-plate"), 64, "the line lacks 64 plates")
    T.eq(ModuleLibrary.missingOwn(start, BurnerToFurnaceModule, "iron-plate"), 0, "the starting kit is the plain module")
    T.eq(ModuleLibrary.producer(start, "iron-plate"), BurnerToFurnaceModule, "plain first")
    -- once a module makes iron plates, the list order counts again
    Lab.patch("iron-ore", 0, 0, 1, 1)
    local module = BurnerToFurnaceModule:instantiate()
    module.buildings[1].entity = Lab.entity("burner-mining-drill", { 1, 1 })
    module.buildings[2].entity = Lab.entity("stone-furnace", { 3, 1 })
    storage.resource_managers[1]:register_source(ModuleResourceSource:new{ module = module })
    T.eq(ModuleLibrary.producer(start, "iron-plate"), ModuleLibrary.get("IronBeltLine"), "then the belt line")
    ModuleLibrary.choose(nil)
  end)
end)

T.describe("Choosing by need", function()
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
  end)

  T.it("best takes the cheapest module that covers a goal, the best score for growth", function()
    ModuleLibrary.choose("best")
    local player = Fakes.player{ surface = Lab.surface() }
    local pair, single = ModuleLibrary.get("StonePairFurnace"), BurnerToFurnaceStoneModule
    T.eq(ModuleLibrary.producer(player, "stone-brick"), pair, "no goal: the best score")
    T.eq(ModuleLibrary.producer(player, "stone-brick", nil, 5), single, "5 a minute: one drill does")
    T.eq(ModuleLibrary.producer(player, "stone-brick", nil, 15), pair, "15 a minute: two drills")
    T.eq(ModuleLibrary.producer(player, "stone-brick", nil, 40), pair, "more than any one makes: the best score")
    local goal = ProductionGoalTask:new{ item = "stone-brick", per_minute = 5 }
    T.eq(goal:shortfall(player), 5, "a goal says what it lacks")
    T.eq(ProductionGoalTask:new{ item = "stone-brick", per_minute = 5, growth = true }:shortfall(player), nil, "growth doesn't")
    ModuleLibrary.choose(nil)
  end)

  T.it("the list order stands without best", function()
    local player = Fakes.player{ surface = Lab.surface() }
    T.eq(ModuleLibrary.producer(player, "stone-brick", nil, 15), BurnerToFurnaceStoneModule, "the switched-on one")
  end)
end)
