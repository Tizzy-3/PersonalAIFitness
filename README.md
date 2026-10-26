# PersonalAIFitness · 个人训练

面向个人使用的原生 iPhone 训练记录项目。SwiftUI + SwiftData，本地优先；当前为 **0.4 AI 教练闭环批次**，不是完整需求已交付，也没有完成真机验收。

## 当前范围

- 手动创建/修订计划，明确确认后产生新版本，保留旧版本。
- AI 制定起始周计划：明确目标、经验、训练日、预算、器械与安全信息；本地规则生成可行候选，AI 从候选中选择解释；七天对比后明确确认才生成每日计划与每周排程。支持明确标记的离线本地规则模式。
- 多手动计划切换、可恢复的删除；删除保留版本、训练历史及进行中执行快照，恢复不自动生效。首页显示今天安排，休息日不会拿别的训练日冒充今天。
- 力量、有氧、徒手记录；热身/正式组、重量/次数/时长/距离、可选 RPE/RIR、上次数据、复制与备注。
- 逐组显式保存、休息计时、暂停/恢复、提前结束与重开后的进行中会话入口。
- 本地历史与基础统计、自定义动作；初始库没有虚构的个人训练或健康数据。
- 扩展中文动作库、英文/别名搜索、肌群/器械筛选、收藏、动作步骤/常见错误与部分有许可的离线示范短片。
- 可配置的 OpenAI 兼容 Chat Completions：自有接口/模型/Keychain密钥，每次先预览数据再明确发送；基于真实记录与本地动作资料问答，保守减量建议经校验、对比和确认才产生新计划版本。
- 加密逻辑备份/恢复：PBKDF2-SHA256 + AES-GCM，恢复前验证与保护副本。
- **AI 教练建档访谈**：教练逐轮结构化追问，每项档案都带来源（本人回答／本人确认／健康数据／待确认推断／未知）；AI 的推断必须由本人逐条确认后才参与制定计划；成年与运动限制必须由本人明确回答，不被默认。
- **按档案组合首版计划**：AI 只在本地允许的动作池内选择，组数、休息、时间再由同一套规则复核；未知能力不生成公斤数。生成结果仍走"看差异 → 本人确认 → 生效"的原流程。
- **每日跟进**：训练前记录精力/酸痛/疼痛/可用时间，训练后记录主观用力与感受；客观组数时长由程序计算，用户不能改写；没回答记为"未回答"，不当成"没问题"。
- **Apple 健康真实读取**：步数、静息心率、HRV（SDNN）、睡眠、活动能量、体重、运动时长、心肺适能；按类型保存增量锚点，样本时间与读取时间分开显示；空结果报"暂无样本"，不谎称权限被拒。
- **身体状态评估**：安全、恢复证据、表现趋势、可信度、今日建议、依据六部分分开输出，**不合成恢复分**；缺数据时只可能给"保守或先收集"，不会给"状态良好"。
- **调整与复盘**：保持原计划／仅调整今天／渐进或周期修改三类；长期修改生成新版本并展示前后差异与引用依据，仅本次修改不碰长期计划；依据变化后未确认建议自动失效。周月复盘用确定性统计，并明确列出这份复盘没能量到的东西。

**尚未实现**：长期周期化与自动进阶、医学限制的个体适配、全库 GIF 与每个动作的完整教学视频、档案修订时间线、历史更正与完整趋势图。自动制定仍只面向本人明确确认已成年、无已知限制、今日无痛的成人；有疼痛或限制时不自动制定。未提交输入不能保证在强制终止后保留。

**本批验证层级**：CI 编译、Core 单测与 iOS Simulator 测试已通过。**未做**真机签名安装、真实 HealthKit 读取、真实 AI 服务联通验证。编译和模拟器测试通过不等于这些已验收。

## 构建与测试

目标 iOS 27.0；仓库自带一个纯 Swift 核心包、iOS App、App tests 和确定性工程生成脚本，无第三方运行依赖。

```sh
python3 scripts/generate_project.py
python3 scripts/check_source.py
swift test --package-path Packages/FitnessCore
xcodebuild test -project PersonalFitness.xcodeproj -scheme PersonalFitness \
  -destination 'platform=iOS Simulator,id=<available iOS 27.0 simulator UDID>'
```

GitHub Actions 固定 Xcode 27.0，依次运行结构检查、核心测试、iOS Simulator 测试和 iPhoneOS 构建，全部成功后打包 **未签名 IPA**。是否已通过，以具体 workflow run 为准；仅有源码和结构检查不代表构建成功。

在成功的 Actions run 中下载 `PersonalFitness-unsigned-ipa`。需要使用自己的证书与描述文件签名后安装，默认 Bundle ID 为 `com.personalfitness.private`；HealthKit 要求最终签名/profile 匹配其 entitlement。CI 通过不等于手机安装或健康数据读取已验证。详见 [试用说明](Documentation/TRYOUT.md)。

## 目录

| 路径 | 用途 |
|---|---|
| `Packages/FitnessCore` | 领域值、验证、计划版本、训练状态、备份 DTO 与单元测试 |
| `Sources/PersonalFitness/Features` | 原生界面与用户输入 |
| `Sources/PersonalFitness/Storage` | SwiftData schema v1/v2/v3、迁移、显式保存、备份恢复 |
| `Sources/PersonalFitness/Planning` | 制定条件、AI候选选择、七天对比/确认与排程执行 |
| `Sources/PersonalFitness/Coach` | API、Keychain、发送预览、教练与建议确认 |
| `Sources/PersonalFitness/ExerciseMedia` | 有许可的动作媒体展示 |
| `Sources/PersonalFitness/Health` | 基础只读能力验证 |
| `Tests/PersonalFitnessTests` | 持久化与加密备份测试 |
| `.github/workflows/ios-trial.yml` | 测试和未签名构建 |

没有账户、订阅、广告、社交或业务后端。AI仅在本人预览并明确发送后调用所配置服务，Apple健康摘要尚不发送。公开源码不包含使用者的训练数据、健康数据、证书或密钥。器械图为生成的视觉占位，不是动作教学素材；图标源为项目自有 SVG。

完整范围见 [功能状态与验收](Documentation/CAPABILITIES.md)，接口配置见 [AI连接说明](Documentation/AI-CONNECTION.md)，媒体逐项许可见 [素材来源](Documentation/MEDIA-SOURCES.md)。没有API Key时不会显示预设AI回答。

制定流程见 [计划创建](Documentation/PLAN-CREATION.md)，规则和科学依据适用范围见 [起始周计划规则](Documentation/PLANNING-RULES.md)。具体组次、估时与排程阈值是版本化保守产品策略，不是研究认证的个人最佳处方。
