import SwiftUI
import AVFoundation
import UIKit

struct DesktopPairingScanner: View {
    let onCode: (String) -> Void
    var prefix = "wiselife-sync://pair/"
    @Environment(\.dismiss) private var dismiss
    @State private var allowed = false
    @State private var checked = false
    var body: some View {
        NavigationStack {
            Group {
                if allowed { DesktopCameraPreview(onCode: onCode, prefix: prefix).overlay(alignment: .bottom) { Text("对准 Mac 上的 WiseLife 配对二维码").padding().background(.regularMaterial).clipShape(Capsule()).padding() } }
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
    let prefix: String
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(onCode: onCode, prefix: prefix) }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) { }
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "WiseLife.Pairing.Camera")
        private let onCode: (String) -> Void
        private let prefix: String
        private var layer: AVCaptureVideoPreviewLayer?
        private var delivered = false
        init(onCode: @escaping (String) -> Void, prefix: String) { self.onCode = onCode; self.prefix = prefix; super.init(nibName: nil, bundle: nil) }
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
            guard !delivered, let value = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first(where: { $0.hasPrefix(prefix) }) else { return }
            delivered = true; stop(); onCode(value)
        }
    }
}
