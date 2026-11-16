# Usage Meter

macOS menu bar app and `claude-usage` CLI showing Claude usage (Pro/Max limits, Enterprise/Team $ budget,
history graph). Swift + SwiftUI + Swift Charts, built with `swiftc`, released through the Homebrew tap `gtmn/tap`.

**Read `docs/HANDOFF.md` first**, then `README.md` (layout, build, tests).

- Test: `./test.sh`. Build: `MenuBar/build.sh`. Run a dev build: `MenuBar/dev.sh`.
- Public repo: no employer/client names, no real usage numbers or `live` renders in commits.
- Never print, log or refresh the Claude Code OAuth token; read it only via `/usr/bin/security`.
- Commit as `gtmn <3950572+gtmn@users.noreply.github.com>`; branch, then fast-forward merge; push over SSH.
