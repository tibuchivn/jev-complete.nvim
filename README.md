# jev-complete.nvim

Neovim plugin providing code completion that uses Jev (TypeSafe AI) to rank suggestion candidates based on code context.

## Requirements

- Neovim >= 0.12
- A TypeSafe API key

## Installation

> Stub — installation instructions will be completed in Phase 4.

Example (lazy.nvim):

```lua
{
  "your-name/jev-complete.nvim",
  config = function()
    require("jev").setup()
  end,
}
```

## Configuration

```lua
require("jev").setup({
  enabled = true,
  confidence_threshold = 0.7, -- minimum Jev confidence to override fuzzy order
  max_candidates = 30,        -- max candidates sent to Jev
  api_endpoint = "https://api.typesafe.ai/v1/systemone",
  model = "jev-latest",
  debug = false,
})
```

The API key is read from `vim.g.jev_api_key` (highest priority) or the
`TYPESAFE_API_KEY` environment variable. You can also set it at runtime:

```lua
require("jev.config").set_api_key("...")
```

When no API key is available, the plugin falls back to plain fuzzy completion
and emits a single warning.

## Status

Under development, Phase 0.

## License

MIT
