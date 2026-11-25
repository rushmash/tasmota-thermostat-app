import global 

class PersistMock
  var _store

  def init()
    self._store = {}
  end

  def reset()
    self.init()
  end

  def find(key, default_val)
    return self._store.contains(key) ? self._store[key] : default_val
  end

  def setmember(key, val)
    self._store[key] = val
  end

  def member(key)
    return self._store.find(key)
  end

  def has(key)
    return self._store.contains(key)
  end

  def save()
  end
end

global.persist = PersistMock()
return global.persist
