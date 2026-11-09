Task = {}

function Task:new (o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  return o
end

function Task:achieved (arg)
  return false
end

function Task:tick (arg)
end

-- Items this task still wants in the main inventory, as {name = total} (a
-- total like GatherResourceTask's qty, not an amount to add), or nil. Used
-- to tell what may be put away when the inventory is full, and what can be
-- fetched early while waiting. Most tasks need nothing.
function Task:needs (args)
  return nil
end
