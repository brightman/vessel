import SwiftUI

struct ActionListView: View {
    @ObservedObject var store: ActionStore
    let onOpenSource: (ActionSource) -> Void
    @State private var filter: ActionItem.Kind?
    @State private var editing: ActionItem?
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
                Button { editing = ActionItem(kind:.todo,title:"") } label: { Image(systemName:"plus.circle.fill").font(.title2) }.accessibilityLabel("新建行动")
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
        .sheet(item:$editing) { ActionEditor(store:store,item:$0) }
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
        Button { if item.status == .suggested { editing = item } else { detail = item } } label: {
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
    @State var item: ActionItem
    @Environment(\.dismiss) private var dismiss
    @State private var external = false
    @State private var lists: [ActionSystemList] = []
    @State private var listID = ""
    @State private var loading = false
    @State private var error: String?
    private var timeZone: TimeZone { TimeZone(identifier:item.timeZoneID) ?? .current }
    var body: some View {
        NavigationStack {
            Form {
                Section("行动内容") {
                    Picker("类型",selection:$item.kind) { ForEach(ActionItem.Kind.allCases,id:\.self) { Text($0.title).tag($0) } }
                        .disabled(item.legacyReminderID != nil || (item.link != nil && item.status != .suggested))
                    TextField("标题",text:$item.title)
                    TextField("备注（仅保存在本机）",text:$item.notes,axis:.vertical)
                }
                Section("时间") {
                    Toggle(item.kind == .todo ? "设置截止时间" : item.kind == .event ? "设置开始时间" : "设置提醒时间",isOn:Binding(get:{item.start != nil},set:{item.start = $0 ? Date.now.addingTimeInterval(3600) : nil}))
                    if item.start != nil { DatePicker(item.kind == .event ? "开始" : item.kind == .todo ? "截止" : "提醒",selection:Binding(get:{item.start ?? .now},set:{item.start = $0}),displayedComponents:item.allDay ? [.date] : [.date,.hourAndMinute]) }
                    if item.kind == .event {
                        Toggle("设置结束时间",isOn:Binding(get:{item.end != nil},set:{item.end = $0 ? (item.start ?? .now).addingTimeInterval(3600) : nil}))
                        if item.end != nil { DatePicker(item.allDay ? "结束日期（不含这一天）" : "结束",selection:Binding(get:{item.end ?? .now},set:{item.end = $0}),displayedComponents:item.allDay ? [.date] : [.date,.hourAndMinute]) }
                        Toggle("全天",isOn:$item.allDay)
                    }
                    Text("时区：\(item.timeZoneID)").font(.caption).foregroundStyle(.secondary)
                    if item.kind == .todo { Text("截止时间不会自动产生通知；需要通知请选择“提醒”。").font(.caption) }
                    if item.kind == .event && item.end == nil { Text("请补充结束时间，未默认安排时长。").font(.caption).foregroundStyle(.orange) }
                }.environment(\.timeZone,timeZone)
                Section("可选系统关联") {
                    Toggle("同时添加到 Apple \(item.kind == .event ? "日历" : "提醒事项")",isOn:$external)
                    if external {
                        if lists.isEmpty { Button("授权并选择系统列表") { loadLists() }.disabled(loading) }
                        else { Picker("列表",selection:$listID) { ForEach(lists) { Text($0.title).tag($0.id) } } }
                    }
                    if !external && item.link != nil { Text("保存后移除关联的系统项目，保留本机行动。").font(.caption).foregroundStyle(.orange) }
                    Text("只写入标题与时间，不发送录音、原话或本机备注。所选账户可能同步到云端。").font(.caption)
                }
                if let source = item.source {
                    Section("原话依据") { Text(source.quote.isEmpty ? "可在详情中打开来源记录。" : source.quote); Text(source.title).font(.caption).foregroundStyle(.secondary) }
                }
                if let error = error ?? store.error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle(item.status == .suggested ? "确认\(item.kind.title)" : "编辑\(item.kind.title)")
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button("确认保存") {
                        Task {
                            if external {
                                guard let list = lists.first(where:{$0.id == listID}) else { error = "请选择可写的系统列表。"; return }
                                item.link = .init(listID:list.id,listTitle:list.title,identifier:item.link?.identifier)
                            } else { item.link = nil }
                            if await store.save(item) { dismiss() }
                            else if let current = store.items.first(where:{$0.id == item.id}) { item = current }
                        }
                    }.disabled(store.busy || loading || item.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                external = item.link != nil
                if let link = item.link { lists = [.init(id:link.listID,title:link.listTitle)]; listID = link.listID }
            }
            .onChange(of:item.kind) { _,_ in external = false; lists = []; listID = ""; item.allDay = false }
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
