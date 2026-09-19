-- lua/jev/config.lua
-- API key resolution (vim.g / environment) and validation.

local M = {}

-- Module-level flag: warn at most once per session to avoid spamming.
local warned_missing_key = false

-- Return a non-empty trimmed string, otherwise nil.
local function normalize(value)
  if type(value) ~= "string" then
    return nil
  end
  value = vim.trim(value)
  if value == "" then
    return nil
  end
  return value
end

-- Resolve the API key by priority:
--   1. vim.g.jev_api_key  (user override)
--   2. $TYPESAFE_API_KEY  (environment)
-- Returns nil when neither is set. The key value is never logged.
function M.get_api_key()
  local from_global = normalize(vim.g.jev_api_key)
  if from_global then
    return from_global
  end
  return normalize(os.getenv("TYPESAFE_API_KEY"))
end

-- Check that an API key is available.
-- Warns a single time per session when missing; never crashes.
-- Returns true when a key exists, false otherwise.
function M.validate()
  if M.get_api_key() then
    return true
  end
  if not warned_missing_key then
    warned_missing_key = true
    vim.notify(
      "[jev-complete] API key không tìm thấy. Set $TYPESAFE_API_KEY hoặc vim.g.jev_api_key. Plugin sẽ fallback về fuzzy completion.",
      vim.log.levels.WARN
    )
  end
  return false
end

-- Allow users to set the key at runtime.
function M.set_api_key(key)
  vim.g.jev_api_key = key
end

return M
