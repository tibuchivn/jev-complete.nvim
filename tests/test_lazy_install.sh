#!/bin/bash
# tests/test_lazy_install.sh
# Verifies the plugin loads when installed through a real plugin manager.
#
# This is the only place a plugin manager appears: lazy.nvim is cloned for the
# test only and is never a runtime dependency.
#
# Run:
#   ./tests/test_lazy_install.sh
#
# Skips with a clear message when there is no network to clone lazy.nvim.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR_TEST="$(mktemp -d)"
LAZY_PATH="$TMPDIR_TEST/data/lazy/lazy.nvim"
CONFIG_DIR="$TMPDIR_TEST/config"
SCRIPT="$TMPDIR_TEST/init.lua"
OUT="$TMPDIR_TEST/out.txt"

cleanup() {
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

if ! command -v nvim >/dev/null 2>&1; then
  echo "SKIP: nvim not available"
  exit 0
fi

# lazy.nvim needs network access on first clone.
if ! git ls-remote --exit-code https://github.com/folke/lazy.nvim.git >/dev/null 2>&1; then
  echo "SKIP: cannot reach github.com to clone lazy.nvim (offline?)"
  exit 0
fi

mkdir -p "$(dirname "$LAZY_PATH")" "$CONFIG_DIR"

echo "cloning lazy.nvim (test-only dependency)..."
if ! git clone --filter=blob:none --branch=stable \
  https://github.com/folke/lazy.nvim.git "$LAZY_PATH" >/dev/null 2>&1; then
  echo "SKIP: lazy.nvim clone failed (network?)"
  exit 0
fi

# Nothing here waits on an autocmd: headless nvim does not emit VeryLazy, so the
# checks run directly after setup() instead.
cat > "$SCRIPT" << EOF
local lazypath = "$LAZY_PATH"
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  spec = {
    {
      dir = "$REPO_ROOT",
      config = function()
        require("jev").setup({ debug = false })
      end,
    },
  },
  root = "$TMPDIR_TEST/data/lazy",
  lockfile = "$TMPDIR_TEST/lazy-lock.json",
})

local function check(label, cond, extra)
  if cond then
    print("PASS: " .. label)
  else
    print("FAIL: " .. label .. (extra and (" -- " .. tostring(extra)) or ""))
    vim.g.jev_lazy_test_failed = true
  end
end

local loaded = pcall(require, "jev")
check("require('jev') succeeds", loaded)
check("load guard set by plugin file", vim.g.loaded_jev_complete == true,
  tostring(vim.g.loaded_jev_complete))

local autocmds = vim.api.nvim_get_autocmds({ group = "JevComplete", event = "FileType" })
check("FileType autocmd registered by setup()", #autocmds > 0, #autocmds)

vim.bo.filetype = "lua"
vim.api.nvim_exec_autocmds("FileType", { buffer = 0, modeline = false })
check("completefunc installed for enabled filetype",
  vim.bo.completefunc == "v:lua.JevComplete", vim.bo.completefunc)

local co = vim.api.nvim_get_option_value("completeopt", { buf = 0 })
check("buffer-local noselect applied", co:find("noselect") ~= nil, co)

if vim.g.jev_lazy_test_failed then
  vim.cmd("cquit 1")
end

print("PASS: plugin loads and wires up correctly via lazy.nvim")
vim.cmd("qa!")
EOF

echo "running nvim with the lazy.nvim init..."

# Hard timeout: a plugin-manager bootstrap can block, and the test must never
# hang the suite.
set +e
XDG_DATA_HOME="$TMPDIR_TEST/data" \
XDG_CONFIG_HOME="$CONFIG_DIR" \
XDG_STATE_HOME="$TMPDIR_TEST/state" \
XDG_CACHE_HOME="$TMPDIR_TEST/cache" \
  timeout 120 nvim --headless -u "$SCRIPT" >"$OUT" 2>&1
NVIM_EXIT=$?
set -e

cat "$OUT"

if [ "$NVIM_EXIT" -eq 124 ]; then
  echo "FAIL: lazy.nvim install test timed out"
  exit 1
fi

if ! grep -q "PASS: plugin loads and wires up correctly via lazy.nvim" "$OUT"; then
  echo "FAIL: lazy.nvim install verification did not pass"
  exit 1
fi

exit 0
