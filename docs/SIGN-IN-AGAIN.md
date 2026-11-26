# "Sign in again" button: options

Status: **decided 2026-11-25: option A, with C as the fallback, and the menu bar item fades while signed
out.** Built on `claude/overnight-polish` (see "What was built" at the end). **Tried for real on
2026-11-25** (see "Tried for real" at the end).

## The problem

Claude Code keeps two things in the Keychain item `Claude Code-credentials`: a short access token (about
8 hours, `claudeAiOauth.expiresAt`) and a refresh token. When the access token runs out, the app runs
`claude mcp list` (LoginNudge.swift) and Claude Code renews it with the refresh token. Once the refresh token
itself has run out, nothing can renew it: someone has to sign in again (`claude auth login`, or `/login`
inside Claude Code). Until then the popup says *Login expired: open Claude Code* and the numbers go stale.

A button would save opening a terminal and remembering the command. It doesn't make anything possible that
isn't possible today.

## Rules any option has to keep (AGENTS.md, DECISIONS.md)

- The app never prints, logs, stores or refreshes the token. Signing in is done by Claude Code itself; the
  app only starts it and then reads the Keychain item again through `/usr/bin/security`, as now.
- The command's output isn't logged: it can hold the sign-in URL and the account's email. The log gets
  times and outcomes only ("sign-in started", "login valid until …").
- Nothing is sent anywhere by the app; the browser talks to Anthropic, not the app.
- It only runs when clicked. No automatic sign-in attempts (that would open browser tabs unasked).

## How the app tells "needs signing in" from "just expired"

Today both show the same message. Proposed states, from what the app already knows:

| What the app sees | Meaning | Shown |
|---|---|---|
| `expiresAt` in the past, nudge not tried yet or < 30 min ago | access token ran out; the nudge will probably renew it | as now |
| nudge ran (`exited(_)`), `expiresAt` unchanged and still past | renewal failed: refresh token gone or revoked | **Sign in again** |
| `401` right after a renewal that looked successful | token revoked server-side | **Sign in again** |
| `noCLI` | no `claude` command to run | text only: "Sign in with Claude Code" |
| no Keychain item (`noCredentials`) | never signed in, or signed out | **Sign in** (same button) |

"Nudge ran and didn't renew" is the reliable signal: it's already logged as `login renewed: no`. One failed
nudge could be a network blip, so show the button after the first failed nudge but keep retrying the nudge
on the 30-minute spacing; the button disappears as soon as `expiresAt` moves into the future.

Not checked (would need a real expired refresh token, i.e. waiting for 7 Dec): what exit code
`claude mcp list` returns in that case, and whether it prints anything useful. The table above doesn't
depend on it; it only looks at whether `expiresAt` moved.

## Where the button sits

In the status line at the top of the popup, where *Login expired: open Claude Code* is shown today:
*Signed out of Claude Code · **Sign in…*** (a small bordered button, like **Update**). Not in the settings
(they're closed most of the time, and this is a state, not a setting). Optionally the menu bar item
could fade or show a small `!` while signed out, since the numbers it shows are getting old; that's a
separate, smaller decision.

## How `claude auth login` behaves (Claude Code 2.1.323)

`claude auth login [--claudeai | --console] [--email <email>] [--sso]`; `--claudeai` (subscription) is the
default. Help text only was checked; the command wasn't run (it would replace the current login).

From how Claude Code's sign-in works in a terminal: it opens the default browser on Anthropic's sign-in page
and waits for the browser to come back to a local callback; if the browser can't be opened or the callback
fails, it shows the URL and asks for a code to be pasted into the terminal. So it is built for a terminal.

- **Started from the menu bar app with no terminal** (stdin `/dev/null`, as LoginNudge does): the browser part
  may well work (`open` works from a GUI process), but if it falls back to "paste the code", there's nowhere
  to paste it and the process hangs until a timeout. There's also no way for the user to see what's going
  on. Not verified.
- **Under `brew services`**: the app runs as a LaunchAgent in the user's GUI session, so opening the browser
  or Terminal works the same as for a copy started by hand. The environment is minimal; LoginNudge already
  sets `PATH`, `USER` and `LOGNAME`, and the same would be needed here.
- **In Terminal**: works as designed, with both the browser flow and the paste fallback.

## Options

**A. Open Terminal running `claude auth login`** (recommended). The app writes a tiny script
(`#!/bin/zsh`, `exec <claude path> auth login`) into its own Application Support folder, makes it
executable and opens it with `open -a Terminal <file>.command`. The user sees Claude Code's own sign-in,
including the paste fallback, and the app never touches its input or output. Afterwards the app polls the
Keychain item's `expiresAt` (every 10 s for up to 10 minutes) and fetches as soon as it moves.
- No Automation permission needed (that would be needed for `tell application "Terminal" to do script`).
- A file the app writes itself isn't quarantined, so no Gatekeeper prompt.
- Uses the user's default terminal only if `open <file>.command` is used without `-a Terminal`; `.command`
  files open in Terminal by default, and some terminals (iTerm) register for them too. Either is fine.
- Effort: small (one button, one state, one script, one poll). Testable with `--render-preview` for the
  look; the flow itself only for real once the refresh token has expired (or after `claude auth logout`).

**B. Run `claude auth login` in the background** and let the browser do the rest. Nicer when it works
(no Terminal window), but it depends on Claude Code never falling back to the paste prompt, gives no
feedback while it waits, and needs a timeout that kills a sign-in the user is halfway through. It would
also be the app driving an interactive login flow it can't see, which is close to "the app handles the
login", the thing the rules keep it away from.

**C. Text and a Copy button only**: *Signed out of Claude Code. Run `claude auth login` in Terminal*
with a button that copies the command. No process started at all. The safe minimum, and the fallback for A
when Terminal can't be opened.

**D. Nothing**: keep *Login expired: open Claude Code*. Starting Claude Code in a terminal shows its own
"please /login" anyway.

## Recommendation

**A with C's text as the fallback**, and the "nudge ran and didn't renew" state as the trigger. It keeps the
app out of the sign-in itself (Claude Code does it, visibly, in a terminal), needs no new permissions, and
is small. Ship it before 7 Dec so the first real expiry is the test; until then, check the look with a
render and the flow once with `claude auth logout` followed by the button, on a day when signing in again
is convenient.

Decided (2026-11-25): A, with C's text and Copy button as the fallback; the menu bar item fades while signed
out.

## What was built

- **When** (`LoginNudge.signInNeeded`, checked in `tests/errors-src`): the nudge ran (finished or timed out)
  and the login wasn't renewed; or it was renewed and the server still refused it; or there's no Keychain
  item. Never without a `claude` command. The state stays until a fetch through the login works again,
  since a fetch between two nudges can't tell.
- **Popup**: a row under the title, *Sign in to Claude Code to get new numbers* with **Sign in…**. The
  saved-numbers line says *Signed out of Claude Code* instead of *Login expired: open Claude Code*.
- **Sign in…** writes `~/Library/Application Support/UsageMeter/sign-in.command` (`exec '<claude>' auth
  login`, nothing else) and opens it, which opens Terminal (or whatever is set to open `.command` files).
  It then reads the Keychain item's expiry every 10 s for up to 10 minutes and fetches as soon as it's in
  the future. While waiting: *Finish signing in in Terminal and your browser.* If the file can't be opened:
  *Couldn't open Terminal. Run claude auth login there.* with **Copy**.
- **Log** (`~/Library/Logs/UsageMeter.log`): "sign-in: opened claude auth login in Terminal", "sign-in:
  login valid until …", "sign-in: no new login after 10 min", "sign-in: couldn't open Terminal". Nothing
  from the command itself.
- **Menu bar**: the item is drawn at 45% opacity while signed out (`MenuBarImage.faded`).
- **Previews**: `--render-preview out.png signedout panel` shows the row with sample data; the `.label.png`
  next to it shows the faded item.

Not verified: that a `.command` file the app writes opens without a Gatekeeper prompt, and how
`claude auth login` behaves when its refresh token has run out. Both need the real flow.

## Tried for real (2026-11-25)

- Claude Code's refresh token ran out on 25 Nov at 06:10, earlier than the 7 Dec expected: the Keychain item
  then had no tokens and `loginEnded: time_limit`. The 13:22 nudge logged "login renewed: no"; the menu bar
  kept the 13:17 numbers (0.1.15 had no signed-out state yet), which led to the stale warning.
- A dev build showed it as signed out right away (no Keychain token at all counts as signed out, without a
  nudge). **Sign in…** opened Terminal running `claude auth login` (log: "sign-in: opened claude auth login
  in Terminal", 23:57:53); after signing in, fresh numbers came at 23:59:47. The new refresh token runs to
  24 Dec: about four weeks, so expect to sign in about once a month.
- Open: the log has no "sign-in: login valid until …" line, though the login came back. Probably the regular
  fetch picked the new login up before the 10-second watch did and ended the wait without logging it.
  Whether a Gatekeeper prompt appeared before Terminal opened wasn't noted.

## Ruled out: a long-lived `claude setup-token` token (2026-11-26)

Tested as a way to skip the monthly sign-in: `claude setup-token` makes a long-lived token, but
`/api/oauth/usage` answers **HTTP 403** to it, on both kinds of plan (Pro/Max and an Enterprise/Team seat). It's made for model
requests (Claude Code's own login also carries `user:profile`, which the usage endpoint likely needs).
Reading usage from the rate-limit headers of a model request made with it would cost usage on every check,
against the rule that the meter sends no model requests. Not an option.
