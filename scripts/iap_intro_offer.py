#!/usr/bin/env python3
"""O3: Stride Pro Yearly's introductory offer, a 1-week free trial in every territory.

    scripts/iap_intro_offer.py            dry run: reads what is live, prints what it would create
    scripts/iap_intro_offer.py --yes      creates what is missing, then reads it back

Decided in RELEASE-1.4.2.md (O3, N2): the offer goes live only once iOS and Mac 1.4.2 are both
live, because 1.4.2 is the first paywall that states a trial's terms. Gate 14 then runs against
the real offer. Re-runnable: territories that already have an introductory offer are skipped, and
an existing offer that is NOT a 1-week free trial stops the script instead of being changed.
"""

import sys

import requests

import asc_api as a

V1 = "https://api.appstoreconnect.apple.com/v1"
APP_ID = "6761262334"
YEARLY_ID = "yyh.stride.habittracker.pro.yearly"
WANT = {"offerMode": "FREE_TRIAL", "duration": "ONE_WEEK", "numberOfPeriods": 1}


def call(method, url, **kw):
    r = requests.request(method, url, headers=a.headers(), **kw)
    if not r.ok:
        sys.exit(f"✗ {method} {url.split('.com')[1]} → {r.status_code}: {r.text[:600]}")
    return r.json() if r.content else None


def pages(url, params=None):
    while url:
        page = call("GET", url, params=params)
        yield page
        url, params = page.get("links", {}).get("next"), None


def yearly():
    for page in pages(f"{V1}/apps/{APP_ID}/subscriptionGroups", {"include": "subscriptions", "limit": 50}):
        for s in page.get("included", []):
            if s["type"] == "subscriptions" and s["attributes"].get("productId") == YEARLY_ID:
                return s["id"], s["attributes"].get("state")
    sys.exit(f"✗ no subscription {YEARLY_ID}")


def territories(sub_id):
    """Where Yearly is sold: the offer is per territory."""
    avail = call("GET", f"{V1}/subscriptions/{sub_id}/subscriptionAvailability")["data"]
    ids = []
    for page in pages(f"{V1}/subscriptionAvailabilities/{avail['id']}/availableTerritories", {"limit": 200}):
        ids += [t["id"] for t in page["data"]]
    return ids


def offers(sub_id):
    """{territory: attributes} of the existing introductory offers."""
    out = {}
    for page in pages(f"{V1}/subscriptions/{sub_id}/introductoryOffers", {"include": "territory", "limit": 200}):
        for o in page["data"]:
            t = (o["relationships"].get("territory", {}).get("data") or {}).get("id", "ALL")
            out[t] = o["attributes"]
    return out


def matches(attrs):
    return all(attrs.get(k) == v for k, v in WANT.items()) and attrs.get("endDate") is None


def main():
    apply = sys.argv[1:] == ["--yes"]
    if sys.argv[1:] not in ([], ["--yes"]):
        sys.exit("usage: iap_intro_offer.py [--yes]")
    sub_id, state = yearly()
    terr = territories(sub_id)
    have = offers(sub_id)
    wrong = {t: v for t, v in have.items() if not matches(v)}
    if wrong:
        sys.exit(f"✗ existing offers that are not a 1-week free trial, left alone: {wrong}")
    missing = [t for t in terr if t not in have]
    print(f"Yearly {sub_id} ({state}): sold in {len(terr)} territories; "
          f"1-week free trial already in {len(have)}; missing in {len(missing)}")
    if not apply:
        print("dry run: nothing written (pass --yes)")
        return
    for i, t in enumerate(missing, 1):
        call("POST", f"{V1}/subscriptionIntroductoryOffers", json={"data": {
            "type": "subscriptionIntroductoryOffers",
            "attributes": WANT,
            "relationships": {
                "subscription": {"data": {"type": "subscriptions", "id": sub_id}},
                "territory": {"data": {"type": "territories", "id": t}},
            }}})
        if i % 25 == 0:
            print(f"  created {i}/{len(missing)}")
    after = offers(sub_id)
    bad = [t for t in terr if t not in after or not matches(after[t])]
    print(f"read-back: {len(after)} offers; territories without a 1-week free trial: {bad or 'none'}")
    if bad:
        sys.exit(1)


if __name__ == "__main__":
    main()
