import SwiftUI
import ImageIO

extension DayRecord.Kind {
    var title: String { switch self { case .voice: "语音"; case .thought: "闪念"; case .image: "图片" } }
    var symbol: String { switch self { case .voice: "waveform"; case .thought: "bolt"; case .image: "photo" } }
    var prototypeIcon: String { self == .image ? "Images" : "AudioLines" }
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
    let onOpenRecord: (UUID) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                metric("声音", icon: "AudioLines", value: "\(Int((records.reduce(0) { $0 + $1.duration } / 60).rounded()))", unit: "分钟")
                    .frame(maxWidth: .infinity, alignment: .leading)
                DaybookStyle.line.frame(width: 1, height: 43)
                metric("闪念", icon: "Lightbulb", value: "\(records.filter { $0.kind == .thought }.count)", unit: "条")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 18)
                DaybookStyle.line.frame(width: 1, height: 43)
                metric("图片", icon: "Images", value: "\(photoCount)", unit: "张")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 18)
            }.padding(.bottom, 16)
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
                    ForEach(0..<3) { row in
                        ZStack(alignment: .leading) {
                            DaybookStyle.field.frame(height: 2)
                            HStack { ForEach(0..<5) { i in DaybookStyle.line.frame(width: 1, height: 14); if i < 4 { Spacer() } } }
                            ForEach(records.filter { record in
                                switch row {
                                case 0: record.kind == .voice
                                case 1: record.kind == .thought
                                default: record.kind == .image
                                }
                            }) { record in
                                let start = DaybookFormat.dayFraction(record.capturedAt)
                                let length = min(1 - start, max(0.0075, record.duration / 86400))
                                Button { onOpenRecord(record.id) } label: {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(record.kind == .image ? DaybookStyle.green : DaybookStyle.accent)
                                        .frame(width: max(7, geometry.size.width * length), height: 10)
                                }.offset(x: geometry.size.width * start)
                                    .accessibilityLabel("\(DaybookFormat.time(record.capturedAt)) \(record.title)")
                            }
                        }.frame(height: 14).offset(y: CGFloat(row) * 19 + 2)
                    }
                    if Calendar.current.isDateInToday(date) && !records.isEmpty {
                        Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: 57)) }
                            .stroke(DaybookStyle.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .offset(x: geometry.size.width * DaybookFormat.dayFraction(now))
                    }
                }
            }.frame(height: 57)
            HStack {
                ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                    Text(String(format: "%02d", hour)).font(.system(size: 9)).monospacedDigit().tracking(0.4)
                    if hour != 24 { Spacer() }
                }
            }.foregroundStyle(DaybookStyle.secondary).padding(.top, 3)
            Text(records.isEmpty ? "上至下：语音 · 闪念 · 图片，有记录的时段会出现在这里。" : "上至下：语音 · 闪念 · 图片，点击片段回看。")
                .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 9)
        }
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
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(DaybookFormat.time(record.capturedAt)).font(.system(size: 10)).monospacedDigit()
                .tracking(-0.3).foregroundStyle(DaybookStyle.secondary).frame(width: 41, alignment: .leading).padding(.top, 3)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(record.title).font(.system(size: 14, weight: .semibold)).lineSpacing(4).lineLimit(2)
                    Spacer(minLength: 0); DaybookIcon("ChevronRight", size: 13).foregroundStyle(DaybookStyle.secondary)
                }.padding(.bottom, 5)
                Text(record.text.isEmpty ? (status ?? "") : record.text)
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
                    HStack(spacing: 3) { DaybookIcon(record.kind.prototypeIcon, size: 11); Text(LocalizedStringKey(record.kind == .image ? "图片记录" : "语音记录")) }
                    Text(record.kind == .image ? (DaybookFormat.language == .english ? "\(photoCount) photos" : "\(photoCount) 张照片") : DaybookFormat.duration(record.duration))
                    if record.kind == .thought { Text("闪念") }
                }.font(.system(size: 9)).foregroundStyle(DaybookStyle.secondary).padding(.top, 8)
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
    @ViewBuilder var content: Content
    @State private var translation: CGFloat = 0
    @State private var horizontalDrag: Bool?
    private let actionWidth: CGFloat = 76
    private var offset: CGFloat { min(0, max(-actionWidth, (revealedID == id ? -actionWidth : 0) + translation)) }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive) {
                revealedID = nil; onDelete()
            } label: {
                Text("删除").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .frame(width: actionWidth).frame(maxHeight: .infinity)
                    .background(DaybookStyle.red, in: RoundedRectangle(cornerRadius: 12))
            }.opacity(offset < 0 ? 1 : 0).allowsHitTesting(revealedID == id)
                .accessibilityHidden(revealedID != id).padding(.bottom, 12)
            content.frame(maxWidth: .infinity, alignment: .leading).background(DaybookStyle.paper).offset(x: offset)
        }.clipped()
            .simultaneousGesture(DragGesture(minimumDistance: 20)
                .onChanged { value in
                    if horizontalDrag == nil { horizontalDrag = abs(value.translation.width) > abs(value.translation.height) * 1.5 }
                    if horizontalDrag == true { translation = value.translation.width }
                }
                .onEnded { value in
                    if horizontalDrag == true {
                        let projected = (revealedID == id ? -actionWidth : 0) + value.predictedEndTranslation.width
                        withAnimation(.easeOut(duration: 0.18)) { revealedID = projected < -actionWidth / 2 ? id : nil; translation = 0 }
                    }
                    translation = 0; horizontalDrag = nil
                })
            .onChange(of: revealedID) { _, _ in translation = 0 }
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
        let value = Int(max(0, seconds)), minute = value / 60, second = value % 60
        if language == .english { return minute > 0 ? "\(minute)m" + (second == 0 ? "" : " \(second)s") : "\(second)s" }
        return minute > 0 ? "\(minute) 分" + (second == 0 ? "钟" : " \(second) 秒") : "\(second) 秒"
    }
}
