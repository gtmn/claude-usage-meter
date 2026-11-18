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
  one has less, the most recent earlier period in the history (40 days) stands in, named "an earlier week's".
  Not from Claude Code's logs: they cover one Mac, at list prices, without claude.ai, and can't be scaled
  without real totals.

## Menu bar

- **No Labels setting and no `$` label on a $ budget.** There's only one bar, so a label tells nothing apart,
  and the amount (`$306`) carries its own `$`.
- **A model's own weekly limit (Fable) is a third line in the week graph**, not a chart of its own: same 0-100%
  scale over the same week. Ochre, because violet merges with the blue week line for colour-blind readers.

## History and estimates

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
  the way the copy came: Homebrew runs `brew update` + `brew upgrade` and restarts with
  `launchctl kickstart -k` (launchd restarts the job itself; `brew services restart` from inside the job
  would be killed halfway); a download is checked against the release's `SHA256SUMS.txt` (catches a
  broken download, not a compromised GitHub account: the same trust as downloading by hand). Not
  Sparkle: it needs signing keys, a feed and an embedded framework, and fits badly with ad-hoc signing
  and a `swiftc`-only build. Worth revisiting with a Developer ID.
- **Two taps:** the public `gtmn/tap` (repo `gtmn/homebrew-tap`, fresh history, only this app) and a private
  one. Each has its own weekly livecheck workflow (GitHub Actions, Linux).
