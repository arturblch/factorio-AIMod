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
  -- DDDD   four burner drills in a ring, each feeding the next its coal
  -- D>Dv   (the layout of many community starts): no fuel to bring
  -- DDDD
  -- DDD<
  ["coal-ring4"] = "0eNqdkMFqwzAMhl/F6Owe4rjd4gfYS5RRnERLBY5cbGe0BL97sXvpRhisJyH06/uEVujdgpdAnMCs4GyPDgx8+CWIfgmMQYyBnIuCWFgRiCfxhTiWinY4C5/OGEACJZzBPNEk0OA5gjmuEGli64qA7YwlVtG7mZh42lUDZAnEI17BNFlu7AzePodU/pSAnCgRPiy1uZ14mXsMYBr5l03CxUdK5LkorjV+q2oYKeDwmOhyyS+u+h+33eK+b3DbV7jtT26jNsD6lUe0ufz3G0Osk/1BdXutdNcdGv2mcr4DsRC/VA==",
  -- DDDDDDDD   the same with eight drills
  -- D>D>D>Dv
  -- DDDDDDDD
  -- DDD<D<D<
  ["coal-ring8"] = "0eNqd0s1qxCAQB/BXkTm7h5ivjfc+RSklH9NkwEwWY8ouwXcvupdtCSXJSWTG3190VmjMgjdL7ECvYOoGDWh4o35wolksoxWdJWNmQSxqYYl78YXYhRXrdhCTG9CCBHI4gn7hJFA78Qz6fYWZeq5NSOB6xNAW6ctITNxfYgJ4CcQd3kEnXm6caaf6tUn5DwnIjhzhMyVuHp+8jA1a0In8L03CbZrJ0cQh4h7bHzEaOrLYPitZuMkfVx1z071ueszN97rZMbfccq8bbn7GTX+7idqAizMPsQcuz/zcHvh6ZtRSHyb4G+0cK3mhqjxTWVUVSVYq738AxxU2qA==",
  -- FFDDDDFF   four burner-furnace pairs back to back in one place: the
  -- FFD<D>FF   same plates as four BurnerToFurnace, but one stop to fuel
  -- FFDDDDFF   and empty them, on a 4x4 patch of ore
  -- FFD<D>FF
  ["furnace-column4"] = "0eNqdktFugzAMRX8l8nN4AAIMfmWqphBcZg1MFcLUCuXfp6SbNm1sK32KIjvn2FdZoR0WPFliB80Kg25xgAaUaBfLaEVnaRhm0WrzItwUTylQm2dx1Ia4F1rMbmIUx8WyNggSyOEIzReuBDITz9A8rjBTz3oIKtYjhrboSUZi4j6JOvASiDs8Q5N6ufEmGpMP42d35g8SkB05wqsuXi5PvIwtWmhSuY2QcJpmcjRxsJxj4yXYg/4bI5N/jf6DlL+TJHRk0VwrabYBzveBiy2w2uCqW5eufl+62BdcvsUo7wkuvyG46p7g8v+De9gXXO7D93tFO8dKUWZ1oTJV12Wqqsz7N8aIJcU=",
  -- FFDDDDFF   eight pairs, on a 4x8 patch
  -- FFD<D>FF
  -- ...
  ["furnace-column8"] = "0eNqdlNFOgzAUQH+luc8lsYXSwa8YYwrr5o1wWUoxWxb+3dBpNFod5YmQXs7pPQ9coekme3JIHuordKaxHdSwY83kyDq2d9h1I2tM+8r8EJ6cWdO+sINpkY7MsNEPZNlhcmRaCxzQ2x7qb1wO2A40Qv14hRGPZLpFRaa3y1jwZD0S0jELOpg5IO3tGWox88g3wZh9Gr+m5fzEwZJHj/amCy+XZ5r6xjqoBY8jOJyGET0OtFjOYfCy2Bf9D4bk/139Fyn/IHHYo7Pt7UTICDhPA6sYuIhwi7VL67+XVmnh8hij3BIuXxFObwmX3w+3SwsXXbpKC6diDPGwpZxaUU6ILenU/XRCprWL752nxdNRSLElnl4TT22Jp1fEK9Pi6Xn5771ZN4YTVcpKFbKoqlIUWs7zO6ZB+QQ=",
  --     SSS   steam power with a lab: an offshore pump (W) facing the water, a
  --    pSSS   boiler (O) the bot keeps fuelled, a steam engine (S) above it, a
  --  LLLSSS   pole (p) reaching the engine and the lab (L)
  --  LLLOOO>W
  ["steam-power"] = "0eNp9kNFqwzAMRX/F6FkpxHMy6t/Y4yjDSdVW4NjGcdaW4n8fSdotrNnebKRzdKUbNHagENkl0DewpiELGt4SmU4Ef6YozpxOwghrGi2ME/5w6E8+kghDF1AY0Xi2FMdXP1HkjuwIEDhRB3oxAIFb73rQ7zfo+eiMHWc60xFomODiDmcEdnu6gC4zrjRb0yx6ZN4hkEucmGb79Ll+uKFrKIIu8QHOYQEh+J4TezdKL6DVpkK4gq7zOO8XLr/xx/LFuPyzpX5YNlVG2HOkdq6qFesLrq7+ZzS5qdbCqR9NZ6wtyFKbIrdF8HbFJv+3Vbg88RNd3mk10juET4r9VK1qua2UVNttXapXmfMXCevE+A==",
  --  AAApLLL   red science: an assembling machine (A) making automation
  --  AAA<LLL   science packs, an inserter taking them into a lab (L), a pole (p)
  --  AAA LLL   reaching all three and wired to the power module's
  ["red-science"] = "0eNp9kNFqwzAMRX/F6NkZS5p01J/R11GG4ohO1FaC7YyVkn8fTtu0o92ejJDuPff6BK0baQgsCcwJHLbkwMCWOhUtk1gyCkVhjORbx7JXHu0nCymPhzzimHqPiXu5CtSA9hB1lrFEComCYkm9QuWwBQ2cyIO5A2tg20sE836CyHtBl7MIegIDN0BxARQZAJMGlo6+wZSTfqLLrNtNNe00kCROTGfQPBw/ZPQtBTClXoBL1+LStShBw9BHzikyIkNfGg3H+Z00BLI8/J/2gVgtxOs3PVJWvygdB7LnbVk9cVzp+/IPZs2d2RN1vaijR+cKcmRTYFsMvaO/o71mt52GLwpx3jbratPUVb3ZrMv6rZqmH2atzBw=",
  ["belt-line"] ="0eNqV1tFugjAUBuBXac51NWtpQXiAvcRiFtCzpQkW0xajMbz7As5MN6bnXEKb72+hf+AMTdvjPjifoDpDWzfYQgWv7oCi6YPHILbBtW0UnU+dqEWDbZLio+uDcD5iSBiicOPYdC+mzqP46IOvNxhBgku4g+omRYLbdD5C9XaG6D593Y7Bvt4hVJBC7eO+C2kx5sAgwfktHqFSg5yZPqUtvtNuZuthLQF9csnhJWm6OL37ftdggErJK3HZ5GLnvPOfi2mvIGHfRZdc58es4zT9NK0Bti7g5jKyGpf0y9U8N6O6Gc+1VNfw3ILqWp5bUt1c/nNS/r6y5eUh6KW9Z80MW5BZzWFXZDbjsCWZNRxWvZBdy3IV2c1Zria7BcvNyO6K5RqyW7JcSy/FCwtmtI1VN0Xvm2IVTtEbp1iVU/TOKVbpNL10itU6TW+dYtVO//nGXf8DHpy3bGmHOStjWPqJZRiWeWJZhpU/sX5adP+7MlOiyZlXCrKSPVBWZMU+UEqyUlyVtYQDhjgN2VyX1mhTlrkyhR6GL0ngeso=",
};

return {
  blueprints = BLUEPRINTS,
  modules = {
    -- several pairs in one place first (the community's burner starts): the
    -- same score as a pair, but one stop to fuel and empty them; growth
    -- (GrowthTask) builds these. A goal of N a minute takes the cheapest
    -- module that covers it (ModuleLibrary.producer), and the start, without
    -- the plates for a column, the pair. Growth on seeds 1, 4, 42, 1234567:
    -- 103 021 in 30 minutes against 89-95 thousand with pairs only
    -- (blueprints/trials.json); a column stops as a whole when one of its
    -- drills runs out of ore (plan item 1.2).
    {name="IronColumn4", blueprint="furnace-column4", resource="iron-ore", product="iron-plate"},
    {name="BurnerToFurnace", blueprint="burner-furnace", resource="iron-ore", product="iron-plate"},
    {name="CopperColumn4", blueprint="furnace-column4", resource="copper-ore", product="copper-plate"},
    {name="BurnerToFurnaceCopper", blueprint="burner-furnace", resource="copper-ore", product="copper-plate"},
    {name="StonePairFurnace", blueprint="pair-furnace", resource="stone", product="stone-brick", off=true},
    {name="BurnerToFurnaceStone", blueprint="burner-furnace", resource="stone", product="stone-brick"},
    {name="CoalRing4", blueprint="coal-ring4", resource="coal", product="coal"},
    {name="BurnerToBurner", blueprint="coal-pair", resource="coal", product="coal"},
    -- power: built by GrowthTask once the burner base runs (plan 3.4); it
    -- makes no items, so no goal ever picks it
    {name="SteamPower", blueprint="steam-power", resource="water"},
    -- research: red science packs from an assembling machine, once
    -- automation is researched; GrowthTask builds it with its pole in reach
    -- of ours (it needs no resource, only our electric network; plan 3.5)
    {name="RedScience", blueprint="red-science"},
    -- stone into a chest: no goal asks for stone (the map has it), but growth
    -- builds it once mining stone by hand holds the bot up (GrowthTask,
    -- util/bottleneck.lua: 40 stone a column of four pairs), and gathers
    -- take the stone from its chest after that (plan 3.12)
    {name="StoneToChest", blueprint="burner-chest", resource="stone", product="stone"},
    -- off: with burners, inserters and belts cost more and add buildings to
    -- fuel for the same plates (/aimod-modules shows each one's score);
    -- /aimod-use can switch them on
    {name="IronToChest", blueprint="furnace-chest", resource="iron-ore", product="iron-plate", off=true},
    {name="IronBeltLine", blueprint="belt-line", resource="iron-ore", product="iron-plate", off=true},
    -- off: eight pairs take too long to build (in 10 minutes of growth some
    -- were never finished)
    {name="IronColumn8", blueprint="furnace-column8", resource="iron-ore", product="iron-plate", off=true},
    {name="CopperColumn8", blueprint="furnace-column8", resource="copper-ore", product="copper-plate", off=true},
    {name="CoalRing8", blueprint="coal-ring8", resource="coal", product="coal", off=true},
  },
};
