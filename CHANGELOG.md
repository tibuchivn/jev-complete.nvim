# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-09-21

First release.

### Added

- Semantic code completion that uses Jev (TypeSafe AI) as a ranking oracle:
  fuzzy candidates appear immediately, Jev ranks them against the surrounding
  code, and the menu is rebuilt in the better order.
- Two-pass architecture: fuzzy pass from the completefunc, asynchronous Jev
  request, then the menu is updated with the ranked order.
- `menu_update_mode` config: `"auto"` (default), `"inplace"`, `"feedkeys"`.
  `auto` attempts an in-place update, verifies it changed the menu, and falls
  back to re-triggering completion when it cannot confirm the change.
- Three guards before any menu update: popup visible, cursor unmoved, prefix
  unchanged.
- Three Jev question formats: `noul` (default), `choice`, `score`.
- Auto-trigger mode, opt-in via `auto_trigger = true`, with its own
  `auto_debounce_ms`.
- Multi-filetype support: Python, JavaScript and Ruby are covered by tests.
- Error taxonomy that distinguishes timeout, DNS failure, connection failure
  and other curl failures.
- Context builder: the whole buffer, or a window around the cursor when the
  buffer exceeds `max_context_tokens`.
- Buffer word extraction with case-insensitive deduplication and a minimum
  word length.
- Three test layers: unit (headless), integration (live Jev API), and real-UI
  E2E through tmux.
- `SECURITY.md` documenting the API key exposure incident and its remediation.

### Changed

- `jev_timeout_ms` default raised from 500ms to 3000ms, after measuring real
  Jev latency at 0.5-1.5s.
- `max_extract_words` default raised from 5000 to 20000. Extraction over 5000
  words measured 9ms, so the higher cap costs roughly 36ms.
- `.gitignore` pattern `tags` narrowed to `/tags` so that `doc/tags` ships with
  the repository and `:help` works for manual installs.

### Fixed

- Nine bugs found during Phase 3. The most consequential: the guards compared
  two different coordinate spaces and so rejected every real update, and
  re-filtering inside the async callback changed the candidate set instead of
  only reordering it.
- `filter_candidates` now preserves the `lower` field, closing a Phase 1 to
  Phase 2 interface gap that crashed question building.
- Guard prefix off-by-one in normal mode.
- `debug_guards` now logs independently of `debug`.
- `completeopt` handling no longer discards `menu`/`popup`: it is global-local,
  and reading it with only `{ buf = N }` returns `""` when unset.

### Security

- See `SECURITY.md` for the Phase 3 API key exposure incident: what happened,
  its impact, the remediation, and the practices adopted afterwards.

[1.0.0]: https://github.com/tibuchivn/jev-complete.nvim/releases/tag/v1.0.0
