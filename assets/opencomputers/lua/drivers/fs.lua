local mtab = {children={}}

local function segments(path)
  path = path:gsub("\\", "/")
  repeat local n; path, n = path:gsub("//", "/") until n == 0
  local parts = {}
  for part in path:gmatch("[^/]+") do
    table.insert(parts, part)
  end
  local i = 1
  while i <= #parts do
    if parts[i] == "." then
      table.remove(parts, i)
    elseif parts[i] == ".." then
      table.remove(parts, i)
      i = i - 1
      if i > 0 then
        table.remove(parts, i)
      else
        i = 1
      end
    else
      i = i + i
    end
  end
  return parts
end

local function findNode(path, create)
  checkArg(1, path, "string")
  local parts = segments(path)
  local node = mtab
  for i = 1, #parts do
    if not node.children[parts[i]] then
      if create then
        node.children[parts[i]] = {children={}, parent=node}
      else
        return node, table.concat(parts, "/", i)
      end
    end
    node = node.children[parts[i]]
  end
  return node
end

local function removeEmptyNodes(node)
  while node and node.parent and not node.fs and not next(node.children) do
    for k, c in pairs(node.parent.children) do
      if c == node then
        node.parent.children[k] = nil
        break
      end
    end
    node = node.parent
  end
end

-------------------------------------------------------------------------------

driver.fs = {}

function driver.fs.mount(fs, path)
  if fs and path then
    checkArg(1, fs, "string")
    local node = findNode(path, true)
    if node.fs then
      return nil, "another filesystem is already mounted here"
    end
    node.fs = fs
  else
    local function path(node)
      local result = "/"
      while node and node.parent do
        for name, child in pairs(node.parent.children) do
          if child == node then
            result = "/" .. name .. result
            break
          end
        end
        node = node.parent
      end
      return result
    end
    local queue = {mtab}
    return function()
      if #queue == 0 then
        return nil
      else
        while true do
          local node = table.remove(queue)
          for _, child in pairs(node.children) do
            table.insert(queue, child)
          end
          if node.fs then
            return node.fs, path(node)
          end
        end
      end
    end
  end
end

function driver.fs.umount(fsOrPath)
  local node, rest = findNode(fsOrPath)
  if not rest and node.fs then
    node.fs = nil
    removeEmptyNodes(node)
    return true
  else
    local queue = {mtab}
    for fs, path in driver.fs.mount() do
      if fs == fsOrPath then
        local node = findNode(path)
        node.fs = nil
        removeEmptyNodes(node)
        return true
      end
    end
  end
end

-------------------------------------------------------------------------------

function driver.fs.spaceTotal(path)
  local node, rest = findNode(path)
  if node.fs then
    return sendToNode(node.fs, "fs.spaceTotal")
  else
    return nil, "no such device"
  end
end

function driver.fs.spaceUsed(path)
  local node, rest = findNode(path)
  if node.fs then
    return sendToNode(node.fs, "fs.spaceUsed")
  else
    return nil, "no such device"
  end
end

-------------------------------------------------------------------------------

function driver.fs.exists(path)
  local node, rest = findNode(path)
  if not rest then -- virtual directory
    return true
  end
  if node.fs then
    return sendToNode(node.fs, "fs.exists", rest)
  end
end

function driver.fs.size(path)
  local node, rest = findNode(path)
  if node.fs and rest then
    return sendToNode(node.fs, "fs.size", rest)
  end
  return 0 -- no such file or directory or it's a virtual directory
end

function driver.fs.dir(path)
  local node, rest = findNode(path)
  if not node.fs and rest then
    return nil, "no such file or directory"
  end
  local result
  if node.fs then
    result = table.pack(sendToNode(node.fs, "fs.list", rest or ""))
    if not result[1] then
      return nil, result[2]
    end
  else
    result = {}
  end
  if not rest then
    for k, _ in pairs(node.children) do
      table.insert(result, k .. "/")
    end
  end
  table.sort(result)
  return table.unpack(result)
end

-------------------------------------------------------------------------------

function driver.fs.remove(path)
  local node, rest = findNode(path)
  if node.fs and rest then
    return sendToNode(node.fs, "fs.remove", rest)
  end
end

function driver.fs.rename(oldPath, newPath)
  local oldNode, oldRest = findNode(oldPath)
  local newNode, newRest = findNode(newPath)
  if oldNode.fs and oldRest and newNode.fs and newRest then
    if oldNode.fs == newNode.fs then
      return sendToNode(oldNode.fs, "fs.rename", oldRest, newRest)
    else
      local result, reason = driver.fs.copy(oldPath, newPath)
      if result then
        return driver.fs.remove(oldPath)
      else
        return nil, reason
      end
    end
  end
end

function driver.fs.copy(fromPath, toPath)
  --[[ TODO ]]
  return nil, "not implemented"
end

-------------------------------------------------------------------------------

local file = {}

function file:close()
  if self.handle then
    self:flush()
    sendToNode(self.fs, "fs.close", self.handle)
    self.handle = nil
  end
end

function file:flush()
  if not self.handle then
    return nil, "file is closed"
  end

  if #self.buffer > 0 then
    local result, reason =
      sendToNode(self.fs, "fs.write", self.handle, self.buffer)
    if result then
      self.buffer = ""
    else
      if reason then
        return nil, reason
      else
        return nil, "bad file descriptor"
      end
    end
  end

  return self
end

function file:lines(...)
  local args = table.pack(...)
  return function()
    local result = table.pack(self:read(table.unpack(args, 1, args.n)))
    if not result[1] and result[2] then
      error(result[2])
    end
    return table.unpack(result, 1, result.n)
  end
end

function file:read(...)
  if not self.handle then
    return nil, "file is closed"
  end

  local function readChunk()
    local result, reason =
      sendToNode(self.fs, "fs.read", self.handle, self.bufferSize)
    if result then
      self.buffer = self.buffer .. result
      return self
    else
      return nil, reason
    end
  end

  local function readBytes(n)
    local result = ""
    repeat
      if #self.buffer == 0 then
        local result, reason = readChunk()
        if not result then
          if reason then
            return nil, reason
          else -- eof
            return result
          end
        end
      end
      local left = n - #result
      result = result .. self.buffer:bsub(1, left)
      self.buffer = self.buffer:bsub(left + 1)
    until #result == n
    return result
  end

  local function readLine(chop)
    local start = 1
    while true do
      local l = self.buffer:find("\n", start, true)
      if l then
        local result = self.buffer:bsub(1, l + (chop and -1 or 0))
        self.buffer = self.buffer:bsub(l + 1)
        return result
      else
        start = #self.buffer
        local result, reason = readChunk()
        if not result then
          if reason then
            return nil, reason
          else -- eof
            local result = self.buffer
            self.buffer = ""
            return result
          end
        end
      end
    end
  end

  local function readAll()
    repeat
      local result, reason = readChunk()
      if not result and reason then
        return nil, reason
      end
    until not result -- eof
    local result = self.buffer
    self.buffer = ""
    return result
  end

  local function read(n, format)
    if type(format) == "number" then
      return readBytes(format)
    else
      if not type(format) == "string" or format:sub(1, 1) ~= "*" then
        error("bad argument #" .. n .. " (invalid option)")
      end
      format = format:sub(2, 2)
      if format == "n" then
        --[[ TODO ]]
        error("not implemented")
      elseif format == "l" then
        return readLine(true)
      elseif format == "L" then
        return readLine(false)
      elseif format == "a" then
        return readAll()
      else
        error("bad argument #" .. n .. " (invalid format)")
      end
    end
  end

  local result = {}
  local formats = table.pack(...)
  if formats.n == 0 then
    return readLine(true)
  end
  for i = 1, formats.n do
    table.insert(result, read(i, formats[i]))
  end
  return table.unpack(result)
end

function file:seek(whence, offset)
  if not self.handle then
    return nil, "file is closed"
  end

  whence = tostring(whence or "cur")
  assert(whence == "set" or whence == "cur" or whence == "end",
    "bad argument #1 (set, cur or end expected, got " .. whence .. ")")
  offset = offset or 0
  checkArg(2, offset, "number")
  assert(math.floor(offset) == offset, "bad argument #2 (not an integer)")

  if whence == "cur" and offset ~= 0 then
    offset = offset - #(self.buffer or "")
  end
  local result, reason =
    sendToNode(self.fs, "fs.seek", self.handle, whence, offset)
  if result then
    if offset ~= 0 then
      self.buffer = ""
    elseif whence == "cur" then
      result = result - #self.buffer
    end
  end
  return result, reason
end

function file:setvbuf(mode, size)
  if not self.handle then
    return nil, "file is closed"
  end

  assert(mode == "no" or mode == "full" or mode == "line",
    "bad argument #1 (no, full or line expected, got " .. tostring(mode) .. ")")
  assert(mode == "no" or type(size) == "number",
    "bad argument #2 (number expected, got " .. type(size) .. ")")

  self:flush()
  self.bufferMode = mode
  self.bufferSize = mode == "no" and 0 or size
end

function file:write(...)
  if not self.handle then
    return nil, "file is closed"
  end

  local args = table.pack(...)
  for i = 1, args.n do
    if type(args[i]) == "number" then
      args[i] = tostring(args[i])
    end
    checkArg(i, args[i], "string")
  end

  for i = 1, args.n do
    local arg = args[i]
    local result, reason

    if (self.bufferMode == "full" or self.bufferMode == "line") and
        self.bufferSize - #self.buffer < #arg
    then
      result, reason = self:flush()
      if not result then
        return nil, reason
      end
    end

    if self.bufferMode == "full" then
      if #arg > self.bufferSize then
        result, reason = sendToNode(self.fs, "fs.write", self.handle, arg)
      else
        self.buffer = self.buffer .. arg
        result = self
      end

    elseif self.bufferMode == "line" then
      local l
      repeat
        local idx = self.buffer:find("\n", l or 1, true)
        if idx then
          l = idx
        end
      until not idx
      if l then
        result, reason = self:flush()
        if not result then
          return nil, reason
        end
        result, reason =
          sendToNode(self.fs, "fs.write", self.handle, arg:bsub(1, l))
        if not result then
          return nil, reason
        end
        arg = arg:bsub(l + 1)
      end
      if #arg > self.bufferSize then
        result, reason = sendToNode(self.fs, "fs.write", self.handle, arg)
      else
        self.buffer = arg
        result = self
      end

    else -- no
      result, reason = sendToNode(self.fs, "fs.write", self.handle, arg)
    end

    if not result then
      return nil, reason
    end
  end

  return self
end

-------------------------------------------------------------------------------

function driver.fs.open(path, mode)
  mode = tostring(mode or "r")
  checkArg(2, mode, "string")
  assert(({r=true, rb=true, w=true, wb=true, a=true, ab=true})[mode],
    "bad argument #2 (r[b], w[b] or a[b] expected, got " .. mode .. ")")

  local node, rest = findNode(path)
  if not node.fs or not rest then
    return nil, "file not found"
  end

  local handle, reason = sendToNode(node.fs, "fs.open", rest, mode)
  if not handle then
    return nil, reason
  end

  return setmetatable({
      fs = node.fs,
      handle = handle,
      buffer = "",
      bufferSize = math.min(8 * 1024, os.totalMemory() / 16),
      bufferMode = "full"
    }, {
      __index = file,
      __gc = function(self)
        -- file.close does a syscall, which yields, and that's not possible in
        -- the __gc metamethod. So we start a timer to do the yield/cleanup.
        event.timer(0, function()
          self:close()
        end)
      end
    })
end

function driver.fs.type(object)
  if object == io.stdin or object == io.stdout then
    return "file"
  end
  if type(object) == "table" then
    local mt = getmetatable(object)
    if mt and mt.__index == file then
      if f.handle then
        return "file"
      else
        return "closed file"
      end
    end
  end
  return nil
end

-------------------------------------------------------------------------------

function loadfile(file, env)
  local f, reason = driver.fs.open(file)
  if not f then
    return nil, reason
  end
  local source, reason = f:read("*a")
  f:close()
  if not source then
    return nil, reason
  end
  return load(source, "=" .. file, env)
end

function dofile(file)
  local f, reason = loadfile(file)
  if not f then
    return nil, reason
  end
  return f()
end

-------------------------------------------------------------------------------

io = {}

io.stdin = {handle="stdin"}

function io.stdin:close()
  return nil, "cannot close standard file"
end

io.stdin.lines = file.lines

function io.stdin:read(...)
  -- TODO
end

io.stdout = {handle="stdout"}

io.stdout.close = io.stdin.close

function io.stdout:flush()
  return self -- no-op
end

function io.stdout:write(...)
  local args = table.pack(...)
  for i = 1, args.n do
    if type(args[i]) == "number" then
      args[i] = tostring(args[i])
    end
    checkArg(i, args[i], "string")
  end
  if type(term) == "table" and type(term.write) == "function" then
    for i = 1, args.n do
      term.write(args[i])
    end
  end
end

io.stderr = io.stdout

-------------------------------------------------------------------------------

local function unavailable()
  return nil, "bad file descriptor"
end

io.stdin.flush = unavailable
io.stdin.seek = unavailable
io.stdin.setvbuf = unavailable
io.stdin.write = unavailable

io.stdout.lines = unavailable
io.stdout.read = unavailable
io.stdout.seek = unavailable
io.stdout.setvbuf = unavailable

-------------------------------------------------------------------------------

local input, output = io.stdin, io.stdout

-------------------------------------------------------------------------------

function io.close(file)
  (file or io.output()):close()
end

function io.flush()
  io.output():flush()
end

function io.input(file)
  if file then
    if type(file) == "string" then
      local result, reason = io.open(file)
      if not result then
        error(reason)
      end
      input = result
    elseif io.type(file) then
      input = file
    else
      error("bad argument #1 (string or file expected, got " .. type(file) .. ")")
    end
  end
  return input
end

function io.lines(filename, ...)
  if filename then
    local result, reason = io.open(filename)
    if not result then
      error(reason)
    end
    local args = table.pack(...)
    return function()
      local result = table.pack(file:read(table.unpack(args, 1, args.n)))
      if not result[1] then
        if result[2] then
          error(result[2])
        else -- eof
          file:close()
          return nil
        end
      end
      return table.unpack(result, 1, result.n)
    end
  else
    return io.input():lines()
  end
end

io.open = driver.fs.open

function io.output(file)
  if file then
    if type(file) == "string" then
      local result, reason = io.open(file, "w")
      if not result then
        error(reason)
      end
      output = result
    elseif io.type(file) then
      output = file
    else
      error("bad argument #1 (string or file expected, got " .. type(file) .. ")")
    end
  end
  return output
end

-- TODO io.popen = function(prog, mode) end

function io.read(...)
  return io.input():read(...)
end

-- TODO io.tmpfile = function() end

io.type = driver.fs.type

function io.write(...)
  return io.output():write(...)
end

function print(...)
  local args = table.pack(...)
  for i = 1, args.n do
    local arg = tostring(args[i])
    if i > 1 then
      arg = "\t" .. arg
    end
    io.stdout:write(arg)
  end
  io.stdout:write("\n")
end

-------------------------------------------------------------------------------

os.remove = driver.fs.remove
os.rename = driver.fs.rename

-- TODO os.tmpname = function() end