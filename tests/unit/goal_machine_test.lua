local T = require 'tests/lib/testing'

-- A task that is done when told so and counts its ticks.
local Step = Task:new()
function Step:achieved(args) return self.done == true end
function Step:tick(args) self.ticks = (self.ticks or 0) + 1 end
local function step(name) return Step:new{ name = name } end

local function names(machine)
  local result, g = {}, machine.goals
  while g do
    result[#result + 1] = g.current.name
    g = g.next
  end
  return result
end

T.describe("GoalMachine", function()
  T.it("is achieved without goals", function()
    T.truthy(GoalMachine:new():achieved{}, "achieved")
  end)

  T.it("pushSingle puts a goal on top", function()
    local m = GoalMachine:new()
    m:pushSingle(step("a"))
    m:pushSingle(step("b"))
    T.same(names(m), { "b", "a" }, "goals")
  end)

  T.it("pushStart puts a list on top, first item first", function()
    local m = GoalMachine:new()
    m:pushSingle(step("old"))
    m:pushStart({ step("a"), step("b"), step("c") })
    T.same(names(m), { "a", "b", "c", "old" }, "goals")
  end)

  T.it("pushNext inserts right after the current goal", function()
    local m = GoalMachine:new()
    m:pushStart({ step("current"), step("later") })
    m:pushNext({ step("a"), step("b") })
    T.same(names(m), { "current", "a", "b", "later" }, "goals")
  end)

  T.it("enqueueGoals appends at the end", function()
    local m = GoalMachine:new()
    m:pushSingle(step("first"))
    m:enqueueGoals({ step("a"), step("b") })
    T.same(names(m), { "first", "a", "b" }, "goals")
  end)

  T.it("ticks the current goal until it is achieved, then pops it", function()
    local m = GoalMachine:new()
    local a, b = step("a"), step("b")
    m:pushStart({ a, b })
    m:tick{}
    m:tick{}
    T.eq(a.ticks, 2, "ticks of a")
    a.done = true
    m:tick{} -- pops a, doesn't tick b yet
    T.same(names(m), { "b" }, "goals after pop")
    T.eq(b.ticks, nil, "b not ticked in the popping tick")
    m:tick{}
    T.eq(b.ticks, 1, "ticks of b")
  end)
end)
