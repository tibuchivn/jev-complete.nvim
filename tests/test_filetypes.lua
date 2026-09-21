-- tests/test_filetypes.lua
-- Layer 1: candidate extraction and filetype handling for Python, JavaScript
-- and Ruby. Fuzzy only -- no Jev call, no API key, no UI.
--
-- Run:
--   nvim --headless -u NONE --cmd "set rtp^=$(pwd)" \
--     -c "luafile tests/test_filetypes.lua" -c "qa!"
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

local saved_config = vim.deepcopy(init.config)

-- setup() is what registers the FileType autocmd under test.
init.setup({ disabled_filetypes = {} })

-- Ensure the plugin does not try to reach Jev during these tests.
local real_call_async = require("jev.client").call_async
require("jev.client").call_async = function()
  return nil
end

local function words_of(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    out[#out + 1] = item.word
  end
  return out
end

local function has_word(items, word)
  for _, item in ipairs(items or {}) do
    if item.word == word then
      return true
    end
  end
  return false
end

local CASES = {
  {
    name = "python",
    filetype = "python",
    lines = {
      "def calculate_total(items):",
      "    return sum(item.price for item in items)",
      "",
      "total = calc",
    },
    prefix = "calc",
    expect = { "calculate_total", "calc" },
  },
  {
    name = "javascript",
    filetype = "javascript",
    lines = {
      "function getUserName(user) {",
      "  return user.name;",
      "}",
      "",
      "const userName = getU",
    },
    prefix = "getU",
    expect = { "getUserName" },
  },
  {
    name = "ruby",
    filetype = "ruby",
    lines = {
      "def format_name(first, last)",
      '  "#{first} #{last}"',
      "end",
      "",
      "formatted = form",
    },
    prefix = "form",
    expect = { "format_name", "formatted" },
  },
}

for _, case in ipairs(CASES) do
  print("== " .. case.name .. " ==")

  vim.api.nvim_buf_set_lines(0, 0, -1, false, case.lines)
  vim.bo.filetype = case.filetype
  cache.clear()

  -- The FileType autocmd installs the completefunc per filetype.
  vim.api.nvim_exec_autocmds("FileType", { buffer = 0, modeline = false })
  eq(vim.bo.completefunc, "v:lua.JevComplete", case.name .. ": completefunc attached")

  vim.api.nvim_win_set_cursor(0, { #case.lines, #case.lines[#case.lines] })
  complete.reset()
  local start_col = complete.JevComplete(1, "")
  ok(type(start_col) == "number", case.name .. ": findstart returns a column")

  local items = complete.JevComplete(0, case.prefix)
  local words = words_of(items)
  ok(#items > 0, case.name .. ": candidates returned for '" .. case.prefix .. "'",
    "got [" .. table.concat(words, ",") .. "]")

  for _, expected in ipairs(case.expect) do
    ok(has_word(items, expected),
      case.name .. ": candidate '" .. expected .. "' present",
      "got [" .. table.concat(words, ",") .. "]")
  end

  -- Every returned candidate must actually match the prefix.
  for _, item in ipairs(items) do
    ok(item.word:lower():sub(1, #case.prefix) == case.prefix:lower()
      or source.is_subsequence(case.prefix:lower(), item.word:lower()),
      case.name .. ": '" .. item.word .. "' matches the prefix")
  end

  -- Identifiers spanning the whole line must survive extraction intact.
  local all = cache.get_words()
  local longest = case.expect[1]
  ok(has_word(all, longest), case.name .. ": '" .. longest .. "' extracted from buffer")
end

init.config = saved_config
require("jev.client").call_async = real_call_async
complete.reset()
vim.bo.filetype = ""

print("")
print(string.format("TOTAL: %d passed, %d failed", passes, failures))

if failures > 0 then
  vim.cmd("cquit 1")
end
