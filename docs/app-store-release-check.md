# ChronoGraph App Store 发布前检查

检查日期：2026年10月29日。发布目标为 **0.2.0，构建 2**，Bundle ID 为 `com.shiyao-zhang.ChronoGraph`，显示名称为 Chrono，支持 iPhone、iPad 及 iOS 17 以上系统。本轮保留这些标识和版本号。

仓库内发现的问题已修复并纳入回归验证。正式提交仍需完成分发签名、App Store Connect 元数据与隐私标签、审核账号，以及专用账户真机验收。未签名归档不能直接作为可上传的分发包。

## 已修复问题

| 问题 | 修复后的行为 |
|---|---|
| 缺少隐私清单 | App 包含 `PrivacyInfo.xcprivacy`，声明自有偏好使用 UserDefaults 的理由 `CA92.1`，以及云功能的账号标识、设备标识和用户内容收集；不追踪。 |
| 隐私政策依赖网络，注册页没有直接入口 | 设置和登录／注册页均可打开随应用提供的中英政策，离线也能阅读。政策补全云日期／逐条规则、设备标识、删除路径与保留说明。 |
| 超长图片绕过尺寸限制 | 允许小于 1 倍缩放，限制最长边为 16,384 像素、总像素为 1,600 万，拒绝非法尺寸；失败时清除旧图片。 |
| 导出语言与应用选择不一致 | 独立图片渲染器继承应用选择的语言、字体尺寸及明暗外观。 |
| 极端日期输入可能溢出或卡住界面 | 本地范围最多 3,660 个日历日；非法、非有限及超限输入明确拒绝，不自动裁剪已确认共享配置。云上传仍受原有 180 天上限约束。 |
| 升级后的旧超限范围与跨时区边界 | 旧超限共享配置可审阅并确认缩短；旧副本数量按已有镜像估算，审阅不修改数据。个人日期校验、保存与恢复均保留原时区，避免合法边界被误拒。 |
| 多年本地日程可能被 EventKit 截断 | 按最多 366 日分段查询，并按日历、事件与起止时间去重。 |
| 反复读取云数据遗留网络资源 | 短生命周期客户端销毁时撤销并释放其 URLSession。 |
| 安装包包含内部文档和测试版标记 | 排除 README、设计分析、进度与国际化开发说明；云功能保留正式的邀请码制访问，移除测试版文案。 |

## 构建与验证

使用 Xcode 27.1 和 iOS 27.1 SDK，最低部署目标保持 iOS 17。最终归档路径为 `/private/tmp/ChronoGraph-0.2.0-2-ready.xcarchive`，构建日志为 `/private/tmp/ChronoGraph-appstore-ready-archive.log`。签名关闭，仅用于检查真机架构与安装包。

最终单元测试为 **222 项通过、0 失败，22 项显式跳过**，结果包为 `/private/tmp/ChronoGraph-appstore-ready-logic.xcresult`。跳过项需要专用日历权限、原生账户或在线集成环境。后端完整 SQLite 测试为 **100 项通过**；这不能替代 PostgreSQL 专项验收。

界面回归覆盖 **13 条不同的 iPhone 路径，均有最终通过记录**：双语政策的设置及注册入口、账户删除、离线退出、日期跨视图切换、首次与重复图片分享、保存照片、共享传输同意、订阅移除、多来源逐条规则和云创建。iPhone 17 Pro／iOS 26.5 首轮结果为 9 通过、2 失败；失败是注册后键盘遮住表单时自动化滑动区域错误。修正测试为关闭键盘并滚动表单后，在 iPhone 17e／iOS 26.5 定向复跑的 8 项全部通过，包含两项失败用例及最终日期／审阅流程。没有把首轮结果包整体记为通过。

小尺寸 iPad mini／iOS 26.1 的中英设置及注册入口 **4 项全部通过**；深色与最大辅助字体的政策截图已检查。模拟器日志仍有 SwiftUI 键盘工具栏与 frame 运行时警告，最终流程可完成；真机验收应继续检查键盘布局。界面测试使用虚拟日历和内存 HTTPS 传输，保存照片也仅保存虚拟图片，不证明真实 iCloud 或生产账号流程。

| 证据 | 结果包 |
|---|---|
| iPhone 首轮 | `/private/tmp/ChronoGraph-appstore-final-ui.xcresult` |
| iPhone 定向复跑 | `/private/tmp/ChronoGraph-appstore-ready-ui.xcresult` |
| iPad 双语及辅助字体 | `/private/tmp/ChronoGraph-appstore-ipad-policy.xcresult` |

定向复跑的用例结束后，可选 `simctl diagnose` 采集进程未退出；单独终止该采集后，Xcode 正常完成并返回 `TEST SUCCEEDED`。最终结果包摘要为 Passed、8 通过、0 失败；中英政策截图亦已检查。

已核对成品的版本、Bundle ID、日历完整访问及照片仅添加用途说明、后台任务标识、图标和资源。1024×1024 的浅色／深色／着色图标均存在且不透明。成品没有 ATS 放宽配置，没有 DEBUG 虚拟登录凭据、虚拟服务地址或测试启动开关。

正式 HTTPS API 的 `/healthz` 与 `/health/ready` 均返回 `{"status":"ok"}`。这项只读检查说明当前服务及数据库可用，不能替代真实账号与生产恢复验收。

## 提交前必须完成

1. **分发签名及上传验证。** 本机检测到 Apple Development 和 Developer ID Application 证书，未检测到 iOS 分发证书。使用与现有 Bundle ID 匹配的付费团队，在 Xcode Organizer 完成 App Store Connect 分发签名和 Validate App。Developer ID Application 用于 macOS 分发，不能替代 iOS 分发签名。确认 App Store Connect 中的版本为 0.2.0；若构建 2 已被接收，须为新的上传选择未使用的构建号。
2. **发布在线隐私政策并填写隐私标签。** 将本轮两份政策同步到公开地址，App Store Connect 的隐私政策链接也应指向更新后的版本。云功能可选但会持续保存数据，不能填“不收集数据”。隐私清单不会自动代填 App Store Connect 的隐私问卷。
3. **提供审核资源。** 在 App Review Information 填写可用的云账号和密码，提供能演示接收日历、配对及找时间的专用参与者和操作步骤；邀请注册需提供有效邀请码。审核期间保持后端可访问。不要把密码写进仓库或本文件。
4. **完成产品页。** 提交真实 iPhone 和 iPad 使用截图、主语言描述（建议补充中英本地化）、支持 URL、联系信息、年龄分级和当前分发地区要求。在 App Store Connect 完成加密出口问卷；本轮未替账号持有人作出口分类声明。
5. **专用账户真机验收。** 按 [iCloud 共享验收](iCloud-sharing-validation.md) 验证源事件不被修改、降低字段后实际清除旧副本、另一个账户订阅、撤销共享、拒绝及恢复日历权限、照片仅添加权限、外部 App 接收图片与真实后台调度。还需覆盖最低支持的 iOS 17 和当前正式 iOS；本机自动化运行时不能证明这两端的实际表现。

## 生产运维建议

依据 [后端说明](../backend/README.md) 核对备份保留、私有异地备份和恢复流程。现有同机数据库 dump 不能覆盖主机或磁盘丢失。PostgreSQL 迁移及并发行为按既有服务验收流程确认。

## App Store Connect 隐私标签

以下来自当前代码的实际收集；用途均为 App Functionality，关联用户，均不用于 Tracking。

| 分类 | 类型 | 实际内容 |
|---|---|---|
| Identifiers | User ID | 账号 ID、用户名／昵称、参与者关联。 |
| Identifiers | Device ID | 随机设备 ID，用于会话、上传设备及日历写回任务。 |
| User Content | Other User Content | 用户明确授权上传的日历字段、邀约与回应。 |

纯本机浏览和图片生成不会自动上传图片。应用没有广告或行为分析 SDK。当前构建 `CHRONOGRAPH_APPLE_SIGN_IN = NO`，采用自有用户名密码登录；如以后启用 Apple 登录，应先完成删除账号时撤销 Apple token 的服务端流程。

## 审核说明参考

> Chrono works without signing in for local calendar browsing, image export and calendar-account sharing. Full Calendar access is required to preview events and maintain explicitly confirmed output calendars. Photos access is add-only and requested when saving an exported image.
>
> Optional cloud collaboration uses invite-only username/password accounts. Signing in does not enable calendar uploads. Open Settings → Cloud collaboration, sign in with the review credentials supplied in App Review Information, choose My uploaded calendars, create a sharing configuration, review its sources, dates and fields, then explicitly approve transfer. Account deletion is available under Account and server → Delete cloud account. Settings and the login/registration page contain an offline Privacy Policy.
>
> Public iCloud subscription links must be enabled and copied in Apple Calendar; EventKit cannot publish or retrieve those links. Chrono maintains confirmed copies and lets users explicitly save and share a supplied link. Local update status does not guarantee immediate provider or subscriber refresh.

为审核账号补充具体的参与者、配对资源和步骤后再粘贴到 App Store Connect。

## 官方依据

- [Apple 审核指南](https://developer.apple.com/app-store/review/guidelines/)：完整功能和审核访问、正式版本、应用内政策与账号删除；自有账号系统的登录例外。
- [Required reason API 声明](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)：声明应用实际使用的 API 及批准理由。
- [隐私标签定义](https://developer.apple.com/app-store/app-privacy-details/)：收集类型、功能用途、关联用户与追踪。
- [应用提交要求](https://developer.apple.com/app-store/submitting/)及[出口合规](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)：正式上传时按当前要求完成。
