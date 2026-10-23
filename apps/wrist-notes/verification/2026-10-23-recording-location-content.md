# 长录音 GPS 与内容分段更新：开发与验证

日期：2026-10-23。对应计划：[recording-location-content](../docs/superpowers/plans/2026-10-23-recording-location-content.md)。

后续实机进展：iPhone 已原位安装并验证真实数据重新分段；Watch 调试连接超时，尚待完成。详见 [真机安装与测试记录](2026-10-23-recording-location-content-device.md)。以下“验证边界”保留首次软件交付时的状态。

## 交付范围

### Watch 位置采集与传输

- 长录音开始、每 600 秒音频边界、停止时，分别发起一次有超时限制的定位。遵守现有地点开关与系统权限。
- 每条记录保留录音会话、音频偏移、请求时间、实际定位时间、经纬度、精度和设备来源。请求时间与实际定位时间独立，拒绝过期或未知时间的定位；后台定时器恢复后不会用当前坐标伪造错过的历史地点。
- GPS 获取与可选位置文件写入失败不会终止音频录制、封片或上传。音频仍按 10 分钟保存，定位记录独立持久化、重试和确认。
- iPhone 先提交 SQLite，再确认收到。支持重复、乱序、重启恢复、旧版设备能力协商及已删除录音的迟到消息。
- SQLite migration 11 增加 `recording_location_samples`，migration 12 增加 `recording_location_addresses`。地址解析结果独立缓存，不覆盖原始坐标和传输载荷；随录音删除级联清理。
- iPhone 前台串行解析地址，采用现有 Apple Maps resolver。离线时保留坐标，随后重试。地址解析可能使用 Apple 服务网络，无需新增自建服务。

### 内容分段与 AI 整理

- 策略版本：`asr-blank-180-chapters-1800-cap-2400-v2`。
- **至少 3 分钟无 ASR 文字**，且该范围已成功处理时，保留为低信息分隔段。界面显示“未识别到文字”，不把识别空白等同于无人声。
- 缺失或失败的处理范围不会被判为静音；原有 ASR/VAD 双成功、至少 10 分钟无人声的强分隔规则继续有效。
- 有内容区域约 30 分钟分章，自动片段最多 40 分钟，优先选择转写行之间的安全时间边界。
- AI 比较相邻章节主题，可以在时长限制内合并；不能跨过空白段、手工编辑边界、缺失覆盖或录音中断。非相邻的同主题内容不会直接合成一段连续音频。
- 标题与摘要使用片段时间及对应的采样地点。位置证据迟到或地址补全后，刷新文字整理缓存，不重新跑 ASR。稀疏定位不会被当作完整路线，提示词要求区分观察与推测。
- 保留原始音频、转写、手工拆分/合并/删除、撤销与旧录音引用。历史长录音通过分段版本变更重新生成派生片段，复用已完成的 ASR/VAD。

### 模型设置与确认

- 使用当前选择的本机模型、自定义 OpenAI/Anthropic 兼容模型或 ChatGPT；无隐式云端回退。
- 复用远程 AI 确认设置，预览包含转写和地点证据（地址、坐标、时间、精度、设备）。授权绑定当前录音数据与模型配置；新位置或转写发生变化后不会沿用过期授权。
- 在读取凭据、发送请求、保存结果的关键位置检查配置与数据是否仍然有效。ChatGPT 刷新令牌或加载模型列表期间数据发生变化时，会阻止过期请求。
- 内容详情入口为“整理主题与总结”；无可用 AI 或需要确认时，本地确定性分段仍可使用。

## 真实 6 小时 42 分录音验证

对既有审计数据库的**新副本**运行实际 Swift/SQLite 派生逻辑，未更改手机数据库，未重新转写，也未调用远程模型。

| 检查 | 结果 |
| --- | --- |
| 原始转写行数 | 69,706 → 69,706 |
| 遗漏转写行 | 0 |
| 同时归属多段的转写行 | 0 |
| 初步分段 | 26 段：18 段有文字、8 段未识别到文字 |
| ASR 处理版本 | 未改变 |
| 本次派生耗时 | 约 19.3 秒（Mac） |

这里的 26 段是 **AI 主题整理之前**的确定性结果，不能与之前调用 Doubao 的实验结果混为一谈。旧文件没有这次新增的逐片 GPS，无法补出历史轨迹。

第一次审计检出了 3 条因浮点时间到音频帧换算而重复归属的转写。已改为使用帧内侧的安全边界，添加失败后通过的回归用例，并在原始快照的新副本上重跑得到上述结果。

私有审计产物保存在 `/Users/karama/Documents/WiseLife-Reports/2026-10-23-native-chapters/`：

- `verification-v2.json`：最终通过的全部指标及 26 段时间范围。
- `native-chapters-v2.sqlite3`：最终验证副本。
- `native-chapter-audit.swift`：本次使用的 Swift 审计程序副本。

报告不包含录音全文、坐标或凭据。

## 软件验证

本次开发会话中完成的针对性检查均通过。分工测试的详细断言与 RED/GREEN 证据见 [GPS 实现报告](2026-10-23-recording-locations-implementation.md) 与 [内容分段实现报告](2026-10-23-content-chapters-implementation.md)。

| 检查 | 结果 |
| --- | --- |
| `test_recording_locations.sh` | PASS；调度、持久化、兼容、重放/确认、删除、位置失败不影响音频 |
| `test_recording_location_addresses.sh` | PASS；前台/权限、离线重试、取消、持久地址缓存 |
| `test_recording_transfer.sh` | PASS；现有音频传输与新位置消息共存 |
| `test_watch_recording_sessions.sh`、`test_watch_sync.sh`、`test_places.sh` | PASS；录音存储、同步、位置生命周期 |
| `test_content_segments.sh` | PASS；长录音分章、空白/失败区分、帧边界、原始行归属与手工修改 |
| `test_content_enrichment.sh` | PASS；主题合并限制、位置迟到、缓存、取消和过期写入 |
| `test_audio_relocation.sh` | PASS；媒体迁移与既有处理结果复用 |
| `test_streaming_recording.sh` | PASS；结束前解码/处理、最终尾片、重放与原始音频保留 |
| `test_configured_content_model.sh` | PASS；本机/OpenAI/Anthropic/ChatGPT 路由、主题返回校验、授权与过期结果；使用模拟传输 |
| `test_content_authorization.sh` | PASS；数据范围、地点/地址变化、删除、带地址时仍展示坐标 |
| `test_chatgpt_accounts.sh` | PASS；账户生命周期，刷新凭据/目录期间数据变化阻止请求 |
| `ruby apps/wrist-notes/Tests/ProjectSourceMembershipSmoke.rb` | PASS；iPhone、Watch、widget 源文件归属 |
| iPhone workspace Debug Simulator build | PASS，最终进程退出码 0；包含嵌入式 Watch 构建 |
| Watch Debug Simulator 独立构建 | PASS |

构建命令（均仅关闭签名，未跳过 App Icon）：

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/wiselife-location-content-build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apps/wrist-notes/WristNotes.xcodeproj -target WristNotesWatch -configuration Debug -sdk watchsimulator CODE_SIGNING_ALLOWED=NO SYMROOT=/private/tmp/wiselife-location-content-watch-build build
```

构建日志：`/private/tmp/wiselife-location-content-ios-final.log` 和 `/private/tmp/wiselife-location-content-watch-build.log`，均包含 `BUILD SUCCEEDED`。最终 iPhone 日志仅有未依赖 AppIntents 的 metadata extraction 提示，无构建错误。

最终独立代码审查接受本次软件实现，无剩余阻塞问题。审查发现的“预览有地址时遗漏坐标”和“ChatGPT 异步等待后未复查数据”两项均已修复并回归通过。审查时尚待完成的最终构建及真实数据重跑，已在本报告中补齐结果。审查原文：`/private/tmp/wiselife-location-content-final-review.md`。

## 验证边界

- 尚未安装到真机；Watch 息屏后的实际 GPS 调度、定位成功率、续航、多小时录音及配对设备传输仍需实测。采样失败时允许缺失地点，音频优先。
- 模型路由与授权使用模拟传输测试，本次未实际调用 Doubao/其他远程服务，也未验证本机模型生成质量。
- 极端转写若存在连续超过 40 分钟的重叠行、没有任何安全切点，自动时长上限的兜底可能切到转写行内；普通重叠/浮点边界有回归，当前真实录音全部行均只归属一段。
- 本次仅开发和验证；未提交或推送代码，未修改设备中的录音数据。
