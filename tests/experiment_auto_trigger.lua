-- tests/experiment_auto_trigger.lua
-- Task 5.2: which mechanism can open the completion popup without the user
-- pressing <C-x><C-u>?
--
-- Driven by tests/experiment_auto_trigger.sh, which runs one mechanism per tmux
-- pane and collects the verdicts. Not run directly.
--
-- Mechanism is chosen with $JEV_EXPERIMENT_MECHANISM:
--   1  complete() from InsertCharPre
--   2  feedkeys("<C-x><C-u>") from InsertCharPre
--   3  feedkeys("<C-x><C-u>") from TextChangedI
--   4  nvim_input("<C-x><C-u>") from TextChangedI
--   5  complete() from TextChangedI, bypassing the completefunc
--
-- The typing itself is sent by the shell as real terminal input, because
-- programmatic keys from a timer callback do not open the popup (Phase 4
-- finding). Each mechanism is therefore exercised in the context it would
-- really run in: a genuine insert-mode keystroke.
--
-- Measurement is event-driven: it starts when the first real keystroke is
-- observed, not when nvim loads. A load-time window would expire before the
-- shell has typed anything.

local mechanism = tonumber(vim.env.JEV_EXPERIMENT_MECHANISM or "1")
local out = vim.env.JEV_EXPERIMENT_OUT or "/tmp/jev5/result.txt"

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
local cache = require("jev.cache")

init.setup({
  debounce_ms = 50,
  auto_debounce_ms = 50,
  jev_timeout_ms = 3000,
  debug = false,
  manage_completeopt = true,
  auto_trigger = false,
})

vim.g.jev_api_key = "experiment-key"

-- The plugin's own completefunc, so "works with 2-pass?" is meaningful.
vim.bo.completefunc = "v:lua.JevComplete"
vim.bo.completeopt = "menu,popup,noselect"

local real_complete = vim.fn.complete
vim.fn.complete = function(start_col, items)
  rec("complete() invoked with startcol=" .. tostring(start_col))
  return real_complete(start_col, items)
end

-- Count invocations of the plugin's own completefunc. This is the decisive
-- "works with 2-pass?" signal: only a mechanism that goes through the
-- completefunc can reuse the existing fuzzy -> rank -> menu-update pipeline.
local COMPLETEFUNC_CALLS = 0
local internal_completefunc = _G.JevComplete
if internal_completefunc then
  _G.JevComplete = function(findstart, base)
    COMPLETEFUNC_CALLS = COMPLETEFUNC_CALLS + 1
    return internal_completefunc(findstart, base)
  end
  require("jev.complete").JevComplete = _G.JevComplete
end

local line_at_trigger = ""

local real_feedkeys = vim.api.nvim_feedkeys
vim.api.nvim_feedkeys = function(keys, feed_mode, escape)
  if type(keys) == "string" and keys:find("\24\21", 1, true) then
    rec("feedkeys(<C-x><C-u>) mode=" .. tostring(feed_mode))
  end
  return real_feedkeys(keys, feed_mode, escape)
end

-- Fixture: "gre" must complete to real words in the buffer.
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "def greet(name):",
  "    return greeting(name)",
  "",
  "value = ",
})
vim.bo.filetype = "python"
cache.clear()

rec("mechanism=" .. mechanism)

local triggered = false
local measured = false

-- Trigger on the settled prefix, not on the first keystroke. Firing at one
-- character would test a different thing (and for real auto-trigger the
-- min_word_length condition would reject it anyway).
-- Must exceed the shell's inter-keystroke gap (250ms), otherwise the timer
-- fires mid-typing and measures a half-typed prefix.
local ARMED_AFTER_MS = 400

local function do_trigger()
  triggered = true

  local line = vim.api.nvim_get_current_line()
  line_at_trigger = line
  local col = vim.fn.col(".") - 1
  local start_col = col
  while start_col > 0 and line:sub(start_col, start_col):match("[%w_]") do
    start_col = start_col - 1
  end

  local items = { { word = "greet" }, { word = "greeting" } }

  if mechanism == 1 then
    rec("triggering after settle: complete() from InsertCharPre")
    pcall(vim.fn.complete, start_col + 1, items)
  elseif mechanism == 2 or mechanism == 3 then
    rec("triggering after settle: feedkeys(<C-x><C-u>)")
    real_feedkeys(
      vim.api.nvim_replace_termcodes("<C-x><C-u>", true, false, true), "n", false
    )
  elseif mechanism == 4 then
    rec("triggering after settle: nvim_input(<C-x><C-u>)")
    vim.api.nvim_input(vim.api.nvim_replace_termcodes("<C-x><C-u>", true, false, true))
  else
    rec("triggering after settle: complete() with no completefunc")
    vim.bo.completefunc = ""
    pcall(vim.fn.complete, start_col + 1, items)
  end
end

local function measure()
  if measured then
    return
  end
  measured = true

  local pum = vim.fn.pumvisible()
  local items = vim.fn.complete_info({ "items" }).items or {}
  local words = {}
  for _, item in ipairs(items) do
    words[#words + 1] = item.word
  end

  local line = vim.api.nvim_get_current_line()
  rec("menu_open=" .. tostring(pum == 1))
  rec("menu_items=" .. table.concat(words, ","))
  rec("menu_items_correct=" .. tostring(#words > 0))
  rec("completefunc_calls=" .. tostring(COMPLETEFUNC_CALLS))
  rec("uses_completefunc=" .. tostring(COMPLETEFUNC_CALLS > 0))
  rec("line_at_trigger=" .. line_at_trigger)
  rec("line=" .. line)
  rec("text_intact=" .. tostring(line == "value = gre"))
  rec("completefunc=" .. vim.inspect(vim.bo.completefunc))

  flush()
  vim.cmd("qa!")
end

-- Measure only after the trigger has had a full settle window to take effect,
-- so the reading cannot race the typing or the trigger itself.
local measure_timer = nil
local function arm_measurement()
  if measure_timer then
    measure_timer:stop()
    measure_timer:close()
  end
  measure_timer = vim.uv.new_timer()
  measure_timer:start(1200, 0, vim.schedule_wrap(function()
    measure_timer:stop()
    measure_timer:close()
    measure_timer = nil
    measure()
  end))
end

-- Word characters immediately before the cursor, which is what a real
-- auto-trigger would evaluate.
local function current_prefix()
  local line = vim.api.nvim_get_current_line()
  local col = vim.fn.col(".") - 1
  local start_col = col
  while start_col > 0 and line:sub(start_col, start_col):match("[%w_]") do
    start_col = start_col - 1
  end
  return line:sub(start_col + 1, col)
end

-- Armed on every keystroke. When it fires the user has stopped typing, so the
-- prefix is settled; that is the moment a real auto-trigger would fire.
-- Guards against TextChangedI firing spuriously when insert mode is entered
-- with no actual typing: an empty prefix must not arm the timer, otherwise the
-- trigger fires before the shell has typed anything.
local settle_timer = nil
local function on_keystroke()
  if current_prefix() == "" then
    return
  end

  if settle_timer then
    settle_timer:stop()
    settle_timer:close()
  end
  settle_timer = vim.uv.new_timer()
  settle_timer:start(ARMED_AFTER_MS, 0, vim.schedule_wrap(function()
    settle_timer:stop()
    settle_timer:close()
    settle_timer = nil
    if not triggered then
      do_trigger()
    end
    arm_measurement()
  end))
end

local hook_event = (mechanism == 1 or mechanism == 2) and "InsertCharPre" or "TextChangedI"
vim.api.nvim_create_autocmd(hook_event, {
  callback = function()
    on_keystroke()
  end,
})

-- Give up rather than hang if the shell never types.
local watchdog = vim.uv.new_timer()
watchdog:start(20000, 0, vim.schedule_wrap(function()
  watchdog:stop()
  watchdog:close()
  if not measured then
    rec("menu_open=false")
    rec("menu_items=")
    rec("menu_items_correct=false")
    rec("line=" .. vim.api.nvim_get_current_line())
    rec("text_intact=false")
    rec("note=no keystroke observed within 20s")
    flush()
    vim.cmd("qa!")
  end
end))

-- Cursor at end of "value = " and enter insert mode; the shell types "gre".
vim.api.nvim_win_set_cursor(0, { 4, 8 })
vim.cmd("startinsert!")
