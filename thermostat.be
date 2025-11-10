import persist
import webserver

var export = module('thermostat')

class Thermostat : Driver
    static var _msg_no_temperature  = 'Thermostat: KNX temperature source is lost'
    var _current_temp, _target_temp, _hysteresis # in celsius
    var _control_period                          # in minutes
    var _running

    def init()
        self._current_temp = 9000.0
        self._target_temp = number(persist.find('thermostat_target_temp', 22.5))
        self._hysteresis = number(persist.find('thermostat_hysteresis', 0.5))
        self._control_period = number(persist.find('thermostat_control_period', 5))
        self._running = false

        tasmota.add_rule('event#knxrx_val1', /value -> self.temperature_knx_handler(value))
        tasmota.add_rule('rules#timer=1', /-> self.rule_timer1_timeout_handler())
        #tasmota.add_rule('power1#state', /value -> tasmota.cmd('power2 ' .. value))
    end

    def start()
        tasmota.cmd('RuleTimer1 60', true)
        tasmota.set_timer(0, /-> self.control())
    end

    def temperature_knx_handler(value)
        self._running = true
        self._current_temp = number(value)
        tasmota.cmd('RuleTimer1 60', true)
    end

    def rule_timer1_timeout_handler()
        self._running = false
        tasmota.set_power(0, true)
        tasmota.log(self._msg_no_temperature)
    end

    def control()
        # bang-bang
        tasmota.set_timer(self._control_period * 60 * 1000, /-> self.control())

        if !self._running
            return
        end

        if self._current_temp > self._target_temp + 0.5 * self._hysteresis
            tasmota.set_power(0, false)
        elif self._current_temp < self._target_temp - 0.5 * self._hysteresis
            tasmota.set_power(0, true)
        end
    end

    def json_append()
        tasmota.response_append(
            ',"Thermostat":{'..
                f'"current_temperature":{self._current_temp:.1f},'..
                f'"target_temperature":{self._target_temp:.1f},'..
                f'"hysteresis":{self._hysteresis:.1f},'..
                f'"control_period":{self._control_period:d}'..
            '}')
    end

    def web_add_main_button()
        webserver.content_send('<form method="get" action="thermostat_settings"><button>Thermostat Settings</button></form>')
    end

    def web_add_handler()
        webserver.on('/thermostat_settings', /-> self.thermostat_settings_http_get(), webserver.HTTP_GET)
        webserver.on('/thermostat_settings', /-> self.thermostat_settings_http_post(), webserver.HTTP_POST)
    end

    def web_sensor()
        if !self._running
            tasmota.web_send(self._msg_no_temperature)
            return
        end

        tasmota.web_send_decimal(
            '{s}Current temperature: {m}'..f'{self._current_temp:.1f} °C'..'{e}'..
            '{s}Target temperature: {m}'..f'{self._target_temp:.1f} °C'..'{e}'..
            '{s}Hysteresis: {m}'..f'{self._hysteresis:.1f} °C'..'{e}'..
            '{s}Control period: {m}'..f'{self._control_period:d} min'..'{e}')
    end

    def thermostat_settings_http_get()
        webserver.content_start('Thermostat Settings')
        webserver.content_send_style()
        webserver.content_send(
            '<fieldset>'..
                '<legend>Thermostat settings</legend>'..
                '<form action="/thermostat_settings" method="post" name="thermostat_settings">'..
                    '<p>'..
                        '<label for="target_temp">Target temperature (°C):</label>'..
                        f'<input type="number" name="target_temp" id="target_temp" min="1" max="30" step="0.5" value="{self._target_temp:.1f}"/>'..
                    '</p><p>'..
                        '<label for="hysteresis">Hysteresis (°C):</label>'..
                        f'<input type="number" name="hysteresis" id="hysteresis" min="0" max="2" step="0.1" value="{self._hysteresis:.1f}"/>'..
                    '</p><p>'..
                        '<label for="control_period">Control period (Minutes):</label>'..
                        f'<input type="number" name="control_period" id="control_period" min="1" max="60" step="1" value="{self._control_period:d}"/>'..
                    '</p><p>'..
                        '<button class="button bgrn" type="submit">Save</button>'..
                    '</p>'..
                '</form>'..
            '</fieldset>')
        webserver.content_button(webserver.BUTTON_MAIN)
        webserver.content_stop()
    end

    def thermostat_settings_http_post()
        import introspect

        for i: 0..webserver.arg_size()-1
            var name = webserver.arg_name(i)
            var value = webserver.arg(i)

            persist.setmember('thermostat_'..name, value)
            introspect.set(self, '_'..name, number(value))
        end

        persist.save()
        webserver.redirect('/')
    end
end

export.Thermostat = Thermostat

return export
