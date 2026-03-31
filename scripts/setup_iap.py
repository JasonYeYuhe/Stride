#!/usr/bin/env python3
"""Create subscription group and products in App Store Connect, then resubmit for review."""

import json
import os
import sys
import time

import jwt
import requests
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))

API_KEY_ID = os.environ["ASC_API_KEY_ID"]
ISSUER_ID = os.environ["ASC_ISSUER_ID"]
KEY_PATH = os.path.expanduser(os.environ["ASC_KEY_PATH"])
BUNDLE_ID = "yyh.stride.habittracker"
BASE_URL = "https://api.appstoreconnect.apple.com/v1"

APP_ID = os.environ["ASC_APP_ID"]

# Subscription definitions matching Configuration.storekit
SUBSCRIPTIONS = [
    {
        "product_id": "yyh.stride.habittracker.pro.monthly",
        "reference_name": "Monthly Pro",
        "period": "ONE_MONTH",
        "group_level": 1,
        "price_usd": "2.99",
        "intro_price_usd": "0.99",
        "intro_period": "ONE_MONTH",
        "intro_periods": 1,
        "localizations": {
            "en_US": {"name": "Stride Pro Monthly", "description": "Full access billed monthly"},
            "zh_Hans": {"name": "Stride Pro 月度", "description": "按月订阅，解锁全部功能"},
            "zh_Hant": {"name": "Stride Pro 月費", "description": "按月訂閱，解鎖全部功能"},
            "ja": {"name": "Stride Pro 月額", "description": "月額プランで全機能をアンロック"},
            "ko": {"name": "Stride Pro 월간", "description": "월간 구독으로 모든 기능 잠금 해제"},
            "es_ES": {"name": "Stride Pro Mensual", "description": "Acceso completo con facturación mensual"},
        },
    },
    {
        "product_id": "yyh.stride.habittracker.pro.yearly",
        "reference_name": "Yearly Pro",
        "period": "ONE_YEAR",
        "group_level": 1,
        "price_usd": "19.99",
        "intro_price_usd": "9.99",
        "intro_period": "ONE_YEAR",
        "intro_periods": 1,
        "localizations": {
            "en_US": {"name": "Stride Pro Yearly", "description": "Full access billed yearly - save 44%"},
            "zh_Hans": {"name": "Stride Pro 年度", "description": "按年订阅，节省44%"},
            "zh_Hant": {"name": "Stride Pro 年費", "description": "按年訂閱，節省44%"},
            "ja": {"name": "Stride Pro 年額", "description": "年額プランで44%お得"},
            "ko": {"name": "Stride Pro 연간", "description": "연간 구독으로 44% 할인"},
            "es_ES": {"name": "Stride Pro Anual", "description": "Acceso completo anual - ahorra 44%"},
        },
    },
]

GROUP_LOCALIZATIONS = {
    "en_US": {"name": "Stride Pro", "custom_name": "Stride Pro"},
    "zh_Hans": {"name": "Stride Pro", "custom_name": "Stride Pro"},
    "zh_Hant": {"name": "Stride Pro", "custom_name": "Stride Pro"},
    "ja": {"name": "Stride Pro", "custom_name": "Stride Pro"},
    "ko": {"name": "Stride Pro", "custom_name": "Stride Pro"},
    "es_ES": {"name": "Stride Pro", "custom_name": "Stride Pro"},
}


def generate_token():
    with open(KEY_PATH, "r") as f:
        private_key = f.read()
    now = int(time.time())
    payload = {
        "iss": ISSUER_ID,
        "iat": now,
        "exp": now + 1200,
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(payload, private_key, algorithm="ES256", headers={"kid": API_KEY_ID})


def hdrs():
    return {
        "Authorization": f"Bearer {generate_token()}",
        "Content-Type": "application/json",
    }


def get(path, params=None):
    r = requests.get(f"{BASE_URL}{path}", headers=hdrs(), params=params)
    r.raise_for_status()
    return r.json()


def post(path, data):
    r = requests.post(f"{BASE_URL}{path}", headers=hdrs(), json=data)
    if not r.ok:
        print(f"  POST {path} failed: {r.status_code}")
        print(f"  {r.text[:1000]}")
        r.raise_for_status()
    return r.json()


def patch(path, data):
    r = requests.patch(f"{BASE_URL}{path}", headers=hdrs(), json=data)
    if not r.ok:
        print(f"  PATCH {path} failed: {r.status_code}")
        print(f"  {r.text[:1000]}")
        r.raise_for_status()
    return r.json()


def delete(path):
    r = requests.delete(f"{BASE_URL}{path}", headers=hdrs())
    if not r.ok:
        print(f"  DELETE {path} failed: {r.status_code}")
        print(f"  {r.text[:500]}")
        r.raise_for_status()


# ── Step 1: Check / Create Subscription Group ────────────────────────

def get_or_create_subscription_group():
    """Get existing or create new subscription group."""
    data = get(f"/apps/{APP_ID}/subscriptionGroups")
    groups = data.get("data", [])

    for g in groups:
        if g["attributes"]["referenceName"] == "Stride Pro":
            print(f"✓ Subscription group exists: {g['id']}")
            return g["id"]

    print("Creating subscription group 'Stride Pro'...")
    result = post("/subscriptionGroups", {
        "data": {
            "type": "subscriptionGroups",
            "attributes": {
                "referenceName": "Stride Pro",
            },
            "relationships": {
                "app": {
                    "data": {"type": "apps", "id": APP_ID}
                }
            }
        }
    })
    group_id = result["data"]["id"]
    print(f"✓ Created subscription group: {group_id}")
    return group_id


def add_group_localizations(group_id):
    """Add localizations to the subscription group."""
    existing = get(f"/subscriptionGroups/{group_id}/subscriptionGroupLocalizations")
    existing_locales = {l["attributes"]["locale"]: l["id"] for l in existing.get("data", [])}

    for locale, info in GROUP_LOCALIZATIONS.items():
        if locale in existing_locales:
            print(f"  Group localization {locale} already exists")
            continue
        try:
            post("/subscriptionGroupLocalizations", {
                "data": {
                    "type": "subscriptionGroupLocalizations",
                    "attributes": {
                        "locale": locale,
                        "name": info["name"],
                        "customAppName": info["custom_name"],
                    },
                    "relationships": {
                        "subscriptionGroup": {
                            "data": {"type": "subscriptionGroups", "id": group_id}
                        }
                    }
                }
            })
            print(f"  ✓ Added group localization: {locale}")
        except Exception as e:
            print(f"  ⚠ Group localization {locale}: {e}")


# ── Step 2: Create Subscriptions ─────────────────────────────────────

def get_or_create_subscription(group_id, sub_def):
    """Get existing or create a subscription product."""
    # Check existing subscriptions in this group
    data = get(f"/subscriptionGroups/{group_id}/subscriptions")
    for s in data.get("data", []):
        if s["attributes"]["productID"] == sub_def["product_id"]:
            print(f"✓ Subscription exists: {sub_def['product_id']} (ID: {s['id']})")
            return s["id"]

    print(f"Creating subscription: {sub_def['product_id']}...")
    result = post("/subscriptions", {
        "data": {
            "type": "subscriptions",
            "attributes": {
                "productID": sub_def["product_id"],
                "name": sub_def["reference_name"],
                "subscriptionPeriod": sub_def["period"],
                "groupLevel": sub_def["group_level"],
                "familySharable": False,
                "reviewNote": "Stride Pro subscription unlocks unlimited habits, advanced statistics, widgets, smart reminders, and iCloud sync.",
            },
            "relationships": {
                "group": {
                    "data": {"type": "subscriptionGroups", "id": group_id}
                }
            }
        }
    })
    sub_id = result["data"]["id"]
    print(f"✓ Created subscription: {sub_def['product_id']} (ID: {sub_id})")
    return sub_id


# ── Step 3: Add Subscription Localizations ───────────────────────────

def add_subscription_localizations(sub_id, sub_def):
    """Add localizations to a subscription."""
    existing = get(f"/subscriptions/{sub_id}/subscriptionLocalizations")
    existing_locales = {l["attributes"]["locale"]: l["id"] for l in existing.get("data", [])}

    for locale, info in sub_def["localizations"].items():
        if locale in existing_locales:
            print(f"  Localization {locale} already exists for {sub_def['product_id']}")
            continue
        try:
            post("/subscriptionLocalizations", {
                "data": {
                    "type": "subscriptionLocalizations",
                    "attributes": {
                        "locale": locale,
                        "name": info["name"],
                        "description": info["description"],
                    },
                    "relationships": {
                        "subscription": {
                            "data": {"type": "subscriptions", "id": sub_id}
                        }
                    }
                }
            })
            print(f"  ✓ Added localization: {locale}")
        except Exception as e:
            print(f"  ⚠ Localization {locale}: {e}")


# ── Step 4: Set Pricing ──────────────────────────────────────────────

def set_subscription_price(sub_id, target_price_usd):
    """Set the base price for a subscription using price points."""
    # Check existing prices
    existing_prices = get(f"/subscriptions/{sub_id}/prices", params={"limit": 5})
    if existing_prices.get("data"):
        print(f"  Pricing already configured ({len(existing_prices['data'])} price(s))")
        return

    # Get price points for USD (United States)
    price_points = get(
        f"/subscriptions/{sub_id}/pricePoints",
        params={
            "filter[territory]": "USA",
            "limit": 200,
        }
    )

    target = float(target_price_usd)
    matched_point = None
    for pp in price_points.get("data", []):
        pp_price = float(pp["attributes"].get("customerPrice", "0"))
        if abs(pp_price - target) < 0.01:
            matched_point = pp
            break

    if not matched_point:
        # List available prices for debugging
        prices_available = [
            f"${pp['attributes'].get('customerPrice', '?')}"
            for pp in price_points.get("data", [])[:10]
        ]
        print(f"  ⚠ Could not find price point for ${target_price_usd}. Available: {prices_available}")
        return

    print(f"  Setting base price to ${target_price_usd} (point: {matched_point['id']})...")
    post("/subscriptionPrices", {
        "data": {
            "type": "subscriptionPrices",
            "attributes": {
                "startDate": None,
                "preserveCurrentPrice": False,
            },
            "relationships": {
                "subscription": {
                    "data": {"type": "subscriptions", "id": sub_id}
                },
                "subscriptionPricePoint": {
                    "data": {"type": "subscriptionPricePoints", "id": matched_point["id"]}
                }
            }
        }
    })
    print(f"  ✓ Price set to ${target_price_usd}")


# ── Step 5: Set Introductory Offers ──────────────────────────────────

def set_intro_offer(sub_id, sub_def):
    """Set introductory offer for a subscription."""
    # Check existing offers
    existing = get(f"/subscriptions/{sub_id}/introductoryOffers", params={"limit": 5})
    if existing.get("data"):
        print(f"  Introductory offer already configured")
        return

    # Get price points for the intro price
    price_points = get(
        f"/subscriptions/{sub_id}/pricePoints",
        params={
            "filter[territory]": "USA",
            "limit": 200,
        }
    )

    target = float(sub_def["intro_price_usd"])
    matched_point = None
    for pp in price_points.get("data", []):
        pp_price = float(pp["attributes"].get("customerPrice", "0"))
        if abs(pp_price - target) < 0.01:
            matched_point = pp
            break

    if not matched_point:
        print(f"  ⚠ Could not find price point for intro price ${sub_def['intro_price_usd']}")
        return

    # Map period strings
    period_map = {
        "ONE_MONTH": "ONE_MONTH",
        "ONE_YEAR": "ONE_YEAR",
    }

    try:
        # Get all territories for the offer
        territories = get(
            f"/subscriptionPricePoints/{matched_point['id']}/territory"
        )
        territory_id = territories["data"]["id"]

        post("/subscriptionIntroductoryOffers", {
            "data": {
                "type": "subscriptionIntroductoryOffers",
                "attributes": {
                    "duration": sub_def["intro_period"],
                    "numberOfPeriods": sub_def["intro_periods"],
                    "offerMode": "PAY_AS_YOU_GO",
                    "startDate": None,
                    "endDate": None,
                },
                "relationships": {
                    "subscription": {
                        "data": {"type": "subscriptions", "id": sub_id}
                    },
                    "subscriptionPricePoint": {
                        "data": {"type": "subscriptionPricePoints", "id": matched_point["id"]}
                    },
                    "territory": {
                        "data": {"type": "territories", "id": territory_id}
                    }
                }
            }
        })
        print(f"  ✓ Introductory offer set: ${sub_def['intro_price_usd']}")
    except Exception as e:
        print(f"  ⚠ Could not set intro offer: {e}")


# ── Step 6: Submit IAPs for Review ───────────────────────────────────

def submit_iap_for_review(sub_id):
    """Submit a subscription for review."""
    try:
        post("/subscriptionSubmissions", {
            "data": {
                "type": "subscriptionSubmissions",
                "relationships": {
                    "subscription": {
                        "data": {"type": "subscriptions", "id": sub_id}
                    }
                }
            }
        })
        print(f"  ✓ Submitted subscription {sub_id} for review")
    except Exception as e:
        print(f"  ⚠ Submit for review: {e}")


# ── Step 7: Resubmit App Version ─────────────────────────────────────

def resubmit_ios_version():
    """Resubmit the rejected iOS version for review."""
    data = get(f"/apps/{APP_ID}/appStoreVersions", params={"limit": 10})
    for v in data.get("data", []):
        attrs = v["attributes"]
        if attrs.get("platform") == "IOS" and attrs["appStoreState"] in (
            "REJECTED", "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED"
        ):
            vid = v["id"]
            state = attrs["appStoreState"]
            print(f"\niOS version {attrs['versionString']}: {state} [ID: {vid}]")

            if state == "REJECTED":
                # For REJECTED state, we can directly resubmit
                print("  Resubmitting for review...")
                try:
                    post("/appStoreVersionSubmissions", {
                        "data": {
                            "type": "appStoreVersionSubmissions",
                            "relationships": {
                                "appStoreVersion": {
                                    "data": {"type": "appStoreVersions", "id": vid}
                                }
                            }
                        }
                    })
                    print("  ✓ iOS version resubmitted for review!")
                except Exception as e:
                    print(f"  ⚠ Resubmit failed: {e}")
                    print("  You may need to upload a new build first.")
            return vid
    print("  No iOS version found to resubmit")
    return None


# ── Main ─────────────────────────────────────────────────────────────

def main():
    print("=" * 60)
    print("Stride IAP Setup — App Store Connect")
    print("=" * 60)

    # Step 1: Subscription Group
    print("\n── Step 1: Subscription Group ──")
    group_id = get_or_create_subscription_group()
    add_group_localizations(group_id)

    # Step 2-5: Create and configure each subscription
    sub_ids = []
    for sub_def in SUBSCRIPTIONS:
        print(f"\n── Setting up: {sub_def['reference_name']} ──")

        sub_id = get_or_create_subscription(group_id, sub_def)
        sub_ids.append(sub_id)

        print("  Adding localizations...")
        add_subscription_localizations(sub_id, sub_def)

        print("  Setting pricing...")
        set_subscription_price(sub_id, sub_def["price_usd"])

        print("  Setting introductory offer...")
        set_intro_offer(sub_id, sub_def)

    # Step 6: Submit IAPs for review
    print("\n── Step 6: Submit IAPs for Review ──")
    for sub_id in sub_ids:
        submit_iap_for_review(sub_id)

    # Step 7: Resubmit iOS version
    print("\n── Step 7: Resubmit iOS Version ──")
    resubmit_ios_version()

    print("\n" + "=" * 60)
    print("Done! Check App Store Connect for status.")
    print("=" * 60)


if __name__ == "__main__":
    if "--check" in sys.argv:
        # Just check current state
        print("Current subscription groups:")
        data = get(f"/apps/{APP_ID}/subscriptionGroups")
        for g in data.get("data", []):
            print(f"  {g['attributes']['referenceName']} (ID: {g['id']})")
            subs = get(f"/subscriptionGroups/{g['id']}/subscriptions")
            for s in subs.get("data", []):
                attrs = s["attributes"]
                print(f"    {attrs['productID']}: {attrs.get('state', '?')} ({attrs['name']})")
    else:
        main()
