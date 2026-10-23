# AI 长录音标题与完整时长

日期：2026-10-22

## 已实现

- 长录音完成转写后，根据「设置 → AI 模型」的选择生成内容标题，显示为 `长录音·内容标题`，不重复开始时间。支持已有 Apple 本地模型、自定义 OpenAI/Anthropic 兼容服务及已配置可用的 ChatGPT 路径；本轮不改变 ChatGPT 接入资格开关。
- Apple 本地模型自动处理。外部 AI 仅在已保存「下次不再提示」时自动处理；未授权时，在语音详情或笔记编辑器点「AI 生成标题」，预览文字并确认发送。
- 标题输入最多取开头、中间、结尾各 450 字符；不足 1350 字符使用全部转写。确认框展示实际摘录，不发送原始音频。共享免提示文案、设置说明及原型隐私说明均包含自动标题用途。
- 已转写但仍缺模型标题的旧长录音、已有临时摘句标题也会排队；手动命名和已有有效 AI 标题不被自动覆盖。显式点击生成可替换当前标题。
- 自动任务串行、同一输入在当前配置和授权下去重。模型失败时可保留转写摘句作为临时标题；主动生成失败保留原标题并显示错误，可手动重试。配置或授权变化、App 重新启动后可重新尝试未完成的标题。
- 转写、标题或模型配置变化会丢弃过期结果；恢复外部 AI 发送前确认后，未获单次确认的自动请求不再发布结果。过期确认不会保存免提示选择，切回本地模型也拒绝旧的远程确认。
- 时长使用完整三段格式：`0小时3分5秒`、`1小时2分3秒`，保留零值，超过 24 小时不回绕。英文、日文使用对应单位。
- 格式覆盖 iPhone 列表、详情、播放器、录音、声音登记、Watch 计时与列表，以及锁屏实时活动和灵动岛。实时活动采用系统 `Text(.currentDate, format:)` 与 `DiscreteFormatStyle` 更新，不增加每秒 ActivityKit 推送。
- 说话人逐字稿的定位时间戳继续使用 `mm:ss` / `h:mm:ss`，便于定位音频。HTML 原型同步时长及授权文案；本轮未新增原型标题生成交互流程。

## 验证结果

以下测试使用本机真实状态/存储逻辑，模型调用使用测试替身，未向外部 AI 发送数据。

| 验证 | 结果与范围 |
| --- | --- |
| `sh scripts/test_recording_titles.sh` | 通过：完整时长、中英日文、边界与非有限值、实时活动离散刷新边界、标题升级/手动保护、转写版本、SQLite 重开、编辑保存回归。 |
| `sh scripts/test_recording_title_coordinator.sh` | 通过：默认不发送、已授权自动生成、单次确认/免提示、手动覆盖与重试、重复请求抑制、临时标题升级、过期转写、手动编辑、撤回授权、切换模型。 |
| `AISettingsSmoke` | 通过：有界摘录、OpenAI 与 Anthropic 标题请求结构、过期请求不发送，以及原有 AI 配置测试。 |
| `sh scripts/test_conversations.sh` | 通过：共享授权及原有 Ask AI/对话回归。 |
| `ruby Tests/ProjectSourceMembershipSmoke.rb` | 通过：iPhone、Watch、录音组件及项目生成器源文件登记。 |
| 原型 `node --check` 与任务路径 `git diff --check` | 通过。 |
| 完整 generic iOS Simulator 构建 | `BUILD SUCCEEDED`，包含 iPhone、Watch、录音组件；仅有既有 AppIntents 元数据提取 warning。 |

构建命令（仓库根目录）：

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/wiselife-quick-recording-build \
  CODE_SIGNING_ALLOWED=NO build
```

日志：

- `/private/tmp/wiselife-ai-titles-duration-final-build.log`
- `/private/tmp/wiselife-ai-titles-duration-final-tests.log`
- `/private/tmp/wiselife-title-coordinator-final.log`
- `/private/tmp/wiselife-ai-titles-conversations.log`

## 评审与修复

独立评审发现：首次手动确认并保存免提示时，生成失败会立即触发同一条记录的自动重复请求。已添加失败回归并观察其失败，再将授权观察器的去重缓存失效改为同步处理，并让手动请求占用同输入的自动尝试记录。修复后的测试确认仅调用一次，主动重试仍然可用。

失败证据：`/private/tmp/wiselife-title-manual-duplicate-red.log`。最终独立复查通过：原始夹具的调用次数由 2 降为 1，协调器回归和实时活动格式边界通过，未发现新的明确问题。实时活动的真机布局与刷新不在本次复查范围内。

## 未实测范围与真机验收

没有安装到用户设备，没有调用真实本地/外部模型，也没有执行原生 UI 自动化或浏览器视觉验收。测试与编译不能证明模型可用性、生成质量或锁屏/灵动岛在熄屏时的刷新与布局。

建议在真机检查：

1. 使用本地模型完成长录音转写，检查标题；模型不可用时检查临时摘句和重试提示。
2. 选择外部 AI，在需要确认时检查预览、取消不保存、确认仅发送一次；勾选免提示后新长录音自动生成标题。
3. 在设置恢复发送前确认，检查后续自动发送停止；手动命名不被覆盖。
4. 检查短录音、超过一小时录音在 iPhone、Watch、锁屏实时活动、灵动岛上的三段时长；确认停止录音后实时活动关闭。

代码保留在本地工作区，未提交或推送。
