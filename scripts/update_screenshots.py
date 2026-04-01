#!/usr/bin/env python3
"""Delete old screenshots and upload fixed ones via ASC API."""

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
BASE = "https://api.appstoreconnect.apple.com/v1"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SCREENSHOT_DIR = os.path.join(SCRIPT_DIR, "..", "build", "ios-screenshots")


def token():
    with open(KEY_PATH) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": API_KEY_ID}
    )


def hdrs(content_type="application/json"):
    return {"Authorization": f"Bearer {token()}", "Content-Type": content_type}


def get(path, params=None):
    r = requests.get(f"{BASE}{path}", headers=hdrs(), params=params)
    r.raise_for_status()
    return r.json()


def delete(path):
    r = requests.delete(f"{BASE}{path}", headers=hdrs())
    if r.status_code not in (200, 204):
        print(f"DELETE {path}: {r.status_code} {r.text[:300]}")
    return r.status_code


def post(path, data):
    r = requests.post(f"{BASE}{path}", headers=hdrs(), json=data)
    if not r.ok:
        print(f"POST {path}: {r.status_code}\n{r.text[:500]}")
    r.raise_for_status()
    return r.json()


def patch(path, data):
    r = requests.patch(f"{BASE}{path}", headers=hdrs(), json=data)
    if not r.ok:
        print(f"PATCH {path}: {r.status_code}\n{r.text[:500]}")
    r.raise_for_status()
    return r.json()


# 1. Find app and version
app_data = get("/apps", params={"filter[bundleId]": BUNDLE_ID})
app_id = app_data["data"][0]["id"]
print(f"App: {app_id}")

versions = get(f"/apps/{app_id}/appStoreVersions", params={
    "filter[appStoreState]": "PREPARE_FOR_SUBMISSION,WAITING_FOR_REVIEW,IN_REVIEW,DEVELOPER_REJECTED,REJECTED",
    "limit": 5,
})["data"]

if not versions:
    versions = get(f"/apps/{app_id}/appStoreVersions", params={"limit": 5})["data"]

for v in versions:
    print(f"  Version {v['attributes']['versionString']}: {v['attributes']['appStoreState']}")

version_id = versions[0]["id"]
print(f"\nUsing version: {version_id}")

# 2. Get localizations for this version
locs = get(f"/appStoreVersions/{version_id}/appStoreVersionLocalizations")["data"]
print(f"\nLocalizations: {len(locs)}")

for loc in locs:
    locale = loc["attributes"]["locale"]
    loc_id = loc["id"]
    print(f"\n--- Locale: {locale} (ID: {loc_id}) ---")

    # 3. Get screenshot sets for this localization
    sets = get(f"/appStoreVersionLocalizations/{loc_id}/appScreenshotSets")["data"]
    print(f"  Screenshot sets: {len(sets)}")

    for ss in sets:
        display_type = ss["attributes"]["screenshotDisplayType"]
        ss_id = ss["id"]
        print(f"  Set: {display_type} (ID: {ss_id})")

        # 4. Get screenshots in this set
        screenshots = get(f"/appScreenshotSets/{ss_id}/appScreenshots")["data"]
        print(f"    Screenshots: {len(screenshots)}")

        # 5. Delete all existing screenshots
        for sc in screenshots:
            sc_id = sc["id"]
            fname = sc["attributes"].get("fileName", "?")
            print(f"    Deleting {fname} ({sc_id})...")
            delete(f"/appScreenshots/{sc_id}")

        # 6. Upload new screenshots for en-US
        # Map display types to file suffixes
        suffix_map = {
            "APP_IPHONE_65": "6.5",
            "APP_IPHONE_67": "6.7",
            "APP_IPAD_PRO_129": "ipad",
            "APP_IPAD_PRO_3GEN_129": "ipad",
            "APP_WATCH_SERIES_7": "watch_s7",
            "APP_WATCH_SERIES_10": "watch_s10",
            "APP_WATCH_ULTRA": "watch_ultra",
        }
        suffix = suffix_map.get(display_type)
        if locale == "en-US" and suffix:
            files = sorted([
                f for f in os.listdir(SCREENSHOT_DIR)
                if f.endswith(".png") and suffix in f
            ])
            print(f"    Uploading {len(files)} new screenshots...")

            for idx, fname in enumerate(files):
                filepath = os.path.join(SCREENSHOT_DIR, fname)
                filesize = os.path.getsize(filepath)
                print(f"    [{idx+1}/{len(files)}] Reserving {fname} ({filesize} bytes)...")

                # Reserve upload
                reservation = post("/appScreenshots", {
                    "data": {
                        "type": "appScreenshots",
                        "attributes": {
                            "fileName": fname,
                            "fileSize": filesize,
                        },
                        "relationships": {
                            "appScreenshotSet": {
                                "data": {"type": "appScreenshotSets", "id": ss_id}
                            }
                        }
                    }
                })

                sc_data = reservation["data"]
                sc_id = sc_data["id"]
                upload_ops = sc_data["attributes"].get("uploadOperations", [])

                # Upload parts
                with open(filepath, "rb") as f:
                    file_bytes = f.read()

                for op in upload_ops:
                    url = op["url"]
                    offset = op["offset"]
                    length = op["length"]
                    method = op["method"]
                    req_headers = {h["name"]: h["value"] for h in op["requestHeaders"]}

                    chunk = file_bytes[offset:offset + length]
                    print(f"      Uploading chunk: offset={offset}, length={length}...")
                    resp = requests.put(url, headers=req_headers, data=chunk)
                    if not resp.ok:
                        print(f"      Upload failed: {resp.status_code} {resp.text[:200]}")

                # Commit
                print(f"      Committing {fname}...")
                import hashlib
                md5 = hashlib.md5(file_bytes).hexdigest()
                patch(f"/appScreenshots/{sc_id}", {
                    "data": {
                        "type": "appScreenshots",
                        "id": sc_id,
                        "attributes": {
                            "sourceFileChecksum": md5,
                            "uploaded": True,
                        }
                    }
                })
                print(f"    ✓ {fname} uploaded")

print("\nDone!")
