# Backlog

## Next

1. **"Sign in again" button** (runs `claude auth login`): decide before 2026-12-07, when Claude Code's
   refresh token here expires.
2. **Release 0.1.13 and test the Update button** (the first real run of both install paths). `main` has the
   formula-based check (a164d60) but no release yet.
   - Order matters once more: the installed 0.1.12 still asks GitHub's releases, not the tap, so it offers
     0.1.13 as soon as the release is out. Clicking Update before the tap is bumped ends in "Homebrew doesn't
     have 0.1.13 yet". So: release, bump the tap, then click Update.
   - Homebrew copy: click Update instead of README's step 4. Check `~/Library/Logs/UsageMeter.log` for
     "brew upgrade to 0.1.13 exited with 0" and that the app comes back (through `brew services`) as 0.1.13.
   - Downloaded copy: unpack the 0.1.12 zip into a scratch folder, open that copy, click Update, and check
     that it replaces itself and reopens as 0.1.13.

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
  It would also close the gap between a release going out and Homebrew copies hearing about it.
- Last month's pace still names the date ("At last month's pace: about $1,990 by the 1 Jan reset"), unlike
  the other outlooks, which dropped it.
- Show the settings on first start (they're closed until the gear is clicked).

## Done

- **The app renews Claude Code's login** (confirmed 2026-11-17). With Claude Code and the Claude app quit
  overnight, `~/Library/Logs/UsageMeter.log` showed two renewals (16 Nov 19:31, 17 Nov 04:40), each after the
  login had expired; `claude mcp list` exited with 0 and the login was renewed for about 8 hours.
  If it ever fails: the log file is only written when the app tries a renewal, and the app's other messages
  go to the system log, which Claude sessions can't read. Run this in your own Terminal:
  `/usr/bin/log show --predicate 'process == "UsageMeter"' --last 1d`.

## Not checked yet

- Pro/Max extra usage (menu bar item and graph): checked only with sample data so far.
- Whether the desktop app's Code tab renews Claude Code's login itself (README says it doesn't seem to).
