# Clipd design

A macOS clipboard history manager for personal use across two MacBooks.
Modelled on Paste (pasteapp.io).

Date: 2026-08-15
Status: design approved in conversation, spec awaiting review

```
Tier: Personal        # not B2B-SaaS, not Regulated. One user, no accounts.
Compute: none         # local Mac app. v1.1 adds Cloudflare R2 as dumb storage.
```

## 1. What it is

A menu bar app that records everything you copy, lets you search that history,
and pastes a chosen item back into the app you were just using.

**v1 is local only.** Sync between the two MacBooks ships in v1.1, but the
schema is built for it from the first line so there is no migration.

### v1 scope

- Menu bar only, no Dock icon
- Captures text and images, with the source app and, where available, source URL
- Local encrypted database, full text search
- Cmd+Shift+V opens a bottom bar, type to filter, Enter pastes into the previous app
- Pinboards for categorising items
- Retention setting: Day, Week, Month, Year, Forever
- Privacy filters so passwords are never stored

### Explicitly not in v1

Sync, link previews, Paste Stack, Quick Paste 1-9, sound effects, plain text
paste mode, iCloud anything.

### Why iCloud is impossible

The account is a free Apple account. CloudKit requires a paid membership. This
is settled, not a preference. Sync is Cloudflare R2 and nothing else, and there
is no backend picker in settings.

## 2. What was measured before this design existed

Per `08-the-next-app.md`, every risky platform assumption was proved with a
throwaway probe before any of this was written. Full results are in `NOTES.md`.
The summary matters because two assumptions were **false**, and both would have
caused real damage.

| # | Assumption | Result |
|---|---|---|
| A1 | Polling `changeCount` is cheap | Pass. 0.0% CPU, flat 9.1 MB at 200ms |
| A2 | Synthetic Cmd+V pastes into another app | Pass, verified by reading the target document back |
| A3 | Panel takes typing then returns focus | Pass. Key within 10ms. Activation is asynchronous |
| A4 | Cmd+Shift+V captured globally without leaking | Pass. Poison-string test, twice |
| A5 | Source app is detectable | Pass, including on a real password copy |
| A6 | Password managers mark their copies | **FALSE for Apple.** See section 5 |
| A7 | Images are a manageable size | Pass. PNG at 2.8 MB, not raw TIFF |
| A8 | Works over a fullscreen app | Pass. **Second display untested** |
| A9 | Permission survives a rebuild | **FALSE under ad-hoc signing.** See section 8 |
| A10 | macOS 26 allows clipboard reads | Pass. No prompt, no entitlement |
| A11 | Focus restore before paste | Pass at 0ms, guard retained anyway |
| - | Whole interaction end to end | Pass |

Two behaviours nobody would have designed for also turned up:

- A password manager clearing the clipboard produces a change carrying **zero
  items**, attributed to whatever app happened to be frontmost.
- **Two apps can hold the same global hotkey and both receive it.** Since the
  real Paste app is installed on this machine, both will open on Cmd+Shift+V
  until Paste is quit.

### Still unproven

- **A8 on a second display.** Only the built-in display was ever attached. Must
  be hand tested before this is claimed to work.
- Whether 1Password sets the concealed marker. Bitwarden does; 1Password is
  assumed to and is deny-listed regardless, so nothing depends on it.

## 3. Shape

One SwiftPM package plus XcodeGen. `.xcodeproj` and generated `Info.plist` are
gitignored and regenerated with `xcodegen generate`.

```
clipd/
  Package.swift          SwiftPM: ClipdCore + tests
  project.yml            XcodeGen: one Mac app target
  Sources/ClipdCore/     every decision. No AppKit anywhere.
  Tests/ClipdCoreTests/  swift-testing. No app, no permissions, no simulator.
  ClipdMac/              thin shell that touches macOS
  ClipdMacTests/         XCTest
  app                    one bash script for every command
```

**The core contains no platform types.** This is the highest value decision in
the layout. Every question of the form "should this be saved" must be answerable
in a plain function with no clipboard, no permissions and no running app.

### ClipdCore (pure)

| Type | Responsibility |
|---|---|
| `ClipboardItem` | The record. UUID, kind, timestamps, tombstone, device id |
| `CaptureDecision` | Given types, source bundle and settings, returns store or refuse **with a reason** |
| `RetentionPolicy` | Given items, a setting and a clock, returns what to delete |
| `SearchQuery` | Parsing and matching rules |
| `SyncMerge` | Last-writer-wins and tombstone rules. Written in v1, used in v1.1 |
| `Store` | Protocol. The database implements it; tests use an in-memory fake |

`CaptureDecision` is where a bug leaks passwords, so it is the most heavily
tested type in the project, and it is testable with no password manager present.

### ClipdMac (thin shell)

| Type | Responsibility |
|---|---|
| `PasteboardWatcher` | 200ms poll, produces a snapshot, decides nothing |
| `Paster` | The CGEvent Cmd+V, exactly as probed |
| `HotKey` | Carbon `RegisterEventHotKey` |
| `PanelController` | The NSPanel, strategy 1 as measured |
| `StatusItemController` | Menu bar icon and menu |

## 4. Data model

Every table carries the same four sync columns, in v1, even though nothing
syncs yet.

```sql
items
  id              TEXT PK      -- UUID, stable across both Macs
  kind            TEXT         -- text | image
  created_at      INTEGER      -- unix ms, when copied
  updated_at      INTEGER      -- sync clock, last writer wins
  deleted_at      INTEGER NULL -- tombstone. Never a hard row delete
  device_id       TEXT         -- which Mac last wrote this row
  source_bundle   TEXT NULL    -- com.google.Chrome
  source_name     TEXT NULL    -- "Google Chrome"
  source_url      TEXT NULL    -- from org.chromium.source-url
  html            TEXT NULL    -- public.html when present
  content_hash    TEXT         -- dedup
  text_content    TEXT NULL    -- searchable text
  preview         TEXT         -- what the card shows
  char_count      INTEGER NULL
  px_width        INTEGER NULL
  px_height       INTEGER NULL
  blob_ref        TEXT NULL    -- filename for image payloads
  pinned          INTEGER

pinboards        id, name, color, sort_order + the same 4 sync columns
item_pinboards   item_id, pinboard_id       + the same 4 sync columns
```

Plus an FTS5 virtual table over `text_content` and `preview`.

`device_id` is a UUID generated once on first launch and stored in
`UserDefaults`. It identifies the Mac, not the user, and never leaves the
device in v1.

**Search in v1 is plain token matching, no query operators.** Typing `aws ecs`
matches items containing both tokens, in any order, case insensitive. No `AND`,
`OR`, quoting or field prefixes. Results are ordered newest first, not by
relevance rank, because a clipboard history is a timeline and the thing you want
is usually recent. Rejected: relevance ranking, which buries the item you copied
30 seconds ago under an old better-matching one.

Three deliberate choices, each with the rejected option recorded:

- **Tombstones, never hard deletes.** Rejected: deleting rows outright. Without
  tombstones a delete on Mac A is resurrected by Mac B on the next sync. That
  bug is invisible until it happens.
- **`item_pinboards` is a real table, not an array on the item.** Rejected:
  storing pinboard ids as a JSON column. Two Macs filing the same item into two
  different Pinboards must merge to both, not fight.
- **Two kinds only, text and image.** Rejected: separate `link`, `richtext` and
  `file` kinds. A link is text with a `source_url`. A file is text that is a
  path. Rich text is text with `html`. Three fewer code paths, identical
  behaviour on screen.

### Storage layout

```
~/Library/Application Support/Clipd/
  clipd.sqlite          SQLCipher. Key in the macOS Keychain.
  blobs/<uuid>.enc      image payload, AES-GCM, same key
  blobs/<uuid>.thumb    card thumbnail, also encrypted
```

Images live on disk, not in the database, because A7 measured them arriving as
already-compressed PNG at around 2.8 MB. The database holds a path and
dimensions.

**Blobs are encrypted too.** An unencrypted screenshot folder beside an
encrypted database would be a pointless gap, and a screenshot of a password
manager or a bank page is exactly what lands there.

## 5. Privacy: how passwords are kept out

This is the part that must not be got wrong, and the naive version was measured
to be broken.

**Apple's Passwords.app sets no marker at all.** Verified at both pasteboard and
item level on a real password copy: a 20 byte `public.utf8-plain-text` and
nothing else. No `ConcealedType`, no `TransientType`, no `source`. A password is
indistinguishable from any other short text copy.

**Bitwarden does set `org.nspasteboard.ConcealedType`.** So the convention is
honoured by third parties and ignored by Apple.

Reasoning alone would have got this wrong. The convention is real and
documented, and a shipping competitor advertises the feature.

### Four independent layers

| Layer | Catches | Evidence |
|---|---|---|
| 0. `ConcealedType` / `TransientType` / `AutoGeneratedType` | Bitwarden, 1Password, other third parties | Measured. Bitwarden marks |
| 1. App deny-list by bundle id | Passwords.app, Keychain Access, anything Apple | Measured. Source app reported correctly |
| 2. Auto-clear tombstone | Managers not on the deny-list | Measured. Zero false positives in 390s |
| 3. Encrypted database and blobs | Limits damage from anything that slips through | Standard practice |

Deny-list ships pre-populated with `com.apple.Passwords`,
`com.apple.keychainaccess`, `com.bitwarden.desktop`,
`com.1password.1password`. Any captured item offers a one-click "never save from
this app".

### The auto-clear rule

Measured behaviour: Passwords.app wipes the clipboard 60.0s and 60.9s after a
copy, in two independent runs. Bitwarden does not clear at all. Across 390
seconds of ordinary use there was exactly one clear, and it followed a password
manager. **No false positives.**

Rule: if the clipboard goes to zero items within 90 seconds of an item being
captured, that item is deleted retroactively. For this case the payload is
**hard deleted**, leaving a tombstone with no content. A secret caught late must
not survive in a soft-deleted row and must never be shipped to R2.

**90 seconds, not 60**, because the two measurements were 60.0s and 60.9s and a
timer that fires "about a minute later" should not be treated as exact. The
window only needs to be wide enough to catch the clear and narrow enough that an
unrelated clear does not delete a wanted item. No unrelated clear was observed
at all, so the margin is cheap.

Only the **single most recent item** is eligible. A clear does not delete a
batch.

The rule is a settings toggle, defaulting on.

### The hole, stated plainly

**Copying a password out of Chrome's or Safari's built-in password manager
defeats layers 0, 1 and 2.** The source app is the browser, which cannot be
deny-listed. No marker is set. Nothing gets cleared.

Only layer 3 and a fast manual "delete and forget" cover it. This case must not
be described as protected, in the UI or anywhere else.

### Content heuristics: rejected

Detecting password-shaped strings was considered and rejected. It would refuse
to save API keys, tokens and random identifiers that the user wants. For a
personal tool a silent refusal is worse than the risk it removes.

### Logging

**The app never writes clipboard values to any log.** Diagnostic output carries
types, sizes and flags only. During probing a probe printed a 40 character text
preview and wrote a real password into a log file, which had to be shredded.

## 6. Capture pipeline

1. `changeCount` moves. 200ms poll, measured at 0.0% CPU.
2. **Zero items? Stop.** Never store, never record a source app. This is the
   auto-clear, measured being attributed to Terminal, an innocent bystander.
3. Read types and frontmost app.
4. `CaptureDecision` runs layers 0 and 1 and returns a **reason**, not a
   boolean. "Why was this not saved" has at least four answers and the settings
   screen has to be able to tell them apart. This is rule 4 of `08`: when a
   failure has several causes, ship the readout.
5. Hash the content. If it matches the newest item, bump `updated_at` instead of
   inserting.
6. Write.

Size cap per item, configurable, defaulting to 10 MB. Anything larger is
refused with a reason.

## 7. Interaction

1. Cmd+Shift+V. Carbon `RegisterEventHotKey`, needs no Accessibility permission
   and does not leak to the app underneath.
2. Record frontmost app, activate, show the panel at the bottom of the screen.
3. Type to filter. FTS5 over text and preview.
4. Enter: hide panel, restore focus, **wait until the previous app is really
   frontmost**, then post Cmd+V.
5. Escape: close and restore focus, no paste.

The wait in step 4 is retained even though it measured 0ms. A slow or busy app
is exactly the case that would post Cmd+V into the wrong window, and that
failure is indistinguishable from "paste does not work at all".

Panel requirements, all measured:

- `NSPanel` subclass overriding `canBecomeKey` to true. A borderless panel
  refuses key by default and the search field then silently receives nothing.
- `level = .screenSaver` and
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`
  for the fullscreen case.
- `setActivationPolicy(.accessory)`.
- **Never read `isKeyWindow` in the same runloop turn as `makeKeyAndOrderFront`.**
  Activation is asynchronous. Doing so produced a convincing false failure
  during probing.

### Settings

Four panes, nothing more.

- **General**: open at login, retention slider, erase history
- **Privacy**: ignored apps, auto-clear toggle
- **Shortcuts**: activation hotkey, rebindable
- **Sync**: empty in v1

### Retention

Runs at launch and hourly. Day, Week, Month, Year, Forever. **Pinned items and
anything filed on a Pinboard are exempt**, otherwise a one week setting quietly
eats the snippets that were deliberately kept.

Retention writes a tombstone and **deletes the blob file from disk**. A
tombstone that leaves a 2.8 MB encrypted screenshot behind is not a delete.

"Erase History" in settings does the same for everything: tombstones every row
and removes every blob. It does not delete Pinboards themselves, only their
contents.

### Making silent failure loud

Without Accessibility, Clipd cannot paste and macOS reports nothing. The panel
shows a large banner saying paste is disabled and why, and the menu bar icon
changes. It deliberately contradicts every other success signal on screen.

The same treatment applies when another app holds the activation hotkey, since
we measured that two apps can both receive it.

## 8. Build and signing

**Sign with the Apple Development certificate, never ad-hoc.**

Measured: under ad-hoc signing the CDHash changes on every build and macOS drops
the Accessibility permission with it. The app then looks healthy and pastes
nothing. Signing with the certificate the free account already provides gives a
designated requirement of identifier plus certificate, with no CDHash in it.
Confirmed twice, including by building a different program into the same
identity and having it trusted with no new grant.

`09-starting-a-new-app.md` recommends `CODE_SIGN_IDENTITY: "-"` so a project
builds for anyone who clones it. **For this app that default is actively
harmful**, and `project.yml` must carry a comment saying why.

Operational note: `tccutil reset Accessibility <bundle-id>` clears a stale
permission entry without touching System Settings. Needed when the signing
identity changes, because the old row stays in the list, still switched on, and
no longer matches.

Install to `/Applications` and launch from there, never from the build folder.

## 9. Sync, v1.1

Not built in v1. Recorded here so v1 does not paint it into a corner.

- **Cloudflare R2**, one bucket, an API token scoped to that bucket with object
  read and write only.
- **Payload encrypted before it leaves the Mac**, key derived from a user
  passphrase and held in the Keychain. R2 stores ciphertext it cannot read, so a
  leaked token exposes nothing useful.
- **Credentials entered in the Sync settings pane and stored in the Keychain.**
  Never in code, never in a committed file. Local development uses a gitignored
  `.env.local` and a throwaway bucket.
- Merge rule: last writer wins per row, using `updated_at` and `device_id`.
  Tombstones always win over content of an older timestamp.
- Items hard-deleted by the auto-clear rule must never be uploaded.

## 10. Testing

- **Core is tested exhaustively** and runs with no app, no permissions and no
  simulator. `CaptureDecision` and `SyncMerge` get the heaviest coverage.
- **Test the shape a hand makes.** For retention and merge, include degenerate
  cases: equal timestamps, a tombstone and an edit at the same millisecond, an
  empty history, a clock that went backwards.
- **Read the test count on every run.** A falling count means tests were
  deleted, not that they passed.
- **Anything crossing a boundary is hand tested**, and "the suite is green" is
  treated as necessary rather than sufficient. That means: the paste path, the
  hotkey, the panel over a fullscreen app, and the panel on a second display.

## 11. Build order

v1 is more than one sitting of work, and `08` rule 9 is explicit that one end to
end path on real hardware comes early, even if ugly. The implementation plan
should follow this order.

1. **Scaffold.** Package, `project.yml`, `./app` script signing with the Apple
   Development identity, private GitHub repo with the remote added **before the
   first commit**. Verify `swift test` and `./app up` both work.
2. **Walking skeleton.** Menu bar icon, hotkey, panel, capture into an in-memory
   list, paste back. No database, no search, no settings. This is the path the
   probes proved, and getting it running as the real app early is what flushes
   out signing and permission problems while they are still cheap.
3. **Core, with tests.** `ClipboardItem`, `CaptureDecision`, `RetentionPolicy`,
   `SearchQuery`, `SyncMerge`. Pure, fast, no app. This is where the thinking is.
4. **Storage.** SQLCipher, blobs, FTS5, migrations. Swap the in-memory list for
   the real store.
5. **Search and the card UI.**
6. **Pinboards.**
7. **Settings, all four panes**, including the loud Accessibility banner.
8. **Hand test the boundaries**: paste into several real apps, the panel over a
   fullscreen app, the panel on a second display, a real password copy from
   Passwords.app and from Bitwarden.

Step 2 before step 3 is deliberate. It is tempting to build the well-tested pure
core first because it is pleasant, but the platform risks all live in the shell,
and this project has already found two false assumptions there.

## 12. Open questions

1. **A8 on a second display.** Unproven. Hand test before claiming it works.
2. **Coexistence with the real Paste app.** Both hold Cmd+Shift+V. Decide
   whether Clipd detects this and warns, or simply documents it.
