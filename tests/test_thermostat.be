import sys
sys.path().push("tests/mocks")
sys.path().push(".")

import persist
import webserver
import tasmota
import thermostat


# Build a Unix timestamp matching a target weekday (0=Sun..6=Sat) and time
# Note: Jan 4, 1970 (epoch day 4) was a Sunday (weekday == 0)
def make_time(wday, hour, min, sec)
    var base_sunday = 3 * 86400
    return base_sunday + (wday * 86400) + (hour * 3600) + (min * 60) + (sec != nil ? sec : 0)
end

# Helper to run a single schedule check
def check_schedule(th, wday, hour, min, sec, expected_temp, expected_preset, desc)
    var ts = make_time(wday, hour, min, sec)
    tasmota.rtc(ts)
    tasmota._mock_tz = 0
    var temp = th.apply_schedule_override(ts)
    assert(temp == expected_temp, f"{desc} (temp)")
    assert(th._current_preset == expected_preset, f"{desc} (preset)")
end

def setup()
    tasmota.reset()
    persist.reset()
    webserver.reset()
end

# 1. Test Hysteresis & Relay Control (Before/After crossing deadband)
def test_hysteresis_control()
    setup()
    var th = thermostat.Thermostat() # Default Comfort = 22.5°C, Hysteresis = 0.5°C (band: 22.25 .. 22.75)
    tasmota.add_rule('event#knxrx_val1', /val -> th.on_knx_temperature(val))
    tasmota.flush_deferred()

    # Activate thermostat via KNX sensor update
    tasmota.trigger_rule('event#knxrx_val1', '22.0')
    tasmota.fire_timer(th.CONTROL_TIMER_ID)
    assert(tasmota.get_power(0) == true, "Should heat when 22.0 < 22.25")

    # Inside deadband (22.4°C) -> Relay must stay ON (no short-cycling)
    tasmota.trigger_rule('event#knxrx_val1', '22.4')
    tasmota.fire_timer(th.CONTROL_TIMER_ID)
    assert(tasmota.get_power(0) == true, "Should stay ON inside hysteresis band")

    # Above upper threshold (22.8°C > 22.75) -> Relay must turn OFF
    tasmota.trigger_rule('event#knxrx_val1', '22.8')
    tasmota.fire_timer(th.CONTROL_TIMER_ID)
    assert(tasmota.get_power(0) == false, "Should turn OFF above 22.75")

    # Cooling down inside deadband (22.4°C) -> Relay must stay OFF
    tasmota.trigger_rule('event#knxrx_val1', '22.4')
    tasmota.fire_timer(th.CONTROL_TIMER_ID)
    assert(tasmota.get_power(0) == false, "Should stay OFF inside hysteresis band")

    print("PASS: test_hysteresis_control")
end

# 2. Test Weekly Schedule Before & After Rule Transition
def test_schedule_before_after()
    setup()

    persist.setmember('thermostat_weekly_rules', [
        [0, 0],     # Sunday 00:00 -> Comfort (22.5)
        [1920, 2],  # Monday 08:00 (1*1440 + 480 = 1920 mins) -> Eco (18.0)
    ])
    var th = thermostat.Thermostat() # Hysteresis = 0.5°C
    tasmota.add_rule('event#knxrx_val1', /val -> th.on_knx_temperature(val))
    tasmota.trigger_rule('event#knxrx_val1', '20.0')
    tasmota.flush_deferred()

    # BEFORE Monday 08:00 (Monday 07:59) -> Target 22.5°C -> Heater ON
    tasmota.rtc(make_time(1, 7, 59, 0))
    tasmota._mock_tz = 0
    tasmota.fire_timer(th.CONTROL_TIMER_ID)
    assert(th._target_temp == 22.5, "Target should be 22.5 before 08:00")
    assert(tasmota.get_power(0) == true, "Heater should be ON before 08:00")

    # AFTER Monday 08:00 (Monday 08:01) -> Target 18.0°C -> Heater OFF (since room is 20.0°C)
    tasmota.rtc(make_time(1, 8, 1, 0))
    tasmota._mock_tz = 0
    tasmota.fire_timer(th.CONTROL_TIMER_ID)
    assert(th._target_temp == 18.0, "Target should drop to 18.0 at 08:01")
    assert(tasmota.get_power(0) == false, "Heater should turn OFF after 08:01")

    print("PASS: test_schedule_before_after")
end

# 3. Test Temporary Override & Frost Safety Floor (5.0°C)
def test_override_and_safety_floor()
    setup()
    var th = thermostat.Thermostat()
    tasmota.add_rule('event#knxrx_val1', /val -> th.on_knx_temperature(val))
    tasmota.trigger_rule('event#knxrx_val1', '10.0')
    tasmota.flush_deferred()

    # Set temporary override to 2.0°C (below SAFE_TEMPERATURE of 5.0°C) until epoch 2000
    th._override_temp = 2.0
    th._override_temp_until = 2000

    # BEFORE expiry (epoch 1999): Override applies, clamped to SAFE_TEMPERATURE (5.0°C)
    tasmota.rtc(1999)
    tasmota.fire_timer(th.CONTROL_TIMER_ID)
    assert(th._target_temp == 5.0, "Safety floor should clamp 2.0°C override to 5.0°C")

    # AFTER expiry (epoch 2001): Reverts to schedule (Comfort 22.5°C)
    tasmota.rtc(2001)
    tasmota.fire_timer(th.CONTROL_TIMER_ID)
    assert(th._target_temp == 22.5, "Should revert to 22.5°C after override expires")

    print("PASS: test_override_and_safety_floor")
end

# 4. Test Watchdog Failsafe & Unload Cleanup
def test_watchdog_and_unload()
    setup()
    var th = thermostat.Thermostat()
    tasmota.add_rule('event#knxrx_val1', /val -> th.on_knx_temperature(val))
    tasmota.trigger_rule('event#knxrx_val1', '25.0')
    tasmota.flush_deferred()
    tasmota.fire_timer(th.CONTROL_TIMER_ID)
    assert(tasmota.get_power(0) == false, "Relay should be OFF at 25.0°C")

    # Trigger watchdog timeout -> Failsafe turns relay 0 ON and logs error
    tasmota.fire_timer(th.WATCHDOG_TIMER_ID)
    assert(th._running == false, "Thermostat should stop running on watchdog timeout")
    assert(tasmota.get_power(0) == true, "Failsafe should set relay 0 to true")
    assert(tasmota._logs.find(th.NO_TEMPERATURE_MSG) != nil, "Should log KNX lost message")

    # Unload should clean up rules, timers, and driver
    th.unload()
    assert(size(tasmota._rules) == 0, "All rules should be removed on unload")
    assert(size(tasmota._timers) == 0, "All timers should be removed on unload")
    assert(size(tasmota._drivers) == 0, "Driver should be unregistered on unload")

    print("PASS: test_watchdog_and_unload")
end

def test_schedule_before_after_exact_boundaries()
    setup()

    var th = thermostat.Thermostat()
    th._presets = {
        0:  ['Default', 18.0],
        10: ['Eco',     16.5],
        20: ['Comfort', 21.5],
        30: ['Sleep',   17.0]
    }

    # ----------------------------------------------------------------------------
    # GROUP 1: Empty Rules Fallback
    # ----------------------------------------------------------------------------
    th._weekly_rules = []
    check_schedule(th, 0, 0, 0, 0,   18.0, 0, "Empty rules -> falls back to preset 0 (Sun 00:00)")
    check_schedule(th, 3, 14, 30, 0, 18.0, 0, "Empty rules -> falls back to preset 0 (Wed 14:30)")

    # ----------------------------------------------------------------------------
    # GROUP 2: Standard Weekly Schedule & Exact Boundaries
    # ----------------------------------------------------------------------------
    # Rules (sorted by week_mins):
    th._weekly_rules = [
        [480, 20],   # Sun 08:00 ->  480 mins -> Preset 20 (Comfort: 21.5)
        [1350, 30],  # Sun 22:30 -> 1350 mins -> Preset 30 (Sleep:   17.0)
        [1815, 20],  # Mon 06:15 -> 1815 mins -> Preset 20 (Comfort: 21.5)
        [1980, 10],  # Mon 09:00 -> 1980 mins -> Preset 10 (Eco:     16.5)
        [8280, 20],  # Fri 18:00 -> 8280 mins -> Preset 20 (Comfort: 21.5)
        [10079, 30]  # Sat 23:59 -> 10079 mins -> Preset 30 (Sleep:  17.0)
    ]

    # 1. Exact start of week (Sunday 00:00:00) -> wraps to last rule of week (Sat 23:59 -> Preset 30)
    check_schedule(th, 0, 0, 0, 0,    17.0, 30, "Sun 00:00:00 (Start of week wrap-around)")

    # 2. One minute before first Sunday rule (Sun 07:59:59 -> mins = 479 < 480)
    check_schedule(th, 0, 7, 59, 59,  17.0, 30, "Sun 07:59:59 (1 sec before first rule)")

    # 3. Exact match on first rule (Sun 08:00:00 -> mins == 480)
    check_schedule(th, 0, 8, 0, 0,    21.5, 20, "Sun 08:00:00 (Exact rule match)")

    # 4. Mid-interval between rules (Sun 15:20:45 -> mins = 920)
    check_schedule(th, 0, 15, 20, 45, 21.5, 20, "Sun 15:20:45 (Mid-day Sunday)")

    # 5. Midnight rollover Sunday -> Monday (Sun 23:59:59 vs Mon 00:00:00)
    check_schedule(th, 0, 23, 59, 59, 17.0, 30, "Sun 23:59:59 (End of Sunday)")
    check_schedule(th, 1, 0, 0, 0,    17.0, 30, "Mon 00:00:00 (Midnight rollover keeps Sun night preset)")

    # 6. Exact Monday morning wake-up (Mon 06:15:00 -> mins == 1815)
    check_schedule(th, 1, 6, 15, 0,   21.5, 20, "Mon 06:15:00 (Exact Monday rule)")

    # 7. Multi-day span with no rules (Tue, Wed, Thu stay on Mon 09:00 Eco preset)
    check_schedule(th, 3, 12, 0, 0,   16.5, 10, "Wed 12:00:00 (Multi-day hold from Mon 09:00)")

    # 8. End of week boundary (Sat 23:58:59 vs Sat 23:59:00 vs Sat 23:59:59)
    check_schedule(th, 6, 23, 58, 59, 21.5, 20, "Sat 23:58:59 (1 min before last rule)")
    check_schedule(th, 6, 23, 59, 0,  17.0, 30, "Sat 23:59:00 (Exact last minute of week)")
    check_schedule(th, 6, 23, 59, 59, 17.0, 30, "Sat 23:59:59 (Last second of week)")

    # ----------------------------------------------------------------------------
    # GROUP 3: Single Rule in Entire Week
    # ----------------------------------------------------------------------------
    th._weekly_rules = [
        [4320, 20]  # Wednesday 00:00 (3 * 1440 = 4320)
    ]
    check_schedule(th, 1, 10, 0, 0,   21.5, 20, "Single rule: Mon 10:00 wraps to Wed rule")
    check_schedule(th, 3, 0, 0, 0,    21.5, 20, "Single rule: Wed 00:00 exact match")
    check_schedule(th, 6, 23, 0, 0,   21.5, 20, "Single rule: Sat 23:00 after Wed rule")

    # ----------------------------------------------------------------------------
    # GROUP 4: Rule at Minute 0 (Sunday 00:00)
    # ----------------------------------------------------------------------------
    th._weekly_rules = [ 
        [0, 10],    # Sun 00:00 -> Eco
        [5000, 20]  # Wed 11:20 -> Comfort
    ]
    check_schedule(th, 0, 0, 0, 0,    16.5, 10, "Rule at min 0: Sun 00:00 matches rule 0 directly")

    print("PASS: test_schedule_before_after_exact_boundaries")
end


test_hysteresis_control()
test_schedule_before_after()
test_schedule_before_after_exact_boundaries()
test_override_and_safety_floor()
test_watchdog_and_unload()

print("\nALL TESTS PASSED!")
