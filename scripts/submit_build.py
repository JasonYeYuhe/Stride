#!/usr/bin/env python3
"""Select build 8 for v1.0.0 and submit for review."""

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


def token():
    with open(KEY_PATH) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": API_KEY_ID}
    )


def headers():
    return {"Authorization": f"Bearer {token()}", "Content-Type": "application/json"}


def get(path, params=None):
    r = requests.get(f"{BASE}{path}", headers=headers(), params=params)
    r.raise_for_status()
    return r.json()


def patch(path, data):
    r = requests.patch(f"{BASE}{path}", headers=headers(), json=data)
    if not r.ok:
        print(f"PATCH {path}: {r.status_code}\n{r.text[:500]}")
    r.raise_for_status()
    return r.json()


def post(path, data):
    r = requests.post(f"{BASE}{path}", headers=headers(), json=data)
    if not r.ok:
        print(f"POST {path}: {r.status_code}\n{r.text[:500]}")
    r.raise_for_status()
    return r.json()


# 1. Find app
app_data = get("/apps", params={"filter[bundleId]": BUNDLE_ID})
app_id = app_data["data"][0]["id"]
print(f"App: {app_id}")

# 2. Get version (any editable state)
versions = get(f"/apps/{app_id}/appStoreVersions", params={
    "filter[appStoreState]": "PREPARE_FOR_SUBMISSION,WAITING_FOR_REVIEW,IN_REVIEW,DEVELOPER_REJECTED,REJECTED",
    "limit": 5,
})["data"]

if not versions:
    # Try broader query
    versions = get(f"/apps/{app_id}/appStoreVersions", params={"limit": 5})["data"]

for v in versions:
    s = v["attributes"]["appStoreState"]
    vs = v["attributes"]["versionString"]
    print(f"  Version {vs}: {s} (ID: {v['id']})")

version = versions[0]
version_id = version["id"]
version_state = version["attributes"]["appStoreState"]
print(f"\nUsing version {version['attributes']['versionString']} ({version_state})")

# 3. Find build 8
builds = get("/builds", params={
    "filter[app]": app_id,
    "filter[version]": "8",
    "sort": "-uploadedDate",
    "limit": 1,
})["data"]

if not builds:
    print("ERROR: Build 8 not found")
    sys.exit(1)

build_id = builds[0]["id"]
build_version = builds[0]["attributes"]["version"]
print(f"Build: {build_version} (ID: {build_id})")

# 4. Select build for this version
print("\nSelecting build...")
patch(f"/appStoreVersions/{version_id}", {
    "data": {
        "type": "appStoreVersions",
        "id": version_id,
        "relationships": {
            "build": {
                "data": {"type": "builds", "id": build_id}
            }
        }
    }
})
print("Build 8 selected!")

# 5. Submit for review
print("\nSubmitting for review...")
try:
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
    print("Submitted for review!")
except requests.HTTPError as e:
    # Try the newer reviewSubmissions endpoint
    print(f"Legacy submit failed, trying reviewSubmissions...")
    try:
        post("/reviewSubmissions", {
            "data": {
                "type": "reviewSubmissions",
                "attributes": {
                    "platform": "IOS"
                },
                "relationships": {
                    "app": {
                        "data": {"type": "apps", "id": app_id}
                    }
                }
            }
        })
        print("Submitted for review!")
    except requests.HTTPError as e2:
        print(f"Submit failed: {e2}")
        print("You may need to add the screen recording note in ASC first.")
