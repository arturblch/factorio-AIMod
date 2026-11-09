# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

AIMod is a Factorio mod (Lua, control stage only — there is no `data.lua`) whose bot plays the game for the player: it builds small production "modules" by mining, crafting, walking and placing buildings. It targets **Factorio 2.1** (`info.json`: `factorio_version` 2.1, `base >= 2.1`); the local install is Steam Factorio 2.1.24 without Space Age.

## Running and testing

There is no build step. The mod is loaded straight from this folder through a junction `%APPDATA%\Factorio\mods\AIMod` → repo (the folder Factorio sees must be named `AIMod`, matching `info.json` and the `__AIMod__/` paths).

The Steam build refuses to start its GUI outside Steam ("Steam requires game restart"), and launching it through Steam with a custom `--config` risks Steam Cloud syncing a scratch `player-data.json` over the user's real one. So all automated runs are headless, via `tools/run-headless.ps1`. It copies the repo to `%TEMP%\aimod-headless` (never touching `%APPDATA%\Factorio`), appends a test entry point to the copy's `control.lua` and runs `factorio --test-scenario AIMod/AIPlay` — Factorio 2.1's headless mode **with a real player**.

```bash
powershell -ExecutionPolicy Bypass -File tools\run-headless.ps1 -Unit
```
Unit tests (`tests/unit_runner.lua`): the bot is switched off and all tests run on the first tick; a few seconds. `-Brief` prints only failures and the summary. There is no per-test filter: to focus on one file, temporarily trim the `require` list in `tests/unit_runner.lua`.

```bash
powershell -ExecutionPolicy Bypass -File tools\run-headless.ps1 -Seed "1,4,42,1234567" -Brief
```
Scenario runs (`tests/scenario_test.lua`): the bot plays AIPlay on each map seed until it prints "Completed goals" or `-Ticks` (default 36000) pass; exit code 1 if any seed fails, gives up on a module, or the storage audit finds a problem. `-CursorNoise` additionally moves the player's selection onto some other nearby entity every tick before the bot runs (a mouse moving over things) and fails the seed if anything the bot didn't target gets mined; it relies on mining tasks re-selecting their target every tick. `-FullInventory` fills every empty main-inventory slot with stone bricks the first time the bot is about to mine, and fails the seed if the bot never had to make room. A seed also fails if the character dies (biters; the bot would otherwise carry on with an empty inventory). Without `-Brief` it prints goal transitions, 30 s snapshots (position, inventory, task stack, every drill/furnace with fuel/input/output) and the bot's own `output.log` summary; `-Full` prints every transition. The regression set used so far is 28 seeds: `1,2,4,6,7,8,10,12,42,1009,2018,2024,3027,4036,5045,6054,7063,8072,9081,10090,11099,12108,13117,14126,15135,31337,987654,1234567` (in test mode seeds 2k and 2k+1 give the same map).

Logs: `%TEMP%\aimod-headless\run-<seed>.log` / `unit.log` (Factorio stdout), and the bot's log `...\data\script-output\output.log`. In a normal game the bot log is `%APPDATA%\Factorio\script-output\output.log`.

A windowed run is possible only through Steam, and only after asking the user (it opens a window on their desktop and shows them as in-game): `steam.exe -applaunch 427520 --config <tmp>\config.ini --mod-directory <tmp>\mods --load-scenario AIMod/AIPlay --disable-audio`, with `<tmp>` laid out like the headless work folder (isolated `write-data`, mod copy with `require 'tests/scenario_test'` appended, so its `[test]` lines land in `<tmp>\data\factorio-current.log`). Close it with `CloseMainWindow()`.

Neither test mode nor `--benchmark` can save a game (`game.auto_save` does nothing there), so save/load is covered by the storage audit in `scenario_test.lua`, not by a real round trip.

API reference matching the installed version: `C:\Program Files (x86)\Steam\steamapps\common\Factorio\doc-html\runtime-api.json`. Check it rather than memory — 2.1 differs from 2.0 in places this code touches (e.g. `recipe.has_category()` instead of `recipe.category`, `defines.inventory.crafter_input` instead of `furnace_source`).

## Architecture

**Entry point and lifecycle.** `control.lua` requires every class, registers them, and exposes `AIMod.init_storage / setup_bot / tick_bot`. `on_player_created` → `setup_bot` creates a `ResourceManager` and a `GoalMachine` seeded with the goal list (`BuildModuleTask` for `BurnerToFurnaceModule`, then `BurnerToBurnerModule`); `on_tick` → `tick_bot` for every player that has a character. The test entry points call the same `AIMod.*` functions or wrap the mod's `on_tick` (`script.get_event_handler`), so keep behaviour there rather than in the event closures.

**Classes and storage.** Classes are prototype tables (`X = Task:new()`, instances via `X:new{...}`, `self.__index = self` set lazily). All bot state lives in `storage` (`goal_machines`, `resource_managers`, `unreachable`, `path_results`, `failed_goals`, ...), so instances are saved with the map. **Every class whose instances can end up in `storage` must be listed in `persistent_classes` in `control.lua`** (it calls `script.register_metatable` and sets `__index` up front); otherwise after loading a save the objects have no methods and the bot crashes. No functions may be stored in `storage`. `scenario_test.lua` audits both.

**Goal machine.** `GoalMachine` is a stack (linked list) of tasks. Each tick it checks only the top task: if `achieved(args)` it is popped (nothing else runs that tick), else `tick(args)` runs. A task asks for sub-work by pushing tasks on top (`pushSingle`, `pushStart({a, b})` = a then b), and is re-ticked when they are done — so a parent's `tick` must be safe to call repeatedly and re-plan from current state. `args = {player, machine}`; tasks call `LuaControl` methods on `player` directly.

**Getting items.** `GatherResourceTask{type, qty}` means "have at least `qty` in the main inventory" (`qty` is a total, not a delta — the same convention is used by `MineResourceTask` and `CollectModuleOutputTask`). It asks `ResourceManager:best_resource_source`, which picks in order: a registered module that already has the item in its output → the nearest map entity that drops it when hand-mined (ore/tree/rock, found on demand in radii 32/100/250, derived from prototypes, skipping ore under our buildings and anything in `Unreachable`) → hand-crafting → a module that must first be fueled and waited on. Each source's `gather` pushes the concrete tasks. `CraftRecipeTask` uses `util/recipes.lua` to expand intermediates recursively and only gathers raw items; the game's hand-craft queue makes the intermediates. With `background = true` (used for module buildings) it is done once the crafts are queued; `Inventories.count_with_queue` counts queued items and `PlaceBuildingTask` waits for them.

**What tasks need.** Tasks report what they still want in the inventory via `needs(args)` (`{name = total}`; `GoalMachine:needs` takes the largest total per item over the stack). This decides what `MakeRoomTask` keeps when the inventory is full (the rest goes into a stash chest, registered as a `ChestResourceSource`) and what `WaitForOutputTask` fetches from the map while a module works. A new task that will consume items should implement `needs`.

**Modules.** `controllers/modules/*.lua` are data: `geometry` (tiles relative to tile 0,0 with required ore), `buildings` (type, center relative to the *corner* of tile 0,0 — a 2×2 at `{1,1}` covers tiles 0..1 — and direction), `inputs` (fuel slots) and `outputs` (`slot = "output"` result inventory, or `"fuel"` surplus above `keep`). `BuildModuleTask` finds a spot, crafts missing buildings, then builds a private `instantiate()`d copy, queues fuel for it and registers it as a `ModuleResourceSource`. It is achieved only when every building stands; otherwise it picks the placed ones back up (`mine_entity`), avoids that spot and retries (3 attempts), then records the module in `storage.failed_goals`.

**Walking.** `MoveToPointTask` steers with "feelers" that dodge trees and rocks (the original author's approach). If the character makes no progress for `STUCK_TICKS` it asks the game's pathfinder (`surface.request_path`; the answer arrives via `on_script_path_request_finished` into `storage.path_results`) and follows the waypoints; if that also fails the target entity goes into `Unreachable` and callers pick something else. `reach = true` ends the walk as soon as `can_reach_entity` holds (needed for big rocks). Ore must be walked onto — hand-mining reach is short.

**Scripted control state sticks.** A `walking_state` or `mining_state` set by script persists until changed (a real player's input does not reset it in headless runs). Tasks therefore reset it when they finish (`MoveToPointTask`, `MineResourceTask`, `MineEntityTask` do this in `achieved`). An earlier test harness that reset walking itself hid exactly this bug — prefer testing with the real player.

**Unused code.** `controllers/tasks/pathfindToPointTask.lua` and `util/pathfinding_fringe.lua` are an unfinished A* from the original author; nothing calls them (the game pathfinder is used instead).

## Factorio Lua specifics

- `require` resolves relative to the requiring file first, then the mod root, then `core/lualib`; `..` is not allowed. `require 'util'` therefore loads the core `util` library (this repo's `util/` is a folder), while `require 'util/logger'` loads the repo file.
- Use `storage`, `helpers.write_file`, `prototypes.entity[...]`, `defines.inventory.character_main` (2.x names).
- With a full main inventory the character can't mine: the mining bar keeps filling and nothing is mined or dropped. An entity with several products (a huge rock: stone and coal) is only mined when all of them fit at once. A hand-craft takes its ingredients when queued, and a finished craft waits until its product has a slot, stalling the whole queue. Mining, collecting and crafting tasks check room first (`Inventories.has_room_for` / `has_room_for_all`) and push `MakeRoomTask`.
- Logging goes through `Logger.makeLogger("Name")` → `log(msg, level)`; `Logger.LEVEL` in `util/logger.lua` filters (DEBUG logs every steering step).

## Tests

- `tests/lib/testing.lua` — minimal `describe`/`it`/`before_each` with `T.eq/same/near/truthy/falsy`. `describe` bodies run when the file is loaded, before `game` exists: create anything that touches the game inside `it`/`before_each`.
- `tests/lib/fakes.lua` — a fake player/inventory that records what the bot did (`printed`, `crafted`, `mined`, `walking_state`...) and a fake pathfinding surface; recipes, prototypes and surfaces are real.
- `tests/lib/lab.lua` — a separate surface generated with no ore, trees, cliffs or enemies; `Lab.reset()` flattens the area to grass and tests place exactly what they need (`Lab.ore`, `Lab.patch`, `Lab.water`, `Lab.entity`).
- A new test file must be added to the `require` list in `tests/unit_runner.lua` (Factorio cannot list directories). Shared storage keys are reset in `T.global_before` there.

## Working notes

`PR_NOTES.md` (git-ignored) holds the running notes for pull request descriptions — what changed, why, how it was verified, known limitations. Keep it updated as changes are made.
