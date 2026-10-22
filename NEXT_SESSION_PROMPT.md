# Stride — 交接 prompt（复制整段发给新会话）

你接手 Stride（iOS/macOS 习惯追踪 App，SwiftUI + SwiftData；Node/Express + SQLite 后端在一台 Azure VM 上）的开发。仓库在 `~/Documents/Stride`，分支 `m4/1.4.1`。你全权负责，按下面的顺序做，不要每一步都来问我；只有在动到用户数据、签名/凭据、或者要提交审核时才需要我点头。

## 现在的状态（2026-10-22）

- **1.4.0（build 22）** 两个平台都已上架；PR #7 已合并，tag `v1.4.0`。
- **1.4.1（build 23）** 代码已完成，正在做最后的门禁。计划与完整记录在 **`RELEASE-1.4.1.md`**（「Progress log」从 2026-10-22 往下读）。PR JasonYeYuhe/Stride#10 是 m4 → main 的草稿。
- 生产服务器已部署 #8/#9（magic link 修复、旧客户端 426）、#11（X2 日期守卫）和 W8（demo 账号脚本）。另外每天 08:20 UTC 多跑一次 demo top-up。
- ASC 已完成：两个平台的 1.4.1 版本记录（PREPARE_FOR_SUBMISSION），6 种语言的 What's New、描述、关键词和推广文本（Mac 有自己的推广文本），本地化 App 名和副标题，审核备注，全部截图（Mac 4 张；iOS 4 种尺寸各 4 张），Lifetime 新增 5 种语言，Lifetime 价格改为 39.99 USD，开启 Billing Grace Period。
- **“很多人退订”已查清**：Stride 从没卖出过月订或年订，只有一次 Lifetime（2026-09-06）。退订是 ColorArchive 和 RoastMate 的（ASC 报表默认按整个账号汇总）。见记忆 `reference_asc_sales_reports`。

## 剩下的事（按顺序）

1. **ASC 网页端 7 处文字**（API 改不了已批准的本地化，409 UNMODIFIABLE）：
   - Monetization → Subscriptions → Stride Pro Yearly，6 种语言的描述，去掉 “save 44%”：en-US「Full access billed yearly」，es-ES「Acceso completo con facturación anual」，ja「年額プランで全機能をアンロック」，ko「연간 구독으로 모든 기능 잠금 해제」，zh-Hans「按年订阅，解锁全部功能」，zh-Hant「按年訂閱，解鎖全部功能」；
   - In-App Purchases → Stride Pro Lifetime，en-US 描述改成「Habit groups, advanced analytics & weekly review」。
   需要先登录 ASC。1Password 授权（`request_credentials`）这次一直报 transport_error，可以让我打开 1Password 再试，或者我自己在 Chrome 里登录。
2. **模拟器门禁**（需要我先重新打开 Claude App 里的 iOS 模拟器面板；这个工具崩溃后只能这样恢复）：
   - gate 3 剩下的部分：iPhone B 同步、取消再勾选后 B 上只剩一条记录、iPad 那一段、小组件那一段；
   - gate 7 iOS：从 1.4.0 / 1.3.1 / 1.3.0 / 1.2.3 原地升级，放好小组件并带 `--reminders`（kit 已修好，1.4.0 可以作起点）；
   - X2 登录分支：日历设为日本历的设备，1.4.0 被 held 的行在 1.4.1 解除 hold，服务器最后存的是真实日期；
   - gate 10.4 的「Mac 上编辑 History 能同步到 iPhone B」。
   跑法见 `scripts/sim_e2e/README.md`。上次的工作流脚本和证据在会话 scratchpad 的 `gates-1.4.1/`。
3. **Mac 清单剩下的**：第 5、12 条（通知横幅和 Dock 角标）。要我在系统弹窗里允许通知，还要看得到 Dock。VoiceOver 由我自己打开再测（这是系统设置）。
4. **提交日**：`release.py show 1.4.1`；gate 11 再跑一遍（`check_email_auth.sh`，email.js 发给 delivered@resend.dev，加号地址收一封）；签名预检；`build-appstore.sh all --upload`（要我点头）；`release.py finish 1.4.1 23 --platform IOS`（要我点头）；Mac 等 gate 10 全部通过后再 `finish --platform MAC_OS`。
5. **审核通过后**：`release.py release 1.4.1`；PR #10 用 merge commit 合并；打 tag `v1.4.1`。然后到 ASC 给 Yearly 创建 7 天免费试用（1.4.2 的 paywall 显示条款之后才做，见计划里的「1.4.2 backlog」）。

## 不变的规矩

- 不用 TestFlight，也不用我做真机检查，由你自己测（模拟器端到端、原地升级、Release 冒烟）。
- ASC 写操作和生产部署每一步都要我点头。权限分类器有时会拦下 agent 自己的 ASC 写操作，被拦时就把命令写成脚本交给我跑（例如 `scripts/asc_writes_1_4_1.sh`），不要绕过。
- 版本用 MANUAL 发布。iOS 先提交；Mac 要等 gate 10 通过。
- 这台 Mac 上绝不运行真实 bundle id 的 Stride。Mac 测试版（`…mactest`）只按路径启动，按 pid 停止。
- 第二时区的测试要用 `TEST_RUNNER_TZ=America/Los_Angeles`，只设 `TZ=` 传不到测试进程，之前的 “LA” 结果其实是在东京跑的。

## 已知的机器/流程陷阱

- 锁屏：codesign 可能失败，先跑 keychain 探测（全局 CLAUDE.md）。锁屏时 Mac 上的 computer use 点不了；iOS 模拟器在锁屏下仍能用。
- 负载很高时（其他会话在构建）iOS 模拟器 MCP 会崩溃，sweep 也会截到空白帧：`STRIDE_A11Y_SETTLE` 调大，截完检查有没有空白帧。
- ASC：`push_metadata.py --app-info` 已修好（写可编辑的那个 appInfo）；`store_screenshots.py` 只能在 `prepare` 之后用。
- 构建根和磁盘规则见全局 CLAUDE.md。持久的根都在 `~/Library/Caches/Stride-build/`，保留不要删。

先读 `RELEASE-1.4.1.md` 里 2026-10-22 的几条 Progress log，再从上面第 1 步开始。
