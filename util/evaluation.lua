--[[
  Evaluation (plan 5.5): how far the bot's base has come, for comparing
  runs - not the production score, which counts plates piling up with
  nothing to take them (by 30 minutes about 95 % of the iron and all the
  copper) as fully as plates that became buildings or research. Four parts,
  compared in this order (Evaluation.better):
   - milestones: the minute each was reached - the power module, a science
     module, every technology on the way to GrowthTask.RESEARCH that takes
     packs (Strategy.roadmap, fixed when tracking starts); one not reached
     counts as the whole run. Earlier is better.
   - used: the plates and stone (ITEMS) that went into buildings and
     research, a minute: what the force used up of them (production
     statistics); fuel doesn't count. More is better.
   - surplus: the share of what was made of ITEMS that nothing used: it
     lies in furnaces, chests and the inventory. Less is better.
   - idle: the share of drill time the drills stood for want of something
     (no fuel, ore gone, other), sampled every SAMPLE_EVERY ticks; and the
     minutes the bot spent on what it lacked (util/bottleneck.lua). Less is
     better. A drill standing with its output full is listed among the
     reasons but isn't idle: what it makes waits in the module until
     something takes it (plan 4.11) - nothing wants more of it yet.
  Evaluation.tick keeps the samples and the milestones in
  storage.evaluation[player index]; Evaluation.report reads them with the
  statistics; Evaluation.line and Evaluation.key write them out
  (/aimod-evaluation, the scenario runs).
]]
Evaluation = {};

Evaluation.ITEMS = {"iron-plate", "copper-plate", "stone"};
Evaluation.SAMPLE_EVERY = 300;    -- ticks between samples of the drills
Evaluation.MILESTONE_EVERY = 60;  -- ticks between looks for milestones
Evaluation.MINUTES_TIE = 0.5;     -- milestones within this sum count as even
Evaluation.USED_TIE = 0.02;       -- and used within this share

local STOPPED = {
  [defines.entity_status.no_fuel] = "no fuel",
  [defines.entity_status.waiting_for_space_in_destination] = "output full",
  [defines.entity_status.full_output] = "output full",
  [defines.entity_status.no_minable_resources] = "ore gone",
};

local function data(player)
  storage.evaluation = storage.evaluation or {};
  local d = storage.evaluation[player.index];
  if(not d) then
    local names = {"power", "science"};
    for i, tech in ipairs(Strategy.roadmap(player.force, GrowthTask.RESEARCH)) do names[#names + 1] = tech; end
    d = {start=game.tick, names=names, milestones={}, drills={working=0}};
    storage.evaluation[player.index] = d;
  end
  return d;
end

local function modules(player, working)
  local manager = storage.resource_managers and storage.resource_managers[player.index];
  local result = {};
  for i, source in ipairs(manager and manager.sources or {}) do
    if(source.module and (not working or source:is_valid())) then result[#result + 1] = source.module; end
  end
  return result;
end

-- Whether milestone `name` holds now.
local function reached(player, name)
  if(name == "power" or name == "science") then
    for i, module in ipairs(modules(player, true)) do
      if(name == "power" and module.power) then return true; end
      if(name == "science" and module.packs and #module.packs > 0) then return true; end
    end
    return false;
  end
  local tech = player.force.technologies[name];
  return tech ~= nil and tech.researched;
end

-- {category = count} for the drills of `list`: working, no fuel, output
-- full, ore gone, other.
function Evaluation.drills(list)
  local counts = {working=0};
  for i, module in ipairs(list) do
    for j, building in ipairs(module.buildings) do
      local entity = module:entity(j);
      if(entity and entity.type == "mining-drill") then
        local status = entity.status;
        local category = status == defines.entity_status.working and "working" or STOPPED[status] or "other";
        counts[category] = (counts[category] or 0) + 1;
      end
    end
  end
  return counts;
end

-- Notes the milestones reached by now.
function Evaluation.look(player)
  local d = data(player);
  for i, name in ipairs(d.names) do
    if(not d.milestones[name] and reached(player, name)) then d.milestones[name] = game.tick; end
  end
end

-- Adds a sample of the drills.
function Evaluation.sample(player)
  local d = data(player);
  for category, count in pairs(Evaluation.drills(modules(player, false))) do
    d.drills[category] = (d.drills[category] or 0) + count;
  end
end

-- Keeps the milestones and the samples, each on its own beat.
function Evaluation.tick(player)
  if(game.tick % Evaluation.MILESTONE_EVERY == 0) then Evaluation.look(player); end
  if(game.tick % Evaluation.SAMPLE_EVERY == 0) then Evaluation.sample(player); end
end

--[[
  The parts from plain numbers, so they can be checked apart from the game:
   - milestones: {{name=, minute= or nil}, ...}; minutes: the run so far
   - made, used: {item = count} of ITEMS over the run
   - drills: {category = drill samples}; short: {item = minutes}
  Returns {milestones=, reached=, of=, minutes=, used=, used_items=,
  surplus=, surplus_items=, idle=, idle_reasons=, short=, short_items=, length=}.
]]
function Evaluation.summary(milestones, minutes, made, used, drills, short)
  local r = {milestones=milestones, reached=0, of=#milestones, minutes=0, length=minutes, used_items={},
    surplus_items={}, idle_reasons={}, short_items=short or {}, short=0};
  for i, m in ipairs(milestones) do
    if(m.minute) then r.reached = r.reached + 1; end
    r.minutes = r.minutes + (m.minute or minutes);
  end
  local made_total, used_total = 0, 0;
  for i, item in ipairs(Evaluation.ITEMS) do
    local m, u = made[item] or 0, math.min(used[item] or 0, made[item] or 0);
    r.used_items[item] = minutes > 0 and u / minutes or 0;
    r.surplus_items[item] = m > 0 and (m - u) / m or 0;
    made_total, used_total = made_total + m, used_total + u;
  end
  r.used = minutes > 0 and used_total / minutes or 0;
  r.surplus = made_total > 0 and (made_total - used_total) / made_total or 0;
  local total = 0;
  for category, count in pairs(drills or {}) do total = total + count; end
  r.idle = total > 0 and (total - (drills.working or 0) - (drills["output full"] or 0)) / total or 0;
  for category, count in pairs(drills or {}) do
    if(category ~= "working" and total > 0) then r.idle_reasons[category] = count / total; end
  end
  for item, m in pairs(r.short_items) do r.short = r.short + m; end
  return r;
end

-- The evaluation of the player's base now (Evaluation.summary).
function Evaluation.report(player)
  local d = data(player);
  local minutes = (game.tick - d.start) / 3600;
  local milestones = {};
  for i, name in ipairs(d.names) do
    milestones[i] = {name=name, minute=d.milestones[name] and (d.milestones[name] - d.start) / 3600 or nil};
  end
  local made, used = {}, {};
  for _, surface in pairs(game.surfaces) do
    local statistics = player.force.get_item_production_statistics(surface);
    for i, item in ipairs(Evaluation.ITEMS) do
      made[item] = (made[item] or 0) + statistics.get_input_count(item);
      used[item] = (used[item] or 0) + statistics.get_output_count(item);
    end
  end
  local short = {};
  for item, ticks in pairs(Bottleneck.spent(player)) do short[item] = ticks / 3600; end
  return Evaluation.summary(milestones, minutes, made, used, d.drills, short);
end

-- Whether report `a` beats `b`: more milestones reached, then reached
-- sooner (their minutes summed, within MINUTES_TIE), then more used (within
-- USED_TIE of it), then less surplus, then less idle.
function Evaluation.better(a, b)
  if(a.reached ~= b.reached) then return a.reached > b.reached; end
  if(math.abs(a.minutes - b.minutes) > Evaluation.MINUTES_TIE) then return a.minutes < b.minutes; end
  if(math.abs(a.used - b.used) > Evaluation.USED_TIE * math.max(a.used, b.used)) then return a.used > b.used; end
  if(math.abs(a.surplus - b.surplus) > 1e-6) then return a.surplus < b.surplus; end
  return a.idle < b.idle;
end

local function percent(share) return string.format("%d %%", math.floor(share * 100 + 0.5)); end

local function sorted_keys(map)
  local keys = {};
  for key in pairs(map or {}) do keys[#keys + 1] = key; end
  table.sort(keys);
  return keys;
end

-- The report in a line, for people.
function Evaluation.line(r)
  local stones = {};
  for i, m in ipairs(r.milestones) do
    stones[i] = m.name .. " " .. (m.minute and string.format("%.1f", m.minute) or "-");
  end
  local used, surplus, reasons, short = {}, {}, {}, {};
  for i, item in ipairs(Evaluation.ITEMS) do
    used[#used + 1] = string.format("%s %.1f", item, r.used_items[item]);
    surplus[#surplus + 1] = item .. " " .. percent(r.surplus_items[item]);
  end
  for i, category in ipairs(sorted_keys(r.idle_reasons)) do
    reasons[#reasons + 1] = category .. " " .. percent(r.idle_reasons[category]);
  end
  local items = sorted_keys(r.short_items);
  table.sort(items, function(x, y) return r.short_items[x] > r.short_items[y]; end);
  for i = 1, math.min(3, #items) do short[#short + 1] = string.format("%s %.1f", items[i], r.short_items[items[i]]); end
  return string.format("evaluation: milestones %d of %d (%s; %.1f min in all); used %.1f/min (%s); surplus %s (%s); idle drills %s (%s), bot short %.1f min (%s)",
    r.reached, r.of, table.concat(stones, ", "), r.minutes, r.used, table.concat(used, ", "), percent(r.surplus),
    table.concat(surplus, ", "), percent(r.idle), #reasons > 0 and table.concat(reasons, ", ") or "none", r.short,
    #short > 0 and table.concat(short, ", ") or "nothing");
end

-- The report as key=value pairs, for tools/run-headless.ps1 to add up.
function Evaluation.key(r)
  return string.format("evaluation-key reached=%d of=%d minutes=%.2f used=%.2f surplus=%.4f idle=%.4f short=%.2f",
    r.reached, r.of, r.minutes, r.used, r.surplus, r.idle, r.short);
end

return Evaluation;
