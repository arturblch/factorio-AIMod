local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'

local PACK = "automation-science-pack"

-- A module of `template` on a patch of `ore` at tiles x..x+3, 0..1, its
-- buildings standing, registered with player 1's resource manager.
local function built(template, ore, x)
  Lab.patch(ore, x, 0, x + 3, 1)
  local module = template:instantiate()
  for _, building in ipairs(module.buildings) do
    building.entity = Lab.entity(building.type, { x + building.position.x, building.position.y })
  end
  storage.resource_managers[1]:register_source(ModuleResourceSource:new{ module = module })
  return module
end

local function column() return ModuleLibrary.get("CopperColumn4") end

T.describe("SupplyChain", function()
  local player
  T.before_each(function()
    Lab.reset()
    storage.resource_managers[1] = ResourceManager:new()
    player = Fakes.player{ surface = Lab.surface() }
  end)

  T.it("counts what the modules make and burn", function()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    built(BurnerToBurnerModule, "coal", 10)
    local chain = SupplyChain.analyze(player)
    local iron, coal = chain.links["iron-plate"], chain.links.coal
    T.same({ iron.rate, iron.modules, iron.need }, { 15, 1, 0 }, "iron: one pair, nothing takes it")
    T.eq(iron.coverage, math.huge, "covered")
    T.near(coal.rate, 25.5, 1e-6, "the coal pair, less what it burns itself")
    T.near(coal.demand.burn, 3.6, 1e-6, "the iron pair's drill and furnace")
    T.near(coal.coverage, 25.5 / 3.6, 1e-6, "coverage")
    T.same(iron.inputs, { coal = true }, "the iron module burns coal")
  end)

  T.it("adds what the planned module takes to build, stock and burn, over the pace", function()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    local chain = SupplyChain.analyze(player, { planned = column() })
    local minutes = SupplyChain.BUILD_MINUTES
    -- four burner drills (9 plates, 5 stone each) and four stone furnaces
    T.near(chain.links["iron-plate"].demand.build, 36 / minutes, 1e-6, "iron")
    T.near(chain.links.stone.demand.build, 40 / minutes, 1e-6, "stone")
    -- eight burners kept at 20
    T.near(chain.links.coal.demand.build, 160 / minutes, 1e-6, "its coal")
    T.near(chain.links.coal.demand.burn, 3.6 + 14.4, 1e-6, "burning with the rest")
    T.eq(chain.links.stone.producer, "StoneToChest", "the stone drill")
  end)

  T.it("finds the least covered link, but what it burns first", function()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    built(BurnerToBurnerModule, "coal", 10)
    local constraint, short = SupplyChain.constraint(SupplyChain.analyze(player, { planned = column() }))
    -- stone 0 of 13.3, coal 25.5 of 3.6 + 14.4 + 53.3: the stone drill burns coal
    T.same({ constraint.item, short.item }, { "coal", "stone" }, "coal for the stone drill")
    built(BurnerToBurnerModule, "coal", 20)
    built(BurnerToBurnerModule, "coal", 30)
    constraint = SupplyChain.constraint(SupplyChain.analyze(player, { planned = column() }))
    T.eq(constraint.item, "stone", "76.5 coal of 71.3: stone")
    built(ModuleLibrary.get("StoneToChest"), "stone", 40)
    local chain = SupplyChain.analyze(player, { planned = column() })
    T.eq(SupplyChain.constraint(chain), nil, "nothing short")
    T.near(chain.links.stone.coverage, 15 / (40 / SupplyChain.BUILD_MINUTES), 1e-6, "a drill's 15 stone a minute")
  end)

  T.it("shows what is on hand, but builds for what will run", function()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    for _, x in ipairs({ 10, 20, 30 }) do built(BurnerToBurnerModule, "coal", x) end
    local module = built(ModuleLibrary.get("CoalRing4"), "coal", 40)
    module:entity(1).get_output_inventory().insert{ name = "coal", count = 7 }
    player = Fakes.player{ surface = Lab.surface(), items = { stone = 200, coal = 100 } }
    local chain = SupplyChain.analyze(player, { planned = column() })
    -- the ring's drill keeps 5 of its 7 coal to burn
    T.same({ chain.links.stone.stock, chain.links.coal.stock }, { 200, 102 }, "inventory and outputs")
    -- 200 stone last five columns; a stone drill runs for much longer
    T.eq(SupplyChain.constraint(chain).item, "stone", "still the stone drill")
    T.truthy(SupplyChain.lines(chain)[1]:find("200 on hand", 1, true), SupplyChain.lines(chain)[1])
  end)

  T.it("leaves out what no module makes", function()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    for _, x in ipairs({ 10, 20 }) do built(BurnerToBurnerModule, "coal", x) end
    -- a wooden chest: 2 wood, and no module makes wood
    local chain = SupplyChain.analyze(player, { planned = ModuleLibrary.get("StoneToChest") })
    T.truthy(chain.links.wood and chain.links.wood.coverage == 0, "wood short")
    -- its drill takes a stone furnace, and no module makes stone yet
    T.eq(SupplyChain.constraint(chain).item, "stone", "stone, not wood")
  end)

  T.it("counts what the labs take for the research, packs and the plates they are made of", function()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    built(BurnerToBurnerModule, "coal", 10)
    Lab.entity("lab", { 20.5, 0.5 })
    Lab.entity("small-electric-pole", { 22.5, 0.5 })
    local tech = game.forces.player.technologies.automation
    T.eq(tech.research_unit_energy, 600, "10 s a unit")
    local chain = SupplyChain.analyze(player, { research = "automation" })
    T.same({ chain.research, chain.labs }, { "automation", 1 }, "one lab on automation")
    T.near(chain.links[PACK].demand.research, 6, 1e-6, "a pack every 10 s")
    T.near(chain.links["copper-plate"].demand.research, 6, 1e-6, "a copper plate a pack")
    T.near(chain.links["iron-plate"].demand.research, 12, 1e-6, "a gear a pack")
    -- no machine makes packs and no copper module: the copper first
    local constraint, short = SupplyChain.constraint(chain)
    T.same({ constraint.item, short.item }, { "copper-plate", PACK }, "copper for the packs")
    T.same(chain.links[PACK].inputs, { ["copper-plate"] = true, ["iron-plate"] = true }, "made of plates")
  end)

  T.it("counts a pack machine on our network", function()
    Lab.entity("lab", { 20.5, 0.5 })
    Lab.entity("small-electric-pole", { 22.5, 0.5 })
    Lab.surface().create_entity{ name = "assembling-machine-1", force = game.forces.player,
      position = { 24.5, 0.5 }, recipe = PACK }
    local chain = SupplyChain.analyze(player, { research = "automation" })
    -- crafting speed 0.5, 5 s a pack
    T.near(chain.links[PACK].rate, 6, 1e-6, "6 packs a minute")
    T.near(chain.links[PACK].coverage, 1, 1e-6, "as many as the lab takes")
  end)

  T.it("has no research demand without a lab on a network", function()
    Lab.entity("lab", { 20.5, 0.5 })
    local chain = SupplyChain.analyze(player, { research = "automation" })
    T.same({ chain.research, chain.links[PACK] }, { nil, nil }, "no research")
  end)

  T.it("reads what was made and used from the statistics and tells what stands", function()
    built(BurnerToFurnaceModule, "iron-ore", 0)
    local chain = SupplyChain.analyze(player)
    T.truthy(chain.links["iron-plate"].made >= 0 and chain.links["iron-plate"].used >= 0, "numbers")
    T.eq(chain.links["iron-plate"].stopped["no fuel"], 2, "drill and furnace without fuel")
    local lines = SupplyChain.lines(SupplyChain.analyze(player, { planned = column() }))
    T.truthy(lines[1]:find("^coal: makes 0.0/min") and lines[1]:find("least covered", 1, true), lines[1])
    T.truthy(SupplyChain.summary(chain):find("^chain: coal 0.00"), SupplyChain.summary(chain))
  end)
end)
