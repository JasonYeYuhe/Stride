#!/usr/bin/env python3
"""App Store Connect API helper for Stride submission."""

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


def generate_token():
    with open(KEY_PATH, "r") as f:
        private_key = f.read()
    now = int(time.time())
    payload = {
        "iss": ISSUER_ID,
        "iat": now,
        "exp": now + 1200,  # 20 min
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(payload, private_key, algorithm="ES256", headers={"kid": API_KEY_ID})


def headers():
    return {
        "Authorization": f"Bearer {generate_token()}",
        "Content-Type": "application/json",
    }


def get(path, params=None):
    r = requests.get(f"{BASE_URL}{path}", headers=headers(), params=params)
    r.raise_for_status()
    return r.json()


def post(path, data):
    r = requests.post(f"{BASE_URL}{path}", headers=headers(), json=data)
    if not r.ok:
        print(f"POST {path} failed: {r.status_code}")
        print(r.text[:500])
    r.raise_for_status()
    return r.json()


def patch(path, data):
    r = requests.patch(f"{BASE_URL}{path}", headers=headers(), json=data)
    if not r.ok:
        print(f"PATCH {path} failed: {r.status_code}")
        print(r.text[:500])
    r.raise_for_status()
    return r.json()


def find_app():
    data = get("/apps", params={"filter[bundleId]": BUNDLE_ID})
    apps = data.get("data", [])
    if not apps:
        print(f"No app found with bundle ID {BUNDLE_ID}")
        sys.exit(1)
    app = apps[0]
    print(f"Found app: {app['attributes']['name']} (ID: {app['id']})")
    return app["id"]


def get_latest_version(app_id):
    data = get(f"/apps/{app_id}/appStoreVersions", params={
        "filter[appStoreState]": "PREPARE_FOR_SUBMISSION,READY_FOR_SALE",
        "limit": 5,
    })
    versions = data.get("data", [])
    for v in versions:
        state = v["attributes"]["appStoreState"]
        vstring = v["attributes"]["versionString"]
        print(f"  Version {vstring}: {state} (ID: {v['id']})")
    return versions


def get_builds(app_id):
    data = get(f"/builds", params={
        "filter[app]": app_id,
        "sort": "-uploadedDate",
        "limit": 5,
    })
    builds = data.get("data", [])
    for b in builds:
        attrs = b["attributes"]
        print(f"  Build {attrs.get('version', '?')} ({attrs.get('processingState', '?')})")
    return builds


def get_version_localizations(version_id):
    data = get(f"/appStoreVersions/{version_id}/appStoreVersionLocalizations")
    return data.get("data", [])


def update_localization(loc_id, description=None, keywords=None,
                       promotional_text=None, whats_new=None):
    attrs = {}
    if description is not None:
        attrs["description"] = description
    if keywords is not None:
        attrs["keywords"] = keywords
    if promotional_text is not None:
        attrs["promotionalText"] = promotional_text
    if whats_new is not None:
        attrs["whatsNew"] = whats_new

    if not attrs:
        return

    return patch(f"/appStoreVersionLocalizations/{loc_id}", {
        "data": {
            "type": "appStoreVersionLocalizations",
            "id": loc_id,
            "attributes": attrs,
        }
    })


def create_localization(version_id, locale, description="", keywords="",
                       promotional_text="", whats_new=""):
    return post("/appStoreVersionLocalizations", {
        "data": {
            "type": "appStoreVersionLocalizations",
            "attributes": {
                "locale": locale,
                "description": description,
                "keywords": keywords,
                "promotionalText": promotional_text,
                "whatsNew": whats_new,
            },
            "relationships": {
                "appStoreVersion": {
                    "data": {"type": "appStoreVersions", "id": version_id}
                }
            }
        }
    })


def submit_for_review(version_id):
    return post("/appStoreVersionSubmissions", {
        "data": {
            "type": "appStoreVersionSubmissions",
            "relationships": {
                "appStoreVersion": {
                    "data": {"type": "appStoreVersions", "id": version_id}
                }
            }
        }
    })


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"

    if cmd == "status":
        app_id = find_app()
        print("\nVersions:")
        get_latest_version(app_id)
        print("\nBuilds:")
        get_builds(app_id)

    elif cmd == "metadata":
        app_id = find_app()
        versions = get_latest_version(app_id)
        if not versions:
            print("No version found")
            sys.exit(1)

        version_id = versions[0]["id"]
        print(f"\nUpdating metadata for version {versions[0]['attributes']['versionString']}...")

        locs = get_version_localizations(version_id)
        existing_locales = {l["attributes"]["locale"]: l["id"] for l in locs}
        print(f"Existing localizations: {list(existing_locales.keys())}")

        # Metadata directory
        meta_dir = os.path.join(os.path.dirname(__file__), "..", "metadata")
        locale_map = {
            "en-US": "en-US",
            "zh-Hans": "zh-Hans",
            "zh-Hant": "zh-Hant",
            "ja": "ja",
            "ko": "ko",
            "es-ES": "es-ES",
        }

        for meta_locale, asc_locale in locale_map.items():
            locale_dir = os.path.join(meta_dir, meta_locale)
            if not os.path.isdir(locale_dir):
                continue

            desc = open(os.path.join(locale_dir, "description.txt")).read().strip()
            kw = open(os.path.join(locale_dir, "keywords.txt")).read().strip()
            promo = open(os.path.join(locale_dir, "promotional_text.txt")).read().strip()
            whats_new = "Initial release! Build better habits with Stride."

            if asc_locale in existing_locales:
                print(f"  Updating {asc_locale}...")
                update_localization(
                    existing_locales[asc_locale],
                    description=desc, keywords=kw,
                    promotional_text=promo, whats_new=whats_new
                )
            else:
                print(f"  Creating {asc_locale}...")
                create_localization(
                    version_id, asc_locale,
                    description=desc, keywords=kw,
                    promotional_text=promo, whats_new=whats_new
                )
        print("Metadata updated!")

    elif cmd == "submit":
        app_id = find_app()
        versions = get_latest_version(app_id)
        if not versions:
            print("No version found")
            sys.exit(1)
        version_id = versions[0]["id"]
        print(f"\nSubmitting version {versions[0]['attributes']['versionString']} for review...")
        submit_for_review(version_id)
        print("Submitted for review!")

    else:
        print(f"Usage: {sys.argv[0]} [status|metadata|submit]")
