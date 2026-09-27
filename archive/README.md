# archive/

Files that used to sit untracked at the repo root. They are kept for the record, not used by
anything: no script, target or workflow reads this directory.

It is `archive/` and not `docs/` on purpose — `docs/` is published by GitHub Pages
(jasonyeyuhe.github.io/Stride), and none of this is meant for the public site.

## 2026-04/

Working notes from the April 2026 review round (v1.0.x, before the v2 work that shipped as
1.2.0). Every item in them has since been fixed, superseded or re-audited — see
`AUDIT-2026-09-09.md` and the `RELEASE-*.md` records at the root for the current picture.
Read them as history, not as a to-do list.

| File | What it was |
|---|---|
| `gemini-review-todo.md` | The Gemini 2.5 Pro + Codex review of 2026-04-01, as a checklist. |
| `todo.md` | The same list after Claude validated it on 2026-04-01, with what was done ticked. |
| `CLAUDE_AUDIT_HANDOFF.md` | 2026-04-11 audit handoff: sync that did not propagate deletions or round-trip reminders/notes, widget un-check not tracked, legal pages 404 on the server, cold-start auth/sync race, thin CI. All of it was addressed by the v2 sync contract (1.2.0) and later releases. |
| `claude_fix_prompt.txt` | The prompt (in Chinese) that handed the audit above to an agent. |
| `upload.sh` | The v1.0.0 (build 7) upload script: archive, export with `ExportOptions.plist`, upload with `altool`. |
| `ExportOptions.plist` | The export options `upload.sh` used (`app-store-connect`, automatic signing). |

`upload.sh` and `ExportOptions.plist` are retired, not merely old: `scripts/build-appstore.sh`
writes its own export options per platform into `build/appstore/` on every run, exports, then
checks the Distribution-signed result with `scripts/verify_archive.sh --exported` before
anything is uploaded (the upload itself is an `xcodebuild -exportArchive` with an upload
destination, authenticated by the ASC API key). `upload.sh` did none of those checks, built
iOS only, hardcoded "v1.0.0 build 7", and uploaded with `altool` and an Apple ID password from
the keychain. Do not resurrect it; the release path is in the root `README.md`.

Removed rather than archived at the same time: an empty root `package-lock.json` (no
`package.json` beside it — the server's lives in `server/`). `.mcp.json`, a symlink to the
machine's own `~/.mcp.json`, is now in `.gitignore`.
