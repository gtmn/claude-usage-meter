# Usage Meter

macOS menu bar app and `claude-usage` CLI showing Claude usage (Pro/Max limits, Enterprise/Team $ budget,
history graph). Swift + SwiftUI + Swift Charts, built with `swiftc`, released through the Homebrew tap `gtmn/tap`.

Read `README.md` (layout, build, tests, releasing), then `docs/DECISIONS.md` (why things are the way they are,
what was ruled out) and `docs/BACKLOG.md` (what's next).

- Test: `./test.sh`. Build: `MenuBar/build.sh`. Run a dev build: `MenuBar/dev.sh` (stops the Homebrew service,
  runs the checkout build, restarts the service on exit). Dev builds report `0.0.0-dev` or a `git describe`
  version and never install updates; `UsageMeter --check-update` tests the update check.
- Releasing (README): bump the tap right after the release. Homebrew copies read the version from the tap's
  formula, so they only hear about a release once the formula has it.
- Public repo: no employer/client names, no real usage numbers or `live` renders in commits.
- Never print, log or refresh the Claude Code OAuth token; read it only via `/usr/bin/security`.
  No personal data in external requests.
- Commit as `gtmn <3950572+gtmn@users.noreply.github.com>`; branch, then fast-forward merge; push over SSH.
  Don't change `gh` auth. Don't commit in the dotfiles repo from here.

## Swift and preview gotchas

- Avoid `Date >=` / `<=`: with Xcode 27.2 they compile to Foundation symbols macOS lacks and crash. Use
  `isAtOrAfter` / `isAtOrBefore`; `test.sh` checks for it.
- Use `@ViewState`, not `@State`: the macOS 27 SDK makes `@State` a macro whose plugin only Xcode has, and
  Homebrew builds with the Command Line Tools. `build.sh` checks for it.
- Use `RectangleMark` for marks with both an x and a y range.
- `Columns` (MenuBarImage.swift) drops empty columns, so don't index its arrays by position: `fonts[1]` crashed
  the compact style on a budget without labels.
- Running the app binary with a flag it doesn't handle (such as `--version`) starts a second menu bar copy.
- Don't set a fake `XPC_SERVICE_NAME` for renders: they exit with 133.
- Render previews with `--render-preview` (sample data, no Keychain). Renders take their settings from the
  arguments, in a throwaway store, never the saved ones; preview and sample models never fetch (`refresh()` is
  guarded).
