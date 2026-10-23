import SwiftUI
import CoreImage.CIFilterBuiltins

struct DesktopPairingView: View {
    @ObservedObject var model: DesktopModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var revoking: DesktopDevice?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date.now
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { VStack(alignment: .leading, spacing: 7) { Text("让 iPhone 与 Mac 相遇").font(.system(size: 25, weight: .semibold)); Text("同一网络，配对一次，文字在设备之间同步。").font(.system(size: 12)).foregroundStyle(DesktopStyle.secondary) }; Spacer(); Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }.buttonStyle(.plain) }
            HStack(alignment: .center, spacing: 28) {
                VStack(spacing: 10) {
                    if let code = model.pairing, code.expiresAt > now, let image = qr(code.url) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 184, height: 184).padding(14).background(.white, in: RoundedRectangle(cornerRadius: 18)).privacySensitive()
                        Text("配对码 \(max(0, Int(code.expiresAt.timeIntervalSince(now)))) 秒后过期").font(.system(size: 10)).foregroundStyle(DesktopStyle.secondary).monospacedDigit()
                    } else {
                        VStack(spacing: 12) { Image(systemName: "qrcode").font(.system(size: 60, weight: .ultraLight)); Text("生成新的配对码").font(.system(size: 12)) }.frame(width: 212, height: 212).background(DesktopStyle.field, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("在 iPhone 上").font(.system(size: 15, weight: .semibold))
                    Text("打开 WiseLife → 设置 → Mac 桌面同步，扫描左侧二维码。")
                        .font(.system(size: 12)).lineSpacing(7).foregroundStyle(DesktopStyle.bodyText)
                    if model.addresses.count > 1 {
                        Picker("本机网络", selection: $model.selectedAddress) { ForEach(model.addresses, id: \.self) { Text($0).tag($0) } }.font(.system(size: 11)).onChange(of: model.selectedAddress) { _, _ in model.renewPairing() }
                    }
                    HStack {
                        Button(copied ? "已复制" : "复制配对链接") {
                            if let code = model.pairing { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code.url, forType: .string); copied = true }
                        }.buttonStyle(DesktopPrimaryButton()).disabled(model.pairing == nil || (model.pairing?.expiresAt ?? .distantPast) <= now)
                        Button("刷新") { model.renewPairing(); copied = false }.buttonStyle(DesktopQuietButton())
                    }
                    Label("仅接收文字与匿名说话人标记", systemImage: "lock.shield").font(.system(size: 10)).foregroundStyle(DesktopStyle.secondary)
                }
            }.desktopCard()
            Text(model.serverStatus).font(.system(size: 11)).foregroundStyle(DesktopStyle.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Text("已配对设备").font(.system(size: 14, weight: .semibold))
                if model.devices.isEmpty { Text("还没有配对的 iPhone。").font(.system(size: 12)).foregroundStyle(DesktopStyle.secondary) }
                ForEach(model.devices) { device in
                    HStack(spacing: 10) { Image(systemName: "iphone"); Text(device.name); Spacer(); Text("\(device.recordCount) 条录音").foregroundStyle(DesktopStyle.secondary); Button("移除", role: .destructive) { revoking = device } }.font(.system(size: 12)).padding(.vertical, 5)
                }
            }.desktopCard()
            Text("移除设备会清除这台 Mac 上来自它的转写与总结。关闭窗口后 WiseLife 仍保持同步；退出 App 或 Mac 休眠时暂停。")
                .font(.system(size: 11)).lineSpacing(6).foregroundStyle(DesktopStyle.secondary)
        }.padding(30).frame(width: 690).background(DesktopStyle.paper).foregroundStyle(DesktopStyle.ink)
            .onReceive(tick) { now = $0 }
            .onAppear { model.renewPairing() }
            .confirmationDialog("移除设备并清除其文字副本？", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
                Button("移除并清除", role: .destructive) { if let device = revoking { model.revoke(device) }; revoking = nil }
            }
    }
    private func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output.transformed(by: .init(scaleX: 5, y: 5)), from: output.extent.applying(.init(scaleX: 5, y: 5))) else { return nil }
        return NSImage(cgImage: image, size: .init(width: image.width, height: image.height))
    }
}

struct DesktopModelSettingsView: View {
    @ObservedObject var model: DesktopModel
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = DesktopModelConfiguration()
    @State private var key = ""
    @State private var models: [String] = []
    @State private var testing = false
    @State private var status: String?
    @State private var failed = false
    @State private var job: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { VStack(alignment: .leading, spacing: 7) { Text("选择模型，整理你的记录").font(.system(size: 25, weight: .semibold)); Text("默认使用 Mac 本机模型，也可连接自己的 AI 服务。").font(.system(size: 12)).foregroundStyle(DesktopStyle.secondary) }; Spacer(); Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }.buttonStyle(.plain) }
            Picker("处理方式", selection: $configuration.mode) {
                Text("Mac 本机模型").tag(DesktopModelConfiguration.Mode.local)
                Text("自定义 AI 服务").tag(DesktopModelConfiguration.Mode.custom)
            }.pickerStyle(.segmented).onChange(of: configuration.mode) { _, mode in
                status = nil; models = []
                if mode == .local { configuration.baseURL = "http://127.0.0.1:11434/v1"; configuration.model = "" }
                else { configuration.autoSummarize = false }
                key = (try? model.apiKey(configuration: configuration)) ?? ""
            }
            if !configuration.isLocal {
                HStack {
                    Text("OpenAI 兼容 HTTPS 接口").font(.system(size: 11)).foregroundStyle(DesktopStyle.secondary)
                    Spacer()
                    Button("填入 DeepSeek 配置") { configuration.baseURL = "https://api.deepseek.com"; configuration.model = "deepseek-flash"; models = []; status = nil }.buttonStyle(DesktopQuietButton())
                }
            }
            VStack(alignment: .leading, spacing: 18) {
                field("服务地址 · Base URL") { TextField(configuration.isLocal ? "http://127.0.0.1:11434/v1" : "https://api.deepseek.com", text: $configuration.baseURL) }
                field("模型名称") {
                    HStack { TextField("填写模型服务中的名称", text: $configuration.model)
                        if !models.isEmpty { Menu("选择模型") { ForEach(models, id: \.self) { name in Button(name) { configuration.model = name } } } }
                    }
                }
                field("API Key · 如服务需要") { SecureField("可选，保存到系统钥匙串", text: $key).privacySensitive() }
                HStack {
                    Button("读取模型列表") { run {
                        models = try await DesktopModelService().models(configuration: configuration, key: key)
                        if configuration.model.isEmpty { configuration.model = models.first ?? "" }
                        status = models.isEmpty ? "服务未返回模型，可手动填写。" : "已读取 \(models.count) 个模型。"
                    } }.buttonStyle(DesktopQuietButton())
                    Button("测试连接") { run { try await DesktopModelService().test(configuration: configuration, key: key); status = "模型连接成功。" } }.buttonStyle(DesktopQuietButton())
                    if testing { ProgressView().controlSize(.small) }
                }.disabled(testing)
                if let status { Text(status).font(.system(size: 11)).foregroundStyle(failed ? DesktopStyle.red : DesktopStyle.green) }
            }.desktopCard()
            Toggle("转写同步完成后，自动生成本机总结", isOn: $configuration.autoSummarize).font(.system(size: 13)).disabled(!configuration.isLocal)
            Text(configuration.isLocal ? "支持本机 OpenAI 兼容接口，例如 Ollama 或 llama.cpp。Base URL 只接受 localhost、127.0.0.1 或 ::1；不包含 /chat/completions。模型服务需先安装并启动。" : "自定义 AI 会接收你确认发送的录音转写文字。每次生成前展示服务地址与模型，由你确认；自动生成仅用于本机模型。API Key 保存在系统钥匙串。")
                .font(.system(size: 11)).lineSpacing(6).foregroundStyle(DesktopStyle.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }.buttonStyle(DesktopQuietButton()); Button("保存配置") {
                do { try model.save(configuration: configuration, key: key); dismiss() }
                catch { status = error.localizedDescription; failed = true }
            }.buttonStyle(DesktopPrimaryButton()).disabled(testing) }
        }.padding(30).frame(width: 690).background(DesktopStyle.paper).foregroundStyle(DesktopStyle.ink)
            .onAppear { configuration = model.configuration; do { key = try model.apiKey() } catch { status = error.localizedDescription; failed = true } }
            .onChange(of: configuration.credentialAccount) { _, _ in key = (try? model.apiKey(configuration: configuration)) ?? ""; status = nil }
            .onDisappear { job?.cancel() }
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(DesktopStyle.secondary); content().textFieldStyle(.plain).font(.system(size: 13)).padding(12).background(DesktopStyle.field, in: RoundedRectangle(cornerRadius: 10)) }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        job?.cancel(); testing = true; status = nil; failed = false
        job = Task { defer { testing = false }; do { try await operation() } catch is CancellationError { } catch { status = error.localizedDescription; failed = true } }
    }
}
