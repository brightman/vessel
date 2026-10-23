# 设备间录音协议 v1（接入设计）

这是应用层协议草案，尚未接入 Wear Engine，也不代表已完成蓝牙传输。

## 录音清单

元数据以 UTF-8 JSON 发送；必须小于 Wear Engine 文档的 1KB 消息上限。

```json
{
  "version": 1,
  "id": "11111111-1111-4111-8111-111111111111",
  "kind": "thought",
  "capturedAtMilliseconds": 1700000000000,
  "durationSeconds": 12.5,
  "byteLength": 6500000,
  "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
```

以上摘要仅为格式示例，不能用于真实文件。`kind` 取 `long` 或 `thought`。UUID 使用小写；时间为 Unix 毫秒；时长为秒；SHA256 为文件原始字节的 64 位小写十六进制。

## 文件与重试

- 使用固定 3,000,000 字节分片，最后一片可短；文件与关联消息必须顺序发送。
- 文件名由本机可信的 UUID 与分片序号生成，不使用来自对端的任意路径。
- 对端清单建立传输身份；接收方只接受此身份的合法序号和预期字节数，持久化后合并，校验总长度和 SHA256。
- 重复分片内容一致时幂等处理，内容不一致时拒绝。重新开始同一录音传输不能修改清单。
- 未完成传输不得导入笔记。SDK 临时文件在回调返回前复制到 App 所有目录；原始 SDK 文件不删除。
- 接收方应限制单次传输及暂存总量并清理过期传输。当前 Receiver 限制完整文件不超过 1GiB；分片接收与断点续传仍未实现。

## 手机持久化确认

`HuaweiRecordingReceiver.receive` 接受已合并的完整本地文件与清单，校验可读性、大小、SHA256、时长及重复 ID 的一致性，写入笔记后返回：

```json
{
  "version": 1,
  "type": "stored",
  "id": "11111111-1111-4111-8111-111111111111",
  "byteLength": 6500000,
  "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
```

未来 SDK 适配层负责把返回值发给经过认证的同一手表应用。哈希用于传输完整性，不替代 SDK 的身份认证。未收到正确 `stored` 回执时手表保留音频，显示未上传。

## 已实现与未实现

已实现：JS 发送队列和分片计划、Swift 完整文件校验/入库/返回确认。

未实现：双方 Wear Engine SDK 连接、手表文件分片 I/O、iPhone 分片持久化与重组、发送确认消息、真实 GT 6 录音。因此不能宣称端到端传输成功。
