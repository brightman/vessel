# 采集地点地址解析

## 目标与实现顺序

用户要求时间轴显示可读地址。使用 iOS 26 MapKit reverse geocoding，无自建服务器和 API Key；Apple 服务可能联网，发送的是待解析坐标，不发送录音、图片或文本。

- [x] 为 CaptureLocation 增加可选地址（文本、解析语言），兼容旧坐标。地址随录音 payload / 图片 capture 元数据保存在现有 SQLite 表中，不另建数据库或更改 schema。删除原记录同时删除地址；坐标始终保留。
- [x] 增加串行地址解析协调器，优先复用已保存的同坐标/语言地址；只在来源开启且 App 前台时为当前日期补齐。失败退避，切日/暂停/后台取消，迟到结果不落盘。不根据附近坐标猜测场所。
- [x] 接入 NotesModel / PhotoLibraryModel 的原子保存，更新时核对原坐标和记录是否仍存在，保留其他字段。地图返回的地址不代表到访某商户或在该点停留。
- [x] 时间轴、当天地点列表、语音/图片详情展示地址。无地址时显示“地点待解析”；详情保留原坐标与联网解析说明。没有坐标仍不显示地点行。AI 地址证据仍受独立地点权限控制，不混入录音转写/图片 OCR。
- [x] 用真实 SQLite 测试重启、旧数据、删除/迟到结果及失败回滚；用可控地理编码边界测试并发合并、缓存、取消/重试和语言。运行原有地点测试及 iOS 构建。

## 验证结果

- `sh apps/wrist-notes/scripts/test_addresses.sh`：通过，真实 SQLite 记录重启、坐标/文本保留、删除/迟到回写、图片回滚与旧数据解码；解析队列测试覆盖去重、缓存、取消、重试和语言。
- `sh apps/wrist-notes/scripts/test_places.sh`：通过，新增地址标题与独立 AI 地点权限测试。
- iOS Simulator / generic iOS Debug 构建通过（`CODE_SIGNING_ALLOWED=NO`）；没有安装或在用户 iPhone 上验收。拆分首页的内容/监听 modifier 链，解决新增监听导致的 SwiftUI type-check 超时，不改变页面结构。
- 同一生产 `AppleCaptureAddressResolver` 在 macOS 26.5.1 上调用真实 MapKit：公共北京测试坐标返回“中国北京市东城区东长安街天安门…”；不是用户坐标。另一美国公共地点在当前环境返回 `MKErrorDomain 4 / MKErrorGEOError -8`，诊断用旧 CLGeocoder 也返回 no-result，说明不能保证所有坐标都有地址。没有把诊断用的旧 API 加入产品。
- 未解析的地址不会覆盖已有地址或生成虚构场所名；失败后切换日期或回到前台可重试。初次解析可能联网，SQLite 缓存可离线显示。

日志：`/private/tmp/wiselife-address-tests.log`、`/private/tmp/wiselife-address-simulator-build.log`、`/private/tmp/wiselife-address-device-build.log`、`/private/tmp/wiselife-address-mapkit-china.log`。`sh apps/wrist-notes/scripts/test_local.sh` 完整回归已通过（退出码 0），日志 `/private/tmp/wiselife-address-regression.log`。`git diff --check -- apps/wrist-notes` 通过。真机 UI 与用户实际坐标尚未验收。
