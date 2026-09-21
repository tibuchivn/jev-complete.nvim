-- lua/jev/complete.lua
-- completefunc entry point implementing the 2-pass architecture:
-- pass 1 returns fuzzy candidates immediately, then Jev ranks them and a
-- feedkeys re-trigger makes pass 2 serve the ranked order.

local init = require("jev")
local cache = require("jev.cache")
local source = require("jev.source")

local M = {}

-- Snapshot and cross-pass state.
M.state = {}

-- Handle of the pending debounce timer, if any.
M.debounce_timer = nil

local function reset_state()
  M.state = {
    bufnr = nil,
    prefix = nil,
    start_col = nil,
    cursor_line = nil,
    cursor_col = nil,
    call_id = nil,
    readiness = nil,
    candidates = nil,
    cached_ranked_items = nil,
    snapshot_bufnr = nil,
    snapshot_changedtick = nil,
  }
end

reset_state()

local function stop_debounce_timer()
  if M.debounce_timer then
    M.debounce_timer:stop()
    M.debounce_timer:close()
    M.debounce_timer = nil
  end
end

-- Column where the word before `col` starts (0-indexed).
local function word_start_col(line, col)
  while col > 0 and line:sub(col, col):match("[%w_]") do
    col = col - 1
  end
  return col
end

-- Decide whether the completion menu may still be replaced by Jev's ranking.
-- Only three guards are used: the popup being visible, the cursor not having
-- moved, and the typed prefix being unchanged. The selected-entry and
-- changedtick guards are intentionally omitted: the completion machinery
-- itself selects index 0 and bumps changedtick as soon as the menu opens, so
-- those two can never be satisfied in real use.
-- `mock` lets the guards be unit tested without an insert-mode session.
function M._should_re_trigger(mock)
  mock = mock or {}

  local pumvisible = mock.pumvisible or vim.fn.pumvisible
  if pumvisible() == 0 then
    init.log_guard("Guard A reject: popup not visible")
    return false
  end

  local line = mock.line or function()
    return vim.fn.line(".")
  end
  local col = mock.col or function()
    return vim.fn.col(".")
  end
  if line() ~= M.state.cursor_line or col() ~= M.state.cursor_col then
    init.log_guard("Guard B reject: cursor moved")
    return false
  end

  -- The prefix is recomputed from the cursor position rather than read from
  -- complete_info(), which has no "base" field in Neovim 0.12.
  local cursor = mock.cursor or function()
    return vim.api.nvim_win_get_cursor(0)
  end
  local line_text = mock.line_text or vim.api.nvim_get_current_line

  local cursor_col = cursor()[2]
  local current_prefix = line_text():sub(M.state.start_col + 1, cursor_col)
  if current_prefix ~= M.state.prefix then
    init.log_guard(string.format(
      "Guard C reject: prefix changed ('%s' -> '%s')",
      M.state.prefix, current_prefix
    ))
    return false
  end

  return true
end

-- Arm (or re-arm) the debounce timer that fires the Jev request.
function M._schedule_debounce()
  stop_debounce_timer()

  local timer = vim.uv.new_timer()
  M.debounce_timer = timer
  timer:start(init.config.debounce_ms, 0, vim.schedule_wrap(function()
    timer:stop()
    timer:close()
    if M.debounce_timer == timer then
      M.debounce_timer = nil
    end
    M._trigger_jev_call()
  end))
end

-- Replace the open menu with the ranked list without re-triggering completion.
-- complete() expects a 1-based column, so start_col (0-based, as returned by
-- findstart) needs the +1; passing the bare value also fails silently at
-- column 0, where complete() does nothing for startcol <= 0.
-- Returns true only when the menu verifiably changed, because complete() can
-- also be a silent no-op and "auto" relies on this to fall back safely.
local function apply_inplace(ranked_items)
  local start_col = M.state.start_col
  if type(start_col) ~= "number" or #ranked_items == 0 then
    return false
  end

  if vim.fn.pumvisible() == 0 then
    return false
  end

  if not pcall(vim.fn.complete, start_col + 1, ranked_items) then
    return false
  end

  if vim.fn.pumvisible() == 0 then
    return false
  end

  local items = vim.fn.complete_info({ "items" }).items or {}
  return items[1] ~= nil and items[1].word == ranked_items[1].word
end

local function re_trigger()
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes("<C-x><C-u>", true, false, true),
    "n",
    false
  )
end

-- Build the request, ask Jev to rank, then update the open menu.
function M._trigger_jev_call()
  local state = M.state
  if not state or not state.prefix then
    return
  end

  local ranking = require("jev.ranking")
  local client = require("jev.client")

  -- Use the candidates pass 1 actually displayed. Re-filtering here would
  -- disagree with what the user sees, because during findstart=0 Neovim
  -- withholds the word being typed and the buffer therefore holds one word
  -- fewer at that moment.
  local candidates = state.candidates or source.filter_candidates(state.prefix, cache.get_words())
  if #candidates == 0 then
    return
  end

  local payload_state = ranking.build_state(require("jev.context").build_context(), candidates)
  local questions = ranking.build_questions(candidates)

  if state.call_id then
    client.cancel(state.call_id)
    state.call_id = nil
  end

  state.call_id = client.call_async(payload_state, questions, function(err, answers)
    vim.schedule(function()
      if err then
        init.log("Jev error: " .. tostring(err))
        return
      end

      local current = M.state
      if not current or not current.prefix then
        return
      end

      -- `candidates` is the list pass 1 showed. It must not be re-filtered
      -- here: during findstart=0 Neovim withholds the word being typed, so a
      -- fresh extraction would return a different set and pass 2 would gain or
      -- lose entries rather than only reordering the visible ones.
      local probabilities = ranking.parse_response(
        answers, init.config.jev_question_format, candidates
      )
      local ranked = ranking.rank_candidates(candidates, probabilities)

      if not M._should_re_trigger() then
        return
      end

      local ranked_items = {}
      for _, entry in ipairs(ranked) do
        ranked_items[#ranked_items + 1] = { word = entry.word }
      end

      local bufnr = vim.api.nvim_get_current_buf()
      cache.set_jev_result(bufnr, current.snapshot_changedtick, current.prefix, probabilities)

      local mode = init.config.menu_update_mode

      if mode == "inplace" or mode == "auto" then
        if apply_inplace(ranked_items) then
          if init.config.debug then
            init.log("menu updated in place")
          end
          return
        end
        if mode == "inplace" then
          -- Explicitly requested: do not silently switch strategies.
          if init.config.debug then
            init.log("in-place update unavailable, menu left unchanged")
          end
          return
        end
      end

      current.cached_ranked_items = ranked_items
      current.readiness = {
        bufnr = current.snapshot_bufnr,
        prefix = current.prefix,
      }

      re_trigger()
    end)
  end)
end

-- completefunc implementation.
function M.JevComplete(findstart, base)
  if not init.config.enabled then
    return findstart == 1 and -3 or {}
  end

  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local start_col = word_start_col(line, vim.fn.col(".") - 1)
    M.state.start_col = start_col
    M.state.bufnr = vim.api.nvim_get_current_buf()
    return start_col
  end

  local current_bufnr = vim.api.nvim_get_current_buf()

  -- PASS 2: a ranked list is ready for this buffer and prefix.
  local readiness = M.state.readiness
  if readiness and readiness.bufnr == current_bufnr and readiness.prefix == base then
    local ranked = M.state.cached_ranked_items or {}
    M.state.readiness = nil
    M.state.cached_ranked_items = nil
    return ranked
  end

  -- PASS 1: fuzzy candidates.
  if base == "" then
    return {}
  end

  local candidates = source.filter_candidates(base, cache.get_words())
  if #candidates == 0 then
    return {}
  end

  M.state.prefix = base
  -- Keep the displayed candidate list so the async callback ranks exactly what
  -- pass 1 showed instead of a freshly (and differently) filtered set.
  M.state.candidates = candidates
  M.state.cursor_line = vim.fn.line(".")
  -- During findstart=0 Neovim parks the cursor at the word start, whereas the
  -- guards run later with it back at the end of the typed text. Storing
  -- vim.fn.col('.') here would therefore compare two different coordinate
  -- spaces and reject every update, so the end-of-word column is derived
  -- instead (vim.fn.col('.') at guard time equals start_col + #base + 1).
  M.state.cursor_col = (M.state.start_col or 0) + #base + 1
  M.state.snapshot_bufnr = current_bufnr
  M.state.snapshot_changedtick = vim.api.nvim_buf_get_changedtick(0)

  if M.state.call_id then
    require("jev.client").cancel(M.state.call_id)
    M.state.call_id = nil
  end

  M._schedule_debounce()

  local items = {}
  for _, candidate in ipairs(candidates) do
    items[#items + 1] = { word = candidate.word }
  end
  return items
end

-- Start completion as if the user pressed <C-x><C-u>.
function M.trigger()
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes("<C-x><C-u>", true, false, true),
    "n",
    false
  )
end

-- Reset all cross-pass state (used by tests).
function M.reset()
  stop_debounce_timer()
  reset_state()
end

-- Expose the current state (used by tests).
function M._get_state()
  return M.state
end

_G.JevComplete = M.JevComplete

return M
