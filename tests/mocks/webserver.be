import global

class WebserverMock
  static var HTTP_ANY  = 0
  static var HTTP_GET  = 1
  static var HTTP_POST = 2

  var _args
  var _routes
  var _output

  def init()
    self._args = {}
    self._routes = {}
    self._output = []
  end

  def reset()
    self.init()
  end

  def on(uri, cb, method)
    var m = method != nil ? method : self.HTTP_ANY
    self._routes[f"{m}:{uri}"] = cb
  end

  # Test helper: Simulate an incoming GET or POST request
  def trigger(uri, method, args)
    self._args.clear()
    if args != nil
      for k : args.keys()
        self._args[k] = str(args[k])
      end
    end
    var m = method != nil ? method : self.HTTP_GET
    var key = f"{m}:{uri}"
    if self._routes.contains(key)
      self._routes[key]()
    elif self._routes.contains(f"{self.HTTP_ANY}:{uri}")
      self._routes[f"{self.HTTP_ANY}:{uri}"]()
    end
  end

  def has_arg(name)
    return self._args.contains(name)
  end

  def arg(name)
    return self._args.find(name)
  end

  def content_start(title) end
  def content_send_style() end
  def content_send(html) self._output.push(str(html)) end
  def content_stop() end
end

global.webserver = WebserverMock()
return global.webserver
