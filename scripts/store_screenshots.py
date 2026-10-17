#!/usr/bin/env python3
"""Read and replace App Store screenshots for ONE version on ONE platform, nothing else.

    scripts/store_screenshots.py list   --platform IOS|MAC_OS --version 1.4.0 [--locale L ...]
    scripts/store_screenshots.py upload --platform IOS --version 1.4.0 \\
        --set APP_IPHONE_67 build/store-screenshots/1.4.0/iphone67/01.png 02.png 03.png \\
        [--set APP_IPAD_PRO_3GEN_129 ...] [--locale en-US ...] [--yes]

`list` is read-only: every locale's appScreenshotSets for that version, with each set's
screenshotDisplayType and its screenshots' fileName, size and assetDeliveryState. Run it first
(RELEASE-1.4.0.md D8: "Read what is live first"), on the live version and on the new one.

`upload` is a DRY RUN unless --yes is given: it resolves everything, validates every file, reads
what is there and prints what it would do, then stops. With --yes, for each locale given (default
en-US only) and each `--set TYPE FILE...`:
  1. the set of that display type is found, or created when the locale has none;
  2. the new files are uploaded in the order given (reserve, PUT the parts, commit with the MD5),
     and each is polled until its assetDeliveryState is COMPLETE (FAILED stops the run);
  3. only then are the set's OLD screenshots deleted — the ones that were there before this run,
     never one of the new ones — and the set is reordered to the order given.
  When old + new would exceed the 10 a set can hold, the old ones are deleted first instead (and
  printed with their fileNames, so the set can be rebuilt from the capture directory).
Every other display type, every other locale and every other version is never touched.

Why a new uploader (design review store-screenshots-misrepresent-shells, ipad-store-screenshots):
  - update_screenshots.py takes `versions[0]` with no platform filter (with both 1.4.0 records in
    PREPARE_FOR_SUBMISSION it can land on macOS), deletes every screenshot of every set in every
    locale but uploads en-US only, and picks files by substring — re-uploading the April files
    with the false "Upgrade to Pro — Unlimited habits, widgets…" row and the iCloud " 2.png"
    duplicates. Never run it.
  - appstore_metadata.py is the 1.0 setup script: its main() rewrites the app info, the
    subscriptions and every locale's description/keywords/What's New with 1.0 copy, and on iOS
    uploads every PNG in build/ios-screenshots into APP_IPHONE_67. Never run it either.
  This one resolves the version by platform AND versionString, refuses a version whose state
  cannot take edits, takes an explicit file list per display type, checks the files' pixel sizes
  locally, and writes nothing without --yes.

Files: PNG or JPEG, from a fresh capture directory (build/store-screenshots/<version>/…). Refused:
anything under build/ios-screenshots or build/mac-screenshots (the stale April captures and AppKit
mocks), iCloud duplicates ("… 2.png"), duplicate file names within a set, and pixel sizes the
display type does not take (table below; a type not in it is passed to ASC unchecked, with a note).

ASC writes need the owner's approval (they change the store page once the version ships). The
key comes from scripts/.env through scripts/asc_api.py, imported only when ASC is called, so
--help and the local checks need no credentials.
"""

import argparse
import hashlib
import os
import re
import struct
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)

PLATFORMS = ("IOS", "MAC_OS")
# Version states in which screenshots can be edited. Anything else (in review, live, …) is refused.
EDITABLE_STATES = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
                   "INVALID_BINARY"}
# Accepted pixel sizes per display type (portrait and landscape). APP_IPHONE_67 is the 6.7"/6.9"
# slot: the iPhone 17 Pro Max simulator captures 1320×2868. The 13" iPad slot takes the iPad Pro
# 13-inch (M5) simulator's 2064×2752 as it is. APP_DESKTOP is exact 16:10 only.
SIZES = {
    "APP_IPHONE_67": {(1290, 2796), (1320, 2868), (1260, 2736)},
    "APP_IPHONE_65": {(1242, 2688), (1284, 2778)},
    "APP_IPAD_PRO_3GEN_129": {(2048, 2732), (2064, 2752)},
    "APP_IPAD_PRO_129": {(2048, 2732)},
    "APP_DESKTOP": {(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)},
}
SET_LIMIT = 10
POLL_SECONDS = 5
POLL_LIMIT = 120          # × 5 s = 10 min per screenshot
STALE_DIRS = ("build/ios-screenshots", "build/mac-screenshots")


def platform_of(display_type):
    if display_type == "APP_DESKTOP":
        return "MAC_OS"
    if display_type.startswith(("APP_IPHONE_", "APP_IPAD_")):
        return "IOS"
    return None


def image_size(path):
    """(width, height) of a PNG or JPEG, read from its header; None when it is neither."""
    with open(path, "rb") as f:
        head = f.read(32)
        if head[:8] == b"\x89PNG\r\n\x1a\n" and head[12:16] == b"IHDR":
            return struct.unpack(">II", head[16:24])
        if head[:2] != b"\xff\xd8":
            return None
        f.seek(2)
        while True:
            marker = f.read(2)
            if len(marker) < 2 or marker[0] != 0xFF:
                return None
            if marker[1] in (0xD8, 0x01) or 0xD0 <= marker[1] <= 0xD7:
                continue
            length = struct.unpack(">H", f.read(2))[0]
            if 0xC0 <= marker[1] <= 0xCF and marker[1] not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">xHH", f.read(5))
                return (w, h)
            f.seek(length - 2, os.SEEK_CUR)


def check_files(platform, sets):
    """Local validation of every --set; returns a list of problems (empty = fine)."""
    problems, notes, seen_types = [], [], set()
    for display_type, files in sets:
        if not re.fullmatch(r"APP_[A-Z0-9_]+", display_type):
            problems.append(f"{display_type}: not a screenshot display type")
            continue
        if display_type in seen_types:
            problems.append(f"{display_type}: given twice; put all its files in one --set, in order")
        seen_types.add(display_type)
        owner = platform_of(display_type)
        if owner and owner != platform:
            problems.append(f"{display_type} belongs to {owner}, not {platform}")
        if not files:
            problems.append(f"{display_type}: no files")
        if len(files) > SET_LIMIT:
            problems.append(f"{display_type}: {len(files)} files; a set holds at most {SET_LIMIT}")
        names = set()
        for path in files:
            real = os.path.realpath(path)
            name = os.path.basename(path)
            rel = os.path.relpath(real, PROJECT_DIR)
            if not os.path.isfile(real):
                problems.append(f"{path}: no such file")
                continue
            if any(rel == d or rel.startswith(d + os.sep) for d in STALE_DIRS):
                problems.append(f"{path}: from {os.path.dirname(rel)}, the stale pre-1.4.0 captures; capture into build/store-screenshots/<version>/")
            if re.search(r" \d+\.(png|jpe?g)$", name, re.IGNORECASE):
                problems.append(f"{path}: looks like an iCloud duplicate (\"… 2.png\")")
            if name in names:
                problems.append(f"{display_type}: the file name {name} twice")
            names.add(name)
            size = image_size(real)
            if size is None:
                problems.append(f"{path}: not a PNG or JPEG")
            elif display_type in SIZES:
                w, h = size
                if (w, h) not in SIZES[display_type] and (h, w) not in SIZES[display_type]:
                    accepted = ", ".join(f"{a}×{b}" for a, b in sorted(SIZES[display_type]))
                    problems.append(f"{path}: {w}×{h}, but {display_type} takes {accepted}")
        if display_type not in SIZES and owner:
            notes.append(f"{display_type}: no local size table; ASC checks the sizes")
    for n in notes:
        print(f"NOTE: {n}")
    return problems


# ── ASC ─────────────────────────────────────────────────────────────────────────────────────
def asc():
    """scripts/asc_api.py, imported on first use: it reads scripts/.env at import."""
    sys.path.insert(0, SCRIPT_DIR)
    import asc_api
    return asc_api


def asc_delete(a, path):
    import requests
    r = requests.delete(f"{a.BASE_URL}{path}", headers=a.headers())
    if r.status_code not in (200, 204):
        print(f"DELETE {path} failed: {r.status_code} {r.text[:300]}")
        r.raise_for_status()


def resolve_version(a, app_id, platform, version_string):
    d = a.get(f"/apps/{app_id}/appStoreVersions", params={
        "filter[platform]": platform, "filter[versionString]": version_string, "limit": 5,
        "fields[appStoreVersions]": "versionString,platform,appStoreState",
    })
    found = [v for v in d.get("data", [])
             if v["attributes"].get("platform") == platform
             and v["attributes"].get("versionString") == version_string]
    if len(found) != 1:
        raise SystemExit(f"{platform} {version_string}: {len(found)} matching versions; expected exactly one")
    v = found[0]
    print(f"{platform} {version_string}: version {v['id']}, {v['attributes']['appStoreState']}")
    return v


def localizations(a, version_id):
    d = a.get(f"/appStoreVersions/{version_id}/appStoreVersionLocalizations", params={"limit": 50})
    return {l["attributes"]["locale"]: l for l in d.get("data", [])}


def screenshot_sets(a, loc_id):
    d = a.get(f"/appStoreVersionLocalizations/{loc_id}/appScreenshotSets", params={"limit": 50})
    return {s["attributes"]["screenshotDisplayType"]: s for s in d.get("data", [])}


def screenshots(a, set_id):
    d = a.get(f"/appScreenshotSets/{set_id}/appScreenshots", params={"limit": 50})
    return d.get("data", [])


def describe(shot):
    at = shot["attributes"]
    state = (at.get("assetDeliveryState") or {}).get("state", "?")
    img = at.get("imageAsset") or {}
    dims = f"{img.get('width', '?')}×{img.get('height', '?')}" if img else "?"
    return f"{at.get('fileName', '?')} ({dims}, {state})"


def cmd_list(args):
    a = asc()
    app_id = a.find_app()
    v = resolve_version(a, app_id, args.platform, args.version)
    locs = localizations(a, v["id"])
    for locale in sorted(locs):
        if args.locale and locale not in args.locale:
            continue
        sets = screenshot_sets(a, locs[locale]["id"])
        print(f"\n{locale}: {len(sets)} set(s)")
        for display_type in sorted(sets):
            shots = screenshots(a, sets[display_type]["id"])
            print(f"  {display_type}: {len(shots)}")
            for s in shots:
                print(f"    {describe(s)}")
    return 0


def upload_one(a, set_id, path):
    data = open(path, "rb").read()
    name = os.path.basename(path)
    r = a.post("/appScreenshots", {"data": {
        "type": "appScreenshots",
        "attributes": {"fileName": name, "fileSize": len(data)},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}},
    }})
    shot_id = r["data"]["id"]
    import requests
    for op in r["data"]["attributes"].get("uploadOperations") or []:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        hdrs = {h["name"]: h["value"] for h in op.get("requestHeaders") or []}
        resp = requests.request(op["method"], op["url"], headers=hdrs, data=chunk)
        if not resp.ok:
            raise SystemExit(f"{name}: upload part at {op['offset']} failed: {resp.status_code} {resp.text[:200]}")
    a.patch(f"/appScreenshots/{shot_id}", {"data": {
        "type": "appScreenshots", "id": shot_id,
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()},
    }})
    for _ in range(POLL_LIMIT):
        at = a.get(f"/appScreenshots/{shot_id}")["data"]["attributes"]
        state = (at.get("assetDeliveryState") or {}).get("state")
        if state == "COMPLETE":
            print(f"      ✓ {name} COMPLETE")
            return shot_id
        if state == "FAILED":
            errors = (at.get("assetDeliveryState") or {}).get("errors")
            raise SystemExit(f"{name}: assetDeliveryState FAILED: {errors}")
        time.sleep(POLL_SECONDS)
    raise SystemExit(f"{name}: not COMPLETE after {POLL_LIMIT * POLL_SECONDS} s; nothing old was deleted for this set")


def cmd_upload(args):
    sets = [(s[0], s[1:]) for s in args.set]
    problems = check_files(args.platform, sets)
    if problems:
        print("Refused — fix these first:")
        for p in problems:
            print(f"  ✗ {p}")
        return 2
    locales = args.locale or ["en-US"]
    a = asc()
    app_id = a.find_app()
    v = resolve_version(a, app_id, args.platform, args.version)
    state = v["attributes"]["appStoreState"]
    if state not in EDITABLE_STATES:
        print(f"Refused: {args.platform} {args.version} is {state}; screenshots are edited only in {', '.join(sorted(EDITABLE_STATES))}")
        return 2
    locs = localizations(a, v["id"])
    missing = [l for l in locales if l not in locs]
    if missing:
        print(f"Refused: {args.version} has no localization for {', '.join(missing)} (have {', '.join(sorted(locs))}); this never creates one")
        return 2

    plan = []
    for locale in locales:
        existing_sets = screenshot_sets(a, locs[locale]["id"])
        for display_type, files in sets:
            s = existing_sets.get(display_type)
            old = screenshots(a, s["id"]) if s else []
            plan.append((locale, display_type, files, s, old))
            print(f"\n{locale} {display_type}: {'set ' + s['id'] if s else 'no set yet (it would be created)'}")
            for o in old:
                print(f"  - delete  {describe(o)}")
            for f in files:
                print(f"  + upload  {os.path.basename(f)}  ({os.path.relpath(os.path.realpath(f), PROJECT_DIR)})")
            if len(old) + len(files) > SET_LIMIT:
                print(f"  (old + new > {SET_LIMIT}: the old ones would be deleted BEFORE the upload)")
    if not args.yes:
        print("\nDRY RUN — nothing was changed. Re-run with --yes (owner-approved ASC write) to apply.")
        return 0

    for locale, display_type, files, s, old in plan:
        print(f"\n{locale} {display_type}:")
        if s is None:
            r = a.post("/appScreenshotSets", {"data": {
                "type": "appScreenshotSets",
                "attributes": {"screenshotDisplayType": display_type},
                "relationships": {"appStoreVersionLocalization": {
                    "data": {"type": "appStoreVersionLocalizations", "id": locs[locale]["id"]}}},
            }})
            set_id = r["data"]["id"]
            print(f"  created set {set_id}")
        else:
            set_id = s["id"]
        delete_first = len(old) + len(files) > SET_LIMIT
        if delete_first:
            for o in old:
                asc_delete(a, f"/appScreenshots/{o['id']}")
                print(f"  - deleted {describe(o)}")
        new_ids = []
        for f in files:
            print(f"  + {os.path.basename(f)}")
            new_ids.append(upload_one(a, set_id, f))
        if not delete_first:
            for o in old:
                asc_delete(a, f"/appScreenshots/{o['id']}")
                print(f"  - deleted {describe(o)}")
        a.patch(f"/appScreenshotSets/{set_id}/relationships/appScreenshots",
                {"data": [{"type": "appScreenshots", "id": i} for i in new_ids]})
        now = [sh["attributes"].get("fileName") for sh in screenshots(a, set_id)]
        want = [os.path.basename(f) for f in files]
        print(f"  set now: {', '.join(now)}")
        if now != want:
            print(f"  ✗ expected exactly {', '.join(want)}")
            return 1
    print("\n✓ Done. Read it back: scripts/store_screenshots.py list "
          f"--platform {args.platform} --version {args.version}")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name, helptext, localehelp in (
            ("list", "read-only: the screenshot sets of every locale", "only this locale (repeatable; default all)"),
            ("upload", "replace the named display types (dry run without --yes)",
             "replace in this locale (repeatable; default en-US only)")):
        sp = sub.add_parser(name, help=helptext, description=helptext)
        sp.add_argument("--platform", required=True, choices=PLATFORMS)
        sp.add_argument("--version", required=True, help="the versionString, e.g. 1.4.0")
        sp.add_argument("--locale", action="append", default=[], help=localehelp)
        if name == "upload":
            sp.add_argument("--set", action="append", nargs="+", required=True, metavar=("TYPE", "FILE"),
                            help="a display type (e.g. APP_IPHONE_67) and its files in store order; repeatable")
            sp.add_argument("--yes", action="store_true", help="apply (otherwise a dry run)")
    args = p.parse_args(argv)
    if args.cmd == "upload" and any(len(s) < 2 for s in args.set):
        p.error("--set needs a display type and at least one file")
    return cmd_list(args) if args.cmd == "list" else cmd_upload(args)


if __name__ == "__main__":
    sys.exit(main())
