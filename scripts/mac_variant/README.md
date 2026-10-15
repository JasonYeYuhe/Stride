# mac_variant — a StrideMac that cannot touch the real store

`build.sh` builds StrideMac Debug (or Release, with `--release`) as
**`yyh.stride.habittracker.mactest`**, ad-hoc signed, with the compile-time flag
`STRIDE_MAC_VARIANT`. It is how the macOS half of a release is checked by an agent on this Mac
(RELEASE-1.4.0.md D7): the menu commands, Settings, the Dock badge, Restore's open panel, Export's
save panels, Mark Done on a Mac banner, and the Mac store screenshots. The Release variant is the
Release-build smoke and the production sign-in check (RELEASE-1.4.1.md gate 12, P1 step 6); see
[Release](#release---release).

**This Mac holds the owner's real Stride store**, at
`~/Library/Group Containers/group.yyh.stride.habittracker/Stride.store`. Never launch the shipping
StrideMac (`yyh.stride.habittracker`) here, never `open -a Stride`, and never launch the variant
before its preflight has passed.

## Why it is built this way

- **Dropping the App Group is not enough on macOS.** `containerURL(forSecurityApplicationGroupIdentifier:)`
  is never nil there (MacOSX SDK `NSFileManager.h:993`), entitled or not, so a plain re-signed build
  still resolves the real store. Sandboxed it is denied and shows the store error screen;
  unsandboxed it opens and migrates the owner's data, and a DEBUG `-demo` launch erases it.
- **So the variant is decided at compile time.** Under `STRIDE_MAC_VARIANT` (code in `Shared/` and
  `Stride/Sources`):
  - the store location is forced to `.noAppGroup` (`Documents/Stride.store` in the variant's own
    sandbox container);
  - App Group defaults and the deletion queue's suite resolve inside the variant;
  - the keychain service is the bundle id;
  - Sentry is off;
  - launch preconditions: sandboxed (`APP_SANDBOX_CONTAINER_ID`), store under `NSHomeDirectory()`,
    bundle id ≠ `yyh.stride.habittracker`.

  `build.sh` refuses to build when `Shared/SharedModelContainer.swift` has no
  `#if STRIDE_MAC_VARIANT` branch.
- **Entitlements generated from the shipping file.** `StrideMac/StrideMac.entitlements` is copied
  and `com.apple.security.application-groups` and `com.apple.developer.associated-domains` are
  deleted with PlistBuddy. The build fails if any `com.apple.developer.*` key remains: an ad-hoc
  binary has no provisioning profile, and AMFI refuses to launch one that carries such a key. A
  hand-written file would hold `files.user-selected.read-write` whether or not the shipping file
  does, and the panel checks exist to prove the shipping file's (1.3.0 and 1.3.1 shipped without
  it: no open or save panel in the sandbox).
- **Command-line settings only.** No project.yml target: no XcodeGen drift, no CI target, and the
  shipping app cannot compile the variant branch. The settings:

  ```
  PRODUCT_BUNDLE_IDENTIFIER=yyh.stride.habittracker.mactest
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) STRIDE_MAC_VARIANT'
  CODE_SIGN_IDENTITY=-  CODE_SIGN_STYLE=Manual  DEVELOPMENT_TEAM=  PROVISIONING_PROFILE_SPECIFIER=
  CODE_SIGN_ENTITLEMENTS=<root>/StrideMacVariant.entitlements
  ```

  `PRODUCT_NAME` stays `Stride`. Before building, `xcodebuild -showBuildSettings` is read back and
  the build stops unless StrideMac resolves to the variant id, `PRODUCT_NAME` Stride, both `DEBUG`
  and `STRIDE_MAC_VARIANT`, and the generated entitlements.
- Ad-hoc signing needs no keychain, so the build works with the screen locked.

## Use

```bash
scripts/mac_variant/build.sh                       # build + preflight; prints the launch commands
scripts/mac_variant/build.sh --release             # the same, Release configuration (below)
scripts/mac_variant/build.sh --entitlements-only   # just generate and check the entitlements
scripts/mac_variant/build.sh --preflight [<app>]   # re-check a built variant before launching it
scripts/mac_variant/build.sh --preflight --release # re-check the Release variant
```

Everything goes under `$STRIDE_MAC_VARIANT_ROOT` (default
`~/Library/Caches/Stride-build/mac-variant`, persistent so a rebuild is incremental; a root under
`~/Documents` is refused): the entitlements, `DerivedData/`, `build.log`, `build-settings.txt`.
The app is `<root>/DerivedData/Build/Products/Debug/Stride.app`. Extra arguments go to
xcodebuild. Swift packages come from the shared checkout (`scripts/ci/build_cache.sh`), and two
builds into one root wait for each other. A build that must outlive the next one, such as the old
version of the Mac in-place upgrade gate, gets its own root
(`STRIDE_MAC_VARIANT_ROOT=~/Library/Caches/Stride-build/mac-variant-1.4.0`). The default was
`${TMPDIR}stride-mac-variant` until 1.4.1; macOS purges `$TMPDIR` on low disk.

**Preflight** (after every build, and on `--preflight`); a failure means do not launch:

- `Info.plist` `CFBundleIdentifier` and `codesign -dv`'s `Identifier=` are the variant id, and the
  signature is ad-hoc;
- `codesign -d --entitlements -` shows no App Group and no `com.apple.developer.*` key, and shows
  `com.apple.security.app-sandbox`;
- `files.user-selected.read-write` is reported. Missing is a warning, not a failure: the variant
  then shows the shipped panel bug, which is what the panel checks are for;
- the server the build talks to, read from the binary (the executable and, in Debug,
  `Stride.debug.dylib`): Debug must hold `http://localhost:3002`, and a Debug preflight of a build
  that holds the production URL instead fails. The Release checks are below.

**Launch** only by path or bundle id:

```bash
open "<root>/DerivedData/Build/Products/Debug/Stride.app"            # or: open -b yyh.stride.habittracker.mactest
open "<root>/DerivedData/Build/Products/Debug/Stride.app" --args -tab 2
```

**Right after the first launch, before any UI action and before any `-demo`:**

```bash
log show --last 5m --style compact \
  --predicate 'subsystem == "yyh.stride.habittracker" AND category == "ModelContainer"' | grep 'outside the App Group'
#   → "Store opened by the app, outside the App Group"
ls -la ~/Library/Containers/yyh.stride.habittracker.mactest/Data/Documents/
#   → Stride.store (+ -wal, -shm), here and only here
ls -la ~/Library/Group\ Containers/group.yyh.stride.habittracker/
#   → unchanged: no new file, the real Stride.store's modification time untouched
```

Anything else (no log line, an App Group path, the store error screen): quit the variant and stop.

## Release (`--release`)

For RELEASE-1.4.1.md gate 12 (a Release-configuration variant launches and passes the store
preflight) and P1 step 6 (sign in on the Mac by token paste). Never the exported real-id app.

```bash
scripts/mac_variant/build.sh --release COMPILER_INDEX_STORE_ENABLE=NO
#   → ~/Library/Caches/Stride-build/mac-variant-release/DerivedData/Build/Products/Release/Stride.app
scripts/mac_variant/build.sh --preflight --release
```

**Unchanged from Debug:** the variant id, `STRIDE_MAC_VARIANT` (it is the flag, not `DEBUG`, that
forces the store into the variant's container, gives the Keychain its own service and keeps
Sentry off), ad-hoc signing with the generated entitlements, the launch check
(`MacVariantLaunchCheck.enforce()` is a `precondition`, which `-O` keeps), and every preflight
check above. The launch and the first-launch checks are the same.

**What Release changes, and what the build and the preflight check:**

- `DEBUG` is not defined. The settings check requires it absent and the optimization not
  `-Onone`. The preflight requires no `Stride.debug.dylib` and no DEBUG-only code in the binary
  (the text of `LaunchWindowSize`'s messages; launch flags such as `-demo` are too short to find
  as text, because Swift keeps literals of up to 15 bytes inside the instructions). So `-demo`,
  `-demoScenario`, `-paywall`, `-statsScrollTo`, `-scrollTo`, `-syncStatus` and `-windowSize` do
  nothing: no demo data and no screenshot frame. Screenshots come from the Debug variant. `-tab`
  works in every build.
- **It is a production client.** `APIClient.defaultBaseURL` is
  `https://stride-api.colorarchive.me` in every non-DEBUG build (APIClient.swift:7-11), and the
  preflight requires that URL in the binary and `http://localhost:3002` absent. Every sign-in
  creates or uses a real account, so (RELEASE-1.4.1.md decision 4):
  - sign in only with the owner's plus-address `<owner>+stride-smoke@gmail.com`, by token paste
    (the variant has no associated domains, so a universal link opens nothing); never the owner's
    primary address, never the demo account;
  - before any `delete-account`, `GET /v1/auth/session` with the same token, and delete only if
    `user.email` is exactly that address;
  - at most one `request-link` per sitting: 3 per 15 min per IP, shared with every device and
    curl on this network. A 429 means wait.
- Its default root is its own, `~/Library/Caches/Stride-build/mac-variant-release` (persistent,
  like the Debug root), so neither configuration makes the other's next build cold.
  `STRIDE_MAC_VARIANT_ROOT` overrides it as for Debug.
- **Both variants have the same bundle id.** While a Debug and a Release variant are both built,
  `open -b yyh.stride.habittracker.mactest` (this README's screenshot recipe included) may start
  either one, and the Release one is a production client. Launch by path then. Both also share
  one container, `~/Library/Containers/yyh.stride.habittracker.mactest/`, so the same store,
  defaults and Keychain service: a session signed in on one is signed in on the other, and a
  Debug session check against the local server answers no user and deletes a production token.
  Sign out before switching configurations.
- `-configuration` is refused as an extra argument: Debug, or `--release`.

## The computer-use pass (RELEASE-1.4.0.md D7)

In the variant, after the checks above:

- ⌘, opens Settings; the sidebar has no Settings row;
- one toolbar per tab, nothing merged; `--args -tab 2`;
- every menu item and shortcut, including Weekly Review (⇧⌘R) before Stats was ever opened;
- an empty-area click and a ⌘-click on the sidebar: the selection stays;
- Settings open with the main window closed, then the Dock icon and Window → Stride;
- the Dock badge, after allowing notifications in the variant's own prompt (its own bundle id,
  so its own permission);
- Restore's open panel, and Export's save panels;
- Mark Done on a Mac banner, once with the app running and once with it quit.

## Store screenshots

The Mac App Store slot (`APP_DESKTOP`) takes only exact 16:10 sizes: 1280×800, 1440×900,
2560×1600 or 2880×1800. Capture the variant's window sized to one of them, into a fresh
`build/store-screenshots/<version>/mac/`, with no widget slide (the Mac has no widgets).
`scripts/store_screenshots.py` uploads them.

**Size the window** with the DEBUG launch flag `-windowSize <W>x<H>` (RELEASE-1.4.1.md W0;
`LaunchWindowSize` in StrideApp.swift). It sets the main window's frame, title bar included, in
points, once per process, so a 1440×900 frame on a 2x display (the owner's 4K display at 2x) is
the 2880×1800 the slot takes. It exists only in DEBUG builds, which the variant always is, and
iOS ignores it. `--args` reach only a new process, so quit a running variant first:

```bash
osascript -e 'if application id "yyh.stride.habittracker.mactest" is running then tell application id "yyh.stride.habittracker.mactest" to quit'
open -b yyh.stride.habittracker.mactest --args -windowSize 1440x900   # by bundle id, never -a Stride
```

**Capture** with `capture.sh`. It launches, activates and quits nothing. It finds the variant by
bundle id and its window by that process's PID, never by the name "Stride".

```bash
scripts/mac_variant/capture.sh --list                     # what it would capture; no capture
scripts/mac_variant/capture.sh build/store-screenshots/1.4.1/mac/01-today.png
scripts/mac_variant/capture.sh --size 2560x1600 <out.png> # another APP_DESKTOP size
scripts/mac_variant/capture.sh --window-id <id> <out.png> # not the largest window (see --list)
scripts/mac_variant/capture.sh --force <out.png>          # replace an existing file
```

Before it captures, it checks:

- exactly one variant instance is running;
- nothing runs as the real `yyh.stride.habittracker`;
- the variant is the frontmost app, so the window has active chrome.

Then it runs `screencapture -x -o -l <window id>`, where `-o` drops the shadow so the image is the
window's frame exactly. It keeps the capture only if:

- the image is not blank (nearly all transparent, or one colour);
- it is exactly 2880×1800 px (`sips`), or the `--size` given.

A rejected capture stays in a temp directory, whose path is printed. Exit status: 0 captured,
1 failed or blank, 2 usage, 3 not running or no on-screen window, 4 refused, 5 wrong size.

**Screen Recording.** A blank or failed capture almost always means the app running the script
(Terminal, iTerm or the Claude app) has no Screen Recording permission. `capture.sh` prints how
to grant it: System Settings → Privacy & Security → Screen & System Audio Recording, then
relaunch that app. The owner grants it for the sitting and revokes it afterwards
(RELEASE-1.4.1.md P3b).

## Cleaning up

- Quit the variant (⌘Q, or `osascript -e 'tell application id "yyh.stride.habittracker.mactest" to quit'`).
- Leave the default roots in place (`mac-variant` and `mac-variant-release`): the next build
  reuses them. Trash a root of its own (an upgrade gate's old version) when that release ships.
- After a Release sitting, sign the variant out, and delete the plus-address account as above if
  the step calls for it.
- The variant's data lives in `~/Library/Containers/yyh.stride.habittracker.mactest/`. It is test
  data, but leave it to the owner to remove: macOS protects other apps' containers.
