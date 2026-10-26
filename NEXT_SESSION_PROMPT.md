# Stride — 交接说明（新会话先读这份）

你接手 Stride（iOS/iPadOS/macOS 习惯追踪 App，SwiftUI + SwiftData + 小组件；Node/Express + SQLite 同步服务器在一台 Azure VM 上）的开发。仓库在 `~/Documents/Stride`，当前分支 `m4/1.4.1`。你全权负责，按下面的顺序做，不要每一步都来问我；只有在动到用户数据、签名/凭据、ASC 写操作、生产部署、或者要提交审核时才需要我点头。

## 现在的状态（2026-10-27）

- **1.4.0（build 22）** 两个平台都已上架。
- **1.4.1（build 23）** 代码已完成；ASC 上两个平台的版本记录已经填好（What's New、元数据、审核备注、截图），状态是 PREPARE_FOR_SUBMISSION。还没上传 build，也还没提交。完整记录在 `RELEASE-1.4.1.md`（「Progress log」从 2026-10-22 往下读），剩下的事见下面的第一部分。PR JasonYeYuhe/Stride#10 是 m4 → main 的草稿。
- **下一阶段 = 1.4.2「Pro worth paying for」**：计划是 **`PLAN-1.4.2.md`**，已经过 Gemini 3.8 Flash（两个视角）和 Claude 对抗审查。Gemini 4 Argon（agy 的 `gemini-4-argon-high`，也就是我说的「Gemini 4 Pro」）因为 agy 配额用完还没跑，约 2026-11-02 恢复，见计划 Phase 0 第 9 项。
- **背景**：Stride 从没卖出过月订或年订，Pro 收入只有一次 Lifetime。所以这一阶段的目标是让 Pro 真正值得买（看得见、说的都对、能试用），而不是挽回流失。
- **工具链变了**：Xcode 27.1；iOS 26.5 的模拟器运行时已经没有了。sim_e2e 套件写死的两台设备（`scripts/sim_e2e/lib.sh:32-33`，F5510EA3 / F54C8C41）不能用了。新的默认设备在 iOS 27.0 上：iPhone 17 Pro `C53F6992…`、Pro Max `8C431EC3…`、iPhone 17 `2D529F09…`、iPad Pro 13" (M5) `7B83B9D7…`。iOS Simulator MCP 在新的 iPhone 17 Pro 上可以用。磁盘约 27 GB 可用。

## 第一部分：把 1.4.1 发出去

1. **模拟器套件迁移**（计划 Phase 0 第 1 项）：把 `lib.sh` 和其他写死设备 ID 或设备名的脚本指到 iOS 27.0 的新设备，跑 `scripts/sim_e2e/selftest.sh`，在 iOS 27.0 上重新记录基线（hosted、a11y sweep）。顺便试一次 StoreKit 测试在 iOS 27.0 上能不能跑（`STRIDE_HOSTED_NO_SKIPS=StoreKitStatusTests`）。
2. **1.4.1 剩下的模拟器门禁**：
   - gate 3：iPhone B 同步、取消再勾选后 B 只剩一条记录、iPad、小组件；
   - gate 7 iOS：从 1.4.0 / 1.3.1 / 1.3.0 / 1.2.3 原地升级，放好小组件并带 `--reminders`；
   - X2 登录分支：日本历设备上被 held 的行；
   - gate 10.4：Mac 上编辑 History 能同步到 iPhone B。
3. **Mac 清单第 5、12 条**（通知横幅和 Dock 角标）：要我在系统弹窗里允许通知。
4. **ASC 网页端 7 处文字**（API 对已批准的本地化报 409，只能在网页端改）：
   - Yearly 的 6 种语言描述去掉 “save 44%”，新文字在 `scripts/iap_copy.py` 里；
   - Lifetime 的 en-US 描述。
   需要登录 ASC：用 1Password（`request_credentials`）或者让我自己登录。
5. **提交日**：
   - `release.py show 1.4.1`；
   - gate 11（`check_email_auth.sh`，email.js 发给 delivered@resend.dev，加号地址收一封）；
   - 签名预检；
   - `build-appstore.sh all --upload`（要我点头）；
   - `release.py finish 1.4.1 23 --platform IOS`（要我点头）；
   - Mac 等 gate 10 全部通过后再 finish。
6. **审核通过后**：`release.py release 1.4.1`；PR #10 用 merge commit 合并；打 tag `v1.4.1`；轮换 App Review 的 demo token（计划 Phase 0 第 3 项）。

## 第二部分：开始 1.4.2（和第一部分可以交错进行）

- **1.4.1 提交 iOS 的当天**，从 m4 的最新提交切出 `m5/1.4.2`，把 `PLAN-1.4.2.md` 改名为 `RELEASE-1.4.2.md`，然后由 W0 开一个 → main 的草稿 PR。
- 按 `PLAN-1.4.2.md` 来做：
  - 先做 **Phase 0**（第 1–11 项；O1–O25 一次性列给我，每条带默认值，我回一行就行）；
  - 然后 **W0 → Wave A（W1–W9）**；第一天做 StoreKit 模拟器、W2 的 SKTestSession 用例和 paywall fixtures，这是 3.1.2 的关键路径；
  - 11-10 检查点：Wave A 全绿才开 Wave B（W10–W11）；
  - 11-18 冻结代码；11-25 两个平台一起 finish。
- **Gemini 4 Argon 复审**（agy 配额恢复后，约 11-02）：在一次性的 `git archive` 副本上跑，绝不能指向仓库，也不用 Chrome。结果写进计划的 Review log。

## 不变的规矩

- 不用 TestFlight，也不用我做真机检查，由你自己测（hosted、模拟器端到端、原地升级、a11y sweep、Mac 测试版、Release 冒烟）。
- ASC 写操作和生产部署每一步都要我点头。权限分类器拦下 agent 自己的 ASC 写操作时，就写成脚本交给我跑（例如 `scripts/asc_writes_1_4_1.sh`），不要绕过。
- 版本用 MANUAL 发布。iOS 先提交；Mac 要等 gate 10 通过。
- 这台 Mac 上绝不运行真实 bundle id 的 Stride。Mac 测试版（`…mactest`）只按路径启动，按 pid 停止；Debug 版和 Release 版 bundle id 相同，Release 版连的是生产服务器。
- 第二时区的测试要用 `TEST_RUNNER_TZ=America/Los_Angeles`，只设 `TZ=` 传不到测试进程。
- 每个新字符串都要进 6 种语言（en 是 key 本身，另外 5 个 Localizable.strings）。
- 工作方法：worktree 隔离的实现 agent → 审查视角 → 对抗验证 → 修复。主分支只用 `--no-ff` 合并。
- 构建根和磁盘规则见全局 CLAUDE.md。持久的根都在 `~/Library/Caches/Stride-build/`（dd-m4、sim-e2e、mac-variant、mac-variant-release、a11y-dd、SourcePackages-*），保留不要删。

## 已知陷阱

- 锁屏时 codesign 可能失败，先跑 keychain 探测；锁屏时 Mac 上的 computer use 点不了；iOS 模拟器在锁屏下仍能用。
- 负载很高时（其他会话在构建）iOS 模拟器 MCP 会崩溃，sweep 也会截到空白帧：`STRIDE_A11Y_SETTLE` 调大，截完检查有没有空白帧。MCP 崩溃后只能让我重新打开模拟器面板。
- ASC：已批准的 IAP 本地化 API 改不了（409），要在网页端改；`push_metadata.py --app-info` 会写可编辑的那个 appInfo；`store_screenshots.py` 只能在 `prepare` 之后用。
- ASC 报表是按整个账号汇总的（还有 ColorArchive、RoastMate）。要按 SKU `stride-habit-tracker` 过滤，见记忆 `reference_asc_sales_reports`。

先读 `PLAN-1.4.2.md` 的开头（Why this plan、Where things stand、Phase 0），再读 `RELEASE-1.4.1.md` 里 2026-10-22 的几条 Progress log，然后从第一部分第 1 步开始。
