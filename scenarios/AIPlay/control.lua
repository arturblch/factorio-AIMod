-- AIPlay: regular 2.0 Freeplay (same starting items, rocket victory) but
-- without the intro message and the crash site cutscene, so the bot gets a
-- character it can drive from the very first tick.
local handler = require("event_handler")
handler.add_lib(require("__base__/script/freeplay/freeplay"))
handler.add_lib(require("silo-script"))
handler.add_lib({
  on_init = function()
    remote.call("freeplay", "set_skip_intro", true)
    remote.call("freeplay", "set_disable_crashsite", true)
  end
})
