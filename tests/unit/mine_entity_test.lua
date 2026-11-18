local T = require 'tests/lib/testing'
local Fakes = require 'tests/lib/fakes'
local Lab = require 'tests/lib/lab'

local function tick(task, player) task:tick{ player = player, machine = GoalMachine:new() } end

--[[
  The character mines whatever is selected. Tree selection boxes are tall
  (tree-02-red: 1.8 x 2.8 tiles around a 0.8 x 0.8 trunk) and overlap, and
  where two overlap the game selects the one in front. Seen on seed 4: the bot
  went for tree-02-red (27.125, -46.375) and felled the one at (27.6, -45.1).
  The same two trees here, moved next to the origin.
]]
T.describe("MineEntityTask on trees that overlap (real character)", function()
  local behind, front, character
  T.before_each(function()
    Lab.reset()
    behind = Lab.entity("tree-02-red", { 2.125, 1.625 }, "neutral")
    front = Lab.entity("tree-02-red", { 2.6, 2.9 }, "neutral")
    character = Lab.entity("character", { 3.5, 1 }) -- within reach of both
  end)

  T.it("a point on the tree behind selects the one in front", function()
    -- where the task used to select: the top of the collision box
    local y = behind.position.y + behind.prototype.collision_box.left_top.y
    character.update_selected_entity({ x = behind.position.x, y = y })
    T.eq(character.selected, front, "selected")
  end)

  T.it("selects and mines exactly the tree behind", function()
    T.truthy(character.can_reach_entity(behind), "in reach")
    tick(MineEntityTask:new{ entity = behind }, character)
    T.eq(character.selected, behind, "selected")
    T.truthy(character.mining_state.mining, "mining")
  end)

  T.it("selects the tree in front when that is the target", function()
    T.truthy(character.can_reach_entity(front), "in reach")
    tick(MineEntityTask:new{ entity = front }, character)
    T.eq(character.selected, front, "selected")
  end)

  T.it("takes the selection back from whatever else got selected", function()
    character.update_selected_entity(front.position)
    T.eq(character.selected, front, "selected before")
    tick(MineEntityTask:new{ entity = behind }, character)
    T.eq(character.selected, behind, "selected after")
  end)
end)

T.describe("MineEntityTask on something it can't select", function()
  T.before_each(function() Lab.reset() end)

  T.it("doesn't mine it, and gives it up after 2 s", function()
    local tree = Lab.entity("tree-01", { 2.5, 2.5 }, "neutral")
    local player = Fakes.player{ surface = Lab.surface(), selects = false }
    player.mining_state = { mining = true }
    local task = MineEntityTask:new{ entity = tree }
    tick(task, player)
    T.falsy(player.mining_state.mining, "not mining")
    T.falsy(task:achieved{ player = player }, "at first")
    task.unselectable_since = game.tick - 120
    tick(task, player)
    T.truthy(Unreachable.is(tree), "unreachable")
    T.truthy(task:achieved{ player = player }, "after 2 s")
    T.falsy(player.mining_state.mining, "stopped mining")
  end)

  T.it("forgets the wait once it gets selected", function()
    local tree = Lab.entity("tree-01", { 2.5, 2.5 }, "neutral")
    local player = Fakes.player{ surface = Lab.surface() }
    local task = MineEntityTask:new{ entity = tree, unselectable_since = game.tick - 120 }
    tick(task, player)
    T.eq(player.selected, tree, "selected")
    T.eq(task.unselectable_since, nil, "timer reset")
    T.falsy(Unreachable.is(tree), "unreachable")
    T.truthy(player.mining_state.mining, "mining")
  end)
end)
