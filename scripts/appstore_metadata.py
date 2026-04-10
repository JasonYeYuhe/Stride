#!/usr/bin/env python3
"""
Stride - App Store Connect Metadata & Screenshot Uploader
Uses App Store Connect API v1

Usage:
    python3 scripts/appstore_metadata.py              # Create app + set metadata
    python3 scripts/appstore_metadata.py --screenshots # Also upload screenshots
"""

import jwt
import time
import requests
import json
import hashlib
import os
import sys

# --- Config ---
API_KEY_ID = "DMMFP6XTXX"
API_ISSUER = "c5671c11-49ec-47d9-bd38-5e3c1a249416"
API_KEY_PATH = os.path.expanduser(
    "~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_DMMFP6XTXX.p8"
)
BUNDLE_ID = "yyh.stride.habittracker"
BASE_URL = "https://api.appstoreconnect.apple.com/v1"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)

# Will be set after app creation/lookup
APP_ID = None


# --- JWT Token ---
def generate_token():
    with open(API_KEY_PATH, "r") as f:
        private_key = f.read()
    now = int(time.time())
    payload = {
        "iss": API_ISSUER,
        "iat": now,
        "exp": now + 1200,
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(payload, private_key, algorithm="ES256", headers={"kid": API_KEY_ID})


def get_headers(content_type="application/json"):
    return {
        "Authorization": f"Bearer {generate_token()}",
        "Content-Type": content_type,
    }


def api_get(path):
    r = requests.get(f"{BASE_URL}{path}", headers=get_headers())
    r.raise_for_status()
    return r.json()


def api_post(path, data, raise_on_error=True):
    r = requests.post(f"{BASE_URL}{path}", headers=get_headers(), json=data)
    if r.status_code >= 400:
        print(f"  POST {path} -> {r.status_code}")
        try:
            errors = r.json().get("errors", [])
            for e in errors:
                print(f"    {e.get('detail', e.get('title', 'Unknown error'))}")
        except Exception:
            print(f"  {r.text[:300]}")
        if raise_on_error:
            r.raise_for_status()
        return None
    return r.json()


def api_patch(path, data, raise_on_error=True):
    r = requests.patch(f"{BASE_URL}{path}", headers=get_headers(), json=data)
    if r.status_code >= 400:
        try:
            errors = r.json().get("errors", [])
            for e in errors:
                print(f"    {e.get('detail', e.get('title', 'Unknown error'))}")
        except Exception:
            print(f"  {r.text[:300]}")
        if raise_on_error:
            r.raise_for_status()
        return None
    return r.json()


def api_delete(path):
    r = requests.delete(f"{BASE_URL}{path}", headers=get_headers())
    return r.status_code


# ============================================================
# 0. Find or Create App
# ============================================================
def find_or_create_app():
    global APP_ID
    print("\n  Looking up app by bundle ID...")

    # Search existing apps
    r = api_get(f"/apps?filter[bundleId]={BUNDLE_ID}")
    apps = r.get("data", [])
    if apps:
        APP_ID = apps[0]["id"]
        print(f"  Found existing app: {apps[0]['attributes']['name']} (ID: {APP_ID})")
        return APP_ID

    # App not found via API. Ensure bundle ID is registered, then guide user.
    print(f"  App not found. Ensuring bundle ID is registered...")

    # Register bundle ID if needed
    r = api_get(f"/bundleIds?filter[identifier]={BUNDLE_ID}")
    bundle_ids = r.get("data", [])

    if not bundle_ids:
        print(f"  Registering bundle ID: {BUNDLE_ID}")
        r = api_post("/bundleIds", {
            "data": {
                "type": "bundleIds",
                "attributes": {
                    "identifier": BUNDLE_ID,
                    "name": "Stride",
                    "platform": "IOS",
                },
            }
        }, raise_on_error=False)
        if r:
            print(f"  ✓ Bundle ID registered: {r['data']['id']}")
    else:
        print(f"  ✓ Bundle ID already registered: {bundle_ids[0]['id']}")

    # App Store Connect API does not support POST /apps (Apple limitation).
    # Open the creation page for the user and wait.
    create_url = "https://appstoreconnect.apple.com/apps/new"
    print(f"\n  ⚠️  Apple's API does not support creating apps.")
    print(f"  Opening App Store Connect for you...")
    print(f"  Fill in:")
    print(f"    Name: Stride - Habit Tracker")
    print(f"    Primary Language: English (U.S.)")
    print(f"    Bundle ID: {BUNDLE_ID}")
    print(f"    SKU: stride-habit-tracker")
    print(f"")
    os.system(f'open "{create_url}"')

    input("  Press ENTER after you've created the app in App Store Connect...")

    # Re-lookup
    r = api_get(f"/apps?filter[bundleId]={BUNDLE_ID}")
    apps = r.get("data", [])
    if apps:
        APP_ID = apps[0]["id"]
        print(f"  ✓ Found app: {apps[0]['attributes']['name']} (ID: {APP_ID})")
        return APP_ID
    else:
        print("  ERROR: App still not found. Please create it manually and re-run.")
        sys.exit(1)


# ============================================================
# 1. Get or Create App Store Version
# ============================================================
def get_or_create_version(platform, version="1.0.0"):
    print(f"\n{'='*50}")
    print(f"  Setting up {platform} v{version}")
    print(f"{'='*50}")

    # Check all version states
    for state in ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "WAITING_FOR_REVIEW", "IN_REVIEW", "READY_FOR_SALE"]:
        r = api_get(f"/apps/{APP_ID}/appStoreVersions?filter[platform]={platform}&filter[appStoreState]={state}")
        versions = r.get("data", [])
        for v in versions:
            if v["attributes"]["versionString"] == version:
                print(f"  Found existing version: {v['id']} ({state})")
                return v["id"]

    # Also try without state filter
    r = api_get(f"/apps/{APP_ID}/appStoreVersions?filter[platform]={platform}")
    versions = r.get("data", [])
    for v in versions:
        if v["attributes"]["versionString"] == version:
            print(f"  Found existing version: {v['id']}")
            return v["id"]

    print(f"  Creating new version {version} for {platform}...")
    data = {
        "data": {
            "type": "appStoreVersions",
            "attributes": {
                "platform": platform,
                "versionString": version,
            },
            "relationships": {
                "app": {
                    "data": {"type": "apps", "id": APP_ID}
                }
            },
        }
    }
    r = api_post("/appStoreVersions", data, raise_on_error=False)
    if r is None:
        # Version likely already exists, try one more lookup without filters
        r = api_get(f"/apps/{APP_ID}/appStoreVersions?filter[platform]={platform}")
        versions = r.get("data", [])
        if versions:
            version_id = versions[0]["id"]
            print(f"  Using existing version: {version_id}")
            return version_id
        print("  ERROR: Cannot find or create version.")
        sys.exit(1)
    version_id = r["data"]["id"]
    print(f"  Created version: {version_id}")
    return version_id


# ============================================================
# 2. Set Localization
# ============================================================
def set_localization(version_id, locale="en-US"):
    print(f"\n  Setting {locale} localization...")

    description = """Stride helps you build better habits, one day at a time.

SIMPLE & BEAUTIFUL
• Create habits with custom emojis and colors
• Track your daily progress with a single tap
• See your streaks grow and stay motivated

POWERFUL INSIGHTS
• View current and best streaks at a glance
• 30-day completion rate tracking
• Weekly activity heatmaps and bar charts
• Discover your most productive days

WORKS EVERYWHERE
• Native iPhone and Mac experience
• Home Screen and Lock Screen widgets
• Smart daily reminders that keep you on track

PRIVACY FIRST
• Data stored locally by default
• Optional account for cross-device sync
• Anonymous analytics with opt-out in Settings

Whether you're building a morning routine, staying hydrated, reading daily, or exercising regularly — Stride makes habit tracking effortless and rewarding.

Start your streak today."""

    keywords = "habit,tracker,streak,daily,routine,goals,productivity,wellness,health,habits"

    whats_new = "Initial release — build better habits with Stride!"

    promo = "Build better habits, one day at a time"

    support_url = "https://jasonyeyuhe.github.io/stride-site/support"
    marketing_url = "https://github.com/JasonYeYuhe/Stride"

    r = api_get(f"/appStoreVersions/{version_id}/appStoreVersionLocalizations")
    localizations = r.get("data", [])

    loc_id = None
    for loc in localizations:
        if loc["attributes"]["locale"] == locale:
            loc_id = loc["id"]
            break

    loc_data = {
        "description": description,
        "keywords": keywords,
        "promotionalText": promo,
        "supportUrl": support_url,
        "marketingUrl": marketing_url,
    }

    if loc_id:
        print(f"  Updating existing localization {loc_id}...")
        api_patch(f"/appStoreVersionLocalizations/{loc_id}", {
            "data": {
                "type": "appStoreVersionLocalizations",
                "id": loc_id,
                "attributes": loc_data,
            }
        }, raise_on_error=False)
        api_patch(f"/appStoreVersionLocalizations/{loc_id}", {
            "data": {
                "type": "appStoreVersionLocalizations",
                "id": loc_id,
                "attributes": {"whatsNew": whats_new},
            }
        }, raise_on_error=False)
    else:
        print(f"  Creating new localization...")
        loc_data["locale"] = locale
        r = api_post("/appStoreVersionLocalizations", {
            "data": {
                "type": "appStoreVersionLocalizations",
                "attributes": loc_data,
                "relationships": {
                    "appStoreVersion": {
                        "data": {"type": "appStoreVersions", "id": version_id}
                    }
                },
            }
        })
        loc_id = r["data"]["id"]

    print(f"  ✓ Localization set: {loc_id}")
    return loc_id


# ============================================================
# 3. Set App Info (category, privacy policy)
# ============================================================
def set_app_info():
    print(f"\n  Setting app info (category, privacy)...")
    r = api_get(f"/apps/{APP_ID}/appInfos")
    infos = r.get("data", [])
    if not infos:
        print("  No app info found!")
        return

    info_id = infos[0]["id"]

    # Set category to Health & Fitness
    try:
        api_patch(f"/appInfos/{info_id}", {
            "data": {
                "type": "appInfos",
                "id": info_id,
                "relationships": {
                    "primaryCategory": {
                        "data": {"type": "appCategories", "id": "HEALTH_AND_FITNESS"}
                    },
                    "secondaryCategory": {
                        "data": {"type": "appCategories", "id": "PRODUCTIVITY"}
                    },
                },
            }
        }, raise_on_error=False)
        print(f"  ✓ Categories: Health & Fitness + Productivity")
    except Exception as e:
        print(f"  Category note: {e}")

    # Set localization (name + privacy URL)
    r = api_get(f"/appInfos/{info_id}/appInfoLocalizations")
    locs = r.get("data", [])
    for loc in locs:
        if loc["attributes"]["locale"] == "en-US":
            api_patch(f"/appInfoLocalizations/{loc['id']}", {
                "data": {
                    "type": "appInfoLocalizations",
                    "id": loc["id"],
                    "attributes": {
                        "name": "Stride - Habit Tracker",
                        "privacyPolicyUrl": "https://jasonyeyuhe.github.io/stride-site/privacy",
                    }
                }
            }, raise_on_error=False)
            print(f"  ✓ App info localization updated")
            break


# ============================================================
# 4. Upload Screenshots
# ============================================================
def upload_screenshots(loc_id, screenshot_files, display_type):
    print(f"\n  Uploading {len(screenshot_files)} screenshots ({display_type})...")

    r = api_get(f"/appStoreVersionLocalizations/{loc_id}/appScreenshotSets")
    sets = r.get("data", [])

    set_id = None
    for s in sets:
        if s["attributes"]["screenshotDisplayType"] == display_type:
            set_id = s["id"]
            break

    if not set_id:
        r = api_post("/appScreenshotSets", {
            "data": {
                "type": "appScreenshotSets",
                "attributes": {"screenshotDisplayType": display_type},
                "relationships": {
                    "appStoreVersionLocalization": {
                        "data": {"type": "appStoreVersionLocalizations", "id": loc_id}
                    }
                },
            }
        }, raise_on_error=False)
        if r is None:
            print(f"  Cannot create screenshot set. Skipping.")
            return
        set_id = r["data"]["id"]
        print(f"  Created screenshot set: {set_id}")
    else:
        # Delete existing screenshots
        r = api_get(f"/appScreenshotSets/{set_id}/appScreenshots")
        existing = r.get("data", [])
        for ss in existing:
            api_delete(f"/appScreenshots/{ss['id']}")
        print(f"  Using screenshot set: {set_id} (cleared {len(existing)} existing)")

    for i, filepath in enumerate(screenshot_files):
        filename = os.path.basename(filepath)
        filesize = os.path.getsize(filepath)
        with open(filepath, "rb") as f:
            file_data = f.read()
        checksum = hashlib.md5(file_data).hexdigest()

        print(f"  [{i+1}/{len(screenshot_files)}] {filename} ({filesize} bytes)...")

        r = api_post("/appScreenshots", {
            "data": {
                "type": "appScreenshots",
                "attributes": {"fileName": filename, "fileSize": filesize},
                "relationships": {
                    "appScreenshotSet": {
                        "data": {"type": "appScreenshotSets", "id": set_id}
                    }
                },
            }
        }, raise_on_error=False)

        if r is None:
            print(f"    Failed to reserve. Skipping.")
            continue

        screenshot_id = r["data"]["id"]
        upload_ops = r["data"]["attributes"].get("uploadOperations", [])

        for op in upload_ops:
            url = op["url"]
            op_headers = {h["name"]: h["value"] for h in op["requestHeaders"]}
            offset = op["offset"]
            length = op["length"]
            chunk = file_data[offset:offset + length]
            requests.put(url, headers=op_headers, data=chunk)

        api_patch(f"/appScreenshots/{screenshot_id}", {
            "data": {
                "type": "appScreenshots",
                "id": screenshot_id,
                "attributes": {
                    "uploaded": True,
                    "sourceFileChecksum": checksum,
                },
            }
        })
        print(f"    ✓ Uploaded")

    print(f"  ✓ All {display_type} screenshots done.")


# ============================================================
# 5. Create Subscription Group + Products
# ============================================================
def setup_subscriptions():
    print(f"\n  Setting up subscriptions...")

    # Check if subscription group exists
    r = api_get(f"/apps/{APP_ID}/subscriptionGroups")
    groups = r.get("data", [])

    group_id = None
    for g in groups:
        if g["attributes"]["referenceName"] == "Stride Pro":
            group_id = g["id"]
            break

    if not group_id:
        print("  Creating subscription group: Stride Pro")
        r = api_post("/subscriptionGroups", {
            "data": {
                "type": "subscriptionGroups",
                "attributes": {
                    "referenceName": "Stride Pro",
                },
                "relationships": {
                    "app": {
                        "data": {"type": "apps", "id": APP_ID}
                    }
                },
            }
        }, raise_on_error=False)
        if r:
            group_id = r["data"]["id"]
            print(f"  ✓ Created group: {group_id}")
        else:
            print("  Could not create subscription group. Configure manually in App Store Connect.")
            return
    else:
        print(f"  Using existing group: {group_id}")

    # Check/create subscriptions
    r = api_get(f"/subscriptionGroups/{group_id}/subscriptions")
    existing = {s["attributes"]["productId"]: s["id"] for s in r.get("data", [])}

    products = [
        ("yyh.stride.habittracker.pro.monthly", "Stride Pro Monthly", 1),
        ("yyh.stride.habittracker.pro.yearly", "Stride Pro Yearly", 2),
    ]

    for product_id, name, order in products:
        if product_id in existing:
            print(f"  ✓ {name} already exists")
            continue

        print(f"  Creating: {name} ({product_id})")
        api_post("/subscriptions", {
            "data": {
                "type": "subscriptions",
                "attributes": {
                    "productId": product_id,
                    "name": name,
                    "groupLevel": order,
                },
                "relationships": {
                    "group": {
                        "data": {"type": "subscriptionGroups", "id": group_id}
                    }
                },
            }
        }, raise_on_error=False)


# ============================================================
# Main
# ============================================================
def main():
    upload_screenshots_flag = "--screenshots" in sys.argv

    print("=" * 50)
    print("  Stride - App Store Connect Setup")
    print("=" * 50)

    # Test API connection
    print("\n  Testing API connection...")
    try:
        generate_token()
        print("  ✓ JWT token generated")
    except Exception as e:
        print(f"  ERROR: Cannot generate token: {e}")
        sys.exit(1)

    # Find or create app
    find_or_create_app()

    # Set app info
    set_app_info()

    # Setup subscriptions
    setup_subscriptions()

    # --- iOS ---
    ios_version_id = get_or_create_version("IOS")
    ios_loc_id = set_localization(ios_version_id)

    if upload_screenshots_flag:
        ios_dir = os.path.join(PROJECT_DIR, "build/ios-screenshots")
        if os.path.isdir(ios_dir):
            screenshots = sorted([
                os.path.join(ios_dir, f)
                for f in os.listdir(ios_dir)
                if f.endswith(".png")
            ])
            if screenshots:
                upload_screenshots(ios_loc_id, screenshots, "APP_IPHONE_67")

    # --- macOS ---
    mac_version_id = get_or_create_version("MAC_OS")
    mac_loc_id = set_localization(mac_version_id)

    if upload_screenshots_flag:
        mac_dir = os.path.join(PROJECT_DIR, "build/mac-screenshots")
        if os.path.isdir(mac_dir):
            screenshots = sorted([
                os.path.join(mac_dir, f)
                for f in os.listdir(mac_dir)
                if f.endswith(".png")
            ])
            if screenshots:
                upload_screenshots(mac_loc_id, screenshots, "APP_DESKTOP")

    print("\n" + "=" * 50)
    print("  ✓ Metadata setup complete!")
    print("=" * 50)
    if APP_ID:
        print(f"\n  App Store Connect: https://appstoreconnect.apple.com/apps/{APP_ID}")
    print()


if __name__ == "__main__":
    main()
