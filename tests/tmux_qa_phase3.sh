#!/bin/bash
# tests/tmux_qa_phase3.sh
# Layer 3: real-UI E2E QA in a tmux session.
# Requires tmux and TYPESAFE_API_KEY. Skips cleanly when either is missing.
#
# Run:
#   TYPESAFE_API_KEY=... ./tests/tmux_qa_phase3.sh
#
# PASS is decided by the re-trigger MECHANISM, not by a menu pixel diff: Jev may
# legitimately agree with the fuzzy order, which would leave the two pane
# snapshots identical while the 2-pass flow worked correctly. The log records
# the pass boundaries and the feedkeys re-trigger; the snapshots are printed
# for human review.
#
# Exits 0 when pass 1 -> feedkeys re-trigger -> pass 2 all ran, 1 otherwise.

set -euo pipefail

SESSION="jev_qa_phase3"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTFILE="/tmp/jev_qa_phase3_test.py"
INITFILE="/tmp/jev_qa_phase3_init.lua"
KEYFILE="/tmp/jev_qa_phase3_key"
LOG="/tmp/jev_qa_phase3_pass.log"
BEFORE="/tmp/jev_qa_phase3_before.txt"
AFTER="/tmp/jev_qa_phase3_after.txt"

if [ -z "${TYPESAFE_API_KEY:-}" ]; then
  echo "SKIP: TYPESAFE_API_KEY not set"
  exit 0
fi

if ! command -v tmux >/dev/null 2>&1; then
  echo "SKIP: tmux not available"
  exit 0
fi

cat > "$TESTFILE" << 'EOF'
def greet(name):
    return f"hi {name}"


greeting = gr
EOF

# A tmux session inherits the tmux SERVER's environment, not this shell's, so
# the key is handed over through a mode-600 temp file instead of the env or a
# command line. It never enters the repository and is removed by cleanup().
umask 077
printf '%s' "$TYPESAFE_API_KEY" > "$KEYFILE"

cat > "$INITFILE" << LUA
vim.opt.runtimepath:prepend("$REPO_ROOT")
vim.g.jev_api_key = vim.trim(vim.fn.readfile("$KEYFILE")[1] or "")

-- debug is off: vim.notify messages raise hit-enter prompts in a tmux pane and
-- corrupt the captures. debounce is widened so pass 1 is stable when shot.
require("jev").setup({ debug = false, debug_guards = false, jev_timeout_ms = 15000, debounce_ms = 800 })
vim.cmd("filetype on")

-- Record the pass boundaries. The on-disk log is the deterministic evidence
-- that the 2-pass flow ran, independent of what Jev happened to answer.
local logf = io.open("$LOG", "w")
local function rec(line)
  logf:write(line .. "\n")
  logf:flush()
end

local complete = require("jev.complete")
local pass = 0

local internal = _G.JevComplete
local wrapper = function(findstart, base)
  if findstart == 1 then
    return internal(findstart, base)
  end
  pass = pass + 1
  local result = internal(findstart, base)
  local words = {}
  for _, item in ipairs(result or {}) do
    words[#words + 1] = item.word
  end
  rec(string.format("PASS%d base=%q -> [%s]", pass, tostring(base), table.concat(words, ",")))
  return result
end
_G.JevComplete = wrapper
complete.JevComplete = wrapper

local real_guard = complete._should_re_trigger
complete._should_re_trigger = function(...)
  local result = real_guard(...)
  rec("GUARD=" .. tostring(result))
  return result
end

local real_feedkeys = vim.api.nvim_feedkeys
vim.api.nvim_feedkeys = function(keys, mode, escape)
  -- The plugin feeds already-translated termcodes, so match the raw bytes
  -- CTRL-X CTRL-U rather than the "<C-x><C-u>" notation.
  if type(keys) == "string" and keys:find("\24\21", 1, true) then
    rec("FEEDKEYS_RETRIGGER")
  end
  return real_feedkeys(keys, mode, escape)
end
LUA

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -f "$TESTFILE" "$INITFILE" "$KEYFILE" "$BEFORE" "$AFTER"
}
trap cleanup EXIT

# Idempotent: drop any stale session and log from a previous run.
tmux kill-session -t "$SESSION" 2>/dev/null || true
rm -f "$LOG" "$BEFORE" "$AFTER"

tmux new-session -d -s "$SESSION" -x 120 -y 30 \
  "nvim -u '$INITFILE' '$TESTFILE'"

sleep 3

# Cursor onto the last line, insert mode, then type the final "e" so the prefix
# is "gre" and the word is genuinely in flight.
tmux send-keys -t "$SESSION" Escape
sleep 0.2
tmux send-keys -t "$SESSION" G
sleep 0.2
tmux send-keys -t "$SESSION" A
sleep 0.3
tmux send-keys -t "$SESSION" "e"
sleep 0.3

tmux send-keys -t "$SESSION" C-x C-u

# Snapshot pass 1: after the debounce window but before Jev answers.
sleep 1.0
tmux capture-pane -t "$SESSION" -p > "$BEFORE"

# Wait for debounce + Jev latency + re-trigger, then snapshot pass 2.
sleep 6
tmux capture-pane -t "$SESSION" -p > "$AFTER"

echo "--- BEFORE (pass 1: fuzzy) ---"
cat "$BEFORE"
echo "--- AFTER (pass 2: ranked) ---"
cat "$AFTER"

echo "--- pass log ---"
cat "$LOG" 2>/dev/null || echo "(no log)"

fail=0

if ! grep -q "^PASS1 " "$LOG" 2>/dev/null; then
  echo "FAIL: pass 1 never ran"
  fail=1
fi

if ! grep -q "^FEEDKEYS_RETRIGGER$" "$LOG" 2>/dev/null; then
  echo "FAIL: feedkeys re-trigger never fired"
  fail=1
fi

if ! grep -q "^GUARD=true$" "$LOG" 2>/dev/null; then
  echo "FAIL: guards did not pass (no re-trigger permitted)"
  fail=1
fi

if ! grep -q "^PASS2 " "$LOG" 2>/dev/null; then
  echo "FAIL: pass 2 never ran"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "PASS: 2-pass flow observed (pass 1 -> feedkeys re-trigger -> guard pass -> pass 2)"
exit 0
