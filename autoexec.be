do                          # embed in `do` so we don't add anything to global namespace
    import introspect
    var thermostat = introspect.module('thermostat', true)    # load module but don't cache
    tasmota.add_extension(thermostat)
end