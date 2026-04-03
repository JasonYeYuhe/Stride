# Stride v1.1 升级计划书

> 生成日期: 2026-04-03
> 状态: 待 Gemini Review 后执行

---

## 一、现状总结

Stride v1.0 (Build 8) 已提交 App Store 审核，功能完整：
- 习惯追踪、打卡、连续天数、统计热力图
- 多平台支持 (iOS/macOS/watchOS/Widgets)
- 魔法链接认证 + 云同步
- 6 语言本地化、StoreKit 2 订阅
- 安全加固已完成 (14项修复)

---

## 二、Bug 修复 (Priority: High → Low)

### BUG-1: 后端 entries 路由未处理的数据库错误 [HIGH]
- **文件**: `server/routes/habits.js` ~line 120
- **问题**: `POST /habits/:id/entries` 中 UNIQUE 约束以外的 DB 错误会直接 throw，暴露内部信息
- **修复**: catch 所有 DB 错误，返回 500 + 通用错误消息

### BUG-2: 后端 entry 删除缺少日期格式验证 [MEDIUM]
- **文件**: `server/routes/habits.js` ~line 129
- **问题**: `DELETE /habits/:id/entries/:date` 不验证 date 参数格式
- **修复**: 复用已有的日期验证正则 `/^\d{4}-\d{2}-\d{2}$/`

### BUG-3: 后端 token 比较存在时序攻击风险 [MEDIUM]
- **文件**: `server/auth.js`
- **问题**: token hash 使用 `===` 比较，理论上可被时序攻击
- **修复**: 使用 `crypto.timingSafeEqual()` 进行常数时间比较

### BUG-4: 后端 sync/habits 端点缺少细粒度限流 [MEDIUM]
- **文件**: `server/routes/sync.js`, `server/routes/habits.js`
- **问题**: 仅有全局 100/15min 限流，sync 端点可被滥用
- **修复**: 为 sync 添加 30/min、habits CRUD 添加 60/min 的独立限流

### BUG-5: iOS 端 ModelContext.save() 静默失败 [LOW]
- **文件**: `Stride/Sources/Views/TodayView.swift`, `AddHabitView.swift`, `SettingsView.swift`
- **问题**: 多处 `try? modelContext.save()` 无用户反馈
- **修复**: 改为 do-catch，失败时显示 toast/alert

### BUG-6: 后端 SELECT * 查询效率低 [LOW]
- **文件**: `server/routes/habits.js`, `server/routes/sync.js`
- **问题**: 多处使用 `SELECT *`，返回不必要的列
- **修复**: 替换为明确的列名列表

---

## 三、新功能 (按优先级排序)

### FEAT-1: 交互式 Widget [HIGH] ⭐
- **价值**: iOS 17 交互式 Widget 是用户最期待的功能，直接在桌面打卡
- **实现**:
  - 使用 `AppIntent` + `Button` 在 Widget 中实现打卡切换
  - systemSmall: 点击整个 Widget 切换最近习惯
  - systemMedium: 每个习惯行独立可点击
  - 复用已有的 `CompleteHabitIntent`
- **文件改动**: `StrideWidget/StrideWidget.swift`, 新增 `WidgetToggleIntent.swift`
- **预计工作量**: 中等

### FEAT-2: 习惯排序 (拖拽重排) [HIGH]
- **价值**: 用户习惯多了之后排序需求强烈，影响日常体验
- **实现**:
  - Habit model 添加 `sortOrder: Int` 属性
  - TodayView 的习惯列表支持 `.onMove` 拖拽
  - SettingsView 习惯管理支持拖拽排序
  - 同步时包含 sortOrder 字段
- **文件改动**: `Habit.swift`, `TodayView.swift`, `SettingsView.swift`, `SyncService.swift`, `server/routes/sync.js`
- **预计工作量**: 中等

### FEAT-3: 单个习惯独立提醒 [HIGH]
- **价值**: 不同习惯在不同时间提醒（如晨练6:30，阅读21:00）
- **实现**:
  - Habit model 添加 `reminderTime: Date?` 和 `reminderEnabled: Bool`
  - 习惯编辑界面添加提醒时间设置
  - NotificationService 为每个习惯注册独立通知
  - 通知内容包含习惯名和 emoji
- **文件改动**: `Habit.swift`, `AddHabitView.swift`(改为 EditHabitView), `NotificationService.swift`
- **预计工作量**: 中等

### FEAT-4: 习惯编辑功能 [HIGH]
- **价值**: 当前创建后无法修改名称/emoji/颜色，用户反馈最多
- **实现**:
  - 将 AddHabitView 扩展为通用的 HabitEditView
  - TodayView 长按/右键 → 编辑
  - SettingsView 习惯管理中添加编辑入口
- **文件改动**: `AddHabitView.swift` → `HabitEditView.swift`, `TodayView.swift`, `SettingsView.swift`
- **预计工作量**: 小

### FEAT-5: 灵活的习惯频率目标 [MEDIUM]
- **价值**: 支持「每周3次」等非每日习惯
- **实现**:
  - Habit model 添加 `frequencyType: .daily | .weekly(times: Int) | .custom(daysOfWeek: [Int])`
  - 打卡逻辑适配：连续天数改为「目标完成率」
  - 进度环显示周目标完成情况
  - Widget 适配新的完成判断逻辑
- **文件改动**: `Habit.swift`, `TodayView.swift`, `StatsView.swift`, `StrideWidget.swift`
- **预计工作量**: 大

### FEAT-6: 习惯笔记/日记 [MEDIUM]
- **价值**: 打卡时记录一句话，增加回顾价值
- **实现**:
  - HabitRecord model 添加 `note: String?`
  - 打卡时可选输入笔记（轻量弹窗）
  - StatsView 显示笔记时间线
  - 导出包含笔记
- **文件改动**: `Habit.swift`, `TodayView.swift`, `StatsView.swift`, `DataExportService.swift`
- **预计工作量**: 中等

### FEAT-7: 后台自动同步 [MEDIUM]
- **价值**: 当前只有前台手动同步，多设备体验不佳
- **实现**:
  - 使用 `BGAppRefreshTask` 注册后台任务
  - 每 30 分钟尝试同步一次
  - 失败时自动排队重试
  - 本地变更队列 (offline queue) 确保离线打卡不丢失
- **文件改动**: `SyncService.swift`, `StrideApp.swift`, `Info.plist`
- **预计工作量**: 大

### FEAT-8: 习惯分组/分类 [LOW]
- **价值**: 习惯多时便于管理
- **实现**:
  - 新增 HabitGroup model
  - TodayView 按分组折叠显示
  - 默认「未分组」
- **预计工作量**: 中等

### FEAT-9: 每周/月回顾总结 [LOW]
- **价值**: 提供阶段性反馈，增加粘性
- **实现**:
  - 新增 ReviewView，周日/月末展示
  - 本周/月完成率趋势
  - 最佳/最差习惯
  - 分享卡片
- **预计工作量**: 中等

### FEAT-10: iPad 优化布局 [LOW]
- **价值**: iPad 用户体验差（当前仅 iPhone 拉伸）
- **实现**:
  - 使用 `NavigationSplitView` 双栏布局
  - 侧边栏：习惯列表
  - 详情栏：统计/热力图
  - 适配多任务/分屏
- **预计工作量**: 中等

---

## 四、代码质量改进

### QA-1: 添加 Service 层单元测试
- AuthService mock 测试
- SyncService 推拉逻辑测试
- StoreService 重试逻辑测试

### QA-2: 后端测试覆盖率提升
- sync 路由边界测试
- 并发同步冲突测试
- 限流测试

### QA-3: SwiftData Migration Plan
- 为新增字段 (sortOrder, reminderTime, frequency, note) 准备 schema migration
- 测试从 v1.0 数据库升级

---

## 五、执行计划

### Phase 1 — Bug 修复 + 基础功能 (立即执行)
1. ✅ BUG-1 ~ BUG-6: 全部 bug 修复
2. ✅ FEAT-4: 习惯编辑
3. ✅ FEAT-2: 习惯排序

### Phase 2 — 核心新功能
4. FEAT-1: 交互式 Widget
5. FEAT-3: 独立提醒
6. FEAT-6: 习惯笔记

### Phase 3 — 高级功能
7. FEAT-5: 灵活频率
8. FEAT-7: 后台同步

### Phase 4 — 锦上添花
9. FEAT-8: 习惯分组
10. FEAT-9: 周/月回顾
11. FEAT-10: iPad 布局

---

## 六、注意事项

1. **向后兼容**: 新增 SwiftData 字段必须有默认值，确保 v1.0 用户平滑升级
2. **同步协议**: 新字段需要后端 API 同步支持，前后端同步更新
3. **Pro 功能划分**: 习惯笔记、灵活频率、后台同步可作为 Pro 功能
4. **本地化**: 所有新 UI 文本需要 6 语言翻译
5. **watchOS**: 新功能需评估 watchOS 适配（排序、笔记可能不适合手表）
6. **App Store 审核**: v1.0 审核通过后再提交 v1.1
