# Found blueprints

`catalog.lua` keeps community blueprints for later: 127 burner-era layouts and
small steam plants from [Factorio Prints](https://factorioprints.com), found in
November 2026 through [Blueprint Atlas](https://factorio.menzies.io/?uses=entity:burner-mining-drill)
(the same database, searchable by building). The bot does not build them:
`blueprints/library.lua` lists what it builds. A layout from here goes there as
a library entry, preferably redrawn in `blueprints/src/`.

Each entry has its source page, the game version it was made in, its
entities, and what the bot's parser (`util/blueprint.lua`) makes of it:
`fits = {resource = score}` for every resource it reads with no errors, and a
note. The score is `ModuleLibrary.report`'s: what the module makes a minute,
less the coal it burns, over what it costs. The plain drill and furnace scores
0.986. `blueprint` is a 2.x string: 1.x blueprints count directions 8 to a
turn, and are turned into 16 here. A blueprint made of separate groups
(Nefrums' "Iron and coal" is a coal ring and a row of furnaces) also has an
entry for each group, `part_of` the whole, since a module mines one resource.

**License.** The authors gave none. Credit the source page when you use a layout.

## What is in it

63 of the 127 fit the bot. They come in a few kinds:

| kind | examples | score |
|---|---|---|
| a row of drill → furnace pairs, 1 to 14 of them | Nefrums speedrun "Debut fer", RSNG+ Derek 2.0 "Copper", Pyro "iron drill smelt", Self-Building Rocket "Initial Iron Mining" | 0.986 (iron), 1.126 (copper) |
| a ring of coal drills feeding each other, 2 to 16 | Pyro "coal burner drills", Nefrums "Iron and coal (part 1)", Paige's "Starter Coal" | 0.611 |
| drill → furnace → inserter → chest | Project Gateway "Step 1 - Smelting" | 0.685 |
| drills into a chest, for stone | Self-Building Rocket "Initial Stone Mining", Pedreira | 0.3–0.6 |
| coal on a belt, burner inserters fuelling the drills | Mining Compendium "B1. Burner Tree", "Coal Loader", Debut de partie "Charbon" | 0.14–0.38 |

The other 64 do not fit:
- 25 of the 27 steam plants (the other two also hold burner drills and
  furnaces, which fit): the parser takes mines and smelters only. Kept for
  electricity, plan item 3.4. The best one there is Nefrums' "Power expansion",
  where electric drills on a coal patch feed the boilers themselves.
- drills that drop their ore on the ground, for the player to pick up;
- inserters that have nothing to take from or nowhere to put things inside the
  blueprint, because they feed something outside it;
- belts that end at the edge of the blueprint, with nothing to collect.

`blueprints/library.lua` has the same layouts drawn by us: `furnace-column4/8`
(drills back to back, a furnace on each side) and `coal-ring4/8`.

## Refreshing it

```bash
node tools/found-blueprints.js fetch <dir> <factorio prints id>...
node tools/found-blueprints.js build <dir>...
powershell -ExecutionPolicy Bypass -File tools\run-headless.ps1 -Unit -Brief
node tools/found-blueprints.js checks %TEMP%\aimod-headless\data\script-output\found-checks.txt
```

`build` rewrites the catalog from every downloaded entry (repeats are dropped,
checks of entries still there are kept). The unit test
`tests/unit/found_blueprints_test.lua` writes the bot's checks, and fails when
an entry marked as fitting no longer fits. `node tools/blueprint.js show <string>`
draws any of them.
