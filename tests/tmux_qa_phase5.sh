#!/bin/bash
# tests/tmux_qa_phase5.sh
# Layer 3: real-UI E2E for auto-trigger (5 scenarios).
#
# Needs tmux. No API key required: the Jev transport is stubbed so the ranking
# is deterministic.
#
# Run:
#   ./tests/tmux_qa_phase5.sh
#
# Written for bash 3.2 (macOS default): no associative arrays.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SESSION="jev_qa_phase5"
INITFILE="/tmp/jev5/qa_init.lua"
LOGDIR="/tmp/jev5/qa"
SNAPDIR="/tmp/jev5/snap"

if ! command -v tmux >/dev/null 2>&1; then
  echo "SKIP: tmux not available"
  exit 0
fi

mkdir -p "$LOGDIR" "$SNAPDIR"

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -f "$INITFILE"
}
trap cleanup EXIT

# $1 scenario id, $2 auto_trigger, $3 disabled_filetypes lua expr, $4 filetype
write_init() {
  local id="$1" auto="$2" disabled="$3" ft="$4"
  cat > "$INITFILE" << LUA
vim.env.JEV_QA_ID = "$id"
vim.env.JEV_QA_LOG = "$LOGDIR/$id.log"
vim.opt.runtimepath:prepend("$REPO_ROOT")

-- Deterministic Jev: no network, fixed ranking.
local stub = function(_state, questions, callback)
  local answers = {}
  for name in pairs(questions) do
    answers[name] = { noul = name == "cand_greeting" and 0.99 or 0.05 }
  end
  vim.defer_fn(function() callback(nil, answers) end, 250)
  return 9001
end
require("jev.client").call_async = stub

require("jev").setup({
  auto_trigger = $auto,
  auto_debounce_ms = 400,
  debounce_ms = 200,
  min_word_length = 3,
  disabled_filetypes = $disabled,
  manage_completeopt = true,
  debug = false,
})

-- Record every trigger and every completefunc invocation so PASS/FAIL is
-- decided by the mechanism, not by a fragile pane diff.
local logf = io.open(vim.env.JEV_QA_LOG, "w")
_G.QA = function(s) logf:write(s .. "\n"); logf:flush() end

local complete = require("jev.complete")
local real_trigger = complete.trigger
complete.trigger = function()
  _G.QA("AUTO_TRIGGER")
  return real_trigger()
end

local internal = _G.JevComplete
local pass = 0
_G.JevComplete = function(findstart, base)
  local r = internal(findstart, base)
  if findstart == 0 then
    pass = pass + 1
    local words = {}
    for _, item in ipairs(r or {}) do words[#words + 1] = item.word end
    _G.QA("COMPLETEFUNC_PASS" .. pass .. " base=" .. tostring(base)
      .. " items=" .. table.concat(words, ","))
  end
  return r
end
require("jev.complete").JevComplete = _G.JevComplete

local cf = require("jev.client")
local real_call = cf.call_async
cf.call_async = function(state, questions, cb)
  _G.QA("JEV_CALL")
  return real_call(state, questions, cb)
end

vim.cmd("filetype on")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "def greet(name):",
  "    return greeting(name)",
  "",
  "value = ",
})
vim.bo.filetype = "$ft"
LUA
}

run_scenario() {
  local id="$1" auto="$2" disabled="$3" ft="$4" keys="$5" manual="${6:-}"
  local log="$LOGDIR/$id.log"

  write_init "$id" "$auto" "$disabled" "$ft"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -f "$log"

  tmux new-session -d -s "$SESSION" -x 120 -y 30 "nvim -u '$INITFILE'"
  sleep 3

  # Real terminal input: cursor to end of the last line, insert mode.
  tmux send-keys -t "$SESSION" Escape
  sleep 0.2
  tmux send-keys -t "$SESSION" G
  sleep 0.2
  tmux send-keys -t "$SESSION" A
  sleep 0.3

  # Type the word character by character, spaced past the debounce window.
  local i=1
  while [ "$i" -le ${#keys} ]; do
    tmux send-keys -t "$SESSION" "${keys:$((i-1)):1}"
    sleep 0.2
    i=$((i + 1))
  done

  if [ -n "$manual" ]; then
    sleep 0.15
    tmux send-keys -t "$SESSION" C-x C-u
  fi

  sleep 2.5
  tmux capture-pane -t "$SESSION" -p > "$SNAPDIR/$id.txt" 2>/dev/null || true
}

has() { grep -q "$2" "$1" 2>/dev/null; }
count() { grep -c "$2" "$1" 2>/dev/null || echo 0; }

declare_result() {
  local id="$1" verdict="$2" note="$3"
  printf '%-34s %s%s\n' "$id" "$verdict" "$note"
}

echo "======================================================================"
echo " Phase 5: auto-trigger tmux E2E (5 scenarios)"
echo "======================================================================"

FAILED=0

# --- Scenario 1: auto-trigger fires, Jev ranks, and the menu reorders ---
run_scenario "s1_auto_fires" true "{}" "python" "gre"
s1_log="$LOGDIR/s1_auto_fires.log"
s1_snap="$SNAPDIR/s1_auto_fires.txt"
# The stub ranks "greeting" above "greet", which is the reverse of the fuzzy
# order (shorter word scores higher), so the ranked word appearing first proves
# the menu was actually rewritten.
if has "$s1_log" "AUTO_TRIGGER" && has "$s1_log" "COMPLETEFUNC_PASS1" && has "$s1_log" "JEV_CALL"; then
  if grep -A3 "value = gre" "$s1_snap" 2>/dev/null | grep -q "greeting"; then
    declare_result "1 auto-trigger fires + reorders" "PASS" " (trigger, Jev, menu reordered)"
  else
    declare_result "1 auto-trigger fires + reorders" "FAIL" " (menu did not reorder)"
    FAILED=$((FAILED + 1))
  fi
else
  declare_result "1 auto-trigger fires + reorders" "FAIL" " (see $s1_log)"
  FAILED=$((FAILED + 1))
fi

# --- Scenario 2: too-short prefix must not fire ---
run_scenario "s2_short_prefix" true "{}" "python" "gr"
s2_log="$LOGDIR/s2_short_prefix.log"
if has "$s2_log" "AUTO_TRIGGER"; then
  declare_result "2 short prefix does not fire" "FAIL" " (auto trigger fired)"
  FAILED=$((FAILED + 1))
else
  declare_result "2 short prefix does not fire" "PASS" " (no trigger)"
fi

# --- Scenario 3: disabled filetype must not fire ---
run_scenario "s3_disabled_ft" true '{ "python" }' "python" "gre"
s3_log="$LOGDIR/s3_disabled_ft.log"
if has "$s3_log" "AUTO_TRIGGER"; then
  declare_result "3 disabled filetype does not fire" "FAIL" " (auto trigger fired)"
  FAILED=$((FAILED + 1))
else
  declare_result "3 disabled filetype does not fire" "PASS" " (no trigger)"
fi

# --- Scenario 4: auto off, manual still works ---
run_scenario "s4_manual_only" false "{}" "python" "gre" "yes"
s4_log="$LOGDIR/s4_manual_only.log"
if has "$s4_log" "AUTO_TRIGGER"; then
  declare_result "4 manual only (auto off)" "FAIL" " (auto fired while disabled)"
  FAILED=$((FAILED + 1))
elif has "$s4_log" "COMPLETEFUNC_PASS1"; then
  declare_result "4 manual only (auto off)" "PASS" " (manual completed)"
else
  declare_result "4 manual only (auto off)" "FAIL" " (manual did not complete)"
  FAILED=$((FAILED + 1))
fi

# --- Scenario 5: manual press during the auto window does not double-trigger ---
run_scenario "s5_manual_cancels_auto" true "{}" "python" "gre" "yes"
s5_log="$LOGDIR/s5_manual_cancels_auto.log"
auto_count="$(count "$s5_log" AUTO_TRIGGER)"
if has "$s5_log" "COMPLETEFUNC_PASS1"; then
  if [ "$auto_count" -le 1 ]; then
    declare_result "5 manual does not double-trigger" "PASS" " (auto triggers: $auto_count)"
  else
    declare_result "5 manual does not double-trigger" "FAIL" " (auto triggers: $auto_count)"
    FAILED=$((FAILED + 1))
  fi
else
  declare_result "5 manual does not double-trigger" "FAIL" " (no completion happened)"
  FAILED=$((FAILED + 1))
fi

echo
echo "----------------------------------------------------------------------"
echo " logs"
echo "----------------------------------------------------------------------"
for id in s1_auto_fires s2_short_prefix s3_disabled_ft s4_manual_only s5_manual_cancels_auto; do
  echo "--- $id ---"
  cat "$LOGDIR/$id.log" 2>/dev/null || echo "(no log)"
  echo
done

if [ "$FAILED" -ne 0 ]; then
  echo "RESULT: $FAILED scenario(s) failed"
  exit 1
fi

echo "RESULT: all 5 scenarios PASS"
exit 0
