import ActivityKit
import AVFAudio
import SwiftUI
import UIKit

struct QuickRecordingSettingsView: View {
    private enum Shortcut: String {
        case actionButton = "操作按钮", lockScreen = "锁屏小组件", liveActivity = "实时活动"
    }
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected: Shortcut?
    @State private var microphoneAllowed = AVAudioApplication.shared.recordPermission == .granted
    @State private var activitiesAllowed = ActivityAuthorizationInfo().areActivitiesEnabled

    var body: some View {
        SettingsPage(title: selected?.rawValue ?? "快捷设置", subtitle: "用适合你的方式，快速开始和保存录音。") {
            if let selected {
                Button { self.selected = nil } label: {
                    Label("快捷设置", systemImage: "chevron.left").font(SettingsMenuStyle.note)
                        .foregroundStyle(DaybookStyle.secondary).padding(.vertical, 8)
                }.accessibilityIdentifier("settings.shortcuts.back")
                instructions(selected)
                SettingsSection("权限状态") {
                    readiness("麦克风", ready: microphoneAllowed)
                    readiness("实时活动", ready: activitiesAllowed)
                    if !microphoneAllowed {
                        Button("允许麦克风访问") {
                            Task {
                                if AVAudioApplication.shared.recordPermission == .denied { openSettings() }
                                else { microphoneAllowed = await AVAudioApplication.requestRecordPermission() }
                            }
                        }.buttonStyle(DaybookSettingsButtonStyle(primary: true))
                    }
                    if !activitiesAllowed {
                        SettingsFootnote(text: "请在系统设置中允许 WiseLife 的实时活动，以便通过操作按钮录音。")
                    }
                    Button("打开 WiseLife 系统设置", action: openSettings)
                        .buttonStyle(DaybookSettingsButtonStyle())
                }
            } else {
                SettingsMenuGroup("快捷录音") {
                    shortcut(.actionButton, icon: "Settings2", subtitle: "长按开始，再次长按停止并保存")
                    shortcut(.lockScreen, icon: "Mic", subtitle: "从锁屏快速开始录音")
                    shortcut(.liveActivity, icon: "Activity", subtitle: "查看录音时长，停止并保存")
                }
                SettingsFootnote(text: "录音由你主动开始，先保存在本机，再按所选模型转写。")
                    .padding(.top, 16)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                microphoneAllowed = AVAudioApplication.shared.recordPermission == .granted
                activitiesAllowed = ActivityAuthorizationInfo().areActivitiesEnabled
            }
        }
    }

    private func shortcut(_ shortcut: Shortcut, icon: String, subtitle: String) -> some View {
        Button { selected = shortcut } label: {
            SettingsMenuRow(icon: icon, title: shortcut.rawValue, subtitle: subtitle)
        }.accessibilityIdentifier("settings.shortcuts." + String(describing: shortcut))
    }
    @ViewBuilder private func instructions(_ shortcut: Shortcut) -> some View {
        switch shortcut {
        case .actionButton:
            SettingsSection("绑定操作按钮") {
                instruction("1", "打开 iPhone「设置」→「操作按钮」。")
                instruction("2", "选择「快捷指令」→「选取快捷指令」。")
                instruction("3", "选择 WiseLife 的「开始／停止录音」。")
                Link("打开快捷指令", destination: URL(string: "shortcuts://")!)
                    .buttonStyle(DaybookSettingsButtonStyle())
                SettingsFootnote(text: "操作按钮需要 iPhone 支持，并由你在系统设置中绑定。没有操作按钮时，也可从快捷指令运行。")
            }
        case .lockScreen:
            SettingsSection("添加锁屏小组件") {
                instruction("1", "长按锁屏，选择「自定」→「锁定屏幕」。")
                instruction("2", "轻点「添加小组件」→ WiseLife →「快捷录音」。")
                SettingsFootnote(text: "轻点麦克风开始录音；再次轻点不会停止。请通过实时活动中的「停止并保存」结束录音。首次使用需允许麦克风和实时活动；锁屏操作可能需要 Face ID 或系统解锁。")
            }
        case .liveActivity:
            SettingsSection("录音时") {
                SettingsFootnote(text: "锁屏和灵动岛显示录音时长。再次长按操作按钮，或轻点实时活动中的「停止并保存」。锁屏上的操作可能需要解锁。")
                SettingsFootnote(text: "录音先保存在本机，再按已选模型转写。来电等中断会结束录音并保存已录制的部分；保存失败时，可在 App 内重试。")
            }
        }
    }
    private func readiness(_ title: String, ready: Bool) -> some View {
        HStack {
            Text(LocalizedStringKey(title)).font(SettingsMenuStyle.title)
            Spacer()
            Label(LocalizedStringKey(ready ? "已允许" : "未允许"), systemImage: ready ? "checkmark.circle.fill" : "circle")
                .font(SettingsMenuStyle.note).foregroundStyle(ready ? DaybookStyle.green : DaybookStyle.secondary)
        }
    }
    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(SettingsMenuStyle.note).foregroundStyle(DaybookStyle.accent)
            Text(LocalizedStringKey(text)).font(SettingsMenuStyle.note).lineSpacing(6)
        }
    }
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
