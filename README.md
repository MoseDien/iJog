# iJog

一个简单好用的跑步记录 App。开始跑步，记录轨迹，回顾历史——仅此而已。

## 功能

- **记录** — GPS 实时轨迹、时长、距离、配速；支持暂停/继续；锁屏后台持续记录
- **自动暂停** — 慢速（走路/等灯）持续 10 秒自动排除在数据外，速度回升自动继续，只保留跑步的部分；暂停满 5 分钟自动结束并保存；可在记录页开关
- **崩溃保护** — 跑步中每 10 秒自动保存草稿，App 被系统杀掉/崩溃后重新打开可恢复（最多丢 10 秒）
- **iCloud 同步（手动）** — 历史页点云朵按钮，把本地跑步上传 iCloud Drive 并拉取其他设备的新记录（按 UUID 并集合并；删除不参与同步）
- **地图** — 跑步过程中实时绘制路线；历史记录回看完整轨迹
- **历史** — 按日期倒序浏览所有跑步记录，滑动删除，查看单次详情
- **双语** — 简体中文 / English（跟随系统语言，文案在 `Localizable.xcstrings` 维护）
- **地图坐标修正** — 中国大陆 GCJ-02 偏移自动转换，轨迹与实际道路对齐（存储仍为标准 WGS-84）

## 技术栈

| 组件 | 选型 |
|---|---|
| 项目生成 | [Tuist](https://tuist.dev) 4.203 |
| 架构 | [swift-composable-architecture](https://github.com/pointfreeco/swift-composable-architecture) (TCA) 1.26 |
| UI | SwiftUI |
| 地图 | MapKit（SwiftUI `Map` + `MapPolyline`） |
| 定位 | CoreLocation |
| 存储 | JSON 文件（每次跑步一个文件，`Documents/Runs/`） |
| 最低系统 | iOS 17.0，iPhone / iPad 通用 |

## 环境要求

- macOS + Xcode 26+（Swift 6.3）
- [mise](https://mise.jdx.dev/)（用于固定 Tuist 版本，见 [`.mise.toml`](.mise.toml)）

## 常用命令

```bash
mise exec -- tuist install     # 解析 SPM 依赖（TCA）
mise exec -- tuist generate    # 生成 iJog.xcodeproj 并打开
mise exec -- tuist build       # 编译
mise exec -- tuist test        # 运行单元测试
```

> 如果你的 shell 已激活 mise shims，可以省略 `mise exec --` 前缀直接用 `tuist`。

> ⚠️ **务必打开 `iJog.xcworkspace`，不要直接打开 `iJog.xcodeproj`**。依赖（含 TCA 宏插件）的工程挂在 workspace 下，裸开 xcodeproj 会报 `plugin for module 'ComposableArchitectureMacros' not found` 等错误。

## 目录结构

```
iJog/
├── .mise.toml              # 固定 tuist 版本
├── Package.swift           # SPM 外部依赖声明（TCA）
├── Project.swift           # Tuist 工程定义（App + 测试 target）
├── docs/DESIGN.md          # 架构设计文档
└── iJog/
    ├── Sources/
    │   ├── iJogApp.swift       # @main 入口
    │   ├── AppFeature.swift    # 根 Feature（TabView）
    │   ├── Models/             # Run 数据模型
    │   ├── Features/
    │   │   ├── Record/         # 记录页（跑步中）
    │   │   └── History/        # 历史列表 + 详情
    │   └── Support/            # LocationClient / RunsRepository / 格式化工具
    └── Tests/iJogTests/        # 单元测试
```

## 在模拟器中验证跑步记录

模拟器没有真实 GPS，用菜单模拟移动定位：

1. 运行 App，授权定位
2. 模拟器菜单 **Features ▸ Location ▸ City Run**（模拟一段持续移动的跑步路线）
3. 回到 App 点"开始"，观察距离增长、路线绘制
4. 点"结束"后切到"历史" tab 查看记录

真机测试后台记录：跑步中锁屏，应看到状态栏蓝色定位指示条，轨迹持续记录。

## 设计文档

架构与关键决策见 [docs/DESIGN.md](docs/DESIGN.md)。
