import SwiftUI
import AVFoundation

struct DesktopSyncSettingsView: View {
    @EnvironmentObject private var sync: PhoneDesktopSyncModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var scanning = false
    @State private var confirmUnpair = false
    @State private var confirmLocalRemoval = false
    var body: some View {
        DaybookSheetLayout(title: "Mac 桌面同步", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: "desktopcomputer").font(.system(size: 32)).foregroundStyle(DaybookStyle.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sync.peerName ?? "让记录，在 Mac 上继续").font(.system(size: 18, weight: .semibold))
                        Text(sync.peerName == nil ? "同步转写，在 Mac 上整理总结。" : "仅在配对设备之间加密传输文字。")
                            .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
                    }
                }.padding(.vertical, 10)
                if sync.peerName != nil {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("打开 App 时自动同步", isOn: $sync.automatic)
                        if let date = sync.lastSynced { LabeledContent("上次同步", value: date.formatted(date: .abbreviated, time: .shortened)) }
                        LabeledContent("待同步变化", value: "\(sync.pendingCount) 项")
                        LabeledContent("已回传总结", value: "\(sync.summaries.count) 条")
                        Button { sync.syncNow() } label: {
                            HStack { if sync.isSyncing { ProgressView().controlSize(.small) }; Text(sync.isSyncing ? "正在同步…" : "立即同步") }
                        }.buttonStyle(DaybookPrimaryButtonStyle(wide: true)).disabled(sync.isSyncing)
                    }.font(.system(size: 13)).padding(18).background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 18))
                    Text("保持 Mac 上的 WiseLife 运行。Mac 生成总结后，再次同步即可在录音详情查看。手机删除的录音会在下次同步时从 Mac 移除。")
                        .font(.system(size: 12)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
                    Button("解除配对并清除 Mac 副本", role: .destructive) { confirmUnpair = true }.disabled(sync.isSyncing)
                    Button("Mac 不在身边，仅移除本机配对") { confirmLocalRemoval = true }.font(.caption).disabled(sync.isSyncing)
                } else {
                    Text("1. 在 Mac 打开 WiseLife → 同步与配对。\n2. 手机与 Mac 连接同一网络。\n3. 扫描配对码，或粘贴 Mac 复制的配对链接。")
                        .font(.system(size: 13)).lineSpacing(8).foregroundStyle(DaybookStyle.bodyText)
                    Button { scanning = true } label: { Label("扫描 Mac 配对码", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity) }
                        .buttonStyle(DaybookPrimaryButtonStyle(wide: true)).disabled(sync.isSyncing)
                    TextField("粘贴 WiseLife 配对链接", text: $code, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(size: 12))
                        .lineLimit(2...4).padding(14).background(DaybookStyle.field, in: RoundedRectangle(cornerRadius: 12))
                        .privacySensitive()
                    Button(sync.isSyncing ? "正在配对…" : "配对并同步录音文字") { sync.pair(code) }
                        .buttonStyle(DaybookSecondaryButtonStyle()).disabled(code.isEmpty || sync.isSyncing)
                    Text("配对后同步这台手机的录音标题、转写、时间与匿名说话人标记。音频、联系人、位置、健康数据与声纹不发送。默认使用 Mac 本机模型；选择自定义 AI 时，在 Mac 上确认本次发送的文字。")
                        .font(.system(size: 12)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
                }
                if let message = sync.message { Text(message).font(.system(size: 12)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary) }
                Button("重新读取配对状态") { sync.retryLoad() }.font(.caption)
            }
        }
        .sheet(isPresented: $scanning) {
            DesktopPairingScanner { value in code = value; scanning = false }
        }
        .confirmationDialog("解除配对？", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("清除 Mac 副本并解除配对", role: .destructive) { Task { _ = await sync.unpair() } }
        } message: { Text("需要连接 Mac。手机原始录音和转写保留，Mac 上这台手机的文字与总结将被清除。") }
        .confirmationDialog("仅移除本机配对？", isPresented: $confirmLocalRemoval, titleVisibility: .visible) {
            Button("仅移除本机配对", role: .destructive) { Task { _ = await sync.unpair(removeLocalOnly: true) } }
        } message: { Text("此操作无法清除离线 Mac 的副本。请稍后在原 Mac 的“同步与配对”中移除手机。") }
    }
}

struct DesktopSummaryPanel: View {
    let recordID: String
    @EnvironmentObject private var sync: PhoneDesktopSyncModel
    @State private var expanded = false
    var body: some View {
        if let summary = sync.summaries[recordID] {
            VStack(alignment: .leading, spacing: 12) {
                Label("Mac 模型总结", systemImage: "desktopcomputer").font(.system(size: 14, weight: .semibold))
                Text(summary.markdown).font(.system(size: 13)).lineSpacing(6).textSelection(.enabled)
                Text("\(summary.model) · \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened))\nAI 生成，请结合原文确认。")
                    .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                if let location = summary.processingLocation { Text(location + (summary.providerHost.map { " · " + $0 } ?? "")).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary) }
                DisclosureGroup("查看原文依据", isExpanded: $expanded) {
                    ForEach(summary.references) { reference in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("[\(reference.id)] " + (reference.start.map(Self.timestamp) ?? "原文摘录")).font(.caption).foregroundStyle(DaybookStyle.accent)
                            Text(reference.text).font(.system(size: 12)).textSelection(.enabled)
                        }.padding(.vertical, 6)
                    }
                }.font(.caption)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(DaybookStyle.blueSoft, in: RoundedRectangle(cornerRadius: 16))
        }
    }
    private static func timestamp(_ time: Double) -> String { String(format: "%02d:%02d", Int(time) / 60, Int(time) % 60) }
}

private struct DesktopPairingScanner: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var allowed = false
    @State private var checked = false
    var body: some View {
        NavigationStack {
            Group {
                if allowed { DesktopCameraPreview(onCode: onCode).overlay(alignment: .bottom) { Text("对准 Mac 上的 WiseLife 配对二维码").padding().background(.regularMaterial).clipShape(Capsule()).padding() } }
                else { ContentUnavailableView(checked ? "请允许使用相机，或返回粘贴配对链接" : "正在准备相机", systemImage: "qrcode.viewfinder") }
            }.navigationTitle("扫描 Mac 配对码")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }.task {
            allowed = await AVCaptureDevice.requestAccess(for: .video); checked = true
        }
    }
}
private struct DesktopCameraPreview: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(onCode: onCode) }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) { }
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "WiseLife.Pairing.Camera")
        private let onCode: (String) -> Void
        private var layer: AVCaptureVideoPreviewLayer?
        private var delivered = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidLoad() {
            super.viewDidLoad(); view.backgroundColor = .black
            let layer = AVCaptureVideoPreviewLayer(session: session); layer.videoGravity = .resizeAspectFill; view.layer.addSublayer(layer); self.layer = layer
            queue.async { [self] in
                guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
                session.addInput(input)
                let output = AVCaptureMetadataOutput(); guard session.canAddOutput(output) else { return }
                session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
                session.startRunning()
            }
        }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); layer?.frame = view.bounds }
        func stop() { queue.async { [self] in session.stopRunning() } }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !delivered, let value = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first(where: { $0.hasPrefix("wiselife-sync://pair/") }) else { return }
            delivered = true; stop(); onCode(value)
        }
    }
}
