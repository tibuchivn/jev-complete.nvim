-- lua/jev/init.lua
-- Entry point for jev-complete.nvim: default config, setup(), debug logger.

local M = {}

-- Default configuration; overridable through setup().
M.config = {
  enabled = true,
  confidence_threshold = 0.7, -- threshold for Jev to override fuzzy order
  max_candidates = 30,        -- max candidates sent to Jev
  api_endpoint = "https://api.typesafe.ai/v1/systemone",
  model = "jev-latest",
  debug = false,              -- enable debug logging

  min_word_length = 3,        -- words shorter than this are dropped from buffer words
  max_extract_words = 5000,   -- max unique words extracted from a buffer (NOTE: sẽ điều chỉnh sau)
}

-- User-facing setup.
-- Example: require('jev').setup({ confidence_threshold = 0.8 })
function M.setup(user_config)
  M.config = vim.tbl_deep_extend("force", M.config, user_config or {})
  -- Validate the API key; warns once and never crashes when missing.
  require("jev.config").validate()
  return M.config
end

-- Debug logger; prints only when config.debug is true.
function M.log(msg)
  if M.config.debug then
    vim.notify("[jev-complete] " .. msg, vim.log.levels.INFO)
  end
end

return M
