-- tests/benchmark_large_buffer.lua
-- Layer 1: performance on a large buffer.
-- No API key and no UI needed.
--
-- Run:
--   nvim --headless -u NONE --cmd "set rtp^=$(pwd)" \
--     -c "luafile tests/benchmark_large_buffer.lua" -c "qa!"
--
-- Exit code 0 when every operation is within its threshold, 1 otherwise.

local failures = 0
local passes = 0

local function ok(cond, label, detail)
  if cond then
    passes = passes + 1
    print("PASS: " .. label)
  else
    failures = failures + 1
    print("FAIL: " .. label .. (detail and (" -- " .. detail) or ""))
  end
end

local init = require("jev")
local source = require("jev.source")
local cache = require("jev.cache")
local context = require("jev.context")
local complete = require("jev.complete")
local client = require("jev.client")

local saved_config = vim.deepcopy(init.config)
local real_call_async = client.call_async

init.setup({ disabled_filetypes = {} })
client.call_async = function()
  return nil
end

local function ms(fn)
  local started = vim.uv.hrtime()
  fn()
  return (vim.uv.hrtime() - started) / 1e6
end

-- ---------------------------------------------------------------------------
-- Fixture: 10,000 lines of pseudo-Python, cursor near the end.
-- ---------------------------------------------------------------------------
print("== fixture: 10,000 lines ==")
local LINES = 10000
local buffer = {}
for i = 1, LINES do
  if i % 4 == 0 then
    buffer[i] = string.format("    total_%d = compute_total(items_%d)", i, i)
  elseif i % 4 == 1 then
    buffer[i] = string.format("def process_batch_%d(records):", i)
  elseif i % 4 == 2 then
    buffer[i] = string.format("    return sum(record.value for record in records)  # %d", i)
  else
    buffer[i] = ""
  end
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, buffer)
vim.api.nvim_win_set_cursor(0, { LINES, 0 })
cache.clear()

local word_count = #source.get_buffer_words()
print(string.format("extracted unique words: %d (cap %d)", word_count, init.config.max_extract_words))

-- The extraction cap is what bounds this. Measure what an uncapped pass would
-- cost, so the note in the config ("to be adjusted later") has real data
-- behind it and the cost of raising the cap is known.
local uncapped_ms = ms(function()
  local saved_cap = init.config.max_extract_words
  init.config.max_extract_words = math.huge
  source.get_buffer_words()
  init.config.max_extract_words = saved_cap
end)
print(string.format("uncapped extraction: %.1f ms", uncapped_ms))

if word_count >= init.config.max_extract_words then
  print(string.format(
    "NOTE: extraction hit the %d-word cap, so words appearing after the first "
      .. "%d unique words are not offered as candidates on this buffer.",
    init.config.max_extract_words, init.config.max_extract_words
  ))
end
ok(word_count >= 5000, "fixture yields a large word set (>=5000)")

-- ---------------------------------------------------------------------------
-- 1. get_buffer_words, cache miss
-- ---------------------------------------------------------------------------
print("== timings ==")
cache.clear()
local miss_ms = ms(function()
  cache.get_words()
end)
print(string.format("1. get_buffer_words (miss)   %8.1f ms", miss_ms))

-- ---------------------------------------------------------------------------
-- 2. get_buffer_words, cache hit  -- threshold < 1ms
-- ---------------------------------------------------------------------------
local hit_ms = ms(function()
  for _ = 1, 100 do
    cache.get_words()
  end
end) / 100
print(string.format("2. get_buffer_words (hit)    %8.3f ms", hit_ms))
ok(hit_ms < 1, "cache hit < 1ms", string.format("%.3f ms", hit_ms))

-- ---------------------------------------------------------------------------
-- 3. filter_candidates over 5000+ words  -- threshold < 50ms
-- ---------------------------------------------------------------------------
local words = cache.get_words()
local filter_ms = ms(function()
  source.filter_candidates("xyz", words)
end)
print(string.format("3. filter_candidates(5000+)  %8.1f ms", filter_ms))
ok(filter_ms < 50, "filter_candidates < 50ms for 5000+ words",
  string.format("%.1f ms", filter_ms))

-- A matching prefix is the heavier case: more candidates to score.
local filter_match_ms = ms(function()
  source.filter_candidates("total", words)
end)
print(string.format("   filter_candidates(match)  %8.1f ms", filter_match_ms))
ok(filter_match_ms < 50, "filter_candidates < 50ms with a matching prefix",
  string.format("%.1f ms", filter_match_ms))

-- ---------------------------------------------------------------------------
-- 4. build_context with fallback  -- threshold < 10ms
-- ---------------------------------------------------------------------------
local full_tokens = context.estimate_tokens(table.concat(buffer, "\n"))
print(string.format("   full buffer tokens        %8d", full_tokens))
ok(full_tokens > init.config.max_context_tokens, "fixture exceeds max_context_tokens (fallback path)")

local context_ms = ms(function()
  context.build_context()
end)
print(string.format("4. build_context (fallback)  %8.1f ms", context_ms))
ok(context_ms < 10, "build_context fallback < 10ms", string.format("%.1f ms", context_ms))

-- ---------------------------------------------------------------------------
-- 5. JevComplete end-to-end, excluding Jev  -- threshold < 100ms
-- ---------------------------------------------------------------------------
init.config.debounce_ms = 100000
local e2e_ms = ms(function()
  complete.reset()
  complete.JevComplete(1, "")
  complete.JevComplete(0, "total")
end)
print(string.format("5. JevComplete (no Jev call) %8.1f ms", e2e_ms))
ok(e2e_ms < 100, "JevComplete end-to-end < 100ms excluding Jev", string.format("%.1f ms", e2e_ms))

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
print("")
print(string.format("TOTAL: %d passed, %d failed", passes, failures))

client.call_async = real_call_async
init.config = saved_config
complete.reset()

if failures > 0 then
  vim.cmd("cquit 1")
end
