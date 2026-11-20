require 'task'
require 'util/logger'
require 'util/economy'

--[[
  PlanTask (plan 2.11)
  Runs a search for growth's next module (Economy.search) a few plans a
  tick, so that a big search - many candidates, a deep beam - spreads over
  ticks instead of stalling the game in one. Factorio has no coroutines, so
  the search is plain data and lives in the task (and so in storage: a
  player joining a multiplayer game gets it too). GrowthTask pushes it and
  reads the ranking once it is done.
   - search: Economy.search(...)
]]
PlanTask = Task:new()
local log = Logger.makeLogger("PlanTask");

PlanTask.RUNS_PER_TICK = 16; -- runs of the model a tick (one is about 0.1 to 0.3 ms)

function PlanTask:achieved (args)
  return self.search.done;
end

function PlanTask:toString()
  return "PlanTask - " .. #self.search.candidates .. " candidates, " .. self.search.runs .. " runs";
end

function PlanTask:tick (args)
  if(Economy.search_step(self.search, PlanTask.RUNS_PER_TICK)) then
    log("Planned with " .. self.search.runs .. " runs of the model", "DEBUG");
  end
end
