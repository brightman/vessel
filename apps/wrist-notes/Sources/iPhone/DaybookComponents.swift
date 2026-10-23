import SwiftUI
import ImageIO

extension DayRecord.Kind {
    var title: String { switch self { case .voice: "语音"; case .thought: "闪念"; case .image: "图片"; case .activity: "活动"; case .sleep: "睡眠"; case .calendar: "日历"; case .location: "地点" } }
    var symbol: String { switch self { case .voice: "waveform"; case .thought: "bolt"; case .image: "photo"; case .activity: "figure.walk"; case .sleep: "bed.double"; case .calendar: "calendar"; case .location: "mappin" } }
    var prototypeIcon: String { switch self { case .image: "Images"; case .activity: "Activity"; case .sleep: "Moon"; case .calendar: "CalendarDays"; case .location: "MapPin"; default: "AudioLines" } }
}

struct DaybookDateHeading: View {
    let date: Date
    let hasRecords: Bool
    let onDate: () -> Void
    private var prefix: String {
        let english = DaybookFormat.language == .english
        return Calendar.current.isDateInToday(date) ? (english ? "Today" : "今天")
            : Calendar.current.isDateInYesterday(date) ? (english ? "Yesterday" : "昨天")
            : (english ? "Review" : "回顾")
    }
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(prefix) · \(DaybookFormat.weekday(date))").font(.system(size: 11, weight: .medium))
                    .tracking(0.4).foregroundStyle(DaybookStyle.secondary)
                Text(DaybookFormat.day(date)).font(.system(size: 34, weight: .semibold))
                    .tracking(-1.5).padding(.top, 10).padding(.bottom, 7)
                Text(hasRecords ? "把值得记住的，留在今天。" : "留白，也是一天的一部分。")
                    .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
            }
            Spacer(minLength: 10)
            Button(action: onDate) {
                VStack(spacing: 0) {
                    Text(DaybookFormat.monthName(date)).font(.system(size: 9)).foregroundStyle(DaybookStyle.secondary)
                        .frame(maxWidth: .infinity).frame(height: 22)
                        .overlay(alignment: .bottom) { DaybookStyle.line.frame(height: 1) }
                    HStack(spacing: 2) {
                        Text("\(Calendar.current.component(.day, from: date))").font(.system(size: 25, weight: .medium))
                        DaybookIcon("ChevronDown", size: 10)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(width: 58, height: 65).background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(DaybookStyle.line, lineWidth: 1))
                    .shadow(color: DaybookStyle.field, radius: 0, y: 3)
            }.accessibilityLabel("选择查看日期")
        }.foregroundStyle(DaybookStyle.ink)
    }
}

struct DaybookOverview: View {
    let records: [DayRecord]
    let photoCount: Int
    let date: Date
    let now: Date
    var healthStale = false
    let onOpenRecord: (UUID) -> Void
    var onOpenPlaces: () -> Void = {}
    private var steps: Double? { records.first { $0.kind == .activity && $0.lifeMoment?.steps?.archived != true }?.metricValue }
    private var sleep: Double? { records.first { $0.kind == .sleep && ($0.lifeMoment?.sleep?.isMain ?? true) }?.metricValue }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                metric("声音", icon: "AudioLines", value: "\(Int((records.filter { $0.kind.isAudio }.reduce(0) { $0 + $1.duration } / 60).rounded()))", unit: "分钟")
                    .frame(maxWidth: .infinity, alignment: .leading)
                DaybookStyle.line.frame(width: 1, height: 43)
                metric(steps == nil ? "闪念" : "步数", icon: steps == nil ? "Lightbulb" : "Activity", value: steps.map { String(Int($0)) } ?? "\(records.filter { $0.kind == .thought }.count)", unit: steps == nil ? "条" : "步")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 18)
                DaybookStyle.line.frame(width: 1, height: 43)
                metric(sleep == nil ? "图片" : "睡眠", icon: sleep == nil ? "Images" : "Moon", value: sleep.map { String(format: "%.1f", $0 / 3600) } ?? "\(photoCount)", unit: sleep == nil ? "张" : "小时")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 18)
            }.padding(.bottom, 16)
            if steps != nil || sleep != nil {
                Text(healthStale ? "健康快照可能已过期 · 步数为当天累计" : "Apple 健康 · 步数为当天累计，不表示活动时段")
                    .font(.system(size: 9)).foregroundStyle(DaybookStyle.secondary).padding(.bottom, 10)
            }
            HStack {
                Text("一天的节奏").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(LocalizedStringKey(Calendar.current.isDateInToday(date)
                    ? (DaybookFormat.language == .english ? "As of \(DaybookFormat.time(now))" : "截至 \(DaybookFormat.time(now))")
                    : records.isEmpty ? "暂无记录" : "全天回顾"))
                    .font(.system(size: 9)).foregroundStyle(DaybookStyle.secondary)
            }.padding(.bottom, 12)
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    ForEach(0..<4) { row in
                        ZStack(alignment: .leading) {
                            DaybookStyle.field.frame(height: 2)
                            HStack { ForEach(0..<5) { i in DaybookStyle.line.frame(width: 1, height: 14); if i < 4 { Spacer() } } }
                            ForEach(records.filter { record in
                                switch row {
                                case 0: record.kind == .voice
                                case 1: record.kind == .thought
                                case 2: record.kind == .image
                                default: record.kind == .location && record.location != nil
                                }
                            }) { record in
                                let segments = record.intervals ?? [DateInterval(start: record.capturedAt, duration: max(0, record.duration))]
                                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                                    let day = LifeAggregation.dayInterval(date)
                                    let start = max(0, min(1, segment.start.timeIntervalSince(day.start) / day.duration))
                                    let length = min(1 - start, max(0.0075, segment.duration / day.duration))
                                    Button { if record.kind == .location { onOpenPlaces() } else { onOpenRecord(record.id) } } label: {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(record.kind == .image || record.kind == .location ? DaybookStyle.green : DaybookStyle.accent)
                                            .frame(width: max(7, geometry.size.width * length), height: 10)
                                    }.offset(x: geometry.size.width * start)
                                        .accessibilityLabel("\(DaybookFormat.time(segment.start)) \(record.title)")
                                }
                            }
                        }.frame(height: 14)
                            .overlay { if row == 3 { Button(action: onOpenPlaces) { Color.clear.contentShape(Rectangle()) }.accessibilityLabel("查看当天地点") } }
                            .offset(y: CGFloat(row) * 19 + 2)
                    }
                    if Calendar.current.isDateInToday(date) && !records.isEmpty {
                        Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: 76)) }
                            .stroke(DaybookStyle.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .offset(x: geometry.size.width * max(0, min(1, now.timeIntervalSince(LifeAggregation.dayInterval(date).start) / LifeAggregation.dayInterval(date).duration)))
                    }
                }
            }.frame(height: 76)
            HStack {
                ForEach(0..<5) { tick in
                    Text(rhythmTick(tick)).font(.system(size: 9)).monospacedDigit().tracking(0.4)
                    if tick != 4 { Spacer() }
                }
            }.foregroundStyle(DaybookStyle.secondary).padding(.top, 3)
            Text(records.isEmpty ? "上至下：语音 · 闪念 · 图片 · 地点，有记录的时段会出现在这里。" : "上至下：语音 · 闪念 · 图片 · 地点，点击片段回看。")
                .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 9)
            let places = records.filter { $0.kind == .location && $0.location != nil }
            if !places.isEmpty {
                Button(action: onOpenPlaces) {
                    HStack(spacing: 6) {
                        DaybookIcon("MapPin", size: 14)
                        Text("地点 · \(places.count) 条记录")
                        Spacer()
                        DaybookIcon("ChevronRight", size: 12)
                    }.font(.system(size: 11)).foregroundStyle(DaybookStyle.green).padding(.vertical, 13)
                }
            }
        }
    }
    private func rhythmTick(_ tick: Int) -> String {
        guard tick != 4 else { return "24" }
        let day = LifeAggregation.dayInterval(date)
        let value = day.start.addingTimeInterval(day.duration * Double(tick) / 4)
        let components = Calendar.current.dateComponents([.hour, .minute], from: value)
        let hour = components.hour ?? 0, minute = components.minute ?? 0
        return minute == 0 ? String(format: "%02d", hour) : String(format: "%02d:%02d", hour, minute)
    }
    private func metric(_ label: String, icon: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) { DaybookIcon(icon, size: 12); Text(LocalizedStringKey(label)).font(.system(size: 10)) }.foregroundStyle(DaybookStyle.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 21, weight: .semibold)).tracking(-0.5).monospacedDigit().foregroundStyle(DaybookStyle.ink)
                if !unit.isEmpty { Text(LocalizedStringKey(unit)).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary) }
            }
        }
    }
}

struct DaybookRecordRow: View {
    let record: DayRecord
    var thumbnails: [URL] = []
    var photoCount = 0
    var status: String? = nil
    var showsMergeSelection = false
    var isMergeSelected = false
    private var isCompleteRecording: Bool { record.recordingSessionID != nil && record.contentProvenance == nil }
    @ViewBuilder private var displayTitle: some View {
        if isCompleteRecording { Text("完整录音") }
        else if record.kind == .location && record.location != nil && record.location?.address == nil { Text("地点待解析") }
        else { Text(record.title) }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(record.lifeMoment?.sleep?.endedAt == nil && record.lifeMoment?.sleep != nil ? "—" : DaybookFormat.time(record.capturedAt))
                    .font(.system(size: 10)).monospacedDigit().tracking(-0.3)
                if record.lifeMoment?.steps?.archived == true { Text("归档").font(.system(size: 9)) }
            }.foregroundStyle(DaybookStyle.secondary).frame(width: 41, alignment: .leading).padding(.top, 3)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    displayTitle.font(.system(size: 14, weight: .semibold)).lineSpacing(4).lineLimit(2)
                    Spacer(minLength: 0)
                    if showsMergeSelection {
                        Image(systemName: isMergeSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(isMergeSelected ? DaybookStyle.accent : DaybookStyle.secondary)
                            .padding(.leading, 4)
                    } else { DaybookIcon("ChevronRight", size: 13).foregroundStyle(DaybookStyle.secondary) }
                }.padding(.bottom, 5)
                Group {
                    if isCompleteRecording { Text(LocalizedStringKey(status ?? "")) }
                    else if record.kind.isAudio, !record.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(record.summary).accessibilityIdentifier("daybook.record.summary.\(record.id.uuidString)")
                    }
                    else if record.contentProvenance != nil { Text("摘要尚未生成") }
                    else { Text(record.kind == .location ? (record.location?.source.label ?? record.text)
                        : record.text.isEmpty ? (status ?? "") : String(record.text.prefix(240))) }
                }
                    .font(.system(size: 12)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary).lineLimit(2)
                if !thumbnails.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(thumbnails.prefix(3), id: \.self) { url in
                            DaybookThumbnail(url: url).frame(width: 68, height: 62).clipped().clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                        if photoCount > 3 { Text("+\(photoCount - 3)").font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary) }
                    }.padding(.top, 11)
                }
                HStack(spacing: 9) {
                    HStack(spacing: 3) { DaybookIcon(record.kind.prototypeIcon, size: 11); Text(LocalizedStringKey(record.kind.title)) }
                    Text(record.kind == .image ? (DaybookFormat.language == .english ? "\(photoCount) photos" : "\(photoCount) 张照片") : record.kind.isAudio ? DaybookFormat.duration(record.duration) : record.lifeMoment?.movement != nil ? (DaybookFormat.language == .english ? "2 source records" : "两条地点依据") : "本机快照")
                    if let device = record.captureDevice { Text(device) }
                    if record.kind == .thought { Text("闪念") }
                    if isCompleteRecording { Text(LocalizedStringKey(record.recordingContinuation == true ? "续段 · 当日范围" : "当日范围")) }
                }.font(.system(size: 9)).foregroundStyle(DaybookStyle.secondary).padding(.top, 8)
                if let point = record.location, record.kind != .location {
                    CapturePlaceRow(point: point).padding(.top, 9)
                }
            }.padding(.leading, 14).padding(.bottom, 23)
                .overlay(alignment: .leading) { DaybookStyle.line.frame(width: 1) }
                .overlay(alignment: .topLeading) {
                    Circle().fill(record.kind == .image ? DaybookStyle.green : DaybookStyle.accent)
                        .frame(width: 5, height: 5).padding(3).background(DaybookStyle.paper, in: Circle()).offset(x: -5, y: 2)
                }
        }.foregroundStyle(DaybookStyle.ink).contentShape(Rectangle())
    }
}

/// Keeps the prototype's ungrouped timeline while preserving swipe-to-delete.
struct DaybookSwipeRow<Content: View>: View {
    let id: UUID
    @Binding var revealedID: UUID?
    let onDelete: () -> Void
    var onSelect: (() -> Void)? = nil
    var isSelected = false
    @ViewBuilder var content: Content
    @State private var translation: CGFloat = 0
    @State private var horizontalDrag: Bool?
    @State private var revealedOffset: CGFloat = -76
    private let actionWidth: CGFloat = 76
    private var offset: CGFloat {
        let leadingLimit = onSelect == nil ? 0 : actionWidth
        return min(leadingLimit, max(-actionWidth, (revealedID == id ? revealedOffset : 0) + translation))
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if offset > 0 { selectButton }
                Spacer(minLength: 0)
                if offset < 0 { deleteButton }
            }
            content.frame(maxWidth: .infinity, alignment: .leading).background(DaybookStyle.paper).offset(x: offset)
        }.clipped()
            // Give horizontal drags priority over the row's Button tap recognizer.
            // A simultaneous gesture can treat the drag release as a tap and close the action.
            .highPriorityGesture(DragGesture(minimumDistance: 20)
                .onChanged { value in
                    if horizontalDrag == nil { horizontalDrag = abs(value.translation.width) > abs(value.translation.height) * 1.5 }
                    if horizontalDrag == true { translation = value.translation.width }
                }
                .onEnded { value in
                    if horizontalDrag == true {
                        let projected = (revealedID == id ? revealedOffset : 0) + value.predictedEndTranslation.width
                        withAnimation(.easeOut(duration: 0.18)) {
                            if onSelect != nil && projected > actionWidth / 2 {
                                revealedID = id; revealedOffset = actionWidth
                            } else if projected < -actionWidth / 2 {
                                revealedID = id; revealedOffset = -actionWidth
                            } else {
                                revealedID = nil
                            }
                            translation = 0
                        }
                    }
                    translation = 0; horizontalDrag = nil
                })
            .onChange(of: revealedID) { _, _ in translation = 0 }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            revealedID = nil; onDelete()
        } label: {
            Text("删除").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                .frame(width: actionWidth).frame(maxHeight: .infinity)
                .background(DaybookStyle.red, in: RoundedRectangle(cornerRadius: 12))
        }.allowsHitTesting(revealedID == id)
            .accessibilityHidden(revealedID != id).padding(.bottom, 12)
    }

    private var selectButton: some View {
        Button {
            revealedID = nil
            onSelect?()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 17, weight: .medium))
                Text(isSelected ? "已选择" : "选择").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white).frame(width: actionWidth).frame(maxHeight: .infinity)
            .background(DaybookStyle.accent, in: RoundedRectangle(cornerRadius: 12))
        }.allowsHitTesting(revealedID == id && onSelect != nil)
            .accessibilityHidden(revealedID != id || onSelect == nil).padding(.bottom, 12)
    }
}

struct DaybookThumbnail: View {
    let url: URL
    @State private var thumbnail: UIImage?
    var body: some View {
        Group {
            if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
            else { Rectangle().fill(DaybookStyle.field).overlay(DaybookIcon("Images")) }
        }.task(id: url) {
            thumbnail = nil
            let work = Task.detached(priority: .utility) { () -> UIImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 320
                      ] as CFDictionary) else { return nil }
                return UIImage(cgImage: image)
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }; thumbnail = result
        }.accessibilityLabel("照片缩略图")
    }
}

struct DaybookCaptureMenu: View {
    let voice: () -> Void
    let image: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        DaybookSheetLayout(title: "记此刻", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 0) {
                Text("说出一个想法，或留住眼前的画面。")
                    .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary).padding(.top, 6).padding(.bottom, 20)
                Button(action: voice) { DaybookOptionRow(icon: "Mic", title: "语音", subtitle: "记下闪念、对话和此刻的感受。") }
                Button(action: image) { DaybookOptionRow(icon: "Images", title: "图片", subtitle: "拍一张照片，或从相册选择。") }
                Text("录音与图片保存在本机，转写和文字识别在设备上完成。")
                    .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary).lineSpacing(6).padding(.top, 18)
            }
        }.presentationDetents([.height(350)])
    }
}

struct DaybookOptionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 15) {
            DaybookIcon(icon, size: 24).foregroundStyle(DaybookStyle.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title)).font(.system(size: 14, weight: .semibold)).foregroundStyle(DaybookStyle.ink)
                Text(LocalizedStringKey(subtitle)).font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary).lineSpacing(4)
            }.frame(maxWidth: .infinity, alignment: .leading)
            DaybookIcon("ChevronRight", size: 16).foregroundStyle(DaybookStyle.accent)
        }.padding(.vertical, 19).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { DaybookStyle.line.frame(height: 1) }.contentShape(Rectangle())
    }
}

struct DaybookEmptyView: View {
    let title: String
    let text: String
    var icon = "BookOpen"
    var body: some View {
        VStack(spacing: 9) {
            DaybookIcon(icon, size: 32).foregroundStyle(DaybookStyle.accent.opacity(0.7)).padding(.bottom, 3)
            Text(LocalizedStringKey(title)).font(.system(size: 15, weight: .semibold)).foregroundStyle(DaybookStyle.ink)
            Text(LocalizedStringKey(text)).font(.system(size: 11)).lineSpacing(6).multilineTextAlignment(.center)
                .foregroundStyle(DaybookStyle.secondary).frame(maxWidth: 250)
        }.padding(.vertical, 34).padding(.horizontal, 10).frame(maxWidth: .infinity)
    }
}

struct DaybookQuietInfo: View {
    var icon = "CircleHelp"
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            DaybookIcon(icon, size: 16).padding(.top, 3)
            Text(LocalizedStringKey(text)).font(.system(size: 11)).lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading)
        }.foregroundStyle(DaybookStyle.secondary).padding(.vertical, 28)
    }
}

enum DaybookFormat {
    static var language: AppLanguage { AppLanguage(rawValue: UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "") ?? .chinese }
    private static var locale: Locale { language.locale }
    static func day(_ date: Date) -> String { date.formatted(.dateTime.locale(locale).month().day()) }
    static func weekday(_ date: Date) -> String { date.formatted(.dateTime.locale(locale).weekday(.wide)) }
    static func time(_ date: Date) -> String { date.formatted(.dateTime.locale(Locale(identifier: "en_GB")).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
    static func monthName(_ date: Date) -> String { date.formatted(.dateTime.locale(locale).month(.abbreviated)) }
    static func dayFraction(_ date: Date) -> Double {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let hourSeconds: Int = (parts.hour ?? 0) * 3600
        let minuteSeconds: Int = (parts.minute ?? 0) * 60
        let seconds: Int = parts.second ?? 0
        return Double(hourSeconds + minuteSeconds + seconds) / 86400.0
    }
    static func duration(_ seconds: TimeInterval) -> String {
        RecordingFormat.duration(seconds, language: language.rawValue)
    }
}
