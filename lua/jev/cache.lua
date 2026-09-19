-- lua/jev/cache.lua
-- Single-entry buffer word cache keyed by (buffer number, changedtick).

local source = require("jev.source")

local M = {}

-- Cached extraction: { bufnr = N, tick = N, words = { ... } }
local entry = nil
local hits = 0
local misses = 0

-- Return the current buffer's words, reusing the cache while the buffer is
-- unchanged. Any edit bumps changedtick and invalidates the cache.
function M.get_words()
  local bufnr = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)

  if entry and entry.bufnr == bufnr and entry.tick == tick then
    hits = hits + 1
    return entry.words
  end

  misses = misses + 1
  local words = source.get_buffer_words()
  entry = { bufnr = bufnr, tick = tick, words = words }
  return words
end

-- Drop the cached entry and reset stats.
function M.clear()
  entry = nil
  hits = 0
  misses = 0
end

-- Cache statistics for debugging: { hits = N, misses = N, size = N }
function M.stats()
  return {
    hits = hits,
    misses = misses,
    size = entry and 1 or 0,
  }
end

return M
