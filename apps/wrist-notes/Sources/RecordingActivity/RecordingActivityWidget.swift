import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct WiseLifeRecordingWidgets: WidgetBundle {
    var body: some Widget {
        WiseLifeRecordingActivity()
        QuickRecordingWidget()
    }
}

struct WiseLifeRecordingActivity: Widget {
    @Environment(\.locale) private var locale
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack(spacing: 16) {
                Image(systemName: "waveform").foregroundStyle(.red)
                VStack(alignment: .leading) {
                    Text(LocalizedStringKey(status(context.state.phase))).font(.headline)
                    elapsed(context).font(.title2.monospacedDigit())
                }
                Spacer()
                stop(context)
            }
            .padding()
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
            .foregroundStyle(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("WiseLife 录音", systemImage: "waveform").foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.trailing) { elapsed(context) }
                DynamicIslandExpandedRegion(.bottom) { stop(context) }
            } compactLeading: {
                Image(systemName: "waveform").foregroundStyle(.red)
            } compactTrailing: {
                elapsed(context).font(.system(size: 9).monospacedDigit()).frame(width: 86)
            } minimal: {
                Image(systemName: "waveform").foregroundStyle(.red)
            }
        }
    }

    private func elapsed(_ context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
        Text(.currentDate, format: RecordingElapsedFormatStyle(startedAt: context.attributes.startedAt,
            language: String(locale.identifier.prefix(2))))
            .lineLimit(1).minimumScaleFactor(0.65)
    }

    @ViewBuilder
    private func stop(_ context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
        if context.state.phase == .recording {
            Button(intent: StopWiseLifeRecordingIntent(sessionID: context.attributes.sessionID.uuidString)) {
                Label("停止并保存", systemImage: "stop.fill")
            }.tint(.red)
        }
    }

    private func status(_ phase: RecordingActivityAttributes.ContentState.Phase) -> String {
        switch phase {
        case .recording: "正在录音"
        case .saved: "录音已保存"
        case .failed: "录音待保存"
        }
    }
}
