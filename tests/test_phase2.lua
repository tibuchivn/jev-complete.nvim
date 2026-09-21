-- tests/test_phase2.lua
-- Manual test suite for Phase 2 (Jev client + ranking + context + jev cache).
-- No real API calls: vim.system is mocked.
-- Run:
--   nvim --headless -u NONE --cmd "set rtp^=$(pwd)" \
--     -c "luafile tests/test_phase2.lua" -c "qa!"
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

local function contains(haystack, needle, label)
  ok(
    type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
    label,
    "expected to contain " .. vim.inspect(needle) .. " in " .. vim.inspect(haystack)
  )
end

local init = require("jev")
local client = require("jev.client")
local ranking = require("jev.ranking")
local context = require("jev.context")
local cache = require("jev.cache")
local jev_config = require("jev.config")

-- Saved so we can restore after mutation-heavy groups.
local saved_config = vim.deepcopy(init.config)

local real_system = vim.system

-- ---------------------------------------------------------------------------
-- Group 0: module interfaces + new config keys
-- ---------------------------------------------------------------------------
print("== Group 0: interfaces + config ==")
eq(type(client.call_async), "function", "client.call_async is a function")
eq(type(client.cancel), "function", "client.cancel is a function")
eq(type(client.cancel_all), "function", "client.cancel_all is a function")
eq(type(client.pending_count), "function", "client.pending_count is a function")
eq(type(ranking.build_state), "function", "ranking.build_state is a function")
eq(type(ranking.build_questions), "function", "ranking.build_questions is a function")
eq(type(ranking.parse_response), "function", "ranking.parse_response is a function")
eq(type(ranking.rank_candidates), "function", "ranking.rank_candidates is a function")
eq(type(context.build_context), "function", "context.build_context is a function")
eq(type(context.estimate_tokens), "function", "context.estimate_tokens is a function")
eq(type(cache.set_jev_result), "function", "cache.set_jev_result is a function")
eq(type(cache.get_jev_result), "function", "cache.get_jev_result is a function")
eq(type(cache.clear_jev), "function", "cache.clear_jev is a function")

eq(init.config.jev_question_format, "noul", "config.jev_question_format default")
eq(init.config.jev_timeout_ms, 3000, "config.jev_timeout_ms default")
eq(init.config.debounce_ms, 300, "config.debounce_ms default")
eq(init.config.max_context_tokens, 28000, "config.max_context_tokens default")
eq(init.config.context_fallback_lines, 200, "config.context_fallback_lines default")

-- ---------------------------------------------------------------------------
-- Group 1: client — API key missing
-- ---------------------------------------------------------------------------
print("== Group 1: client no api key ==")
do
  local calls = 0
  vim.system = function()
    calls = calls + 1
    return { kill = function() end, is_closing = function() return false end }
  end

  vim.g.jev_api_key = nil
  local saved_env = vim.env.TYPESAFE_API_KEY
  vim.env.TYPESAFE_API_KEY = nil

  local got_err, got_answers
  local returned = client.call_async("state", {}, function(err, answers)
    got_err, got_answers = err, answers
  end)
  vim.wait(200, function() return got_err ~= nil end)

  ok(got_err ~= nil, "missing key reports an error")
  eq(got_answers, nil, "missing key gives no answers")
  eq(calls, 0, "missing key never invokes curl")
  ok(returned == nil or type(returned) == "number", "call_async returns id or nil")

  vim.env.TYPESAFE_API_KEY = saved_env
end

-- ---------------------------------------------------------------------------
-- Group 2: client — success, timeout, malformed JSON
-- ---------------------------------------------------------------------------
print("== Group 2: client responses ==")
vim.g.jev_api_key = "test_key"

local function with_mock_system(mock, fn)
  vim.system = mock
  local ok_run, err = pcall(fn)
  vim.system = real_system
  if not ok_run then
    failures = failures + 1
    print("FAIL: mock system run errored -- " .. tostring(err))
  end
end

do
  with_mock_system(function(_cmd, _opts, cb)
    vim.schedule(function()
      cb({ code = 0, stdout = '{"answers":{"cand_help":{"noul":0.9}}}', stderr = "" })
    end)
    return { kill = function() end, is_closing = function() return false end }
  end, function()
    local done = false
    local got_err, got_answers
    client.call_async("state", {}, function(err, answers)
      got_err, got_answers = err, answers
      done = true
    end)
    vim.wait(1000, function() return done end)
    ok(done, "success path invokes callback")
    eq(got_err, nil, "success path has no error")
    ok(type(got_answers) == "table", "success path yields answers table")
    ok(got_answers and got_answers.cand_help ~= nil, "answers contains question key")
    eq(got_answers and got_answers.cand_help.noul, 0.9, "answers carries noul value")
  end)
end

do
  with_mock_system(function(_cmd, _opts, cb)
    vim.schedule(function()
      cb({ code = 28, stdout = "", stderr = "curl: (28) Operation timed out after 500ms" })
    end)
    return { kill = function() end, is_closing = function() return false end }
  end, function()
    local done = false
    local got_err
    client.call_async("state", {}, function(err)
      got_err = err
      done = true
    end)
    vim.wait(1000, function() return done end)
    ok(done, "timeout path invokes callback")
    contains(got_err or "", "Jev timeout after " .. init.config.jev_timeout_ms .. "ms",
      "timeout error message")
  end)
end

do
  with_mock_system(function(_cmd, _opts, cb)
    vim.schedule(function()
      cb({ code = 0, stdout = "not-json{{{", stderr = "" })
    end)
    return { kill = function() end, is_closing = function() return false end }
  end, function()
    local done = false
    local got_err
    client.call_async("state", {}, function(err)
      got_err = err
      done = true
    end)
    vim.wait(1000, function() return done end)
    ok(done, "malformed JSON invokes callback")
    contains(got_err or "", "JSON parse error", "malformed JSON error message")
  end)
end

do
  with_mock_system(function(_cmd, _opts, cb)
    vim.schedule(function()
      cb({ code = 7, stdout = "", stderr = "curl: (7) Failed to connect" })
    end)
    return { kill = function() end, is_closing = function() return false end }
  end, function()
    local done = false
    local got_err
    client.call_async("state", {}, function(err)
      got_err = err
      done = true
    end)
    vim.wait(1000, function() return done end)
    ok(done, "connection failure invokes callback")
    ok(got_err ~= nil, "connection failure reports an error")
  end)
end

do
  local cmd_seen
  with_mock_system(function(cmd, _opts, cb)
    cmd_seen = cmd
    vim.schedule(function()
      cb({ code = 0, stdout = '{"answers":{}}', stderr = "" })
    end)
    return { kill = function() end, is_closing = function() return false end }
  end, function()
    local done = false
    client.call_async("state", {}, function() done = true end)
    vim.wait(1000, function() return done end)

    local joined = table.concat(cmd_seen, " ")
    contains(joined, "-X POST", "curl uses POST")
    contains(joined, "--max-time", "curl sets max-time")
    contains(joined, "Authorization: Bearer test_key", "curl sends bearer auth")
    contains(joined, "Content-Type: application/json", "curl sends JSON content type")
    ok(not joined:find("TYPESAFE", 1, true), "curl argv has no env var name")
  end)
end

-- ---------------------------------------------------------------------------
-- Group 3: client — cancel
-- ---------------------------------------------------------------------------
print("== Group 3: client cancel ==")
do
  local killed = false
  with_mock_system(function(_cmd, _opts, _cb)
    return {
      kill = function() killed = true end,
      is_closing = function() return false end,
    }
  end, function()
    local callback_fired = false
    local id = client.call_async("state", {}, function() callback_fired = true end)
    eq(type(id), "number", "call_async returns numeric id")
    eq(client.pending_count(), 1, "call is pending before cancel")

    client.cancel(id)
    vim.wait(200, function() return callback_fired end)

    eq(killed, true, "cancel kills the running process")
    eq(callback_fired, false, "cancelled call never invokes callback")
    eq(client.pending_count(), 0, "cancelled call leaves no pending entry")
    client.cancel(id)
    ok(true, "cancel on finished call is a no-op")
  end)
end

do
  with_mock_system(function(_cmd, _opts, _cb)
    return {
      kill = function() end,
      is_closing = function() return false end,
    }
  end, function()
    local i1 = client.call_async("s", {}, function() end)
    local i2 = client.call_async("s", {}, function() end)
    ok(i2 > i1, "call ids increase")
    eq(client.pending_count(), 2, "two pending calls tracked")
    client.cancel_all()
    eq(client.pending_count(), 0, "cancel_all clears pending calls")
  end)
end

-- ---------------------------------------------------------------------------
-- Group 4: ranking — build_state
-- ---------------------------------------------------------------------------
print("== Group 4: ranking.build_state ==")
do
  local state = ranking.build_state("local x = 1", {
    { word = "help", lower = "help" },
    { word = "held", lower = "held" },
  })
  contains(state, "local x = 1", "state keeps context")
  contains(state, "Candidate list:", "state has candidate header")
  contains(state, "- help", "state lists candidate help")
  contains(state, "- held", "state lists candidate held")
  contains(state, "---", "state has separator")
end

-- ---------------------------------------------------------------------------
-- Group 5: ranking — build_questions (all three formats)
-- ---------------------------------------------------------------------------
print("== Group 5: ranking.build_questions ==")
do
  local candidates = {
    { word = "help", lower = "help" },
    { word = "Foo", lower = "foo" },
  }

  init.config.jev_question_format = "noul"
  local q_noul = ranking.build_questions(candidates)
  eq(q_noul.cand_help.type, "noul", "noul question type")
  ok(q_noul.cand_foo ~= nil, "noul question key lowercased")
  contains(q_noul.cand_help.instructions, "help", "noul instructions name the word")
  eq(q_noul.best_candidate, nil, "noul has no choice question")

  init.config.jev_question_format = "choice"
  local q_choice = ranking.build_questions(candidates)
  ok(q_choice.best_candidate ~= nil, "choice has best_candidate question")
  eq(q_choice.best_candidate.type, "choice", "choice question type")
  eq(q_choice.best_candidate.criteria.help, "Word 'help' as a completion", "choice criteria entry")
  eq(q_choice.best_candidate.criteria.foo, "Word 'Foo' as a completion", "choice criteria uses original case")
  eq(q_choice.cand_help, nil, "choice has no per-candidate question")

  init.config.jev_question_format = "score"
  local q_score = ranking.build_questions(candidates)
  eq(q_score.cand_help.type, "score", "score question type")
  eq(type(q_score.cand_help.criteria), "table", "score criteria is a list")
  eq(#q_score.cand_help.criteria, 5, "score criteria has five levels")
  eq(q_score.cand_help.criteria[1], "irrelevant", "score first level")
  eq(q_score.cand_help.criteria[5], "perfect", "score last level")

  init.config.jev_question_format = "noul"
end

-- ---------------------------------------------------------------------------
-- Group 6: ranking — parse_response (all three formats)
-- ---------------------------------------------------------------------------
print("== Group 6: ranking.parse_response ==")
do
  local candidates = {
    { word = "help", lower = "help" },
    { word = "held", lower = "held" },
  }

  local p_noul = ranking.parse_response(
    { cand_help = { noul = 0.9 } },
    "noul",
    candidates
  )
  eq(p_noul.help, 0.9, "noul probability parsed")
  eq(p_noul.held, 0, "noul missing answer defaults to zero")

  local p_choice = ranking.parse_response(
    { best_candidate = { probabilities = { help = 0.8, held = 0.2 } } },
    "choice",
    candidates
  )
  eq(p_choice.help, 0.8, "choice probability parsed")
  eq(p_choice.held, 0.2, "choice second probability parsed")

  local p_choice_missing = ranking.parse_response(
    { best_candidate = { probabilities = { help = 0.8 } } },
    "choice",
    candidates
  )
  eq(p_choice_missing.held, 0, "choice missing candidate defaults to zero")

  local p_empty_choice = ranking.parse_response({}, "choice", candidates)
  eq(p_empty_choice.help, 0, "choice without answer defaults to zero")

  local p_score = ranking.parse_response({
    cand_help = { score = "perfect" },
    cand_held = { score = "irrelevant" },
  }, "score", candidates)
  eq(p_score.help, 1.0, "score 'perfect' normalizes to 1.0")
  eq(p_score.held, 0.0, "score 'irrelevant' normalizes to 0.0")

  local p_score_mid = ranking.parse_response({
    cand_help = { score = "strong" },
    cand_held = { score = "moderate" },
  }, "score", candidates)
  eq(p_score_mid.help, 0.75, "score 'strong' normalizes to 0.75")
  eq(p_score_mid.held, 0.5, "score 'moderate' normalizes to 0.5")

  local p_score_index = ranking.parse_response({
    cand_help = { score = 5 },
    cand_held = { score = 1 },
  }, "score", candidates)
  eq(p_score_index.help, 1.0, "numeric score index 5 normalizes to 1.0")
  eq(p_score_index.held, 0.0, "numeric score index 1 normalizes to 0.0")

  local p_score_missing = ranking.parse_response({}, "score", candidates)
  eq(p_score_missing.help, 0, "score without answer defaults to zero")
end

-- ---------------------------------------------------------------------------
-- Group 7: ranking — rank_candidates
-- ---------------------------------------------------------------------------
print("== Group 7: ranking.rank_candidates ==")
do
  local candidates = {
    { word = "aaa", lower = "aaa", score = 10 },
    { word = "bbb", lower = "bbb", score = 20 },
  }
  local snapshot = vim.deepcopy(candidates)

  local promoted = ranking.rank_candidates(candidates, { aaa = 0.9, bbb = 0.1 })
  eq(promoted[1].word, "aaa", ">= threshold promotes over higher fuzzy score")
  eq(promoted[2].word, "bbb", "below threshold stays on fuzzy score")
  eq(candidates[1].final_score, nil, "input table not mutated")
  eq(#candidates, #snapshot, "input length unchanged")

  local kept = ranking.rank_candidates(candidates, { aaa = 0.5, bbb = 0.2 })
  eq(kept[1].word, "bbb", "below threshold keeps fuzzy order")

  local mixed = ranking.rank_candidates(candidates, { bbb = 0.9 })
  eq(mixed[1].word, "bbb", "single promotion wins")
  eq(mixed[2].word, "aaa", "missing probability keeps fuzzy score")

  local empty = ranking.rank_candidates({}, {})
  eq(#empty, 0, "rank_candidates handles empty input")

  local threshold_check = ranking.rank_candidates(
    { { word = "x", lower = "x", score = 5 } },
    { x = init.config.confidence_threshold }
  )
  eq(threshold_check[1].final_score, init.config.confidence_threshold * 10000 + 5,
    "exactly-at-threshold uses bonus formula")
end

-- ---------------------------------------------------------------------------
-- Group 8: context
-- ---------------------------------------------------------------------------
print("== Group 8: context ==")
eq(context.estimate_tokens(""), 0, "empty string has zero tokens")
eq(context.estimate_tokens("abcd"), 1, "four chars is one token")
eq(context.estimate_tokens("abcde"), 2, "five chars rounds up to two tokens")
eq(context.estimate_tokens("12345678"), 2, "eight chars is two tokens")

do
  init.config.max_context_tokens = 28000
  init.config.context_fallback_lines = 200
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "line one", "line two", "line three" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local ctx = context.build_context()
  contains(ctx, "line one", "small buffer keeps first line")
  contains(ctx, "line three", "small buffer keeps last line")
  contains(ctx, "-- <CURSOR> --", "context marks cursor")

  local marker_pos = ctx:find("-- <CURSOR> --", 1, true)
  local two_pos = ctx:find("line two", 1, true)
  ok(two_pos and marker_pos and two_pos < marker_pos, "cursor marker follows cursor line")
end

do
  init.config.max_context_tokens = 5
  init.config.context_fallback_lines = 4

  local lines = {}
  for i = 1, 20 do
    lines[i] = string.format("line%02d", i)
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { 10, 0 })

  local ctx = context.build_context()
  contains(ctx, "line08", "fallback keeps line two before cursor")
  contains(ctx, "line12", "fallback keeps line two after cursor")
  ok(not ctx:find("line07", 1, true), "fallback drops line three before cursor")
  ok(not ctx:find("line13", 1, true), "fallback drops line three after cursor")
  contains(ctx, "-- <CURSOR> --", "fallback keeps cursor marker")
  ok(#ctx < #table.concat(lines, "\n"), "fallback context is shorter than full buffer")
end

-- ---------------------------------------------------------------------------
-- Group 9: jev result cache
-- ---------------------------------------------------------------------------
print("== Group 9: jev result cache ==")
do
  cache.clear_jev()
  cache.set_jev_result(1, 100, "hel", { help = 0.9 })
  local got = cache.get_jev_result(1, 100, "hel")
  ok(type(got) == "table", "jev cache returns stored map")
  eq(got and got.help, 0.9, "jev cache value intact")

  eq(cache.get_jev_result(1, 101, "hel"), nil, "changedtick change misses")
  eq(cache.get_jev_result(2, 100, "hel"), nil, "bufnr change misses")
  eq(cache.get_jev_result(1, 100, "he"), nil, "prefix change misses")

  local saved_ttl = cache.jev_ttl_ms
  cache.jev_ttl_ms = 0
  eq(cache.get_jev_result(1, 100, "hel"), nil, "expired ttl misses")
  cache.jev_ttl_ms = saved_ttl

  cache.clear()
  eq(cache.get_jev_result(1, 100, "hel"), nil, "clear() also clears jev cache")

  cache.set_jev_result(1, 100, "hel", { help = 0.9 })
  cache.clear_jev()
  eq(cache.get_jev_result(1, 100, "hel"), nil, "clear_jev drops jev cache")

  eq(cache.stats().hits, 0, "clear resets word cache stats")
  eq(cache.stats().misses, 0, "clear resets word cache misses")
end

-- ---------------------------------------------------------------------------
-- Group 10: format validation in setup()
-- ---------------------------------------------------------------------------
print("== Group 10: setup validation ==")
do
  init.setup({ jev_question_format = "bogus" })
  eq(init.config.jev_question_format, "noul", "invalid format falls back to noul")

  init.setup({ jev_question_format = "choice" })
  eq(init.config.jev_question_format, "choice", "valid format accepted")

  init.setup({ jev_question_format = "noul" })
end

-- ---------------------------------------------------------------------------
-- Restore + summary
-- ---------------------------------------------------------------------------
init.config = saved_config
vim.system = real_system

print("")
print(string.format("TOTAL: %d passed, %d failed", passes, failures))

if failures > 0 then
  vim.cmd("cquit 1")
end
