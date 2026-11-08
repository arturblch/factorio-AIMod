require 'task'
require 'util'
require 'util/inventories'
require 'util/logger'
require 'controllers/tasks/moveToPointTask'

--[[
  PlaceBuildingTask moves to a location within range of building stuff and
  places the item from your inventory on the ground.
  Obstacles are not cleared in order to build the entity.
   - type: string; The kind of building to build
   - building: table; (Optional) The buidling table in the module to connect
                      the placed entity with
   - position: {x=number,y=number}; the location to build the building
   - direction: defines.direction; The orientation for the building
]]--
PlaceBuildingTask = Task:new()
local log = Logger.makeLogger("PlaceBuildingTask");
local player_build_distance = 6; --see base/prototypes/entity/demo-entity.lua (player prototype)

local MAX_WALK_ATTEMPTS = 5;
local BLOCKED_TICKS = 300; -- 5 s next to a spot that stays blocked (cliff, unreachable tree)

function PlaceBuildingTask:achieved (args)
  return self.placed ~= nil or self.failed;
end

function PlaceBuildingTask:toString()
  return "PlaceBuildingTask - type: " .. self.type .. " position: (" .. self.position.x .. ", " .. self.position.y .. ")";
end

function PlaceBuildingTask:tick (args)
  local player = args.player;
  local prototype = prototypes.entity[self.type];
  local box = prototype.collision_box;
  local p = player.position;
  -- the character's own body blocks placement, so it must not stand on the spot
  local margin = 0.5;
  local standing_on_spot =
    p.x > self.position.x + box.left_top.x - margin and p.x < self.position.x + box.right_bottom.x + margin and
    p.y > self.position.y + box.left_top.y - margin and p.y < self.position.y + box.right_bottom.y + margin;
  if(standing_on_spot or util.distance(p, self.position) > player_build_distance) then
    self.walk_attempts = (self.walk_attempts or 0) + 1;
    if(self.walk_attempts > MAX_WALK_ATTEMPTS) then
      log("Can't get to " .. self.position.x .. ", " .. self.position.y .. " to place " .. self.type .. ", giving up", "WARN");
      self.failed = true;
      return;
    end
    -- stand just above the building; 2 tiles of clearance because
    -- MoveToPointTask stops anywhere within ~1.4 tiles of its target
    args.machine:pushSingle(MoveToPointTask:new{x=self.position.x, y=self.position.y + box.left_top.y - 2})
  else
    if(Inventories.total_craftable_count(player, self.type) == 0) then
      log("No " .. self.type .. " in the inventory to place, giving up", "WARN");
      self.failed = true;
      return;
    end
    if(player.surface.can_place_entity{name=self.type, position=self.position, direction=self.direction, force=player.force}) then
      local inventories = Inventories.get_all_inventories(player);
      for i, inv in ipairs(inventories) do
        if(inv.get_item_count(self.type) > 0) then
          -- create first, so a failed placement doesn't eat the item
          local entity = player.surface.create_entity{
            name=self.type,
            position=self.position,
            direction=self.direction,
            force=player.force
          };
          if(entity) then
            inv.remove({name=self.type, count=1});
            self.placed = entity;
            if(self.building ~= nil) then
              self.building.entity = entity;
            end
            break;
          end
        end
      end
    else
      self.blocked_since = self.blocked_since or game.tick;
      if(not self.reported) then
        self.reported = true;
        log("Unable to place " .. self.type .. " at " .. self.position.x .. ", " .. self.position.y, "WARN");
        player.print("Unable to place building")
      end
      if(game.tick - self.blocked_since >= BLOCKED_TICKS) then
        log("The spot for " .. self.type .. " stays blocked, giving up", "WARN");
        self.failed = true;
      end
    end
  end
end
