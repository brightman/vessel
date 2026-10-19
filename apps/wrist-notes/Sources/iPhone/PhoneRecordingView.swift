import SwiftUI

struct PhoneRecordingView: View {
    @ObservedObject var recorder: PhoneRecorder
    @EnvironmentObject private var model: NotesModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false
    let onSaved: (Date) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 27) {
                Spacer()
                Image(systemName: "waveform").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(NotesStyle.red)
                Text(recorder.draft != nil ? "录音已结束" : recorder.isRecording ? "正在录音" : "说出这一刻")
                    .font(.title2.weight(.semibold))
                Text(RecordingFormat.duration(recorder.duration)).font(.system(size: 44, weight: .light, design: .rounded).monospacedDigit())
                if let error = recorder.errorMessage { Text(error).font(.callout).foregroundStyle(NotesStyle.warning).multilineTextAlignment(.center) }
                if recorder.draft != nil {
                    Button("保存录音") {
                        if let draft = recorder.draft, model.savePhoneRecording(id: draft.id, fileURL: draft.fileURL,
                            capturedAt: draft.capturedAt, duration: draft.duration) {
                            recorder.didSave(); dismiss(); onSaved(draft.capturedAt)
                        }
                    }.buttonStyle(.borderedProminent).tint(NotesStyle.red)
                } else {
                    Button {
                        if recorder.isRecording { recorder.stop() }
                        else { Task { await recorder.start() } }
                    } label: {
                        ZStack {
                            Circle().stroke(NotesStyle.red.opacity(0.3), lineWidth: 2).frame(width: 88, height: 88)
                            if recorder.requestingPermission { ProgressView() }
                            else if recorder.isRecording { RoundedRectangle(cornerRadius: 8).fill(NotesStyle.red).frame(width: 35, height: 35) }
                            else { Circle().fill(NotesStyle.red).frame(width: 70, height: 70) }
                        }
                    }.disabled(recorder.requestingPermission)
                        .accessibilityLabel(recorder.isRecording ? "结束录音" : "开始录音")
                }
                Text("录音保存在本机，保存后使用已选择的模型转写。")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }.padding(28).frame(maxWidth: .infinity).background(NotesStyle.background)
                .navigationTitle("语音").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if recorder.isRecording || recorder.draft != nil { confirmDiscard = true }
                        else { recorder.discard(); dismiss() }
                    }
                } }
                .confirmationDialog("放弃这段录音？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("放弃录音", role: .destructive) { recorder.discard(); dismiss() }
                }
                .interactiveDismissDisabled(recorder.isRecording || recorder.requestingPermission || recorder.draft != nil)
                .alert("保存未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                    Button("好") { model.errorMessage = nil }
                } message: { Text(model.errorMessage ?? "") }
        }
    }
}
