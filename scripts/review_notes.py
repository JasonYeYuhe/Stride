#!/usr/bin/env python3
"""Put a version's App Review notes from docs/review-notes-<version>.md on both platforms' records.

    scripts/review_notes.py 1.4.1          dry run: prints the live notes and what would replace them
    scripts/review_notes.py 1.4.1 --yes    applies, then reads back

The doc holds one fenced block under "## iOS…" and one under "## macOS". Only the Notes field of
each record's appStoreReviewDetail changes: the demo account's user name and password (its login
token) stay exactly as they are, and are never read into this script's output. App Store Connect
carries the previous version's notes over to a new record (`release.py prepare`), which is why
1.4.0's Mac record first arrived with notes about a Settings row 1.4.0 had removed.
"""

import os
import re
import sys

import requests

import asc_api as a

V1 = "https://api.appstoreconnect.apple.com/v1"
APP_ID = "6761262334"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def call(method, url, **kw):
    r = requests.request(method, url, headers=a.headers(), **kw)
    if not r.ok:
        sys.exit(f"✗ {method} {url.split('.com')[1]} → {r.status_code}: {r.text[:300]}")
    return r.json() if r.content else None


def blocks(version):
    path = os.path.join(ROOT, "docs", f"review-notes-{version}.md")
    text = open(path, encoding="utf-8").read()
    out = {}
    for platform, heading in (("IOS", r"## iOS[^\n]*"), ("MAC_OS", r"## macOS[^\n]*")):
        m = re.search(heading + r"\n+```\n(.*?)\n```", text, re.S)
        if not m:
            sys.exit(f"✗ no fenced block under the {platform} heading in {path}")
        notes = m.group(1).strip()
        if re.search(r"(?i)\btoken\s*[:=]|password\s*[:=]", notes):
            sys.exit(f"✗ the {platform} block looks like it holds a secret; refusing")
        if len(notes) > 4000:
            sys.exit(f"✗ the {platform} notes are {len(notes)} characters (ASC allows 4000)")
        out[platform] = notes
    return out


def main():
    args = [x for x in sys.argv[1:] if not x.startswith("--")]
    if len(args) != 1:
        sys.exit(__doc__)
    version, apply = args[0], "--yes" in sys.argv[1:]
    want = blocks(version)
    versions = call("GET", f"{V1}/apps/{APP_ID}/appStoreVersions",
                    params={"filter[versionString]": version, "limit": 10})["data"]
    changed = 0
    for platform, notes in want.items():
        recs = [v for v in versions if v["attributes"]["platform"] == platform]
        if len(recs) != 1:
            sys.exit(f"✗ {platform} {version}: {len(recs)} version records (run release.py prepare {version} first)")
        state = recs[0]["attributes"]["appStoreState"]
        if state != "PREPARE_FOR_SUBMISSION":
            sys.exit(f"✗ {platform} {version} is {state}: notes are editable only before submission")
        detail = call("GET", f"{V1}/appStoreVersions/{recs[0]['id']}/appStoreReviewDetail",
                      params={"fields[appStoreReviewDetails]": "notes"})["data"]
        if detail is None:
            sys.exit(f"✗ {platform} {version} has no App Review detail to edit")
        have = (detail["attributes"].get("notes") or "").strip()
        if have == notes:
            print(f"✓ {platform}: notes already as in the doc")
            continue
        print(f"{platform}: {'replacing' if apply else 'would replace'} {len(have)} characters "
              f"(starting {have[:60]!r}) with the doc's {len(notes)}")
        if apply:
            call("PATCH", f"{V1}/appStoreReviewDetails/{detail['id']}",
                 json={"data": {"type": "appStoreReviewDetails", "id": detail["id"],
                                "attributes": {"notes": notes}}})
            back = call("GET", f"{V1}/appStoreReviewDetails/{detail['id']}",
                        params={"fields[appStoreReviewDetails]": "notes"})["data"]["attributes"].get("notes", "")
            if back.strip() != notes:
                sys.exit(f"✗ {platform}: read-back differs")
            print(f"  ✓ {platform}: notes set and read back")
            changed += 1
    if not apply and any(True for _ in want):
        print("(dry run; --yes to apply)")


if __name__ == "__main__":
    main()
