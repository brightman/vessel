import SwiftUI
import CoreImage.CIFilterBuiltins
import CompanionCore

struct CompanionView: View {
    @ObservedObject var model: CompanionModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 218)
            Rectangle().fill(Theme.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let error = model.error { errorBanner(error) }
                    if let notice = model.notice { noticeBanner(notice) }
                    switch model.page {
                    case .overview: overview
                    case .models: modelLibrary
                    case .devices: pairedDevices
                    case .privacy: privacy
                    }
                }.padding(32).frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity)
            }.background(Theme.background)
        }
        .foregroundStyle(Theme.ink).tint(Theme.accent).preferredColorScheme(.light)
        .frame(minWidth: 1000, minHeight: 720)
        .onChange(of: model.page) { _, page in if page == .devices { model.loadPairingDevices() } }
        .sheet(isPresented: $model.showPairing, onDismiss: { model.closePairing() }) { pairingSheet }
                .alert("撤销设备配对？", isPresented: Binding(get: { model.pendingRevoke != nil }, set: { if !$0 { model.pendingRevoke = nil } })) {
            Button("取消", role: .cancel) { model.pendingRevoke = nil }
            Button("撤销配对", role: .destructive) {
                if let device = model.pendingRevoke { model.revoke(device) }; model.pendingRevoke = nil
            }
        } message: { Text("该 iPhone 的请求将被取消，之后需要重新扫码配对。手机端应同时移除已保存的凭据。") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 24, weight: .medium)).foregroundStyle(Theme.accent)
                    .frame(width: 42, height: 42).background(Theme.blueSoft, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("WiseLife").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("Mac Companion").font(.system(size: 10, weight: .medium)).tracking(0.6).foregroundStyle(Theme.muted)
                }
            }.padding(.horizontal, 22).padding(.top, 36).padding(.bottom, 40)
            Text("工作空间").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Theme.muted).padding(.leading, 25).padding(.bottom, 12)
            ForEach(CompanionModel.Page.allCases) { page in
                Button { model.page = page } label: {
                    HStack(spacing: 11) {
                        Image(systemName: page.icon).font(.system(size: 15)).frame(width: 20)
                        Text(page.rawValue).font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                        Spacer()
                        if page == .devices, !model.devices.isEmpty { Text("\(model.devices.count)").font(.system(size: 10, weight: .medium)) }
                    }.padding(.horizontal, 13).frame(height: 42)
                        .background(model.page == page ? Theme.blueSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(model.page == page ? Theme.accent : Theme.muted)
                }.buttonStyle(.plain).padding(.horizontal, 13).padding(.bottom, 5)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) { Circle().fill(model.advertising ? Theme.green : Theme.muted).frame(width: 6, height: 6); Text(model.advertising ? "局域网服务已开启" : "局域网服务已暂停").font(.system(size: 11, weight: .medium)) }
                Text("文本在你的 Mac 上处理").font(.system(size: 10)).foregroundStyle(Theme.muted)
                Divider()
                HStack { Text("工程预览版").font(.system(size: 10)); Spacer(); Text("0.2.0").font(.system(size: 10, design: .monospaced)) }.foregroundStyle(Theme.muted)
            }.padding(16).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 14)).padding(16)
        }.frame(maxHeight: .infinity).background(Theme.sidebar)
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("WISELIFE · MAC").font(.system(size: 10, weight: .medium)).tracking(2).foregroundStyle(Theme.muted)
                Text(model.page.rawValue).font(.system(size: 28, weight: .semibold, design: .rounded))
            }
            Spacer()
            Label("Apple silicon · MLX", systemImage: "desktopcomputer").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 13).padding(.vertical, 9).background(.white, in: Capsule()).overlay(Capsule().strokeBorder(Theme.line))
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("在你的 Mac 上，运行本地 AI。").font(.system(size: 23, weight: .semibold))
                Text("为 iPhone 处理已授权的文字，模型与推理都留在这台 Mac。").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }.padding(.bottom, 3)
            hardwareCard
            HStack(alignment: .top, spacing: 16) {
                panel {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionLabel("本机模型", icon: "cpu")
                        HStack { Text(model.state.title).font(.system(size: 18, weight: .semibold)); Spacer(); statusDot(model.ready) }
                        Text(model.currentModel?.name ?? "下载后，点击加载即可在本机运行").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        if model.operationID != nil { operationProgress }
                        else if model.ready {
                            HStack { Label("8K 上下文上限", systemImage: "text.alignleft"); Spacer(); Button("卸载模型") { model.unload() } }.font(.system(size: 11))
                        } else {
                            Button { model.page = .models } label: { Label("前往模型库", systemImage: "arrow.right").frame(maxWidth: .infinity) }.buttonStyle(CompanionPrimaryButtonStyle())
                        }
                    }
                }
                panel {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionLabel("iPhone 连接", icon: "iphone")
                        Text(model.devices.isEmpty ? (model.pairingRegistryLoaded ? "等待配对" : "配对与设备") : "已配对 \(model.devices.count) 台设备").font(.system(size: 18, weight: .semibold))
                        Text(model.serviceMessage).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
                        Button { model.openPairing() } label: { Label("配对 iPhone", systemImage: "qrcode").frame(maxWidth: .infinity) }.buttonStyle(CompanionSecondaryButtonStyle()).disabled(!model.initialized)
                    }
                }
            }
            availabilityCard
            panel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { sectionLabel("运行状态", icon: "waveform.path"); Spacer(); if model.active { Button("取消生成") { model.cancelGeneration() }.font(.system(size: 11)) } }
                    HStack(alignment: .top, spacing: 16) {
                        metric("推理队列", model.active ? "处理中" : "空闲", detail: "等待 \(model.queued) / 2")
                        metric("首次响应", model.metrics.map { String(format: "%.2f s", $0.firstTokenSeconds) } ?? "—", detail: "实际请求后记录")
                        metric("进程峰值内存", ByteCountFormatter.string(fromByteCount: model.sample.peakProcessBytes, countStyle: .memory), detail: "系统内存压力：\(pressureLabel)")
                    }
                }
            }
            Label("Mac 休眠或网络不可达时，可在 iPhone 重试，不会自动改用云端模型。", systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }
    private var hardwareCard: some View {
        panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 13) {
                    Image(systemName: "desktopcomputer").font(.system(size: 24, weight: .regular)).foregroundStyle(Theme.accent)
                        .frame(width: 48, height: 48).background(Theme.field, in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("这台 Mac").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Text(model.hardware.chip).font(.system(size: 17, weight: .semibold))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(model.hardware.memoryGB) GB").font(.system(size: 24, weight: .semibold)).monospacedDigit()
                        Text("统一内存").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                }
                Divider().overlay(Theme.line)
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let recommended = model.recommendedModel {
                            HStack(spacing: 7) {
                                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                                Text("为你推荐 " + recommended.name).fontWeight(.semibold)
                            }.font(.system(size: 13))
                            Text("根据本机 \(model.hardware.memoryGB) GB 内存选择，为系统与其他应用保留余量。").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        } else {
                            Text("这台 Mac 暂无适合的内置模型").font(.system(size: 13, weight: .semibold))
                            Text("当前模型建议在 Apple silicon、8 GB 或以上内存的 Mac 上使用。").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer(minLength: 0)
                    if model.page != .models {
                        Button("查看推荐模型") { model.page = .models }.buttonStyle(CompanionSecondaryButtonStyle()).fixedSize()
                    }
                }
                if model.sample.pressure == "warning" || model.sample.pressure == "critical" {
                    Label("当前内存压力偏高，可以先关闭其他应用，或选择 1.7B 轻量模型。", systemImage: "memorychip")
                        .font(.system(size: 11)).foregroundStyle(Theme.warning)
                }
            }
        }
    }
    private var availabilityCard: some View {
        panel {
            HStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 22)).foregroundStyle(Theme.accent).frame(width: 38)
                VStack(alignment: .leading, spacing: 5) {
                    Text("为配对的 iPhone 提供本地 AI").font(.system(size: 13, weight: .semibold))
                    Text("开启后可被附近设备发现；只有已配对设备可发送文字。").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Toggle("提供本地 AI", isOn: Binding(get: { model.available }, set: { model.changeAvailability($0) })).labelsHidden().toggleStyle(.switch).disabled(!model.initialized)
            }
        }
    }
    private var modelLibrary: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("选择适合这台 Mac 的模型。").font(.system(size: 22, weight: .semibold))
                Text("点击下载，即从 Hugging Face 获取模型。下载并校验后，可离线加载使用。").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            hardwareCard
            HStack {
                Text("可下载模型").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("可用空间 " + ByteCountFormatter.string(fromByteCount: model.freeBytes, countStyle: .file)).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }.padding(.horizontal, 4).padding(.top, 4)
            ForEach(model.orderedModels) { item in modelCard(item) }
            Text("推荐依据总内存与当前内置模型目录，实际内存占用还取决于上下文长度和其他应用。下载大小不代表运行内存；具体性能需以本机使用为准。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(5).padding(.horizontal, 4)
            panel {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("本地运行与存储", icon: "internaldrive")
                    Text("同时只加载一个模型、处理一个请求。上下文最多 8,192 tokens，输出最多 2,048 tokens。空闲 10 分钟或系统内存紧张时自动卸载。").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(5)
                    Text("下载文件保存在这台 Mac 的应用资料目录，不会上传笔记或录音。").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
        }
    }
    private func modelCard(_ item: CatalogModel) -> some View {
        let recommended = model.recommendedModel?.id == item.id
        return panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: "cpu").font(.system(size: 23, weight: .regular)).foregroundStyle(Theme.accent)
                        .frame(width: 48, height: 48).background(Theme.field, in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(item.name).font(.system(size: 17, weight: .semibold))
                            badge(recommended ? "为你推荐" : model.fits(item) ? "轻量选择" : "内存要求较高")
                        }
                        Text(ModelRecommendation.explanation(for: item.id, hardware: model.hardware)).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if model.currentModelID == item.id && model.ready {
                        Label("已加载", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.green).fixedSize()
                    }
                }
                HStack(spacing: 12) {
                    Label(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file), systemImage: "arrow.down.circle")
                    Text("建议 \(ModelRecommendation.suggestedMemoryGB(for: item.id) ?? 16) GB+ 内存")
                    Link(item.license, destination: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!)
                }.font(.system(size: 11)).foregroundStyle(Theme.muted)
                Divider().overlay(Theme.line)
                if model.operationID == item.id { operationProgress }
                else { modelActions(item) }
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Link(item.id, destination: URL(string: item.source + "/tree/" + item.revision)!)
                        Text("固定版本 " + item.revision).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        Text("从 Hugging Face 直接下载固定版本，逐个校验文件完整性后才可加载。当前为工程预览模型，尚需完成 M3 Air 持续性能验收。")
                    }.font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 10)
                } label: { Text("来源与版本").font(.system(size: 10)) }.tint(Theme.muted)
            }
        }
    }
    private func modelActions(_ item: CatalogModel) -> some View {
        HStack(spacing: 12) {
            Link(destination: URL(string: item.source)!) {
                Label("Hugging Face", systemImage: "arrow.up.right.square")
            }.font(.system(size: 11))
            if model.installed.contains(item.id) {
                Label("已下载并校验", systemImage: "checkmark.circle").font(.system(size: 10)).foregroundStyle(Theme.green)
            }
            Spacer(minLength: 0)
            if model.installed.contains(item.id) {
                Button("删除", role: .destructive) { model.remove(item) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted).disabled(model.busy || model.active)
                if model.currentModelID == item.id && model.ready {
                    Button("卸载模型") { model.unload() }.buttonStyle(CompanionSecondaryButtonStyle()).disabled(model.busy)
                } else {
                    Button("加载模型") { model.load(item) }.buttonStyle(CompanionPrimaryButtonStyle()).disabled(model.busy || model.active)
                }
            } else {
                Button { model.download(item) } label: {
                    Label(model.retryDownloadID == item.id ? "重新下载" : "下载模型", systemImage: "arrow.down")
                }.buttonStyle(CompanionPrimaryButtonStyle()).disabled(model.busy || !model.initialized || !model.fits(item))
            }
        }
    }
    private var operationProgress: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text(model.operationLabel).fontWeight(.medium)
                Spacer()
                if let progress = model.progress {
                    Text(model.downloadPhase == .verifying ? "校验中" : progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().foregroundStyle(Theme.muted)
                }
                Button("取消") { model.cancelOperation() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            }.font(.system(size: 11))
            if let progress = model.progress { ProgressView(value: progress).tint(Theme.accent) }
            else { ProgressView().controlSize(.small) }
            if model.downloadPhase != nil {
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: model.downloadTotal, countStyle: .file)).monospacedDigit()
                    Spacer()
                    if model.downloadPhase == .verifying {
                        Text("校验完成后即可加载")
                    } else if model.downloadSpeed > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(model.downloadSpeed), countStyle: .file) + "/s").monospacedDigit()
                    } else { Text("正在建立安全连接…") }
                }.font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
        }.padding(14).background(Theme.background, in: RoundedRectangle(cornerRadius: 12))
    }
    private var pairedDevices: some View {
        VStack(alignment: .leading, spacing: 20) {
            availabilityCard
            if model.pairingAccessPending {
                panel {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("正在读取配对资料，请完成系统钥匙串授权。").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
            } else if !model.pairingRegistryLoaded {
                panel {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("读取本机的配对资料").font(.system(size: 15, weight: .semibold))
                        Text("配对资料保存在系统钥匙串中，完成系统授权后可查看已配对的设备。").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        Button("读取配对资料") { model.loadPairingDevices() }.buttonStyle(CompanionSecondaryButtonStyle())
                    }
                }
            } else if model.devices.isEmpty {
                panel {
                    VStack(spacing: 18) {
                        Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(Theme.accent).padding(.top, 20)
                        Text("从一次扫码，建立信任。").font(.system(size: 20, weight: .medium, design: .rounded))
                        Text("在 iPhone「设置 → AI 模型 → 附近 Mac」中扫描配对码。\n两台设备需处于可互通的局域网，并允许本地网络访问。").font(.system(size: 12)).multilineTextAlignment(.center).foregroundStyle(Theme.muted).lineSpacing(6)
                        Button { model.openPairing() } label: { Label("配对 iPhone", systemImage: "qrcode") }.buttonStyle(CompanionPrimaryButtonStyle()).controlSize(.large).disabled(!model.initialized).padding(.bottom, 20)
                    }.frame(maxWidth: .infinity)
                }
            } else {
                ForEach(model.devices) { device in
                    panel {
                        HStack(spacing: 16) {
                            Image(systemName: "iphone").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(device.name).font(.system(size: 14, weight: .semibold))
                                Text("配对于 " + device.pairedAt.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                                Text("已授权设备 · 当前在线状态未知").font(.system(size: 10)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button("撤销配对", role: .destructive) { model.pendingRevoke = device }.buttonStyle(CompanionSecondaryButtonStyle())
                        }
                    }
                }
                Button { model.openPairing() } label: { Label("配对另一台 iPhone", systemImage: "plus") }.disabled(!model.initialized)
            }
            panel {
                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("连接帮助", icon: "wifi")
                    if !model.networkNames.isEmpty {
                        Picker("使用的本机网络", selection: Binding(get: { model.selectedNetwork }, set: { model.changeNetwork($0) })) {
                            ForEach(model.networkNames, id: \.self) { Text(LocalInterface.displayName(for: $0)).tag($0) }
                        }.font(.system(size: 12)).frame(maxWidth: 300)
                    }
                    Text("找不到 Mac 时，请检查局域网权限、Mac 是否休眠，以及路由器或热点是否阻止设备互访。配对需要支持「附近 Mac」的 WiseLife iPhone 版本。").font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(5)
                    Button("重试局域网服务") { model.retryService() }.disabled(!model.initialized)
                    Text("配对不是在线证明。Mac 只会在收到合法请求后处理文字。").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
        }
    }
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("你的文字，交给你信任的 Mac。").font(.system(size: 22, weight: .medium, design: .rounded))
            privacyRow("只处理你授权的文字", "选择「附近 Mac」后，获准用于当前任务的文字会离开 iPhone，经局域网发送到这台 Mac。音频、照片和无关资料不在此服务的接收范围内。", icon: "text.badge.checkmark")
            privacyRow("一次扫码，独立凭据", "所有请求使用 TLS 加密。配对码 2 分钟失效且只能使用一次；每台 iPhone 使用独立凭据，Mac 将凭据校验值和证书存于系统钥匙串。", icon: "key.horizontal")
            privacyRow("推理完成后，释放会话", "Mac 保存模型文件和配对资料；不保存提示词、转写、总结或回复，也不记录请求和响应正文。每次生成使用独立的推理会话。", icon: "arrow.trianglehead.2.clockwise.rotate.90")
            privacyRow("服务暂停时，由你决定下一步", "Mac 不可用时，iPhone 应明确提示并允许重试。该服务不会把请求改发给 ChatGPT、自定义云端服务或 WiseLife 服务器。", icon: "hand.raised")
            panel {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("关于这个版本", icon: "info.circle")
                    Text("独立 macOS 15+／Apple silicon 工程预览版。使用 MLX Swift、mlx-swift-lm、SwiftNIO、NIOSSL 与 Swift Certificates。模型许可证为 Apache-2.0，具体来源和版本见模型库。").font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(5)
                    Text("正式支持范围、上下文设置与性能指标需在 M3 Air／16GB 上完成基准测试后确定。发布版仍需 Developer ID 签名及公证。").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
        }
    }
    private func privacyRow(_ title: String, _ text: String, icon: String) -> some View {
        panel {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: icon).font(.system(size: 22, weight: .light)).foregroundStyle(Theme.accent).frame(width: 30)
                VStack(alignment: .leading, spacing: 9) { Text(title).font(.system(size: 14, weight: .semibold)); Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(5) }
            }
        }
    }
    private var pairingSheet: some View {
        VStack(spacing: 18) {
            HStack { Text("配对 iPhone").font(.system(size: 20, weight: .semibold)); Spacer(); Button { model.closePairing() } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            Text("在 iPhone「设置 → AI 模型 → 附近 Mac」中扫码。\n配对会将这台 Mac 设为获准文字的处理设备。").font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineSpacing(5)
            if let pairing = model.pairing, let image = qrImage(pairing.url.absoluteString) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 216, height: 216).padding(18).background(.white, in: RoundedRectangle(cornerRadius: 16))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("配对码 \(max(0, Int(pairing.expiresAt.timeIntervalSince(context.date)))) 秒后失效 · 仅可使用一次").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted)
                }
            } else {
                Image(systemName: model.devices.isEmpty ? "qrcode" : "checkmark.shield").font(.system(size: 60, weight: .ultraLight)).foregroundStyle(Theme.accent).frame(height: 220)
                Text("配对码已使用或失效").font(.system(size: 12))
            }
            Label(model.serviceMessage, systemImage: "wifi").font(.system(size: 11)).foregroundStyle(Theme.muted)
            if !model.advertising { Button("重试设备发现") { model.retryService() }.buttonStyle(CompanionSecondaryButtonStyle()) }
            Button("重新生成配对码") { model.openPairing() }.buttonStyle(CompanionSecondaryButtonStyle())
            Text("二维码包含一次性配对凭据和证书指纹，请勿分享。\n配对后仍需在 iPhone 开启本次任务的文字发送授权。").font(.system(size: 10)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineSpacing(4)
        }.padding(28).frame(width: 430).background(Theme.background).tint(Theme.accent)
    }
    private func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage, let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: .init(width: cg.width, height: cg.height))
    }
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, alignment: .leading).padding(22).background(.white, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.line.opacity(0.8)))
    }
    private func sectionLabel(_ title: String, icon: String) -> some View { Label(title, systemImage: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted) }
    private func statusDot(_ ready: Bool) -> some View { Circle().fill(ready ? Theme.green : Theme.line).frame(width: 9, height: 9) }
    private func badge(_ label: String) -> some View { Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.accent).padding(.horizontal, 7).padding(.vertical, 4).background(Theme.blueSoft, in: Capsule()) }
    private func metric(_ label: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(label).font(.system(size: 10)).foregroundStyle(Theme.muted); Text(value).font(.system(size: 18, weight: .medium, design: .rounded)); Text(detail).font(.system(size: 9)).foregroundStyle(Theme.muted) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var pressureLabel: String { ["normal": "正常", "warning": "偏高", "critical": "严重" ][model.sample.pressure] ?? "未知" }
    private func noticeBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle")
            Text(message).font(.system(size: 12))
            Spacer()
            Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }.foregroundStyle(Theme.accent).padding(14).background(Theme.blueSoft, in: RoundedRectangle(cornerRadius: 12))
    }
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) { Image(systemName: "exclamationmark.circle"); Text(message).font(.system(size: 12)); Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.foregroundStyle(Color(red: 0.57, green: 0.30, blue: 0.17)).padding(14).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }
}
