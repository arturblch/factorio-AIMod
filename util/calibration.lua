--[[
  Calibration (plan 2.12): how far the base keeps up with its paper rates,
  measured as it plays, so that the planner's model (util/economy.lua)
  takes the game's numbers rather than tuned ones - the adaptive part of
  its model predictive control.

  Every EVERY ticks, availability per item the working modules make: the
  share of their drills at work right now (not out of fuel, not waiting for
  room, not out of ore), weighted by each module's rate - a coal ring
  standing full between refuel rounds makes less than its paper rate. It
  goes into a running average (WEIGHT of a new sample) in
  storage.calibration[player index]; Calibration.factors gives the model
  what has MIN_SAMPLES samples or more, until then it keeps its defaults
  (COAL_DELIVERY for coal).
  Measured burning was tried as well (the coal the force burnt in the last
  minute over the burners' paper rate, at least 1: hand furnaces and the
  boiler burn too): the model then built 6 to 7 coal rings where 4 to 5 do,
  235 947 in 30 minutes on 4 maps against 263 878 without it, so it is out.
]]
Calibration = {};

Calibration.EVERY = 300;      -- ticks between samples (5 s)
Calibration.WEIGHT = 0.05;    -- of a new sample in the running average (about 100 s)
Calibration.MIN_SAMPLES = 12; -- a minute of samples before the model uses them
Calibration.FLOOR = 0.3;      -- the least availability counted

local function modules(player)
  local manager = storage.resource_managers and storage.resource_managers[player.index];
  local result = {};
  for i, source in ipairs(manager and manager.sources or {}) do
    if(source.module and source:is_valid()) then result[#result + 1] = source.module; end
  end
  return result;
end

-- {item = share of drills at work, weighted by rate} for `list` of modules.
function Calibration.availability(list)
  local work, total = {}, {};
  for i, module in ipairs(list) do
    local drills, working = 0, 0;
    for j, building in ipairs(module.buildings) do
      local entity = module:entity(j);
      if(entity and entity.type == "mining-drill") then
        drills = drills + 1;
        if(entity.status == defines.entity_status.working) then working = working + 1; end
      end
    end
    if(drills > 0) then
      local counted = {}; -- a module with two outputs of one item counts once
      for k, output in ipairs(module.outputs) do
        local rate = module:productionRate(output.type);
        if(rate > 0 and not counted[output.type]) then
          counted[output.type] = true;
          work[output.type] = (work[output.type] or 0) + rate * working / drills;
          total[output.type] = (total[output.type] or 0) + rate;
        end
      end
    end
  end
  local result = {};
  for item, rate in pairs(total) do
    if(rate > 0) then result[item] = work[item] / rate; end
  end
  return result;
end

local function average(old, sample)
  if(old == nil) then return sample; end
  return old + (sample - old) * Calibration.WEIGHT;
end

-- Takes this tick's sample, every EVERY ticks.
function Calibration.tick(player)
  if(game.tick % Calibration.EVERY ~= 0) then return; end
  storage.calibration = storage.calibration or {};
  local data = storage.calibration[player.index] or {availability={}, samples={}};
  storage.calibration[player.index] = data;
  local list = modules(player);
  for item, share in pairs(Calibration.availability(list)) do
    data.availability[item] = average(data.availability[item], share);
    data.samples[item] = (data.samples[item] or 0) + 1;
  end
end

-- What the model should take: {item = availability, ...} for items with
-- enough samples (at least FLOOR); nil with no samples at all.
function Calibration.factors(player)
  local data = storage.calibration and storage.calibration[player.index];
  if(not data) then return nil; end
  local factors = {};
  for item, share in pairs(data.availability) do
    if((data.samples[item] or 0) >= Calibration.MIN_SAMPLES) then
      factors[item] = math.max(Calibration.FLOOR, math.min(1, share));
    end
  end
  return factors;
end

return Calibration;
