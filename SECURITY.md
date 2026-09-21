# Security Notes

## Incident: API key exposure (Phase 3)

### What happened

While authoring the Phase 3 work, a live TypeSafe API key was written into a
project planning document in plaintext, in four places. That file was committed
before the exposure was noticed.

Timeline:

1. The key was added to the planning document while the Phase 3 work was being
   prepared.
2. The file was committed (`5124bcd`) together with the Phase 3 work, before the
   updated prompt content had been reviewed.
3. The key was scrubbed from the file and replaced with `<REDACTED-API-KEY>`.
4. The verification greps were rewritten to a generic pattern
   (`apikey_[0-9a-f]{20,}`), because the original greps contained the literal
   key and so had themselves become a copy of the secret.
5. The commit was replaced (`git reset --soft` + recommit), then the old objects
   were pruned with `git reflog expire --expire=now --all` and
   `git gc --prune=now`.

### Impact

- The key sat on disk in plaintext and inside one commit object.
- No git remote was configured, so nothing was pushed anywhere.
- Pruning removed the reachable copy, but **cannot un-send** a secret that has
  been written to disk. Anyone with access to the machine or to a filesystem
  snapshot taken during the window could have read it.

### Remediation

- The exposed key was revoked and rotated immediately.
- The replacement is stored only as `$JEV_API_KEY` in the shell profile.
- No key material exists in any repository file or in git history.

### Lessons learned

- Never paste live secrets into prompt files, tests, or docs, even as an
  "example". Use `<YOUR_API_KEY>`.
- A verification grep must use a **generic pattern**. A grep containing the
  literal secret is a copy of the secret.
- Secret scanning has to run **before** a commit, not after.
- Review prompt and documentation files explicitly before staging: they are
  written by a different process than the code and are easy to gloss over.

### Practices going forward

- API keys are read from the environment only: `$JEV_API_KEY` (current) and
  `$TYPESAFE_API_KEY` (legacy). `vim.g.jev_api_key` can override for interactive
  use.
- Only the key's **source** is ever logged, never its value.
- `.gitignore` ignores `.env`, `*.key`, and `secrets/`.
- Integration tests read the key from the environment and skip when it is
  absent. This document and every other file in the repository use placeholders.

### Reporting

Treat any exposed credential as compromised: rotate it first, then clean up the
repository. Cleaning history is secondary to rotation, because a rotated key is
harmless.
