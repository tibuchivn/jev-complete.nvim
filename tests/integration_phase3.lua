-- tests/integration_phase3.lua
-- Layer 2: exercises the real Jev API end to end (headless, no UI).
-- Run:
--   TYPESAFE_API_KEY=... nvim --headless -u NONE --cmd "set rtp^=$(pwd)" \
--     -c "luafile tests/integration_phase3.lua" -c "qa!"
-- Prints PASS/FAIL and exits non-zero on failure. Skips when no key is set.

local init = require("jev")
local client = require("jev.client")
local complete = require("jev.complete")

if not require("jev.config").get_api_key() then
  print("SKIP: no TYPESAFE_API_KEY set; integration test needs a live key.")
  os.exit(0)
end

local failures = 0
local function ok(cond, label, detail)
  if cond then
    print("PASS: " .. label)
  else
    failures = failures + 1
    print("FAIL: " .. label .. (detail and (" -- " .. detail) or ""))
  end
end

init.setup({ debug = false, debug_guards = false, debounce_ms = 50, jev_timeout_ms = 10000 })

vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local function greet(name)",
  "  return 'hi ' .. name",
  "end",
  "",
  "local greeting = gre",
})
vim.api.nvim_win_set_cursor(0, { 5, 20 })

-- Headless has no popup menu, so the visibility guard can never pass. Stub it
-- so the remainder of the async path (call -> parse -> rank -> readiness) is
-- still exercised. The real guards are covered by Layer 1.
complete._should_re_trigger = function()
  return true
end

complete.reset()
local start_col = complete.JevComplete(1, "")
ok(type(start_col) == "number", "findstart returns a number")

local fuzzy_items = complete.JevComplete(0, "gre")
ok(#fuzzy_items > 0, "pass 1 returns fuzzy items")

local done = vim.wait(15000, function()
  return complete._get_state().readiness ~= nil
end, 100)

if not done then
  print("FAIL: Jev did not answer within 15s")
  client.cancel_all()
  os.exit(1)
end

local state = complete._get_state()
ok(state.readiness ~= nil, "readiness set once Jev answered")
ok(state.readiness and state.readiness.prefix == "gre", "readiness keyed on the typed prefix")

local ranked_items = complete.JevComplete(0, "gre")
ok(#ranked_items == #fuzzy_items, "pass 2 returns the same item count")
ok(complete._get_state().readiness == nil, "pass 2 clears readiness (anti-loop)")

local function words(items)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = item.word
  end
  return table.concat(out, ", ")
end

print("Fuzzy order:  " .. words(fuzzy_items))
print("Ranked order: " .. words(ranked_items))

print("")
if failures > 0 then
  print(string.format("TOTAL: %d failed", failures))
  os.exit(1)
end
print("PASS: 2-pass flow completed against the live Jev API.")
