# 动作库与示范素材来源

## 本批次实际覆盖

- 66 个固定 ID 的中文动作：力量、有氧和徒手，保留 0.1 原 15 个 ID 及记录口径。
- 别名、主要/辅助肌群、器械、动作模式、技术难度、通用步骤、常见错误、替代和部分进阶变式。
- 搜索支持多关键词、别名、英文与辅助肌群；可按类型、主要肌群、器械和收藏筛选。
- 详情可离线查看已内置素材，加入手动计划需预览并确认新版本。

本批实际内置 **11 个动作的源视频派生示范**：每项包含 H.264 MP4、静态封面，以及真实视频连续片段转换的 GIF 预览。其余 55 个动作明确显示暂无已核验示范素材；不提供伪造播放按钮。

GIF 不是将两张照片交替播放：它从对应的真实短片截取中部连续不超过 6 秒，缩至 160px 范围、6fps。计划和训练页面最多为一个指定动作播放预览，其余显示封面；减少动态效果或应用不活跃时显示静态封面。详情中的 MP4 用 AVKit 播放，可离线使用。

**这些是动作示范短片，不是完整教学课程。完整教学视频本批尚未接入。** 视频画面仅用于帮助理解动作，不证明个人动作已合格、负重设置适宜或具有诊疗结论。

## 为什么选择这些文件

来源是 [wger 官方 API](https://wger.de/api/v2/video/)，每条接受的媒体均明确标为作者 **Goulart**、许可 **CC BY-SA 4.0**。wger 的[官方文档与变更记录](https://wger.readthedocs.io/en/stable/)还说明 Goulart 向项目贡献了视频并以 CC BY-SA 许可发布。每项保留 source object ID、原始 URL、作者、许可、原片 SHA256、压缩后文件 SHA256、封面 SHA256、GIF SHA256 和转换说明，见资源目录中的 `media-manifest.json` 与 `NOTICE.md`。

媒体压缩、去音轨、调整尺寸和截取 GIF 的衍生文件仍按 [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) 提供。媒体许可只覆盖这些明确列出的素材；本项目未复制 wger 应用源码。

没有把第三方上传者名字直接当成原作者授权证明。调查期间获取过的其他静态图片没有纳入 App：部分照片的独立原始权属无法充分确认，不为增加覆盖率而打包。辅助引体对应的某段器械引体视频也未采用，因为画面无法清楚确认辅助设置，不将近似动作泛化绑定。

## 动作文字和筛选分类

中文步骤和常见错误是本项目编写的通用动作提示；没有声称经过针对使用者的现场指导或专业动作审核。技术难度只用于检索，不能当成个人安全评级。动作替代项只展示候选关系，不会自动忽略个人运动限制替换生效计划；手动加入仍需本人核对并确认。

训练中出现疼痛或异常不适应先停止相关动作，App 不根据视频作疾病诊断。尚无个人训练历史时，界面保持未知，不生成虚构成绩。

## 已打包映射

| 中文动作 | 稳定 ID | wger 原始动作 | 视频记录 | 作者/许可 |
|---|---|---|---|---|
| 杠铃卧推 | `builtin.barbell-bench-press` | Bench Press | [wger.video.21](https://wger.de/media/exercise-video/73/2bdb390c-312c-4497-a722-5eed2c823e5a.MOV) | Goulart / CC BY-SA 4.0 |
| 绳索过顶臂屈伸 | `builtin.cable-overhead-triceps-extension` | Triceps Extensions on Cable | [wger.video.55](https://wger.de/media/exercise-video/659/1f2eb3b6-3185-429f-8330-26dc88f39aff.MOV) | Goulart / CC BY-SA 4.0 |
| 哑铃卧推 | `builtin.dumbbell-bench-press` | Benchpress Dumbbells | [wger.video.17](https://wger.de/media/exercise-video/75/080c799b-8afd-4130-8d72-9cef0cd79f54.MOV) | Goulart / CC BY-SA 4.0 |
| 哑铃弯举 | `builtin.dumbbell-curl` | Biceps Curls With Dumbbell | [wger.video.48](https://wger.de/media/exercise-video/92/8bfb917c-3d0d-49b9-8073-5d7e01c1b894.MOV) | Goulart / CC BY-SA 4.0 |
| 哑铃肩上推举 | `builtin.dumbbell-shoulder-press` | Shoulder Press, Dumbbells | [wger.video.12](https://wger.de/media/exercise-video/567/64f33c19-1d96-4b7c-af17-6c6a4941c614.MOV) | Goulart / CC BY-SA 4.0 |
| 曲杆仰卧臂屈伸 | `builtin.ez-skullcrusher` | Skullcrusher SZ-bar | [wger.video.63](https://wger.de/media/exercise-video/246/2a194d11-ff5d-4bdf-849e-1c441cf7b0b1.MOV) | Goulart / CC BY-SA 4.0 |
| 面拉 | `builtin.face-pull` | Facepull | [wger.video.79](https://wger.de/media/exercise-video/222/eea93fcc-6a3c-4783-8f70-0234c791a001.MOV) | Goulart / CC BY-SA 4.0 |
| 上斜哑铃卧推 | `builtin.incline-dumbbell-press` | Incline Bench Press - Dumbbell | [wger.video.24](https://wger.de/media/exercise-video/537/b9c937e9-daeb-42a9-be8e-7a77e368478c.MOV) | Goulart / CC BY-SA 4.0 |
| 哑铃侧平举 | `builtin.lateral-raise` | Lateral Raises | [wger.video.6](https://wger.de/media/exercise-video/348/de69928a-8a35-4096-821c-1f46de5e0e03.MOV) | Goulart / CC BY-SA 4.0 |
| 俯卧腿弯举 | `builtin.lying-leg-curl` | Leg Curls (laying) | [wger.video.35](https://wger.de/media/exercise-video/365/becaf013-5044-40d0-bae9-7ed60c973737.MOV) | Goulart / CC BY-SA 4.0 |
| 哑铃俯身臂屈伸 | `builtin.triceps-kickback` | Tricep Dumbbell Kickback | [wger.video.76](https://wger.de/media/exercise-video/655/2d88a05b-bde3-4026-bfbf-524c11068dc5.MOV) | Goulart / CC BY-SA 4.0 |

## 验证边界

构建前已核对 API 许可和文件对应关系、精确大小、摘要及多个时间点的动作画面。图片/GIF帧数和视频封装检查不等于真机播放验证；CI 中的 ExerciseMediaTests 进一步检查包内文件、GIF可解码及 AVAsset 视频轨道和可播放标志。实际测试是否通过以对应 Actions 作业为准，不把测试源码存在当成执行通过。
