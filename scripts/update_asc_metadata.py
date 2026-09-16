#!/usr/bin/env python3
"""
Quick script to update ASC privacy policy URL and macOS version description
for the Guideline 3.1.2(c) fix.
"""

import jwt
import time
import requests
import os

from dotenv import load_dotenv

# --- Config (same as appstore_metadata.py) ---
# Credentials come from scripts/.env (gitignored), the same file asc_api.py reads. They used
# to be hardcoded here — key id, issuer id, and a .p8 path inside iCloud Drive's Downloads
# folder, i.e. synced to Apple's servers and every signed-in device. The ids alone can't
# authenticate, but they are half of a credential and they contradict the convention the rest
# of the repo follows.
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))
try:
    API_KEY_ID = os.environ["ASC_API_KEY_ID"]
    API_ISSUER = os.environ["ASC_ISSUER_ID"]
    API_KEY_PATH = os.path.expanduser(os.environ["ASC_KEY_PATH"])
except KeyError as missing:
    raise SystemExit(
        f"{missing} is not set. Put ASC_API_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH in "
        "scripts/.env (see scripts/asc_api.py)."
    )
APP_ID = "6761262334"
BASE_URL = "https://api.appstoreconnect.apple.com/v1"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)


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


def get_headers():
    return {
        "Authorization": f"Bearer {generate_token()}",
        "Content-Type": "application/json",
    }


def api_get(path):
    r = requests.get(f"{BASE_URL}{path}", headers=get_headers())
    r.raise_for_status()
    return r.json()


def api_patch(path, data):
    r = requests.patch(f"{BASE_URL}{path}", json=data, headers=get_headers())
    if r.status_code >= 400:
        print(f"  PATCH {path} -> {r.status_code}: {r.text[:200]}")
    else:
        print(f"  PATCH {path} -> {r.status_code} OK")
    return r.json() if r.text else {}


def update_privacy_policy_url():
    """Update privacy policy URL in App Info for all localizations."""
    print("\n=== Updating Privacy Policy URL ===")
    r = api_get(f"/apps/{APP_ID}/appInfos")
    infos = r.get("data", [])
    if not infos:
        print("  No app info found!")
        return

    info_id = infos[0]["id"]
    r = api_get(f"/appInfos/{info_id}/appInfoLocalizations")
    locs = r.get("data", [])

    for loc in locs:
        locale = loc["attributes"]["locale"]
        loc_id = loc["id"]
        current_url = loc["attributes"].get("privacyPolicyUrl", "")
        print(f"  [{locale}] current: {current_url}")

        api_patch(f"/appInfoLocalizations/{loc_id}", {
            "data": {
                "type": "appInfoLocalizations",
                "id": loc_id,
                "attributes": {
                    "privacyPolicyUrl": "https://jasonyeyuhe.github.io/stride-site/privacy",
                }
            }
        })


def update_macos_description():
    """Update description for macOS version with correct URLs."""
    print("\n=== Updating macOS Version Description ===")

    # Find macOS version
    r = api_get(f"/apps/{APP_ID}/appStoreVersions?filter[platform]=MAC_OS")
    versions = r.get("data", [])
    if not versions:
        print("  No macOS versions found!")
        return

    version = versions[0]
    version_id = version["id"]
    state = version["attributes"]["appStoreState"]
    print(f"  Found macOS version {version['attributes']['versionString']} (state: {state}, id: {version_id})")

    # Get localizations
    r = api_get(f"/appStoreVersions/{version_id}/appStoreVersionLocalizations")
    locs = r.get("data", [])

    locale_files = {
        "en-US": "en-US",
        "zh-Hans": "zh-Hans",
        "zh-Hant": "zh-Hant",
        "ja": "ja",
        "ko": "ko",
        "es-ES": "es-ES",
    }

    for loc in locs:
        locale = loc["attributes"]["locale"]
        loc_id = loc["id"]

        if locale in locale_files:
            desc_path = os.path.join(PROJECT_DIR, "metadata", locale_files[locale], "description.txt")
            if os.path.exists(desc_path):
                with open(desc_path, "r") as f:
                    description = f.read().strip()
                print(f"  [{locale}] Updating description from {desc_path}...")
                api_patch(f"/appStoreVersionLocalizations/{loc_id}", {
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "id": loc_id,
                        "attributes": {
                            "description": description,
                            "supportUrl": "https://jasonyeyuhe.github.io/stride-site/support",
                        }
                    }
                })
            else:
                print(f"  [{locale}] No description file found at {desc_path}")
        else:
            print(f"  [{locale}] Skipping (no metadata file)")


if __name__ == "__main__":
    print("Stride ASC Metadata Update - Guideline 3.1.2(c) Fix")
    update_privacy_policy_url()
    update_macos_description()
    print("\n=== Done ===")
