import string
import persist
import webserver
import json

var export = module('thermostat')

def load_file(fn)
    var obj, f
    f = open(tasmota.wd .. fn, 'r')
    obj = f.read()
    f.close()
    return obj
end

class Thermostat : Driver
    static var _heater = 0     # tasmota's relay number to which heater is connected
    static var _msg_no_temperature  = "temperature source is lost"

    var _current_temp, _target_temp, _hysteresis # in celsius
    var _control_period                          # in minutes
    var _running

    def init()
        self._current_temp = 9000.0

        self._target_temp = number(persist.member('target_temp'))
        if !self._target_temp
            self._target_temp = 22.5
        end

        self._hysteresis = number(persist.member('hysteresis'))
        if !self._hysteresis
            self._hysteresis = 0.5
        end

        self._control_period = number(persist.member('control_period'))
        if !self._control_period
            self._control_period = 5 # 5 min
        end

        self._running = false

        tasmota.add_rule("event#knxrx_val1", /value -> self.current_temperature_knx_handler(value))
        tasmota.add_rule("rules#timer=1", /-> self.rule_timer1_timeout_handler())
        #tasmota.add_rule("power1#state", /value -> tasmota.cmd(string.format("Power2 %s", str(value))))
    end

    def start()
        tasmota.cmd('RuleTimer1 60', true)
        tasmota.set_timer(0, /-> self.control())
    end

    def current_temperature_knx_handler(value)
        self._running = true
        self._current_temp = number(value)
        tasmota.cmd('RuleTimer1 60', true)
    end

    def rule_timer1_timeout_handler()
        self._running = false
        tasmota.set_power(self._heater, true)
        tasmota.log(self._msg_no_temperature)
    end

    def control()
        # bang-bang
        tasmota.set_timer(self._control_period * 60 * 1000, /-> self.control())

        if self._running
            if self._current_temp > self._target_temp + 0.5 * self._hysteresis
                tasmota.set_power(self._heater, false)
            elif self._current_temp < self._target_temp - 0.5 * self._hysteresis
                tasmota.set_power(self._heater, true)
            end
        end
    end

    def json_append()
        tasmota.response_append(
            string.format(
                ",\"current_temperature\": %.1f"..
                ",\"target_temperature\": %.1f"..
                ",\"hysteresis\": %.1f"..
                ",\"control_period\": %d",
                self._current_temp, self._target_temp, self._hysteresis, self._control_period))
    end

    def web_add_main_button()
        webserver.content_send("<form method=\"get\" action=\"cts\"><button>Configure Thermostat</button></form>")
    end

    def web_add_handler()
        webserver.on('/cts', /-> self.configure_thermostat_http_get(), webserver.HTTP_GET)
        webserver.on('/cts', /-> self.configure_thermostat_http_post(), webserver.HTTP_POST)
    end

    def web_sensor()
        if !self._running
            tasmota.web_send("Thermostat is not running")
            return
        end

        tasmota.web_send_decimal(
            string.format(
                "{s}Current temperature: {m}%.1f °C{e}"..
                "{s}Target temperature: {m}%.1f °C{e}"..
                "{s}Hysteresis: {m}%.1f °C{e}"..
                "{s}Control period: {m}%d min{e}",
                self._current_temp, self._target_temp, self._hysteresis, self._control_period))
    end

    def configure_thermostat_http_get()
        webserver.content_start('Configure Thermostat')
        webserver.content_send_style()

        var content = load_file('configure_template.html')
        webserver.content_send(string.format(content, self._target_temp, self._hysteresis, self._control_period))
        webserver.content_button(webserver.BUTTON_MAIN)
        webserver.content_stop()
    end

    def configure_thermostat_http_post()
        if webserver.has_arg('target_temp')
            var value = webserver.arg('target_temp')
            persist.setmember('target_temp', value)
            self._target_temp = number(value)
        end

        if webserver.has_arg('hysteresis')
            var value = webserver.arg('hysteresis')
            persist.setmember('hysteresis', value)
            self._hysteresis = number(value)
        end

        if webserver.has_arg('control_period')
            var value = webserver.arg('control_period')
            persist.setmember('control_period', value)
            self._control_period = number(value)
        end

        persist.save()
        webserver.redirect("/")
    end
end

export.Thermostat = Thermostat

return export
