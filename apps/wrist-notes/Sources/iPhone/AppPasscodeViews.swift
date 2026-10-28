import SwiftUI

private struct PasscodeDigits: View {
    let count: Int
    var body: some View {
        HStack(spacing: 17) {
            ForEach(0..<6) { index in
                Circle().fill(index < count ? DaybookStyle.accent : DaybookStyle.line)
                    .frame(width: 12, height: 12)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("已输入 \(count) 位，共六位")
        .privacySensitive()
    }
}

private struct PasscodeKeypad: View {
    let disabled: Bool
    var biometry: (() -> Void)?
    let enter: (String) -> Void
    let erase: () -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)
    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(1...9, id: \.self) { number in digit(String(number)) }
            Group {
                if let biometry {
                    Button(action: biometry) {
                        Image(systemName: "faceid").font(.system(size: 27))
                            .frame(maxWidth: .infinity, minHeight: 58)
                    }.accessibilityLabel("使用生物识别解锁")
                } else { Color.clear.frame(height: 58) }
            }
            digit("0")
            Button(action: erase) {
                Image(systemName: "delete.backward").font(.system(size: 22))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel("删除一位")
            .accessibilityIdentifier("appLock.delete")
        }
        .buttonStyle(.plain)
        .foregroundStyle(DaybookStyle.ink)
        .disabled(disabled)
    }
    private func digit(_ value: String) -> some View {
        Button { enter(value) } label: {
            Text(value).font(.system(size: 29, weight: .regular, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(DaybookStyle.line, lineWidth: 0.5))
        }
        .accessibilityIdentifier("appLock.digit.\(value)")
    }
}

private struct PasscodeWaitMessage: View {
    let retryAt: Date?
    let message: String?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let remaining = retryAt.map { max(0, Int(ceil($0.timeIntervalSince(timeline.date)))) } ?? 0
            Text(remaining > 0 ? "\(remaining) 秒后可再次尝试" : (message ?? " "))
                .font(.system(size: 13)).foregroundStyle(DaybookStyle.secondary)
                .multilineTextAlignment(.center).frame(minHeight: 36)
                .accessibilityIdentifier("appLock.message")
        }
    }
}

struct AppPasscodeUnlockView: View {
    @ObservedObject var model: AppLockModel
    @State private var digits = ""
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    WiseLifeMark(ink: DaybookStyle.accent).frame(width: 72, height: 72)
                        .padding(.bottom, 26)
                    Text("回到你的 WiseLife").font(.system(size: 25, weight: .semibold))
                    Text("输入 App 六位密码")
                        .font(.system(size: 14)).foregroundStyle(DaybookStyle.secondary).padding(.top, 10)
                    PasscodeDigits(count: digits.count).padding(.top, 30).padding(.bottom, 12)
                    if model.isBusy { ProgressView().frame(height: 36) }
                    else { PasscodeWaitMessage(retryAt: model.retryAt, message: model.message) }
                    Spacer(minLength: 24)
                    PasscodeKeypad(disabled: model.isBusy || (model.retryAt.map { $0 > .now } ?? false),
                        biometry: model.biometricEnabled ? { Task { await model.unlockWithBiometry() } } : nil,
                        enter: append, erase: { if !digits.isEmpty { digits.removeLast() } })
                    Text(model.biometricEnabled ? "\(model.biometricName) 或 App 密码" : "你的记录，只为你打开")
                        .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
                        .padding(.top, 24).padding(.bottom, 20)
                }
                .frame(maxWidth: 330, minHeight: max(0, geometry.size.height - 32))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28).padding(.vertical, 16)
            }
        }
        .background(DaybookStyle.paper.ignoresSafeArea())
        .onDisappear { digits = "" }
        .accessibilityIdentifier("appLock.unlock")
    }
    private func append(_ digit: String) {
        guard digits.count < 6 else { return }
        digits += digit
        if digits.count == 6 {
            let code = digits
            Task { _ = await model.unlock(code: code); digits = "" }
        }
    }
}

struct AppPasscodeEditor: View {
    enum Mode: String, Identifiable { case setup, change, enableBiometry; var id: String { rawValue } }
    @ObservedObject var model: AppLockModel
    let mode: Mode
    var allowsSkip = false
    var completed: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var digits = ""
    @State private var firstCode = ""
    @State private var currentCode = ""
    @State private var useBiometry = false
    @State private var busy = false
    @State private var error: String?

    private var needsCurrent: Bool { mode != .setup && step == 0 }
    private var confirming: Bool { mode == .setup ? step == 1 : step == 2 }
    private var title: String {
        if needsCurrent { return "输入当前 App 密码" }
        return confirming ? "再输入一次，确认密码" : (mode == .change ? "设置新的六位密码" : "为记录加一道保护")
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        if !allowsSkip { Button("取消") { dismiss() }.disabled(busy || model.isBusy) }
                        Spacer()
                        if allowsSkip { Button("暂时跳过") { model.skipSetup() }.disabled(busy || model.isBusy) }
                    }
                    .font(.system(size: 14)).foregroundStyle(DaybookStyle.secondary)
                    Spacer(minLength: 24)
                    WiseLifeMark(ink: DaybookStyle.accent).frame(width: 64, height: 64).padding(.bottom, 24)
                    Text(title).font(.system(size: 24, weight: .semibold))
                        .multilineTextAlignment(.center).minimumScaleFactor(0.85)
                    Text(needsCurrent ? "验证后继续" : "六位数字，打开属于你的个人记录")
                        .font(.system(size: 13)).foregroundStyle(DaybookStyle.secondary).padding(.top, 10)
                    PasscodeDigits(count: digits.count).padding(.top, 28).padding(.bottom, 12)
                    if busy || model.isBusy { ProgressView().frame(height: 36) }
                    else { PasscodeWaitMessage(retryAt: model.retryAt, message: error) }
                    if mode == .setup && !confirming && model.biometricAvailable {
                        Toggle("同时启用 \(model.biometricName)", isOn: $useBiometry)
                            .font(.system(size: 14)).tint(DaybookStyle.accent)
                            .padding(.horizontal, 8).padding(.top, 10).disabled(busy)
                    }
                    if confirming {
                        Button("重新输入新密码") {
                            firstCode = ""; digits = ""; error = nil
                            step = mode == .setup ? 0 : 1
                        }.font(.system(size: 13)).padding(.top, 8).disabled(busy)
                    }
                    Spacer(minLength: 22)
                    PasscodeKeypad(disabled: busy || model.isBusy || (model.retryAt.map { $0 > .now } ?? false),
                        enter: append, erase: { if !digits.isEmpty { digits.removeLast() } })
                    Text(allowsSkip ? "也可以稍后在设置中开启" : "密码仅用于解锁此设备上的 WiseLife")
                        .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
                        .padding(.top, 22).padding(.bottom, 16)
                }
                .frame(maxWidth: 330, minHeight: max(0, geometry.size.height - 32))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28).padding(.vertical, 16)
            }
        }
        .background(DaybookStyle.paper.ignoresSafeArea()).tint(DaybookStyle.accent)
        .interactiveDismissDisabled(busy || model.isBusy)
        .onChange(of: model.lockCycle) { _, _ in
            clear()
            if !allowsSkip { dismiss() }
        }
        .onDisappear { clear() }
        .accessibilityIdentifier("appLock.editor.\(mode.rawValue)")
    }
    private func clear() { digits = ""; firstCode = ""; currentCode = ""; error = nil }
    private func append(_ digit: String) {
        guard digits.count < 6 else { return }
        digits += digit
        guard digits.count == 6 else { return }
        let code = digits
        if needsCurrent {
            busy = true
            Task {
                do {
                    if mode == .enableBiometry {
                        try await model.enableBiometry(current: code)
                        completed(); dismiss()
                    } else {
                        try await model.validateCurrent(code)
                        currentCode = code; step = 1; error = nil
                    }
                } catch { self.error = error.localizedDescription }
                digits = ""; busy = false
            }
        } else if !confirming {
            firstCode = code; digits = ""; step += 1; error = nil
        } else {
            guard code == firstCode else { digits = ""; error = "两次输入不一致，请重新确认。"; return }
            busy = true
            Task {
                do {
                    if mode == .setup { try await model.createPasscode(code, useBiometry: useBiometry) }
                    else { try await model.changePasscode(current: currentCode, replacement: code) }
                    completed(); dismiss()
                } catch { self.error = error is CancellationError ? nil : error.localizedDescription }
                digits = ""; busy = false
            }
        }
    }
}

struct AppPasscodeSettingsSection: View {
    @EnvironmentObject private var model: AppLockModel
    @State private var editor: AppPasscodeEditor.Mode?
    var body: some View {
        SettingsSection("隐私与安全") {
            VStack(spacing: 0) {
                Button { editor = model.isConfigured ? .change : .setup } label: {
                    SettingsRow(symbol: "lock.shield", title: model.isConfigured ? "修改密码" : "设置密码",
                                subtitle: model.isConfigured ? "已开启六位 App 密码" : "为个人记录设置六位数字密码")
                }
                .accessibilityIdentifier("settings.appPasscode")
                if model.isConfigured {
                    Divider().overlay(NotesStyle.border)
                    Toggle(isOn: Binding(get: { model.biometricEnabled }, set: { enabled in
                        if enabled { editor = .enableBiometry }
                        else { Task { await model.disableBiometry() } }
                    })) {
                        Label("\(model.biometricName) 解锁", systemImage: model.biometricName == "Touch ID" ? "touchid" : "faceid")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .tint(DaybookStyle.accent).padding(18)
                    .disabled(!model.biometricAvailable && !model.biometricEnabled)
                }
            }.settingsCard()
            SettingsFootnote(text: model.isConfigured
                ? "离开 App 后会重新锁定。生物识别不可用时，仍可使用 App 密码。"
                : "可暂时不设置；之后随时在这里开启。")
        }
        .fullScreenCover(item: $editor) { mode in AppPasscodeEditor(model: model, mode: mode) }
    }
}
