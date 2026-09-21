#!/bin/bash
# tests/experiment_inplace_vs_feedkeys.sh
# Runs the menu-update experiment (Task 4.3) in a real tmux UI and prints a
# comparison table for the two strategies.
#
#   Mode A "feedkeys": rank -> readiness -> feedkeys("<C-x><C-u>") -> pass 2
#   Mode B "inplace" : rank -> vim.fn.complete(start_col + 1, ranked_items)
#
# Needs tmux but NOT an API key: the experiment stubs the transport so both
# modes run on an identical, deterministic schedule.
#
# The completion trigger and the accept key are sent as REAL terminal input via
# tmux send-keys. Programmatic feedkeys/nvim_input from a timer callback do not
# open the popup (measured on Neovim 0.12.5), so Lua cannot drive this.
#
# Run:
#   ./tests/experiment_inplace_vs_feedkeys.sh
#
# Written for bash 3.2 (macOS default): no associative arrays.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SESSION="jev_experiment"
INITFILE="/tmp/jev_experiment_init.lua"
ACCEPT_MARKER="/tmp/jev_experiment_accepted.txt"

if ! command -v tmux >/dev/null 2>&1; then
  echo "SKIP: tmux not available"
  exit 0
fi

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -f "$INITFILE" "$ACCEPT_MARKER"
}
trap cleanup EXIT

run_mode() {
  local mode="$1"
  local out="/tmp/jev_experiment_${mode}.txt"

  # The mode is baked into the generated init file: a tmux session inherits the
  # tmux server's environment, not this shell's, so env passing is unreliable.
  cat > "$INITFILE" << LUA
vim.env.JEV_EXPERIMENT_MODE = "$mode"
vim.env.JEV_EXPERIMENT_OUT = "$out"
vim.opt.runtimepath:prepend("$REPO_ROOT")
dofile("$REPO_ROOT/tests/experiment_inplace_vs_feedkeys.lua")
LUA

  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -f "$out" "$ACCEPT_MARKER"

  tmux new-session -d -s "$SESSION" -x 120 -y 30 "nvim -u '$INITFILE'"
  sleep 3

  # Real user input: trigger completion.
  tmux send-keys -t "$SESSION" C-x C-u

  # Wait for the experiment to finish measuring and ask for the accept key.
  local waited=0
  while [ ! -f "$ACCEPT_MARKER" ] && [ "$waited" -lt 60 ]; do
    sleep 0.5
    waited=$((waited + 1))
  done

  if [ ! -f "$ACCEPT_MARKER" ]; then
    echo "mode=$mode ERROR: experiment never reached the accept step"
    tmux capture-pane -t "$SESSION" -p 2>/dev/null | tail -20 || true
    return 1
  fi

  # Real user input: select the top entry, then accept it. With noselect in
  # completeopt nothing is selected, so <C-y> alone would insert nothing.
  tmux send-keys -t "$SESSION" C-n
  sleep 0.3
  tmux send-keys -t "$SESSION" C-y

  # Wait for the final measurement. Poll for the specific line: the file is
  # already non-empty from the earlier phase, so testing for content would
  # return immediately and report a false failure.
  waited=0
  while ! grep -q "^text_intact=" "$out" 2>/dev/null && [ "$waited" -lt 40 ]; do
    sleep 0.5
    waited=$((waited + 1))
  done

  if ! grep -q "^text_intact=" "$out" 2>/dev/null; then
    echo "mode=$mode ERROR: no final result"
    return 1
  fi

  echo "mode=$mode complete"
}

field() {
  sed -n "s/^$2=//p" "$1" | head -1
}

echo "=============================================================="
echo " Experiment: in-place complete() vs feedkeys re-trigger"
echo "=============================================================="
echo

A="/tmp/jev_experiment_A.txt"
B="/tmp/jev_experiment_B.txt"

# run_mode writes measurements to its own per-mode file, so copy them to the
# table paths used below.
run_mode feedkeys && cp /tmp/jev_experiment_feedkeys.txt "$A"
run_mode inplace && cp /tmp/jev_experiment_inplace.txt "$B"

for pair in "A feedkeys:$A" "B inplace:$B"; do
  label="${pair%%:*}"
  file="${pair##*:}"
  echo "--- Mode $label ---"
  for k in pum_after_pass1 fuzzy_order menu_after feedkeys_seen inplace_seen first_after reordered accepted_line text_intact flicker_states flicker_reopened update_latency_ms; do
    printf '  %-18s %s\n' "$k" "$(field "$file" "$k")"
  done
  echo
done

echo "=============================================================="
echo " Comparison"
echo "=============================================================="
printf '%-20s %-24s %-24s\n' "metric" "A feedkeys" "B inplace"
printf '%-20s %-24s %-24s\n' "------" "----------" "---------"
for k in fuzzy_order menu_after feedkeys_seen inplace_seen reordered text_intact accepted_line flicker_states flicker_reopened update_latency_ms; do
  printf '%-20s %-24s %-24s\n' "$k" "$(field "$A" "$k")" "$(field "$B" "$k")"
done
echo

a_ok=false
b_ok=false
[ "$(field "$A" reordered)" = "true" ] && [ "$(field "$A" text_intact)" = "true" ] && a_ok=true
[ "$(field "$B" reordered)" = "true" ] && [ "$(field "$B" text_intact)" = "true" ] && b_ok=true

echo "Mode A correct: $a_ok"
echo "Mode B correct: $b_ok"
echo

if [ "$a_ok" = true ] && [ "$b_ok" = true ]; then
  echo "VERDICT: both modes work."
elif [ "$b_ok" = true ]; then
  echo "VERDICT: in-place wins."
elif [ "$a_ok" = true ]; then
  echo "VERDICT: feedkeys wins."
else
  echo "VERDICT: neither mode worked -- investigate before changing any default."
fi
