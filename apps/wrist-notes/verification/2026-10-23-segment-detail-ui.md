# 内容片段详情与首页摘要修复

## 修复范围

- `ContentSegmentDetailView` 原先使用系统 `List` 分组详情，与已确认原型的底部详情页不一致。现在复用 `DaybookSheetLayout`、普通语音详情的播放器和“总结 / 全文”控件；全文连续排版，按需加载更多。片段编辑放在“管理片段”菜单，处理状态默认收起。
- `DaybookRecordRow` 原先用转写正文前 240 个字符作为卡片描述。现在音频卡片读取已保存的 `record.summary`；派生片段缺少摘要时明确显示“摘要尚未生成”。
- 带 `recordingSessionID` 的派生片段原先也被当成“完整录音”。现在只有没有 `contentProvenance` 的录音会使用完整录音标题和状态。

原型依据：`prototype/daybook.js` 的 `openRecord`；`prototype/daybook.css` 的 `.audio-player`、`.detail-tabs`、`.detail-content`。

## 已验证

- iOS Simulator workspace 构建成功：`WristNotes` scheme、Debug、`WISELIFE_CONTENT_LAB`。构建日志为 `/private/tmp/wiselife-segment-detail-style-build.log`，包含 `BUILD SUCCEEDED`。
- 已安装并启动在 **WiseLife Content Lab**，设备 ID `012F6CC3-6B1C-4D05-A9FC-2E729A8E30E5`，bundle ID `cloud.karama.wisenote`。未安装到真机。
- 安装后重新定位模拟器内音频路径。对比安装前备份，全部 **31 个片段**的 ID、标题、摘要、revision、classification 一致。
- 使用真实 `ContentSegmentSnapshot` → `ContentSegmentPresentation.timelineRecords` 读取链路：**31 个片段 → 19 条有效时间轴记录**，缓存转写行数 **69,706**。
- 19 条时间轴记录的摘要均非空（60–147 字符），逐条与 SQLite 保存值一致。
- 原始音频大小 **99,523,276 bytes**，SHA-256 保持 `05b4100fc316365e1127403b972b49671274f1db90c376c64e3abada6c830537`。
- 三个修改的 Swift 文件 `git diff --check` 通过。本次 UI 修复未重新调用 ASR 或 AI 生成摘要。

本机数据核对证据保存在 `/Users/karama/Documents/WiseLife-Reports/2026-10-23-simulator-content-v2/detail-ui-fix-verification.json`；该目录还保留安装前数据库备份和 `timeline-after-detail-ui-fix.json`。

## 验证限制

界面工具 `cua.getApp('Simulator')` 持续返回 `Sky Computer Use native pipe startup failed`。因此尚未完成新版详情页的截图、点击、播放和拖动验证；构建与数据核对不代表已完成视觉验收。

本次使用现有模拟器 v2 分段结果；不改变生产自动分段调度，也不重新生成每日回顾。
