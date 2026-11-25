# Backlog

## Next

1. **"Sign in again" button** (runs `claude auth login`): decide before 2026-12-07, when Claude Code's
   refresh token here expires. Options and a recommendation: [SIGN-IN-AGAIN.md](SIGN-IN-AGAIN.md).
2. **Test the Update button's restart with 0.1.14 → 0.1.15.** 0.1.12 → 0.1.13 installed fine (2026-11-21,
   "brew upgrade to 0.1.13 exited with 0") but the new copy didn't start: `launchctl kickstart` kept the old
   code signature (see DECISIONS, Distribution). Fixed with a detached `brew services restart`, which ships in
   0.1.14; the update *to* 0.1.14 still runs 0.1.13's restart, so run `brew services restart
   claude-usage-meter` after it. On the next one, check the log for "brew services restart exited with 0"
   and that the app comes back by itself.
3. **Test the downloaded copy's Update** (still untested): unpack an older release zip into a scratch folder,
   open that copy, click Update, and check that it replaces itself and reopens as the new version. Also check
   whether its Open at login item still works after the swap (macOS may have recorded the old signature
   there too).

## Ideas (not decided)

- **The same subscription on several Macs.** Each Mac records the same account-wide curve, but only while it
  runs; merged, they'd give the whole curve. One history file per Mac in iCloud Drive (`history-<Mac>.json`:
  each Mac writes only its own, so no sync conflicts); the app reads all of them and merges by time (one point
  per window per 10 minutes, as now). Only worth it once the curve is watched on more than one Mac.
- From ClaudeUsageBar, another menu bar app: notifications, reset countdowns, service status, a global
  shortcut, and hiding the numbers while on pace (its PR #124).
- Developer ID signing and notarization for the download (needs a paid Apple developer account).
- Bump the tap formula from the release workflow (needs a token with write access to the tap as a secret).
  It would also close the gap between a release going out and Homebrew copies hearing about it.

## Done

- **Dark-mode contrast of the estimated line** (2026-11-25): a washed-out slate instead of blue at 45%,
  3.1:1 against the background (was 1.9:1). Light mode unchanged (1.8:1), as is the fainter gap line
  (0.25, 1.4:1 in both modes).
- **The settings are open on first start** (closed with the gear, and remembered). A copy that never
  touched the gear also opens them once after the update, since "not set" now means open.
- **Last period's pace no longer names the reset date** ("At last month's pace: about $1,990 by the reset"),
  like the other outlooks: the reset time has its own line.
- **The app renews Claude Code's login** (confirmed 2026-11-17). With Claude Code and the Claude app quit
  overnight, `~/Library/Logs/UsageMeter.log` showed two renewals (16 Nov 19:31, 17 Nov 04:40), each after the
  login had expired; `claude mcp list` exited with 0 and the login was renewed for about 8 hours.
  If it ever fails: the log file is only written when the app tries a renewal, and the app's other messages
  go to the system log, which Claude sessions can't read. Run this in your own Terminal:
  `/usr/bin/log show --predicate 'process == "UsageMeter"' --last 1d`.

## Not checked yet

- Pro/Max extra usage (menu bar item and graph): checked only with sample data so far.
- Whether the desktop app's Code tab renews Claude Code's login itself (README says it doesn't seem to).
