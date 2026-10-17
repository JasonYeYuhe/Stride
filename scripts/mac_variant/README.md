# mac_variant — a StrideMac that cannot touch the real store

`build.sh` builds StrideMac Debug as **`yyh.stride.habittracker.mactest`**, ad-hoc signed, with
the compile-time flag `STRIDE_MAC_VARIANT`. It is how the macOS half of a release is checked by an
agent on this Mac (RELEASE-1.4.0.md D7): the menu commands, Settings, the Dock badge, Restore's
open panel, Export's save panels, Mark Done on a Mac banner, and the Mac store screenshots.

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
scripts/mac_variant/build.sh --entitlements-only   # just generate and check the entitlements
scripts/mac_variant/build.sh --preflight [<app>]   # re-check a built variant before launching it
```

Everything goes under `$STRIDE_MAC_VARIANT_ROOT` (default `${TMPDIR}stride-mac-variant`; a root
under `~/Documents` is refused): the entitlements, `DerivedData/`, `build.log`,
`build-settings.txt`. The app is `<root>/DerivedData/Build/Products/Debug/Stride.app`. Extra
arguments go to xcodebuild.

**Preflight** (after every build, and on `--preflight`); a failure means do not launch:

- `Info.plist` `CFBundleIdentifier` and `codesign -dv`'s `Identifier=` are the variant id, and the
  signature is ad-hoc;
- `codesign -d --entitlements -` shows no App Group and no `com.apple.developer.*` key, and shows
  `com.apple.security.app-sandbox`;
- `files.user-selected.read-write` is reported. Missing is a warning, not a failure: the variant
  then shows the shipped panel bug, which is what the panel checks are for.

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
2560×1600 or 2880×1800. Capture the variant's window (`screencapture -o -l <window id>`) sized to
one of them, into a fresh `build/store-screenshots/<version>/mac/`, with no widget slide (the Mac
has no widgets). `scripts/store_screenshots.py` uploads them.

## Cleaning up

- Quit the variant (⌘Q, or `osascript -e 'tell application id "yyh.stride.habittracker.mactest" to quit'`).
- `/usr/bin/trash "$STRIDE_MAC_VARIANT_ROOT"` (or `${TMPDIR}stride-mac-variant`) when the build is no
  longer needed.
- The variant's data lives in `~/Library/Containers/yyh.stride.habittracker.mactest/`. It is test
  data, but leave it to the owner to remove: macOS protects other apps' containers.
