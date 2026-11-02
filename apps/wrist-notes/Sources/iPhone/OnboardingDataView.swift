import SwiftUI
import EventKit
import CoreLocation
import HealthKit

struct OnboardingDataView: View {
    @EnvironmentObject private var life: LifeSourceModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @ObservedObject private var reminders = WiseLifeRuntime.shared.reminders
    @State private var requesting: LifeSource?
    @State private var permissionRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sourceCard(.health, icon: "heart", purpose: "结合睡眠与活动，帮你看见作息变化，给出更贴近状态的建议。", scope: "只读取你选择的步数、睡眠、运动与活动能量，不写入健康数据。", fallback: "不开启也能根据你的笔记生成回顾。")
            sourceCard(.calendar, icon: "calendar", purpose: "把一天的安排与记录放在一起，回顾会议、规划时间。", scope: "访问事件标题、时间与地点；仅在你明确要求创建日程时写入。", fallback: "不开启则不展示日历安排，记录与 AI 问答仍可使用。")
            sourceCard(.location, icon: "mappin.and.ellipse", purpose: "为录音和照片补充地点，帮你想起在哪里发生了什么。", scope: "使用 App 时获取位置，按录音和图片的采集场景记录；不进行全天持续追踪。", fallback: "没有地点的记录照常保存，不猜测位置。")
            VStack(alignment: .leading, spacing: 12) {
                Label("提醒事项", systemImage: "checklist").font(.system(size: 15, weight: .medium))
                Text("把「明天提醒我」这样的明确指令，变成可跟进的事项。")
                Text("读取提醒事项；按你的明确指令创建待办与提醒，不擅自完成或删除。")
                    .foregroundStyle(DaybookStyle.secondary)
                Text(reminderStatus).foregroundStyle(reminders.appleAccess == .authorized ? DaybookStyle.green : DaybookStyle.secondary)
                if reminders.appleAccess != .authorized {
                    Button(reminders.isLoadingApple ? "正在请求…" : reminders.appleAccess == .notDetermined ? "选择授权" : "前往系统设置") {
                        if reminders.appleAccess == .notDetermined { Task { await reminders.requestAppleAccess() } } else { openSettings() }
                    }.buttonStyle(DaybookSettingsButtonStyle()).disabled(reminders.isLoadingApple || requesting != nil)
                }
                if let error = reminders.appleError { Text(error).foregroundStyle(DaybookStyle.red) }
                Text("未授权时，想法仍可保存在 WiseLife，暂不能写入 Apple 提醒事项。")
                    .foregroundStyle(DaybookStyle.secondary)
            }.font(.system(size: 12)).lineSpacing(6).daybookRecordingCard()
            SettingsFootnote(text: "麦克风、相机与照片在实际使用时申请。健康数据的读取权限由系统保护，App 不能判断你拒绝了哪些健康项目。可以随时在系统设置中调整授权。")
            if let error = life.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(DaybookStyle.red) }
        }
        .onAppear { refreshPermissions() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshPermissions() } }
    }

    private func sourceCard(_ source: LifeSource, icon: String, purpose: String, scope: String, fallback: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(source.title, systemImage: icon).font(.system(size: 15, weight: .medium))
            Text(purpose)
            Text(scope).foregroundStyle(DaybookStyle.secondary)
            Text(status(source)).foregroundStyle(DaybookStyle.secondary)
            HStack(spacing: 12) {
                Button(requesting == source ? "正在请求…" : restricted(source) ? "前往系统设置" : life.isEnabled(source) ? "重新检查授权" : "选择授权") {
                    if restricted(source) { openSettings(); return }
                    requesting = source
                    Task {
                        await life.setEnabled(true, source: source, day: .now)
                        requesting = nil; refreshPermissions()
                    }
                }.buttonStyle(DaybookSettingsButtonStyle()).disabled(requesting != nil || reminders.isLoadingApple || !life.storageIsAvailable)
                if life.isEnabled(source) {
                    Button("暂停此来源") { Task { await life.setEnabled(false, source: source, day: .now) } }
                        .foregroundStyle(DaybookStyle.secondary).disabled(requesting != nil)
                }
            }
            Text(fallback).foregroundStyle(DaybookStyle.secondary)
        }.font(.system(size: 12)).lineSpacing(6).daybookRecordingCard()
            .accessibilityIdentifier("onboarding.permission.\(source.rawValue)")
    }
    private func status(_ source: LifeSource) -> String {
        _ = permissionRevision
        guard life.isEnabled(source) else { return "未启用 · 可选" }
        switch source {
        case .health:
            if requesting == .health { return "正在等待权限选择" }
            if let snapshot = life.snapshot(.health, day: .now), snapshot.status == .error || snapshot.status == .unavailable { return snapshot.message ?? "权限选择未完成，请重试" }
            return HKHealthStore.isHealthDataAvailable() ? "已完成权限选择 · 可读取项目以系统设置为准" : "此设备不支持 Apple 健康"
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess, .authorized: return "已允许访问"
            case .notDetermined: return "等待授权选择"
            default: return "权限受限 · 可在系统设置调整"
            }
        case .location: return life.status(.location)
        }
    }
    private func restricted(_ source: LifeSource) -> Bool {
        _ = permissionRevision
        switch source {
        case .health: return false
        case .calendar: return [.denied, .restricted, .writeOnly].contains(EKEventStore.authorizationStatus(for: .event))
        case .location: return [.denied, .restricted].contains(CLLocationManager().authorizationStatus) || !CLLocationManager.locationServicesEnabled()
        }
    }
    private var reminderStatus: String {
        switch reminders.appleAccess { case .authorized: "已允许访问"; case .notDetermined: "未授权 · 可选"; default: "权限受限 · 可在系统设置调整" }
    }
    private func refreshPermissions() {
        permissionRevision += 1
        life.refreshLocationStatus(day: .now)
        reminders.refreshAppleLists()
    }
    private func openSettings() { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
}
