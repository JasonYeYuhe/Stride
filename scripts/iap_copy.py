#!/usr/bin/env python3
"""Set the App Store copy of Stride Pro's in-app purchases, and nothing else.

    scripts/iap_copy.py            dry run: reads what is live, prints what it would change
    scripts/iap_copy.py --yes      applies it, then reads it back

What it sets (RELEASE-1.4.1.md, owner decisions of 2026-10-21, after W9's ASC read-back):
  - the Yearly subscription's six descriptions, without a saving figure. "save 44%" was true in
    USD and GBP only (19.99 against 12 x 2.99) and wrong in the euro, yen, won, yuan and Taiwan
    dollar storefronts, because the figure was written per language while prices are per
    storefront. The app's paywall computes its own badge from the live prices
    (StoreService.yearlySavingsPercent), so the store copy now names no figure at all;
  - the Lifetime purchase's localizations in all six languages. It had en-US only, and its
    description left out Weekly Review, one of D11's three Pro features. Names and descriptions
    use the app catalogs' own words ("Lifetime", the Settings upsell line).

1.4.2 (RELEASE-1.4.2.md D16, O22) adds the App Review note of all three products (`reviewNote`).
The live notes predate D11: Monthly and Yearly said "unlocks unlimited habits, advanced statistics,
widgets, smart reminders, and iCloud sync" (all free), Lifetime "habit groups + advanced analytics"
without Weekly Review. Each note now says D11's three things, in the review notes' own words
(docs/review-notes-1.4.1.md), and where the paywall is. The dry run prints every live note next to
the proposed one, changed or not.

Monthly's localizations, the subscription group, prices and availability are left alone. ASC
limits: a name at most 35 characters, a description at most 55, a review note at most 4,000;
checked before anything is sent. A changed
localization of an approved product goes to App Review with the next version submission.
SUBSCRIPTIONS in setup_iap.py carries the same Yearly copy, so the two scripts agree.
"""

import sys

import requests

import asc_api as a

V1 = "https://api.appstoreconnect.apple.com/v1"
V2 = "https://api.appstoreconnect.apple.com/v2"
APP_ID = "6761262334"
MONTHLY_ID = "yyh.stride.habittracker.pro.monthly"
YEARLY_ID = "yyh.stride.habittracker.pro.yearly"
LIFETIME_ID = "yyh.stride.habittracker.pro.lifetime"
NAME_MAX, DESCRIPTION_MAX, REVIEW_NOTE_MAX = 35, 55, 4000

# D11's three things, as docs/review-notes-1.4.1.md words them for App Review. setup_iap.py builds
# its creation note from the same text, so a product created later starts right.
PRO_REVIEW_NOTE = (
    "Stride Pro adds three things: Habit Groups; Advanced Analytics (Insights, the 8-week Trend "
    "chart, the Strength chart and your top 5 streaks); and Weekly Review. Everything else is "
    "free, including the Strength score and History. The paywall is under Settings > Upgrade to "
    "Pro (on the Mac, Stride > Settings…), or Unlock with Pro on the Advanced Analytics card in "
    "Statistics."
)
REVIEW_NOTES = {
    MONTHLY_ID: "Stride Pro Monthly is an auto-renewable subscription, billed monthly. " + PRO_REVIEW_NOTE,
    YEARLY_ID: "Stride Pro Yearly is an auto-renewable subscription, billed yearly. " + PRO_REVIEW_NOTE,
    LIFETIME_ID: "Stride Pro (Lifetime) is a one-time purchase (non-consumable) that unlocks the same "
                 "Pro as the subscriptions, and can be restored with Restore Purchases. " + PRO_REVIEW_NOTE,
}
REVIEW_NOTE_LABELS = {MONTHLY_ID: "Monthly", YEARLY_ID: "Yearly", LIFETIME_ID: "Lifetime"}

YEARLY_DESCRIPTIONS = {
    "en-US": "Full access billed yearly",
    "es-ES": "Acceso completo con facturación anual",
    "ja": "年額プランで全機能をアンロック",
    "ko": "연간 구독으로 모든 기능 잠금 해제",
    "zh-Hans": "按年订阅，解锁全部功能",
    "zh-Hant": "按年訂閱，解鎖全部功能",
}

LIFETIME = {
    "en-US": ("Stride Pro (Lifetime)", "Habit groups, advanced analytics & weekly review"),
    "es-ES": ("Stride Pro (De por vida)", "Grupos de hábitos, análisis avanzado y resumen semanal"),
    "ja": ("Stride Pro（買い切り）", "習慣グループ、高度な分析、週間レビュー"),
    "ko": ("Stride Pro (평생)", "습관 그룹, 고급 분석 및 주간 리뷰"),
    "zh-Hans": ("Stride Pro（终身）", "习惯分组、高级分析与每周回顾"),
    "zh-Hant": ("Stride Pro（終身）", "習慣分組、進階分析與每週回顧"),
}


class Unmodifiable(Exception):
    """ASC will not change this localization through the API in its current state."""


def call(method, url, **kw):
    r = requests.request(method, url, headers=a.headers(), **kw)
    if r.status_code == 409 and "UNMODIFIABLE" in r.text:
        raise Unmodifiable(r.json()["errors"][0].get("detail", "unmodifiable"))
    if not r.ok:
        sys.exit(f"✗ {method} {url.split('.com')[1]} → {r.status_code}: {r.text[:400]}")
    return r.json() if r.content else None


def check_limits():
    problems = []
    for loc, text in YEARLY_DESCRIPTIONS.items():
        if len(text) > DESCRIPTION_MAX:
            problems.append(f"Yearly {loc} description is {len(text)} characters")
    for loc, (name, text) in LIFETIME.items():
        if len(name) > NAME_MAX:
            problems.append(f"Lifetime {loc} name is {len(name)} characters")
        if len(text) > DESCRIPTION_MAX:
            problems.append(f"Lifetime {loc} description is {len(text)} characters")
    for product, note in REVIEW_NOTES.items():
        if len(note) > REVIEW_NOTE_MAX:
            problems.append(f"{REVIEW_NOTE_LABELS[product]} review note is {len(note)} characters")
    if problems:
        sys.exit("✗ over ASC's limits:\n  " + "\n  ".join(problems))


def subscriptions():
    """{product id: the subscription resource} for Monthly and Yearly, each exactly once."""
    groups = call("GET", f"{V1}/apps/{APP_ID}/subscriptionGroups", params={"include": "subscriptions"})
    found = {}
    for product in (MONTHLY_ID, YEARLY_ID):
        subs = [i for i in groups.get("included", []) if i["type"] == "subscriptions"
                and i["attributes"].get("productId") == product]
        if len(subs) != 1:
            sys.exit(f"✗ expected one {product}, found {len(subs)}")
        found[product] = subs[0]
    return found


def yearly_localizations():
    return call("GET", f"{V1}/subscriptions/{subscriptions()[YEARLY_ID]['id']}/subscriptionLocalizations",
                params={"limit": 50})["data"]


def live_review_notes():
    """{product id: (url, resource type, resource id, the live note)} for all three products."""
    notes = {}
    for product, sub in subscriptions().items():
        notes[product] = (f"{V1}/subscriptions/{sub['id']}", "subscriptions", sub["id"],
                          sub["attributes"].get("reviewNote"))
    iap_id, _ = lifetime()
    iap = call("GET", f"{V2}/inAppPurchases/{iap_id}")["data"]
    notes[LIFETIME_ID] = (f"{V2}/inAppPurchases/{iap_id}", "inAppPurchases", iap_id,
                          iap["attributes"].get("reviewNote"))
    return notes


def lifetime():
    iaps = call("GET", f"{V1}/apps/{APP_ID}/inAppPurchasesV2", params={"limit": 50})["data"]
    match = [i for i in iaps if i["attributes"].get("productId") == LIFETIME_ID]
    if len(match) != 1:
        sys.exit(f"✗ expected one {LIFETIME_ID}, found {len(match)}")
    iap_id = match[0]["id"]
    locs = call("GET", f"{V2}/inAppPurchases/{iap_id}/inAppPurchaseLocalizations",
                params={"limit": 50})["data"]
    return iap_id, locs


def main():
    apply = "--yes" in sys.argv[1:]
    check_limits()
    plan = []

    for loc in yearly_localizations():
        attrs = loc["attributes"]
        want = YEARLY_DESCRIPTIONS.get(attrs["locale"])
        if want is None:
            print(f"  note: Yearly has a {attrs['locale']} localization this script does not set; left alone")
        elif attrs.get("description") != want:
            plan.append(("PATCH", f"{V1}/subscriptionLocalizations/{loc['id']}",
                         {"data": {"type": "subscriptionLocalizations", "id": loc["id"],
                                   "attributes": {"description": want}}},
                         f"Yearly {attrs['locale']}: {attrs.get('description')!r} → {want!r}"))

    iap_id, locs = lifetime()
    by_locale = {l["attributes"]["locale"]: l for l in locs}
    for locale, (name, text) in LIFETIME.items():
        have = by_locale.get(locale)
        if have is None:
            plan.append(("POST", f"{V1}/inAppPurchaseLocalizations",
                         {"data": {"type": "inAppPurchaseLocalizations",
                                   "attributes": {"locale": locale, "name": name, "description": text},
                                   "relationships": {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iap_id}}}}},
                         f"Lifetime {locale}: new — {name!r} / {text!r}"))
        elif (have["attributes"].get("name"), have["attributes"].get("description")) != (name, text):
            plan.append(("PATCH", f"{V1}/inAppPurchaseLocalizations/{have['id']}",
                         {"data": {"type": "inAppPurchaseLocalizations", "id": have["id"],
                                   "attributes": {"name": name, "description": text}}},
                         f"Lifetime {locale}: {have['attributes'].get('name')!r} / "
                         f"{have['attributes'].get('description')!r} → {name!r} / {text!r}"))

    print("App Review notes (live → proposed):")
    for product, (url, kind, rid, have) in live_review_notes().items():
        want = REVIEW_NOTES[product]
        label = REVIEW_NOTE_LABELS[product]
        print(f"  {label} ({product})")
        print(f"    live:     {have!r}")
        print(f"    proposed: {want!r}" + ("  (same)" if have == want else ""))
        if have != want:
            plan.append(("PATCH", url,
                         {"data": {"type": kind, "id": rid, "attributes": {"reviewNote": want}}},
                         f"{label} review note: {have!r} → {want!r}"))
    print()

    if not plan:
        print("✓ Nothing to change: the live copy already matches.")
        return
    print(("Applying" if apply else "Would apply (dry run; --yes to apply)") + f", {len(plan)} change(s):")
    for _, _, _, what in plan:
        print(f"  {what}")
    if not apply:
        return
    by_hand = []
    for method, url, body, what in plan:
        try:
            call(method, url, json=body)
            print(f"  ✓ {what.split(':')[0]}")
        except Unmodifiable as e:
            # Measured 2026-10-22: an approved product's existing localization answers 409
            # "Cannot edit SubscriptionLocalization when it is in ACTIVE state". The ASC web UI
            # takes the same edit and sends it to review with the next version.
            print(f"  – {what.split(':')[0]}: {e}")
            by_hand.append(what)

    # Read back.
    skipped = {w.split(":")[0] for w in by_hand}
    bad = [f"Yearly {l['attributes']['locale']}" for l in yearly_localizations()
           if YEARLY_DESCRIPTIONS.get(l["attributes"]["locale"], l["attributes"].get("description"))
           != l["attributes"].get("description")]
    _, locs = lifetime()
    got = {l["attributes"]["locale"]: (l["attributes"].get("name"), l["attributes"].get("description")) for l in locs}
    bad += [f"Lifetime {k}" for k, v in LIFETIME.items() if got.get(k) != v]
    bad += [f"{REVIEW_NOTE_LABELS[p]} review note" for p, (_, _, _, note) in live_review_notes().items()
            if note != REVIEW_NOTES[p]]
    bad = [b for b in bad if b not in skipped]
    if bad:
        sys.exit(f"✗ read-back differs: {', '.join(bad)}")
    if by_hand:
        print(f"✓ Read back: everything the API accepts is set. {len(by_hand)} approved localization(s) "
              "need the same edit in App Store Connect's web UI (Monetization → the product → its "
              "localization); it goes to review with 1.4.1:")
        for w in by_hand:
            print(f"    {w}")
    else:
        print("✓ Read back: Yearly's 6 descriptions, Lifetime's 6 localizations and the three "
              "review notes are as set.")


if __name__ == "__main__":
    main()
