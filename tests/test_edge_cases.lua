-- tests/test_edge_cases.lua
-- Layer 1: edge cases for the completion pipeline.
-- No API key and no UI needed.
--
-- Run:
--   nvim --headless -u NONE --cmd "set rtp^=$(pwd)" \
--     -c "luafile tests/test_edge_cases.lua" -c "qa!"
-- Exit code 0 when every case passes, 1 when any case fails.

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

local function eq(actual, expected, label)
  ok(
    actual == expected,
    label,
    "expected=" .. vim.inspect(expected) .. " actual=" .. vim.inspect(actual)
  )
end

local init = require("jev")
local source = require("jev.source")
local cache = require("jev.cache")
local complete = require("jev.complete")
local client = require("jev.client")
local jev_config = require("jev.config")

local saved_config = vim.deepcopy(init.config)
local saved_key = vim.g.jev_api_key
local real_call_async = client.call_async

init.setup({ disabled_filetypes = {} })

local function set_lines(lines)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end

-- Neutralise Jev so these tests stay offline; the debounce timer may still fire.
client.call_async = function()
  return nil
end

-- ---------------------------------------------------------------------------
-- 1. Empty buffer
-- ---------------------------------------------------------------------------
print("== 1. empty buffer ==")
set_lines({})
cache.clear()
complete.reset()
eq(#source.get_buffer_words(), 0, "get_buffer_words returns {} for an empty buffer")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
eq(#complete.JevComplete(0, "abc"), 0, "completion returns {} on an empty buffer")

-- ---------------------------------------------------------------------------
-- 2. Empty prefix
-- ---------------------------------------------------------------------------
print("== 2. empty prefix ==")
set_lines({ "local greeting = 1" })
cache.clear()
complete.reset()
complete.JevComplete(1, "")
eq(#complete.JevComplete(0, ""), 0, "empty prefix returns {}")
eq(#source.filter_candidates("", { { word = "greeting", lower = "greeting" } }), 0,
  "filter_candidates returns {} for an empty prefix")

-- ---------------------------------------------------------------------------
-- 3. Prefix longer than every word
-- ---------------------------------------------------------------------------
print("== 3. prefix longer than any word ==")
set_lines({ "local greeting = 1" })
cache.clear()
complete.reset()
complete.JevComplete(1, "")
eq(#complete.JevComplete(0, "verylongprefix"), 0,
  "prefix longer than every candidate returns {}")

-- ---------------------------------------------------------------------------
-- 4. Disabled filetype
-- ---------------------------------------------------------------------------
print("== 4. disabled filetype ==")
init.setup({ disabled_filetypes = { "markdown" } })
vim.bo.completefunc = ""
vim.bo.filetype = "markdown"
vim.api.nvim_exec_autocmds("FileType", { buffer = 0, modeline = false })
eq(vim.bo.completefunc, "", "disabled filetype does not get the completefunc")

vim.bo.filetype = "lua"
vim.api.nvim_exec_autocmds("FileType", { buffer = 0, modeline = false })
eq(vim.bo.completefunc, "v:lua.JevComplete", "enabled filetype gets the completefunc")
init.setup({ disabled_filetypes = {} })

-- ---------------------------------------------------------------------------
-- 5. No API key
-- ---------------------------------------------------------------------------
print("== 5. no API key ==")
do
  local saved_env_new = vim.env.JEV_API_KEY
  local saved_env_old = vim.env.TYPESAFE_API_KEY
  vim.g.jev_api_key = nil
  vim.env.JEV_API_KEY = nil
  vim.env.TYPESAFE_API_KEY = nil

  eq(jev_config.get_api_key(), nil, "get_api_key returns nil with no source")
  eq(jev_config.validate(), false, "validate reports false with no key")

  -- The plugin must still serve fuzzy candidates without a key.
  set_lines({ "local greeting = 1", "gre" })
  cache.clear()
  vim.api.nvim_win_set_cursor(0, { 2, 3 })
  complete.reset()
  local ok_start, start_col = pcall(complete.JevComplete, 1, "")
  ok(ok_start, "findstart does not crash without a key")
  ok(type(start_col) == "number", "findstart still returns a column without a key")

  local ok_items, items = pcall(complete.JevComplete, 0, "gre")
  ok(ok_items, "pass 1 does not crash without a key")
  ok(#items > 0, "fuzzy candidates still returned without a key")

  vim.env.JEV_API_KEY = saved_env_new
  vim.env.TYPESAFE_API_KEY = saved_env_old
end

-- ---------------------------------------------------------------------------
-- 6. Readonly buffer
-- ---------------------------------------------------------------------------
print("== 6. readonly buffer ==")
set_lines({ "local greeting = 1", "gre" })
cache.clear()
vim.api.nvim_win_set_cursor(0, { 2, 3 })
vim.bo.readonly = true
complete.reset()
local ok_ro = pcall(function()
  complete.JevComplete(1, "")
  complete.JevComplete(0, "gre")
end)
ok(ok_ro, "readonly buffer does not crash completion")
vim.bo.readonly = false

-- ---------------------------------------------------------------------------
-- 7. Multiple buffers: cache keyed by bufnr
-- ---------------------------------------------------------------------------
print("== 7. multiple buffers ==")
do
  local first = vim.api.nvim_get_current_buf()
  set_lines({ "onlyalpha here" })
  cache.clear()
  local first_words = cache.get_words()

  local second = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(second)
  set_lines({ "onlybeta there" })
  local second_words = cache.get_words()

  local function has(words, word)
    for _, entry in ipairs(words) do
      if entry.word == word then
        return true
      end
    end
    return false
  end

  ok(has(first_words, "onlyalpha"), "first buffer words cached")
  ok(has(second_words, "onlybeta"), "second buffer words cached")
  ok(not has(second_words, "onlyalpha"), "second buffer cache is not the first buffer's")

  local stats = cache.stats()
  eq(stats.misses, 2, "switching buffers forces a cache miss")
  eq(stats.size, 1, "cache holds a single entry")

  vim.api.nvim_set_current_buf(first)
  vim.api.nvim_buf_delete(second, { force = true })
end

-- ---------------------------------------------------------------------------
-- 8. Typing continues while Jev is in flight -> the old call is cancelled
-- ---------------------------------------------------------------------------
print("== 8. new prefix cancels the in-flight call ==")
do
  local cancelled = {}
  local real_cancel = client.cancel
  client.cancel = function(id)
    cancelled[#cancelled + 1] = id
    return real_cancel(id)
  end

  set_lines({ "local greeting = 1", "gre" })
  cache.clear()
  vim.api.nvim_win_set_cursor(0, { 2, 3 })

  complete.reset()
  complete._get_state().call_id = 12345
  complete.debounce_timer = nil
  init.config.debounce_ms = 10000

  complete.JevComplete(1, "")
  complete.JevComplete(0, "gre")
  ok(#cancelled > 0, "a new prefix cancels the previous in-flight call")
  eq(complete._get_state().call_id, nil, "call_id cleared after cancelling")

  client.cancel = real_cancel
end

-- ---------------------------------------------------------------------------
-- 9. Cursor moves while Jev is in flight -> guards reject
-- ---------------------------------------------------------------------------
print("== 9. cursor moved rejects the update ==")
do
  complete.reset()
  local state = complete._get_state()
  state.cursor_line = 3
  state.cursor_col = 8
  state.start_col = 4
  state.prefix = "gre"

  local mock = {
    pumvisible = function()
      return 1
    end,
    line = function()
      return 4
    end,
    col = function()
      return 8
    end,
    cursor = function()
      return { 4, 7 }
    end,
    line_text = function()
      return "foo gre"
    end,
  }

  eq(complete._should_re_trigger(mock), false, "cursor move rejects the re-trigger")
end

-- ---------------------------------------------------------------------------
-- 10. <C-x><C-u> with the menu already open does not double-trigger
-- ---------------------------------------------------------------------------
print("== 10. repeated trigger does not double-fire ==")
do
  local calls = 0
  client.call_async = function()
    calls = calls + 1
    return 555
  end

  set_lines({ "local greeting = 1", "gre" })
  cache.clear()
  vim.api.nvim_win_set_cursor(0, { 2, 3 })
  init.config.debounce_ms = 60

  complete.reset()
  complete.JevComplete(1, "")
  complete.JevComplete(0, "gre")
  -- A second trigger inside the debounce window must re-arm, not stack.
  complete.JevComplete(1, "")
  complete.JevComplete(0, "gre")

  vim.wait(400, function()
    return calls > 0
  end)
  eq(calls, 1, "repeated trigger within the debounce window yields one Jev call")
end

client.call_async = real_call_async
init.config = saved_config
vim.g.jev_api_key = saved_key
complete.reset()
vim.bo.filetype = ""

print("")
print(string.format("TOTAL: %d passed, %d failed", passes, failures))

if failures > 0 then
  vim.cmd("cquit 1")
end
