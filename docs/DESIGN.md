# iJog 架构设计

## 总览

iJog 是一个单 target SwiftUI App，使用 TCA（swift-composable-architecture）管理状态与副作用，Tuist 负责从 `Project.swift` 清单生成 Xcode 工程。所有外部能力（定位、文件存储、时钟）都封装为 TCA `@DependencyClient`，Feature 层纯逻辑、可完整单测。

```
┌─────────────────────────────────────────────┐
│ AppFeature（TabView 根）                     │
│ ┌───────────────────────┐ ┌───────────────┐ │
│ │ RecordFeature 记录    │ │ HistoryFeature│ │
│ │                       │ │   历史列表     │ │
│ │  ┌─RunDetailFeature──┐│ │  ┌──────────┐ │ │
│ │  │ 跑步结束 → 详情    ││ │  │RunDetail │ │ │
│ │  └───────────────────┘│ │  └──────────┘ │ │
│ └───────────────────────┘ └───────────────┘ │
└─────────────────────────────────────────────┘
        │ 依赖注入（@Dependency）
        ▼
┌──────────────┐ ┌────────────────┐ ┌─────────────┐
│LocationClient│ │ RunsRepository │ │continuousClock│
│ CoreLocation │ │ JSON 文件存储   │ │ 计时器        │
└──────────────┘ └────────────────┘ └─────────────┘
```

两个 tab 各自独立，无跨 tab 通信：历史页每次 `onAppear` 重新从磁盘加载，跑步结束后切过去自然能看到新记录。

## 数据模型

```swift
struct Run: Codable, Identifiable, Equatable {
  let id: UUID
  let startedAt: Date        // 开始时间
  var duration: TimeInterval // 实际跑步秒数（不含暂停）
  var distance: Double       // 米
  var route: [RoutePoint]    // 轨迹点序列
}

struct RoutePoint: Codable, Equatable {
  let lat: Double
  let lon: Double
}
```

### 存储：JSON 文件

每次跑步存为 `Documents/Runs/<uuid>.json`，ISO 8601 日期编码。

选择 JSON 文件而非 SwiftData / GRDB 的理由：

- 一次跑步轨迹几十 KB，一辈子跑几千次也就几百 MB 量级，文件系统足够
- 零依赖、零迁移成本，坏了单个文件不影响其他记录
- 对 TCA 最友好：repository 是纯函数式客户端，测试用 in-memory mock 即可，不需要 Core Data 那套上下文生命周期

将来要做复杂统计（周报/月报）时再迁移 SwiftData，`RunsRepository` 是唯一接触存储的层，替换成本被隔离在这一个文件。

## 依赖客户端

### LocationClient

包装 `CLLocationManager`，以 `AsyncStream<CLLocation>` 暴露定位流：

```swift
@DependencyClient
struct LocationClient {
  var authorizationStatus: @Sendable () -> CLAuthorizationStatus
  var requestWhenInUse: @Sendable () -> Void
  var startUpdates: @Sendable () -> Void
  var stopUpdates: @Sendable () -> Void
  var locations: @Sendable () -> AsyncStream<CLLocation>
}
```

Live 实现要点：

- 共享单例 `CLLocationManager` + delegate（`NSObject, CLLocationManagerDelegate, @unchecked Sendable`）
- `activityType = .fitness`、`distanceFilter = 5`（米）、`desiredAccuracy = kCLLocationAccuracyBestForNavigation`
- `allowsBackgroundLocationUpdates = true` + `showsBackgroundLocationIndicator = true`，配合 Info.plist 的 `UIBackgroundModes: [location]` 实现锁屏记录

### RunsRepository

```swift
@DependencyClient
struct RunsRepository {
  var loadRuns: @Sendable () throws -> [Run]
  var save: @Sendable (Run) throws -> Void
  var delete: @Sendable (UUID) throws -> Void
}
```

## 记录页状态机

```
        startTapped               pauseTapped
  ┌───┐ ───────────► ┌─────────┐ ───────────► ┌────────┐
  │idle│             │ running │ ◄─────────── │ paused │
  └───┘ ◄─────────── └─────────┘  resumeTapped └────────┘
    ▲    saveCompleted  │    ▲                      │
    │                   │    │    finishTapped      │
    └───────────────────┴────┴──────────────────────┘
                     （保存 Run 后重置）

  running ──持续慢速≥10s──► autoPaused（isAutoPaused = true，冻结计时/距离/轨迹）
  autoPaused ──speed ≥ 2.5 m/s──► running（自动恢复）
  autoPaused ──暂停满 5 分钟──► 自动结束（有轨迹→保存 / 无移动→丢弃）
```

- **计时**：`running` 时用 `continuousClock.timer` 每秒发 `timerTicked`，`elapsed` 累加；暂停时取消该 effect。最终时长精度为秒。
- **距离**：`locationUpdated` 到来时与上一个有效点做 haversine 计算，**位移 < 2 米的点直接丢弃**（过滤 GPS 静止抖动，防止站在原地距离虚增），否则累加进 `distance` 并追加 `route`。
- **配速**：展示值 = `elapsed / (distance / 1000)`，距离为 0 时显示 `--`。
- **自动暂停（慢速自动排除）**：速度 < 2.0 m/s 持续 10 秒 → 冻结计时/距离/轨迹（慢速点丢弃）；速度 ≥ 2.5 m/s 自动恢复（滞回防抖）。GPS 在自动暂停期间保持开启以检测恢复；手动暂停则停 GPS。首次定位前（`lastSpeed == nil`）不参与慢速判断。开关在记录页工具栏，默认开。
- **慢速超时自动结束**：自动暂停持续 5 分钟 → 自动结束并保存当前跑步（等同手动"结束"）；若期间几乎无移动（轨迹不足 2 个点）则静默丢弃并清草稿，不生成空记录。

## 关键决策记录

| 决策 | 理由 |
|---|---|
| iOS 17.0 起步 | SwiftUI `MapPolyline` 需要 iOS 17；2026 年覆盖绝大多数活跃设备 |
| 本地化：英文 key + zh-Hans 翻译 | 源语言 en（SwiftUI `Text`/`Label` 自动查表），`String Catalog`（`Localizable.xcstrings`）维护 zh-Hans；`TextState`/格式化函数经 `String(localized:)` 查表；日期用系统 `.formatted` 自动本地化 |
| JSON 文件存储 | 见上文明细；简单优先 |
| 后台定位开箱启用 | 跑步 App 锁屏必用；Info.plist 一行 + 一个属性的成本 |
| 2 米抖动阈值 | 静止时 GPS 抖动通常 ±10m 内但密集；`distanceFilter = 5` 已过滤大部分，2 米兜底防止缓慢漂移累积 |
| 计时用 clock 而非时间差 | `paused` 需要停表语义；用 TestClock 可在单测中虚拟推进 |
| 结束需二次确认 | 防止跑步中误触丢数据 |
| 自动暂停阈值 2.0/2.5 m/s + 10s 确认 | 快走≈1.4-1.7 m/s、慢跑≈2.2+ m/s，两阈值滞回防抖；确认窗口防 GPS 瞬时漂移误判；GPS 不停（需检测恢复） |
| 崩溃保护：跑步草稿 | App 被系统 kill/崩溃/误划掉时最多丢 10 秒数据。进行中状态每满 10 秒及手动暂停时写入 `Documents/RunDraft.json`（Runs 目录外，防被 loadRuns 误读）；启动时发现草稿弹窗"恢复/丢弃"；保存失败时草稿保留，下次启动可恢复 |
| iCloud 同步：iCloud Drive 文档容器 | 数据本就是"每跑一个 UUID.json 文件"，直接在 iCloud 容器 `Documents/Runs/` 做文件并集合并（记录不可变→无内容冲突），比 CloudKit 轻。手动触发（历史页云朵按钮）→ `CloudSyncClient` 上传本地新增 + 下载云端新增 → 弹窗报数并刷新列表。v1 限制：删除不跨设备同步；自动同步（metadata query 监听）留待后续 |
| 地图偏移修正（GCJ-02） | 中国大陆地图瓦片用加密 GCJ-02 坐标，CoreLocation 输出 WGS-84，直接绘制轨迹会整体偏移数百米。存储保留 WGS-84 原始数据，仅渲染时经 `displayCoordinate` 转换（公开近似算法，精度 1-2 米；境外自动跳过）。蓝色定位点由系统处理无需转换；距离计算仍基于 WGS-84 |
| History 用 `StackState` 导航 | TCA 标准栈导航模式，路径可单测 |

## 测试策略

- **FormatTests**：haversine 用已知距离（纬度 1° ≈ 111km）断言；配速/时长格式化边界（0 距离 → `--`）
- **RecordFeatureTests**：`TestClock` 虚拟推进计时；mock 定位流喂 1km 正方形四角 → 断言距离 ≈ 3km；暂停期间 tick 不累计；`finishTapped` 保存的 `Run` 字段正确
- **HistoryFeatureTests**：加载按日期倒序；滑动删除后列表更新且 repository 收到 delete
