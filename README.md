# Usage Meter

A small macOS menu bar app that shows your Claude subscription usage and tells you
in plain words whether you'll run out before the reset. It handles both kinds of plan:

- **Pro / Max:** the 5-hour session window and the weekly limit, in percent.
- **Enterprise / Team seats:** the monthly $ budget, in percent and in dollars.

<img src="docs/screenshots/hero.png" width="412" alt="The popup opened under the menu bar item: the item shows 5h 20% →35% and 7d 60% →105%; the popup has Session 5 h at 20%, on track for about 35%, Week all models at 60% in yellow, runs out Friday morning, a line graph of the week with a dashed projection to 100%, and the Menu bar item settings below, with Projection set to Beside">

*Sample numbers and a made-up history, rendered by the app itself.*

| Pro / Max | Enterprise / Team |
|---|---|
| <img src="docs/screenshots/popup-pro-max.png" width="356" alt="Popup: Session 5 h at 20%; Week all models at 60% in yellow, runs out 8 h before the weekly reset; below, a line graph of both this week with a dashed projection of the week to 100%"> | <img src="docs/screenshots/popup-enterprise.png" width="356" alt="Popup: Monthly budget at 21%, $412.80 used of $2,000.00, $1,587.20 left, on track for about $800 by the 1 Dec reset; below, a line graph of money spent this month with a dashed projection, the unrecorded part drawn lighter as estimated"> |
| <img src="docs/screenshots/popup-pro-max-extra.png" width="356" alt="Popup: Session and Week rows, then Extra usage at 25%, $12.40 used of $50.00, on track for about $16; the 5h/7d graph, and below it a graph of extra usage this month with a dashed projection to about $16"> | <img src="docs/screenshots/popup-enterprise-daily.png" width="356" alt="The same popup with the graph switched to Per day: a bar per UTC day, the unrecorded days' bars lighter as estimated"> |
| <img src="docs/screenshots/popup-pro-max-fable.png" width="356" alt="Popup: Session, Week all models and Week Fable at 35%; the week graph with a third, ochre line for Fable ending at Fable 35%"> | |

### Menu bar styles

Each one is a setting in the popup (see [Settings](#settings)), shown enlarged on a dark and a light menu bar.

| Bars | Compact | Mono | Alerts |
|---|---|---|---|
| <img src="docs/screenshots/menubar-pro-max.png" width="140" alt="Menu bar item with 5h and 7d bars at 20% (green, under pace) and 60% (yellow, ahead of pace), each with a pace tick, on a dark and a light menu bar"> | <img src="docs/screenshots/menubar-compact.png" width="110" alt="Compact style: two rings, the week outside in yellow and the session inside in green, with 5h 20% and 7d 60% beside them"> | <img src="docs/screenshots/menubar-mono.png" width="140" alt="Mono palette: the 5h and 7d bars filled in the text colour instead of green and yellow"> | <img src="docs/screenshots/menubar-alerts.png" width="140" alt="Alerts palette: the 5h bar in the text colour while on pace, the 7d bar yellow because it is ahead of pace"> |

| Projection beside | Projection instead | Only the 5 h limit |
|---|---|---|
| <img src="docs/screenshots/menubar-projection-beside.png" width="218" alt="The 5h and 7d bars with 20% →35% and 60% →105%: the number, then where it is heading at the reset"> | <img src="docs/screenshots/menubar-projection-instead.png" width="168" alt="The 5h and 7d bars with →35% and →105% in place of the numbers"> | <img src="docs/screenshots/menubar-only5h.png" width="140" alt="A single 5h bar at 20%"> |

| Budget | Budget amount | Budget, Compact, projection beside | Extra usage beside the limits |
|---|---|---|---|
| <img src="docs/screenshots/menubar-enterprise.png" width="130" alt="Menu bar item with a single green $ bar at 21% and a pace tick, on a dark and a light menu bar"> | <img src="docs/screenshots/menubar-enterprise-amount.png" width="120" alt="A budget bar with $412 beside it instead of 21%"> | <img src="docs/screenshots/menubar-projection.png" width="97" alt="Compact style on a budget: one ring, with $412 on top and →$530 below it, where the budget is heading at the reset"> | <img src="docs/screenshots/menubar-pro-max-extra.png" width="190" alt="The 5h and 7d bars, and beside them a $ bar with $12"> |

No browser cookie to paste. It reuses the login that [Claude Code](https://claude.com/claude-code)
already keeps on your Mac.

> **Unofficial.** Not affiliated with or endorsed by Anthropic. It relies on an
> undocumented endpoint that may change or stop working at any time.

## What it shows

- **Menu bar**, in one of two styles, switched under **Style** in the popup's settings (the gear button):
  - **Bars** (default): two mini bars, `5h` and `7d`, with percentages (or just one of them,
    see [Settings](#settings)), or a single `$` bar on an Enterprise/Team seat.
  - **Compact**: rings with their percentages beside them: the week outside and the 5h
    session inside (the week follows the weekly limit furthest ahead of pace), or one budget
    ring on an Enterprise/Team seat.

  Both use the same colours, as ClaudeUsageBar's pace icon: green on or under pace, yellow
  ahead of it, orange 15+ points ahead (about a day early in a week) or nearly full (90%+). Early
  in a window, where a few percent would look far ahead, it stays plain. Switch **Colour** to
  **Mono** for bars or rings in the menu bar's text colour, like the numbers, or to **Alerts** for
  the text colour while on or under pace and yellow or orange only once a limit is ahead or nearly full. On a $ budget,
  the number can be the share used (`21%`) or the money spent so far (`$306`). The popup's settings
  turn on or off the `5h`/`7d` **labels**, the **number**, a **pace tick** where usage
  would be if spread evenly over the window, and, once a limit is 15+ points ahead, the points
  ahead of pace (`+24`: % used minus % expected by now), the time left until it runs out
  at that pace (`1.5d left`), or how long before the reset that is (`3d early`). Times are rounded: half days from a day on (`1.5d`),
  whole hours below, and minutes under an hour for the 5h session only.
- **Popup**, per limit:
  - usage bar with a pace marker (how much of the window has passed)
  - for the $ budget: the amount used, the budget and what's left,
    e.g. *$412.80 used of $2,000.00 · $1,587.20 left*
  - an outlook line, e.g. *Lasts until the reset — on track for about 45%*,
    or in money for the budget, *Lasts until the reset — on track for about $1,240*
  - reset time
- **The budget's reset date** isn't part of the usage data. The app takes the real one from
  the [status-line snapshot](#optional-status-line-snapshot) when you've set that up (Claude Code
  passes it as `rate_limits.spend_limit`, along with the period: monthly, weekly or daily).
  Without it, the app assumes 00:00 UTC on the 1st of each month and marks the date *(assumed)*,
  until it sees a reset happen: the amount falling between two fetches within 20 minutes of
  00:00 UTC on the 1st confirms the date. A fall at any other time brings *(assumed)* back.
- **Pro/Max with extra usage turned on:** the same $ amounts appear as an *Extra usage*
  row below the 5h and 7d limits, with its own graph under the 5h/7d one (recorded only:
  Claude Code's logs can't tell which activity was paid extra). Tick **Extra usage beside it**
  to add a `$` item next to the 5h/7d one in the menu bar, as `%` or the amount.
- **History graph** in the popup, a line over time like a temperature curve:
  - on an Enterprise/Team seat, money spent across the budget period, with a dashed
    projection to the reset (and the budget line once the curve gets near it). Switch to
    **Per day** for a bar per day, in UTC days like Claude's own usage page.
  - on Pro/Max, the 5h and 7d percentages this week (from the last weekly reset to the next), plus a
    line for a model's own weekly limit (Fable) when the plan has one, with a
    dashed projection of the weekly limit to 100% or to the reset, matching the outlook line
  - hover over it for the time and value at any point
  - **‹ ›** step back through earlier weeks (or budget months) as far as the history goes; click
    the title to return to now. Past periods show how they went, without a projection.
  - **Weeks** (or **Months**) switches to the long view: the weekly % (or the money spent) as one
    line over several periods, a dashed line at each reset with its date, and what each period
    reached labelled just before its reset (an orange point where it ran out or reached the
    budget). Hover for the time, the value, the period's dates and when it ran out. Eight weeks
    (six months) at a time; ‹ › page through older ones.
  - **5h limit hits** (Pro/Max): each time the 5h session reached 100% is an orange point on the
    session line in the week view, and an orange tick along the bottom of the long view, where
    each week's label counts them (`5h ×3`). Hover for when it was hit and how long it was blocked
    until the session reset ("at least" when the Mac was asleep around the reset).

  Claude's usage data only says "now", so the app records its own history from the first
  time it runs: one point per limit about every 10 minutes (and at every reset), in
  `~/Library/Application Support/UsageMeter/history.json`. Usage numbers only, never
  credentials. It's kept without a time limit; after 60 days it's thinned to one point per
  limit per hour (the highest, so each period's peak before its reset stays), about 2 MB a year.
- **Before the app ran, or while the Mac was off,** the budget curve is estimated from Claude
  Code's session logs on this Mac (`~/.claude/projects`), drawn lighter:
  - The app reads only each request's time, model and token counts, never message content,
    and keeps nothing on disk.
  - Each request is priced at list price, and the curve is scaled so it ends exactly at the
    known total. The amounts are real and only the shape in between is estimated.
  - Everything the app didn't record is drawn lighter, quiet time included: the logs can't
    see spending elsewhere. The hover says "(estimated)" where spending was placed and
    "about $… · no activity" where the logs show none (a weekend, a night). An unrecorded
    stretch with the same amount on both sides stays solid, since nothing was spent in it.
  - Spending the logs can't see (the Claude apps, other computers) is spread over the
    Claude Code activity in the same stretch.
  - A stretch with no Claude Code activity stays a gap. In the per-day view, its spending
    counts on the day it was first seen, and the tooltip says so.

  Claude's own per-day chart (Settings → Usage) isn't available to the app: its endpoint
  doesn't accept Claude Code's login.
- Refreshes every 5 minutes, on wake, when the network returns, and when you open the popup.
  If a fetch fails, the last numbers stay and a short note explains why (e.g. *Offline*).
  That works across restarts too: the app keeps the last good numbers in
  `~/Library/Application Support/UsageMeter/last-usage.json` (limits, numbers and reset times
  only) and shows them at launch until a fetch succeeds, leaving out any limit that has reset since.
  While it shows saved numbers, the popup says so at the top, e.g. *Saved numbers from 01:57 ·
  Too many requests, will retry*.

Projections are a straight-line estimate from your average rate so far in the
window. In the first 15% of a window (45 minutes of the 5-hour window, about a day
of the week, about 4½ days of the month) that rate alone is too jumpy: $20 in the
first two hours of a month would project to $7,200. So the week and the budget start
from the previous period's average pace instead, from the app's own history, e.g.
*At last month's pace: about $600 by the 1 Jan reset*. A period counts once the app
recorded at least a quarter of it; if the last one has less (the Mac was off), the most
recent earlier one the history covers stands in (*At an earlier week's pace: …*). As the
first 15% goes by, this period's own spending counts more and more, and after it only this
period counts. The 5-hour session, and any limit without such a period, says
*Too early to project* until then, unless more than 15% is already used: that's ahead of
an even pace for the whole first 15%, so it projects as if that usage had taken all of it
(the slowest it can be going) and the colours and alerts apply, e.g. 58% twenty minutes
into a session: *Runs out around 10:52*.

## Settings

The gear button at the top of the popup shows or hides the settings (closed until you open them;
the app remembers). They sit under the graph: **Menu bar item**, one setting per row, then
**Open at login**, **Check for updates** and **Quit** (⌘Q also quits while the popup is open).
Hover over a control to see what it does.

- **Style**: Bars or Compact; Colour, Alerts or Mono.
- **Limits** (Pro/Max): both, or only `5h` or `7d`. The popup and the graph keep showing both.
  An account without a 5-hour limit shows only `7d` anyway.
- **Number**: `%` or off; on a $ budget also the amount spent.
- **Projection**: off, or where each limit is heading at its reset (`→35%`, `→140%` when it runs out
  first), instead of the number or beside it. Beside a single bar or ring it goes on a second line.
- **Extra usage** (Pro/Max with extra usage turned on): a `$` item beside the limits, as `%` or amount.
- **When ahead**: off, or how far ahead once a limit is 15+ points ahead of pace.
- **Labels** and **Pace tick**. On a $ budget there's no Labels setting and no `$` label: one bar
  needs no label, and the amount (`$306`) has its own `$`.

| Pro / Max | Enterprise / Team |
|---|---|
| <img src="docs/screenshots/settings-pro-max.png" width="356" alt="Menu bar item settings, one per row: Style Bars or Compact and Colour, Alerts or Mono; Limits Both, 5h or 7d; Number % or Off; Projection Off, Instead or Beside; Extra usage Off, % or Amount; When ahead Off, +N, time left or early; checkboxes Labels and Pace tick"> | <img src="docs/screenshots/settings-enterprise.png" width="356" alt="The same settings on a budget account: Number %, Amount or Off, Projection Off, Instead or Beside, no Limits or Extra usage rows, and only the Pace tick checkbox"> |

**Updates.** With **Check for updates** on, a newer version shows under the popup's title, with
what's new and an **Update** button that installs it the way your copy came. A Homebrew copy
asks the tap's formula, so it only hears about a version `brew upgrade` can already install; a
downloaded copy asks for the latest GitHub release.
- Homebrew: `brew update` and `brew upgrade claude-usage-meter` (it builds from source, about a
  minute), then restarts through `brew services`, or opens the new copy. Updating from 0.1.13
  needs one manual step: that version's restart doesn't work, so run
  `brew services restart claude-usage-meter` after it says it's restarting.
- Download: fetches the release zip, checks it against the release's `SHA256SUMS.txt`, replaces the
  app and reopens it. A file the app downloads itself isn't quarantined, so there's no warning.

**Check now** asks once, right away, also with the daily check off, and says "Up to date" or which
version is out. A dev build hears about releases but doesn't install them. `UsageMeter --check-update`
asks once from the command line.

## How it gets the data

1. **Claude Code login (primary).** Reads Claude Code's OAuth token from the macOS
   Keychain item `Claude Code-credentials` and calls
   `GET https://api.anthropic.com/api/oauth/usage` (the call behind Claude Code's `/status`).
   - The token is read on every fetch, never stored, logged or sent anywhere else.
   - It is **never refreshed** by this app, because that would rotate Claude Code's refresh token
     and could sign Claude Code out. Claude Code in Terminal or an IDE renews it (the desktop app's
     Code tab doesn't seem to), and it lasts about 8 hours. When it has expired, the app runs `claude mcp list`
     once (at most every 30 minutes, in an empty folder) if the Claude Code command is installed.
     Checking the MCP connections makes Claude Code renew its own login; it sends no request to a
     model and costs nothing. (`claude auth status` only reports the expiry.) The command's output
     is discarded; the app logs only whether the login was renewed, in `~/Library/Logs/UsageMeter.log`.
   - It reads the item the same way Claude Code does, through Apple's `security` tool, which the
     item already trusts. So there's no Keychain password dialog, not after a rebuild and not after
     Claude Code refreshes its token. (Asking the Keychain directly would prompt each time, because
     every rewrite of the item resets its list of allowed apps.) This doesn't open anything new:
     any program running as you can read the item this way, because that's how Claude Code stores it.
2. **Claude Code status line (fallback).** If the token can't be used, the app reads
   `~/.claude/usage-snapshot.json`, written by [`statusline-snapshot.sh`](statusline-snapshot.sh)
   from the documented `rate_limits` field Claude Code passes to status-line commands.
   The app also uses this file for the budget's reset date (`rate_limits.spend_limit.resets_at`),
   which the usage endpoint doesn't return; a reset that has already passed is ignored.

The app talks only to `api.anthropic.com`, plus GitHub if you turn on **Check for updates**
(off by default; once a day) or click **Check now**: it asks for the latest version number, sending
nothing about you or your usage. No analytics, no other servers.

## Requirements

- macOS 14 or later
- Xcode command line tools (`swiftc`), except for the download
- Claude Code, signed in with a Pro or Max subscription

## Install with Homebrew

```bash
brew trust gtmn/tap                       # Homebrew 7 asks for this for third-party taps
brew install gtmn/tap/claude-usage-meter
brew services start claude-usage-meter    # opens it now and at every login
```

Homebrew builds the app from source on your Mac (about a minute), so no download
is quarantined and no notarization is needed. It also installs the command-line
reader as `claude-usage` and the status-line script under
`$(brew --prefix)/share/claude-usage-meter/`. Use `brew services` to open it at login:
a Homebrew copy hides the app's **Open at login** switch, which would remember the
versioned Homebrew folder that changes with every upgrade. Under `brew services` the
popup says *Opens at login (brew)* instead.

To update: `brew upgrade claude-usage-meter`. If a new version doesn't show up, run
`brew update` first: Homebrew refreshes its taps by itself at most once a day.

## Download

Each version tag gets a [release](https://github.com/gtmn/claude-usage-meter/releases) with a
pre-built app for Apple silicon and Intel Macs (`UsageMeter-<version>.zip`) and the command-line
reader (`claude-usage-<version>.zip`). They're built by GitHub Actions
([`.github/workflows/release.yml`](.github/workflows/release.yml)).

The app is ad-hoc signed but not notarized, so macOS blocks it the first time: open it once,
then click **Open Anyway** in System Settings → Privacy & Security. Or remove the quarantine:

```bash
xattr -dr com.apple.quarantine /Applications/UsageMeter.app
```

Homebrew is still the easier way: no warning, and `brew upgrade` updates it. Turn on
**Open at login** in the popup's settings to start it at login.

## Build and run from a checkout

```bash
cd MenuBar
./build.sh            # builds MenuBar/build/UsageMeter.app (ad-hoc signed, this Mac only)
./build.sh --install  # also copies it to ~/Applications and launches it
./dev.sh              # runs a dev build in place of the installed copy, see below
```

Enable **Open at login** in the popup after installing.

To try changes while the Homebrew copy is installed, run `./dev.sh`. It stops the
Homebrew service and quits any other copy, builds the checkout (stamped with `git describe`),
and runs it in the terminal. Quit it from its popup or press Ctrl-C, and the Homebrew copy
is started again. Both use the same history and settings, so your real data carries on.
Dev builds are unoptimised (about 10 s instead of 30) and skipped when nothing that goes into
the build changed since the last one; `./dev.sh --rebuild` builds anyway.

### Optional: status-line snapshot

Recommended on Enterprise/Team seats, where it supplies the budget's real reset date.
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

Installed as `claude-usage` by Homebrew; from a checkout:

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

## Screenshots

The images in [`docs/screenshots/`](docs/screenshots) are rendered from sample numbers
(no Keychain access, no real usage), so they can be regenerated at any time. `TZ=UTC` keeps the
times in UTC, so the images don't show the time zone of the Mac that rendered them:

```bash
cd MenuBar && ./build.sh && cd ..
export TZ=UTC
APP=MenuBar/build/UsageMeter.app/Contents/MacOS/UsageMeter
$APP --render-preview docs/screenshots/popup-pro-max.png
$APP --render-preview docs/screenshots/popup-enterprise.png enterprise
$APP --render-preview docs/screenshots/popup-enterprise-daily.png enterprise daily
mv docs/screenshots/popup-pro-max.png.label.png docs/screenshots/menubar-pro-max.png
mv docs/screenshots/popup-enterprise.png.label.png docs/screenshots/menubar-enterprise.png
$APP --render-preview docs/screenshots/settings-pro-max.png settings extra
$APP --render-preview docs/screenshots/popup-pro-max-extra.png extra amount
$APP --render-preview docs/screenshots/popup-pro-max-fable.png fable
mv docs/screenshots/popup-pro-max-extra.png.label.png docs/screenshots/menubar-pro-max-extra.png
$APP --render-preview docs/screenshots/settings-enterprise.png settings enterprise amount
$APP --render-preview docs/screenshots/hero.png scene beside
for v in compact mono alerts beside projected only5h "enterprise amount" "compact enterprise amount beside"; do
  $APP --render-preview /tmp/um.png $v
  case "$v" in
    beside) name=projection-beside ;; projected) name=projection-instead ;;
    "enterprise amount") name=enterprise-amount ;; "compact enterprise amount beside") name=projection ;;
    *) name=$v ;;
  esac
  mv /tmp/um.png.label.png "docs/screenshots/menubar-$name.png"
done
rm docs/screenshots/*.label.png /tmp/um.png
```

Renders never read or change your own settings: they use the arguments, in a throwaway store.

`scene` draws the whole popup opened under the item on a plain menu bar (the README's first image).
Add `compact` for the Compact menu bar style, `mono` or `alerts` for those palettes, `amount` for the budget's amount, `extra` for Pro/Max with extra usage (and its menu bar item), `only5h` or `only7d` for one limit in the menu bar, `fable` for a Fable weekly limit (and its line in the graph), `update` for a newer release offered, `panel` for the whole popup or `settings` for its settings alone, `nolabels`, `nopercent`, `nopace` or `noahead` to leave those out, `left` or `early` for the time left or early, `daily` for the per-day bars, `overview` for the Weeks or Months view, `full` for the session at its limit, `burst` for 58% twenty minutes into a session, `back=2` for two periods (or overview pages) back, `hover` to show the graph's tooltip (`hover=1.5` halfway along the projection), `light` for light mode, or `live` to render your
own current numbers and recorded history instead (don't commit those).

## Releasing

1. Tag the commit and push the tag: `git tag -a vX.Y.Z -m "Usage Meter X.Y.Z"`, then
   `git push origin vX.Y.Z`. The workflow tests, builds and publishes the GitHub release with
   the zips in a few minutes. (It also builds every push to `main`, kept as a downloadable
   artifact on the run; `.github/package.sh X.Y.Z` makes the same files locally, in `dist/`.)
2. Take the sha256 of GitHub's tag tarball
   (`https://github.com/gtmn/claude-usage-meter/archive/refs/tags/vX.Y.Z.tar.gz`).
3. Update `url` and `sha256` in `Formula/claude-usage-meter.rb` of the tap
   ([`gtmn/homebrew-tap`](https://github.com/gtmn/homebrew-tap), checked out locally under
   `$(brew --repository)/Library/Taps/gtmn/homebrew-tap`), commit as "claude-usage-meter X.Y.Z"
   and push.
4. `brew upgrade claude-usage-meter`, `brew test claude-usage-meter`,
   `brew services restart claude-usage-meter`.
   The popup's **Update** button can stand in for the upgrade and restart (with **Check for
   updates** on or after **Check now**); from 0.1.13 also run `brew services restart` yourself
   (see Updates). `brew test` still runs by hand.

## Layout

| Path | What |
|---|---|
| `UsageReader.swift` | Reads both sources, projections, plain-language wording |
| `History.swift` | Records and stores usage over time for the graph; fills gaps, daily totals |
| `ClaudeCodeLogs.swift` | Reads request times and token counts from Claude Code's logs, for the estimates |
| `LoginNudge.swift` | Runs `claude mcp list` when Claude Code's login has expired, so Claude Code renews it |
| `UpdateCheck.swift` | The opt-in update check's plain parts: versions, release files, checksums |
| `MenuBar/` | The SwiftUI menu bar app |
| `main.swift` | Command-line reader |
| `statusline-snapshot.sh` | Claude Code status-line command for the fallback |
| `tests/` | Scenario checks |
| `docs/DECISIONS.md` | Why things work the way they do, and what was ruled out |
| `docs/BACKLOG.md` | What's next and open ideas |
| `docs/screenshots/` | README images, rendered from sample data |
| `.github/` | Release workflow and `package.sh`, which builds the release files |

## License

MIT, see [LICENSE](LICENSE).
