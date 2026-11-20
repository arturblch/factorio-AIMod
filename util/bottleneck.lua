--[[
  Bottleneck (plan 2.3): how much time the bot spends on each item it lacks,
  so that growth builds a module for the one that holds it up most.

  Every tick the stack is read from the top down to the first task that
  says what the bot is doing it for:
   - WaitForOutputTask: waiting for a module to make its item;
   - HandSmeltTask: smelting its item by hand, because no module makes enough
     (mining the ore for it counts here too);
   - GatherResourceTask that the map provides (`by_hand`): mining or chopping
     its item by hand;
  while building, fueling, collecting from a module, crafting or research
  count for nothing (any of those tasks stops the search). The ticks add up
  in storage.time_spent[player index][item]; GrowthTask compares them with
  what they were when it chose its last module.
]]
Bottleneck = {};

-- what the bot does then isn't for an item it lacks
local function stops(task)
  local kind = getmetatable(task);
  return kind == BuildBuildingTask or kind == PlaceBuildingTask or kind == BuildModuleTask
    or kind == FuelBuildingTask or kind == CollectModuleOutputTask or kind == TakeFromChestTask
    or kind == CraftRecipeTask or kind == ProductionGoalTask or kind == GrowthTask
    or kind == ResearchTask or kind == ResearchTriggerTask;
end

-- The item the task on top of `machine` works for, or nil.
function Bottleneck.item(machine)
  local entry = machine and machine.goals;
  while(entry ~= nil) do
    local task, kind = entry.current, getmetatable(entry.current);
    if(kind == WaitForOutputTask) then
      return task.type;
    elseif(kind == HandSmeltTask) then
      return task.item;
    elseif(kind == GatherResourceTask) then
      if(not task.by_hand) then
        return nil;
      end
      -- ore mined for a hand smelt is for the smelt's product
      local below = entry.next and entry.next.current;
      if(getmetatable(below) == HandSmeltTask) then
        return below.item;
      end
      return task.type;
    elseif(stops(task)) then
      return nil;
    end
    entry = entry.next;
  end
  return nil;
end

-- Counts this tick for the item the bot works for, if any.
function Bottleneck.tick(player, machine)
  local item = Bottleneck.item(machine);
  if(item) then
    storage.time_spent = storage.time_spent or {};
    local spent = storage.time_spent[player.index] or {};
    spent[item] = (spent[item] or 0) + 1;
    storage.time_spent[player.index] = spent;
  end
end

-- {item = ticks} spent so far.
function Bottleneck.spent(player)
  return storage.time_spent and storage.time_spent[player.index] or {};
end

-- A copy of Bottleneck.spent, to compare with later.
function Bottleneck.snapshot(player)
  local copy = {};
  for item, ticks in pairs(Bottleneck.spent(player)) do
    copy[item] = ticks;
  end
  return copy;
end

-- {item = ticks} spent since `before` (a snapshot; nil: since the start).
function Bottleneck.since(player, before)
  local result = {};
  for item, ticks in pairs(Bottleneck.spent(player)) do
    local delta = ticks - ((before or {})[item] or 0);
    if(delta > 0) then result[item] = delta; end
  end
  return result;
end

return Bottleneck;
