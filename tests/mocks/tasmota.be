import global

class Driver end
global.Driver = Driver

class TasmotaMock
  var _mock_utc, _mock_tz, _mock_dump
  var _relays, _rules, _timers, _deferred, _drivers, _logs, _cmds, _web_outputs

  def init()
    self.reset()
  end

  def reset()
    self._mock_utc = 1795563660
    self._mock_tz = 0
    self._mock_dump = nil
    self._relays = [false, false]
    self._rules = {}
    self._timers = {}
    self._deferred = []
    self._drivers = []
    self._logs = []
    self._cmds = []
    self._web_outputs = []
  end

  def rtc(arg)
    if type(arg) == 'int' 
      self._mock_utc = arg
    end
    
    var data = {'utc': self._mock_utc, 'local': self._mock_utc + self._mock_tz, 'timezone': self._mock_tz}
    return type(arg) == 'string' ? data.find(arg) : data
  end

  def time_dump(ts)
    if self._mock_dump != nil 
      return self._mock_dump 
    end

    var sec_in_day = ts % 86400
    return {
      'hour': sec_in_day / 3600,
      'min': (sec_in_day % 3600) / 60,
      'sec': sec_in_day % 60,
      'weekday': ((ts / 86400) + 4) % 7
    }
  end

  def get_power(idx) 
    return self._relays[idx != nil ? idx : 0] 
  end
  
  def set_power(idx, state) 
    self._relays[idx] = bool(state) 
  end
  
  def cmd(c)
    self._cmds.push(c) 
    return {} 
  end
  
  def add_rule(trig, cb) 
    self._rules[trig] = cb
  end
  
  def remove_rule(trig)
    self._rules.remove(trig)
  end
  
  def trigger_rule(trig, val)
    if self._rules.contains(trig)
      self._rules[trig](val) 
    end
  end

  def set_timer(ms, cb, id)
    self._timers[id] = {'delay': ms, 'cb': cb} 
  end
  
  def remove_timer(id)
    self._timers.remove(id) 
  end
  
  def fire_timer(id)
    if self._timers.contains(id)
      var cb = self._timers[id]['cb']
      self._timers.remove(id)
      cb()
    end
  end

  def defer(cb) 
    self._deferred.push(cb) 
  end
  
  def flush_deferred()
    var q = self._deferred
    self._deferred = []
    for cb : q
      cb()
    end
  end

  def add_driver(d) 
    self._drivers.push(d) 
  end
  
  def remove_driver(d)
    var i = self._drivers.find(d)
    if i != nil 
      self._drivers.remove(i) 
    end
  end

  def log(msg, lvl) 
    self._logs.push(str(msg)) 
  end
  
  def web_send(html) 
    self._web_outputs.push(str(html)) 
  end
  
  def web_send_decimal(html) 
    self._web_outputs.push(str(html)) 
  end
end

global.tasmota = TasmotaMock()
return global.tasmota
