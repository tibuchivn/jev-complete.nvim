-- tests/smoke_phase2.lua
-- Optional smoke test that calls the real Jev API. Skipped when no key is set.
-- Run:
--   TYPESAFE_API_KEY=... nvim --headless -u NONE --cmd "set rtp^=$(pwd)" \
--     -c "luafile tests/smoke_phase2.lua" -c "qa!"

local init = require("jev")
local client = require("jev.client")
local ranking = require("jev.ranking")
local jev_config = require("jev.config")

if not jev_config.get_api_key() then
  print("SKIP: no TYPESAFE_API_KEY set; smoke test needs a live key.")
  return
end

init.setup({ jev_timeout_ms = 10000 })

local candidates = {
  { word = "help", lower = "help", score = 995 },
  { word = "hello", lower = "hello", score = 994 },
  { word = "helicopter", lower = "helicopter", score = 990 },
}

local context = "local function greet()\n  -- <CURSOR> --\nend"

local state = ranking.build_state(context, candidates)
local questions = ranking.build_questions(candidates)

local done = false
local result_err, result_answers

client.call_async(state, questions, function(err, answers)
  result_err = err
  result_answers = answers
  done = true
end)

vim.wait(15000, function() return done end)

if not done then
  print("FAIL: Jev did not respond within 15s")
  vim.cmd("cquit 1")
end

if result_err then
  print("FAIL: " .. tostring(result_err))
  vim.cmd("cquit 1")
end

print("Jev answered " .. tostring(#vim.tbl_keys(result_answers)) .. " question(s).")
local probabilities = ranking.parse_response(result_answers, init.config.jev_question_format, candidates)
for _, candidate in ipairs(candidates) do
  print(string.format("  %s -> %.4f", candidate.word, probabilities[candidate.lower] or 0))
end

local ranked = ranking.rank_candidates(candidates, probabilities)
print("Ranked order:")
for i, entry in ipairs(ranked) do
  print(string.format("  %d. %s (final=%.2f)", i, entry.word, entry.final_score))
end

print("PASS: smoke test completed.")
