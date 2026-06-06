# Stride 深度审计 + v2.0 大版本规划报告

> 生成日期：2026-06-06
> 范围：iOS / macOS / watchOS / Widget 客户端 + Node.js 后端 + 竞品对标
> 当前版本：v1.1.0 (Build 11)，SwiftUI + SwiftData / Express + better-sqlite3，服务端 272 测试通过
> 方法：三路并行深度代码审查 + 竞品调研，关键缺陷已逐条用 file:line 核实

---

## 0. 执行摘要

Stride v1.1 是一个**工程质量扎实、安全意识到位**的多平台习惯打卡应用。同步协议经过大量测试加固（tombstone 删除传播、跨用户隔离），服务端基础安全做得比多数独立开发者好。

但要做"大更新（v2.0）",有三件事必须同时推进:

1. **修掉一批真实的数据完整性缺陷**（时区/DST、多设备 last-write-wins、Watch 不同步、unbounded tombstone）——这些是当前最大的隐性风险,用户多设备/跨时区使用时会丢数据或连续天数错乱。
2. **补齐"桌面级"功能短板**——竞品几乎都有而我们没有的:**定量习惯、灵活/宽容的频率、Apple Health 集成、习惯分组、更深的分析**。这些是用户选择对手而非我们的直接理由。
3. **打造两个差异化锚点**——(a) 基于现有热力图的**精美可分享进度卡片**（"超越 HabitKit"），(b) **业界最强的 Apple 生态集成**（交互式小组件 + Live Activities + 手表 Complication + Health 双向同步）。这是 Apple-only 独立应用最有防御力的定位。

### 模块健康度

| 模块 | 评分 | 一句话 |
|------|------|--------|
| 后端安全 | 🟢 良好 | 哈希 token、参数化 SQL、限流分层;主要缺 trust proxy + 可观测性未接线 |
| 后端可观测性/运维 | 🔴 缺失 | dd-trace 装了没初始化、无 Sentry、无优雅退出、无备份文档 |
| 同步正确性 | 🟡 隐患 | 协议测试充分,但客户端时区/updatedAt/Watch 三处会丢数据 |
| iOS/macOS 客户端 | 🟡 可用 | 代码干净,但无 ViewModel 层、四份重复打卡逻辑、可访问性有洞 |
| watchOS | 🔴 孤岛 | 手表 app **完全不联网同步**,且取消打卡不参与删除追踪 |
| Widget | 🟢 良好 | 已用 AppIntents 交互式打卡;缺可配置选习惯、Live Activities |
| 测试覆盖 | 🟡 偏科 | Model 数学覆盖好;Service 层(Sync/API/Auth/Store)零测试 |
| 功能完整度 vs 竞品 | 🟡 落后 | 仅二元每日打卡,缺定量/灵活频率/分组/Health |

---

## 1. P0 必修缺陷（数据完整性 + 安全，发版前必须处理）

### 客户端

- **C1 — 时区/DST 会让打卡"跨天漂移"** 〔最高风险〕
  `HabitRecord` 以本地日历 `startOfDay` 存储 (`Shared/Habit.swift:141`)，序列化用固定到 `.current` 的 `yyyy-MM-dd` (`SyncService.swift:24-30`, `DataExportService.swift:5-11`)。用户从 UTC+8 飞到 UTC-5 后，同一条记录可能映射到前一天 → 配合全局的 `isDate(_:inSameDayAs:)` 匹配，会**同时产生重复记录和孤儿记录**，连续天数错乱。整个日期层没有任何 UTC 锚定。**这是同步/连续天数层最大的正确性风险，且目前零测试。**

- **C2 — 多设备 last-write-wins 失效（数据互相覆盖）**
  每次推送都发 `updatedAt: Date()`（当前时间）而非真实的每习惯修改时间 (`SyncService.swift:111`)，`Habit` 模型根本没有 `updatedAt` 字段。服务端无法做正确的冲突解决——一台同步较晚的旧设备会覆盖另一台的新编辑。

- **C3 — Apple Watch 是数据孤岛 + 取消打卡不同步** 〔已核实〕
  `StrideWatch/` 全目录**没有任何** `SyncService` / `APIClient` 引用——手表 app 只能看本地数据，从不与后端通信（手机和手表是两台设备，App Group 不互通）。且 `WatchTodayView.toggleCompletion` 删除记录时**不调用 `trackDeletedEntry`** (`WatchTodayView.swift:50-68`)，所以手表上的"取消打卡"永远不会作为删除同步出去。

- **C4 — Widget 删除追踪与 save 顺序颠倒**
  `StrideWidget.swift:83` 先写删除标记到 App Group，再 `try context.save()` (`:90`)。若 save 抛错，记录被标记为"已删除待同步"但实际没删 → 下次推一个不该有的 tombstone，再下次又被重新上传。

### 后端

- **S1 — 缺 `trust proxy`，限流形同虚设** 〔HIGH〕
  nginx 反代在同一 droplet (`DEPLOY.md`)，但 `index.js` 没有 `app.set('trust proxy', 1)`。`express-rate-limit` 把所有请求按上游 IP（loopback）计数 → **全体用户共用一个限流桶**。3 次/15 分钟的魔法链接限流变成全局，要么被一个攻击者打满（DoS 掉所有人登录），要么无效。

- **S2 — 可观测性完全没接线** 〔HIGH〕
  `dd-trace@5` 在 `package.json:15` 但**没有任何 `require('dd-trace').init()`**（必须是第一行 import 才生效）；服务端**没有 `@sentry/node`、没有 Sentry init**。生产环境**没有错误追踪、没有 APM**，只有 `console.log`。

- **S3 — tombstone 无限增长** 〔HIGH〕
  `deletion_tombstones` 只增不删（`habits.js:180/233`, `sync.js:69`，唯一的 DELETE 是 demo 重置）。每次删习惯/打卡都是一行永久数据，`/sync/pull?since=` 每次 `DISTINCT` 扫描它。长期会拖慢增量拉取并占满存储。需要保留窗口（如 90 天）+ 定期清扫。

- **S4 — 增量同步退化成全量**
  `/sync/push` 即使行未变也把 `updated_at` 重写成服务器 `now` (`sync.js:60/122`)。一台设备全量推一次 → 另一台下次 `?since` 拉取会重新下载全部条目。多设备下增量同步逐渐退化为全量，放大 S3 的扫描成本。

- **S5 — 无全局错误处理 / 进程可被一条路由打挂 / 栈泄漏**
  `habits.js:95` 对非 UNIQUE 的 DB 错误 `throw err`;**没有 Express 全局错误中间件**;若 droplet 上 `NODE_ENV` 未设为 production,未捕获异常会把**栈追踪泄漏给客户端**。还缺 `SIGTERM` 优雅退出（PM2 重启会丢在途请求 + WAL 未 checkpoint）。

- **S6 — 仓库内提交了生产数据库文件 + 无备份策略**
  仓库里有 `server/stride.db`、`stride.db-wal`、`stride 2.db-shm`（全部用户数据的唯一来源）。这些不该进仓库,有被部署覆盖的风险;`DEPLOY.md` 也没写任何 `stride.db` 备份方案。

> 完整的中低优先级清单（约 30 项，含 C5~C12 客户端、S7~S10 后端）见本报告附录 A / B。

---

## 2. 竞品对标：我们缺的"桌面级"功能（table-stakes）

调研覆盖 Streaks、Habitify、HabitKit、Productive、Way of Life、Done、Routinery、Atoms、Finch、Stoic 等。**大多数主流竞品都有、而 Stride 没有**的功能（缺失 = 用户选对手的直接理由）：

1. **定量/可量化习惯** —「喝 8 杯水」「读 30 分钟」「跑 5 km」。Habitify / Done / HabitKit 都支持。我们 `HabitRecord` 只有 `date + note`，**这是最大的功能空缺**。
2. **灵活 + 宽容的频率** —「每周 3 次」「每月 20 次」「仅工作日」「每 N 天」，以及**跳过/休息日不断连续**（Way of Life 的 skip、Atoms 的 "Don't Miss Twice"）。死板的每日连续是 Streaks 类应用的头号差评。
3. **Apple Health 集成** — 运动/睡眠/正念类习惯自动打卡。Streaks / Habitify 都做了，Apple 平台已是预期功能。
4. **习惯分组/分类** — 按目标或生活领域组织（习惯超过 ~8 个后必需）。
5. **更深的分析** — 周/月总结、趋势线、完成率随时间变化、最佳/最差日。"没有趋势线、没有相关性、没有周报"是 Streaks 的经典槽点，我们不该继承。

> 我们已有但需确认/强化：交互式 Widget（已有✅）、数据导出（已有✅）、Watch app（有但是孤岛，需联网+Complication）。

---

## 3. v2.0 产品蓝图（差异化锚点）

按"惊喜度 ÷ 成本"排序，全部可选/可关：

1. **可分享的精美进度卡片**（基于现有热力图）⭐⭐⭐
   HabitKit 几乎只靠 GitHub-grid 美学 + 可分享性就做成了品牌。做主题化、可导出的进度卡（网格 + 连续天数 + 统计），为 Instagram/iMessage 分享而设计 → 自然增长飞轮。成本中等，回报高。

2. **最强 Apple 生态集成（核心定位）** ⭐⭐⭐
   交互式小组件（已有，扩展到锁屏/控制中心/StandBy）+ **Live Activities / 灵动岛**（"今日 3/5"、连续天数告急倒计时）+ **手表 Complication + 独立打卡**（先修 C3 让手表能联网）+ **Apple Health 双向同步**。这是连 Streaks 都做得不够的、对 Apple-only 独立应用最有防御力的楔子。

3. **宽容的连续天数模型** ⭐⭐
   引入 Way of Life 的"跳过日"和 Atoms 的"别连续错两天"。死板连续是全行业通病,温柔地解决它本身就是差异化("为真实生活设计的习惯")。

4. **温和、可选的游戏化（不是 Habitica）** ⭐⭐
   Finch（$30M ARR,纯自举）证明情感化/游戏化驱动留存,但 2025 普遍提醒 Habitica 式 XP/惩罚在新鲜感过后失效。甜点区:细微奖励、里程碑庆祝、身份认同式鼓励,**可一键关闭**。

5. **得体的 AI 习惯教练** ⭐⭐
   自适应洞察（"你在做了 Y 的日子完成 X 的概率高 70%"）、低潮预测、反思式周报、智能提醒时机。这是 2025→2026 最明显的趋势。风险:必须感觉"有用"而非噱头（见第 6 节陷阱）。

6. **轻量"安静的问责"** ⭐
   Cohorty 模式:可选的小队/共享进度 + 表情反应、**无聊天**。社交能提升完成率（研究称 +65~95%）但重社交会让应用臃肿、劝退内向用户。安静、可选的一层能拿到好处、避开代价。

---

## 4. 架构 / 工程债务（v2.0 重构窗口）

- **A1 — 无 ViewModel 层,业务逻辑散落在 View 里**:`toggleCompletion` 有**四份近重复实现**（`TodayView` / `WatchTodayView` / `StrideWidget` / `StrideShortcuts`），且行为不一致（只有 TodayView 追踪删除）。无法单元测试。应抽出一个 `HabitStore` / 领域服务统一打卡 + 删除追踪 + widget 刷新。
- **A2 — 删除追踪写到三个地方**:主 app 写 `UserDefaults.standard`、widget 写 App Group suite、手表什么都不写。应统一到一个共享 helper（App Group suite）。
- **A3 — 服务全是单例、无依赖注入** → Service 层无法 mock → Service 层零测试（恶性循环）。
- **A4 — `SettingsView` 570 行 god view**;且 `DataExportService.exportCSV/JSON` 被写在 Section body 里 (`SettingsView.swift:383-384`),**每次渲染都重新序列化全部习惯 + 误报 `exportPerformed` 埋点**（已核实 `DataExportService.swift:16/45`）。
- **A5 — `NotificationService` 不是 `@Observable`**,但 SettingsView 把它的值 copy 进 `@State`,状态不同步。
- **A6 — SwiftData 迁移**:v2.0 要加 `value/unit/target/frequency/groupId/updatedAt` 等字段,必须写 `SchemaMigrationPlan` 并测试从 v1.1 数据库升级（向后兼容,新字段带默认值）。
- **A7 — 后端无迁移框架**:`db.js` 用 `PRAGMA table_info` + `ALTER TABLE` 手搓,无版本表、无回滚。功能扩张前建议引入轻量 migration runner。
- **A8 — 重复 UI**:进度环、完成圆点在 6 处各写一遍,无共享组件。

---

## 5. 数据模型演进（前后端同步）

为支撑定量 + 灵活频率 + 分组,`Habit` / `HabitRecord` 与服务端 schema 需扩展：

```
Habit:      + type (.binary | .quantity)       + targetValue: Double?
            + unit: String?                     + frequency (daily | timesPerWeek(n) | daysOfWeek([Int]) | everyNDays(n))
            + groupId: UUID?                     + updatedAt: Date   (修 C2)
            + isBadHabit: Bool (戒除型,缺席=成功)

HabitRecord:+ value: Double?  (定量打卡的数值)  + updatedAt: Date
            + completedAt: Date (真实打卡时刻,区别于 date 的 startOfDay)

新增 HabitGroup: id / name / colorHex / sortOrder
后端: 对应列 + (habit_id, updated_at) 复合索引;tombstone 加保留窗口;补 subscription/entitlement 端点
```

> 所有日期统一以 UTC 锚定 + 显式存用户时区,根除 C1。

---

## 6. 商业化建议

- **两种模型可行,中间地带最危险**:一次性买断（Streaks $4.99 / Way of Life $9.99）口碑好但封顶;订阅是标准但"订阅疲劳/激进付费墙"是全品类头号差评。
- **在订阅之外加一个买断/终身解锁**:Habitify $64.99 终身、Strides $79.99 都在对冲。我们已有 StoreKit 订阅,**加终身解锁是低风险的好感 + 转化杠杆**。
- **免费层必须真能用**:Atoms 的"3 个习惯 + 第 2 个要等到第 3 天"是教科书级反面案例。
- **定价锚点**:premium 明显低于流媒体(~$3.99–6.99/月、~$20–35/年,年付折 20–30%)。Atoms £17.99/月被群嘲后被迫砍价 45%。
- **可作为 Pro 功能的候选**:无限习惯（免费给 5~7 个）、定量习惯、AI 洞察、高级分析、自定义主题/分享卡、Health 集成。基础打卡永远免费。

---

## 7. 分阶段执行路线图

### Phase 0 — 止血（发任何新功能前,2~3 天）
修 C1（时区 UTC 锚定 + 测试）、C2（加 `updatedAt`）、C3（手表联网 + 删除追踪）、C4（widget save 顺序）、S1（trust proxy）、S2（dd-trace/Sentry 接线）、S5（全局错误中间件 + 优雅退出）、S6（移除 db 文件 + 备份脚本）。**这些是数据安全底线。**

### Phase 1 — 桌面级功能补齐（v2.0 核心）
定量习惯 + 灵活频率 + 宽容连续天数 + 习惯分组 + 更深分析(周/月报、趋势)。配套 SwiftData 迁移（A6）+ 后端 schema/迁移框架（A7）+ Service 层抽象与测试（A1/A3）。

### Phase 2 — 差异化锚点
可分享进度卡片 + Live Activities/灵动岛 + 手表 Complication + Apple Health 双向同步 + S3/S4 同步性能修复。

### Phase 3 — 锦上添花
温和游戏化（可关）+ AI 周报/洞察 + 安静问责（可选）+ iPad NavigationSplitView 真双栏 + 可访问性补全（C 系列）。

### 贯穿全程
- 每个 Phase 前后跑 `cd server && npm test` + iOS/macOS build + `StrideTests`。
- 新 UI 文案补齐 6 语言本地化。
- 商业化:加终身解锁 + 划分 Pro 功能。

---

## 8. 风险与注意事项

1. **向后兼容**:所有新 SwiftData 字段必须有默认值 + 写迁移计划 + 测试 v1.1→v2.0 升级。
2. **前后端同步更新**:新字段需 API 同步支持,避免魔法链接/CORS/同步协议断裂。
3. **不要踩竞品的坑**:重度 RPG 游戏化、吝啬/挤牙膏的免费层、激进付费墙、强制社交、为 AI 而 AI、抢跑不稳定的 Widget/Live Activities(Atoms 的"无响应 widget"是品牌污点)、功能臃肿变成日程规划器、鼓励用户追踪过多习惯(Streaks 12 个、Atoms 6 个的"克制"反而被称赞)。
4. **watchOS 取舍**:排序/笔记可能不适合手表,但联网同步 + Complication 是必须的。

---

## 附录 A — 客户端中低优先级问题（节选）

- C5 四份重复 `toggleCompletion` 行为不一致(见 A1)
- C6 `currentStreak` 每次渲染重建 Set,无缓存,长列表浪费
- C7 多处 `try? modelContext.save()` 静默失败(HabitTemplatesView:148、TodayView 笔记编辑:268 等)
- C8 `StoreService.isPro` 只看"有无任意 entitlement",无产品 ID 映射、无服务端收据校验
- C9 `CompleteHabitIntent` 用字符串匹配习惯(重名冲突),无 `AppEntity`/`EntityQuery`;无"取消打卡"/"创建习惯" Intent
- C10 可访问性洞:热力图 84 格逐格朗读太吵无摘要;AddHabitView 颜色/emoji 选择器无 label 无 button trait;大字体下网格裁切
- C11 Onboarding 用自定义 DragGesture 翻页,丢失原生 TabView(.page) 可访问性
- C12 `completionRate` 新建习惯当天打卡=100%,拉高"30天均值"

## 附录 B — 后端中低优先级问题（节选）

- S7 `safeCompareHashes` 是死代码(token 查找走 SQL 等值,非常数时间;实际不可利用)
- S8 `?since` / `from` / `to` 未校验直接进 SQL 字符串比较(不崩但可能返回错误集合)
- S9 health check 不触碰 DB(SQLite 锁死也报健康);缺 `busy_timeout`
- S10 demo token 硬编码、可复用、有效期 1 年、提交进仓库(`seed-demo.js:13`),App Review 后应轮换/移除;`users.tier` 列从不写入(订阅校验未实现)
- S11 API 响应信封不统一;`/sync/pull` 无分页(重度用户全量拉);PUT 实为 PATCH 语义(COALESCE)易误解

---

*本报告由三路并行深度审查(iOS 客户端 / Node 后端 / 竞品调研)综合而成,所有 P0 缺陷已用 file:line 核实。建议从 Phase 0 止血开始。*
