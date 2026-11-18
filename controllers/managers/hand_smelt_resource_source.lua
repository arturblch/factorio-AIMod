require 'resource_source';

require 'controllers/tasks/hand_smelt_task'

--[[
  HandSmeltResourceSource
  ResourceManager's very last resort (plan 1.7): nothing gives the item and no
  module can be built for it, but a stone furnace makes it from ore the bot
  can mine by hand. Happens when the only module making iron plates ran out
  of ore while a module of iron is being built: the plates for it would
  otherwise come from nowhere. gather smelts them by hand (HandSmeltTask).
   - item: string; the product
]]
HandSmeltResourceSource = ResourceSource:new();

function HandSmeltResourceSource:compute_types()
  self.types = {{type=self.item}};
end

function HandSmeltResourceSource:is_valid()
  return true;
end

function HandSmeltResourceSource:gather(opts)
  opts.machine:pushSingle(HandSmeltTask:new{item=opts.type, qty=opts.qty});
end
