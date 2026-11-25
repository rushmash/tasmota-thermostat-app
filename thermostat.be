import persist
import webserver
import strict

class Thermostat : Driver
    static var NO_TEMPERATURE_MSG = 'Thermostat: Lost KNX connection. Control disabled.'
    static var WATCHDOG_TIMEOUT_MS = 60000
    static var WATCHDOG_TIMER_ID = 'WT'
    static var CONTROL_TIMER_ID = 'CT'
    static var SAFE_TEMPERATURE = 5.0
    static var DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]


    var _current_temp, _target_temp, _hysteresis # in Celcius
    var _control_period                          # in Minutes
    var _running

    var _presets             # a map of temperature presets { preset_id : [ preset_name, temp ], ,,,  }
    var _weekly_rules        # a sorted list (by week_mins) containing temperature override points in time [week_mins, preset_id]
                             # where week_mins is in minutes from the start of the week (which is sunday)
    var _override_temp       # in Celcius
    var _override_temp_until # epoch seconds
    var _current_preset       

    def init()
        self._current_temp = 9000.0
        self._hysteresis   = number(persist.find('thermostat_hysteresis', 0.5))
        self._control_period = number(persist.find('thermostat_control_period', 5))
        self._current_preset = 0
        self._running = false

        var default_presets = {
            0: ['Comfort', 22.5],
            1: ['Sleep', 20.0],
            2: ['Eco', 18.0],
        }
        self._presets = persist.find('thermostat_presets', default_presets)
        var presets = {}
        for k: self._presets.keys()
            presets[int(k)] = self._presets[k]
        end
        self._presets = presets
        self._target_temp = self._presets[0][1]

        var default_rules = [
            [0, 0],
        ]
        self._weekly_rules = persist.find('thermostat_weekly_rules', default_rules)
        self._override_temp = number(persist.find('thermostat_override_temp', 0))
        self._override_temp_until = number(persist.find('thermostat_override_temp_until', 0))

        tasmota.add_rule('power1#state', /value -> tasmota.cmd('power2 ' .. value))
        tasmota.add_rule('event#knxrx_val1', /value_str -> self.on_knx_temperature(value_str))
        tasmota.set_timer(self.WATCHDOG_TIMEOUT_MS, /-> self.on_watchdog_timeout(), self.WATCHDOG_TIMER_ID)
        tasmota.defer(/-> self.control())
        tasmota.add_driver(self)
    end

    def unload()
        self._running = false
        tasmota.set_power(0, true)
        tasmota.remove_rule('event#knxrx_val1')
        tasmota.remove_rule('power1#state')
        tasmota.remove_timer(self.CONTROL_TIMER_ID)
        tasmota.remove_timer(self.WATCHDOG_TIMER_ID)
        tasmota.remove_driver(self)
    end

    def on_knx_temperature(value_str)
        self._running = true
        self._current_temp = number(value_str)
        tasmota.remove_timer(self.WATCHDOG_TIMER_ID)
        tasmota.set_timer(self.WATCHDOG_TIMEOUT_MS, /-> self.on_watchdog_timeout(), self.WATCHDOG_TIMER_ID)
    end

    def on_watchdog_timeout()
        self._running = false
        tasmota.set_power(0, true)
        tasmota.log(self.NO_TEMPERATURE_MSG)
    end

    def control()
        tasmota.set_timer(self._control_period * 60 * 1000, /-> self.control(), self.CONTROL_TIMER_ID)

        if !self._running
            return
        end

        var now_local = tasmota.rtc('local')
        self._target_temp = self.apply_schedule_override(now_local)
        var now_epoch = tasmota.rtc('utc')
        self._target_temp = self.apply_temporary_override(self._target_temp, now_epoch)
        self._target_temp = self.apply_safety_override(self._target_temp)

        var half_hyst = 0.5 * self._hysteresis
        if self._current_temp > self._target_temp + half_hyst
            tasmota.set_power(0, false)
        elif self._current_temp < self._target_temp - half_hyst
            tasmota.set_power(0, true)
        end
    end

    def apply_schedule_override(time_local)
        var dump = tasmota.time_dump(time_local)
        var mins = (dump['weekday'] * 24 + dump['hour']) * 60 + dump['min']

        var i = size(self._weekly_rules) - 1
        while i >= 0
            var rule_time_mins = self._weekly_rules[i][0]
            var preset_id = self._weekly_rules[i][1]
            if mins >= rule_time_mins
                self._current_preset = preset_id
                return number(self._presets[preset_id][1])
            end
            
            i -= 1
        end

        if size(self._weekly_rules) >= 1
            var preset_id = self._weekly_rules[-1][1]
            self._current_preset = preset_id
            return number(self._presets[preset_id][1])
        end
        
        self._current_preset = 0
        return number(self._presets[0][1])
    end

    def apply_temporary_override(temp, time_epoch)
        if time_epoch <= self._override_temp_until
            return self._override_temp
        end

        return temp
    end

    def apply_safety_override(temp)
        if temp < self.SAFE_TEMPERATURE
            return self.SAFE_TEMPERATURE
        end

        return temp
    end

    def web_add_main_button()
        webserver.content_send('<form method="get" action="thermostat"><button>Thermostat</button></form>')
    end

    def web_add_handler()
        webserver.on('/thermostat', /-> self.http_get(), webserver.HTTP_GET)
        webserver.on('/thermostat', /-> self.http_post(), webserver.HTTP_POST)
    end

    def web_sensor()
        if !self._running
            tasmota.web_send(self.NO_TEMPERATURE_MSG)
        end

        var now_epoch = tasmota.rtc('utc')
        var target_info = self._presets[self._current_preset][0]
        if now_epoch <= self._override_temp_until
            target_info = 'Override'
        end

        tasmota.web_send_decimal(
            '{s}Current temperature: {m}'..f'{self._current_temp:.1f} °C'..'{e}'..
            '{s}Target temperature: {m}'..f'({target_info})  '..f'{self._target_temp:.1f} °C'..'{e}')
    end

    def http_get()
        webserver.content_start("Thermostat")
        webserver.content_send_style()
        self.send_body()
        webserver.content_stop()
    end

    def http_post()
        if webserver.has_arg('delete_rule')
            import string
            var rule = string.split(webserver.arg('delete_rule'), '_')
            var i = self._weekly_rules.find([number(rule[0]), number(rule[1])])
            self._weekly_rules.remove(i)
            persist.setmember('thermostat_weekly_rules', self._weekly_rules)
        end

        if webserver.has_arg('add_time')
            var time   = webserver.arg('add_time')
            var preset = int(webserver.arg('add_preset')) 
            var days   = []

            for d: self.DAYS.keys()
                if webserver.has_arg('add_day_' + str(d))
                    days.push(d)
                end
            end

            for d: days
                self._weekly_rules.push([ d * 24 * 60 + self.time_str_to_mins(time), int(preset)])
            end
            
            self.sort_rules(self._weekly_rules)
            persist.setmember('thermostat_weekly_rules', self._weekly_rules)
        end

        if webserver.has_arg('preset_0')
            for i: self._presets.keys()
                self._presets[i][1] = number(webserver.arg(f'preset_{i}'))
            end

            persist.setmember('thermostat_presets', self._presets)
        end

        if webserver.has_arg('hysteresis')
            self._hysteresis = number(webserver.arg('hysteresis'))
            self._control_period = number(webserver.arg('control_period'))

            persist.setmember('thermostat_hysteresis', self._hysteresis)
            persist.setmember('thermostat_control_period', self._control_period)
        end

        if webserver.has_arg('override_temp') 
            self._override_temp = number(webserver.arg('override_temp'))
            self._override_temp_until = number(webserver.arg('end_epoch'))

            persist.setmember('thermostat_override_temp', self._override_temp)
            persist.setmember('thermostat_override_temp_until', self._override_temp_until)

            import math
            var duration_hours = math.round((self._override_temp_until - tasmota.rtc('utc')) / 360.0) / 10.0
            tasmota.log(f'Thermostat: Set temperature to {self._override_temp} for next {duration_hours} hours.')
        end

        if webserver.has_arg('cancel_override')
            self._override_temp_until = tasmota.rtc('utc') - 10
            persist.setmember('thermostat_override_temp_until', self._override_temp_until)
        end

        persist.save()
        webserver.redirect("/thermostat")
    end

    def send_body()
        webserver.content_send('<style>')
        webserver.content_send('fieldset{margin:0 0 12px;padding:8px 10px 12px;border:1px solid #666;border-radius:.3em;background:var(--c_frm)}')
        webserver.content_send('legend{padding:0 6px}')
        webserver.content_send('label{cursor:pointer}')
        webserver.content_send('input,select,button{font-family:inherit;font-size:1em}')
        webserver.content_send('input,select{width:100%;border:1px solid #bbb;border-radius:.2em;background:var(--c_in);color:var(--c_intxt)}')
        webserver.content_send('input[type="checkbox"]{width:1em;height:1em;margin:0 4px 0 0;padding:0;vertical-align:-1px}')
        webserver.content_send('button{width:100%;padding:0 12px;line-height:2.4rem;border:0;border-radius:.3em;background:var(--c_btn);color:var(--c_btntxt);cursor:pointer;transition:background .4s}')
        webserver.content_send('button:hover{background:var(--c_btnhvr)}')
        webserver.content_send('.btn-save{background:var(--c_btnsv)}')
        webserver.content_send('.btn-save:hover{background:var(--c_btnsvhvr)}')
        webserver.content_send('.btn-del{width:auto;padding:0 8px;line-height:1.8rem;font-size:1rem;background:var(--c_btnrst)}')
        webserver.content_send('.btn-del,.btn-cancel:hover{background:var(--c_btnrsthvr)}')
        webserver.content_send('.btn-cancel{margin-top:10px;background:var(--c_btnrst)}')
        webserver.content_send('.btn-add{margin-top:10px}')
        webserver.content_send('.row{display:flex;align-items:center;gap:8px;margin:8px 0}')
        webserver.content_send('.row-value{display:flex;align-items:center;gap:4px;margin-left:auto}')
        webserver.content_send('.w-time{width:120px}')
        webserver.content_send('.w-preset{width:110px}')
        webserver.content_send('.w-temp{width:70px}')
        webserver.content_send('#day_checkboxes{display:flex;flex-wrap:wrap;gap:6px 14px;justify-content:center;padding:4px 0}')
        webserver.content_send('#day_checkboxes label{white-space:nowrap}')
        webserver.content_send('.day-header{margin-top:10px;padding:5px 10px;border-left:4px solid #2e7d32;background:var(--c_in);color:var(--c_intxt);font-weight:bold;font-size:.9em}')
        webserver.content_send('table{width:100%;margin-top:4px;border-collapse:collapse}')
        webserver.content_send('th{padding:5px;border-bottom:1px solid var(--c_tab);color:var(--c_tab);font-size:.8em;text-align:left}')
        webserver.content_send('td{padding:8px 5px;border-bottom:1px solid var(--c_tab);font-size:.9em}')
        webserver.content_send('th.actions,td.actions{text-align:right}')
        webserver.content_send('.footer a{color:#aaa;text-decoration:none}')
        webserver.content_send('.footer a:hover{text-decoration:underline}')
        webserver.content_send('.row{padding:0px}')
        webserver.content_send('</style><fieldset><legend>Weekly Schedule</legend>')

        var now_time = tasmota.rtc('utc')
        if now_time <= self._override_temp_until 
            import math
            var duration_hours = math.round((self._override_temp_until - now_time) / 360.0) / 10.0
            webserver.content_send(f'<div class="row"><label>Override with {self._override_temp:.1f} &deg;C for {duration_hours} hours')
        end

        self.send_schedule()
        webserver.content_send('<form method="post" action="/thermostat"><div id="day_checkboxes">')

        for d: self.DAYS.keys()
            var ck = ''
            if d == 0
                ck = 'checked'
            end
            webserver.content_send(f'<label><input type="checkbox" name="add_day_{d}" value="{d}" {ck}>{self.DAYS[d]:.3s}</label>')
        end

        webserver.content_send('</div><div class="row"><label for="addTime">Time</label>')
        webserver.content_send('<input type="time" id="addTime" name="add_time" class="w-time" value="09:00" required>')
        webserver.content_send('<label for="add_preset">Preset</label><select id="add_preset" name="add_preset" class="w-preset">')

        for i: self._presets.keys()
            webserver.content_send(f'<option value="{i}">{self._presets[i][0]}</option>')
        end

        webserver.content_send('</select></div><button type="submit" class="btn-save">Add rule</button></form></fieldset>')
        webserver.content_send('<fieldset><legend>Temperature Presets</legend><form method="post" action="/thermostat">')

        for i: self._presets.keys()
            var preset_id = f'preset_{i}'
            var val = f'{self._presets[i][1]:.1f}'
            webserver.content_send('<div class="row">')
            webserver.content_send(f'<label for={preset_id}>{self._presets[i][0]}</label>')
            webserver.content_send('<div class="row-value">')
            webserver.content_send(f'<input type="number" id="{preset_id}" name="{preset_id}" class="w-temp" step="0.1" value="{val}">')
            webserver.content_send('<span>&deg;C</span></div></div>')
        end
        webserver.content_send('<button type="submit" class="btn-save">Apply</button></form></fieldset>')

        webserver.content_send('<fieldset><legend>Temporary Override</legend><form id="override_form"><div class="row">')
        webserver.content_send('<label for="override_temp" style="display: flex; font-weight: 600; margin-bottom: 4px;">')
        webserver.content_send('Target temperature</label><div class="row-value">')
        webserver.content_send('<input id="override_temp" class="w-temp" name="temperature" type="number" step="0.5" min="5" max="30" value="22.0" required/>')
        webserver.content_send('<span>&deg;C</span></div></div>')
        webserver.content_send('<div style="margin-bottom: 8px;"><span style="font-size: 12px; margin-bottom: 4px;">')
        webserver.content_send('Quick duration</span><div style="display: flex; gap: 6px;">')
        webserver.content_send('<button type="button" class="btn-add" onclick="setDuration(30)">+30m</button>')
        webserver.content_send('<button type="button" class="btn-add" onclick="setDuration(60)">+1h</button>')
        webserver.content_send('<button type="button" class="btn-add" onclick="setDuration(120)">+2h</button>')
        webserver.content_send('<button type="button" class="btn-add" onclick="setDuration(240)">+4h</button>')
        webserver.content_send('</div></div><div class="row">')
        webserver.content_send('<label for="override_end" style="display: block; font-weight: 600; margin-bottom: 4px;">')
        webserver.content_send('Hold until</label><div class="row-value">')
        webserver.content_send('<input id="override_end" type="datetime-local" required style="padding: 8px; box-sizing: border-box;"/>')
        webserver.content_send('</div></div><button type="submit" class="btn-save">Start override</button></form>')
        webserver.content_send('<form method="post" action="/thermostat"><button type="submit" class="btn-cancel">Cancel override</button>')
        webserver.content_send('<input type="hidden" id="cancel_override" value="1"/></form></fieldset>')

        webserver.content_send('<script>')
        webserver.content_send('const endInput=document.getElementById("override_end"),tempInput=document.getElementById("override_temp"),')
        webserver.content_send('overrideForm=document.getElementById("override_form");function formatLocalISO(e){const t=e=>String(e).padStart(2,"0");')
        webserver.content_send('return`${e.getFullYear()}-${t(e.getMonth()+1)}-${t(e.getDate())}T${t(e.getHours())}:${t(e.getMinutes())}`}')
        webserver.content_send('function parseLocalISO(e){const[t,n]=e.split("T"),[o,r,a]=t.split("-").map(Number),[d,m]=n.split(":").map(Number);')
        webserver.content_send('return new Date(o,r-1,a,d,m)}function setDuration(e){const t=new Date,n=new Date(t.getTime()+60*e*1e3);')
        webserver.content_send('endInput.min=formatLocalISO(t),endInput.value=formatLocalISO(n)}setDuration(60),')
        webserver.content_send('overrideForm.addEventListener("submit",function(e){e.preventDefault();')
        webserver.content_send('const t=parseLocalISO(endInput.value),n=Math.floor(t.getTime()/1e3),o=new URLSearchParams;')
        webserver.content_send('o.append("override_temp",tempInput.value),o.append("end_epoch",n),')
        webserver.content_send('fetch("/thermostat",{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},body:o}).then(()=>location.reload())});');
        webserver.content_send('</script>')

        webserver.content_send('<fieldset><legend>Control & Timing</legend><form method="post" action="/thermostat">')
        webserver.content_send('<div class="row"><label for="hysteresis">Hysteresis (total span)</label><div class="row-value">')
        webserver.content_send(f'<input type="number" name="hysteresis" id="hysteresis" min="0" max="5" step="0.1" class="w-temp" value="{self._hysteresis:.1f}"/>')
        webserver.content_send('<span>&deg;C</span></div></div><div class="row"><label for="control_period">Control period</label><div class="row-value">')
        webserver.content_send(f'<input type="number" name="control_period" id="control_period" min="1" max="60" step="1" class="w-temp" value="{self._control_period:d}"/>')
        webserver.content_send('<span>min</span></div></div><button type="submit" class="btn-save">Apply</button></form></fieldset>')
        
        webserver.content_send('<p></p><form action="/" method="get"><button>Main Menu</button></form>')
    end

    def send_schedule()
        for d: self.DAYS.keys()
            var day_rules = []
            for rule: self._weekly_rules
                var rule_mins = rule[0]
                var preset_id = rule[1]
                if d * 24 * 60 <= rule_mins && rule_mins < (d + 1) * 24 * 60 
                    day_rules.push(rule)
                end
            end

            if size(day_rules) == 0
                continue
            end

            webserver.content_send(f'<div class="day-header">{self.DAYS[d]}</div>')
            webserver.content_send('<table><thead><tr><th>Time</th><th>Preset</th><th>Temp</th><th class="actions"></th></tr></thead><tbody>')

            for entry: day_rules
                var rule_mins = entry[0]
                var preset_id = entry[1]
                var preset_name = self._presets[preset_id][0]
                var preset_temp = self._presets[preset_id][1]

                webserver.content_send(f'<tr><td>{self.mins_to_time_str(rule_mins)}</td>')
                webserver.content_send(f'<td>{preset_name}</td><td>{preset_temp:.1f}</td>')
                webserver.content_send('<td class="actions"><form method="post" action="/thermostat" style="display:inline">')
                webserver.content_send(f'<input type="hidden" name="delete_rule" value="{rule_mins}_{preset_id}">')
                webserver.content_send('<button type="submit" class="btn-del" title="Delete rule">&times;</button></form></td></tr>')
            end
            webserver.content_send('</tbody></table>')
        end
    end

    def time_str_to_mins(time_str)
        # 01:10 -> 70
        import string
        var parts = string.split(time_str, ':')
        if size(parts) == 2
            return number(parts[0]) * 60 + number(parts[1])
        end

        raise 'invalid_time_str'
    end

    def mins_to_time_str(mins)
        # 70 -> 01:10
        var min = number(mins) % (24 * 60) 
        var mm = min % 60
        var hh = min / 60

        return f'{hh:02i}:{mm:02i}'
    end

    def sort_rules(l)
        for i:1..size(l)-1
            var k = l[i]
            var j = i
            while (j > 0) && (l[j-1][0] > k[0])
                l[j] = l[j-1]
                j -= 1
            end
            l[j] = k
        end

        return l
    end
end

return Thermostat()
