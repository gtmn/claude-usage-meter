# Backlog

## Next

1. **Check that the app renews Claude Code's login.** After the login lapses with no Claude Code session
   running, look for "login renewed" in `~/Library/Logs/UsageMeter.log`. Not yet seen in the app: a manual
   `claude mcp list` renewed it (2026-11-15), but so far a running Claude Code session always renewed it first.
   - Cleanest test: a night with Claude Code and the Claude app fully quit.
   - The log file is only written once the app tries a renewal; if it doesn't exist, no attempt was made.
   - The app's other messages go to the system log. Claude sessions can't read that, so run this in your
     own Terminal: `/usr/bin/log show --predicate 'process == "UsageMeter"' --last 1d`.
2. **"Sign in again" button** (runs `claude auth login`): decide before 2026-12-07, when Claude Code's
   refresh token here expires.

## Ideas (not decided)

- **The same subscription on several Macs.** Each Mac records the same account-wide curve, but only while it
  runs; merged, they'd give the whole curve. One history file per Mac in iCloud Drive (`history-<Mac>.json`:
  each Mac writes only its own, so no sync conflicts); the app reads all of them and merges by time (one point
  per window per 10 minutes, as now). Only worth it once the curve is watched on more than one Mac.
- Dark-mode contrast of the lighter (estimated) line.
- From ClaudeUsageBar, another menu bar app: notifications, reset countdowns, service status, a global
  shortcut, and hiding the numbers while on pace (its PR #124).
- Developer ID signing and notarization for the download (needs a paid Apple developer account).
- Bump the tap formula from the release workflow (needs a token with write access to the tap as a secret).

## Not checked with real data

- Pro/Max extra usage (menu bar item and graph): checked only with sample data so far.
