#!/usr/bin/env python3
"""Cancel review, push all localized metadata, and resubmit for review."""

import os
import sys
import time
import json
import jwt
import requests
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))

API_KEY_ID = os.environ["ASC_API_KEY_ID"]
ISSUER_ID = os.environ["ASC_ISSUER_ID"]
KEY_PATH = os.path.expanduser(os.environ["ASC_KEY_PATH"])
BUNDLE_ID = "yyh.stride.habittracker"
BASE_URL = "https://api.appstoreconnect.apple.com/v1"

LOCALE_MAP = {
    "en-US": "en-US",
    "zh-Hans": "zh-Hans",
    "zh-Hant": "zh-Hant",
    "ja": "ja",
    "ko": "ko",
    "es-ES": "es-ES",
}

META_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "metadata")


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
        print(f"  {r.text[:500]}")
    r.raise_for_status()
    return r.json()


def patch(path, data):
    r = requests.patch(f"{BASE_URL}{path}", headers=hdrs(), json=data)
    if not r.ok:
        print(f"  PATCH {path} failed: {r.status_code}")
        print(f"  {r.text[:500]}")
    r.raise_for_status()
    return r.json()


def delete(path):
    r = requests.delete(f"{BASE_URL}{path}", headers=hdrs())
    if not r.ok:
        print(f"  DELETE {path} failed: {r.status_code}")
        print(f"  {r.text[:500]}")
    r.raise_for_status()
    return r


def find_app():
    data = get("/apps", params={"filter[bundleId]": BUNDLE_ID})
    apps = data.get("data", [])
    if not apps:
        print(f"No app found with bundle ID {BUNDLE_ID}")
        sys.exit(1)
    app = apps[0]
    print(f"App: {app['attributes']['name']} (ID: {app['id']})")
    return app["id"]


def get_versions(app_id):
    data = get(f"/apps/{app_id}/appStoreVersions", params={
        "filter[appStoreState]": "PREPARE_FOR_SUBMISSION,WAITING_FOR_REVIEW,IN_REVIEW,READY_FOR_SALE",
        "limit": 10,
    })
    return data.get("data", [])


def cancel_submission(version_id):
    """Cancel a version submission (works for WAITING_FOR_REVIEW)."""
    # Find the submission resource
    data = get(f"/appStoreVersions/{version_id}/appStoreVersionSubmission")
    submission = data.get("data")
    if submission:
        submission_id = submission["id"]
        print(f"  Cancelling submission {submission_id}...")
        delete(f"/appStoreVersionSubmissions/{submission_id}")
        print("  Submission cancelled.")
        return True
    else:
        print("  No active submission found.")
        return False


def push_metadata(version_id):
    """Push all localized metadata for a version."""
    locs = get(f"/appStoreVersions/{version_id}/appStoreVersionLocalizations")
    existing = {l["attributes"]["locale"]: l["id"] for l in locs.get("data", [])}
    print(f"  Existing localizations: {list(existing.keys())}")

    for meta_locale, asc_locale in LOCALE_MAP.items():
        locale_dir = os.path.join(META_DIR, meta_locale)
        if not os.path.isdir(locale_dir):
            print(f"  Skipping {asc_locale} — no metadata directory")
            continue

        desc_file = os.path.join(locale_dir, "description.txt")
        kw_file = os.path.join(locale_dir, "keywords.txt")
        promo_file = os.path.join(locale_dir, "promotional_text.txt")

        desc = open(desc_file).read().strip() if os.path.exists(desc_file) else ""
        kw = open(kw_file).read().strip() if os.path.exists(kw_file) else ""
        promo = open(promo_file).read().strip() if os.path.exists(promo_file) else ""
        if len(kw) > 100:
            print(f"  WARNING: {asc_locale} keywords are {len(kw)} chars (max 100), truncating")
            kw = kw[:100]
            last_comma = kw.rfind(",")
            if last_comma > 0:
                kw = kw[:last_comma]

        # whatsNew is not allowed on the first version (1.0)
        attrs = {
            "description": desc,
            "keywords": kw,
            "promotionalText": promo,
        }

        if asc_locale in existing:
            print(f"  Updating {asc_locale}...")
            patch(f"/appStoreVersionLocalizations/{existing[asc_locale]}", {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "id": existing[asc_locale],
                    "attributes": attrs,
                }
            })
        else:
            print(f"  Creating {asc_locale}...")
            post("/appStoreVersionLocalizations", {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "attributes": {
                        "locale": asc_locale,
                        **attrs,
                    },
                    "relationships": {
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": version_id}
                        }
                    }
                }
            })
    print("  Metadata push complete.")


def push_app_info(app_id):
    """Push localized app name and subtitle via appInfoLocalizations."""
    infos = get(f"/apps/{app_id}/appInfos")
    info_list = infos.get("data", [])
    if not info_list:
        print("  No appInfo found, skipping name/subtitle push.")
        return
    info_id = info_list[0]["id"]
    locs = get(f"/appInfos/{info_id}/appInfoLocalizations")
    existing = {l["attributes"]["locale"]: l["id"] for l in locs.get("data", [])}
    print(f"  Existing appInfo localizations: {list(existing.keys())}")

    for meta_locale, asc_locale in LOCALE_MAP.items():
        locale_dir = os.path.join(META_DIR, meta_locale)
        if not os.path.isdir(locale_dir):
            continue
        name_file = os.path.join(locale_dir, "name.txt")
        subtitle_file = os.path.join(locale_dir, "subtitle.txt")
        name = open(name_file).read().strip() if os.path.exists(name_file) else ""
        subtitle = open(subtitle_file).read().strip() if os.path.exists(subtitle_file) else ""
        if not name and not subtitle:
            continue
        attrs = {}
        if name:
            attrs["name"] = name
        if subtitle:
            attrs["subtitle"] = subtitle

        if asc_locale in existing:
            print(f"  Updating appInfo {asc_locale}: name={name!r}, subtitle={subtitle!r}")
            patch(f"/appInfoLocalizations/{existing[asc_locale]}", {
                "data": {
                    "type": "appInfoLocalizations",
                    "id": existing[asc_locale],
                    "attributes": attrs,
                }
            })
        else:
            print(f"  Creating appInfo {asc_locale}: name={name!r}, subtitle={subtitle!r}")
            post("/appInfoLocalizations", {
                "data": {
                    "type": "appInfoLocalizations",
                    "attributes": {"locale": asc_locale, **attrs},
                    "relationships": {
                        "appInfo": {
                            "data": {"type": "appInfos", "id": info_id}
                        }
                    }
                }
            })
    print("  App info push complete.")


def submit_for_review(version_id):
    post("/appStoreVersionSubmissions", {
        "data": {
            "type": "appStoreVersionSubmissions",
            "relationships": {
                "appStoreVersion": {
                    "data": {"type": "appStoreVersions", "id": version_id}
                }
            }
        }
    })
    print("  Submitted for review!")


def main():
    app_id = find_app()
    versions = get_versions(app_id)

    if not versions:
        print("No versions found.")
        sys.exit(1)

    for v in versions:
        state = v["attributes"]["appStoreState"]
        vstring = v["attributes"]["versionString"]
        platform = v["attributes"].get("platform", "unknown")
        vid = v["id"]
        print(f"\nVersion {vstring} ({platform}): {state} [ID: {vid}]")

        if state in ("WAITING_FOR_REVIEW", "IN_REVIEW"):
            print("  Attempting to cancel submission...")
            try:
                cancel_submission(vid)
                # Wait a moment for state to update
                time.sleep(2)
            except Exception as e:
                print(f"  Failed to cancel: {e}")
                print("  Skipping this version (may be IN_REVIEW and uncancellable).")
                continue

        # Re-fetch to confirm state
        updated = get(f"/appStoreVersions/{vid}")
        new_state = updated["data"]["attributes"]["appStoreState"]
        print(f"  Current state: {new_state}")

        if new_state == "PREPARE_FOR_SUBMISSION":
            print("  Pushing version metadata...")
            push_metadata(vid)
            print("  Pushing app name & subtitle...")
            push_app_info(app_id)
            print("  Submitting for review...")
            submit_for_review(vid)
        elif new_state == "READY_FOR_SALE":
            print("  Already live, skipping.")
        else:
            print(f"  Unexpected state {new_state}, skipping.")


if __name__ == "__main__":
    main()
