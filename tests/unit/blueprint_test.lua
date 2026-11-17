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
    T.same(names, { "BurnerToFurnace", "BurnerToFurnaceCopper", "BurnerToFurnaceStone", "BurnerToBurner" }, "names")
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
    T.eq(#lines, #ModuleLibrary.listed(), "a line each")
    T.eq(lines[1], "BurnerToFurnace: iron-plate from iron-ore, 2 buildings", "first")
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
    T.eq(names()[1], "BurnerToFurnace", "back to the library")
  end)

  T.it("refuses a name it doesn't know", function()
    T.eq(ModuleLibrary.choose{ "IronToChest", "Nope" }, "Nope", "unknown")
    T.eq(storage.module_choice, nil, "nothing changed")
  end)

  T.it("/aimod-use sets, shows and resets the choice", function()
    T.truthy(AIMod.use_modules("IronToChest, BurnerToBurner"):find("IronToChest, BurnerToBurner %(your choice"), "set")
    T.truthy(AIMod.use_modules(""):find("IronToChest, BurnerToBurner"), "shown")
    T.truthy(AIMod.use_modules("default"):find("^AIMod builds, best first: BurnerToFurnace"), "reset")
    T.truthy(AIMod.use_modules("Nope"):find("no module Nope"), "unknown")
  end)
end)
