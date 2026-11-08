Logger = {
  LEVEL= "INFO",
  LEVELS = {
    "DEBUG",
    "INFO",
    "WARN",
    "ERROR"
  }
}

local levelsToIndex = {}
for key,val in pairs( Logger.LEVELS ) do levelsToIndex[ val ] = key end

-- DEBUG, INFO, WARN, ERROR
-- Written to <user data dir>/script-output/output.log
-- (%APPDATA%\Factorio\script-output\output.log on Windows).
local path = "output.log";

function Logger.log(message)
  helpers.write_file(path, message .. "\n", true);
end

function Logger.logAtLevel(level, message)
  if(levelsToIndex[Logger.LEVEL] <= levelsToIndex[level]) then
    Logger.log(message)
  end
end

function Logger.makeLogger(class)
  return function(msg, level)
    Logger.logAtLevel(level, class .. "> " .. level .. " - " .. msg)
  end
end
