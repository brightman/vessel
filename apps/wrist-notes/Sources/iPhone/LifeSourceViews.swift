import SwiftUI
import UIKit

struct LifeSourceSheet: View {
    @ObservedObject var model: LifeSourceModel
    let source: LifeSource
    let day: Date
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL
    var body: some View {
        DaybookSheetLayout(title: source.title, onClose: onClose) {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("启用此来源", isOn: Binding(get: { model.isEnabled(source) }, set: { enabled in Task { await model.setEnabled(enabled, source: source, day: day) } }))
                Text(LocalizedStringKey(model.status(source, day: day))).font(.headline)
                Text(LocalizedStringKey(explanation)).font(.system(size: 12)).lineSpacing(5).foregroundStyle(DaybookStyle.secondary)
                if source == .health, let message = model.healthObservationMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                if let snapshot = model.snapshot(source, day: day) {
                    if let date = snapshot.refreshedAt { Text("上次更新：\(date.formatted())").font(.caption) }
                    if snapshot.isStale { Text("当前显示上次保存的快照，可能已过期。").font(.caption).foregroundStyle(.orange) }
                    if let message = snapshot.message { Text(LocalizedStringKey(message)).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                }
                if let error = model.errorMessage { Text(LocalizedStringKey(error)).font(.caption).foregroundStyle(.orange) }
                if source == .location {
                    Button("刷新权限状态") { model.refreshLocationStatus(day: day) }
                        .buttonStyle(DaybookPrimaryButtonStyle(wide: true)).disabled(!model.isEnabled(source))
                } else {
                    Button("刷新所选日期") { model.refresh(source, day: day) }
                        .buttonStyle(DaybookPrimaryButtonStyle(wide: true)).disabled(!model.isEnabled(source) || model.refreshing.contains(source))
                }
                if source == .health {
                    Button("管理健康读取授权") { Task { await model.setEnabled(true, source: .health, day: day) } }
                        .buttonStyle(DaybookSecondaryButtonStyle())
                }
                Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                    .buttonStyle(DaybookSecondaryButtonStyle())
                Text("暂停后不再读取新数据，已有快照保留在本机。AI 是否可用这些数据，需在 AI 偏好中另行开启。")
                    .font(.caption).lineSpacing(5).foregroundStyle(DaybookStyle.secondary)
            }
        }
    }
    private var explanation: String {
        switch source {
        case .health: "只读步数、睡眠与体能训练，不写入健康。体能训练包含类型、起止时间、持续时长和可读取的距离、活动能量，按开始日期归属；手动录入标注来源。数据变化或回到前台时，更新今天、昨天、所选日期及其前一天；其他历史日期在查看时刷新。后台更新由系统调度，步数最多每小时通知一次，不保证固定间隔。锁屏期间若无法读取，解锁后补刷。健康不披露读取授权状态，无数据也可能表示未允许读取。步数按自然日累计，昨日步数归档到零点并标注实际更新时间，不保证准点同步。整夜睡眠按结束日期归属，午睡单独保留；跨设备样本去重。起床时间为睡眠结束估计，可本人确认或撤销；没有可读取的质量评分时不推测好坏。权限可在系统的健康设置中管理。"
        case .calendar: "只读所选日期的日程，不创建或修改日历。成功刷新会移除已取消的缓存日程；读取失败保留旧快照。"
        case .location: "开启后，iPhone 和 Apple Watch 在录音开始时尝试获取地点；拍照时记录位置，从相册导入时读取照片原始位置。Watch 需单独允许定位，开关会在连接后同步。定位失败不影响录音；没有地点的记录不显示地点。只保留采集点，不记录连续轨迹。前台查看时使用 Apple 地图将坐标解析为地址，可能需要联网；仅向 Apple 提交坐标，地址随记录缓存在本机。照片未含时区时按本机时区解释拍摄时间。"
        }
    }
}

struct LifeRecordDetailView: View {
    let record: DayRecord
    @ObservedObject var model: LifeSourceModel
    let onClose: () -> Void
    var body: some View {
        DaybookSheetLayout(title: record.kind.title, onClose: onClose) {
            VStack(alignment: .leading, spacing: 18) {
                Text(record.title).font(.title2.bold())
                Text(record.capturedAt.formatted()).font(.caption).foregroundStyle(DaybookStyle.secondary)
                Text(record.text).font(.body).lineSpacing(5).textSelection(.enabled)
                if record.kind == .activity && record.lifeMoment?.workout == nil { Text("这是自然日累计步数，不是一次活动或连续步行轨迹。").font(.caption) }
                if model.isStale(record) { Text("来源刷新失败；这是可能已过期的本机快照。").foregroundStyle(.orange).font(.caption) }
                Text("来源：\(Text(LocalizedStringKey(record.kind == .activity || record.kind == .sleep ? "Apple 健康" : record.kind == .calendar ? "日历" : "前台单次定位"))) · 本机快照").font(.caption).foregroundStyle(DaybookStyle.secondary)
                if let error = model.errorMessage { Text(LocalizedStringKey(error)).foregroundStyle(.orange).font(.caption) }
                Button("删除本机快照", role: .destructive) { if model.delete(record.id) { onClose() } }
                Text("删除后不会再次导入同一条记录，也不会删除系统中的原始数据。").font(.caption).foregroundStyle(DaybookStyle.secondary)
            }
        }
    }
}
