# Stride — 交接说明（新会话先读这份）

你接手 Stride 的开发。Stride 是 iOS/iPadOS/macOS 的习惯追踪 App：
- 客户端：SwiftUI + SwiftData + 小组件；
- 同步服务器：Node/Express + SQLite，跑在一台 Azure VM 上。

仓库在 `~/Documents/Stride`，当前分支 `m4/1.4.1`。

你全权负责，按下面的顺序做，不要每一步都来问我。只有这几种情况需要我点头：
- 动到用户数据；
- 签名或凭据；
- ASC 写操作；
- 生产部署；
- 提交审核。

## 现在的状态（2026-11-08 晚）

- **1.4.1（build 23）**
  - **Mac 已上架**：11-08 由我手动发布。
  - **iOS 在审核中**：WAITING_FOR_REVIEW，11-07 提交，Yearly 和 Lifetime 两个 IAP 在同一个 submission 里。
  - 1.4.1 自己的门禁全部通过。gate 11 和 gate 12 的 iOS 部分在 11-08 跑过：Release 模拟器版连生产服务器，用加号测试账号登录、同步、放小组件，最后在 App 里删除了这个账号。
  - 记录在 `RELEASE-1.4.1.md` 的「Progress log」，看 2026-11-07 和 11-08 的几条。
  - PR JasonYeYuhe/Stride#10 是 m4 → main 的草稿。
  - m4/1.4.1 比 origin 多 17 个以上的提交，还没 push。push 时先问我。
- **下一阶段是 1.4.2「Pro worth paying for」**，计划在 **`PLAN-1.4.2.md`**。
  - **先读它开头的「Re-plan of 2026-11-08」一节，它覆盖下面所有日期。**
  - 这次重排经过了 Gemini 3.8 Flash 两个视角的审查（结论 R1–R12 在计划末尾的 Review log），N1–N6 我都已经拍板。
- **背景**：Stride 从没卖出过月订或年订，Pro 收入只有一次 Lifetime。所以这一阶段的目标是让 Pro 真正值得买：看得见、说的都对、能试用。
- **环境**
  - Xcode 27.1。sim_e2e 套件已经迁到 iOS 27.0 的设备上：iPhone 17 Pro `C53F6992…`、Pro Max `8C431EC3…`、iPhone 17 `2D529F09…`、iPad Pro 13" (M5) `7B83B9D7…`。基线是 hosted 732、a11y 326+12。
  - StoreKit 测试（SKTestSession）在 iOS 27.0 上仍然跑不起来，要用 iOS 18.5 的设备。
  - iPhone 17 Pro 上装着 1.4.1 (23) 的 **Release** 版，已登出；它连的是生产服务器。跑套件前会被 Debug 版覆盖。
  - 磁盘只剩约 28 GB，低于 30 GB 不要启动新的模拟器，先叫我清空废纸篓。

## 已经拍板的决定（2026-11-08，全部按推荐）

| # | 决定 |
|---|---|
| N1 | 1.4.2 只做 **Wave A（W0–W9）**。Wave B（Weekly Review）挪到 1.5.0 开头，记为 X0，不再设检查点 |
| N2 | 7 天 Yearly 试用：等 iOS 和 Mac 的 1.4.2 都到 PENDING_DEVELOPER_RELEASE，在发布那一次一起创建优惠、一起发布，然后跑 gate 14。如果 Mac 比 iOS 晚 3 天以上，就在 iOS 发布当天开 |
| N3 | 放宽 rule 4，但严格限定，细节见下 |
| N4 | 1.4.2 不加新的 Pro 品类，1.5.0 再议 |
| N5 | Mac Dock 角标修复放进 W9，作为 Phase 0 第 12 项，W9 本来就负责 NotificationService.swift |
| N6 | 不重跑 Gemini 4 Argon，改成冻结前让 Argon 审 1.4.2 做完的分支 |
| 其他 | Gemini 的 R9–R12 一条都不采纳；其余 O 项都取默认值 |

N3 的限定条件：
- 只用 `requestReview(in:)`（系统自带的评分请求），W7 实现；
- 每个版本最多一次，记在 `UserDefaults.standard`，不同步也不备份；
- 只在一次打卡刚好凑满 7 天连续或达成一周目标之后；
- 装机前 3 天不弹，引导页里不弹，有 sheet 显示时也不弹；
- 设置 → About 里的 "Rate Stride" 那一行保留；
- 在 `Shared/` 里加一个纯函数 `ReviewPromptRule`，每个条件都有单元测试；
- 加一个 hosted 测试，证明 `-demo` 和 UI 测试的参数下不会调用它。

## 第一部分：把 1.4.1 收尾（等 iOS 审核结果，期间做第二部分）

1. 每天看一次 `release.py show 1.4.1`。
2. **iOS 通过后**，这几步每一步都要我点头：
   - `release.py release 1.4.1 --platform IOS`；
   - PR #10 用 merge commit（`--no-ff`）合并进 main；
   - 打 tag `v1.4.1`；
   - 轮换 App Review 的 demo token（Phase 0 第 3 项）。
3. **如果被拒**：修复提交在 m4 上，再合并进 m5。
4. 发布后看 Sentry（项目 stride-apple，sessions API 的用法见记忆 `reference_sentry`），确认没有新的崩溃。

## 第二部分：开始 1.4.2（按 Re-plan 里的日程）

| 日期 | 做什么 |
|---|---|
| 11-09 | 从 m4 最新提交切出 `m5/1.4.2`；`PLAN-1.4.2.md` 改名为 `RELEASE-1.4.2.md`，把 N1–N6 写进去；W0（基线、纯移动、开 → main 的草稿 PR）；W9 同时开工 |
| 11-09 到 11-18 | Wave A（W1–W9）。第一天先做 StoreKit 模拟器（iOS 18.5）、W2 的 SKTestSession 用例和 paywall fixtures，这是 3.1.2 的关键路径 |
| **11-19** | 冻结代码；没变绿的按 D1 的砍单顺序处理；Argon 审完成的分支 |
| 11-19 到 11-24 | 跑门禁 1–13；Mac gate 10 里点通知横幅按钮那一步由我来 |
| **11-25** | 目标：两个平台一起 `finish`。没赶上就 12-01，最晚 12-04 |

还没做完的 Phase 0 项：3、4、7、8、11、12。2 等 iOS 发布。9 按 N6 取消，10 已经由 N1–N6 代替。

Phase 0 第 12 项包括：
- **Mac Dock 角标**：用 `NSApp.dockTile.badgeLabel`。这个标签只在 App 运行时存在，所以每次 setBadge、启动时、场景激活时都要设一次；关掉或计数为 0 时设成 nil。NotificationService 本身是 `@MainActor`，没有线程问题。
- **三个 VoiceOver 标签**。
- **通知横幅按钮**：只能由我来点。

新文件放在 `Stride/Sources/Views/` 这类实际目录里，不要放到仓库根目录。

## 不变的规矩

- 不用 TestFlight，也不用我做真机检查，由你自己测：hosted、模拟器端到端、原地升级、a11y sweep、Mac 测试版、Release 冒烟。
- ASC 写操作和生产部署每一步都要我点头。权限分类器拦下 agent 自己的 ASC 写操作时，就写成脚本交给我跑，不要绕过。
- 版本用 MANUAL 发布。
- 这台 Mac 上绝不运行真实 bundle id 的 Stride。Mac 测试版（`…mactest`）只按路径启动，按 pid 停止。
- 生产 token 和凭据由我来粘贴，agent 不碰。删除测试账号用 App 自己的 Delete Account 流程，并先确认屏幕上显示的是加号测试地址。
- 生产的 `request-link` 每次最多发一封：先确认我已经准备好收邮件再发。token 30 分钟过期，11-08 就因为过期多发了一封。
- 第二时区的测试要用 `TEST_RUNNER_TZ=America/Los_Angeles`。
- 每个新字符串都要进 6 种语言。
- 工作方法：worktree 隔离的实现 agent → 审查视角 → 对抗验证 → 修复。主分支只用 `--no-ff` 合并。
- Gemini 只能通过 agy（`mcp__gemini__ask_gemini`）调用，`workspace` 指向一次性的 `git archive` 副本，绝不指向仓库，也不用 Chrome。
- 构建根和磁盘规则见全局 CLAUDE.md。持久的根都在 `~/Library/Caches/Stride-build/`，保留不要删。
- 模拟器：
  - 用 UDID 指定设备；用之前先 `mkdir /tmp/lock-<slug>`，用完删掉；
  - 调 iOS Simulator MCP 时**必须传 `device`**，不传会截到别的会话的模拟器（NihongoRide-Placement）；
  - 坐标是 402×874 points。

## 已知陷阱

- 锁屏时 codesign 可能失败，先跑 keychain 探测（全局 CLAUDE.md）。
- 负载很高时模拟器点击会滞后，甚至落到别的元素上，点完要重新截图确认。sweep 会截到空白帧：把 `STRIDE_A11Y_SETTLE` 调大，截完检查空白帧。
- 模拟器启动失败（"system shell probably crashed"、mainScreenSurfaceNotFound）时，`simctl shutdown` 再 `boot`，不要 erase。
- ASC：已批准的 IAP 本地化不能用 API 改（409），要在网页端改；`store_screenshots.py` 只能在 `prepare` 之后用；报表按整个账号汇总，要按 SKU 过滤（见记忆 `reference_asc_sales_reports`）。
- 新装的 Release 版可能显示 "Sign in again to keep syncing"。那是 localhost 套件留在钥匙串里的 token，不是生产被登出。

先读 `PLAN-1.4.2.md` 的「Re-plan of 2026-11-08」和 Phase 0，再读 `RELEASE-1.4.1.md` 最近几条 Progress log，然后从第二部分 11-09 那一行开始，同时留意第一部分的审核状态。
