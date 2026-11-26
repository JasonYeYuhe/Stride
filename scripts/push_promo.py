#!/usr/bin/env python3
"""Promotional text only, on a live (or any) version of both platforms, from metadata/<locale>/.

    scripts/push_promo.py 1.4.2          dry run: prints live vs. file per platform and locale
    scripts/push_promo.py 1.4.2 --yes    PATCHes promotionalText only, then reads it back

push_metadata.py also writes the description and keywords, which a READY_FOR_SALE version does not
accept; promotional text can change at any time without review. The Mac record reads
promotional_text.macos.txt when it exists, as in push_metadata.py.
"""
import os
import sys

import requests

import asc_api as a

V1 = "https://api.appstoreconnect.apple.com/v1"
APP_ID = "6761262334"
META = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "metadata")
LOCALES = {"en-US": "en-US", "es-ES": "es-ES", "ja": "ja", "ko": "ko", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant"}


def call(method, url, **kw):
    r = requests.request(method, url, headers=a.headers(), **kw)
    if not r.ok:
        sys.exit(f"✗ {method} {url.split('.com')[1]} → {r.status_code}: {r.text[:500]}")
    return r.json() if r.content else None


def text(locale, platform):
    d = os.path.join(META, locale)
    f = os.path.join(d, "promotional_text.macos.txt")
    if platform != "MAC_OS" or not os.path.exists(f):
        f = os.path.join(d, "promotional_text.txt")
    t = open(f).read().strip()
    if len(t) > 170:
        sys.exit(f"✗ {f} is {len(t)} characters (ASC allows 170)")
    return t


def main():
    args = sys.argv[1:]
    if len(args) not in (1, 2) or (len(args) == 2 and args[1] != "--yes"):
        sys.exit("usage: push_promo.py <version> [--yes]")
    version, apply = args[0], len(args) == 2
    bad = 0
    for platform in ("IOS", "MAC_OS"):
        vs = call("GET", f"{V1}/apps/{APP_ID}/appStoreVersions",
                  params={"filter[platform]": platform, "filter[versionString]": version})["data"]
        if len(vs) != 1:
            sys.exit(f"✗ {platform} {version}: {len(vs)} versions")
        v = vs[0]
        print(f"{platform} {version} {v['attributes']['appStoreState']}")
        locs = call("GET", f"{V1}/appStoreVersions/{v['id']}/appStoreVersionLocalizations", params={"limit": 50})["data"]
        by = {l["attributes"]["locale"]: l for l in locs}
        for meta, asc in LOCALES.items():
            want = text(meta, platform)
            loc = by.get(asc)
            if loc is None:
                sys.exit(f"✗ {platform} has no {asc} localization")
            have = (loc["attributes"].get("promotionalText") or "").strip()
            if have == want:
                print(f"  {asc}: already set")
                continue
            print(f"  {asc}: {'set' if apply else 'would set'} → {want}")
            if apply:
                call("PATCH", f"{V1}/appStoreVersionLocalizations/{loc['id']}", json={"data": {
                    "type": "appStoreVersionLocalizations", "id": loc["id"],
                    "attributes": {"promotionalText": want}}})
                back = call("GET", f"{V1}/appStoreVersionLocalizations/{loc['id']}")["data"]["attributes"]
                ok = (back.get("promotionalText") or "").strip() == want
                bad += not ok
                print(f"    read-back {'ok' if ok else 'MISMATCH'}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
