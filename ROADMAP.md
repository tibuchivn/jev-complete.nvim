# Roadmap

Features planned for future releases (post v1.0.0). Nothing here is committed
to a date.

## Planned

### Keymaps

A default keymap for the manual trigger, which is currently only `<C-x><C-u>`.
Candidates: `<C-Space>` or `<Tab>`. Any default would be opt-in, because both
keys are commonly taken.

### `:JevStatus` command

Display the current state in one place:

- pending Jev calls (`client.pending_count()`)
- cache statistics (`cache.stats()`)
- which source the API key came from
- recent errors

### `:checkhealth jev-complete`

Neovim health check integration:

- verify `curl` is available
- verify an API key is set
- verify connectivity to `api.typesafe.ai`
- report the resolved configuration

### LSP as a candidate source

Use LSP completion results alongside buffer words. Today candidates come only
from buffer words; tags were planned for Phase 2 but never implemented.

### Custom question templates

Let users define their own `questions` payload for Jev, beyond the three
built-in formats (`noul` / `choice` / `score`).

### Better response caching

Caching is currently keyed on `(bufnr, changedtick, prefix)` with a 5s TTL and
is discarded whenever the buffer changes. Future work: a persistent cache across
sessions, and a semantic cache keyed on the context rather than the exact buffer
state.

### Candidate extraction improvements

`max_extract_words` is a hard cap, so on very large buffers words appearing
after the first N unique words are not offered. A window around the cursor, or
ranking by proximity rather than insertion order, would remove that ceiling.

## Not Planned

- Telemetry or analytics. The plugin collects no user data.
- Non-Jev backends. It is Jev-specific by design.
