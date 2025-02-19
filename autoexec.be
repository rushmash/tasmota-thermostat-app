import sys
var wd = tasmota.wd
if size(wd) sys.path().push(wd) end

import thermostat

var t = thermostat.Thermostat()
tasmota.add_driver(t)
t.start()

if size(wd) sys.path().pop() end
