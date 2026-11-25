# "Sign in again" button: options

Status: options note, not decided, nothing implemented. Decide before 2026-12-07, when Claude Code's refresh
token on the main Mac runs out (backlog, Next 1).

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

Decisions needed:
1. A (Terminal) vs C (copy only) vs D.
2. Whether the menu bar item should show the signed-out state too.
3. Whether to test with a deliberate `claude auth logout` before 7 Dec, or wait for the real expiry.
