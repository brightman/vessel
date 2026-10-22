import AppIntents
import SwiftUI
import WidgetKit

private struct QuickRecordingEntry: TimelineEntry {
    let date: Date
}

private struct QuickRecordingProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickRecordingEntry {
        QuickRecordingEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickRecordingEntry) -> Void) {
        completion(QuickRecordingEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickRecordingEntry>) -> Void) {
        completion(Timeline(entries: [QuickRecordingEntry(date: .now)], policy: .never))
    }
}

struct QuickRecordingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WiseLifeQuickRecording", provider: QuickRecordingProvider()) { _ in
            Button(intent: StartWiseLifeRecordingIntent()) {
                Image(systemName: "mic.fill")
                    .font(.title2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("开始录音"))
            .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        }
        .configurationDisplayName("快捷录音")
        .description("轻点开始录音，通过实时活动停止并保存。")
        .supportedFamilies([.accessoryCircular])
    }
}
