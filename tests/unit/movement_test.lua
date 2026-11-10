local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'

local function walk_to(x, y, fields)
  local task = MoveToPointTask:new{ x = x, y = y }
  for k, v in pairs(fields or {}) do task[k] = v end
  return task
end

-- what a stuck check sees: no movement and no getting closer for longer
-- than allowed
local function pretend_stuck(task, player)
  task.progress_position = { x = player.position.x, y = player.position.y }
  task.best_distance = util.distance(player.position, { x = task.x, y = task.y })
  task.progress_tick = game.tick - 1000
  task.closer_tick = game.tick - 1000
end

T.describe("MoveToPointTask bearings", function()
  local task = walk_to(0, 0)

  T.it("measures bearings clockwise from north", function()
    local player = Fakes.player()
    T.near(task:getBearingToTarget(player, { x = 0, y = -5 }), 0, 1e-6, "north")
    T.near(task:getBearingToTarget(player, { x = 5, y = 0 }), 90, 1e-6, "east")
    T.near(task:getBearingToTarget(player, { x = 0, y = 5 }), 180, 1e-6, "south")
    T.near(task:getBearingToTarget(player, { x = -5, y = 0 }), 270, 1e-6, "west")
    T.near(task:getBearingToTarget(player, { x = 5, y = -5 }), 45, 1e-6, "north-east")
  end)

  T.it("turns bearings into the 8 walking directions", function()
    local expected = { [0] = "north", [30] = "northeast", [90] = "east", [135] = "southeast",
      [180] = "south", [225] = "southwest", [270] = "west", [315] = "northwest", [350] = "north" }
    for bearing, direction in pairs(expected) do
      T.eq(task:getDirection(bearing), direction, "bearing " .. bearing)
    end
  end)
end)

T.describe("MoveToPointTask", function()
  T.it("stops the character when it arrives", function()
    local player = Fakes.player{ position = { x = 10.5, y = 0 } }
    player.walking_state = { walking = true, direction = defines.direction.east }
    T.truthy(walk_to(10, 0):achieved{ player = player }, "achieved")
    T.falsy(player.walking_state.walking, "still walking")
  end)

  T.it("is not done while far away", function()
    local player = Fakes.player{ position = { x = 0, y = 0 } }
    T.falsy(walk_to(10, 0):achieved{ player = player }, "achieved")
  end)

  T.it("can stop as soon as the entity is within reach", function()
    local rock = { valid = true, name = "huge-rock", position = { x = 10, y = 0 } }
    local player = Fakes.player{ can_reach = function(entity) return entity == rock end }
    T.truthy(walk_to(10, 0, { entity = rock, reach = true }):achieved{ player = player }, "with reach")
    T.falsy(walk_to(10, 0, { entity = rock }):achieved{ player = player }, "without reach")
  end)

  T.it("asks the pathfinder the first time it gets stuck", function()
    local surface = Fakes.pathfinding_surface(7)
    local player = Fakes.player{ surface = surface }
    local task = walk_to(10, 0)
    pretend_stuck(task, player)
    task:checkProgress(player)
    T.eq(#surface.requests, 1, "path requests")
    T.same(surface.requests[1].goal, { x = 10, y = 0 }, "goal")
    T.eq(task.request_id, 7, "request id")
    T.falsy(task.stuck, "gave up")
  end)

  T.it("asks the pathfinder when walking doesn't bring it closer", function()
    local surface = Fakes.pathfinding_surface(7)
    local player = Fakes.player{ surface = surface, position = { x = -30, y = 0 } }
    local task = walk_to(10, 0)
    task.best_distance = 5 -- it was 5 tiles away, now it is 40, and it keeps moving
    task.closer_tick = game.tick - 1000
    task:checkProgress(player)
    T.eq(#surface.requests, 1, "path requests")
  end)

  T.it("gives steering a while to get round an obstacle", function()
    local surface = Fakes.pathfinding_surface(7)
    local player = Fakes.player{ surface = surface, position = { x = -30, y = 0 } }
    local task = walk_to(10, 0)
    task.best_distance = 5
    task.closer_tick = game.tick - 300 -- 5 s
    task:checkProgress(player)
    T.eq(#surface.requests, 0, "path requests")
  end)

  T.it("counts getting closer as progress", function()
    local surface = Fakes.pathfinding_surface(7)
    local player = Fakes.player{ surface = surface, position = { x = 0, y = 0 } }
    local task = walk_to(10, 0)
    task.best_distance = 12
    task.closer_tick = game.tick - 1000
    task:checkProgress(player)
    T.eq(#surface.requests, 0, "path requests")
    T.eq(task.best_distance, 10, "closest so far")
  end)

  T.it("turns the short way round past north", function()
    Lab.reset()
    -- the target is a little east of due north, the character heads a little west of it
    local player = Fakes.player{ surface = Lab.surface(), position = { x = 0.5, y = 0.5 } }
    local task = walk_to(1.5, -20)
    task.current_bearing = 355
    task:tick{ player = player, machine = GoalMachine:new() }
    T.truthy(task.current_bearing < 10, "bearing " .. task.current_bearing)
    T.eq(player.walking_state.direction, defines.direction.north, "direction")
  end)

  T.it("gives up and remembers the target the second time", function()
    local rock = { valid = true, name = "huge-rock", position = { x = 10, y = 0 } }
    local player = Fakes.player{ surface = Fakes.pathfinding_surface(7) }
    local task = walk_to(10, 0, { entity = rock, reach = true, path_requested = true })
    pretend_stuck(task, player)
    task:checkProgress(player)
    T.truthy(task.stuck, "gave up")
    T.truthy(Unreachable.is(rock), "remembered as unreachable")
    T.truthy(task:achieved{ player = player }, "achieved (gave up)")
  end)

  T.it("follows the pathfinder's waypoints", function()
    local player = Fakes.player{ position = { x = 0, y = 0 } }
    local task = walk_to(10, 0, { path_requested = true, request_id = 7 })
    storage.path_results = { [7] = { path = {
      { position = { x = 0.1, y = 0 } }, -- already there
      { position = { x = 5, y = 0 } },
    } } }
    task:tick{ player = player, machine = GoalMachine:new() } -- picks up the answer
    T.eq(storage.path_results[7], nil, "answer consumed")
    task:tick{ player = player, machine = GoalMachine:new() } -- starts walking
    T.eq(task.waypoint, 2, "skipped the waypoint it stands on")
    T.same(player.walking_state, { walking = true, direction = defines.direction.east }, "walking")
  end)

  T.it("waits, standing, for the pathfinder's answer", function()
    local player = Fakes.player()
    player.walking_state = { walking = true, direction = defines.direction.east }
    local task = walk_to(10, 0, { path_requested = true, request_id = 7 })
    storage.path_results = {}
    task:tick{ player = player, machine = GoalMachine:new() }
    T.falsy(player.walking_state.walking, "walking")
    T.falsy(task.stuck, "gave up")
  end)

  T.it("gives up when there is no route", function()
    local rock = { valid = true, name = "huge-rock", position = { x = 10, y = 0 } }
    local player = Fakes.player()
    local task = walk_to(10, 0, { entity = rock, path_requested = true, request_id = 7 })
    storage.path_results = { [7] = { try_again_later = false } }
    task:tick{ player = player, machine = GoalMachine:new() }
    T.truthy(task.stuck, "gave up")
    T.truthy(Unreachable.is(rock), "remembered as unreachable")
  end)
end)

T.describe("Unreachable", function()
  T.it("remembers entities by name and position", function()
    local rock = { valid = true, name = "huge-rock", position = { x = 1, y = 2 } }
    local other = { valid = true, name = "huge-rock", position = { x = 3, y = 2 } }
    Unreachable.mark(rock)
    T.truthy(Unreachable.is(rock), "marked")
    T.falsy(Unreachable.is(other), "other rock")
  end)

  T.it("forgets nothing but ignores invalid entities", function()
    local rock = { valid = true, name = "huge-rock", position = { x = 1, y = 2 } }
    Unreachable.mark(rock)
    rock.valid = false
    T.falsy(Unreachable.is(rock), "invalid")
  end)
end)

T.describe("Fringe (pathfinding queue)", function()
  local function path(total, heuristic, name) return { name = name, score = { total = total, heuristic = heuristic } } end

  T.it("pops the cheapest path first", function()
    local fringe = Fringe:new()
    fringe:add(path(5, 5, "ten"))
    fringe:add(path(1, 1, "two"))
    fringe:add(path(3, 4, "seven"))
    T.eq(fringe:size(), 3, "size")
    T.eq(fringe:pop().name, "two", "first")
    T.eq(fringe:pop().name, "seven", "second")
    T.eq(fringe:pop().name, "ten", "third")
    T.eq(fringe:size(), 0, "size after")
  end)
end)
