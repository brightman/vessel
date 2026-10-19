import SwiftUI
import UIKit

struct DaybookReminderListView: View {
    @ObservedObject var store: DaybookReminderStore
    var onOpenRecord: ((UUID) -> Void)? = nil
    var sourceTitle: (UUID) -> String? = { _ in nil }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showNewReminder = false
    @State private var editingReminder: DaybookReminder?
    @State private var deletingReminder: DaybookReminder?

    private var sortedItems: [DaybookReminder] {
        store.items.sorted {
            let leftFinished = $0.status == .completed || $0.status == .cancelled
            let rightFinished = $1.status == .completed || $1.status == .cancelled
            return leftFinished == rightFinished ? $0.scheduledAt < $1.scheduledAt : !leftFinished
        }
    }

    var body: some View {
        DaybookSheetLayout(title: "我的提醒", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 0) {
                Text("你确认过的小行动，都在这里。\n可以随时调整内容与时间。")
                    .font(.system(size: 12)).lineSpacing(8).foregroundStyle(DaybookStyle.secondary)
                    .padding(.top, 6).padding(.bottom, 20)
                if let error = store.errorMessage {
                    Text(error).font(.system(size: 12)).lineSpacing(6).foregroundStyle(DaybookStyle.red)
                        .padding(.bottom, 12)
                }
                if sortedItems.isEmpty {
                    VStack(spacing: 10) {
                        DaybookIcon("Bell", size: 32).foregroundStyle(DaybookStyle.accent.opacity(0.65))
                        Text("还没有安排提醒").font(.system(size: 15, weight: .medium)).foregroundStyle(DaybookStyle.ink)
                        Text("有值得跟进的事，再轻轻提醒你。").font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 34)
                } else {
                    ForEach(sortedItems) { reminder in row(reminder) }
                }
                Button { showNewReminder = true } label: {
                    HStack(spacing: 7) { DaybookIcon("Plus", size: 15); Text("新建提醒") }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DaybookSettingsButtonStyle(primary: true))
                .disabled(!store.isAvailable || store.isBusy)
                .padding(.top, 16)
                DaybookNotificationStatus(store: store).padding(.top, 18)
                SettingsFootnote(text: "提醒保存在本机，由 iPhone 系统通知。已确认的提醒与 AI 主动建议分别管理。")
                    .padding(.top, 12)
            }
        }
        .sheet(isPresented: $showNewReminder) {
            DaybookReminderEditor(store: store, proposedTitle: "")
        }
        .sheet(item: $editingReminder) { reminder in
            DaybookReminderEditor(store: store, proposedTitle: reminder.title, reminder: reminder,
                                  sourceTitle: reminder.sourceID.flatMap(sourceTitle))
        }
        .confirmationDialog("删除这条提醒？", isPresented: Binding(
            get: { deletingReminder != nil },
            set: { if !$0 { deletingReminder = nil } }
        ), titleVisibility: .visible) {
            Button("删除提醒", role: .destructive) {
                guard let reminder = deletingReminder else { return }
                deletingReminder = nil
                Task { await store.delete(reminder.id) }
            }
        } message: { Text("已安排的通知也会取消。") }
        .task { await store.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refreshAuthorization() } }
        }
    }

    private func row(_ reminder: DaybookReminder) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if reminder.status == .completed { DaybookIcon("Check", size: 13).foregroundStyle(DaybookStyle.green) }
                Text(reminder.title).font(.system(size: 14, weight: .medium))
                    .lineSpacing(7).foregroundStyle(DaybookStyle.ink)
            }
            Text(reminder.scheduledAt.formatted(.dateTime.month().day().hour().minute()) + " · " + reminder.statusTitle)
                .font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
            if let sourceID = reminder.sourceID, let onOpenRecord {
                if let title = sourceTitle(sourceID) {
                    Button { onOpenRecord(sourceID) } label: {
                        HStack(spacing: 6) {
                            DaybookIcon("ArrowUpRight", size: 12)
                            Text("原记录：\(title)").lineLimit(1)
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(DaybookStyle.accent).padding(.vertical, 3)
                } else { Text("原记录已删除").font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary) }
            }
            HStack(spacing: 16) {
                if reminder.status == .scheduled || reminder.status == .needsAttention {
                    Button("修改时间 / 内容") { editingReminder = reminder }
                    Button("标记完成") { Task { await store.complete(reminder.id) } }
                    Button("取消提醒") { Task { await store.cancel(reminder.id) } }
                } else {
                    Button("重新安排") { editingReminder = reminder }
                    Button("移除") { deletingReminder = reminder }
                }
            }
            .font(.system(size: 11)).foregroundStyle(DaybookStyle.accent)
            .buttonStyle(.plain).padding(.top, 3).padding(.vertical, 5).disabled(store.isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(DaybookStyle.line).frame(height: 1) }
    }
}

struct DaybookReminderEditor: View {
    @ObservedObject var store: DaybookReminderStore
    let reminder: DaybookReminder?
    let sourceID: UUID?
    let sourceTitle: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var title: String
    @State private var scheduledAt: Date
    @State private var submitting = false

    init(store: DaybookReminderStore, proposedTitle: String, reminder: DaybookReminder? = nil,
         sourceID: UUID? = nil, initialDate: Date? = nil, sourceTitle: String? = nil) {
        self.store = store
        self.reminder = reminder
        self.sourceID = sourceID ?? reminder?.sourceID
        self.sourceTitle = sourceTitle
        _title = State(initialValue: reminder?.title ?? proposedTitle)
        let defaultDate = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? Date.now.addingTimeInterval(3600)
        _scheduledAt = State(initialValue: reminder?.scheduledAt ?? initialDate ?? defaultDate)
    }

    private var canConfirm: Bool {
        !submitting && !store.isBusy && store.isAvailable &&
        (try? DaybookReminder.validatedTitle(title)) != nil &&
        (try? DaybookReminder.validateDate(scheduledAt)) != nil
    }

    var body: some View {
        DaybookSheetLayout(title: reminder == nil ? "先确认，再替你记下" : "修改提醒", onClose: {
            if !submitting { dismiss() }
        }) {
            VStack(alignment: .leading, spacing: 0) {
                Text("选一个适合自己的时刻。确认前，不会创建提醒。")
                    .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary).lineSpacing(8)
                    .padding(.top, 6).padding(.bottom, 20)
                DaybookSettingsField("提醒我") {
                    TextField("想提醒自己做什么", text: $title, axis: .vertical)
                        .lineLimit(1...4).accessibilityLabel("提醒内容")
                }
                if title.trimmingCharacters(in: .whitespacesAndNewlines).count > 200 {
                    Text("提醒内容请控制在 200 字以内。")
                        .font(.system(size: 12)).foregroundStyle(DaybookStyle.red).padding(.top, 10)
                }
                HStack(alignment: .top, spacing: 12) {
                    DaybookSettingsField("日期") {
                        DatePicker("日期", selection: $scheduledAt, in: Date.now..., displayedComponents: .date)
                            .datePickerStyle(.compact).labelsHidden().accessibilityLabel("提醒日期")
                    }
                    DaybookSettingsField("时间") {
                        DatePicker("时间", selection: $scheduledAt, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.compact).labelsHidden().accessibilityLabel("提醒时间")
                    }
                }
                .padding(.top, 18).padding(.bottom, 16)
                if sourceID != nil {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("来自你的记录").font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
                        HStack(spacing: 6) {
                            DaybookIcon("Link2", size: 12)
                            Text(sourceTitle ?? "已关联原始记录").font(.system(size: 10)).lineLimit(2)
                        }.foregroundStyle(DaybookStyle.accent)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).stroke(DaybookStyle.line, lineWidth: 1) }
                    }
                    .padding(.leading, 13).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) { Rectangle().fill(DaybookStyle.accent.opacity(0.45)).frame(width: 2) }
                    .padding(.vertical, 4)
                }
                SettingsFootnote(text: "确认后会设置 iPhone 本地通知。你确认的提醒与 AI 主动建议分别管理，可随时修改或取消。")
                    .padding(.top, 13)
                DaybookNotificationStatus(store: store).padding(.top, 13)
                if let error = store.errorMessage {
                    Text(error).font(.system(size: 12)).lineSpacing(7).foregroundStyle(DaybookStyle.red)
                        .padding(.top, 12)
                }
                DaybookSettingsActions(cancel: { dismiss() }, save: save,
                                       canSave: canConfirm, saveTitle: reminder == nil ? "确认提醒" : "保存修改",
                                       isSaving: submitting, canCancel: !submitting)
                    .padding(.top, 22)
            }
        }
        .interactiveDismissDisabled(submitting)
        .task { await store.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refreshAuthorization() } }
        }
    }

    private func save() {
        submitting = true
        Task {
            let saved = await store.confirm(title: title, scheduledAt: scheduledAt, sourceID: sourceID, editingID: reminder?.id)
            submitting = false
            if saved { dismiss() }
        }
    }
}

struct DaybookPreferencesView: View {
    @ObservedObject var preferences: DaybookPreferences
    @ObservedObject var reminders: DaybookReminderStore
    var onOpenRecord: ((UUID) -> Void)? = nil
    var sourceTitle: (UUID) -> String? = { _ in nil }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var quietStartMinutes: Int
    @State private var quietEndMinutes: Int
    @State private var quietSaved = false
    @State private var showReminders = false

    init(preferences: DaybookPreferences, reminders: DaybookReminderStore,
         onOpenRecord: ((UUID) -> Void)? = nil, sourceTitle: @escaping (UUID) -> String? = { _ in nil }) {
        self.preferences = preferences
        self.reminders = reminders
        self.onOpenRecord = onOpenRecord
        self.sourceTitle = sourceTitle
        _quietStartMinutes = State(initialValue: preferences.quietStartMinutes)
        _quietEndMinutes = State(initialValue: preferences.quietEndMinutes)
    }

    var body: some View {
        DaybookSheetLayout(title: "AI 偏好与提醒", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 0) {
                preferenceRow("主动给我建议", detail: "发现值得跟进的记录时，在 App 内提醒我。", isOn: $preferences.proactiveEnabled)
                sectionTitle("建议频率")
                HStack(spacing: 7) {
                    frequencyButton(1, title: "每天精选 1 条")
                    frequencyButton(3, title: "每天最多 3 条")
                }.padding(.vertical, 2)
                Text("少而有用。从你允许使用的当天记录中选择。")
                    .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary).lineSpacing(7)
                    .padding(.top, 12).padding(.bottom, 4)
                preferenceRow("免打扰时段", detail: "此时收起主动建议，仍可主动向 AI 提问。", isOn: $preferences.quietEnabled)
                HStack(alignment: .top, spacing: 12) {
                    DaybookSettingsField("开始") {
                        DatePicker("开始", selection: timeBinding($quietStartMinutes), displayedComponents: .hourAndMinute)
                            .datePickerStyle(.compact).labelsHidden().accessibilityLabel("免打扰开始时间")
                    }
                    DaybookSettingsField("结束（可跨天）") {
                        DatePicker("结束", selection: timeBinding($quietEndMinutes), displayedComponents: .hourAndMinute)
                            .datePickerStyle(.compact).labelsHidden().accessibilityLabel("免打扰结束时间")
                    }
                }.padding(.top, 18).padding(.bottom, 16)
                Button("保存时段") {
                    preferences.quietStartMinutes = quietStartMinutes
                    preferences.quietEndMinutes = quietEndMinutes
                    quietSaved = true
                }.buttonStyle(DaybookSettingsButtonStyle())
                if quietSaved {
                    Text("已更新免打扰时段。").font(.system(size: 11)).foregroundStyle(DaybookStyle.green).padding(.top, 10)
                }
                sectionTitle("允许 AI 使用的记录")
                preferenceRow("语音与闪念", detail: "录音转写、讨论与随手说出的想法", isOn: $preferences.allowAudio)
                preferenceRow("图片与说明", detail: "你选择的图片与说明，未自动读取相册", isOn: $preferences.allowPhotos)
                SettingsFootnote(text: "关闭后，新回答不再使用该类记录，已有相关回答会收起。原始录音与照片保留在本机；已确认的提醒由你单独管理。")
                    .padding(.top, 16)
                Button { showReminders = true } label: {
                    HStack(spacing: 9) {
                        DaybookIcon("Bell", size: 17).foregroundStyle(DaybookStyle.secondary)
                        Text("管理已确认的提醒").font(.system(size: 11))
                        Spacer(minLength: 0)
                        DaybookIcon("ChevronRight", size: 17).foregroundStyle(DaybookStyle.secondary)
                    }.padding(.vertical, 16).contentShape(Rectangle())
                }
                .overlay(alignment: .bottom) { Rectangle().fill(DaybookStyle.line).frame(height: 1) }
                DaybookNotificationStatus(store: reminders).padding(.top, 16)
                SettingsFootnote(text: preferenceStatus)
                    .padding(.top, 12)
            }
        }
        .sheet(isPresented: $showReminders) {
            DaybookReminderListView(store: reminders, onOpenRecord: onOpenRecord, sourceTitle: sourceTitle)
        }
        .onChange(of: quietStartMinutes) { _, _ in quietSaved = false }
        .onChange(of: quietEndMinutes) { _, _ in quietSaved = false }
        .task { await reminders.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reminders.refreshAuthorization() } }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(DaybookStyle.ink)
            .padding(.top, 24).padding(.bottom, 12)
    }

    private var preferenceStatus: String {
        if !preferences.proactiveEnabled { return "主动建议已关闭。你仍可主动向 AI 提问。" }
        if preferences.isQuiet(at: .now) { return "当前处于免打扰时段。已确认的提醒仍按原定时间通知。" }
        return "当前可展示主动建议。每条新提醒仍需你确认。"
    }

    private func preferenceRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(DaybookStyle.ink)
                Text(detail).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary).lineSpacing(7)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn).labelsHidden().tint(DaybookStyle.accent)
                .scaleEffect(0.81, anchor: .trailing).frame(width: 42, height: 25)
        }
        .padding(.vertical, 17)
        .overlay(alignment: .bottom) { Rectangle().fill(DaybookStyle.line).frame(height: 1) }
    }

    private func frequencyButton(_ value: Int, title: String) -> some View {
        Button { preferences.dailySuggestionLimit = value } label: {
            Text(title).font(.system(size: 11))
                .foregroundStyle(preferences.dailySuggestionLimit == value ? DaybookStyle.accent : DaybookStyle.secondary)
                .frame(maxWidth: .infinity).padding(.horizontal, 8).padding(.vertical, 12)
                .background(preferences.dailySuggestionLimit == value ? DaybookStyle.blueSoft : DaybookStyle.white,
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(DaybookStyle.accent.opacity(preferences.dailySuggestionLimit == value ? 0.6 : 0.2), lineWidth: 1)
                }
        }
        .accessibilityAddTraits(preferences.dailySuggestionLimit == value ? .isSelected : [])
    }

    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }
}

private struct DaybookNotificationStatus: View {
    @ObservedObject var store: DaybookReminderStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                DaybookIcon(store.authorization.canSchedule ? "Bell" : "BellOff", size: 13)
                Text(store.authorization.title)
            }.font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
            if store.authorization == .denied {
                Button("打开系统通知设置") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }.font(.system(size: 11)).foregroundStyle(DaybookStyle.accent)
                Text("通知权限关闭时不会新增提醒。开启后请重新确认需要的提醒。")
                    .font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary).lineSpacing(7)
            }
        }
    }
}
