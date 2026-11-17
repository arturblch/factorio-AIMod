--[[
  The modules the bot builds, as blueprints. Edit this list to change what
  the bot builds and in what order it prefers them: for an item it takes
  the first module here that makes it and that it hasn't given up on.

  Each entry:
   - name: the module's name (logs, storage.failed_goals, the plan drawn
     in game); a global <name>Module holds it (controllers/modules/library.lua)
   - blueprint: a key of BLUEPRINTS below, or a blueprint string itself
   - resource: what its drills mine
   - product: (optional) what it is there for; checked against its outputs
   - off: (optional) true to keep it listed without building it

  A blueprint string can come from the game (blueprint, Export string),
  from sites such as factorioprints.com, or from
  `node tools/blueprint.js encode blueprints/src/<name>.json` (the sources
  of the ones below); `node tools/blueprint.js show <string>` draws one.
  What the bot makes of a blueprint (ore tiles, fuel, where it takes the
  product) is worked out in util/blueprint.lua.
]]
local BLUEPRINTS = {
  -- DDFF   a burner drill facing a stone furnace
  -- D>FF
  ["burner-furnace"] = "0eNp9js1qwzAQhF/FzFk+WHFSrGNfI4Tgn21YkFdBkkOC0bsHKQktbehx2ZnvmxWDXejsWSLMCtsPZGHwuXghX02era2iq0J0QtXX4qUfCQocaYb50VXg0UmA2a8IfJLeZpz0M+VYodUzC8upLlAkBZaJrjBNUm86xVi/jN9pnQ4KJJEj00NXjttRlnkgD9Oo/7QKZxc4spPsupb4rWzAxJ7Gx6fNk35xtXo/7Q9x8yTmoRfyoXy2O91tW9123a5pP3RKdyJWfww=",
  -- DDDD   two burner drills feeding each other coal
  -- D>D<
  ["coal-pair"] = "0eNqVjsFqwzAQRH9FzFk5WHVSrO/orYQi21tnQV4FSW4SjP49WLmEEgo9Djv73qzo/ULnyJJhV3jXk4fFxyWofolCUY2RvU/qm2hkmRS54aRCPlGEBmeaYZ8QGjwESbCfKxJP4vxGFTfTVqvA3czCMu0qF0WDZaQrbFP0i58huOeSKUcNksyZ6WGp4fYly9xThG30XzaNc0icOcimuNb6raoxcqThcWm3Jb+45n/ct1fcpq7/oZhq3B9Mt29N23WHpn03pdwBpt2FCA==",
  -- DDc    a burner drill into a wooden chest
  -- D>
  ["burner-chest"] = "0eNp9js1qwzAQhF9FzFkOtbBTrGNfI5TgnyVdkFdBkpsEo3cvlg8tbehx2ZnvmxWDW+gaWBLsCtcP5GDxtgShoKbAzimW5FWvbt5PJGr8oJigwYlm2B91DR69RNjTisgX6d1GlH6mLVaA1czCcqkKF1mDZaI7bJ31k84urHbhd9jkdw2SxIlpt5XjcZZlHijA1vo/q8bVR07sZVPdS/xRJmDiQOP+abZFv7hGP132B2gObUG+HNq8bf2kEMu3PZqubUzTdce6eTU5fwFguH/q",
  -- DDFF<c a burner drill, a stone furnace and a burner inserter emptying it
  -- D>FF   into a wooden chest
  ["furnace-chest"] = "0eNpt0N1qwzAMBeBXMbp2yuLaHfFlX2OMkR+tEzhysZ2tJeTdR5yWdU0ujcV3jjRC4wY8B+IEdgRXN+jAwnEIjEF0gZyTIibPKD6HwHWLUhBHDAmDIE5e1OLH+w5ZtF8YE0ighD3YB1cCtZ4j2LcRIp24dnMU1z2ChWwXNxsmCcQdXsCWk9yYXqKKJepvWE3vEpATJcIlJz+uHzz0DQawpbwLTd6s6ImJT0VeECScfaREnueoSx6/5grQUcB2+dFzoydXye09VuL+Jm4Y++du9/uuFb0z2XnZmf/dSrUBa7l5tpVqHtT5kN8YYv41B1UZrXRVHUr9qqbpF0Knusc=",
  -- DDFFDD two burner drills facing one stone furnace: a brick takes 2 stone,
  -- D>FF<D so one drill keeps the furnace busy only 40% of the time
  ["pair-furnace"] = "0eNqVkEFqwzAQRa8iZi0vrNgp1jm6KyXI9sQMyKMgyU2C0d2DlISU1hS6GRjm672PVujtgidPHEGvYE2PFjS8n53oF8/oxejJ2iCOZiCehGMUIeZ5XDybAUECRZxBfwNJoMFxAP2xQqCJjc1sNjPmWMFWMzHxVBU6JAnEI15A10luvCnG6ml8pVX6lIAcKRLedWW5HniZe/Sga/mXVsLJBYrkOLsuJX4tHWAkj8P90uRKP7hKblf7Rdw9iBuM3f+6tVvd6vIDX+hDWdu96tpGNV23r5s3ldINJKqhrg==",
  -- DDDDDDDDDD        five burner drills onto a belt, four burner inserters
  -- DvDvDvDvDv        into four stone furnaces: 5 drills feed 4 furnaces
  --  >>>>>>>>>>>>>>>>  exactly (1.25 ore/s)
  --            i i i i
  --            FFFFFFFF
  ["belt-line"] = "0eNqV1tFugjAUBuBXac51NWtpQXiAvcRiFtCzpQkW0xajMbz7As5MN6bnXEKb72+hf+AMTdvjPjifoDpDWzfYQgWv7oCi6YPHILbBtW0UnU+dqEWDbZLio+uDcD5iSBiicOPYdC+mzqP46IOvNxhBgku4g+omRYLbdD5C9XaG6D593Y7Bvt4hVJBC7eO+C2kx5sAgwfktHqFSg5yZPqUtvtNuZuthLQF9csnhJWm6OL37ftdggErJK3HZ5GLnvPOfi2mvIGHfRZdc58es4zT9NK0Bti7g5jKyGpf0y9U8N6O6Gc+1VNfw3ILqWp5bUt1c/nNS/r6y5eUh6KW9Z80MW5BZzWFXZDbjsCWZNRxWvZBdy3IV2c1Zria7BcvNyO6K5RqyW7JcSy/FCwtmtI1VN0Xvm2IVTtEbp1iVU/TOKVbpNL10itU6TW+dYtVO//nGXf8DHpy3bGmHOStjWPqJZRiWeWJZhpU/sX5adP+7MlOiyZlXCrKSPVBWZMU+UEqyUlyVtYQDhjgN2VyX1mhTlrkyhR6GL0ngeso=",
};

return {
  blueprints = BLUEPRINTS,
  modules = {
    {name="BurnerToFurnace", blueprint="burner-furnace", resource="iron-ore", product="iron-plate"},
    {name="BurnerToFurnaceCopper", blueprint="burner-furnace", resource="copper-ore", product="copper-plate"},
    {name="StonePairFurnace", blueprint="pair-furnace", resource="stone", product="stone-brick", off=true},
    {name="BurnerToFurnaceStone", blueprint="burner-furnace", resource="stone", product="stone-brick"},
    {name="BurnerToBurner", blueprint="coal-pair", resource="coal", product="coal"},
    -- off: with burners, inserters and belts cost more and add buildings to
    -- fuel for the same plates (/aimod-modules shows each one's score), and
    -- a chest of stone is no goal of its own; /aimod-use can switch them on
    {name="IronToChest", blueprint="furnace-chest", resource="iron-ore", product="iron-plate", off=true},
    {name="IronBeltLine", blueprint="belt-line", resource="iron-ore", product="iron-plate", off=true},
    {name="StoneToChest", blueprint="burner-chest", resource="stone", product="stone", off=true},
  },
};
