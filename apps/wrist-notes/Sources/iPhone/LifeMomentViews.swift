import SwiftUI

struct LifeMomentDetailView: View {
    let record: DayRecord
    @ObservedObject var model: LifeSourceModel
    let onOpen: (UUID) -> Void
    let onClose: () -> Void

    // Confirmation and late HealthKit results update an already-open sheet.
    private var current: DayRecord { model.records.first { $0.id == record.id } ?? record }
    private var title: String {
        if record.lifeMoment?.steps != nil { return "昨日累计步数" }
        if record.lifeMoment?.workout != nil { return "体能训练" }
        if record.lifeMoment?.sleep != nil { return "起床与睡眠" }
        return "位置变化"
    }
    var body: some View {
        DaybookSheetLayout(title: title, onClose: onClose) {
            VStack(alignment: .leading, spacing: 22) {
                if let steps = current.lifeMoment?.steps { stepsContent(steps) }
                if let sleep = current.lifeMoment?.sleep { sleepContent(sleep) }
                if let workout = current.lifeMoment?.workout { workoutContent(workout) }
                if let movement = current.lifeMoment?.movement { movementContent(movement) }
                if model.isStale(current), current.lifeMoment?.movement == nil {
                    Text("来源刷新失败；这是可能已过期的本机快照。").font(.caption).foregroundStyle(.orange)
                }
                if let error = model.errorMessage { Text(LocalizedStringKey(error)).font(.caption).foregroundStyle(.orange) }
                VStack(alignment: .leading, spacing: 10) {
                    Button("删除此片段", role: .destructive) { if model.delete(record.id) { onClose() } }
                    Text("仅移除此片段，保留 Apple 健康数据、原始录音和照片。").font(.caption).foregroundStyle(DaybookStyle.secondary)
                }.padding(.top, 8)
            }.padding(.top, 8)
        }
    }

    private func workoutContent(_ workout: WorkoutMoment) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(workout.activity).font(.title2.bold())
            field("开始", value: stamp(workout.startedAt))
            field("结束", value: stamp(workout.endedAt))
            let seconds = Int(workout.duration)
            field("训练持续时长", value: "\(seconds / 3600)小时\(seconds / 60 % 60)分\(seconds % 60)秒")
            field("距离", value: workout.distanceMeters.map { String(format: "%.2f 公里", $0 / 1000) } ?? "未提供")
            field("活动能量", value: workout.activeKilocalories.map { String(format: "%.0f 千卡", $0) } ?? "未提供")
            field("来源", value: workout.sourceName)
            if workout.manuallyEntered { explanation("此训练为手动录入，不是设备自动测量。") }
            explanation("训练持续时长不等于锻炼圆环分钟数。跨午夜训练完整归属开始当天；不同来源可能重复，不与每日步数或能量相加。")
            refreshButton(day: workout.startedAt)
        }
    }

    private func stepsContent(_ steps: StepMoment) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(steps.count.map { Int($0).formatted() } ?? "—").font(.system(size: 42, weight: .semibold)).monospacedDigit()
                Text("步").foregroundStyle(DaybookStyle.secondary)
            }
            Text(steps.count == nil ? "等待健康数据" : "昨日全天累计").font(.subheadline).foregroundStyle(DaybookStyle.secondary)
            VStack(spacing: 14) {
                field("统计日期", value: DaybookFormat.day(steps.interval.start))
                field("统计范围", value: "\(stamp(steps.interval.start)) → \(stamp(steps.interval.end))")
                field("归档时间", value: stamp(record.capturedAt))
                field("实际更新", value: steps.updatedAt.map(stamp) ?? localized("尚未同步", "Not synced yet"))
                field("来源", value: localized("Apple 健康", "Apple Health"))
            }.padding(16).background(DaybookStyle.field, in: RoundedRectangle(cornerRadius: 16))
            explanation("零点是归档时间。系统可能延后同步，健康数据更新或打开 App 后会补齐；晚到数据会更新同一条记录。")
            explanation("昨日步数不计入今天的步数。没有可读取的数据不代表 0 步。")
            refreshButton(day: record.capturedAt)
        }
    }

    @ViewBuilder private func sleepContent(_ sleep: SleepMoment) -> some View {
        if let start = sleep.startedAt, let end = sleep.endedAt, let seconds = sleep.asleepSeconds {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(DaybookFormat.time(end)).font(.system(size: 42, weight: .semibold)).monospacedDigit()
                    Text(sleep.isMain ? (sleep.confirmed ? "本人确认起床" : "起床 · 估计") : "睡眠结束")
                        .font(.caption).foregroundStyle(sleep.confirmed ? DaybookStyle.green : DaybookStyle.secondary)
                }
                VStack(spacing: 14) {
                    field("入睡", value: stamp(start))
                    field("醒来", value: stamp(end))
                    field("实际睡眠", value: duration(seconds))
                    field("期间清醒", value: sleep.awakeSeconds.map(duration) ?? localized("暂无数据", "Unavailable"))
                    field("来源", value: sleep.sourceName ?? localized("Apple 健康", "Apple Health"))
                    field("实际更新", value: model.snapshot(.health, day: current.capturedAt)?.refreshedAt.map(stamp) ?? "—")
                }.padding(16).background(DaybookStyle.field, in: RoundedRectangle(cornerRadius: 16))
                if sleep.isMain {
                    explanation("睡眠结束不一定等于离床时间。确认后，会将这个时间标记为你本人确认的起床时间。")
                    Button {
                        model.confirmWake(current.id, expectedEnd: end, confirmed: !sleep.confirmed)
                    } label: {
                        if sleep.confirmed { Text("撤销起床确认") }
                        else { Text("我在 \(DaybookFormat.time(end)) 起床") }
                    }.buttonStyle(DaybookPrimaryButtonStyle(wide: true))
                }
                stages(sleep)
                VStack(alignment: .leading, spacing: 8) {
                    Text("睡眠质量").font(.subheadline.bold())
                    Text("暂无质量评分").font(.subheadline).foregroundStyle(DaybookStyle.secondary)
                    explanation("当前来源未提供可读取的质量评分，不根据睡眠时长或分期推测好坏。")
                }
                refreshButton(day: current.capturedAt)
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                Text("昨夜睡眠 · 待同步").font(.title2.bold())
                explanation("等待完整睡眠记录，暂不推测入睡、起床时间或睡眠质量。")
                explanation("仅有卧床数据时，不会将卧床时长当作实际睡眠。")
                refreshButton(day: record.capturedAt)
            }
        }
    }
    private func stages(_ sleep: SleepMoment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("睡眠分期").font(.subheadline.bold())
            if [.deep, .core, .rem].contains(where: { sleep.stages[$0] != nil }) {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach([SleepStage.deep, .core, .rem, .asleep], id: \.self) { stage in
                            if let seconds = sleep.stages[stage], seconds > 0 {
                                stageColor(stage).frame(width: geometry.size.width * seconds / max(1, sleep.asleepSeconds ?? 1))
                            }
                        }
                    }.clipShape(Capsule())
                }.frame(height: 9).accessibilityHidden(true)
                ForEach([SleepStage.deep, .core, .rem, .asleep], id: \.self) { stage in
                    if let seconds = sleep.stages[stage], seconds > 0 {
                        HStack {
                            Circle().fill(stageColor(stage)).frame(width: 7, height: 7)
                            Text(LocalizedStringKey(stageTitle(stage)))
                            Spacer(); Text(duration(seconds)).monospacedDigit()
                        }.font(.caption)
                    }
                }
                explanation("图条表示各阶段累计占比，不表示阶段发生顺序。")
            } else { explanation("来源未提供睡眠分期，已保留可读取的实际睡眠时长。") }
        }
    }

    private func movementContent(_ movement: LocationMovement) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(record.title).font(.title2.bold())
            Text("两次记录相距约 \(Int((movement.distance / 1_000).rounded())) km").font(.headline)
            evidence(movement.from, label: "前一条地点记录")
            evidence(movement.to, label: "后一条地点记录")
            explanation("根据已有录音、照片的两个地点生成，未开启持续定位。距离为两点直线距离，不代表行程距离。")
            explanation("以上是记录时间，不代表出发或抵达时间；不能据此推断路线、交通方式或停留时长。")
        }
    }
    private func evidence(_ value: LocationMovement.Evidence, label: String) -> some View {
        Button { onOpen(value.parentID ?? value.id) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(LocalizedStringKey(label)).font(.caption).foregroundStyle(DaybookStyle.secondary)
                    Spacer(); DaybookIcon("ArrowUpRight", size: 15)
                }
                Text(value.point.address?.city ?? localized("地点待解析", "Location pending")).font(.headline)
                Text(value.point.displayTitle).font(.subheadline)
                Text("\(stamp(value.capturedAt)) · \(value.point.title)").font(.caption).foregroundStyle(DaybookStyle.secondary)
                Text(value.point.accuracy.map { localized("定位精度约 ±\(Int($0.rounded())) 米", "Location accuracy about ±\(Int($0.rounded())) m") }
                    ?? localized("定位精度未提供", "Location accuracy unavailable"))
                    .font(.caption).foregroundStyle(DaybookStyle.secondary)
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(value.point.source.label))
                    if let device = value.device { Text(device) }
                    Spacer(); Text("回看原记录")
                }.font(.caption).foregroundStyle(DaybookStyle.accent)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(DaybookStyle.field, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
    private func refreshButton(day: Date) -> some View {
        Button("刷新健康数据") { model.refresh(.health, day: day) }
            .buttonStyle(DaybookSecondaryButtonStyle())
            .disabled(!model.isEnabled(.health) || model.refreshing.contains(.health))
    }
    private func field(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(LocalizedStringKey(label)).foregroundStyle(DaybookStyle.secondary)
            Spacer(minLength: 0); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.caption)
    }
    private func explanation(_ value: String) -> some View {
        Text(LocalizedStringKey(value)).font(.caption).foregroundStyle(DaybookStyle.secondary).lineSpacing(5)
    }
    private func stamp(_ date: Date) -> String { "\(DaybookFormat.day(date)) \(DaybookFormat.time(date))" }
    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        return localized("\(minutes / 60)小时\(minutes % 60)分", "\(minutes / 60)h \(minutes % 60)m")
    }
    private func localized(_ chinese: String, _ english: String) -> String { DaybookFormat.language == .english ? english : chinese }
    private func stageTitle(_ stage: SleepStage) -> String {
        switch stage { case .deep: "深睡"; case .core: "核心睡眠"; case .rem: "REM"; default: "未分期睡眠" }
    }
    private func stageColor(_ stage: SleepStage) -> Color {
        switch stage { case .deep: DaybookStyle.accent; case .core: DaybookStyle.accent.opacity(0.55); case .rem: DaybookStyle.green; default: DaybookStyle.secondary.opacity(0.4) }
    }
}
