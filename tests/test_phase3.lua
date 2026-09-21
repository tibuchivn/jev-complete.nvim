-- tests/test_phase3.lua
-- Layer 1 unit tests for Phase 3 (2-pass feedkeys architecture).
-- No API key and no UI needed.
-- Run:
--   nvim --headless -u NONE --cmd "set rtp^=$(pwd)" \
--     -c "luafile tests/test_phase3.lua" -c "qa!"
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
local complete = require("jev.complete")
local client = require("jev.client")
local cache = require("jev.cache")

local saved_config = vim.deepcopy(init.config)
local real_system = vim.system

local function set_lines(lines)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end

-- ---------------------------------------------------------------------------
-- Group 0: interfaces + config
-- ---------------------------------------------------------------------------
print("== Group 0: interfaces + config ==")
eq(type(complete.JevComplete), "function", "complete.JevComplete is a function")
eq(type(complete.trigger), "function", "complete.trigger is a function")
eq(type(complete.reset), "function", "complete.reset is a function")
eq(type(complete._should_re_trigger), "function", "complete._should_re_trigger is a function")
eq(type(complete._get_state), "function", "complete._get_state is a function")
eq(type(complete._schedule_debounce), "function", "complete._schedule_debounce is a function")
eq(type(complete._trigger_jev_call), "function", "complete._trigger_jev_call is a function")
eq(_G.JevComplete, complete.JevComplete, "JevComplete exported as a global for completefunc")

eq(type(init.config.disabled_filetypes), "table", "config.disabled_filetypes is a table")
eq(init.config.auto_trigger, false, "config.auto_trigger defaults to false")
eq(init.config.debug_guards, false, "config.debug_guards defaults to false")
eq(init.config.manage_completeopt, true, "config.manage_completeopt defaults to true")

-- ---------------------------------------------------------------------------
-- Group 1: 3 guards
-- ---------------------------------------------------------------------------
print("== Group 1: 3 guards ==")

-- Fresh state with a known snapshot; `live` mutates what the guards observe.
local function arm(live)
  complete.reset()
  complete._get_state().cursor_line = 5
  complete._get_state().cursor_col = 9
  complete._get_state().start_col = 4
  complete._get_state().prefix = "gre"

  live = live or {}
  return {
    pumvisible = function()
      if live.pum_visible == nil then
        return 1
      end
      return live.pum_visible
    end,
    line = function()
      return live.cursor_line or 5
    end,
    col = function()
      return live.cursor_col or 9
    end,
    cursor = function()
      return { live.cursor_row or 5, live.cursor_col0 or 7 }
    end,
    line_text = function()
      return live.line_text or "foo gre"
    end,
  }
end

do
  local mock = arm()
  eq(complete._should_re_trigger(mock), true, "all 3 guards pass on valid context")
end

do
  local mock = arm({ pum_visible = 0 })
  eq(complete._should_re_trigger(mock), false, "Guard A rejects when popup hidden")
end

do
  local mock = arm({ cursor_line = 6 })
  eq(complete._should_re_trigger(mock), false, "Guard B rejects when line moved")
end

do
  local mock = arm({ cursor_col = 12 })
  eq(complete._should_re_trigger(mock), false, "Guard B rejects when column moved")
end

do
  local mock = arm({ cursor_col0 = 6, line_text = "foo gr" })
  eq(complete._should_re_trigger(mock), false, "Guard C rejects when prefix changed")
end

-- Off-by-one: prefix "gre" must be read as "gre", not "gr".
do
  local mock = arm({ line_text = "foo gre", cursor_col0 = 7 })
  eq(complete._should_re_trigger(mock), true, "Guard C off-by-one: prefix 'gre' matches 'gre'")
end

-- Same setup but one byte short must NOT match.
do
  local mock = arm({ line_text = "foo grx", cursor_col0 = 6 })
  eq(complete._should_re_trigger(mock), false, "Guard C off-by-one: 'gr' does not match 'gre'")
end

-- ---------------------------------------------------------------------------
-- Group 2: debounce timer
-- ---------------------------------------------------------------------------
print("== Group 2: debounce ==")
do
  init.config.debounce_ms = 60
  local calls = {}
  local real_call_async = client.call_async
  client.call_async = function(state, questions)
    calls[#calls + 1] = { state = state, questions = questions }
    return 900
  end

  set_lines({ "local greeter = 1", "gre" })
  cache.clear()
  vim.api.nvim_win_set_cursor(0, { 2, 3 })

  complete.reset()
  complete.JevComplete(1, "")
  complete.JevComplete(0, "gre")
  eq(#calls, 0, "debounce defers the Jev call")

  vim.wait(400, function()
    return #calls > 0
  end)
  eq(#calls, 1, "debounce fires exactly one Jev call")
  ok(calls[1].state ~= nil and #calls[1].state > 0, "Jev call receives a state string")
  ok(calls[1].questions ~= nil and next(calls[1].questions) ~= nil, "Jev call receives questions")

  -- A new pass 1 inside the window must coalesce into a single call.
  calls = {}
  complete.reset()
  complete.JevComplete(1, "")
  complete.JevComplete(0, "gre")
  vim.wait(20)
  complete.JevComplete(1, "")
  complete.JevComplete(0, "gree")
  vim.wait(400)
  eq(#calls, 1, "repeated pass 1 coalesces into one Jev call")

  client.call_async = real_call_async
end

-- ---------------------------------------------------------------------------
-- Group 3: 2-pass architecture
-- ---------------------------------------------------------------------------
print("== Group 3: 2-pass architecture ==")
do
  complete.reset()
  set_lines({ "local greeting = 1", "gre" })
  cache.clear()
  vim.api.nvim_win_set_cursor(0, { 2, 3 })

  local start_col = complete.JevComplete(1, "")
  eq(type(start_col), "number", "pass 1 findstart returns a number")
  eq(start_col, 0, "pass 1 findstart returns word start column")

  local empty_items = complete.JevComplete(0, "")
  eq(#empty_items, 0, "empty base yields no items")

  local real_call_async = client.call_async
  client.call_async = function()
    return 901
  end
  init.config.debounce_ms = 10000

  complete.reset()
  complete.JevComplete(1, "")
  local fuzzy = complete.JevComplete(0, "gre")
  ok(#fuzzy > 0, "pass 1 returns fuzzy items immediately")
  eq(type(fuzzy[1].word), "string", "pass 1 item carries word")
  eq(complete._get_state().prefix, "gre", "pass 1 stores prefix")
  ok(complete._get_state().readiness == nil, "pass 1 leaves readiness unset")

  -- Simulate Jev having answered: readiness + cached ranked items.
  local bufnr = vim.api.nvim_get_current_buf()
  local ranked = { { word = "greeting" }, { word = "greeter" }, { word = "gre" } }
  complete._get_state().cached_ranked_items = ranked
  complete._get_state().readiness = { bufnr = bufnr, prefix = "gre" }

  local pass2 = complete.JevComplete(0, "gre")
  eq(#pass2, #ranked, "pass 2 returns the cached ranked items")
  eq(pass2[1].word, "greeting", "pass 2 preserves ranked order")
  eq(complete._get_state().readiness, nil, "pass 2 clears readiness (anti-loop)")
  eq(complete._get_state().cached_ranked_items, nil, "pass 2 clears cached items")

  -- Pass 3 with the same prefix must be a fresh pass 1, not stale cache.
  local pass3 = complete.JevComplete(0, "gre")
  ok(#pass3 > 0, "pass 3 returns fresh fuzzy items")
  ok(pass3[1].word ~= nil, "pass 3 items carry word")
  ok(complete._get_state().readiness == nil, "pass 3 leaves readiness unset")

  client.call_async = real_call_async
end

-- Readiness keyed on prefix: a different prefix must not consume the cache.
do
  complete.reset()
  set_lines({ "local greeting = 1", "gre" })
  cache.clear()
  vim.api.nvim_win_set_cursor(0, { 2, 3 })

  local real_call_async = client.call_async
  client.call_async = function()
    return 902
  end
  init.config.debounce_ms = 10000

  complete.JevComplete(1, "")
  complete.JevComplete(0, "gre")

  local bufnr = vim.api.nvim_get_current_buf()
  complete._get_state().cached_ranked_items = { { word = "greeting" } }
  complete._get_state().readiness = { bufnr = bufnr, prefix = "other" }

  local items = complete.JevComplete(0, "gre")
  ok(complete._get_state().readiness ~= nil, "mismatched prefix keeps readiness")
  eq(items[1].word ~= "greeting", true, "mismatched prefix does not serve cached ranked list")

  client.call_async = real_call_async
end

-- ---------------------------------------------------------------------------
-- Group 4: timeout vs connect-fail vs other
-- ---------------------------------------------------------------------------
print("== Group 4: error taxonomy ==")
vim.g.jev_api_key = "test_key"
init.config.jev_timeout_ms = 500

local function run_exit(code, stderr)
  local got_err
  vim.system = function(_cmd, _opts, cb)
    vim.schedule(function()
      cb({ code = code, stdout = "", stderr = stderr })
    end)
    return { kill = function() end, is_closing = function() return false end }
  end

  local done = false
  client.call_async("state", {}, function(err)
    got_err = err
    done = true
  end)
  vim.wait(1000, function()
    return done
  end)
  vim.system = real_system
  return got_err
end

contains(run_exit(28, "curl: (28) Operation timed out"), "Jev timeout after 500ms",
  "exit 28 reports timeout")
contains(run_exit(6, "curl: (6) Could not resolve host"), "Jev DNS resolution failed",
  "exit 6 reports DNS failure")
contains(run_exit(7, "curl: (7) Failed to connect"), "Jev connection failed",
  "exit 7 reports connection failure")
contains(run_exit(1, "curl: (1) Unsupported protocol"), "Jev request failed (curl exit 1)",
  "exit 1 reports generic failure")

-- ---------------------------------------------------------------------------
-- Group 5: regression / bug-fix verification
-- ---------------------------------------------------------------------------
print("== Group 5: bug-fix verification ==")

-- bug #1: filter_candidates must preserve `lower` so build_questions works.
do
  local source = require("jev.source")
  local ranking = require("jev.ranking")
  local filtered = source.filter_candidates("hel", {
    { word = "Hello", lower = "hello" },
  })
  eq(filtered[1].lower, "hello", "filter_candidates preserves lower (bug #1)")

  init.config.jev_question_format = "noul"
  local questions = ranking.build_questions(filtered)
  ok(questions.cand_hello ~= nil, "build_questions works on filtered candidates (bug #1)")
end

-- bug #6: debug_guards logs independently of debug.
do
  local logged = {}
  local real_notify = vim.notify
  vim.notify = function(msg)
    logged[#logged + 1] = msg
  end

  init.config.debug = false
  init.config.debug_guards = true
  init.log_guard("guard probe")
  ok(#logged == 1, "log_guard emits when debug_guards=true and debug=false (bug #6)")
  contains(logged[1] or "", "guard probe", "log_guard message content (bug #6)")

  logged = {}
  init.config.debug_guards = false
  init.log_guard("should not appear")
  eq(#logged, 0, "log_guard is silent when debug_guards=false (bug #6)")

  vim.notify = real_notify
end

-- bug #5: noselect is applied buffer-locally via the FileType autocmd.
do
  init.config.manage_completeopt = true
  init.setup({ disabled_filetypes = {}, manage_completeopt = true })

  vim.bo.completeopt = "menu,popup"
  vim.bo.filetype = "lua"
  vim.api.nvim_exec_autocmds("FileType", { buffer = 0, modeline = false })

  local co = vim.api.nvim_get_option_value("completeopt", { buf = 0 })
  contains(co, "noselect", "noselect added buffer-locally (bug #5)")
  contains(co, "menu", "existing menu flag preserved (bug #7)")
  contains(co, "popup", "existing popup flag preserved (bug #7)")
  local global_co = vim.api.nvim_get_option_value("completeopt", { scope = "global" })
  eq(global_co:find("noselect") == nil, true, "global completeopt left untouched (bug #5)")

  vim.bo.filetype = ""
end

-- bug #5b: manage_completeopt=false opts out.
do
  init.setup({ disabled_filetypes = {}, manage_completeopt = false })
  vim.bo.completeopt = "menu,popup"
  vim.bo.filetype = "lua"
  vim.api.nvim_exec_autocmds("FileType", { buffer = 0, modeline = false })

  local co = vim.api.nvim_get_option_value("completeopt", { buf = 0 })
  eq(co:find("noselect") == nil, true, "manage_completeopt=false opts out (bug #5)")

  vim.bo.filetype = ""
end

-- bug #3: off-by-one — guard C reads the full typed prefix.
-- "local greeting": the word starts at 0-indexed column 6 and the cursor sits
-- at 0-indexed column 14, so the typed prefix is exactly "greeting".
do
  local mock = arm({ line_text = "local greeting", cursor_col0 = 14 })
  complete._get_state().start_col = 6
  complete._get_state().prefix = "greeting"
  eq(complete._should_re_trigger(mock), true, "Guard C reads full prefix, not short by one (bug #3)")

  -- One byte short must not match, proving the check is not off by one.
  local short = arm({ line_text = "local greeting", cursor_col0 = 13 })
  complete._get_state().start_col = 6
  complete._get_state().prefix = "greeting"
  eq(complete._should_re_trigger(short), false, "Guard C rejects a one-byte-short prefix (bug #3)")
end

-- autocmd: disabled_filetypes are skipped.
do
  init.setup({ disabled_filetypes = { "markdown" }, manage_completeopt = true })
  vim.bo.completefunc = ""
  vim.bo.filetype = "markdown"
  vim.api.nvim_exec_autocmds("FileType", { buffer = 0, modeline = false })
  eq(vim.bo.completefunc, "", "disabled_filetypes are skipped")
  vim.bo.filetype = ""
end

-- bug #8: the column snapshot must be in the same coordinate space the guards
-- observe. During findstart=0 Neovim reports the word start, so storing
-- vim.fn.col('.') there made Guard B reject every real update.
do
  complete.reset()
  set_lines({ "local greeting = 1", "local gre" })
  cache.clear()
  vim.api.nvim_win_set_cursor(0, { 2, 9 })

  local real_call_async = client.call_async
  client.call_async = function()
    return 903
  end
  init.config.debounce_ms = 10000

  complete.JevComplete(1, "")
  complete.JevComplete(0, "gre")

  local state = complete._get_state()
  -- start_col is 6 ("local gre"), so the cursor at guard time is 6 + 3 + 1 = 10.
  eq(state.start_col, 6, "bug #8: start_col captured")
  eq(state.cursor_col, 10, "bug #8: cursor_col stored in guard-time coordinates")

  client.call_async = real_call_async
end

-- bug #9: the candidates pass 1 displayed must be the ones ranked. Re-filtering
-- inside the Jev callback would return a different set, because during
-- findstart=0 Neovim withholds the in-progress word from the buffer.
do
  complete.reset()
  set_lines({ "local greeter = 1", "gre" })
  cache.clear()
  vim.api.nvim_win_set_cursor(0, { 2, 3 })

  local sent_questions
  local real_call_async = client.call_async
  client.call_async = function(_state, questions, callback)
    sent_questions = questions
    vim.defer_fn(function()
      local answers = {}
      for name in pairs(questions) do
        answers[name] = { noul = 0.9 }
      end
      callback(nil, answers)
    end, 5)
    return 904
  end

  init.config.debounce_ms = 10
  init.config.jev_question_format = "noul"

  local pass1 = complete.JevComplete(1, "")
  ok(type(pass1) == "number", "bug #9: pass 1 runs")
  local shown = complete.JevComplete(0, "gre")
  ok(#shown > 0, "bug #9: pass 1 shows candidates")

  -- Mutate the buffer after pass 1 to prove the ranked set is the pass 1 set.
  vim.api.nvim_buf_set_lines(0, 1, 2, false, { "gre" })
  vim.wait(300, function()
    return complete._get_state().readiness ~= nil
  end)

  local state = complete._get_state()
  ok(state.candidates ~= nil, "bug #9: pass 1 candidates retained in state")

  local question_count = sent_questions and vim.tbl_count(sent_questions) or 0
  eq(question_count, #shown, "bug #9: Jev was asked about exactly the shown candidates")

  local pass2 = complete.JevComplete(0, "gre")
  eq(#pass2, #shown, "bug #9: pass 2 item count equals pass 1")

  client.call_async = real_call_async
end

-- ---------------------------------------------------------------------------
-- Restore + summary
-- ---------------------------------------------------------------------------
init.config = saved_config
vim.system = real_system
complete.reset()

print("")
print(string.format("TOTAL: %d passed, %d failed", passes, failures))

if failures > 0 then
  vim.cmd("cquit 1")
end
