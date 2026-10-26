# PersonalAIFitness · 个人训练

面向个人使用的原生 iPhone 训练记录项目。SwiftUI + SwiftData，本地优先；当前为 **0.1 首个试用批次**，不是完整 AI 健身产品。

## 当前范围

- 手动创建/修订计划，明确确认后产生新版本，保留旧版本。
- 力量、有氧、徒手记录；热身/正式组、重量/次数/时长/距离、可选 RPE/RIR、上次数据、复制与备注。
- 逐组显式保存、休息计时、暂停/恢复、提前结束与重开后的进行中会话入口。
- 本地历史与基础统计、自定义动作；初始库没有虚构的个人训练或健康数据。
- 加密逻辑备份/恢复：PBKDF2-SHA256 + AES-GCM，恢复前验证与保护副本。
- HealthKit 仅提供步数、静息心率与体重的基础只读验证。

**尚未实现**：AI 服务、身体状态引擎、规则自动计划、完整健康历史/增量同步/多来源处理、动作 GIF/教学视频、收藏/替代、档案变更时间线及完整趋势。运动限制目前是手动档案，不会自动排除动作。进行中的未提交输入不能保证在强制终止后保留；已成功保存的结果由持久化恢复。

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
| `Sources/PersonalFitness/Storage` | SwiftData schema v1、显式保存、备份恢复 |
| `Sources/PersonalFitness/Health` | 基础只读能力验证 |
| `Tests/PersonalFitnessTests` | 持久化与加密备份测试 |
| `.github/workflows/ios-trial.yml` | 测试和未签名构建 |

没有账户、订阅、广告、社交或业务后端，当前没有 AI 请求或健康数据外发。公开的是程序源码，不包含使用者的训练数据、健康数据、证书或密钥。器械图为生成的视觉占位，不是动作教学素材；图标源为项目自有 SVG。
