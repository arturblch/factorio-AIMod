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

BurnerToBurnerModule = BaseModule:new{
  name="BurnerToBurner",
  resource="coal",
  geometry={
    {position={x=0, y=0}, resource="coal"},
    {position={x=0, y=1}, resource="coal"},
    {position={x=1, y=0}, resource="coal"},
    {position={x=1, y=1}, resource="coal"},
    {position={x=2, y=0}, resource="coal"},
    {position={x=2, y=1}, resource="coal"},
    {position={x=3, y=0}, resource="coal"},
    {position={x=3, y=1}, resource="coal"}
  },
  -- the two drills face each other and keep each other fueled
  buildings={
    {type="burner-mining-drill", position={x=1, y=1}, direction=defines.direction.east},
    {type="burner-mining-drill", position={x=3, y=1}, direction=defines.direction.west}
  },
  inputs={
    {building=1, type="coal", slot="fuel", ongoing=false}
  },
  -- drills have no output inventory: surplus coal piles up in the fuel slots
  outputs={
    {building=1, type="coal", slot="fuel", keep=5},
    {building=2, type="coal", slot="fuel", keep=5}
  }
};
