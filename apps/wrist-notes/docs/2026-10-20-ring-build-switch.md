# Eureka Ring 编译与录音文件兼容

类型：技术说明 · 状态：current · 更新：2026-11-03 · 适用：WiseLife iPhone／Watch，当前 `codex/vessel` 工作区。

## 当前构建

`Config/BuildFeatures.json` 的 `eurekaRing` 已设为 `true`。Podfile 使用仓库内 `../../pods/br_flutter_plugin_ble` 的 Native 子模块，包含 BLE、适配层、Opus 及隐私／许可资源；不引用相邻 SDK 源码，不引入 Flutter 或 `br_app_services`。

集成测试从宿主展开的 SDK 额外链接 Opus 框架；不再创建第二个 Opus Pod 子目标，避免同一 XCFramework 的重复拷贝。生成 Pod 的最低 iOS 版本设为 15.0，兼容 Xcode 27；App 仍要求 iOS 26。

修改开关后执行 `pod install`，共享读取器同步更新依赖、`WISELIFE_EUREKA_RING` 和源码排除。关闭功能不删除已有录音；仅改 JSON 后直接 Build 不会更新现有工程。

## 两种原音的处理契约

| 来源 | 原音文件 | 处理层接入 | 来源标记 |
| --- | --- | --- | --- |
| Apple Watch | 每小时一个独立 M4A，最后一份可不足一小时 | 按录音组、序号及真实偏移形成连续音源，保留缺失文件产生的缺口 | `captureDevice: watch` |
| EurekaRing | 一条设备录音对应一个完整文件，超过一小时也不拆原音 | BLE 校验后流式转为 16 kHz 单声道 AAC/M4A，进入现有本机录音库与统一处理队列；不套用 Watch 小时分片描述符 | `captureDevice: ring` |

AI 窗口最多 300 秒核心区间及两侧各 2 秒上下文，仅引用原音帧范围。全文、说话人和主题片段的时间戳相对整条录音，不在小时边界归零；内容主题分段沿用现有规则，与物理音频是否分片无关。明确标记为 Ring 的单文件不会被遗留的小时组元数据合并成 Watch 分片。

Ring 任务保留稳定笔记 UUID 和同步回执，重传不重复导入。保存成功后清理 SDK／转换暂存副本，不删除硬件原音。

## 来源兼容与展示

新增可选 Codable 字段 `RecordingOrigin.captureDevice`，取值 `watch`／`ring`／`iPhone`／`unknown`，保留原设备名称、ID、文件名和时区字段。使用现有 JSON payload／SQLite 表，无新增 SQL 列或 schema 迁移。旧数据缺字段时从 `Watch`／`Apple Watch`、`Ring`／`EurekaRing` 名称识别，未知来源保持未知，不重写旧音频。

Watch 采集及手机 Watch 接收入口写入 watch，Ring 导入入口写入 ring，AI 音源快照保留字段。首页、完整录音和内容片段详情统一展示 Apple Watch／EurekaRing，原设备型号仍保存在元数据中。

## 本次验证

环境：2026-11-03，`codex/vessel` 分支，基线 `7ed237f` 加本次工作区修改；Xcode 27.1（27A9275），iOS 26.3 的 WiseNote Ring Tests 模拟器。代码尚未提交。

| 检查 | 实际结果 |
| --- | --- |
| `pod install` | 成功，仅使用仓库内 Native Pod；Bluetooth／Native／Opus 3.0.0 |
| `ruby Tests/BuildFeaturesSmoke.rb` | 3 项、91 断言通过；开关可逆、测试 Opus 链接及 Watch 配置验证 |
| `python3 scripts/verify_ble_pod.py` | 79 项完整性检查、3 个 XCFramework 和真机／模拟器架构通过 |
| `sh scripts/test_audio_processing.sh` | 来源向后兼容、明确来源跨 AI 快照保留；7323.5 秒 Ring 单文件与 Watch 三个小时文件的窗口边界一致、跨小时语句只归属一次；队列回滚／重试／恢复通过 |
| `sh scripts/test_hourly_recording.sh` | 实际写入 3601 秒 AAC：Watch 两份文件、Ring 一份完整文件；持久化、重开、来源、有界处理及独立删除通过；遗留小时组元数据不改变 Ring 单文件归属 |
| `xcodebuild ... -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | iPhone arm64、嵌入 Watch 与小组件编译通过；源码成员及 Watch 嵌入结构检查通过 |
| `xcodebuild ... -destination 'id=8AF9489C-FAD1-4AA2-A88A-E9591649A948' -only-testing:RingIntegrationTests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test` | 整个包 53 项、2 项资源 smoke 跳过、0 失败；其中 Ring 集成类 31 项全部通过，覆盖真实 Opus 转码、同步、断连、解绑、格式化、闪念、手机来源保存及处理队列路由 |

同时修复共用旧测试夹具与当前代码的接口差异：声音登记测试使用独立模拟 URL；持久化故障通过现有 SQLite 触发器注入；队列测试使用已有的三次自动重试预算。未修改对应生产策略。测试使用模拟硬件及合成音频，不向真实 Ring 发送命令。

**未验证：**真实 Ring 蓝牙配对、多小时 Opus 传输耗时、锁屏传输及硬件格式化；本地模型在真机的质量／内存／能耗；本次未做手机／手表签名安装或发布。

## 历史

2026-10-20 曾按用户要求关闭 Ring，当时缺少相邻源码适配层，开启状态未完成构建。2026-11-03 用户要求在当前分支恢复本仓库 Pod、开启编译及兼容两类录音。本节以前的默认关闭／外部源码恢复步骤不再适用于当前配置。历史设备记录见 [原生接入验证](../verification/eureka-ring-native.md)。
