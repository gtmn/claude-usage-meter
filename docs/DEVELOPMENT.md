# Developing Usage Meter

Building, testing, the README screenshots and releasing. The layout of the repo is in the
[README](../README.md#project-layout); why things are as they are, in [DECISIONS.md](DECISIONS.md).

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

## Tests

```bash
./test.sh
```

Prints the outlook wording for fixed scenarios (in UTC, so the output is the same
on any machine) and the short message for each kind of error.

`MenuBar/build/UsageMeter.app/Contents/MacOS/UsageMeter --test-notification` posts the signed-out
notification once (asking for permission the first time) and prints whether macOS took it;
`--check-update` asks GitHub once for the latest version.

## Screenshots

The images in [`screenshots/`](screenshots) are rendered from sample numbers (no Keychain access,
no real usage), so they can be regenerated at any time. `TZ=UTC` keeps the times in UTC, so the
images don't show the time zone of the Mac that rendered them. From the repo root:

```bash
cd MenuBar && ./build.sh && cd ..
export TZ=UTC
APP=MenuBar/build/UsageMeter.app/Contents/MacOS/UsageMeter
S=docs/screenshots
$APP --render-preview $S/hero.png scene beside
$APP --render-preview $S/popup-pro-max.png
$APP --render-preview $S/popup-enterprise.png enterprise
$APP --render-preview $S/popup-enterprise-daily.png enterprise daily
$APP --render-preview $S/popup-pro-max-extra.png extra amount
$APP --render-preview $S/popup-pro-max-fable.png fable
$APP --render-preview $S/settings-pro-max.png settings extra
$APP --render-preview $S/settings-enterprise.png settings enterprise amount
# The menu bar settings, one sheet each (rows and captions: MenuBar/Sources/MenuBarSheet.swift).
$APP --render-preview $S/menubar-pro-max.png sheet=pro-max
$APP --render-preview $S/menubar-enterprise.png sheet=enterprise
rm -f $S/*.label.png
```

Every render also writes `<name>.label.png`, the menu bar item enlarged 6 times, for checking details.

Renders never read or change your own settings: they use the arguments, in a throwaway store.

`scene` draws the whole popup opened under the item on a plain menu bar (the README's first image).
Add `compact` for the Circle menu bar style, `dots` for Dots, `icon` for Gauge, `text` for Indicator off, `beside` for Projection on (`projected`: on, with Number off), `mono` or `alerts` for those palettes, `amount` for the budget's amount, `extra` for Pro/Max with extra usage (and its menu bar item), `only5h` or `only7d` for one limit in the menu bar, `fable` for a Fable weekly limit (and its line in the graph), `update` for a newer release offered, `signedout` for saved numbers while signed out of Claude Code (the menu bar item faded; with `panel`, the Sign in… row), `panel` for the whole popup or `settings` for its settings alone, `nolabels`, `nopercent`, `nopace` or `noahead` to leave those out, `left` or `early` for the time left or early, `daily` for the per-day bars, `overview` for the Weeks or Months view, `day` for the Day view (Pro/Max, or with `enterprise` or `extra` the budget's), `full` for the session at its limit, `burst` for 58% twenty minutes into a session, `over` for a budget spending faster than it lasts, `runout` for the session projected to run out with the week on track, `stale` for old numbers (faded, grey, a red dot in Dots), `back=2` for two periods (days, or overview pages) back, `hover` to show the graph's tooltip (`hover=1.5` halfway along the projection), `light` for light mode, or `live` to render your
own current numbers and recorded history instead (don't commit those).

## Releasing

1. Tag the commit and push the tag: `git tag -a vX.Y.Z -m "Usage Meter X.Y.Z"`, then
   `git push origin vX.Y.Z`. The workflow tests, builds and publishes the GitHub release with
   the zips in a few minutes. (It also builds every push to `main` that changes more than docs, kept as a
   downloadable artifact on the run; `.github/package.sh X.Y.Z` makes the same files locally, in `dist/`.)
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
   (see Updates in the [guide](GUIDE.md)). `brew test` still runs by hand.
