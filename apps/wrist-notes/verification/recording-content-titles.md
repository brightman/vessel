# 录音内容标题：原生实现与验证

日期：2026-10-21。需求：iPhone 首页／我的记录的长录音标题使用“长录音·内容标题”；开始时间仅在时间轴／元数据中展示。此前只有 HTML 原型实现，本轮补齐原生代码。

2026-10-22 更新：标题已扩展为跟随所选 AI，并在免提示授权后支持外部 AI 自动生成。下文保留当日验证记录；当前实现与验证范围见 [AI 长录音标题与完整时长](ai-recording-titles-duration.md)。

## 已实现

- 首页和记录列表的共同 DayRecord 投影、语音详情、旧笔记列表、编辑器和总结确认标题均采用内容标题。
- 未生成时显示“长录音·待生成标题”。旧版本“长录音 · M月d日 HH:mm”的默认名称不会再作为 iPhone 标题显示。
- 有转写文本后自动排队生成；旧的已转写默认名称在启动／前台恢复时排队处理。一次处理一条，正在转写／区分说话人的记录先等待。
- 优先调用 Apple Foundation Models，检查模型和原文语言支持，采样长转写的开头／中间／结尾，限制输入输出长度。模型不可用或出错时，从本机转写中提取简短内容标题。不会自动调用远程模型。
- 标题来源与转写版本作为可选字段随 VoiceNote 原有 SQLite payload 保存；旧数据兼容，无新增数据库版本。
- 用户自定义标题保留；自动结果必须匹配当前转写版本和原始标题，编辑后还原内容、删除、重新转写、手动改名均不会被过期结果覆盖。
- 重新转写使旧自动标题失效；修改原有自定义标题不触发自动覆盖。
- 编辑器未改标题时保留后台新生成的标题；成功保存后更新编辑基线，连续保存及改回旧名称不会丢失修改。
- Watch 的录音默认元数据和传输协议保持兼容；本轮改动是 iPhone 的处理与显示。

## 验证

- `sh scripts/test_recording_titles.sh`：通过。标题格式、缺少文本、时间默认值、前缀去重、本地提取、模型包装清理、手动优先、编辑后还原版本、重新转写、旧 Codable 与真实 SQLite 重开，以及原笔记编辑回归。
- `sh scripts/test_speaker_contacts.sh`：联系人、说话人持久化和 owner 回归通过。
- `sh scripts/test_places.sh`：通过。采集元数据、定位生命周期、图片元数据和 DayRecord 投影回归。修正历史 v2 测试夹具：重建旧 schema 时同时移除后来新增的 v4 提醒附表。
- `ruby Tests/ProjectSourceMembershipSmoke.rb`：iPhone／Watch／录音组件与生成器文件登记通过。
- 完整 `xcodebuild` generic iOS Simulator 构建通过，含 iPhone、Watch 与录音组件。编辑器保存修复及总结确认标题更新后的最终增量构建也通过（exit 0，BUILD SUCCEEDED）。
- 独立审查已修复连续手动保存的基线问题，无未解决阻断项。

日志：`/private/tmp/wiselife-recording-titles-tests.log`、`/private/tmp/wiselife-title-contacts-tests.log`、`/private/tmp/wiselife-title-places-tests.log`、`/private/tmp/wiselife-native-titles-final-build.log`。

## 验证边界

测试验证了标题状态／持久化／失效策略；异步 NotesModel 队列和 SwiftUI 编辑器由代码审查及构建检查，未进行原生 UI 自动化。没有在真机验证 Apple 本地模型的可用性和生成质量，也未安装到用户手机。模型不可用的设备会使用转写摘句标题。

建议真机验收：录制并完成转写，确认列表与详情不出现重复时间；手动改名后重开；标题生成期间修改文本／删除记录；重新转写自动标题记录；关闭 Apple Intelligence 后确认仍可从转写生成简短标题。尚未提交或推送代码。
