#!/usr/bin/env python3
"""Owner-only: put the App Review demo login token into a version's Sign-In Password, both platforms.

    scripts/demo_token_to_asc.py 1.4.2

It asks for the token at a hidden prompt (paste it from 1Password), then PATCHes
`demoAccountPassword` on the iOS and macOS records' appStoreReviewDetail. The token is never
printed, logged, written to disk or taken from an argument or the environment, and the read-back
compares SHA-256 digests, not text. The demo user name and the notes are left as they are
(scripts/review_notes.py owns the notes).

Agents do not run this: production tokens are pasted by the owner (RELEASE-1.4.2.md, submission
checklist).
"""

import getpass
import hashlib
import os
import sys

import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_api as a  # noqa: E402  (loads scripts/.env for the ASC API key)

V1 = "https://api.appstoreconnect.apple.com/v1"
APP_ID = "6761262334"


def call(method, url, **kw):
    r = requests.request(method, url, headers=a.headers(), **kw)
    if not r.ok:
        sys.exit(f"✗ {method} {url.split('.com')[1]} → {r.status_code}")
    return r.json() if r.text else {}


def digest(s):
    return hashlib.sha256(s.encode()).hexdigest()


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: scripts/demo_token_to_asc.py <version>")
    version = sys.argv[1]
    if not sys.stdin.isatty():
        sys.exit("✗ run it in a terminal: the token is read only from a hidden prompt")
    token = getpass.getpass("Demo login token (hidden): ").strip()
    if len(token) < 16 or any(c.isspace() for c in token):
        sys.exit("✗ that does not look like a login token (too short, or has spaces)")

    for platform in ("IOS", "MAC_OS"):
        recs = call("GET", f"{V1}/apps/{APP_ID}/appStoreVersions",
                    params={"filter[versionString]": version, "filter[platform]": platform})["data"]
        if not recs:
            sys.exit(f"✗ {platform}: no {version} record (run release.py prepare {version} first)")
        detail = call("GET", f"{V1}/appStoreVersions/{recs[0]['id']}/appStoreReviewDetail")["data"]
        if not detail:
            sys.exit(f"✗ {platform}: the record has no review detail yet")
        call("PATCH", f"{V1}/appStoreReviewDetails/{detail['id']}",
             json={"data": {"type": "appStoreReviewDetails", "id": detail["id"],
                            "attributes": {"demoAccountRequired": True,
                                           "demoAccountPassword": token}}})
        back = call("GET", f"{V1}/appStoreReviewDetails/{detail['id']}",
                    params={"fields[appStoreReviewDetails]": "demoAccountPassword,demoAccountName"})
        attrs = back["data"]["attributes"]
        ok = digest(attrs.get("demoAccountPassword") or "") == digest(token)
        print(f"  {'✓' if ok else '✗'} {platform}: Sign-In Password set "
              f"({'matches' if ok else 'DOES NOT match'} on read-back; user name unchanged)")
        if not ok:
            sys.exit(1)


if __name__ == "__main__":
    main()
