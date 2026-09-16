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

WHATS_NEW_BY_VERSION = {
  "1.2.1": {
    "en-US": "Fixes a bug that stopped Stride from reporting crashes, so any problem "
             "you hit now reaches us and gets fixed faster. No changes to your habits or data.",
    "zh-Hans": "修复了崩溃上报失效的问题——现在你遇到的任何异常都能传回来,修得更快。习惯和数据不受影响。",
    "zh-Hant": "修正了當機回報失效的問題——現在你遇到的任何異常都能傳回來,修得更快。習慣與資料不受影響。",
    "ja": "クラッシュレポートが送信されない不具合を修正しました。問題が届くようになり、修正が早くなります。習慣とデータに変更はありません。",
    "ko": "충돌 보고가 전송되지 않던 문제를 수정했습니다. 이제 문제가 접수되어 더 빨리 해결됩니다. 습관과 데이터는 그대로입니다.",
    "es-ES": "Corrige un fallo que impedía a Stride informar de los cierres inesperados, "
             "así cualquier problema nos llega y se arregla antes. Tus hábitos y datos no cambian.",
  },
  "1.2.2": {
    "en-US": "Widgets are here. Earlier versions shipped without them by mistake — add Stride "
             "to your Home Screen or Lock Screen. This update also fixes cross-device sync, "
             "which wasn't saving your check-ins to the server or carrying deletions between "
             "devices, and corrects streaks for \u201cSpecific days\u201d habits in time zones "
             "behind UTC.",
    "zh-Hans": "小组件回来了 —— 之前的版本因失误没有打包进去,现在可以把 Stride 添加到主屏幕和锁定屏幕。"
               "本次更新还修复了跨设备同步(此前打卡记录没有真正上传到服务器,删除也不会同步到其他设备),"
               "以及 UTC 以西时区下「指定日期」习惯连续天数计算错误的问题。",
    "zh-Hant": "小工具回來了 —— 先前的版本因疏失沒有打包進去,現在可以把 Stride 加入主畫面和鎖定畫面。"
               "本次更新也修正了跨裝置同步(先前打卡紀錄沒有真正上傳到伺服器,刪除也不會同步到其他裝置),"
               "以及 UTC 以西時區下「指定日期」習慣連續天數計算錯誤的問題。",
    "ja": "ウィジェットが使えるようになりました。これまでのバージョンでは手違いで含まれていませんでした。"
          "ホーム画面やロック画面に追加できます。今回の更新では、チェックインがサーバーに保存されず削除も"
          "他の端末に反映されなかったデバイス間同期の不具合と、UTCより西のタイムゾーンで「特定の曜日」の"
          "習慣の連続日数が正しく計算されない問題も修正しました。",
    "ko": "위젯을 사용할 수 있습니다. 이전 버전에는 실수로 포함되지 않았습니다. 홈 화면과 잠금 화면에 "
          "Stride를 추가해 보세요. 이번 업데이트에서는 체크인이 서버에 저장되지 않고 삭제도 다른 기기에 "
          "반영되지 않던 기기 간 동기화 문제와, UTC보다 서쪽 시간대에서 \u2018특정 요일\u2019 습관의 "
          "연속 일수가 잘못 계산되던 문제도 함께 수정했습니다.",
    "es-ES": "Ya están los widgets. Las versiones anteriores se publicaron sin ellos por error: "
             "añade Stride a tu pantalla de inicio o de bloqueo. Esta actualización también "
             "corrige la sincronización entre dispositivos, que no guardaba tus registros en el "
             "servidor ni propagaba las eliminaciones, y arregla las rachas de los hábitos de "
             "\u201cDías concretos\u201d en zonas horarias al oeste de UTC.",
  },
  "1.2.3": {
    "en-US": "A reliability release for anything you track across devices.\n\n"
             "\u2022 Sync keeps the newer edit. A device coming back online no longer "
             "overwrites a measurable habit you logged elsewhere, and edits made offline now "
             "reach your other devices.\n"
             "\u2022 Checking off a measurable habit from the widget, watch or Siri adds to the "
             "day instead of erasing it.\n"
             "\u2022 Best streak and completion rates now follow each habit\u2019s schedule, so "
             "\u201cMon/Wed/Fri\u201d and \u201c3\u00d7 a week\u201d habits are scored the way "
             "you actually do them.\n"
             "\u2022 Reminders stop when you delete or archive a habit.\n"
             "\u2022 Reopening the app the next morning shows today, not yesterday, and the "
             "widget refreshes as soon as anything changes.\n"
             "\u2022 Purchases that can\u2019t be verified now say so instead of failing quietly, "
             "and Pro unlocks right at launch.\n"
             "\u2022 The whole app is translated \u2014 onboarding, templates, the habit editor, "
             "Weekly Review and more no longer fall back to English.",
    "zh-Hans": "这是一次围绕可靠性的更新，尤其是多设备同步。\n\n"
               "\u2022 同步以较新的修改为准：久未联网的设备重新上线，不会再覆盖你在别处记录的计量型习惯；"
               "离线时的修改现在也能同步到其他设备。\n"
               "\u2022 从小组件、手表或 Siri 打卡计量型习惯时，会在当天的记录上累加，而不是清空。\n"
               "\u2022 最佳连续和完成率会按习惯自身的频率计算，「周一/三/五」和「每周 3 次」这类习惯"
               "不再被当成每天都要做。\n"
               "\u2022 删除或归档习惯后，对应的提醒会一并取消。\n"
               "\u2022 隔夜再打开 App 会显示今天而不是昨天；数据一有变化，小组件立即刷新。\n"
               "\u2022 无法验证的购买会给出明确提示，不再无声失败；启动时立即解锁 Pro。\n"
               "\u2022 全应用完成本地化：引导页、模板、习惯编辑器、每周回顾等不再显示英文。",
    "zh-Hant": "這是一次圍繞可靠性的更新，尤其是多裝置同步。\n\n"
               "\u2022 同步以較新的修改為準：久未連網的裝置重新上線，不會再覆蓋你在別處記錄的計量型習慣；"
               "離線時的修改現在也能同步到其他裝置。\n"
               "\u2022 從小工具、手錶或 Siri 打卡計量型習慣時，會在當天的紀錄上累加，而不是清空。\n"
               "\u2022 最佳連續和完成率會按習慣自身的頻率計算，「週一/三/五」和「每週 3 次」這類習慣"
               "不再被當成每天都要做。\n"
               "\u2022 刪除或封存習慣後，對應的提醒會一併取消。\n"
               "\u2022 隔夜再打開 App 會顯示今天而不是昨天；資料一有變化，小工具立即刷新。\n"
               "\u2022 無法驗證的購買會給出明確提示，不再無聲失敗；啟動時立即解鎖 Pro。\n"
               "\u2022 全應用完成在地化：導覽頁、範本、習慣編輯器、每週回顧等不再顯示英文。",
    "ja": "複数の端末で使うときの信頼性を高める更新です。\n\n"
          "\u2022 同期は新しい編集を優先します。久しぶりに接続した端末が、他の端末で記録した"
          "数値型の習慣を上書きすることはなくなりました。オフライン中の編集も他の端末に届きます。\n"
          "\u2022 ウィジェット、Apple Watch、Siri から数値型の習慣を記録すると、その日の記録に"
          "加算されます（消えなくなりました）。\n"
          "\u2022 最長記録と達成率が習慣ごとの頻度に従うようになり、「月・水・金」や「週3回」の"
          "習慣も実際のやり方どおりに評価されます。\n"
          "\u2022 習慣を削除・アーカイブすると、その通知も止まります。\n"
          "\u2022 翌朝アプリを開くと昨日ではなく今日が表示され、変更があるとウィジェットがすぐ"
          "更新されます。\n"
          "\u2022 確認できなかった購入は理由を表示するようになり、起動直後に Pro が有効になります。\n"
          "\u2022 アプリ全体を翻訳しました。オンボーディング、テンプレート、習慣の編集画面、"
          "週間レビューなどが英語のままになることはありません。",
    "ko": "여러 기기에서 쓸 때의 안정성을 높인 업데이트입니다.\n\n"
          "\u2022 동기화가 더 최신 편집을 유지합니다. 오랜만에 연결된 기기가 다른 기기에서 기록한 "
          "수치형 습관을 덮어쓰지 않으며, 오프라인에서 한 편집도 다른 기기에 전달됩니다.\n"
          "\u2022 위젯, 애플 워치, Siri에서 수치형 습관을 체크하면 그날의 기록에 더해집니다(지워지지 않습니다).\n"
          "\u2022 최고 연속과 달성률이 습관별 빈도를 따릅니다. \u2018월/수/금\u2019이나 \u2018주 3회\u2019 "
          "습관도 실제 방식대로 계산됩니다.\n"
          "\u2022 습관을 삭제하거나 보관하면 해당 알림도 함께 중지됩니다.\n"
          "\u2022 다음 날 아침 앱을 열면 어제가 아닌 오늘이 표시되고, 변경 사항이 생기면 위젯이 바로 갱신됩니다.\n"
          "\u2022 확인할 수 없는 구매는 이유를 알려 주며, 실행 즉시 Pro가 적용됩니다.\n"
          "\u2022 앱 전체를 번역했습니다. 온보딩, 템플릿, 습관 편집기, 주간 리뷰 등이 더 이상 영어로 "
          "표시되지 않습니다.",
    "es-ES": "Una actualización centrada en la fiabilidad, sobre todo entre dispositivos.\n\n"
             "\u2022 La sincronización conserva la edición más reciente: un dispositivo que vuelve "
             "a conectarse ya no sobrescribe un hábito medible que registraste en otro, y lo que "
             "editas sin conexión llega al resto de tus dispositivos.\n"
             "\u2022 Marcar un hábito medible desde el widget, el reloj o Siri suma al día en "
             "lugar de borrarlo.\n"
             "\u2022 La mejor racha y las tasas de cumplimiento siguen la frecuencia de cada "
             "hábito, así que \u201clunes/miércoles/viernes\u201d y \u201c3 veces por semana\u201d "
             "se puntúan como los haces de verdad.\n"
             "\u2022 Los recordatorios se cancelan al eliminar o archivar un hábito.\n"
             "\u2022 Al volver a la app a la mañana siguiente verás hoy, no ayer, y el widget se "
             "actualiza en cuanto algo cambia.\n"
             "\u2022 Las compras que no se pueden verificar ahora lo indican en vez de fallar en "
             "silencio, y Pro se activa nada más abrir la app.\n"
             "\u2022 Toda la app está traducida: la introducción, las plantillas, el editor de "
             "hábitos y el resumen semanal ya no aparecen en inglés.",
  },
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


def ensure_localizations(app_id, platform, version_id, version_string):
    whats_new_all = WHATS_NEW_BY_VERSION.get(version_string)
    if whats_new_all is None:
        raise SystemExit(f"No What's New copy for {version_string} — add it to "
                         f"WHATS_NEW_BY_VERSION in this script before releasing.")
    have = {l["attributes"]["locale"]: l for l in a.get_version_localizations(version_id)}
    prev = previous_localizations(app_id, platform, version_id) if len(have) < len(LOCALES) else {}
    for loc in LOCALES:
        whats_new = whats_new_all[loc]
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


def submission_versions(sub_id):
    """appStoreVersion ids in a review submission.

    `include=appStoreVersion` is required: without it every item comes back with empty
    relationships, and the old "is this version already in the submission?" test was
    always false.
    """
    items = a.get(f"/reviewSubmissions/{sub_id}/items",
                  params={"include": "appStoreVersion", "limit": 50})["data"]
    return {(i.get("relationships", {}).get("appStoreVersion", {}).get("data") or {}).get("id")
            for i in items} - {None}


def submit(app_id, platform, version_id):
    """Submit `version_id` for review. Returns True only if it is now submitted.

    reviewSubmissions is the current API; appStoreVersionSubmissions is retired.

    This used to take the first open submission it found and, if that one was already
    WAITING_FOR_REVIEW or IN_REVIEW, print "nothing more to do" and return — without looking
    at WHICH version it held. With 1.2.1 still in review, `finish 1.2.2` would have attached
    the build, printed that line, exited 0, and never submitted 1.2.2.
    """
    d = a.get("/reviewSubmissions", params={
        "filter[app]": app_id, "filter[platform]": platform,
        "filter[state]": "READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW", "limit": 10})
    draft = None
    for sub in d["data"]:
        state = sub["attributes"]["state"]
        held = submission_versions(sub["id"])
        if state == "READY_FOR_REVIEW":
            draft = sub
        elif version_id in held:
            print(f"  [{platform}] already submitted: submission {sub['id']} is {state}")
            return True
        else:
            print(f"  [{platform}] NOT SUBMITTED: submission {sub['id']} is {state} with another "
                  f"version ({', '.join(sorted(held)) or 'unknown'}). Wait for it to finish, or "
                  f"remove it in App Store Connect, then run finish again.")
            return False

    sub = draft
    if sub is None:
        sub = a.post("/reviewSubmissions", {"data": {
            "type": "reviewSubmissions",
            "attributes": {"platform": platform},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }})["data"]
        print(f"  [{platform}] created review submission {sub['id']}")
    if version_id not in submission_versions(sub["id"]):
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
    return True


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
            ensure_localizations(app_id, p, vid, version_string)
        return 0

    if cmd == "finish":
        if not build_number:
            print("finish needs a build number"); return 1
        # Every platform that doesn't end up submitted is named here and makes the exit code
        # non-zero. Each of these used to be a `continue` and the command still exited 0.
        not_submitted = []
        for p in PLATFORMS:
            vid = versions(app_id, version_string).get(p, {}).get("id")
            if not vid:
                print(f"  [{p}] no {version_string} version — run prepare first")
                not_submitted.append(p); continue
            b = find_build(app_id, build_number, p)
            for _ in range(60):          # processing usually lands inside 15 min
                if b and b["attributes"]["processingState"] == "VALID":
                    break
                print(f"  [{p}] build {build_number} "
                      f"{b['attributes']['processingState'] if b else 'not uploaded yet'} — waiting 60s")
                time.sleep(60)
                b = find_build(app_id, build_number, p)
            else:
                print(f"  [{p}] build {build_number} never became VALID — stopping")
                not_submitted.append(p); continue
            attach_build(vid, b["id"])
            print(f"  [{p}] attached build {build_number}")
            if not submit(app_id, p, vid):
                not_submitted.append(p)
        if not_submitted:
            print(f"FAILED: {version_string} was NOT submitted for {', '.join(not_submitted)}")
            return 1
        return 0

    print(__doc__); return 1


if __name__ == "__main__":
    sys.exit(main())
