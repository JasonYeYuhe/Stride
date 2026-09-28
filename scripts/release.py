#!/usr/bin/env python3
"""Drive a Stride App Store release through the ASC API, per platform, idempotently.

    scripts/release.py prepare 1.2.1     # create the version records + What's New
    scripts/release.py finish  1.2.1 15  # attach build N, then submit for review
    scripts/release.py release 1.2.1     # after approval + the device check: go live
    scripts/release.py cancel  1.2.1     # pull a version out of review (e.g. to swap its build)
    scripts/release.py show    1.2.1     # report state without changing anything

Versions are created with releaseType MANUAL: an approved version waits in
PENDING_DEVELOPER_RELEASE until `release` is run. It used to be AFTER_APPROVAL, so an
approval could publish a build before anyone had tapped a sign-in link on a real device —
1.3.0 was switched to MANUAL while already in review (2026-09-28) for exactly that.

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
  "1.3.0": {
    "en-US": "Backup and restore, a large widget, one-tap sign-in, and text that reads right "
             "in every language.\n\n"
             "\u2022 Export as JSON now saves a complete backup: every habit, group, schedule, "
             "target, note and check-in. On a device with no habits, Restore from Backup in "
             "Settings brings it all back, and Erase Local Data clears a device first if you "
             "need to.\n"
             "\u2022 A large Home Screen widget on iPhone and iPad (and extra large on iPad) lists "
             "up to eight habits, each one a tap to check off. Widgets also turn over to the new "
             "day at midnight on their own.\n"
             "\u2022 Tap the link in the sign-in email and Stride opens already signed in, with no "
             "code to copy. If your mail app opens the link as a web page instead, the code is "
             "still there to paste.\n"
             "\u2022 Turning on a reminder while creating or editing a habit now asks for "
             "notification permission first. On a new install, those reminders were never "
             "delivered.\n"
             "\u2022 Chart labels, the heatmap and Today now grow with larger text sizes and stay "
             "readable at the largest ones.\n"
             "\u2022 Text fixes: \u201c1 day\u201d and \u201c1 check-in\u201d instead of \u201c1 "
             "days\u201d and \u201c1 check-ins\u201d; the \u201cweeks\u201d label in Stats and "
             "the widget gallery are translated in every language; and choosing English in "
             "Stride\u2019s language setting now applies everywhere."
             "\n\u2022 Checking a habit again right after unchecking it works the first time. Before, it stayed unchecked until Stride was reopened.",
    "zh-Hans": "本次更新带来备份与恢复、大尺寸小组件、一键登录，并修正了各语言的文字问题。\n\n"
               "\u2022 「导出为 JSON」现在会保存完整备份：每个习惯、分组、重复周期、目标、备注和打卡记录。"
               "在没有任何习惯的设备上，用设置里的「从备份恢复」即可全部找回；如有需要，可先用"
               "「抹掉本地数据」清空设备。\n"
               "\u2022 iPhone 和 iPad 主屏幕新增大尺寸小组件（iPad 上还有超大尺寸），最多列出 8 个习惯，"
               "轻点即可打卡。小组件到午夜也会自动切换到新的一天。\n"
               "\u2022 点一下登录邮件里的链接，Stride 就会打开并完成登录，无需复制代码。如果邮件 App "
               "把链接作为网页打开，页面上仍有代码可以粘贴。\n"
               "\u2022 在新建或编辑习惯时开启提醒，现在会先请求通知权限。此前在新安装的设备上，"
               "这类提醒从未送达。\n"
               "\u2022 图表标签、热力图和「今天」页面会随更大的字体一起放大，在最大字号下也清晰可读。\n"
               "\u2022 文字修正：统计中的「周」单位和小组件库中的预览不再显示英文；在 Stride 的语言设置中"
               "选择英语后，所有文字都会切换为英语。"
               "\n\u2022 取消打卡后立即再次打卡，现在会马上生效。此前需要重新打开 Stride 才能打卡。",
    "zh-Hant": "本次更新帶來備份與恢復、大型小工具、一鍵登入，並修正了各語言的文字問題。\n\n"
               "\u2022 「匯出為 JSON」現在會儲存完整備份：每個習慣、分組、排程、目標、備註和打卡紀錄。"
               "在沒有任何習慣的裝置上，用設定裡的「從備份恢復」即可全部找回；如有需要，可先用"
               "「清除本機資料」清空裝置。\n"
               "\u2022 iPhone 與 iPad 主畫面新增大型小工具（iPad 上還有超大型），最多列出 8 個習慣，"
               "點一下即可打卡。小工具到午夜也會自動切換到新的一天。\n"
               "\u2022 點一下登入郵件裡的連結，Stride 就會開啟並完成登入，不必複製代碼。如果郵件 App "
               "把連結當成網頁開啟，頁面上仍有代碼可以貼上。\n"
               "\u2022 在新增或編輯習慣時開啟提醒，現在會先請求通知權限。先前在新安裝的裝置上，"
               "這類提醒從未送達。\n"
               "\u2022 圖表標籤、熱力圖和「今天」頁面會隨更大的字級一起放大，在最大字級下也清晰易讀。\n"
               "\u2022 文字修正：統計中的「週」單位和小工具庫中的預覽不再顯示英文；在 Stride 的語言設定中"
               "選擇英文後，所有文字都會切換為英文。"
               "\n\u2022 取消打卡後立即再次打卡，現在會馬上生效。先前需要重新開啟 Stride 才能打卡。",
    "ja": "バックアップと復元、大きいウィジェット、ワンタップでのログイン、そして各言語の表記を"
          "直した更新です。\n\n"
          "\u2022 「JSON で書き出す」で、習慣・グループ・スケジュール・目標・メモ・チェックインを"
          "すべて含む完全なバックアップを保存できるようになりました。習慣がないデバイスなら、"
          "設定の「バックアップから復元」ですべて戻せます。必要なら先に「ローカルデータを消去」で"
          "デバイスを空にできます。\n"
          "\u2022 iPhone と iPad のホーム画面に大サイズのウィジェットを追加しました（iPad では特大"
          "サイズも）。最大8つの習慣を表示し、タップひとつで記録できます。ウィジェットは午前0時に"
          "自動で新しい日に切り替わります。\n"
          "\u2022 ログインメールのリンクをタップすると、Stride が開いてそのままログインします。"
          "コードのコピーは不要です。メールアプリがリンクを Web ページとして開いた場合は、"
          "これまでどおりコードを貼り付けられます。\n"
          "\u2022 習慣の作成・編集中にリマインダーをオンにすると、先に通知の許可を求めるように"
          "なりました。これまで新しくインストールした端末では、この通知が届きませんでした。\n"
          "\u2022 グラフのラベル、ヒートマップ、「今日」の画面が大きな文字サイズに合わせて拡大し、"
          "最大サイズでも読みやすくなりました。\n"
          "\u2022 表記の修正：統計の「週」の単位とウィジェットギャラリーのプレビューが英語のまま"
          "表示されなくなりました。Stride の言語設定で英語を選ぶと、すべての表示が英語になります。"
          "\n\u2022 チェックを外した直後に同じ習慣をもう一度チェックすると、すぐに記録されるようになりました。これまではアプリを開き直すまでチェックされないままでした。",
    "ko": "백업과 복원, 대형 위젯, 탭 한 번으로 로그인, 그리고 모든 언어의 문구를 바로잡은 "
          "업데이트입니다.\n\n"
          "\u2022 \u2018JSON으로 내보내기\u2019가 이제 습관, 그룹, 반복 주기, 목표, 메모, 체크인을 모두 "
          "담은 완전한 백업을 저장합니다. 습관이 없는 기기에서는 설정의 \u2018백업에서 복원\u2019으로 "
          "모두 되돌릴 수 있고, 필요하면 \u2018로컬 데이터 지우기\u2019로 기기를 먼저 비울 수 있습니다.\n"
          "\u2022 iPhone과 iPad 홈 화면에 대형 위젯이 추가되었습니다(iPad에서는 초대형도). 습관을 "
          "최대 8개까지 보여 주며, 탭 한 번으로 체크할 수 있습니다. 위젯은 자정이 되면 알아서 새 "
          "날로 넘어갑니다.\n"
          "\u2022 로그인 이메일의 링크를 탭하면 Stride가 열리면서 바로 로그인됩니다. 코드를 복사할 "
          "필요가 없습니다. 메일 앱이 링크를 웹 페이지로 열면, 예전처럼 코드를 붙여 넣으면 됩니다.\n"
          "\u2022 습관을 만들거나 편집하면서 알림을 켜면 이제 먼저 알림 권한을 요청합니다. 이전에는 "
          "새로 설치한 기기에서 이 알림이 전달되지 않았습니다.\n"
          "\u2022 차트 레이블, 히트맵, \u2018오늘\u2019 화면이 큰 텍스트 크기에 맞춰 커지며, 가장 큰 "
          "크기에서도 읽기 쉽습니다.\n"
          "\u2022 문구 수정: 통계의 \u2018주\u2019 단위와 위젯 갤러리 미리 보기가 더 이상 영어로 표시되지 "
          "않습니다. Stride의 언어 설정에서 영어를 고르면 모든 문구가 영어로 바뀝니다."
          "\n\u2022 체크를 해제한 직후 같은 습관을 다시 체크하면 바로 체크됩니다. 이전에는 Stride를 다시 열 때까지 체크되지 않았습니다.",
    "es-ES": "Copias de seguridad que se pueden restaurar, un widget grande, inicio de sesión con un "
             "toque y textos correctos en todos los idiomas.\n\n"
             "\u2022 \u201cExportar como JSON\u201d guarda ahora una copia de seguridad completa: "
             "todos los hábitos, grupos, frecuencias, objetivos, notas y registros. En un "
             "dispositivo sin hábitos, \u201cRestaurar desde copia de seguridad\u201d, en Ajustes, "
             "lo recupera todo, y \u201cBorrar datos locales\u201d vacía antes el dispositivo si "
             "lo necesitas.\n"
             "\u2022 Nuevo widget grande para la pantalla de inicio del iPhone y el iPad (y "
             "extragrande en el iPad): muestra hasta ocho hábitos y cada uno se marca con un toque. "
             "Los widgets también pasan solos al nuevo día a medianoche.\n"
             "\u2022 Toca el enlace del correo de inicio de sesión y Stride se abre con la sesión ya "
             "iniciada, sin copiar ningún código. Si tu app de correo abre el enlace como página "
             "web, el código sigue ahí para pegarlo.\n"
             "\u2022 Activar un recordatorio al crear o editar un hábito ahora pide primero permiso "
             "para las notificaciones. En una instalación nueva, esos recordatorios no llegaban "
             "nunca.\n"
             "\u2022 Las etiquetas de los gráficos, el mapa de calor y la pantalla Hoy crecen con los "
             "tamaños de texto grandes y se leen bien incluso en los mayores.\n"
             "\u2022 Textos corregidos: \u201cRacha de 1 día\u201d y \u201c1 registro\u201d en lugar "
             "de \u201c1 días\u201d y \u201c1 registros\u201d; la unidad \u201csemanas\u201d de "
             "Estadísticas y la galería de widgets ya no aparecen en inglés; y elegir inglés en el "
             "idioma de Stride se aplica en toda la app."
             "\n\u2022 Volver a marcar un hábito justo después de desmarcarlo funciona a la primera. Antes seguía sin marcar hasta volver a abrir Stride.",
  },
  "1.3.1": {
    "en-US": "Sync is rebuilt in this version, so save a backup first: Settings → Export "
             "as JSON.\n\n"
             "• Sync now sends only what changed since the last sync, so it is much faster "
             "on a long history.\n"
             "• Signing in to a different account on a device that holds another account’s "
             "habits now asks first what to do with them. You can export a backup, then start "
             "from that account’s data, or cancel and leave this device as it is. Habits from two "
             "accounts are no longer mixed. Habits that don’t "
             "belong to any account yet can also be uploaded to the account you sign in to.\n"
             "• If a habit is deleted on another device while you edit it offline, the "
             "deletion still wins, but your edits are kept in Settings → Recovered Edits, "
             "ready to export.\n"
             "• A backup made under another account now comes back as new copies instead of "
             "disappearing at the next sync, and a restored habit that another device had deleted "
             "can be brought back with Restore as New Copies in Settings.\n"
             "• When you need to sign in again, Today shows “Sign in again to keep "
             "syncing” instead of sync failing silently.",
    "zh-Hans": "本版本重写了同步，请先保存一份备份：设置 →「导出为 JSON」。\n\n"
               "• 同步现在只发送上次同步以来的改动，记录很多时也快得多。\n"
               "• 在存有其他账户习惯的设备上登录另一个账户时，会先询问如何处理这些习惯："
               "你可以先导出备份，再从此账户的数据开始；也可以取消，让这台设备保持原样。"
               "两个账户的习惯不会再混在一起。还不属于任何账户的"
               "习惯，也可以上传到你登录的账户。\n"
               "• 离线编辑某个习惯时，如果它在另一台设备上被删除，删除仍会生效，但你的编辑会"
               "保留在「设置 → 找回的编辑」中，可以导出。\n"
               "• 在另一个账户下制作的备份，现在会以新副本的形式恢复，不会在下次同步时消失；"
               "已在其他设备上删除的恢复习惯，可以在设置中用「恢复为新副本」找回。\n"
               "• 需要重新登录时，「今天」页面会显示「重新登录以继续同步」，同步不再无声地失败。",
    "zh-Hant": "本版本重寫了同步，請先儲存一份備份：設定 →「匯出為 JSON」。\n\n"
               "• 同步現在只傳送上次同步以來的變更，紀錄很多時也快得多。\n"
               "• 在存有其他帳號習慣的裝置上登入另一個帳號時，會先詢問如何處理這些習慣："
               "你可以先匯出備份，再從此帳號的資料開始；也可以取消，讓這台裝置保持原樣。"
               "兩個帳號的習慣不會再混在一起。還不屬於任何帳號的"
               "習慣，也可以上傳到你登入的帳號。\n"
               "• 離線編輯某個習慣時，如果它在另一台裝置上被刪除，刪除仍會生效，但你的編輯會"
               "保留在「設定 → 找回的編輯」中，可以匯出。\n"
               "• 在另一個帳號下製作的備份，現在會以新副本的形式恢復，不會在下次同步時消失；"
               "已在其他裝置上刪除的恢復習慣，可以在設定中用「恢復為新副本」找回。\n"
               "• 需要重新登入時，「今天」頁面會顯示「重新登入以繼續同步」，同步不再無聲地失敗。",
    "ja": "このバージョンで同期の仕組みを作り直しました。まずバックアップを保存してください："
          "設定 →「JSON で書き出す」。\n\n"
          "• 同期は前回から変わった分だけを送るようになり、記録が多くてもずっと速く終わります。\n"
          "• 別のアカウントの習慣が入っているデバイスでほかのアカウントにログインすると、"
          "その習慣をどうするかを先に確認します。バックアップを書き出してからそのアカウントの"
          "データから始めることも、キャンセルしてこのデバイスをそのままにしておくこともできます。"
          "2つのアカウントの習慣が混ざることはなくなりました。まだどの"
          "アカウントにも属していない習慣は、ログインしたアカウントにアップロードすることもできます。\n"
          "• オフラインで編集した習慣が別のデバイスで削除されていた場合、削除は反映されますが、"
          "編集内容は「設定 → 復旧した編集」に残り、書き出せます。\n"
          "• 別のアカウントで作ったバックアップは、次の同期で消えずに新しいコピーとして復元"
          "されます。別のデバイスで削除された習慣を復元した場合は、設定の「新しいコピーとして復元」"
          "で戻せます。\n"
          "• 再ログインが必要になると、「今日」の画面に「同期を続けるには再度ログインしてください」"
          "と表示されます。これまでは同期が何も知らせずに失敗していました。",
    "ko": "이번 버전에서 동기화를 새로 만들었습니다. 먼저 백업을 저장해 두세요: 설정 → "
          "‘JSON으로 내보내기’.\n\n"
          "• 동기화가 이제 지난번 이후 바뀐 내용만 보내므로, 기록이 많아도 훨씬 빠릅니다.\n"
          "• 다른 계정의 습관이 있는 기기에서 다른 계정으로 로그인하면, 그 습관을 어떻게 할지 "
          "먼저 묻습니다. 백업을 내보낸 뒤 이 계정의 데이터로 시작하거나, 취소하고 이 기기를 그대로 "
          "둘 수 있습니다. 두 계정의 "
          "습관이 더 이상 섞이지 않습니다. 아직 어느 계정에도 속하지 않은 습관은 로그인한 계정에 "
          "업로드할 수도 있습니다.\n"
          "• 오프라인에서 편집한 습관이 다른 기기에서 삭제되면 삭제가 적용되지만, 편집 내용은 "
          "‘설정 → 복구된 편집’에 남아 내보낼 수 있습니다.\n"
          "• 다른 계정에서 만든 백업은 이제 다음 동기화 때 사라지지 않고 새 사본으로 복원됩니다. "
          "다른 기기에서 삭제된 습관을 복원했다면 설정의 ‘새 사본으로 복원’으로 되살릴 수 "
          "있습니다.\n"
          "• 다시 로그인해야 할 때는 ‘오늘’ 화면에 ‘동기화를 계속하려면 다시 "
          "로그인하세요’가 표시됩니다. 이전에는 동기화가 조용히 실패했습니다.",
    "es-ES": "La sincronización se ha rehecho en esta versión, así que guarda antes una copia de "
             "seguridad: Ajustes → “Exportar como JSON”.\n\n"
             "• La sincronización envía solo lo que ha cambiado desde la última vez, así que es "
             "mucho más rápida con un historial largo.\n"
             "• Si inicias sesión con otra cuenta en un dispositivo que guarda los hábitos de "
             "otra, Stride te pregunta primero qué hacer con ellos: puedes exportar una copia de "
             "seguridad y después empezar con los datos de esa cuenta, o cancelar y dejar el "
             "dispositivo como está. Los hábitos de dos cuentas ya no se mezclan. Los "
             "hábitos que aún no pertenecen a ninguna cuenta también se pueden subir a la cuenta "
             "con la que inicias sesión.\n"
             "• Si un hábito se elimina en otro dispositivo mientras lo editas sin conexión, la "
             "eliminación se mantiene, pero tus cambios se guardan en Ajustes → “Ediciones "
             "recuperadas”, listos para exportar.\n"
             "• Una copia de seguridad hecha con otra cuenta se restaura ahora como copias "
             "nuevas en lugar de desaparecer en la siguiente sincronización, y un hábito restaurado "
             "que otro dispositivo había eliminado se recupera con “Restaurar como copias "
             "nuevas” en Ajustes.\n"
             "• Cuando tengas que volver a iniciar sesión, la pantalla Hoy muestra “Inicia "
             "sesión de nuevo para seguir sincronizando” en lugar de que la sincronización "
             "falle en silencio.",
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
                       "releaseType": "MANUAL"},   # see the module docstring
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

    if cmd == "cancel":
        # Only a submission that holds THIS version is cancelled — never "the first open one"
        # (the mistake `submit` used to make, see its docstring).
        not_cancelled = []
        for p, v in versions(app_id, version_string).items():
            d = a.get("/reviewSubmissions", params={
                "filter[app]": app_id, "filter[platform]": p,
                "filter[state]": "READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES",
                "limit": 10})
            hit = [sub for sub in d["data"] if v["id"] in submission_versions(sub["id"])]
            if not hit:
                print(f"  [{p}] no open submission holds {version_string} "
                      f"({v['attributes']['appStoreState']})")
                continue
            for sub in hit:
                a.patch(f"/reviewSubmissions/{sub['id']}", {"data": {
                    "type": "reviewSubmissions", "id": sub["id"], "attributes": {"canceled": True}}})
                print(f"  [{p}] cancel requested for submission {sub['id']} "
                      f"(was {sub['attributes']['state']})")
        for _ in range(20):                  # cancelling is asynchronous on Apple's side
            states = {p: v["attributes"]["appStoreState"]
                      for p, v in versions(app_id, version_string).items()}
            if not any(st in ("WAITING_FOR_REVIEW", "IN_REVIEW") for st in states.values()):
                break
            time.sleep(15)
        for p, st in states.items():
            print(f"  [{p}] {version_string} now {st}")
            if st in ("WAITING_FOR_REVIEW", "IN_REVIEW"):
                not_cancelled.append(p)
        if not_cancelled:
            print(f"STILL IN REVIEW: {', '.join(not_cancelled)}"); return 1
        return 0

    if cmd == "release":
        # Only an approved, held version can be released; anything else is reported, not forced.
        not_released = []
        for p, v in versions(app_id, version_string).items():
            state = v["attributes"]["appStoreState"]
            if state == "READY_FOR_SALE":
                print(f"  [{p}] already live"); continue
            if state != "PENDING_DEVELOPER_RELEASE":
                print(f"  [{p}] {state} — not approved and held, so not released")
                not_released.append(p); continue
            a.post("/appStoreVersionReleaseRequests", {"data": {
                "type": "appStoreVersionReleaseRequests",
                "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}},
            }})
            print(f"  [{p}] release requested")
        if not_released:
            print(f"NOT released: {', '.join(not_released)}"); return 1
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
