#!/usr/bin/env python3
"""Drive a Stride App Store release through the ASC API, per platform, idempotently.

    scripts/release.py prepare 1.2.1     # create the version records + What's New
    scripts/release.py finish  1.2.1 15  # attach build N, then submit for review
    scripts/release.py show    1.2.1     # report state without changing anything

Why this exists: scripts/asc_api.py is platform-blind (it grabs versions[0] and
hopes) and still posts to appStoreVersionSubmissions, which Apple replaced with
reviewSubmissions — that is why 1.2.0's final submit had to be finished by hand in
Chrome. Every step here is re-runnable: it looks for the object first and only
creates what is missing, so a half-finished release is fixed by running it again.
"""

import sys, time
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import asc_api as a

PLATFORMS = ["IOS", "MAC_OS"]
LOCALES = ["en-US", "zh-Hans", "zh-Hant", "ja", "ko", "es-ES"]

WHATS_NEW = {
    "en-US": "Fixes a bug that stopped Stride from reporting crashes, so any problem "
             "you hit now reaches us and gets fixed faster. No changes to your habits or data.",
    "zh-Hans": "修复了崩溃上报失效的问题——现在你遇到的任何异常都能传回来,修得更快。习惯和数据不受影响。",
    "zh-Hant": "修正了當機回報失效的問題——現在你遇到的任何異常都能傳回來,修得更快。習慣與資料不受影響。",
    "ja": "クラッシュレポートが送信されない不具合を修正しました。問題が届くようになり、修正が早くなります。習慣とデータに変更はありません。",
    "ko": "충돌 보고가 전송되지 않던 문제를 수정했습니다. 이제 문제가 접수되어 더 빨리 해결됩니다. 습관과 데이터는 그대로입니다.",
    "es-ES": "Corrige un fallo que impedía a Stride informar de los cierres inesperados, "
             "así cualquier problema nos llega y se arregla antes. Tus hábitos y datos no cambian.",
}


def versions(app_id, version_string):
    """All appStoreVersions with this versionString, keyed by platform."""
    d = a.get(f"/apps/{app_id}/appStoreVersions", params={
        "filter[versionString]": version_string, "limit": 20,
        "fields[appStoreVersions]": "versionString,platform,appStoreState",
    })
    return {v["attributes"]["platform"]: v for v in d["data"]}


def previous_localizations(app_id, platform, exclude_version):
    """Metadata from the newest other version on this platform, to copy forward."""
    d = a.get(f"/apps/{app_id}/appStoreVersions", params={
        "filter[platform]": platform, "limit": 10,
        "fields[appStoreVersions]": "versionString,platform,appStoreState",
    })
    for v in d["data"]:
        if v["id"] == exclude_version:
            continue
        locs = a.get_version_localizations(v["id"])
        if locs:
            return {l["attributes"]["locale"]: l["attributes"] for l in locs}
    return {}


def ensure_version(app_id, platform, version_string):
    existing = versions(app_id, version_string).get(platform)
    if existing:
        print(f"  [{platform}] version {version_string} already exists "
              f"({existing['attributes']['appStoreState']})")
        return existing["id"]
    print(f"  [{platform}] creating version {version_string}...")
    r = a.post("/appStoreVersions", {"data": {
        "type": "appStoreVersions",
        "attributes": {"platform": platform, "versionString": version_string,
                       "releaseType": "AFTER_APPROVAL"},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
    }})
    return r["data"]["id"]


def ensure_localizations(app_id, platform, version_id):
    have = {l["attributes"]["locale"]: l for l in a.get_version_localizations(version_id)}
    prev = previous_localizations(app_id, platform, version_id) if len(have) < len(LOCALES) else {}
    for loc in LOCALES:
        whats_new = WHATS_NEW[loc]
        if loc in have:
            if have[loc]["attributes"].get("whatsNew") == whats_new:
                print(f"    {loc}: what's-new already set")
                continue
            a.update_localization(have[loc]["id"], whats_new=whats_new)
            print(f"    {loc}: what's-new updated")
        else:
            src = prev.get(loc, {})
            a.create_localization(
                version_id, loc,
                description=src.get("description", "") or "",
                keywords=src.get("keywords", "") or "",
                promotional_text=src.get("promotionalText", "") or "",
                whats_new=whats_new)
            print(f"    {loc}: created" + (" (metadata copied forward)" if src else " (EMPTY metadata — fill it in)"))


def find_build(app_id, build_number, platform):
    d = a.get("/builds", params={
        "filter[app]": app_id, "filter[version]": str(build_number),
        "limit": 20, "include": "preReleaseVersion",
        # preReleaseVersion MUST be listed here. fields[builds] is a whitelist over
        # relationships too, so omitting it makes ASC return the builds with an EMPTY
        # relationships object while still shipping the preReleaseVersions in
        # `included` — the platform can then never be matched, find_build returns None
        # for a build that plainly exists, and the caller waits out its whole timeout.
        "fields[builds]": "version,processingState,expired,uploadedDate,preReleaseVersion",
        "fields[preReleaseVersions]": "platform,version",
    })
    pre = {i["id"]: i["attributes"]["platform"] for i in d.get("included", [])
           if i["type"] == "preReleaseVersions"}
    for b in d["data"]:
        rel = b.get("relationships", {}).get("preReleaseVersion", {}).get("data")
        if rel and pre.get(rel["id"]) == platform and not b["attributes"].get("expired"):
            return b
    return None


def attach_build(version_id, build_id):
    a.patch(f"/appStoreVersions/{version_id}/relationships/build",
            {"data": {"type": "builds", "id": build_id}})


def submit(app_id, platform, version_id):
    """reviewSubmissions is the current API; appStoreVersionSubmissions is retired."""
    d = a.get("/reviewSubmissions", params={
        "filter[app]": app_id, "filter[platform]": platform,
        "filter[state]": "READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW", "limit": 10})
    sub = d["data"][0] if d["data"] else None
    if sub is None:
        sub = a.post("/reviewSubmissions", {"data": {
            "type": "reviewSubmissions",
            "attributes": {"platform": platform},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }})["data"]
        print(f"  [{platform}] created review submission {sub['id']}")
    state = sub["attributes"]["state"]
    if state != "READY_FOR_REVIEW":
        print(f"  [{platform}] submission {sub['id']} is {state} — nothing more to do")
        return
    items = a.get(f"/reviewSubmissions/{sub['id']}/items", params={"limit": 20})["data"]
    if not any(i.get("relationships", {}).get("appStoreVersion", {}).get("data", {}).get("id") == version_id
               for i in items):
        a.post("/reviewSubmissionItems", {"data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub["id"]}},
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}},
            }}})
        print(f"  [{platform}] added version to submission")
    a.patch(f"/reviewSubmissions/{sub['id']}", {"data": {
        "type": "reviewSubmissions", "id": sub["id"], "attributes": {"submitted": True}}})
    print(f"  [{platform}] SUBMITTED for review")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "show"
    version_string = sys.argv[2] if len(sys.argv) > 2 else None
    build_number = sys.argv[3] if len(sys.argv) > 3 else None
    if not version_string:
        print(__doc__); return 1
    app_id = a.find_app()

    if cmd == "show":
        for p, v in versions(app_id, version_string).items():
            at = v["attributes"]
            print(f"  {p:8} {at['versionString']:8} {at['appStoreState']}")
            for l in a.get_version_localizations(v["id"]):
                print(f"      {l['attributes']['locale']:8} whatsNew="
                      f"{(l['attributes'].get('whatsNew') or '')[:48]!r}")
        return 0

    if cmd == "prepare":
        for p in PLATFORMS:
            vid = ensure_version(app_id, p, version_string)
            ensure_localizations(app_id, p, vid)
        return 0

    if cmd == "finish":
        if not build_number:
            print("finish needs a build number"); return 1
        for p in PLATFORMS:
            vid = versions(app_id, version_string).get(p, {}).get("id")
            if not vid:
                print(f"  [{p}] no {version_string} version — run prepare first"); continue
            b = find_build(app_id, build_number, p)
            for _ in range(60):          # processing usually lands inside 15 min
                if b and b["attributes"]["processingState"] == "VALID":
                    break
                print(f"  [{p}] build {build_number} "
                      f"{b['attributes']['processingState'] if b else 'not uploaded yet'} — waiting 60s")
                time.sleep(60)
                b = find_build(app_id, build_number, p)
            else:
                print(f"  [{p}] build {build_number} never became VALID — stopping"); continue
            attach_build(vid, b["id"])
            print(f"  [{p}] attached build {build_number}")
            submit(app_id, p, vid)
        return 0

    print(__doc__); return 1


if __name__ == "__main__":
    sys.exit(main())
