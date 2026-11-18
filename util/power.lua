--[[
  Power: what the player's electric networks make and use, read straight
  from the game (no state of its own). For /aimod-power, the scenario runs'
  reports and the bot's own decisions (a power module's coal, see
  BaseModule:fuelUse).

  Per network (one per group of connected poles):
   - production: W the generators deliver right now (what the consumers draw)
   - capacity: W the generators could deliver
   - consumers: per entity name, how many, how many work, how many are short
     of power, and the W they draw at full work
  Boilers aren't on a network (steam is a fluid), so they are counted for
  the whole force: how many, how many out of fuel, the coal in them.
]]
Power = {};

local CONSUMER_STATUS = {
  [defines.entity_status.working] = "working",
  [defines.entity_status.low_power] = "short",
  [defines.entity_status.no_power] = "short",
};

local function name_list(map, format)
  local names = {};
  for name in pairs(map) do names[#names + 1] = name; end
  table.sort(names);
  local parts = {};
  for i, name in ipairs(names) do
    parts[#parts + 1] = format(name, map[name]);
  end
  return parts;
end

-- The force's electric networks on the player's surface, by network id:
-- {id=, poles=, production=, capacity=, generators={name=count},
--  consumers={name={count=, working=, short=, usage=}}}, sorted by id.
function Power.networks(player)
  local by_id = {};
  local function network(id)
    by_id[id] = by_id[id] or {id=id, poles=0, production=0, capacity=0, generators={}, consumers={}};
    return by_id[id];
  end
  for i, entity in pairs(player.surface.find_entities_filtered{force=player.force}) do
    local id = entity.electric_network_id;
    if(id) then
      local prototype = entity.prototype;
      if(entity.type == "electric-pole") then
        network(id).poles = network(id).poles + 1;
      elseif(entity.type == "generator") then
        local n = network(id);
        n.production = n.production + entity.energy_generated_last_tick * 60;
        n.capacity = n.capacity + prototype.get_max_energy_production() * 60;
        n.generators[entity.name] = (n.generators[entity.name] or 0) + 1;
      elseif(prototype.electric_energy_source_prototype) then
        local n = network(id);
        local c = n.consumers[entity.name] or {count=0, working=0, short=0, usage=0};
        c.count = c.count + 1;
        local state = CONSUMER_STATUS[entity.status];
        if(state) then c[state] = c[state] + 1; end
        c.usage = c.usage + prototype.get_max_energy_usage() * 60;
        n.consumers[entity.name] = c;
      end
    end
  end
  local list = {};
  for id, n in pairs(by_id) do list[#list + 1] = n; end
  table.sort(list, function(a, b) return a.id < b.id; end);
  return list;
end

-- The force's boilers: {count=, no_fuel=, fuel={item=count}}.
function Power.boilers(player)
  local result = {count=0, no_fuel=0, fuel={}};
  for i, boiler in pairs(player.surface.find_entities_filtered{force=player.force, type="boiler"}) do
    result.count = result.count + 1;
    if(boiler.status == defines.entity_status.no_fuel) then
      result.no_fuel = result.no_fuel + 1;
    end
    local inventory = boiler.get_fuel_inventory();
    for j, item in pairs(inventory and inventory.get_contents() or {}) do
      result.fuel[item.name] = (result.fuel[item.name] or 0) + item.count;
    end
  end
  return result;
end

-- `w` watts as "60 kW" / "1.8 MW".
function Power.format(w)
  if(w >= 1e6) then
    return string.format("%.1f MW", w / 1e6);
  end
  return string.format("%.0f kW", w / 1e3);
end

-- Fuel a second a power module's boilers burn for what its generators
-- deliver now (a boiler turns fuel into steam one to one, in 2.1 at 100 %).
function Power.fuelUse(module, fuel)
  local value = prototypes.item[fuel] and prototypes.item[fuel].fuel_value or 0;
  if(value <= 0) then
    return 0;
  end
  local delivered = 0;
  for i, building in ipairs(module.buildings) do
    local entity = module:entity(i);
    if(entity and entity.type == "generator") then
      delivered = delivered + entity.energy_generated_last_tick * 60;
    end
  end
  return delivered / value;
end

-- Lines for /aimod-power: a line per network, then the boilers.
function Power.lines(player)
  local lines = {};
  for i, n in ipairs(Power.networks(player)) do
    local share = n.capacity > 0 and n.production / n.capacity * 100 or 0;
    local consumers = name_list(n.consumers, function(name, c)
      return string.format("%s %d (%d working%s, %s at full work)", name, c.count, c.working,
        c.short > 0 and (", " .. c.short .. " short of power") or "", Power.format(c.usage));
    end);
    local generators = name_list(n.generators, function(name, count) return name .. " " .. count; end);
    lines[#lines + 1] = string.format("network %d: %s used of %s (%.0f %%); %s; %d poles; %s", n.id,
      Power.format(n.production), Power.format(n.capacity), share,
      #generators > 0 and table.concat(generators, ", ") or "no generators", n.poles,
      #consumers > 0 and table.concat(consumers, ", ") or "no consumers");
  end
  local b = Power.boilers(player);
  if(b.count > 0) then
    local fuel = name_list(b.fuel, function(name, count) return count .. " " .. name; end);
    lines[#lines + 1] = string.format("boilers: %d%s, holding %s", b.count,
      b.no_fuel > 0 and (" (" .. b.no_fuel .. " out of fuel)") or "", #fuel > 0 and table.concat(fuel, ", ") or "no fuel");
  end
  if(#lines == 0) then
    lines[1] = "no electric network yet";
  end
  return lines;
end

-- One line for the scenario runs' reports: totals over the networks.
function Power.summary(player)
  local production, capacity, short, consumers, working = 0, 0, 0, 0, 0;
  local networks = Power.networks(player);
  for i, n in ipairs(networks) do
    production, capacity = production + n.production, capacity + n.capacity;
    for name, c in pairs(n.consumers) do
      consumers, working, short = consumers + c.count, working + c.working, short + c.short;
    end
  end
  local b = Power.boilers(player);
  return string.format("power: %d networks, %s used of %s, consumers %d (%d working, %d short), boilers %d (%d out of fuel, %d coal)",
    #networks, Power.format(production), Power.format(capacity), consumers, working, short, b.count, b.no_fuel, b.fuel.coal or 0);
end

return Power;
