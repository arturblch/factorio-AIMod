--[[
  A minimal test framework that runs inside Factorio (the same Lua 5.2 and
  API the mod uses), so no separate Lua install is needed.

    local T = require 'tests/lib/testing'
    T.describe("GoalMachine", function()
      T.before_each(function() ... end)
      T.it("pops achieved goals", function()
        T.eq(actual, expected, "what is compared")
      end)
    end)

  describe/it only register tests; tests/unit_runner.lua runs them.
]]
local T = { suites = {} }
local current

function T.describe(name, define)
  local suite = { name = name, tests = {}, before = {} }
  current = suite
  define()
  current = nil
  T.suites[#T.suites + 1] = suite
end

function T.before_each(fn)
  current.before[#current.before + 1] = fn
end

function T.it(name, fn)
  current.tests[#current.tests + 1] = { name = name, fn = fn }
end

-- Hooks run before every test of every suite (shared state resets).
T.global_before = {}

local function show(value)
  return serpent.line(value, { comment = false, sortkeys = true, nocode = true })
end

local function fail(message)
  error(message, 3)
end

function T.eq(actual, expected, what)
  if actual ~= expected then
    fail((what or "value") .. ": expected " .. show(expected) .. ", got " .. show(actual))
  end
end

-- Deep equality of plain data (tables compared by content).
function T.same(actual, expected, what)
  if show(actual) ~= show(expected) then
    fail((what or "value") .. ":\n    expected " .. show(expected) .. "\n    got      " .. show(actual))
  end
end

function T.near(actual, expected, epsilon, what)
  if type(actual) ~= "number" or math.abs(actual - expected) > (epsilon or 1e-6) then
    fail((what or "value") .. ": expected ~" .. show(expected) .. ", got " .. show(actual))
  end
end

function T.truthy(value, what)
  if not value then fail((what or "value") .. ": expected truthy, got " .. show(value)) end
end

function T.falsy(value, what)
  if value then fail((what or "value") .. ": expected falsy, got " .. show(value)) end
end

-- The error message plus the traceback lines that point into the code
-- under test (the framework's own frames are noise).
local function trim_traceback(err)
  local lines = {}
  for line in tostring(err):gmatch("[^\n]+") do
    if not (line:find("tests/lib/testing.lua", 1, true) or line:find("tests/unit_runner.lua", 1, true)
        or line:find("[C]: in function", 1, true)) then
      lines[#lines + 1] = line
    end
  end
  return table.concat(lines, "\n")
end

-- Runs everything, reports through `report(line)`, returns true if all passed.
function T.run(report)
  local passed, failed = 0, 0
  for _, suite in ipairs(T.suites) do
    for _, test in ipairs(suite.tests) do
      local ok, err = xpcall(function()
        for _, hook in ipairs(T.global_before) do hook() end
        for _, hook in ipairs(suite.before) do hook() end
        test.fn()
      end, debug.traceback)
      if ok then
        passed = passed + 1
        report("PASS " .. suite.name .. " > " .. test.name)
      else
        failed = failed + 1
        report("FAIL " .. suite.name .. " > " .. test.name .. "\n" .. trim_traceback(err))
      end
    end
  end
  report("SUMMARY " .. passed .. " passed, " .. failed .. " failed")
  return failed == 0
end

return T
