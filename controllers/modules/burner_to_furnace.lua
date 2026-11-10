--[[
Base Modules:
 - Geometry
    - List of tiles and types
 - Buildings and their positions and directions
 - Inputs and Outputs
    - consumers of fuel/recipe ingredients
    - providers of some end product
--]]
require 'base_module'

-- A burner drill on `ore` feeding the stone furnace east of it, which smelts
-- the ore into `product`. One layout for every ore a stone furnace takes.
function BaseModule.burnerToFurnace(name, ore, product)
  return BaseModule:new{
    name=name,
    resource=ore,
    geometry={
      {position={x=0, y=0}, resource=ore},
      {position={x=0, y=1}, resource=ore},
      {position={x=1, y=0}, resource=ore},
      {position={x=1, y=1}, resource=ore},
      {position={x=2, y=0}},
      {position={x=2, y=1}},
      {position={x=3, y=0}},
      {position={x=3, y=1}}
    },
    buildings={
      {type="burner-mining-drill", position={x=1, y=1}, direction=defines.direction.east},
      {type="stone-furnace", position={x=3, y=1}}
    },
    inputs={
      {building=1, type="coal", slot="fuel", ongoing=true},
      {building=2, type="coal", slot="fuel", ongoing=true}
    },
    outputs={
      {building=2, type=product, slot="output"}
    }
  };
end

BurnerToFurnaceModule = BaseModule.burnerToFurnace("BurnerToFurnace", "iron-ore", "iron-plate");
BurnerToFurnaceCopperModule = BaseModule.burnerToFurnace("BurnerToFurnaceCopper", "copper-ore", "copper-plate");
BurnerToFurnaceStoneModule = BaseModule.burnerToFurnace("BurnerToFurnaceStone", "stone", "stone-brick");
