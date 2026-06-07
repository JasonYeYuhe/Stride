#!/usr/bin/env python3
"""Upload the App Review screenshot for a StoreKit-managed (v2) in-app purchase.

The existing setup_iap.py handles auto-renewable subscriptions; this fills the gap
for the new In-App Purchases system (non-consumables / consumables), whose review
screenshot uses the inAppPurchaseAppStoreReviewScreenshots endpoint.

Usage:
    python3 scripts/upload_iap_screenshot.py <productId> <image.png>

Reads ASC creds from scripts/.env (ASC_API_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH).
"""
import os, sys, time, hashlib, jwt, requests
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))
KEY_ID = os.environ["ASC_API_KEY_ID"]
ISS = os.environ["ASC_ISSUER_ID"]
KEY = os.path.expanduser(os.environ["ASC_KEY_PATH"])
BASE = "https://api.appstoreconnect.apple.com/v1"
BUNDLE = os.environ.get("ASC_BUNDLE_ID", "yyh.stride.habittracker")

if len(sys.argv) != 3:
    print(__doc__); sys.exit(1)
PRODUCT_ID, IMG = sys.argv[1], sys.argv[2]

def token():
    now = int(time.time())
    return jwt.encode({"iss": ISS, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
                      open(KEY).read(), algorithm="ES256", headers={"kid": KEY_ID})
def H(): return {"Authorization": f"Bearer {token()}", "Content-Type": "application/json"}
def get(p, params=None):
    r = requests.get(BASE + p, headers=H(), params=params); r.raise_for_status(); return r.json()
def post(p, d):
    r = requests.post(BASE + p, headers=H(), json=d)
    if not r.ok: print("POST", p, r.status_code, r.text[:600])
    r.raise_for_status(); return r.json()
def patch(p, d):
    r = requests.patch(BASE + p, headers=H(), json=d)
    if not r.ok: print("PATCH", p, r.status_code, r.text[:600])
    r.raise_for_status(); return r.json()
def delete(p):
    return requests.delete(BASE + p, headers=H()).status_code

app_id = get("/apps", {"filter[bundleId]": BUNDLE})["data"][0]["id"]
iap = get(f"/apps/{app_id}/inAppPurchasesV2", {"filter[productId]": PRODUCT_ID})["data"][0]
iap_id = iap["id"]
print(f"IAP {iap['attributes']['name']} ({PRODUCT_ID}) id={iap_id} state={iap['attributes'].get('state')}")

# replace any existing review screenshot
try:
    ex = get(f"/inAppPurchases/{iap_id}/appStoreReviewScreenshot").get("data")
    if ex:
        print("deleting existing screenshot", ex["id"], "->", delete(f"/inAppPurchaseAppStoreReviewScreenshots/{ex['id']}"))
except Exception:
    pass

data = open(IMG, "rb").read()
res = post("/inAppPurchaseAppStoreReviewScreenshots", {
    "data": {"type": "inAppPurchaseAppStoreReviewScreenshots",
             "attributes": {"fileName": os.path.basename(IMG), "fileSize": len(data)},
             "relationships": {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iap_id}}}}})
sc = res["data"]; sc_id = sc["id"]
for op in sc["attributes"].get("uploadOperations", []):
    h = {x["name"]: x["value"] for x in op["requestHeaders"]}
    rr = requests.request(op["method"], op["url"], headers=h, data=data[op["offset"]:op["offset"] + op["length"]])
    rr.raise_for_status()
patch(f"/inAppPurchaseAppStoreReviewScreenshots/{sc_id}", {
    "data": {"type": "inAppPurchaseAppStoreReviewScreenshots", "id": sc_id,
             "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
for _ in range(12):
    time.sleep(5)
    st = get(f"/inAppPurchaseAppStoreReviewScreenshots/{sc_id}")["data"]["attributes"].get("assetDeliveryState", {})
    print("assetDeliveryState:", st.get("state"))
    if st.get("state") in ("COMPLETE", "FAILED"):
        break
print("FINAL IAP state:", get(f"/apps/{app_id}/inAppPurchasesV2", {"filter[productId]": PRODUCT_ID})["data"][0]["attributes"]["state"])
