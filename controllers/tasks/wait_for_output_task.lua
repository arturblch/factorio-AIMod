require 'task'
require 'util'
require 'util/logger'

--[[
  WaitForOutputTask
  Waits until a module has produced enough. Gives up as soon as the module
  runs out of fuel or ore, so the task that asked can re-plan (refuel, or
  pick another source).
   - module: BaseModule
   - type: string; the product to wait for
   - qty: number; how many should be waiting in the module's outputs
]]
WaitForOutputTask = Task:new()
local log = Logger.makeLogger("WaitForOutputTask");

function WaitForOutputTask:achieved (args)
  if(self.module:outputCount(self.type) >= self.qty) then
    return true;
  end
  if(self.started and (self.module:isStarved() or not self.module:isOperational())) then
    log("Module stopped while waiting for " .. self.type, "INFO");
    return true;
  end
  return false;
end

function WaitForOutputTask:toString()
  return "WaitForOutputTask - " .. self.qty .. " " .. self.type;
end

function WaitForOutputTask:tick (args)
  -- the very first check happens before freshly added fuel has been lit
  self.started = true;
end
