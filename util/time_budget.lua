--[[
  TimeBudget (plan 5.6): what the bot spends its time on - an explanation
  next to the evaluation (util/evaluation.lua), not a goal of its own.

  Every tick the stack is read twice:
   - job: what growth is busy with, the task right above GrowthTask (the
     bottom task while the goals before growth run: "goals"): a module being
     built ("build": ProductionGoalTask, BuildModuleTask), the refuel round
     ("fuel": FuelBuildingTask, the coal it gathers and the
     CollectModuleOutputTask{all} that takes the coal modules' coal for it),
     emptying an output ("collect": any other CollectModuleOutputTask),
     research ("research"), the plan ("plan"); GrowthTask itself on top is
     "idle".
   - doing: what the character does, the first task from the top that says:
     walking, mining or chopping by hand, smelting by hand, waiting for a
     module, waiting for the hand-craft queue, placing a building, fuelling,
     taking from a module or chest, making room; "other" else.
  The ticks are kept apart for the first EARLY minutes and the rest, in
  storage.time_budget[player index] = {early = {job=, doing=}, late = ...}.
]]
TimeBudget = {};

TimeBudget.EARLY = 10; -- minutes counted apart: the start, short of everything

local doing_of, job_of;

-- The classes are globals of other files: looked up once they all exist.
local function maps()
  if(doing_of) then return; end
  doing_of = {
    [MoveToPointTask] = "walk",
    [MineResourceTask] = "mine",
    [MineEntityTask] = "mine",
    [HandSmeltTask] = "smelt",
    [WaitForOutputTask] = "wait",
    [CraftRecipeTask] = "craft",
    [PlaceBuildingTask] = "place",
    [FuelBuildingTask] = "fuel",
    [CollectModuleOutputTask] = "take",
    [TakeFromChestTask] = "take",
    [MakeRoomTask] = "room",
  };
  job_of = {
    [ProductionGoalTask] = "build",
    [BuildModuleTask] = "build",
    [FuelBuildingTask] = "fuel",
    [GatherResourceTask] = "fuel", -- only the refuel round pushes one right above growth
    [ResearchTask] = "research",
    [ResearchTriggerTask] = "research",
    [PlanTask] = "plan",
  };
end

-- What the character does: {name of the category}.
function TimeBudget.doing(machine)
  maps();
  local entry = machine and machine.goals;
  while(entry ~= nil) do
    local category = doing_of[getmetatable(entry.current)];
    if(category) then return category; end
    entry = entry.next;
  end
  return "other";
end

-- What growth is busy with (see the top of the file).
function TimeBudget.job(machine)
  maps();
  local entry = machine and machine.goals;
  if(entry == nil) then return "idle"; end
  if(getmetatable(entry.current) == GrowthTask) then return "idle"; end
  local above;
  while(entry ~= nil) do
    if(getmetatable(entry.current) == GrowthTask) then
      local task, kind = above.current, getmetatable(above.current);
      if(kind == CollectModuleOutputTask) then
        return task.all and "fuel" or "collect";
      end
      return job_of[kind] or "other";
    end
    above = entry;
    entry = entry.next;
  end
  return "goals";
end

local function data(player)
  storage.time_budget = storage.time_budget or {};
  local d = storage.time_budget[player.index];
  if(not d) then
    d = {start=game.tick, early={job={}, doing={}}, late={job={}, doing={}}};
    storage.time_budget[player.index] = d;
  end
  return d;
end

-- Counts this tick.
function TimeBudget.tick(player, machine)
  local d = data(player);
  local period = (game.tick - d.start) < TimeBudget.EARLY * 3600 and d.early or d.late;
  local job, doing = TimeBudget.job(machine), TimeBudget.doing(machine);
  period.job[job] = (period.job[job] or 0) + 1;
  period.doing[doing] = (period.doing[doing] or 0) + 1;
end

-- {category = share} of `counts` ({category = ticks}); and their total.
local function shares(counts)
  local total = 0;
  for k, n in pairs(counts or {}) do total = total + n; end
  local result = {};
  for k, n in pairs(counts or {}) do result[k] = total > 0 and n / total or 0; end
  return result, total;
end

-- The shares by period: {early = {job=, doing=, minutes=}, late = ..., all = ...}.
function TimeBudget.summary(d)
  local all = {job={}, doing={}};
  for i, name in ipairs({"early", "late"}) do
    for part, counts in pairs({job=d[name].job, doing=d[name].doing}) do
      for k, n in pairs(counts) do all[part][k] = (all[part][k] or 0) + n; end
    end
  end
  local result = {};
  for name, period in pairs({early=d.early, late=d.late, all=all}) do
    local job, ticks = shares(period.job);
    result[name] = {job=job, doing=shares(period.doing), minutes=ticks / 3600};
  end
  return result;
end

function TimeBudget.report(player)
  return TimeBudget.summary(data(player));
end

local function percents(map)
  local keys = {};
  for k in pairs(map) do keys[#keys + 1] = k; end
  table.sort(keys, function(a, b) if(map[a] ~= map[b]) then return map[a] > map[b]; end return a < b; end);
  local parts = {};
  for i, k in ipairs(keys) do
    if(map[k] >= 0.005) then parts[#parts + 1] = string.format("%s %d %%", k, math.floor(map[k] * 100 + 0.5)); end
  end
  return table.concat(parts, ", ");
end

-- The report in a line, for people.
function TimeBudget.line(r)
  local parts = {};
  for i, name in ipairs({"early", "late"}) do
    local p = r[name];
    if(p.minutes > 0) then
      parts[#parts + 1] = string.format("%s %.1f min: job %s; doing %s", name, p.minutes, percents(p.job), percents(p.doing));
    end
  end
  return "bot time: " .. (#parts > 0 and table.concat(parts, " | ") or "nothing yet");
end

-- The shares of the later period as key=value pairs (late_job_<x>=,
-- late_doing_<x>=), for tools/run-headless.ps1 to average.
function TimeBudget.key(r)
  local parts = {};
  for i, part in ipairs({"job", "doing"}) do
    local keys = {};
    for k in pairs(r.late[part]) do keys[#keys + 1] = k; end
    table.sort(keys);
    for j, k in ipairs(keys) do parts[#parts + 1] = string.format("late_%s_%s=%.4f", part, k, r.late[part][k]); end
  end
  return "time-key " .. table.concat(parts, " ");
end

return TimeBudget;
