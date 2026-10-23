import SwiftUI

/// Owns only the disposable enrollment take; the shared profile commits validated replacements.
struct MyVoiceEnrollmentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var profile: MyVoiceProfileModel
    var recordingBlocked = false
    @StateObject private var recorder = PhoneRecorder()
    @State private var preparing = false
    @State private var confirmedSolo = false
    @State private var confirmingDelete = false
    @State private var saveTask: Task<Void, Never>?
    @State private var startTask: Task<Void, Never>?

    var body: some View {
        DaybookSheetLayout(title: "我的声音", onClose: close) {
            VStack(alignment: .leading, spacing: 20) {
                if profile.isSaving {
                    ProgressView("正在验证并保存声音档案…").frame(maxWidth: .infinity).padding(.vertical, 28)
                    note("正在本机检查独立讲话与声音质量，请稍候。")
                    action("取消", perform: abandon)
                } else if recorder.isRecording || recorder.requestingPermission {
                    recording
                } else if let draft = recorder.draft {
                    review(draft)
                } else if profile.storageError != nil {
                    hero("声音档案暂时无法读取", subtitle: "这不表示登记已删除。解锁 iPhone 后会自动重试，也可以手动重新读取。", symbol: "lock.shield")
                    action("重试读取", emphasis: DaybookStyle.accent) { profile.reload() }
                } else if let stored = profile.profile, !preparing {
                    registered(stored)
                } else {
                    preparation
                }
                if let message = recorder.errorMessage ?? profile.storageError ?? profile.errorMessage {
                    Text(LocalizedStringKey(message)).font(.system(size: 12)).foregroundStyle(DaybookStyle.red)
                        .accessibilityLabel(Text(LocalizedStringKey(message)))
                }
                Label { note("声音档案仅保存在本机，不上传云端，可随时删除。") } icon: {
                    Image(systemName: "lock.shield").foregroundStyle(DaybookStyle.green)
                }
                note("登记录音仅用于本机提取声音特征，保存或退出后删除。所需资源随语音转写模型下载；请在设置中的“语音转写模型”准备资源。")
            }.padding(.top, 18)
        }
        .confirmationDialog("删除我的声音？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("确认删除", role: .destructive) { abandon(); _ = profile.delete(); preparing = false }
            Button("保留登记", role: .cancel) {}
        } message: { Text("删除后，后续录音不再自动匹配“我”。已有笔记和手动标注会保留。") }
        .onAppear { profile.reload() }
        .onDisappear { abandon() }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { profile.reload(); return }
            startTask?.cancel(); startTask = nil
            if recorder.isRecording { recorder.stop() }
            else if recorder.requestingPermission { recorder.discard() }
        }
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 18) {
            hero("让笔记认出你的声音", subtitle: "录下 30～60 秒独立讲话，在多人录音中，找到你说的话。", symbol: "waveform")
            Label("30–60 秒 · iPhone 麦克风", systemImage: "mic")
                .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
            Text("找一个安静的地方").font(.headline)
            note("避开音乐、电视和其他人的声音。")
            Text("只录你一个人讲话").font(.headline)
            note("用平常的语气连续说话，不用刻意念得标准。")
            prompt
            if profile.profile != nil { note("新录音保存后才会替换当前登记。") }
            if recordingBlocked { note("请先保存或放弃当前手机录音，再登记我的声音。") }
            action("开始录制", emphasis: DaybookStyle.red) {
                confirmedSolo = false; profile.errorMessage = nil
                startTask = Task {
                    guard !Task.isCancelled else { return }
                    await recorder.start(maximumDuration: 60, builtInMicrophoneOnly: true)
                }
            }.disabled(recordingBlocked)
            if profile.profile != nil { action("返回") { preparing = false } }
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 18) {
            hero("说说此刻的你", subtitle: "按平常的语速，只录你一个人讲话。", symbol: "mic.fill")
            Text(RecordingFormat.duration(recorder.duration)).font(.system(size: 36, weight: .light, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.55)
                .frame(maxWidth: .infinity).accessibilityLabel("录制时长")
            Image(systemName: "waveform").font(.system(size: 38, weight: .light))
                .foregroundStyle(DaybookStyle.red).frame(maxWidth: .infinity)
                .symbolEffect(.variableColor, options: .repeating, isActive: recorder.isRecording && !reduceMotion)
                .accessibilityHidden(true)
            ProgressView(value: min(recorder.duration, 60), total: 60).tint(DaybookStyle.red)
                .accessibilityLabel("声音登记录制进度")
            HStack { Text("0:00"); Spacer(); Text("0:30"); Spacer(); Text("1:00") }
                .font(.caption).foregroundStyle(DaybookStyle.secondary)
            note(recorder.duration >= 30 ? "现在可以结束，也可以继续说到 60 秒。" : "录满 30 秒后可结束，60 秒自动停止。")
            prompt
            action("结束录音", emphasis: DaybookStyle.red) { recorder.stop() }.disabled(recorder.duration < 30 || recorder.requestingPermission)
            action("取消", perform: abandon)
            note("退出将放弃本次录音，已有登记不受影响。")
        }
    }

    private func review(_ draft: PhoneRecordingDraft) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            hero("这一段，是你的声音", subtitle: "录音已结束，确认后保存声音档案。", symbol: "checkmark")
            Text(RecordingFormat.duration(draft.duration)).font(.system(size: 36, weight: .light, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.55).frame(maxWidth: .infinity)
            if draft.duration < 30 { note("录音不足 30 秒，请重新录制。") }
            Toggle("这段录音中只有我在讲话", isOn: $confirmedSolo)
            note("如果混入了其他人的声音，建议重新录制。")
            action("保存我的声音", emphasis: DaybookStyle.accent) {
                saveTask = Task {
                    let saved = await profile.saveRecording(url: draft.fileURL, duration: draft.duration, confirmedSolo: confirmedSolo)
                    if saved, !Task.isCancelled { recorder.discard(); preparing = false }
                }
            }.disabled(!confirmedSolo || draft.duration < 30 || draft.duration > 60.5)
            action("重新录制") { abandon(); preparing = true }
        }
    }

    private func registered(_ stored: VoiceProfile) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            hero("我的声音已登记", subtitle: "之后的录音，会尝试把你的发言标记为“我”。", symbol: "checkmark.circle", color: DaybookStyle.green)
            LabeledContent("登记时长", value: RecordingFormat.duration(stored.recordingDuration))
            LabeledContent("最近登记") { Text(stored.enrolledAt, style: .date) }
            LabeledContent("保存位置") { Text("仅此 iPhone") }
            note("只把有把握的片段标记为“我”；不确定时保留说话人标签，可手动修改。")
            action("重新录制") { preparing = true; profile.errorMessage = nil }
            action("完成", emphasis: DaybookStyle.accent, perform: close)
            Button("删除我的声音", role: .destructive) { confirmingDelete = true }.frame(minHeight: 44)
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("可以聊聊今天").font(.system(size: 12, weight: .semibold))
            note("今天准备做些什么？最近有什么让你在意的小事？按平常的语速，接着说说自己的想法。")
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(DaybookStyle.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
    private func hero(_ title: String, subtitle: String, symbol: String, color: Color = DaybookStyle.accent) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 29)).foregroundStyle(color)
                .frame(width: 64, height: 64).background(DaybookStyle.secondary.opacity(0.08), in: Circle())
            Text(LocalizedStringKey(title)).font(.system(size: 21, weight: .semibold))
            note(subtitle)
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 12)
    }
    private func note(_ text: String) -> some View {
        Text(LocalizedStringKey(text)).font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary).lineSpacing(6)
    }
    private func action(_ title: String, emphasis: Color? = nil, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Text(LocalizedStringKey(title)).frame(maxWidth: .infinity, minHeight: 44) }
            .buttonStyle(MyVoiceActionStyle(emphasis: emphasis))
    }
    private func abandon() {
        profile.cancelEnrollment(); saveTask?.cancel(); saveTask = nil
        startTask?.cancel(); startTask = nil
        recorder.discard(); confirmedSolo = false
    }
    private func close() { abandon(); dismiss() }
}

private struct MyVoiceActionStyle: ButtonStyle {
    let emphasis: Color?
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: emphasis == nil ? .regular : .medium))
            .foregroundStyle(emphasis == nil ? DaybookStyle.accent : Color.white)
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(emphasis ?? DaybookStyle.blueSoft, in: RoundedRectangle(cornerRadius: 14))
            .opacity(!isEnabled ? 0.42 : configuration.isPressed ? 0.75 : 1)
    }
}

/// Observe the child directly: NotesModel does not relay child object changes.
struct MyVoiceSettingsEntry: View {
    @ObservedObject var profile: MyVoiceProfileModel
    var open: (() -> Void)?
    var body: some View {
        Group {
            if let open {
                Button(action: open) { DaybookOptionRow(icon: "AudioLines", title: "我的声音", subtitle: profile.label) }
            } else {
                NavigationLink(value: SettingsRoute.myVoice) {
                    HStack(spacing: 10) {
                        Image(systemName: "person.wave.2").frame(width: 21)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("我的声音").font(.system(size: 12, weight: .medium))
                            Text(LocalizedStringKey(profile.label)).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }.foregroundStyle(DaybookStyle.ink).padding(16)
                }
            }
        }.onAppear { profile.reload() }
    }
}
