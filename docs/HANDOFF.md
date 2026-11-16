# Usage Meter - handoff

Public repo (`github.com/gtmn/claude-usage-meter`): keep employer and client names out of commits, docs and
screenshots. `README.md` is the user-facing reference (data sources, install, build, tests, layout); this file
adds state, decisions and maintainer notes.

## What this is
macOS menu bar app (Swift, SwiftUI `MenuBarExtra`, Swift Charts, macOS 14+) plus a `claude-usage` CLI that
show Claude usage: 5h/7d limits on Pro/Max, monthly $ budget with pace marker and projection on
Enterprise/Team seats, and a history graph. Built with `swiftc` (no Xcode project), distributed through the
user's Homebrew tap `gtmn/tap`.

## Current state (2026-11-16)
- Latest release **v0.1.9** (`4e4ba1d`), tags `v0.1.0`..`v0.1.9` on GitHub. v0.1.9 is the first with a GitHub
  release (pre-built universal zips, made by `.github/workflows/release.yml` on the tag); the tap formula
  points to it. On main since then, unreleased: `% / Amount` for the budget in the menu
  bar; Pro/Max extra usage as an optional `$` item beside the 5h/7d one and as its own graph (recorded only,
  never estimated from logs: on Pro/Max most activity is covered by the plan); the `panel` / `settings` /
  `extra` preview modes; settings screenshots in the README. The Pro/Max extra-usage parts are checked only
  with sample data (this account is Enterprise).
- Installed: Homebrew `claude-usage-meter 0.1.9`, run by `brew services`
  (`~/Library/LaunchAgents/sh.brew.claude-usage-meter.plist`). The old `~/Applications/UsageMeter.app` is in
  the Trash and its leftover login item was removed (2026-11-15).
- App data: `~/Library/Application Support/UsageMeter/history.json` (recorded history since 2026-11-10 19:08)
  and `last-usage.json` (saved numbers). Log: `~/Library/Logs/UsageMeter.log` (did not exist yet on 2026-11-15 23:15).
- Status line: `~/.claude/statusline-snapshot.sh` (identical copy of the repo file) is set as `statusLine` in the
  dotfiles' `config/packages/claude/.claude/settings.json` (committed). `~/.claude/usage-snapshot.json` has never
  been written: the status line only runs in terminal Claude Code, not desktop sessions, so "(assumed)" can still
  show until the app confirms a reset itself (first chance 2026-12-01 00:00 UTC).

## Open / Next 3 steps
1. **Verify the login renewal**: after Claude Code's login lapses with no session running, check
   `~/Library/Logs/UsageMeter.log` for "login renewed". Unverified through the app so far (manual
   `claude mcp list` test on 2026-11-15 worked; the 2026-11-13 check of the old `auth status` nudge could not read the log).
2. **Before 2026-12-07** (Claude Code refresh token expiry): decide on a "Sign in again" button (`claude auth login`).
Other ideas offered, not requested: dark-mode contrast of the lighter (estimated) line; ClaudeUsageBar features
(notifications, reset countdowns, service status, global shortcut); hide numbers while on pace (its PR #124).

## Key decisions and why
- **Token via `/usr/bin/security`**, not `SecItemCopyMatching`: Claude Code writes the Keychain item with the
  `security` CLI, so reads through it need no dialog; direct reads prompted after every rebuild and token refresh.
  Touch ID ("biometric proxy") cannot replace that dialog.
- **Never refresh the OAuth token** (would rotate Claude Code's refresh token and sign it out). When expired, run
  `claude mcp list` (no model call, free) at most every 30 min from an empty folder. Supersedes `claude auth status`
  (does not renew) and `claude -p` (costs usage).
- **Budget reset = 00:00 UTC on the 1st** (same as Claude's own UI, which computes it client-side). A drop within
  20 min of that is remembered as confirmation and removes "(assumed)".
- **Estimates from Claude Code logs** (`~/.claude/projects/**/*.jsonl`, deduped by message id + requestId, list
  prices) fill unrecorded stretches, scaled to the real totals at both ends of a gap. Drawing rule (user, final):
  everything the app didn't record is lighter; hover says "no activity" only where logs show none, "(estimated)"
  where spending was placed; a gap with equal amounts on both sides stays solid.
- **Early projection** uses last period's pace until 15% of the period, then the current pace.
- Claude's daily spend chart endpoint (`claude.ai/api/organizations/{org}/usage/spend`) rejects OAuth tokens and is
  behind Cloudflare: not used; do not try to bypass the bot check.
- **Homebrew builds from source** (no quarantine/notarization); version via `USAGE_METER_VERSION`; `brew services`
  replaces the app's own Open-at-login switch (hidden in Homebrew copies).
- **Tap split**: public `gtmn/tap` (repo `gtmn/homebrew-tap`, fresh history, only this app) and private
  `gtmn/tap-private`. Each has its own weekly livecheck workflow (GitHub Actions, Linux).

## Rules & preferences
- Commit as `gtmn <3950572+gtmn@users.noreply.github.com>`; branch first, then fast-forward merge locally (sole
  maintainer); push over SSH. Don't change `gh` auth (the gh login here is a different account).
- Never print or log the OAuth token; no personal data in external requests.
- Don't commit in the dotfiles repo from this project.
- Swift gotchas: avoid `Date >=`/`<=` (with Xcode 27.2 they compile to Foundation symbols macOS lacks and crash; `test.sh` checks; use `isAtOrAfter`/`isAtOrBefore`);
  use `RectangleMark` for x+y ranges; render previews with `--render-preview` (no Keychain, sample data); never
  commit `live` renders. Renders take their settings from the arguments (throwaway store), never the saved
  ones; preview/sample models never fetch (`refresh()` is guarded).
- Develop with `MenuBar/dev.sh` (stops the Homebrew service, runs the checkout build, restarts the service).

## Where things are
Code layout: see README "Layout". Release flow: annotated tag `vX.Y.Z` ("Usage Meter X.Y.Z"), push it (the workflow
publishes the GitHub release with the zips) -> sha256 of GitHub's tag tarball -> update
`Formula/claude-usage-meter.rb` in `gtmn/homebrew-tap` (local tap checkout under
`$(brew --repository)/Library/Taps/gtmn/homebrew-tap`, commit "claude-usage-meter X.Y.Z") -> `brew upgrade`,
`brew test`, `brew services restart`. Other Macs need `brew update` first if Homebrew auto-updated in the
last 24 h. The download is ad-hoc signed only (Gatekeeper "Open Anyway"); notarizing needs a Developer ID.

## Restore on a new Mac
1. Xcode command line tools; `brew trust gtmn/tap` (Homebrew 7 needs it for third-party taps), then
   `brew install gtmn/tap/claude-usage-meter && brew services start claude-usage-meter`.
2. Sign in to Claude Code (`claude`); the app reads its login without a Keychain dialog.
3. Status line: `cp statusline-snapshot.sh ~/.claude/` (the dotfiles carry the `statusLine` setting, not the script).
4. Optional: copy `~/Library/Application Support/UsageMeter/history.json` from backup to keep recorded history
   (otherwise the graph re-estimates from local Claude Code logs, which are also lost on a wipe).
5. For development: `git clone git@github.com:gtmn/claude-usage-meter.git`, `./test.sh`, `MenuBar/build.sh`.
Not captured anywhere yet: the dotfiles `Brewfile` has neither the `gtmn/tap` taps nor `claude-usage-meter`.

## Open questions
- Add `gtmn/tap` + `claude-usage-meter` (and `brew services`) to the dotfiles Brewfile, and ship
  `statusline-snapshot.sh` via dotfiles or the formula's `share/` copy?
- Back up `history.json`?
- Build the "Sign in again" button before 7 Dec?

## Sources
- "claude-usage-meter installation", app session `local_ac7c0279-c015-4e75-a2cd-f32f7d1dbe65`, 2026-11-10 to 2026-11-15.
- "Usage Meter: check the login nudge log", app session `local_7795c439-2ccc-49cb-99a0-80e5b0d1e71d`, 2026-11-13.
