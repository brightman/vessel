import SwiftUI

struct DaybookHardwareView: View {
    let watch: PhoneWatchStatus
    let openWatch: () -> Void
#if WISELIFE_EUREKA_RING
    let openRing: () -> Void
#endif
    let onClose: () -> Void
#if WISELIFE_EUREKA_RING
    @EnvironmentObject private var ring: EurekaRingModel
#endif

    var body: some View {
        DaybookSheetLayout(title: "连接硬件", onClose: onClose) {
            VStack(alignment: .leading, spacing: 0) {
                Text("让声音成为记录").font(.system(size: 24, weight: .semibold)).padding(.top, 14).padding(.bottom, 10)
#if WISELIFE_EUREKA_RING
                Text("Apple Watch 和 EurekaRing 可以同时连接，录音会汇集到你的本机记录中。")
                    .font(.system(size: 12)).lineSpacing(7).foregroundStyle(DaybookStyle.secondary).padding(.bottom, 24)
#else
                Text("Apple Watch 录音会汇集到你的本机记录中。")
                    .font(.system(size: 12)).lineSpacing(7).foregroundStyle(DaybookStyle.secondary).padding(.bottom, 24)
#endif
                row("Apple Watch", subtitle: "轻点录音，按住记录闪念", icon: "Watch", connected: watch.hasPairedWatch, status: watch.title, action: openWatch)
#if WISELIFE_EUREKA_RING
                row("EurekaRing", subtitle: "录音、闪念与蓝牙同步", icon: "Ring", connected: ring.isConnected, action: openRing)
#endif
                DaybookQuietInfo(text: "设备状态变化不会删除本机历史记录。录音和转写在本机完成。这里不需要登录账号。")
                    .padding(.top, 24)
            }
        }
    }
    private func row(_ title: String, subtitle: String, icon: String, connected: Bool, status: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                DaybookIcon(icon, size: 30).foregroundStyle(DaybookStyle.accent).frame(width: 54, height: 64)
                    .background(DaybookStyle.blueSoft, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                    HStack(spacing: 5) {
                        Circle().fill(connected ? DaybookStyle.green : DaybookStyle.secondary).frame(width: 4, height: 4)
                        Text(status ?? (connected ? "已连接" : "未连接")).font(.system(size: 10))
                    }.foregroundStyle(connected ? DaybookStyle.green : DaybookStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                DaybookIcon("ChevronRight", size: 16).foregroundStyle(DaybookStyle.secondary)
            }.padding(.vertical, 18).overlay(alignment: .bottom) { DaybookStyle.line.frame(height: 1) }
        }
    }
}

#if WISELIFE_EUREKA_RING
struct EurekaRingDetailView: View {
    let onBack: () -> Void
    let onClose: () -> Void
    var phoneIsRecording = false
    @EnvironmentObject private var ring: EurekaRingModel
    @State private var confirmUnbind = false
    @State private var confirmFormat = false

    var body: some View {
        DaybookSheetLayout(title: "硬件状态", onClose: onClose) {
            VStack(alignment: .leading, spacing: 20) {
                Button(action: onBack) { HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("全部硬件") }.font(.system(size: 11)) }
                    .foregroundStyle(DaybookStyle.accent).padding(.top, 5)
                VStack(spacing: 12) {
                    DaybookIcon("Ring", size: 38).foregroundStyle(DaybookStyle.accent).frame(width: 78, height: 78)
                        .background(DaybookStyle.blueSoft, in: RoundedRectangle(cornerRadius: 24))
                    Text("EurekaRing").font(.system(size: 23, weight: .semibold))
                    HStack(spacing: 6) {
                        Circle().fill(ring.isConnected ? DaybookStyle.green : DaybookStyle.secondary).frame(width: 5, height: 5)
                        Text(ring.connectionLabel).font(.system(size: 11))
                    }.foregroundStyle(DaybookStyle.secondary)
                    Text(ring.status).font(.system(size: 11)).lineSpacing(6).multilineTextAlignment(.center).foregroundStyle(DaybookStyle.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 5)

                if ring.binding != nil { deviceInformation }
                if ring.isBusy {
                    HStack(spacing: 10) { ProgressView(); Text(ring.status).font(.system(size: 11)) }
                    if let progress = ring.progress { ProgressView(value: progress).tint(DaybookStyle.accent) }
                }
                if let error = ring.errorMessage {
                    Text(error).font(.system(size: 11)).lineSpacing(6).foregroundStyle(DaybookStyle.red).textSelection(.enabled)
                }

                primaryActions

                if ring.binding != nil {
                    VStack(spacing: 18) {
                        if ring.isConnected {
                            Button("断开连接") { ring.disconnect() }.disabled(ring.isBusy)
                            Button("解绑设备") { confirmUnbind = true }.disabled(ring.isBusy || ring.isRecording || ring.needsFormatReconciliation)
                            Button("格式化设备") { confirmFormat = true }.foregroundStyle(DaybookStyle.red)
                                .disabled(ring.isBusy || ring.isRecording || ring.needsFormatReconciliation)
                        }
                    }.font(.system(size: 12)).frame(maxWidth: .infinity).padding(.top, 4)
                }
                Text("录音和闪念通过蓝牙同步，转换后保存在本机。Ring 闪念自动使用本地转写和 Apple 本地模型整理，在“一天 → 闪念”中查看。同步不会删除设备原录音。")
                    .font(.system(size: 10)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
            }.opacity(ring.isBusy ? 0.85 : 1)
        }
        .task { if ring.binding == nil { ring.scan() } else { await ring.foreground() } }
        .onDisappear { ring.stopScan() }
        .onChange(of: ring.isConnected) { _, connected in
            if !connected { confirmUnbind = false; confirmFormat = false }
        }
        .confirmationDialog("解绑 EurekaRing？", isPresented: $confirmUnbind, titleVisibility: .visible) {
            Button("确认解绑，保留录音", role: .destructive) { Task { await ring.unbind() } }
            Button("取消", role: .cancel) {}
        } message: { Text("解除设备与此 App 的绑定。设备上的录音和已保存到手机的笔记都会保留。") }
        .confirmationDialog("清空 EurekaRing 的全部录音？", isPresented: $confirmFormat, titleVisibility: .visible) {
            Button("清空并格式化设备", role: .destructive) { Task { await ring.format() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会永久删除设备内的全部录音和闪念，包括尚未同步的文件。当前已知有 \(ring.pendingCount) 条待同步记录\(ring.listIsComplete ? "" : "，设备列表尚未完整读取")。手机上已有的笔记会保留。")
        }
    }

    @ViewBuilder private var primaryActions: some View {
        switch ring.primaryAction {
        case .scan: scanControls
        case .reconnect:
            Button("重新连接") {
                if let binding = ring.binding { Task { await ring.connect(binding.device) } }
            }
            .buttonStyle(DaybookPrimaryButtonStyle(wide: true)).disabled(ring.isBusy)
            if ring.needsFormatReconciliation {
                Text("上次格式化结果待核对。请先重新连接，再确认设备文件状态。")
                    .font(.system(size: 11)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
            }
        case .reconcileFormat:
            Button("核对上次格式化结果") { Task { await ring.reconcileFormat() } }
                .buttonStyle(DaybookPrimaryButtonStyle(wide: true)).disabled(ring.isBusy || ring.isRecording)
            if ring.isRecording {
                Text("请先在 Ring 上结束录音或闪念，再核对上次格式化结果。")
                    .font(.system(size: 11)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
            }
        case .controls: connectedActions
        }
    }

    private var deviceInformation: some View {
        VStack(spacing: 0) {
            field("上次同步", value: ring.lastSync.map { RecordingFormat.date($0) } ?? "尚未同步")
            field("设备电量", value: ring.battery.map { "\($0)%" } ?? "尚未读取")
            field("待同步记录", value: "\(ring.pendingCount) 条\(ring.listIsComplete ? "" : " · 列表待核对")")
            field("闪念通知", value: !ring.isConnected ? "等待连接" : ring.flashIdeaSupported ? "已开启" : "暂不可用 · 可补同步历史闪念")
            field("设备存储", value: ring.storage, last: true)
        }.padding(.horizontal, 16).background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(DaybookStyle.line))
    }
    private func field(_ title: String, value: String, last: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 16) { Text(title); Spacer(); Text(value).multilineTextAlignment(.trailing).foregroundStyle(DaybookStyle.secondary) }
            .font(.system(size: 11)).padding(.vertical, 15)
            .overlay(alignment: .bottom) { if !last { DaybookStyle.line.frame(height: 1) } }
    }
    private var connectedActions: some View {
        VStack(spacing: 12) {
            Button(ring.isFlashIdeaRecording ? "请在 Ring 上结束闪念" : ring.isRecording ? "结束录音并同步" : "开始 Ring 录音") { Task { await ring.toggleRecording() } }
                .buttonStyle(DaybookPrimaryButtonStyle(wide: true)).disabled(ring.isBusy || ring.isFlashIdeaRecording || (phoneIsRecording && !ring.isRecording))
            Text("使用 Ring 的闪念操作录制。结束后自动同步到本机并整理；离线录制的闪念可点“同步录音与闪念”补同步。")
                .font(.system(size: 10)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
            if phoneIsRecording { Text("手机正在录音，保存后可从这里开始 Ring 录音。").font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary) }
            HStack(spacing: 12) {
                Button("同步录音与闪念") { Task { await ring.synchronize() } }.buttonStyle(DaybookSecondaryButtonStyle())
                Button("刷新状态") { Task { await ring.refresh() } }.buttonStyle(DaybookSecondaryButtonStyle())
            }.disabled(ring.isBusy || ring.isRecording)
        }
    }
    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(ring.isScanning ? "停止扫描" : "查找附近的 Ring") { if ring.isScanning { ring.stopScan() } else { ring.scan() } }
                .buttonStyle(DaybookPrimaryButtonStyle(wide: true)).disabled(ring.isBusy)
            ForEach(ring.discovered) { device in
                Button { Task { await ring.connect(device) } } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(device.name).font(.system(size: 13, weight: .medium))
                            Text(device.sn.isEmpty ? "附近的录音设备" : "SN · \(device.sn.suffix(6))").font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                        }
                        Spacer(); Text("连接").font(.system(size: 11)).foregroundStyle(DaybookStyle.accent)
                    }.padding(16).background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 14))
                }.disabled(ring.isBusy)
            }
        }
    }
}
#endif
