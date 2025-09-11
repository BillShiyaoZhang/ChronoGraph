# ChronoGraph

一款基于 SwiftUI 的 iOS 日历活动「隐私导出」工具。ChronoGraph 允许你：按自定义日期范围聚合多日事件、选择需要包含的日历、应用不同隐私显示模式，然后一键生成高分辨率的长图（纵向）并使用系统分享。

> English version: see [README.md](README.md)

## 核心特性
- **日期范围**：今天 / 近 3 天 / 7 天 / 14 天（`CalendarManager.DateRange` 可扩展）。
- **多日历选择**：首次默认全选；后续选择持久化存储。
- **隐私模式**：隐藏（仅显示时间块占位）/ 缩略（标题 + 时间）/ 完整（全部字段）。遮罩逻辑仅在视图层，原始事件不出设备。
- **忙碌状态可视化**：基于 `EKEventAvailability`（忙碌 / 空闲 / 暂定 / 不可用），彩色圆点 + 标签。
- **折叠空白日期**：仅保留日期头部，减少长图高度。
- **确定性长图导出**：锁定宽度再渲染，避免布局抖动；自适应安全缩放；统一背景避免透明；支持 Light / Dark 一致性。
- **系统分享**：生成后直接弹出 `UIActivityViewController`（AirDrop / 微信 / 文件 / 备忘录 等）。
- **双渲染路径**：优先使用 iOS 16+ `ImageRenderer`，失败回退 UIKit Snapshot，降低空白图风险。
- **状态持久化**：隐私模式 / 日期范围 / 已选日历 ID / 折叠偏好 等。
- **授权自适应**：iOS 17+ 使用 `requestFullAccessToEvents()`；向下兼容 iOS 16 授权方式。

## 目录结构概览
```
ChronoGraph/
  Managers/
    CalendarManager.swift        // 授权、日历 & 事件抓取、偏好持久化
    ImageExportManager.swift     // SwiftUI 视图转 UIImage（长内容安全缩放）
    ExportedImageItemSource.swift// 分享表单富元数据 (临时 JPEG 文件)
  Models/
    CalendarEvent.swift          // EKEvent 投影 + 忙碌状态 + 隐私枚举
  Views/
    InAppEventListView.swift     // 日期分组列表 + 隐私遮罩 + 详情弹窗
    CalendarSelectionView.swift  // 日历过滤选择
    LiquidContentView.swift      // 主容器/工具栏/导出入口
  ChronoGraphApp.swift           // App 入口
```
架构风格：轻量 MVVM。*Managers* 持有状态与副作用；*Views* 纯渲染 + 用户交互；*Models* 隔离外部框架类型（EventKit）。

## 导出流程（高层）
1. 用户点击分享按钮。
2. 创建一个“等宽 / 等参数”的镜像列表视图（避免直接引用滚动中视图造成高度不稳定）。
3. `ImageExportManager.generateImage` 预计算目标高度，选择安全缩放（最长边 ≤ 16384px）。
4. 生成 UIImage，封装为 `ExportedImageItemSource`（附标题 / 图片 / 临时文件 URL）。
5. 弹出系统分享面板。

## 隐私模式说明
| 模式 | 用户看到 | 数据暴露风险 |
|------|----------|--------------|
| 隐藏 | 仅忙碌块（用状态名代替标题） | 极低 |
| 缩略 | 标题 + 起止时间 | 低 |
| 完整 | 标题 / 时间 / 位置 / 备注 | 取决于内容 |

> 原始事件不上传；导出图片仅在本地生成，是否外发由用户决定。

## 运行要求
- **iOS**：16.0+（支持 iOS 17 授权接口；后续可适配更高版本）
- **Xcode**：15+（Swift 5.9+），推荐使用最新稳定版
- **依赖框架**：SwiftUI / EventKit / UIKit / SafariServices

### 权限描述 (Info.plist)
确保包含：
- `NSCalendarsUsageDescription` — 说明为何需要读取日历事件。

## 快速开始
1. 克隆仓库。
2. 打开 `ChronoGraph.xcodeproj`。
3. 在目标设置里配置 Team（签名）。
4. 选择真机 / 模拟器运行，首次访问会弹授权框。
5. 选择日历 → 切换隐私模式 → 点击导出按钮。

## 可扩展点（Roadmap 方向）
| 领域 | 当前 | 规划/候选增强 |
|------|------|---------------|
| 布局类型 | 单列列表 | 周网格 / 热力图 / 时间轴
| 导出格式 | 长图 (JPEG) | PDF / 分段分页 / 矢量
| 隐私维度 | 3 个模式 | 字段级开关（隐藏位置/备注等）
| 筛选器 | 日历集合 | 关键词 / 忙碌类型 / 全天筛选
| 主题 | 系统色 | 自定义主题 / 自动配色
| 多语言 | 中文主文案 | 完整英文本地化 + 其他语言

## 错误与安全处理
- 事件抓取使用 UUID Token 避免竞态（后发覆盖先发）。
- 渲染尺寸上限防止 CoreGraphics 内存/尺寸崩溃。
- 双路径渲染降低空白图风险。
- 失败不强制自动分享（需非空图像）。

## 测试建议
当前测试目录已存在基础文件：
- 引入“虚拟事件工厂”生成确定性数据
- 针对隐私模式的快照测试
- 长列表（高密度事件）性能测试
- 导出图尺寸/比例边界测试

## 近期 Roadmap
- 周视图（方格化）原型
- 多区间合并导出（例如：今天 + 近七天）
- 导出进度指示（替换当前纯布尔状态）
- 文案英文化 / 本地化抽取

## 贡献指南
欢迎 PR。较大变更请先发起 Issue 讨论，包含：
1. 问题 / 用户场景
2. 方案草图（UI / 数据结构）
3. 兼容性或迁移影响

## License
当前未附 License 文件，默认视为作者“保留所有权利”。正式开源前请添加如 MIT / Apache-2.0 等协议。

## 致谢
- Apple EventKit & SwiftUI 团队
- 社区关于 SwiftUI 长内容截图 & 性能的经验分享

---
文档为初版草稿，后续将补充：截图演示 / 多语言 / 复杂导出示例。欢迎反馈。