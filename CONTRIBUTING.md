# Contributing to Clipd

Contributions are welcome. A typo fix is as useful as a feature.

## Before you start something large

Open an issue first and describe what you want to change. Clipd is a small app
with strong opinions about where code goes, and it is much nicer to agree on the
shape of a change before you write it than to ask you to move it afterwards.

Small fixes need no issue. Send the pull request.

## Getting set up

```sh
git clone https://github.com/hengkysandy/clipd.git
cd clipd
brew install xcodegen

security find-identity -v -p codesigning
echo 'Apple Development: you@example.com (TEAMID)' > .app-signing

./app up      # build, install to /Applications, launch
./app test    # both test suites
```

You need Xcode 26 or later and macOS 15 or later. A free Apple account is
enough. `.app-signing` is gitignored, so your identity never leaves your Mac.

If the app runs but nothing pastes, the cause is almost always the Accessibility
permission rather than your code. `./app sig` checks the signature is
rebuild-safe, and `./app trust` clears a stale grant so you can grant it again.

## The one rule about layout

**`Sources/ClipdCore` must not import AppKit, or anything else from the
platform.** It is plain Swift with plain functions.

Everything that decides something lives there: what gets captured, what gets
deleted, how two Macs merge, how a language is detected. Everything that touches
macOS lives in `ClipdMac` and decides nothing.

This is what makes the interesting parts testable with no running app, no
permissions and no password manager present. `swift test` runs the whole core
suite in a couple of seconds. If a change puts a decision in `ClipdMac`, it has
become untestable, and it will be asked to move.

## Tests

A change is not finished until its tests are.

- Anything that decides what gets stored, or what gets deleted, needs tests.
  `CaptureDecision` is where a bug leaks a password, so it is the most heavily
  tested type in the project. Keep it that way.
- Anything touching sync needs tests. Most of the real bugs found so far lived
  in the interaction between two features, not inside either one, and unit tests
  of each piece alone did not reach them. `ClipdMacTests/TwoDeviceDedupTests.swift`
  is the pattern: run two stores, sync them, and assert they agree.
- Core tests use swift-testing (`import Testing`, `@Test`, `#expect`). Shell
  tests use XCTest.

Sync tests that talk to a real bucket read credentials from a gitignored
`.env.local` and are skipped when it is absent, so you can work on everything
else without an R2 account. **Never point a test at the `items/` or
`manifests/` prefixes.** Test objects go under `clipd-tests/<uuid>/`.

## Things that will be asked for in review

- **Say why, not what.** The comments in this codebase explain rejected options
  and measured results, because those are the things a reader cannot recover
  from the code. Comments that restate the line above them get deleted.
- **No em-dashes** in code, comments, commit messages or documentation. A comma,
  a colon or a full stop instead.
- **Never log a clipboard value.** Kinds, sizes, counts and reasons only. The
  same goes for anything you paste into an issue.
- **No secrets in the repo**, including in test fixtures.
- Swift 6 strict concurrency is on. Please do not turn it off to make a warning
  go away.

## Reporting a security issue

Do not open a public issue for a security problem.

Use GitHub's private vulnerability reporting on this repository: go to the
**Security** tab and choose **Report a vulnerability**. That opens a private
thread with the maintainer.

Clipd holds whatever the user copied, which for many people includes passwords,
tokens and private keys. A bug that lets any of that escape the encrypted
database, reach a log, or leave the machine unencrypted is treated as serious
even if it looks hard to trigger.
