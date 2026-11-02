import SwiftUI

/// Used by both the home timeline and My Records. Each result owns its tap target.
struct FlashTimelineRow: View {
    let record: DayRecord
    let group: FlashTimelineGroup
    let onAction: (UUID) -> Void
    let onAsset: (UUID) -> Void
    let onSource: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(DaybookFormat.time(record.capturedAt)).font(.system(size: 10)).monospacedDigit()
                Text("录下").font(.system(size: 8))
            }.foregroundStyle(DaybookStyle.secondary).frame(width: 41, alignment: .leading).padding(.top, 4)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.commands) { item in
                    Button { onAction(item.id) } label: { FlashCommandRow(item: item) }
                        .accessibilityIdentifier("flash.timeline.action.\(item.id.uuidString)")
                    DaybookStyle.line.frame(height: 0.5)
                }
                ForEach(group.assets) { item in
                    Button { onAsset(item.id) } label: { assetRow(item) }
                        .accessibilityIdentifier("flash.timeline.asset.\(item.id.uuidString)")
                    DaybookStyle.line.frame(height: 0.5)
                }
                Button(action: onSource) {
                    HStack(spacing: 5) {
                        DaybookIcon("AudioLines", size: 12)
                        Text(record.captureDevice == "Apple Watch" ? "Watch" : record.captureDevice ?? "录音")
                        Text(audioDuration).monospacedDigit()
                        Spacer(minLength: 5)
                        Text("原话与录音").foregroundStyle(DaybookStyle.accent)
                        DaybookIcon("ChevronRight", size: 11)
                    }.font(.system(size: 9)).foregroundStyle(DaybookStyle.secondary)
                        .frame(minHeight: 40).contentShape(Rectangle())
                }.accessibilityIdentifier("flash.timeline.source.\(record.id.uuidString)")
                if let location = record.location { CapturePlaceRow(point: location).padding(.bottom, 8) }
            }.padding(.leading, 14)
                .overlay(alignment: .leading) { DaybookStyle.line.frame(width: 1) }
                .overlay(alignment: .topLeading) {
                    Circle().fill(DaybookStyle.accent).frame(width: 5, height: 5).padding(3)
                        .background(DaybookStyle.paper, in: Circle()).offset(x: -5, y: 3)
                }
        }.buttonStyle(.plain).foregroundStyle(DaybookStyle.ink).padding(.bottom, 23)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("flash.timeline.group.\(record.id.uuidString)")
    }
    private var audioDuration: String {
        let seconds = record.duration.isFinite ? Int(max(0, record.duration)) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private func assetRow(_ item: FlashAsset) -> some View {
        HStack(alignment: .top, spacing: 8) {
            DaybookIcon(item.kind == .idea ? "Lightbulb" : "NotebookPen", size: 16)
                .foregroundStyle(DaybookStyle.accent).frame(width: 21, height: 23)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.kind == .idea ? "想法" : "记账")
                    Spacer(minLength: 0)
                    Text(item.statusTitle).font(.system(size: 9))
                        .foregroundStyle(item.revoked ? DaybookStyle.secondary : item.ready ? DaybookStyle.green : DaybookStyle.red)
                }.font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                Text(item.kind == .idea ? item.text : "\(item.title) · \(item.amountText)")
                    .font(.system(size: item.kind == .idea ? 12 : 13, weight: item.kind == .idea ? .regular : .semibold))
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(item.revoked ? DaybookStyle.secondary : DaybookStyle.ink)
                if item.kind == .expense {
                    Text(item.ready ? "\(item.category ?? "未分类") · \(item.date ?? "")" : "信息待补充 · 未计入账目")
                        .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                }
            }
            DaybookIcon("ChevronRight", size: 11).foregroundStyle(DaybookStyle.secondary).padding(.top, 27)
        }.padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

struct FlashCommandRow: View {
    let item: ActionItem
    var showsChevron = true
    private var state: FlashCommandState { FlashCommandState(item: item) }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            DaybookIcon(item.kind.icon, size: 16).foregroundStyle(DaybookStyle.accent).frame(width: 21, height: 23)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.kind.title)
                    Spacer(minLength: 0)
                    Text(state.title).font(.system(size: 9))
                        .foregroundStyle(state.needsAttention ? DaybookStyle.red : state.succeeded ? DaybookStyle.green : DaybookStyle.secondary)
                }.font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineSpacing(4)
                    .foregroundStyle(state == .revoked ? DaybookStyle.secondary : DaybookStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(schedule).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary).monospacedDigit()
                if state.needsAttention, let error = item.syncError {
                    Text(error).font(.system(size: 10)).foregroundStyle(DaybookStyle.red).lineSpacing(3)
                } else if state == .created && item.kind == .todo {
                    Text("待完成").font(.system(size: 9)).foregroundStyle(DaybookStyle.secondary)
                }
            }
            if showsChevron { DaybookIcon("ChevronRight", size: 11).foregroundStyle(DaybookStyle.secondary).padding(.top, 27) }
        }.padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    private var schedule: String {
        guard let start = item.start else { return item.kind == .todo ? "未设截止时间" : "补充时间后安排" }
        let formatter = DateFormatter()
        formatter.locale = DaybookFormat.language.locale
        formatter.timeZone = TimeZone(identifier: item.timeZoneID) ?? .current
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = formatter.timeZone
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: .now)
        formatter.setLocalizedDateFormatFromTemplate((sameYear ? "MMMd" : "yyyyMMMd") + (item.allDay ? "" : " HHmm"))
        let text = (item.kind == .todo ? "截止 " : "") + formatter.string(from: start)
        guard item.kind == .event, let end = item.end else { return text }
        if !item.allDay && calendar.isDate(start, inSameDayAs: end) { formatter.dateFormat = "HH:mm" }
        return text + "–" + formatter.string(from: end)
    }
}

struct FlashActionDetailView: View {
    @ObservedObject var store: ActionStore
    let id: UUID
    let onOpenSource: (ActionSource) -> Void
    let onClose: () -> Void
    @State private var editing: ActionItem?
    private var item: ActionItem? { store.flashTimelineItems.first { $0.id == id } }
    var body: some View {
        DaybookSheetLayout(title: item?.kind.title ?? "行动", onClose: onClose) {
            if let item {
                let state = FlashCommandState(item: item)
                VStack(alignment: .leading, spacing: 18) {
                    FlashCommandRow(item: item, showsChevron: false)
                    Text("时间按 \(item.timeZoneID) 显示").font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                    if !item.deleted && state != .revoked {
                        HStack(spacing: 22) {
                            if item.status != .cancelled && item.operation != .delete {
                                Button(state == .needsDetails ? "补充信息" : "编辑") { editing = item }
                                    .accessibilityIdentifier("flash.action.edit")
                            }
                            if item.sync == .failed || item.sync == .pending {
                                Button("重试") { Task { _ = await store.retry(item) } }
                            }
                            if item.status != .cancelled && item.operation != .delete {
                                Button("撤销") { Task { _ = await store.setStatus(item, .cancelled) } }
                                    .accessibilityIdentifier("flash.action.revoke")
                            }
                        }.font(.system(size: 13, weight: .medium)).foregroundStyle(DaybookStyle.accent).disabled(store.busy)
                        if item.kind == .todo && [.created, .completed].contains(state) {
                            Button(item.status == .completed ? "恢复为未完成" : "标记已完成") {
                                Task { _ = await store.setStatus(item, item.status == .completed ? .active : .completed) }
                            }.font(.system(size: 13)).foregroundStyle(DaybookStyle.accent).disabled(store.busy)
                                .accessibilityIdentifier("flash.action.complete")
                        }
                    } else {
                        Text("已停止此项行动，原话仍保留，不会再次自动创建。")
                            .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
                    }
                    if let source = item.source {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("原话依据").font(.system(size: 12, weight: .medium))
                            Text(source.quote).font(.system(size: 13)).lineSpacing(6)
                            Text(RecordingFormat.date(source.capturedAt) + (source.device.map { " · " + $0 } ?? ""))
                                .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                            Button("原话与录音") { onOpenSource(source) }.font(.system(size: 12)).foregroundStyle(DaybookStyle.accent)
                        }.daybookRecordingCard(padding: 14)
                    }
                    if let error = store.error { Text(error).font(.system(size: 12)).foregroundStyle(DaybookStyle.red) }
                }.padding(.top, 10)
            } else { DaybookQuietInfo(text: "这项行动暂不可用，请返回查看。") }
        }.sheet(item: $editing) { ActionEditor(store: store, item: $0) }
    }
}
