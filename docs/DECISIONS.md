# Design decisions

Why the app works the way it does. `README.md` says *what* it does; this file keeps the reasons and the
options that were ruled out, so they aren't tried again.

## Claude Code's login

- **Read the token through `/usr/bin/security`, not `SecItemCopyMatching`.** Claude Code writes the Keychain
  item with the `security` CLI, so reads through the same tool need no dialog. Direct reads prompted after
  every rebuild and every token refresh. Touch ID ("biometric proxy") can't replace that dialog.
- **Never refresh the OAuth token.** That would rotate Claude Code's refresh token and sign Claude Code out.
- **When the token has expired, run `claude mcp list`** (no model call, costs nothing), at most every 30
  minutes, from an empty folder. Ruled out: `claude auth status` (only reports the expiry, doesn't renew) and
  `claude -p` (renews, but costs usage).
- **Status line as the fallback source.** Claude Code passes `rate_limits` to status-line commands, so the
  script works without the token. It only runs where Claude Code runs status lines: in our checks the
  terminal, not the desktop app's Code tab.
- **Claude's daily spend endpoint is not used.** `claude.ai/api/organizations/{org}/usage/spend` rejects OAuth
  tokens and sits behind Cloudflare's bot check. Don't try to get around the bot check.

## Budget and projections

- **The budget resets at 00:00 UTC on the 1st**, as in Claude's own UI (which computes it in the browser). A
  drop within 20 minutes of that time is remembered as confirmation and removes "(assumed)".
- **Early projections use last period's pace** until 15% of the period has passed, then the current pace.
  A period counts once a quarter of it is recorded (the pace is usage over the time covered); if the last
  one has less, the most recent earlier period in the history stands in, named "an earlier week's".
  Not from Claude Code's logs: they cover one Mac, at list prices, without claude.ai, and can't be scaled
  without real totals.
- **An early burst isn't "too early"** (2026-11-19): with no earlier period (the 5 h session), the first 15%
  holds projections back only while usage is at most 15%. Past that it's ahead of an even pace for the
  whole first 15%, which isn't noise, so it projects at usage ÷ the first 15% (the slowest it can be going:
  warns without overstating) and the pace colours apply. 58% twenty minutes in: runs out in about 30
  minutes, where the rate so far would say 15.

## Menu bar

- **No Labels setting and no `$` label on a $ budget.** There's only one bar, so a label tells nothing apart,
  and the amount (`$306`) carries its own `$`.
- **The Projection setting is text only, rounded to 5% and not capped** (2026-11-24): the bars and colours
  stay on current usage. `→140%` says it runs out, as When ahead says in time. Just Off and On: On puts it
  after the number, and on a second line beside a single bar or ring (one row has no room for two numbers).
  With Number off it takes the number's column, and the plain number shows until there's a projection: a
  bar with no text early in every window would look broken. (0.1.14 had Instead and Beside; both load as On.) The menu bar's amounts have no thousands separator
  (`$1990`): it only takes room, and a budget stays in four digits; the popup keeps it (`$1,990`).
- **Indicator: Bars, Circle, Dots, Icon or Off** (2026-11-24). Was "Style"; Off is the numbers alone (saved as
  `text`, its first name), Circle the earlier Compact (still saved as `compact`). On a $ budget the names are
  singular (Bar, Dot). Dots puts a dot before each row for the pace colour, since the text stays in the text
  colour; Mono has no dots, Alerts shows one only once ahead. Without a dot the text starts at the edge: kept
  room read as a gap, and the width changes with the numbers anyway. The dot is small (4 pt stacked, 5 pt on
  one line, 2 pt gap). Icon is Apple's gauge symbol (also shown when there's no data), tinted like the worst
  limit, its needle at the highest use; not the Claude logo, which is Anthropic's mark and would suggest an
  official app. With Dots or Off nothing else is sure to show, so the popup greys out combinations that would
  leave the item empty (nothing to click); settings saved before that show the plain number. The palette has
  its own row (Colours), hidden with Off.
- **A model's own weekly limit (Fable) is a third line in the week graph**, not a chart of its own: same 0-100%
  scale over the same week. Ochre, because violet merges with the blue week line for colour-blind readers.

## History and estimates

- **History is kept without a time limit** (2026-11-19), so past weeks and months can be looked back at.
  Points older than 60 days are thinned to one per window per hour, keeping each hour's highest point so a
  period's peak before its reset survives. About 2 MB a year; it was 40 days before.
- **Looking back: ‹ › through periods, and a long view as one line** (2026-11-19). The long view is the weekly
  % (or the budget's money) as one line over 8 weeks (6 months), a dashed rule at each reset and the value
  each period reached labelled before it, orange where it ran out. Tried first as one bar per period at its
  peak; a line reads better, and with the resets marked the sawtooth (climb, drop at the reset) is the
  point rather than noise. Drawn from one point per hour (the highest). Periods are reset to reset, stepped
  back from the current reset (calendar months in UTC for the budget). Only recorded points count; past
  periods aren't estimated from the logs. The 5 h session's line is left out (it resets too often to say
  much there); its limit hits are shown instead.
- **5 h limit hits come from the history** (2026-11-19): a session counts once from its first point at 100%
  until usage drops (the reset). Blocked time runs to that first lower point; if nothing was recorded for
  over 30 minutes before it, the reset time isn't known and the time counts "at least" to the last 100%.
- **History stays 10-minute for 60 days, then hourly** (2026-11-19). Finer isn't available: the app fetches
  every 5 minutes, and more often runs into the rate limit. Keeping 10-minute points beyond 60 days would
  be about 6 MB a year instead of about 2, rewritten on every fetch, for nothing visible: the long view
  draws hourly peaks.

- **Unrecorded stretches are estimated from Claude Code's logs** (`~/.claude/projects/**/*.jsonl`, deduplicated
  by message id + requestId, priced at list prices), scaled to the real totals at both ends of a gap.
- **Drawing rule:** everything the app didn't record itself is drawn lighter. The hover says "no activity"
  only where the logs show none, and "(estimated)" where spending was placed. A gap with the same amount on
  both sides stays solid: nothing happened, and that is known.
- **Pro/Max extra usage is recorded only, never estimated from logs.** On Pro/Max most activity is covered by
  the plan, so the logs can't tell which part was paid extra.

## Distribution

- **Homebrew builds from source:** no quarantine, no notarization needed. The version comes in through
  `USAGE_METER_VERSION`.
- **`brew services` replaces the app's Open-at-login switch** in Homebrew copies (hidden there), because the
  switch would remember the versioned Cellar folder, which changes with every upgrade.
- **GitHub releases carry pre-built universal zips**, ad-hoc signed only. Notarizing would need an Apple
  Developer ID.
- **Updates are opt-in** ("Check for updates", off by default), because the app promised to talk only to
  `api.anthropic.com`. One unauthenticated request a day to GitHub's latest-release API; **Check now**
  sends one right away even with the setting off, because the user asked for it. A Homebrew copy reads the
  version from the tap's formula (through the same API), not the releases: a release goes out minutes before
  the tap is bumped, and offering it then would end in "Homebrew doesn't have it yet". Update installs
  the way the copy came: Homebrew runs `brew update` + `brew upgrade`, then `brew services restart`
  in a session of its own (`posix_spawn` with `POSIX_SPAWN_SETSID`). Not `launchctl kickstart -k`: launchd
  keeps the code signature it recorded when the job was loaded, an ad-hoc signed rebuild doesn't match it,
  and the new copy is refused (`OS_REASON_CODESIGNING`, seen on the 0.1.12 → 0.1.13 update). Only unloading
  and reloading the job records the new one. In its own session because unloading ends everything in the
  job's process group: started normally, the restart dies halfway and leaves the job unloaded (both checked
  with a throwaway launch agent). A download is checked against the release's `SHA256SUMS.txt` (catches a
  broken download, not a compromised GitHub account: the same trust as downloading by hand). Not
  Sparkle: it needs signing keys, a feed and an embedded framework, and fits badly with ad-hoc signing
  and a `swiftc`-only build. Worth revisiting with a Developer ID.
- **Two taps:** the public `gtmn/tap` (repo `gtmn/homebrew-tap`, fresh history, only this app) and a private
  one. Each has its own weekly livecheck workflow (GitHub Actions, Linux).
