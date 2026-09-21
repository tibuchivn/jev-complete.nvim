-- tests/experiment_inplace_vs_feedkeys.lua
-- Layer 3 experiment: measures the two menu-update strategies against real
-- Neovim UI.
--
--   Mode A "feedkeys": rank -> readiness -> feedkeys("<C-x><C-u>") -> pass 2
--   Mode B "inplace" : rank -> vim.fn.complete(start_col + 1, ranked_items)
--
-- Driven by tests/experiment_inplace_vs_feedkeys.sh.
--
-- The completion trigger is NOT sent from Lua: programmatic feedkeys/nvim_input
-- do not open the popup from a timer callback (measured). The shell driver
-- sends a real <C-x><C-u> through tmux, exactly as a user would. This file only
-- instruments the run and writes the measurements.
--
-- Each mode uses the shipped code path (init.config.menu_update_mode), so the
-- numbers describe what users actually get, not a prototype.

local mode = vim.env.JEV_EXPERIMENT_MODE or "feedkeys"
local out = vim.env.JEV_EXPERIMENT_OUT or "/tmp/jev_experiment_result.txt"

local lines = {}
local function rec(line)
  lines[#lines + 1] = line
end
local function flush()
  local fh = io.open(out, "w")
  fh:write(table.concat(lines, "\n") .. "\n")
  fh:close()
end

local init = require("jev")
local client = require("jev.client")
local cache = require("jev.cache")

local RANKED_FIRST = "helicopter"

init.setup({
  menu_update_mode = mode,
  debounce_ms = 50,
  jev_timeout_ms = 5000,
  debug = false,
  manage_completeopt = true,
})

vim.g.jev_api_key = "experiment-key"

-- Filetype detection is off under -u NONE, so the FileType autocmd that
-- installs the completefunc would never fire. Attach it directly, which also
-- makes the experiment independent of filetype detection.
vim.bo.completefunc = "v:lua.JevComplete"

-- The same autocmd is what applies the buffer-local noselect, so apply it here
-- too. Without noselect the popup auto-selects its first entry and inserts it,
-- which changes the line and makes the guards reject the update.
vim.bo.completeopt = "menu,popup,noselect"

local call_started_at = nil
local delivered_at = nil
client.call_async = function(_state, questions, callback)
  call_started_at = vim.uv.hrtime() / 1e6
  local answers = {}
  for name in pairs(questions) do
    answers[name] = { noul = name == ("cand_" .. RANKED_FIRST) and 0.99 or 0.05 }
  end
  vim.defer_fn(function()
    delivered_at = vim.uv.hrtime() / 1e6
    callback(nil, answers)
  end, 300)
  return 777
end

local FEEDKEYS_SEEN = false
local INPLACE_SEEN = false
local GUARD_LOG = {}
local real_feedkeys = vim.api.nvim_feedkeys
vim.api.nvim_feedkeys = function(keys, feed_mode, escape)
  if type(keys) == "string" and keys:find("\24\21", 1, true) then
    FEEDKEYS_SEEN = true
  end
  return real_feedkeys(keys, feed_mode, escape)
end
local real_complete = vim.fn.complete
vim.fn.complete = function(start_col, items)
  INPLACE_SEEN = true
  return real_complete(start_col, items)
end

-- Diagnostic: record whether the guards permitted the update, together with the
-- live values at guard time.
local complete = require("jev.complete")
local real_guard = complete._should_re_trigger
complete._should_re_trigger = function(...)
  local state = complete._get_state()
  local detail = string.format(
    "pum=%s line=%s/%s col=%s/%s start_col=%s prefix=%q",
    tostring(vim.fn.pumvisible()),
    tostring(vim.fn.line(".")), tostring(state.cursor_line),
    tostring(vim.fn.col(".")), tostring(state.cursor_col),
    tostring(state.start_col), tostring(state.prefix)
  )
  local ok, result = pcall(real_guard, ...)
  GUARD_LOG[#GUARD_LOG + 1] = detail .. " -> " .. (ok and tostring(result) or ("error " .. tostring(result)))
  return ok and result or false
end

-- The word starts at column 8, deliberately away from 0: complete() is a silent
-- no-op for startcol <= 0, which would confound the comparison.
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local helicopter = 1",
  "local hello = 2",
  "local held = 3",
  "local foo hel",
})
cache.clear()

local function menu_words()
  local items = vim.fn.complete_info({ "items" }).items or {}
  local words = {}
  for _, item in ipairs(items) do
    words[#words + 1] = item.word
  end
  return table.concat(words, ",")
end

rec("mode=" .. mode)

-- Cursor at the end of "local foo hel" and enter insert mode; the shell driver
-- then presses <C-x><C-u> for real. startinsert! appends at end of line, which
-- gives the full "hel" prefix: set_cursor is clamped to the last character and
-- a plain startinsert would insert before it, leaving only "he".
vim.api.nvim_win_set_cursor(0, { 4, 12 })
vim.cmd("startinsert!")

-- Poll from the main loop. Phases are event-driven rather than wall-clock:
-- the shell sends the trigger after nvim has started, so a fixed window that
-- begins at load time would expire before the menu ever opens.
local started = vim.uv.hrtime() / 1e6
local fuzzy_order = nil
local settle_started = nil
local update_at = nil
local flicker_samples = {}

local timer = vim.uv.new_timer()
timer:start(50, 50, vim.schedule_wrap(function()
  local now = vim.uv.hrtime() / 1e6

  -- Phase 1: wait for the menu to open, then capture the fuzzy order.
  if fuzzy_order == nil then
    if vim.fn.pumvisible() == 1 then
      fuzzy_order = menu_words()
      settle_started = now
      rec("pum_after_pass1=1")
      rec("fuzzy_order=" .. fuzzy_order)
    elseif now - started > 10000 then
      timer:stop()
      timer:close()
      rec("pum_after_pass1=" .. vim.fn.pumvisible())
      rec("fuzzy_order=")
      rec("menu_after=" .. menu_words())
      rec("feedkeys_seen=" .. tostring(FEEDKEYS_SEEN))
      rec("inplace_seen=" .. tostring(INPLACE_SEEN))
      rec("first_after=")
      rec("reordered=false")
      rec("accepted_line=" .. vim.api.nvim_get_current_line())
      rec("text_intact=false")
      rec("note=menu never opened")
      flush()
      vim.cmd("qa!")
    end
    return
  end

  -- Sample for flicker: the popup closing at any point during the update is
  -- what a user would perceive as a flash.
  local sample = (vim.fn.pumvisible() == 1) and menu_words() or "<closed>"
  if #flicker_samples == 0 or flicker_samples[#flicker_samples] ~= sample then
    flicker_samples[#flicker_samples + 1] = sample
  end

  -- Record when the menu first differs from the fuzzy order: that is the
  -- user-visible update moment.
  if update_at == nil and sample ~= "<closed>" and sample ~= fuzzy_order then
    update_at = now
  end

  -- Phase 2: settle long enough for the stubbed 300ms answer plus the mode's
  -- own update path, then measure the resulting menu.
  if now - settle_started < 2500 then
    return
  end

  timer:stop()
  timer:close()

  local after_words = menu_words()
  local first_word = after_words:match("^([^,]*)") or ""
  rec("menu_after=" .. after_words)
  rec("feedkeys_seen=" .. tostring(FEEDKEYS_SEEN))
  rec("inplace_seen=" .. tostring(INPLACE_SEEN))
  rec("guard_calls=" .. tostring(#GUARD_LOG))
  rec("first_after=" .. first_word)
  rec("reordered=" .. tostring(first_word == RANKED_FIRST))
  if call_started_at and delivered_at then
    rec(string.format("stub_latency_ms=%.1f", delivered_at - call_started_at))
  end
  -- Flicker: how many distinct states the menu passed through. A single
  -- transition (fuzzy -> ranked) means no visible flash; a <closed> entry means
  -- the popup blinked off at some point.
  rec("flicker_states=" .. table.concat(flicker_samples, " => "))
  rec("flicker_reopened=" .. tostring(table.concat(flicker_samples, "|"):find("<closed>") ~= nil))
  if update_at then
    rec(string.format("update_latency_ms=%.1f", update_at - (call_started_at or update_at)))
  end
  flush()

  -- Phase 3: the shell sends the accept key as real input, then the final
  -- measurement is taken.
  local accepted_marker = "/tmp/jev_experiment_accepted.txt"
  local fh = io.open(accepted_marker, "w")
  fh:write("send\n")
  fh:close()

  vim.defer_fn(function()
    local accepted = vim.api.nvim_get_current_line()
    rec("accepted_line=" .. accepted)
    rec("text_intact=" .. tostring(accepted == "local foo helicopter"))
    flush()
    vim.cmd("qa!")
  end, 1200)
end))
