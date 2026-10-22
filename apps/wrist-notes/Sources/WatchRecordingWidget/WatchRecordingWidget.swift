import SwiftUI
import WidgetKit

private struct RecordingEntry: TimelineEntry {
    let date: Date
}

private struct RecordingProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordingEntry { RecordingEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (RecordingEntry) -> Void) {
        completion(RecordingEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordingEntry>) -> Void) {
        // This is an entry point, not a cached assertion that a recording is running.
        completion(Timeline(entries: [RecordingEntry(date: .now)], policy: .never))
    }
}

@main
struct WiseLifeWatchRecordingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WiseLifeWatchQuickRecording", provider: RecordingProvider()) { _ in
            RecordingComplicationView()
                .widgetURL(WatchRecordingLink.url)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("WiseLife 录音")
        .description("轻点开始录音；录音中轻点返回，停止并保存请使用 App 内按钮。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

private struct RecordingComplicationView: View {
    @Environment(\.widgetFamily) private var family
    private let recordingRed = Color(red: 0.96, green: 0.17, blue: 0.21)

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("WiseLife 快捷录音"))
            .accessibilityHint(Text("未录音时开始录音，录音中返回 App。"))
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            Label("录音", systemImage: "mic.fill")
        case .accessoryRectangular:
            HStack(spacing: 7) {
                microphone.font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WiseLife").font(.headline).widgetAccentable()
                    Text("快捷录音").font(.caption)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
        case .accessoryCorner:
            microphone.font(.title2)
                .widgetLabel { Text("录音") }
        default:
            ZStack {
                AccessoryWidgetBackground()
                microphone.font(.title2)
            }
        }
    }

    private var microphone: some View {
        Image(systemName: "mic.fill")
            .foregroundStyle(recordingRed)
            .widgetAccentable()
    }
}
