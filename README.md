# Usage Meter

A small macOS menu bar app that shows your Claude subscription usage and tells you in plain words
whether you'll run out before the reset: the 5-hour session and weekly limits on Pro/Max, the $ budget
on Enterprise/Team seats. No browser cookie to paste: it reuses the login that
[Claude Code](https://claude.com/claude-code) already keeps on your Mac.

> **Unofficial.** Not affiliated with or endorsed by Anthropic. It relies on an
> undocumented endpoint that may change or stop working at any time.

<img src="docs/screenshots/hero.png" width="412" alt="The popup opened under the menu bar item: the item shows 5h 20% →35% and 7d 60% →105%; the popup has Session 5 h at 20%, on track for about 35%, Week all models at 60% in yellow, runs out Friday morning, a line graph of the week with a dashed projection to 100%, and the Menu bar item settings below, with Projection set to Beside">

*Sample numbers and a made-up history, rendered by the app itself.*

## What it does

- **Menu bar item** with your limits at a glance: bars, rings, dots, a gauge, a sparkle or just the
  numbers, coloured by pace (green on track, yellow ahead, orange well ahead).
- **Plain-language outlook** for each limit: *Lasts until the reset — on track for about 35%*, or
  *Runs out Friday morning, 8 h before Friday's reset*.
- **Projection** in the menu bar if you like: `60% →105%` says the week runs out first.
- **History graph** of this week or budget month, with the projection to the reset. Hover for any
  point, step back through earlier periods, or look at it per day, week or month.
- **Enterprise/Team budgets** in % or dollars, and Pro/Max **extra usage** as its own item.
- **One-click updates** (opt-in), and a **command-line reader**, `claude-usage`.

Everything in detail, including all settings: the [guide](docs/GUIDE.md).

| Pro / Max | Enterprise / Team |
|---|---|
| <img src="docs/screenshots/popup-pro-max.png" width="356" alt="Popup: Session 5 h at 20%; Week all models at 60% in yellow, runs out 8 h before the weekly reset; below, a line graph of both this week with a dashed projection of the week to 100%"> | <img src="docs/screenshots/popup-enterprise.png" width="356" alt="Popup: Monthly budget at 21%, $412.80 used of $2,000.00, $1,587.20 left, on track for about $800 by the 1 Dec reset; below, a line graph of money spent this month with a dashed projection, the unrecorded part drawn lighter as estimated"> |
| <img src="docs/screenshots/popup-pro-max-extra.png" width="356" alt="Popup: Session and Week rows, then Extra usage at 25%, $12.40 used of $50.00, on track for about $16; the 5h/7d graph, and below it a graph of extra usage this month with a dashed projection to about $16"> | <img src="docs/screenshots/popup-enterprise-daily.png" width="356" alt="The same popup with the graph switched to Per day: a bar per UTC day, the unrecorded days' bars lighter as estimated"> |
| <img src="docs/screenshots/popup-pro-max-fable.png" width="356" alt="Popup: Session, Week all models and Week Fable at 35%; the week graph with a third, ochre line for Fable ending at Fable 35%"> | |

### In the menu bar

At real size, on a dark and a light menu bar. Each is a setting in the popup.

| Bars | Circle | Dots |
|---|---|---|
| <img src="docs/screenshots/bar-bars.png" width="133" alt="Bars: 5h and 7d bars at 20% and 60% with their labels"> | <img src="docs/screenshots/bar-circle.png" width="124" alt="Circle: two rings with 5h 20% and 7d 60%"> | <img src="docs/screenshots/bar-dots.png" width="110" alt="Dots: 5h 20% and 7d 60%, each after a coloured dot"> |
| **Gauge** | **Sparkle** | **Numbers only** |
| <img src="docs/screenshots/bar-gauge.png" width="124" alt="Gauge: a yellow gauge before 5h 20% and 7d 60%"> | <img src="docs/screenshots/bar-sparkle.png" width="123" alt="Sparkle: a yellow sparkle before 5h 20% and 7d 60%"> | <img src="docs/screenshots/bar-off.png" width="104" alt="Indicator off: 5h 20% and 7d 60% as text"> |
| **Bars, no labels** | **Circle, no labels** | **Dots, no labels** |
| <img src="docs/screenshots/bar-bars-nolabels.png" width="118" alt="Bars with 20% and 60%, without the 5h and 7d labels"> | <img src="docs/screenshots/bar-circle-nolabels.png" width="109" alt="Rings with 20% and 60%, no labels"> | <img src="docs/screenshots/bar-dots-nolabels.png" width="95" alt="Dots with 20% and 60%, no labels"> |
| **Gauge, no labels** | **Mono** | **Alerts** |
| <img src="docs/screenshots/bar-gauge-nolabels.png" width="109" alt="A gauge with 20% and 60%, no labels"> | <img src="docs/screenshots/bar-mono.png" width="133" alt="Mono: bars in the text colour"> | <img src="docs/screenshots/bar-alerts.png" width="133" alt="Alerts: only the 7d bar coloured, as it is ahead of pace"> |
| **Projection** | **Projection, number off** | **Only 5h** |
| <img src="docs/screenshots/bar-projection.png" width="172" alt="Bars with 20% →35% and 60% →105%"> | <img src="docs/screenshots/bar-projection-only.png" width="147" alt="Bars with →35% and →105% in place of the numbers"> | <img src="docs/screenshots/bar-only5h.png" width="133" alt="A single 5h bar at 20%"> |
| **Budget** | **Budget, amount** | **Budget, projection** |
| <img src="docs/screenshots/bar-budget.png" width="118" alt="A single budget bar at 21%"> | <img src="docs/screenshots/bar-budget-amount.png" width="121" alt="A budget bar with $412"> | <img src="docs/screenshots/bar-budget-projection.png" width="129" alt="A budget bar with $412 over →$520"> |
| **Extra usage beside the limits** |  |  |
| <img src="docs/screenshots/bar-extra.png" width="187" alt="The 5h and 7d bars, and beside them a $ bar with $12"> |  |  |

## Install

```bash
brew trust gtmn/tap                       # Homebrew 7 asks for this for third-party taps
brew install gtmn/tap/claude-usage-meter
brew services start claude-usage-meter    # opens it now and at every login
```

Or download the app from the [releases](https://github.com/gtmn/claude-usage-meter/releases). It isn't
notarized, so macOS asks once ([details](docs/GUIDE.md#download)). Needs macOS 14 or later and
Claude Code signed in.

## How it works

On every fetch (every 5 minutes, on wake and when you open the popup) it reads Claude Code's login from
the macOS Keychain, never storing, logging or refreshing it, and asks Claude's usage endpoint, the one
behind Claude Code's `/status`. If that fails, it falls back to what Claude Code's status line wrote.
Besides `api.anthropic.com` it talks only to GitHub, and only when you turn on update checks.
[More](docs/GUIDE.md#how-it-gets-the-data).

## Project layout

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
| `docs/GUIDE.md` | Everything the app shows, its settings, how it gets the data, installing |
| `docs/DEVELOPMENT.md` | Building, testing, screenshots, releasing |
| `docs/DECISIONS.md` | Why things work the way they do, and what was ruled out |
| `docs/BACKLOG.md` | What's next and open ideas |
| `docs/screenshots/` | README images, rendered from sample data |
| `.github/` | Release workflow and `package.sh`, which builds the release files |

## Development

```bash
./test.sh            # scenario checks: wording, projections, error messages
MenuBar/build.sh     # builds MenuBar/build/UsageMeter.app
MenuBar/dev.sh       # runs the checkout build in place of the Homebrew copy
```

Building, screenshots and releasing: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Why things are the way
they are: [docs/DECISIONS.md](docs/DECISIONS.md).

## License

MIT, see [LICENSE](LICENSE).
