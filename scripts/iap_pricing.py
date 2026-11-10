#!/usr/bin/env python3
"""Stride Pro's pricing settings in App Store Connect: the Lifetime price and the grace period.

    scripts/iap_pricing.py            dry run: reads what is live, prints what it would change
    scripts/iap_pricing.py --yes      applies it, then reads it back

Owner decision of 2026-10-22, after the churn investigation (RELEASE-1.4.1.md): Lifetime cost
19.99 USD, the same as one year of Yearly, so nobody had a reason to subscribe (in its first
months Stride sold one Lifetime and no subscription).
  - Lifetime: 39.99 USD in the USA, the base territory; Apple equalizes the other storefronts
    from it (the schedule has no manual price elsewhere).
  - Billing Grace Period on for the app's subscriptions (16 days, all renewals, sandbox too): a
    subscriber whose renewal fails keeps Pro while Apple retries. 1.4.1's Settings shows the
    payment row for it (D12).
The 7-day free trial on Yearly is NOT set here: the paywall shows its terms only from 1.4.2.
"""

import sys

import requests

import asc_api as a

V1 = "https://api.appstoreconnect.apple.com/v1"
V2 = "https://api.appstoreconnect.apple.com/v2"
APP_ID = "6761262334"
LIFETIME_ID = "yyh.stride.habittracker.pro.lifetime"
LIFETIME_USD = "39.99"
GRACE = {"optIn": True, "sandboxOptIn": True, "duration": "SIXTEEN_DAYS", "renewalType": "ALL_RENEWALS"}


def call(method, url, **kw):
    r = requests.request(method, url, headers=a.headers(), **kw)
    if not r.ok:
        sys.exit(f"✗ {method} {url.split('.com')[1]} → {r.status_code}: {r.text[:400]}")
    return r.json() if r.content else None


def lifetime_id():
    iaps = call("GET", f"{V1}/apps/{APP_ID}/inAppPurchasesV2", params={"limit": 50})["data"]
    match = [i["id"] for i in iaps if i["attributes"].get("productId") == LIFETIME_ID]
    if len(match) != 1:
        sys.exit(f"✗ expected one {LIFETIME_ID}, found {len(match)}")
    return match[0]


def current_usd(iap_id):
    """The USA manual price of the Lifetime schedule (the base territory)."""
    prices = call("GET", f"{V1}/inAppPurchasePriceSchedules/{iap_id}/manualPrices",
                  params={"filter[territory]": "USA", "include": "inAppPurchasePricePoint", "limit": 50})
    points = {i["id"]: i["attributes"].get("customerPrice") for i in prices.get("included", [])
              if i["type"] == "inAppPurchasePricePoints"}
    for p in prices.get("data", []):
        point = p["relationships"]["inAppPurchasePricePoint"]["data"]["id"]
        if p["attributes"].get("endDate") is None:
            return points.get(point)
    return None


def usd_point(iap_id, price):
    url, params = f"{V2}/inAppPurchases/{iap_id}/pricePoints", {"filter[territory]": "USA", "limit": 200}
    while url:
        page = call("GET", url, params=params)
        for p in page["data"]:
            if p["attributes"].get("customerPrice") == price:
                return p["id"]
        url, params = page.get("links", {}).get("next"), None
    sys.exit(f"✗ no USA price point at {price}")


def main():
    apply = "--yes" in sys.argv[1:]
    plan = []

    iap = lifetime_id()
    have = current_usd(iap)
    if have != LIFETIME_USD:
        point = usd_point(iap, LIFETIME_USD)
        body = {"data": {"type": "inAppPurchasePriceSchedules",
                         "relationships": {
                             "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap}},
                             "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                             "manualPrices": {"data": [{"type": "inAppPurchasePrices", "id": "${usa}"}]}}},
                "included": [{"type": "inAppPurchasePrices", "id": "${usa}",
                              "attributes": {"startDate": None},
                              "relationships": {"inAppPurchasePricePoint": {
                                  "data": {"type": "inAppPurchasePricePoints", "id": point}}}}]}
        plan.append(("POST", f"{V1}/inAppPurchasePriceSchedules", body,
                     f"Lifetime USA {have} → {LIFETIME_USD} USD (other storefronts equalized by Apple)"))

    grace = call("GET", f"{V1}/apps/{APP_ID}/subscriptionGracePeriod")["data"]
    attrs = grace["attributes"]
    if any(attrs.get(k) != v for k, v in GRACE.items()):
        plan.append(("PATCH", f"{V1}/subscriptionGracePeriods/{grace['id']}",
                     {"data": {"type": "subscriptionGracePeriods", "id": grace["id"], "attributes": GRACE}},
                     f"Billing Grace Period {({k: attrs.get(k) for k in GRACE})} → {GRACE}"))

    if not plan:
        print("✓ Nothing to change: the live settings already match.")
        return
    print(("Applying" if apply else "Would apply (dry run; --yes to apply)") + f", {len(plan)} change(s):")
    for *_, what in plan:
        print(f"  {what}")
    if not apply:
        return
    for method, url, body, what in plan:
        call(method, url, json=body)
        print(f"  ✓ {what.split(' →')[0]}")

    bad = []
    if current_usd(iap) != LIFETIME_USD:
        bad.append("Lifetime price")
    if any(call("GET", f"{V1}/apps/{APP_ID}/subscriptionGracePeriod")["data"]["attributes"].get(k) != v
           for k, v in GRACE.items()):
        bad.append("grace period")
    if bad:
        sys.exit(f"✗ read-back differs: {', '.join(bad)}")
    print(f"✓ Read back: Lifetime {LIFETIME_USD} USD; Billing Grace Period on (16 days, all renewals).")


if __name__ == "__main__":
    main()
