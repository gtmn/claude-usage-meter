# Usage Meter

A small macOS menu bar app that shows your Claude subscription usage (the 5-hour
session window and the weekly limit) and tells you in plain words whether you'll
run out before the reset:

> **7d 60%** — Runs out Wednesday night, 8 h before Thursday's reset

No browser cookie to paste. It reuses the login that [Claude Code](https://claude.com/claude-code)
already keeps on your Mac.

> **Unofficial.** Not affiliated with or endorsed by Anthropic. It relies on an
> undocumented endpoint that may change or stop working at any time.

## What it shows

- **Menu bar:** two mini bars, `5h` and `7d`, with percentages. A number turns
  orange when that limit is nearly full (90%+) or projected to run out before it resets.
- **Popup**, per limit:
  - usage bar with a pace marker (how much of the window has passed)
  - an outlook line, e.g. *Lasts until the reset at 14:00 — on track for about 45%*
  - reset time
- Refreshes every 5 minutes, on wake, when the network returns, and when you open the popup.
  If a fetch fails, the last numbers stay and a short note explains why (e.g. *Offline*).

Projections are a straight-line estimate from your average rate so far in the
window, and are held back for the first 15% of a window (45 minutes of the
5-hour window, about a day of the week), where they'd be too jumpy.

## How it gets the data

1. **Claude Code login (primary).** Reads Claude Code's OAuth token from the macOS
   Keychain item `Claude Code-credentials` and calls
   `GET https://api.anthropic.com/api/oauth/usage` (the call behind Claude Code's `/status`).
   - The token is read on every fetch, never stored, logged or sent anywhere else.
   - It is **never refreshed** by this app, because that would rotate Claude Code's refresh token
     and could sign Claude Code out. If it has expired, run `claude` in Terminal once.
   - macOS asks once whether the app may read that Keychain item: choose **Always Allow**.
     Ad-hoc signed builds count as a new app after every rebuild, so it asks again then.
2. **Claude Code status line (fallback).** If the token can't be used, the app reads
   `~/.claude/usage-snapshot.json`, written by [`statusline-snapshot.sh`](statusline-snapshot.sh)
   from the documented `rate_limits` field Claude Code passes to status-line commands.

The app talks only to `api.anthropic.com`. No analytics, no update checks, no other servers.

## Requirements

- macOS 14 or later
- Xcode command line tools (`swiftc`)
- Claude Code, signed in with a Pro or Max subscription

## Build and run

```bash
cd MenuBar
./build.sh            # builds MenuBar/build/UsageMeter.app (ad-hoc signed, this Mac only)
./build.sh --install  # also copies it to ~/Applications and launches it
```

Enable **Open at login** in the popup after installing.

### Optional: status-line fallback

Copy the script and point Claude Code's status line at it in `~/.claude/settings.json`:

```bash
cp statusline-snapshot.sh ~/.claude/
```

```json
"statusLine": { "type": "command", "command": "~/.claude/statusline-snapshot.sh" }
```

Already using a status line? Keep it by setting `NEXT_STATUSLINE` to its command;
the script passes the same input on to it.

## Command-line reader

```bash
swiftc -O -o usage UsageReader.swift main.swift
./usage            # Claude Code login, falling back to the status-line file
./usage oauth      # Claude Code login only
./usage snapshot   # status-line file only
./usage raw        # raw JSON from the usage endpoint
```

## Tests

```bash
./test.sh
```

Prints the outlook wording for fixed scenarios (in UTC, so the output is the same
on any machine) and the short message for each kind of error.

## Layout

| Path | What |
|---|---|
| `UsageReader.swift` | Reads both sources, projections, plain-language wording |
| `MenuBar/` | The SwiftUI menu bar app |
| `main.swift` | Command-line reader |
| `statusline-snapshot.sh` | Claude Code status-line command for the fallback |
| `tests/` | Scenario checks |

## License

MIT, see [LICENSE](LICENSE).
