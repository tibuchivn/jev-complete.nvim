-- lua/jev/client.lua
-- Asynchronous Jev API client built on vim.system() + curl.

local init = require("jev")
local jev_config = require("jev.config")

local M = {}

-- Monotonic call id counter.
local next_id = 0

-- Pending calls: [id] = { proc = SystemObj, cancelled = boolean }.
local pending = {}

local function now_ms()
  return vim.uv.hrtime() / 1e6
end

local function finish(id, callback)
  pending[id] = nil
  callback()
end

-- Call the Jev API asynchronously.
-- callback(err, answers): err is a string on failure, answers a table on
-- success. Returns the call id, or nil when no API key is configured.
function M.call_async(state, questions, callback)
  local api_key = jev_config.get_api_key()
  if not api_key then
    vim.schedule(function()
      callback("No API key configured", nil)
    end)
    return nil
  end

  local payload = vim.json.encode({
    model = init.config.model,
    state = state,
    questions = questions,
  })

  local timeout_seconds = string.format("%.3f", init.config.jev_timeout_ms / 1000)

  local cmd = {
    "curl",
    "-s",
    "-X", "POST",
    "-H", "Authorization: Bearer " .. api_key,
    "-H", "Content-Type: application/json",
    "-d", payload,
    "--max-time", timeout_seconds,
    "-o", "-",
    init.config.api_endpoint,
  }

  next_id = next_id + 1
  local id = next_id
  local started = now_ms()

  init.log(string.format("jev call #%d start, payload %d bytes", id, #payload))

  local proc = vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      local entry = pending[id]
      if not entry or entry.cancelled then
        return
      end

      local elapsed = now_ms() - started
      init.log(string.format("jev call #%d finished in %.0fms (exit %d)", id, elapsed, result.code))

      local timed_out = result.code ~= 0
        or (result.stderr or ""):find("Operation timed out", 1, true) ~= nil

      if timed_out then
        finish(id, function()
          callback(string.format("Jev timeout after %dms", init.config.jev_timeout_ms), nil)
        end)
        return
      end

      local decoded_ok, decoded = pcall(vim.json.decode, result.stdout or "")
      if not decoded_ok or type(decoded) ~= "table" then
        init.log(string.format("jev call #%d parse failed", id))
        finish(id, function()
          callback("JSON parse error: " .. tostring(result.stdout), nil)
        end)
        return
      end

      finish(id, function()
        callback(nil, decoded.answers or {})
      end)
    end)
  end)

  pending[id] = { proc = proc, cancelled = false }
  return id
end

-- Cancel a pending call. The callback of a cancelled call is never invoked.
function M.cancel(call_id)
  local entry = pending[call_id]
  if not entry then
    return
  end

  entry.cancelled = true
  if entry.proc and not entry.proc:is_closing() then
    entry.proc:kill("sigkill")
  end
  pending[call_id] = nil
end

-- Cancel every pending call.
function M.cancel_all()
  for id in pairs(pending) do
    M.cancel(id)
  end
end

-- Number of calls still awaiting a response.
function M.pending_count()
  local count = 0
  for _ in pairs(pending) do
    count = count + 1
  end
  return count
end

return M
