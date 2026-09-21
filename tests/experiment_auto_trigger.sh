#!/bin/bash
# tests/experiment_auto_trigger.sh
# Task 5.2: finds a mechanism that can open the completion popup without the
# user pressing <C-x><C-u>.
#
# For each mechanism, a tmux pane runs nvim with that mechanism wired up, the
# shell types "gre" as REAL terminal input, and the resulting popup is measured.
#
# Needs tmux but NOT an API key.
#
# Run:
#   ./tests/experiment_auto_trigger.sh
#
# Written for bash 3.2 (macOS default): no associative arrays.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SESSION="jev_auto_exp"
INITFILE="/tmp/jev5/init.lua"
OUTDIR="/tmp/jev5"

if ! command -v tmux >/dev/null 2>&1; then
  echo "SKIP: tmux not available"
  exit 0
fi

mkdir -p "$OUTDIR"

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -f "$INITFILE"
}
trap cleanup EXIT

run_mechanism() {
  local mech="$1"
  local out="$OUTDIR/result_${mech}.txt"

  cat > "$INITFILE" << LUA
vim.env.JEV_EXPERIMENT_MECHANISM = "$mech"
vim.env.JEV_EXPERIMENT_OUT = "$out"
vim.opt.runtimepath:prepend("$REPO_ROOT")
dofile("$REPO_ROOT/tests/experiment_auto_trigger.lua")
LUA

  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -f "$out"

  tmux new-session -d -s "$SESSION" -x 120 -y 30 "nvim -u '$INITFILE'"
  sleep 3

  # Real user typing: three keystrokes, spaced out. A missing pane means nvim
  # already exited, which is itself a result worth recording.
  tmux send-keys -t "$SESSION" "g" 2>/dev/null || true
  sleep 0.25
  tmux send-keys -t "$SESSION" "r" 2>/dev/null || true
  sleep 0.25
  tmux send-keys -t "$SESSION" "e" 2>/dev/null || true

  # Wait for the experiment to finish measuring and quit.
  local waited=0
  while [ ! -s "$out" ] && [ "$waited" -lt 70 ]; do
    sleep 0.5
    waited=$((waited + 1))
  done

  if [ ! -s "$out" ]; then
    echo "mechanism=$mech ERROR: no result after $waited half-seconds"
  fi
}

field() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

echo "======================================================================"
echo " Task 5.2: auto-trigger mechanism comparison"
echo "======================================================================"
echo

NAMES_1="1. complete() from InsertCharPre"
NAMES_2="2. feedkeys() from InsertCharPre"
NAMES_3="3. feedkeys() from TextChangedI"
NAMES_4="4. nvim_input() from TextChangedI"
NAMES_5="5. complete() from TextChangedI (no completefunc)"

for mech in 1 2 3 4 5; do
  echo "running mechanism $mech..."
  run_mechanism "$mech"
done

echo
echo "======================================================================"
echo " Comparison"
echo "======================================================================"
printf '%-44s %-7s %-8s %-14s %-8s\n' "mechanism" "menu?" "text_ok" "via_completefunc" "items"
printf '%-44s %-7s %-8s %-14s %-8s\n' "--------------------------------------------" "------" "-------" "----------------" "-----"

# A mechanism only qualifies for the 2-pass architecture if it opens a menu AND
# the menu came from the plugin's completefunc. A direct complete() call can
# open a menu but bypasses the fuzzy -> rank -> update pipeline entirely.
QUALIFYING=""
for mech in 1 2 3 4 5; do
  file="$OUTDIR/result_${mech}.txt"
  eval "name=\$NAMES_${mech}"
  menu="$(field "$file" menu_open)"
  intact="$(field "$file" text_intact)"
  via="$(field "$file" uses_completefunc)"
  items="$(field "$file" menu_items)"
  [ -z "$items" ] && items="<none>"
  printf '%-44s %-7s %-8s %-14s %-8s\n' "$name" "${menu:-?}" "${intact:-?}" "${via:-?}" "$items"

  if [ "$menu" = "true" ] && [ "$via" = "true" ] && [ -z "$QUALIFYING" ]; then
    QUALIFYING="$name"
  fi
done
echo

for mech in 1 2 3 4 5; do
  echo "--- mechanism $mech detail ---"
  cat "$OUTDIR/result_${mech}.txt" 2>/dev/null || echo "(no result)"
  echo
done

if [ -n "$QUALIFYING" ]; then
  echo "VERDICT: first mechanism that opens a menu AND goes through the completefunc = $QUALIFYING"
  exit 0
fi

echo "VERDICT: NO mechanism opened the popup."
echo "Per the Phase 5 prompt, stop here and report rather than inventing a workaround."
exit 1
