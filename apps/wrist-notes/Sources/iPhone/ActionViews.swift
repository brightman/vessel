import SwiftUI

private enum ActionEditorRoute: Identifiable {
    case create(ActionItem)
    case edit(ActionItem)

    var id: UUID { item.id }

    var item: ActionItem {
        switch self {
        case .create(let item), .edit(let item): item
        }
    }

    var isNew: Bool {
        if case .create = self { return true }
        return false
    }
}

struct ActionListView: View {
    @ObservedObject var store: ActionStore
    let onOpenSource: (ActionSource) -> Void
    @State private var filter: ActionItem.Kind?
    @State private var editorRoute: ActionEditorRoute?
    @State private var detail: ActionItem?
    @State private var pendingSource: ActionSource?
    private var visible: [ActionItem] { store.items.filter { filter == nil || $0.kind == filter } }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                VStack(alignment:.leading,spacing:8) {
                    Text("把理解，变成下一步").font(.caption).foregroundStyle(DaybookStyle.secondary)
                    Text("从一件小事开始。").font(.title2.weight(.medium))
                    Text("待办、提醒、日程，都从你的决定开始。").font(.caption).foregroundStyle(DaybookStyle.secondary)
                }
                Spacer()
                Button {
                    editorRoute = .create(ActionItem(kind:.todo,title:""))
                } label: { Image(systemName:"plus.circle.fill").font(.title2) }
                    .accessibilityLabel("新建行动")
            }
            ScrollView(.horizontal,showsIndicators:false) {
                HStack { filterButton(nil,"全部"); ForEach(ActionItem.Kind.allCases,id:\.self) { kind in filterButton(kind,kind.title) } }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
            section("等你决定",items:visible.filter{$0.status == .suggested})
            section("已加入行动",items:visible.filter{$0.status != .suggested && $0.status != .cancelled}.sorted {
                if ($0.status == .completed) != ($1.status == .completed) { return $0.status != .completed }
                return ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture)
            })
            if visible.contains(where:{$0.status == .cancelled}) {
                DisclosureGroup("已取消 / 已忽略") { ForEach(visible.filter{$0.status == .cancelled}) { row($0) } }
            }
            Text("行动保存在本机。关联 Apple 列表或日历后，内容可能随该账户同步。").font(.caption2).foregroundStyle(DaybookStyle.secondary)
        }
        .disabled(store.busy)
        .sheet(item:$editorRoute) { route in
            ActionEditor(store:store,item:route.item,isNew:route.isNew)
        }
        .sheet(item:$detail,onDismiss:{ if let source = pendingSource { pendingSource = nil; onOpenSource(source) } }) { ActionDetailView(store:store,id:$0.id,onOpenSource:{ pendingSource = $0; detail = nil }) }
        .task { await store.refresh() }
    }
    private func filterButton(_ kind: ActionItem.Kind?, _ title: String) -> some View {
        Button(title) { filter = kind }.font(.caption).padding(.horizontal,13).padding(.vertical,8)
            .background(filter == kind ? DaybookStyle.blueSoft : DaybookStyle.white,in:Capsule())
            .accessibilityAddTraits(filter == kind ? .isSelected : [])
    }
    private func section(_ title: String, items: [ActionItem]) -> some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text(title).font(.headline); Spacer(); Text("\(items.count) 项").font(.caption).foregroundStyle(DaybookStyle.secondary) }
            if items.isEmpty { Text(title == "等你决定" ? "暂时没有待确认建议。" : "不必一次安排好所有事情，先从一件小事开始。").font(.caption).foregroundStyle(DaybookStyle.secondary).padding(.vertical,18) }
            ForEach(items) { row($0) }
        }
    }
    private func row(_ item: ActionItem) -> some View {
        Button { if item.status == .suggested { editorRoute = .edit(item) } else { detail = item } } label: {
            HStack(spacing:12) {
                DaybookIcon(item.status == .completed ? "Check" : item.kind.icon,size:22)
                VStack(alignment:.leading,spacing:6) {
                    Text(item.title).font(.system(size:14,weight:.medium)).foregroundStyle(DaybookStyle.ink)
                    Text(item.start.map{ item.timeLabel($0) } ?? "未设时间").font(.caption).foregroundStyle(DaybookStyle.secondary)
                    Text("\(item.kind.title) · \(item.statusTitle)").font(.caption2)
                    if item.sync == .failed || item.sync == .missing || item.sync == .pending { Text(item.syncTitle).font(.caption2).foregroundStyle(.orange) }
                }
                Spacer(); Image(systemName:"chevron.right").font(.caption)
            }.padding(15).frame(maxWidth:.infinity,alignment:.leading).background(DaybookStyle.white,in:RoundedRectangle(cornerRadius:16))
        }.buttonStyle(.plain)
        .contextMenu {
            if item.status == .suggested { Button("忽略建议") { Task { _ = await store.setStatus(item,.cancelled) } } }
        }
    }
}

struct ActionEditor: View {
    @ObservedObject var store: ActionStore
    @State private var item: ActionItem
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var external = false
    @State private var lists: [ActionSystemList] = []
    @State private var listID = ""
    @State private var loading = false
    @State private var error: String?
    private var timeZone: TimeZone { TimeZone(identifier:item.timeZoneID) ?? .current }
    private var titleText: String {
        if isNew { return "新建行动" }
        return item.status == .suggested ? "确认\(item.kind.title)" : "编辑\(item.kind.title)"
    }
    private var canSave: Bool {
        !store.busy && !loading && !item.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }

    init(store: ActionStore, item: ActionItem, isNew: Bool = false) {
        self.store = store
        self.isNew = isNew
        _item = State(initialValue:item)
    }

    var body: some View {
        DaybookSheetLayout(title:titleText,onClose:{ dismiss() }) {
            VStack(alignment:.leading,spacing:18) {
                Text(isNew ? "把重要的下一步放进你的行动里。" : "你可以随时调整内容、时间和系统关联。")
                    .font(.system(size:12)).foregroundStyle(DaybookStyle.secondary).lineSpacing(8)
                    .padding(.top,6).padding(.bottom,2)

                DaybookSettingsField("类型") {
                    Picker("类型",selection:$item.kind) {
                        ForEach(ActionItem.Kind.allCases,id:\.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).tint(DaybookStyle.accent)
                    .disabled(item.legacyReminderID != nil || (item.link != nil && item.status != .suggested))
                }
                DaybookSettingsField("要做什么") {
                    TextField("行动内容",text:$item.title,axis:.vertical)
                        .lineLimit(1...4).accessibilityLabel("行动内容")
                }
                DaybookSettingsField("备注（仅保存在本机）") {
                    TextField("补充说明",text:$item.notes,axis:.vertical)
                        .lineLimit(2...5).accessibilityLabel("行动备注")
                }

                scheduleFields
                if let source = item.source { sourceCard(source) }
                systemDestination

                if let error = error ?? store.error {
                    Text(error).font(.system(size:12)).foregroundStyle(DaybookStyle.red).lineSpacing(6)
                }
                DaybookSettingsActions(cancel:{ dismiss() },save:save,canSave:canSave,
                    saveTitle:isNew ? "添加行动" : item.status == .suggested ? "确认并加入" : "保存修改",
                    isSaving:store.busy || loading,canCancel:!store.busy && !loading)
                    .padding(.top,4)
            }
            .padding(.top,6)
        }
        .interactiveDismissDisabled(store.busy || loading)
        .onAppear {
            external = item.link != nil
            if let link = item.link { lists = [.init(id:link.listID,title:link.listTitle)]; listID = link.listID }
        }
        .onChange(of:item.kind) { _,_ in external = false; lists = []; listID = ""; item.allDay = false }
    }

    private var scheduleFields: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("安排时间").font(.system(size:13,weight:.medium)).foregroundStyle(DaybookStyle.ink)
            Toggle(primaryTimeToggleTitle,isOn:Binding(get:{item.start != nil},set:{ enabled in
                item.start = enabled ? Date.now.addingTimeInterval(3600) : nil
            }))
            .font(.system(size:13)).tint(DaybookStyle.accent)
            if item.start != nil {
                DaybookSettingsField(primaryDateTitle) {
                    DatePicker(primaryDateTitle,selection:Binding(get:{item.start ?? .now},set:{item.start = $0}),
                        displayedComponents:item.allDay ? [.date] : [.date,.hourAndMinute])
                        .datePickerStyle(.compact).labelsHidden().accessibilityLabel(primaryDateTitle)
                }
            }
            if item.kind == .event {
                Toggle("设置结束时间",isOn:Binding(get:{item.end != nil},set:{ enabled in
                    item.end = enabled ? (item.start ?? .now).addingTimeInterval(3600) : nil
                }))
                .font(.system(size:13)).tint(DaybookStyle.accent)
                if item.end != nil {
                    DaybookSettingsField(item.allDay ? "结束日期（不含这一天）" : "结束") {
                        DatePicker("结束",selection:Binding(get:{item.end ?? .now},set:{item.end = $0}),
                            displayedComponents:item.allDay ? [.date] : [.date,.hourAndMinute])
                            .datePickerStyle(.compact).labelsHidden().accessibilityLabel("结束")
                    }
                }
                Toggle("全天",isOn:$item.allDay).font(.system(size:13)).tint(DaybookStyle.accent)
                if item.end == nil {
                    Text("请补充日程结束时间。").font(.system(size:11)).foregroundStyle(DaybookStyle.secondary)
                }
            }
            Text("时区：\(item.timeZoneID)").font(.system(size:11)).foregroundStyle(DaybookStyle.secondary)
            if item.kind == .todo { Text("截止时间不会自动产生通知；需要通知请选择“提醒”。").font(.system(size:11)).foregroundStyle(DaybookStyle.secondary) }
        }
        .environment(\.timeZone,timeZone)
        .padding(16).background(DaybookStyle.blueSoft,in:RoundedRectangle(cornerRadius:16))
    }

    private var primaryTimeToggleTitle: String {
        switch item.kind {
        case .todo: "设置截止时间"
        case .reminder: "设置提醒时间"
        case .event: "设置开始时间"
        }
    }

    private var primaryDateTitle: String {
        switch item.kind {
        case .todo: "截止"
        case .reminder: "提醒"
        case .event: "开始"
        }
    }

    private func sourceCard(_ source: ActionSource) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text("原话依据").font(.system(size:11)).foregroundStyle(DaybookStyle.secondary)
            Text(source.quote.isEmpty ? "可在详情中打开来源记录。" : source.quote)
                .font(.system(size:13)).foregroundStyle(DaybookStyle.ink).lineSpacing(6)
            Text(source.title).font(.system(size:10)).foregroundStyle(DaybookStyle.accent)
        }
        .frame(maxWidth:.infinity,alignment:.leading).padding(15)
        .background(DaybookStyle.blueSoft,in:RoundedRectangle(cornerRadius:14))
        .overlay(alignment:.leading) { RoundedRectangle(cornerRadius:2).fill(DaybookStyle.accent.opacity(0.55)).frame(width:2).padding(.vertical,10) }
    }

    private var systemDestination: some View {
        VStack(alignment:.leading,spacing:12) {
            Toggle("同时添加到 Apple \(item.kind == .event ? "日历" : "提醒事项")",isOn:$external)
                .font(.system(size:13)).tint(DaybookStyle.accent)
            if external {
                Text("只写入标题与时间，不发送录音、原话或本机备注。所选账户可能同步到云端。")
                    .font(.system(size:11)).foregroundStyle(DaybookStyle.secondary).lineSpacing(5)
                if lists.isEmpty {
                    Button(loading ? "正在读取系统列表…" : "授权并选择系统列表") { loadLists() }
                        .buttonStyle(DaybookSettingsButtonStyle()).disabled(loading)
                } else {
                    Picker("列表",selection:$listID) { ForEach(lists) { Text($0.title).tag($0.id) } }
                        .pickerStyle(.menu).tint(DaybookStyle.accent)
                }
            }
            if !external && item.link != nil {
                Text("保存后移除关联的系统项目，保留本机行动。")
                    .font(.system(size:11)).foregroundStyle(DaybookStyle.red)
            }
        }
        .padding(16).background(DaybookStyle.blueSoft,in:RoundedRectangle(cornerRadius:16))
    }

    private func save() {
        Task {
            if external {
                guard let list = lists.first(where:{$0.id == listID}) else { error = "请选择可写的系统列表。"; return }
                item.link = .init(listID:list.id,listTitle:list.title,identifier:item.link?.identifier)
            } else { item.link = nil }
            if await store.save(item) { dismiss() }
            else if let current = store.items.first(where:{$0.id == item.id}) { item = current }
        }
    }
    private func loadLists() {
        loading = true; error = nil
        Task {
            defer { loading = false }
            do { lists = try await store.lists(kind:item.kind); listID = lists.first?.id ?? ""; if lists.isEmpty { error = "没有可写的系统列表。" } }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct ActionDetailView: View {
    @ObservedObject var store: ActionStore
    let id: UUID
    let onOpenSource: (ActionSource) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var deleting = false
    private var item: ActionItem? { store.items.first{$0.id == id} }
    var body: some View {
        NavigationStack {
            if let item {
                List {
                    Section(item.kind.title) {
                        Text(item.title).font(.title3)
                        Text(item.statusTitle)
                        if let start = item.start { Text("\(item.kind == .todo ? "截止" : "开始")：\(item.timeLabel(start))") }
                        if let end = item.end, item.kind == .event { Text("结束：\(item.timeLabel(end))") }
                        Text("时区：\(item.timeZoneID)").font(.caption).foregroundStyle(.secondary)
                        if !item.notes.isEmpty { Text(item.notes) }
                    }
                    if let source = item.source {
                        Section("原话依据") {
                            if !source.quote.isEmpty { Text(source.quote) }
                            if let offset = source.offset { Text("原话位置：约 \(Int(offset)) 秒").font(.caption).foregroundStyle(.secondary) }
                            Button("打开来源：\(source.title)") { onOpenSource(source) }
                        }
                    }
                    Section("系统状态") {
                        Text(item.syncTitle)
                        if item.sync == .failed || item.sync == .pending { Button("重试系统操作") { Task { _ = await store.retry(item) } } }
                        if item.sync == .missing { Text("不会自动重建。可编辑行动，关闭关联并保存，再按需重新添加。").font(.caption) }
                    }
                    Section {
                        Button("编辑") { editing = true }
                        if item.kind != .event {
                            Button(item.status == .completed ? "恢复为未完成" : "标记已完成") { Task { _ = await store.setStatus(item,item.status == .completed ? .active : .completed) } }
                        }
                        if item.status != .cancelled { Button("取消行动") { Task { _ = await store.setStatus(item,.cancelled) } } }
                        Button("删除行动",role:.destructive) { deleting = true }
                    }
                    if let error = store.error { Text(error).foregroundStyle(.red) }
                }.disabled(store.busy)
                .sheet(isPresented:$editing) { ActionEditor(store:store,item:item) }
                .confirmationDialog("删除这项行动？",isPresented:$deleting,titleVisibility:.visible) {
                    Button("删除行动及关联的系统项目",role:.destructive) { Task { if await store.delete(item) { dismiss() } } }
                } message: { Text("已安排的通知也会取消。若系统删除失败，将保留行动供你重试。") }
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismiss() } } }
            } else { Text("行动已移除").onAppear { dismiss() } }
        }
    }
}
