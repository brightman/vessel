import SwiftUI

struct CapturePlaceRow: View {
    let point: CaptureLocation
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            DaybookIcon("MapPin", size: 13)
            VStack(alignment: .leading, spacing: 4) {
                (point.address.map { Text($0.text) } ?? Text("地点待解析")).lineLimit(2)
                Text(LocalizedStringKey(point.source.label)).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
            }
        }.font(.system(size: 12)).foregroundStyle(DaybookStyle.green)
    }
}

struct CapturePlaceDetails: View {
    let point: CaptureLocation
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CapturePlaceRow(point: point)
            if point.address == nil {
                Text("地址尚未解析，联网后再次查看可补齐。原始坐标已保存在本机。")
            }
            Text("坐标：\(point.title)").monospacedDigit()
            if let date = point.measuredAt {
                Text("地点时间：\(date.formatted(.dateTime.year().month().day().hour().minute()))")
            }
            if let accuracy = point.accuracy { Text("精度约 \(String(format: "%.0f", accuracy)) 米") }
        }.font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(DaybookStyle.field, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct DaybookPlacesView: View {
    let records: [DayRecord]
    let date: Date
    let onOpen: (UUID) -> Void
    let onClose: () -> Void
    var body: some View {
        DaybookSheetLayout(title: "当天的地点", onClose: onClose) {
            VStack(alignment: .leading, spacing: 20) {
                Text("\(DaybookFormat.day(date)) · \(records.count) 条地点记录")
                    .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
                if records.isEmpty { Text("这一天还没有地点记录。").font(.system(size: 13)) }
                ForEach(records) { record in
                    Button { onOpen(record.id) } label: {
                        HStack(alignment: .top, spacing: 14) {
                            Text(DaybookFormat.time(record.capturedAt)).monospacedDigit().font(.system(size: 11))
                            VStack(alignment: .leading, spacing: 7) {
                                if let point = record.location { CapturePlaceRow(point: point) }
                                else { Text(record.title).font(.system(size: 13)) }
                                if let device = record.captureDevice { Text(device).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            DaybookIcon("ChevronRight", size: 14)
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Text("只展示记录时的地点，不代表连续行程或停留时长。")
                    .font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
            }
        }
    }
}

struct DaybookPlaceDetailView: View {
    let record: DayRecord
    let onOpenParent: (UUID) -> Void
    let onClose: () -> Void
    var body: some View {
        DaybookSheetLayout(title: "地点详情", onClose: onClose) {
            VStack(alignment: .leading, spacing: 20) {
                Text(record.capturedAt.formatted(.dateTime.year().month().day().hour().minute())).font(.system(size: 12))
                if let point = record.location { CapturePlaceDetails(point: point) }
                if let device = record.captureDevice { LabeledContent("采集设备", value: device).font(.system(size: 13)) }
                if let parent = record.parentRecordID {
                    Button("查看关联记录") { onOpenParent(parent) }.buttonStyle(DaybookPrimaryButtonStyle(wide: true))
                }
                Text("地点随关联录音或图片保存在本机，删除原记录时一起移除。")
                    .font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
            }
        }
    }
}
