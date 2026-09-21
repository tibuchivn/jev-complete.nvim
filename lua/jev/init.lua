-- lua/jev/init.lua
-- Entry point for jev-complete.nvim: default config, setup(), debug logger.

local M = {}

-- Default configuration; overridable through setup().
M.config = {
  enabled = true,
  confidence_threshold = 0.7, -- threshold for Jev to override fuzzy order
  max_candidates = 30,        -- max candidates sent to Jev
  api_endpoint = "https://api.typesafe.ai/v1/systemone",
  model = "jev-latest",
  debug = false,              -- enable debug logging

  min_word_length = 3,        -- words shorter than this are dropped from buffer words
  max_extract_words = 20000,  -- max unique words extracted from a buffer; Phase 4 measured an
                              -- uncapped pass over 5000 words at 9ms, so 20000 is ~36ms

  jev_question_format = "noul", -- "noul" | "choice" | "score": how candidates are asked about
  jev_timeout_ms = 3000,        -- raised from 500ms: Phase 3 measured real Jev latency at 0.5-1.5s
  debounce_ms = 300,            -- delay before firing a Jev call (manual trigger)
  auto_debounce_ms = 500,       -- delay before an auto-triggered Jev call; longer than
                                -- debounce_ms so typing does not spam the API
  max_context_tokens = 28000,   -- estimated token ceiling for the sent context
  context_fallback_lines = 200, -- lines around the cursor used when the buffer is too large

  disabled_filetypes = {},      -- filetypes that never get the completefunc
  auto_trigger = false,         -- fire completion automatically while typing (opt-in)
  debug_guards = false,         -- log which guard rejected a re-trigger (independent of debug)
  manage_completeopt = true,    -- add buffer-local noselect so the menu can be rebuilt
  menu_update_mode = "auto",   -- "feedkeys" | "inplace" | "auto": how the ranked menu replaces the fuzzy one
}

local VALID_QUESTION_FORMATS = {
  noul = true,
  choice = true,
  score = true,
}

-- Add noselect buffer-locally so the popup does not auto-select its first
-- entry. The completion menu itself bumps changedtick and selects index 0 as
-- soon as it opens, which would make the re-trigger guards reject every update.
-- completeopt is global-local: reading it with only { buf = N } yields "" when
-- no buffer-local value exists, so fall back to the global value to avoid
-- discarding flags such as menu/popup.
local function ensure_noselect(bufnr)
  local effective = vim.api.nvim_get_option_value("completeopt", { buf = bufnr, scope = "local" })
  if effective == "" then
    effective = vim.api.nvim_get_option_value("completeopt", { scope = "global" })
  end

  local parts = vim.split(effective, ",", { trimempty = true })
  for _, part in ipairs(parts) do
    if part == "noselect" then
      return
    end
  end

  parts[#parts + 1] = "noselect"
  vim.api.nvim_set_option_value("completeopt", table.concat(parts, ","), { buf = bufnr })
end

-- Attach the completefunc to buffers as they get a filetype, skipping any
-- filetype listed in disabled_filetypes.
local function register_autocmds()
  local augroup = vim.api.nvim_create_augroup("JevComplete", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = augroup,
    callback = function(args)
      local filetype = vim.bo.filetype
      for _, disabled in ipairs(M.config.disabled_filetypes) do
        if filetype == disabled then
          return
        end
      end

      vim.opt_local.completefunc = "v:lua.JevComplete"

      if M.config.manage_completeopt then
        ensure_noselect(args.buf)
      end
    end,
  })

  -- Auto-trigger is armed per typed character. InsertCharPre is used rather
  -- than TextChangedI because TextChangedI also fires when insert mode is
  -- entered, with nothing typed, and because pasting through the terminal
  -- produces one TextChangedI for the whole paste rather than per-character
  -- events that the debounce can coalesce.
  vim.api.nvim_create_autocmd("InsertCharPre", {
    group = augroup,
    callback = function(args)
      if not M.config.auto_trigger then
        return
      end

      -- Only word characters are interesting; a space or punctuation ends the
      -- word being typed, so a trigger there would be noise.
      if not vim.v.char:match("[%w_]") then
        require("jev.complete").cancel_auto()
        return
      end

      require("jev.complete")._schedule_auto_trigger()
    end,
  })
end

-- User-facing setup.
-- Example: require('jev').setup({ confidence_threshold = 0.8 })
function M.setup(user_config)
  M.config = vim.tbl_deep_extend("force", M.config, user_config or {})

  if not VALID_QUESTION_FORMATS[M.config.jev_question_format] then
    vim.notify(
      string.format(
        "[jev-complete] Invalid jev_question_format %q, falling back to 'noul'.",
        tostring(M.config.jev_question_format)
      ),
      vim.log.levels.WARN
    )
    M.config.jev_question_format = "noul"
  end

  -- Validate the API key; warns once and never crashes when missing.
  require("jev.config").validate()

  -- Load the completion module so it publishes the global that the
  -- completefunc string ("v:lua.JevComplete") resolves against. Without this
  -- the global is still nil the first time completion runs.
  require("jev.complete")

  register_autocmds()
  return M.config
end

-- Debug logger; prints only when config.debug is true.
function M.log(msg)
  if M.config.debug then
    vim.notify("[jev-complete] " .. msg, vim.log.levels.INFO)
  end
end

-- Guard logger; independent of config.debug so guard rejections can be
-- inspected on their own.
function M.log_guard(msg)
  if M.config.debug_guards then
    vim.notify("[jev-complete] " .. msg, vim.log.levels.INFO)
  end
end

return M
