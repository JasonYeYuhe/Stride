# Stride — 交接 prompt（复制整段发给新会话）

你接手 Stride（iOS/macOS 习惯追踪 App，SwiftUI + SwiftData；Node/Express + SQLite 后端在一台 Azure VM 上）的下一阶段开发。仓库在 `~/Documents/Stride`，当前 `main` 已包含 1.2.3（build 17，2026-09-17 上架）和之后的收尾提交。你全权负责，按下面的顺序做，不要每一步都来问我；只有在动到用户数据、签名/凭据、或者要提交审核时才需要我点头。

## 先读什么（按顺序，别跳）

1. `DEV-PLAN-1.3.md` —— 下阶段的完整计划：6 个里程碑、每个的具体改动（精确到文件和行号）、验收标准、争议点的裁决、以及两次 Gemini 审查改了什么。**M0 + M1 + M2 是已承诺的范围**，M3–M6 是同等细度的后续。
2. `DEV-PLAN-1.3-reviews.md` —— Gemini 3.1 Pro 和 3.8 Flash 的原始审查意见（计划里的 Review log 说明了哪些采纳、哪些拒绝及原因）。
3. `RELEASE-1.2.3.md` —— 上一版发布记录：哪些 bug 只有靠"在生产库副本上演练"和"用真实演示账号跑上线代码"才发现，测试套件全绿也没抓到。这是本项目最重要的方法论。
4. `AUDIT-2026-09-09.md` —— 31 项缺陷的审计原文，计划里所有"gap"的出处。
5. `server/DEPLOY.md` —— 部署流程（先 dry-run diff、备份、rsync、重启、验证），以及"先在生产库副本上演练"的做法。
6. 记忆目录 `~/.claude/projects/-Users-jason-Documents-Stride/memory/`（会自动加载）：基础设施、App Store 状态、签名陷阱、模拟器规范、本地化陷阱都在里面。

## 从哪里开始

从 **M0**（服务端契约 + CI + 运维基础，不需要 App Review）开始，严格按 `DEV-PLAN-1.3.md` 里 M0 的清单和验收标准做。M0 的每一条都是 M2（增量推送）的前提；服务端改动部署前必须在生产库副本上演练（DEPLOY.md 有步骤，1.2.3 就是这样抓到 NULL `updated_at` 的）。

M0 做完并部署验证后进入 M1（1.3.0）：这是一个**不碰 schema** 的发布，目的是在 M2 改同步引擎之前先把备份/恢复、大号小组件、复数规则、Dynamic Type、提醒权限修复和一键登录发出去，并用它验证新的 CI 和演练脚本。

M2（1.3.1，增量推送）单独一个版本，不要和任何功能混在一起。它的设计细节、测试清单和"账号切换会把上一个账号的数据推进下一个账号"这类已知坑都写在计划里，照着做。

## 每次提交审核前的固定动作

- `scripts/check_demo_account.sh`（编译上线的同步代码，用真实演示账号拉取并打印审核员会看到的连续天数/完成率；exit 3 表示演示数据过期需要重新生成）
- `scripts/sync_rehearsal.sh`（M2 起，双设备模拟收敛）
- `scripts/a11y_sweep.sh`（M1 起）
- `scripts/release.py` 六种语言的 What's New；任何商店描述改动必须在同一次提交里用 `scripts/push_metadata.py` 推送（`release.py` 只写 What's New，会把上一版描述原样复制）
- 打包用 `scripts/build-appstore.sh all --upload`（凭据从 `scripts/.env` 读），附加+提交用 `scripts/release.py finish <version> <build>`（现在没真正提交会返回非 0）
- 写 `RELEASE-<version>.md`

## 已知的机器/流程陷阱（都在记忆里，这里只提醒）

- 锁屏时 codesign 可能失败（`errSecInternalComponent`）：先跑 `security show-keychain-info ~/Library/Keychains/login.keychain-db` 和一个 1 秒的 codesign 探测，再开始打包。
- Xcode 大版本更新后需要重新接受许可（`sudo xcodebuild -license accept`），只有我能做。
- 模拟器：复用 iPhone 17 Pro；CoreSimulatorService 卡死时 `killall -9 com.apple.CoreSimulator.CoreSimulatorService`。
- 本地化：`xcodebuild -exportLocalizations` 在 Xcode 27 上输出的 key 是错的；运行时 key 规则 Int→`%lld`、String→`%@`、Double→`%lf`；插值里嵌套三元表达式永远不会被翻译；`String(localized:)` 不跟随 App 内语言选择，界面代码用 `appLocalized`/`appCalendar`。
- 服务端 `.env` 里 `FROM_EMAIL` 含 `<>`，不要 `source .env`；`seed-demo.js` 自己会加载 dotenv。
- 用 agy 调 Gemini 审查：`agy --model gemini-3.1-pro-high --print="<prompt>"`（模型 id 已含 effort，不要再传 `--effort`；`--print` 必须是 `--print=...` 的形式，prompt 长时用 Python `subprocess` 传参）。

## 需要我做的事（你做不了）

- 把 iCloud Drive `Downloads/` 里的两份 ASC `.p8` 密钥移到 `~/Library/Application Support/CLI-Pulse-Secrets/`。
- 清掉旧 DigitalOcean 主机 `143.198.85.72` 上残留的 `stride.db`（M0 的 owner action）。
- App Store Connect 里确认月付/年付是否配置了首购优惠（M0 的 ASC check），决定删优惠还是在 M1 加披露文案。

做完 M0 给我一个简短的进度汇报（部署验证结果 + CI 截图级别的证据即可），然后直接进 M1。
