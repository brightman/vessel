# 地点与采集设备：原生实现

日期：2026-10-20。对应原型：`prototype/places-design.md`。

## 已接通的功能

- 数据来源 → 地点：默认关闭；开启后尝试获取录音开始位置，并读取选中照片的原始位置。暂停立即取消本机未完成的定位，已保存地点保留。
- iPhone 与 Watch：录音先启动，定位异步进行；最多等待 20 秒，不等待定位再保存录音。拒绝、超时、过期/无效坐标都不会阻止音频保存。短闪念可能来不及获得地点。
- Watch 偏好通过 WCSession application context 同步，离线时使用最后收到的开关，重新连接后更新。Watch 自己检查定位权限。已采集的地点进入 pending metadata、传输 metadata 和 iPhone inbox；不改动音频接收时同步移动临时文件和保存后 ACK 的顺序。
- iPhone 草稿与 Watch 未完成音频的 sidecar 保存已获取的位置；恢复/重试保留地点。退出时未能写入的元数据不影响原始音频保留。
- 图片在压缩前解析 EXIF/TIFF/GPS。优先保留原始拍摄时间、坐标、可用精度和相机型号。PhotosPicker 使用当前编码；只有已经具备照片权限时才补读选中 PHAsset 的创建时间和位置，不额外索取全相册权限。
- 相机打开期间暂存短期定位样本，依据照片的快门时间选取附近样本；不使用较晚点击“使用照片”时的位置。后台、关闭相机、取消、暂停均停止采集。样本不形成持久轨迹。
- 一批跨日照片按拍摄日拆成记录，在同一 SQLite 事务中提交。每张照片保存自己的原始元数据，另存导入时间；保存后跳到导入记录对应的拍摄日。
- 缺少拍摄设备的相册图片显示“设备未知”；导入方式另列，不推断为导入手机拍摄。无拍摄时间的照片按导入日保存，但其坐标不会被投射成“当天到访”的地点证据。
- 首页节奏第四行展示地点点位，整行和下方地点汇总可进入当日列表；地点详情展示来源、时间、可用精度、设备，并可打开关联记录。录音/照片的列表和详情显示采集硬件。
- **无地点时省略整行**。不显示“未获取地点”。
- EurekaRing 沿用既有录音来源信息，不开启 SDK 编译开关，不附加手机当前位置。

## 本地存储与 AI

数据库升级到 `user_version = 3`，在既有事务中增加：

- `photo_moments.imported_at REAL`；
- `photo_attachments.capture BLOB`：可选的 Codable 拍摄时间、设备、导入方式、地点、时区信息；
- 录音地点使用现有 `voice_notes.payload` 的可选字段，避免重写既有表结构。

经纬度是结构化数值字段，不以向量索引作为原始数据存储。地点时间轴从持久化的媒体元数据投射，删除媒体后其地点同时消失。旧数据可继续解码，原有“保存时的地点”快照保留原描述。

地点作为独立 `.location` 证据进入现有检索链路，受 AI 偏好的地点授权约束；不会将经纬度拼到录音转写或照片 OCR 中。AI 开启地点来源也不会自动获得关联媒体的文本。原始照片文字可能自己含地址，这是用户的内容，不做自动删改。

## 已知边界

- 地点以坐标表示，**未调用地址反查/地图服务**。不推断场所名、路线、到访持续时间。
- EXIF 没有时区时以本机时区解释，详情明确标注。PhotosPicker/系统可能移除位置元数据；没有原始位置就不补写今天的手机位置。
- 暂停需等 Watch 收到设置同步才对离线手表生效。
- 构建/单元测试不证明 GPS、真机快门元数据或配对 Watch 传输端到端行为。
- UI 工具拒绝访问 Simulator：`Computer Use was not approved to use Simulator`，本次没有原生截图或点击验收。未修改用户已有模拟器数据；为本任务创建的独立空白 QA 模拟器已关机并清理。

## 验证

已完成：

- `sh apps/wrist-notes/scripts/test_local.sh`：通过，退出码 0。包含录音草稿、Watch 状态、手势、SQLite 迁移/事务、照片、语音身份、转写资源、AI 对话/历史/权限、提醒、每日洞察、全文检索、SQLite Vector 和全部新增地点测试。
- iOS Simulator Debug 构建：通过，包含内嵌 Watch App；未启用 Ring SDK。
- 范围内 `git diff --check`：通过。
- `generic/platform=iOS` Debug 无签名构建：通过，包含实体 Watch 的文件传输分支。此结果不代表真机联调或发布。
- 构建警告仅有已有的 Watch AccentColor 缺失、AppIntents 元数据跳过、ChatGPT 授权窗口旧初始化 API；没有编译错误。

测试入口：

```sh
sh apps/wrist-notes/scripts/test_local.sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
# 将 destination 改为 generic/platform=iOS 可验证真机架构（不签名、不安装）。
```

新增 `scripts/test_places.sh` 覆盖：坐标校验、传输编码、旧记录解码、SQLite 重开/删除/v2 迁移、Watch pending 和 iPhone 草稿、跨日导入、拒绝/授权/暂停/取消/过期定位、相机时间匹配、真实 JPEG 元数据读取、缺失元数据和 AI 来源隔离。跨日导入回归先观察到失败，再完成修复。

## 真机验收步骤

1. 设置开启地点，授予 iPhone 与 Watch 定位。Watch 连到 iPhone 后分别录制一段较长录音、一个短闪念；检查音频、硬件来源、可用地点与开始时间。短闪念无定位也应正常保存。
2. 暂停地点并等待 Watch 连接同步，重复录音；新记录没有地点行，旧记录地点仍存在。再验证系统拒绝定位的情况。
3. 导入有 GPS 的历史照片、不同日期的一批照片、没有 GPS/相机型号的截图。检查原始日期、导入日期、来源、跨日列表和缺失地点行。
4. 拍照后停留在确认页再保存；检查使用快门附近的位置，而非确认位置。后台/取消后不继续定位。
5. 重启 App，确认记录、地点和开关恢复；删除测试媒体后确认关联地点消失。只允许 AI 使用录音而不允许地点，确认发送预览不包含自动采集的坐标。
