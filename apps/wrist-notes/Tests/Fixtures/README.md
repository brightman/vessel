# 合成音频 fixture

`sdk-opus-16k-mono.bin` 是由原 SDK 使用的 YbridOpus 0.8.0 编码器生成的一秒 440 Hz 合成音，不含用户录音。16 kHz 单声道，50 个 20 ms 包，每包用 `opus_packet_pad` 补足 80 字节。

用于验证新版源码解码器可读取旧 SDK 的定长帧，并保留非静音内容；不代表真实 EurekaRing 的录音、文件头或 BLE 已通过验证。
