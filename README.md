# jev-complete.nvim

Semantic code completion for Neovim that uses Jev (TypeSafe AI) as a ranking
oracle. Candidates come from the current buffer and appear instantly as fuzzy
matches; Jev then re-ranks them against the surrounding code and the menu is
rebuilt in the better order.

Jev ranks. It does not generate code.

## Requirements

- Neovim >= 0.12
- A TypeSafe API key
- `curl` in `PATH`

## Installation

### lazy.nvim

```lua
{
  "yourname/jev-complete.nvim",
  config = function()
    require("jev").setup()
  end,
}
```

### Manual

Clone the repository, add it to `runtimepath`, and call `setup()`:

```lua
vim.opt.runtimepath:prepend("/path/to/jev-complete.nvim")
require("jev").setup()
```

## Setup API key

```bash
export JEV_API_KEY="your-key-here"
```

Add that line to your shell profile to make it persistent. The legacy variable
`TYPESAFE_API_KEY` still works, and `vim.g.jev_api_key` takes precedence over
both:

```lua
vim.g.jev_api_key = "your-key-here"
```

Without a key the plugin still works and emits a single warning: completion
falls back to fuzzy matching only.

## Usage

1. Enter insert mode in any buffer with a filetype.
2. Type at least 3 characters of a word that appears somewhere in the buffer.
3. Press `<C-x><C-u>` to trigger completion.
4. Fuzzy candidates appear immediately.
5. After roughly a second, the menu is rebuilt in Jev's order.

Accept an entry with `<C-y>` or by pressing `<C-n>`/`<C-p>` to pick one.

## Configuration

```lua
require("jev").setup({
  enabled = true,                  -- master switch
  confidence_threshold = 0.7,      -- Jev must exceed this to reorder
  max_candidates = 30,             -- candidates sent to Jev
  api_endpoint = "https://api.typesafe.ai/v1/systemone",
  model = "jev-latest",
  debug = false,                   -- verbose logging
  debug_guards = false,            -- log why a menu update was rejected

  min_word_length = 3,             -- shorter words are not candidates
  max_extract_words = 20000,       -- cap on unique words taken from a buffer

  jev_question_format = "noul",    -- "noul" | "choice" | "score"
  jev_timeout_ms = 3000,           -- per-request timeout
  debounce_ms = 300,               -- delay before asking Jev (manual trigger)
  auto_debounce_ms = 500,          -- delay before asking Jev (auto trigger)
  max_context_tokens = 28000,      -- context ceiling
  context_fallback_lines = 200,    -- lines around the cursor when over the ceiling

  disabled_filetypes = {},         -- filetypes that never get the completefunc
  auto_trigger = false,            -- complete automatically while typing (opt-in)
  manage_completeopt = true,       -- add buffer-local 'noselect'
  menu_update_mode = "auto",       -- "feedkeys" | "inplace" | "auto"
})
```

### Notable options

- `confidence_threshold` - Jev only reorders when its probability for a
  candidate is at least this high. Below it, the fuzzy order is kept.
- `jev_question_format` - how candidates are presented to Jev. `noul` asks a
  yes/no per candidate, `choice` asks it to pick the best, `score` asks for a
  relevance level. `noul` is the default and the cheapest.
- `menu_update_mode` - how the ranked list replaces the fuzzy one. `auto` tries
  an in-place update and falls back to re-triggering completion; `inplace` and
  `feedkeys` force one strategy. See `.omo/PHASE4_FINDINGS.md` for measurements.
- `max_extract_words` - on very large buffers extraction stops at this cap, so
  words appearing after the first N unique words are not offered as candidates.
  Extraction over 5000 words measured 9ms, so the default of 20000 is cheap.
- `auto_trigger` / `auto_debounce_ms` - see "Auto-trigger" below.
- `disabled_filetypes` - e.g. `{ "TelescopePrompt", "NvimTree", "markdown" }`.

## Auto-trigger

By default completion is manual: you press `<C-x><C-u>`. To have it fire while
you type, opt in:

```lua
require("jev").setup({
  auto_trigger = true,
  auto_debounce_ms = 500,  -- how long to wait after your last keystroke
})
```

Auto-trigger fires only when all of these hold:

- you are in insert mode
- the completion menu is not already open
- the word before the cursor is at least `min_word_length` characters
- the filetype is not in `disabled_filetypes`
- the buffer is not readonly

It waits `auto_debounce_ms` after your last keystroke before calling Jev, which
keeps the API from being hit on every character. A word-ending character (space,
punctuation) cancels a pending trigger, and pressing `<C-x><C-u>` cancels it and
runs the manual flow instead, so the two never double-fire.

**Auto-trigger increases API calls significantly.** Typing a whole word means
one request once you pause, and every pause is a request, so monitor your usage.
The debounce is deliberately longer than the manual one for this reason.

## Architecture

```
<C-x><C-u>
    |
    v
pass 1: buffer words -> fuzzy filter -> menu appears immediately
    |   (debounce)
    v
request: context + candidates -> Jev
    |
    v
response: parse -> rank
    |
    v
guards: menu visible? cursor unmoved? prefix unchanged?
    |
    v
menu rebuilt in Jev's order
```

The completefunc cannot return asynchronously, so the fuzzy list is returned
immediately and the ranked list replaces it once Jev answers. Two strategies are
available for that replacement (`menu_update_mode`); both are verified to
reorder without flicker or text corruption, and `auto` picks the in-place update
when it can confirm the change and re-triggers completion otherwise.

Three guards protect the update: the popup must still be visible, the cursor
must not have moved, and the typed prefix must be unchanged. Guards for
"an entry is selected" and "the buffer changed" are deliberately absent: the
completion menu itself selects its first entry and changes the buffer's
`changedtick` as soon as it opens, so those two can never hold during a real
completion.

## Troubleshooting

- **No completion menu at all** - check that the filetype is not in
  `disabled_filetypes`, and that `:set completefunc?` reports `v:lua.JevComplete`.
- **Menu appears but never reorders** - set `debug_guards = true`; the log names
  the guard that rejected the update. Also check the API key is visible to
  Neovim (`:lua print(require('jev.config').get_api_key() ~= nil)`).
- **Requests time out** - Jev latency is commonly 0.5-1.5s; raise
  `jev_timeout_ms` if you see timeouts, and check `:messages`.
- **Nothing in `:messages`** - set `debug = true` for verbose logging.
- **Slow on a huge buffer** - tune `max_extract_words` and
  `context_fallback_lines`; `tests/benchmark_large_buffer.lua` reports timings.

## Testing

```bash
# unit suites (no key, no UI)
nvim --headless -u NONE --cmd "set rtp^=$(pwd)" -c "luafile tests/test_phase3.lua" -c "qa!"

# integration (needs $JEV_API_KEY; skips otherwise)
JEV_API_KEY=... nvim --headless -u NONE --cmd "set rtp^=$(pwd)" \
  -c "luafile tests/integration_phase3.lua" -c "qa!"

# real-UI checks (need tmux)
./tests/experiment_inplace_vs_feedkeys.sh
./tests/tmux_qa_phase3.sh
```

## Security

API keys are read from the environment and never logged. See
[SECURITY.md](./SECURITY.md) for the Phase 3 key-exposure incident and the
practices adopted after it.

## License

MIT - see [LICENSE](./LICENSE).
