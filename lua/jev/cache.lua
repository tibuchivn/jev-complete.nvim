-- lua/jev/cache.lua
-- Single-entry buffer word cache keyed by (buffer number, changedtick).

local source = require("jev.source")

local M = {}

-- Cached extraction: { bufnr = N, tick = N, words = { ... } }
local entry = nil
local hits = 0
local misses = 0

-- Jev ranking results live in a separate table so buffer-word caching is
-- unaffected by them.
local jev_results = {}

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

-- Drop both cached buffer words and cached Jev results, and reset stats.
function M.clear()
  entry = nil
  hits = 0
  misses = 0
  jev_results = {}
end

-- Cache statistics for debugging: { hits = N, misses = N, size = N }
function M.stats()
  return {
    hits = hits,
    misses = misses,
    size = entry and 1 or 0,
  }
end

-- Lifetime of a cached Jev result, in milliseconds.
M.jev_ttl_ms = 5000

local function jev_key(bufnr, changedtick, prefix)
  return string.format("%d:%d:%s", bufnr, changedtick, prefix)
end

-- Store a Jev result for (bufnr, changedtick, prefix).
function M.set_jev_result(bufnr, changedtick, prefix, probabilities)
  jev_results[jev_key(bufnr, changedtick, prefix)] = {
    time = vim.uv.hrtime() / 1e6,
    probabilities = probabilities,
  }
end

-- Return the cached Jev result, or nil when missing or past its TTL.
function M.get_jev_result(bufnr, changedtick, prefix)
  local key = jev_key(bufnr, changedtick, prefix)
  local stored = jev_results[key]
  if not stored then
    return nil
  end

  if vim.uv.hrtime() / 1e6 - stored.time >= M.jev_ttl_ms then
    jev_results[key] = nil
    return nil
  end

  return stored.probabilities
end

-- Drop cached Jev results only.
function M.clear_jev()
  jev_results = {}
end

return M
