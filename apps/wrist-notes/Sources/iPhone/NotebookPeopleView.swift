import SwiftUI

struct NotebookRelationshipEditor: View {
    @Binding var selection:[String]
    @State private var custom=""
    var body:some View {
        Section("关系（可多选）") {
            ForEach(NotebookRelationships.normalized(NotebookRelationships.presets+selection),id:\.self) { value in
                Button {
                    if selection.contains(value) { selection.removeAll{$0==value} } else { selection.append(value) }
                } label: {
                    HStack { Text(value); Spacer(); if selection.contains(value) { Image(systemName:"checkmark") } }
                }.foregroundStyle(DaybookStyle.ink)
            }
            HStack {
                TextField("自定义关系",text:$custom)
                Button("添加") { selection=NotebookRelationships.normalized(selection+[custom]); custom="" }
                    .disabled(custom.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
            Text("未选择时留空，不会自动归类。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct NotebookPeopleView: View {
    let onOpenSource:(UUID)->Void
    @State private var people:[NotebookPerson]=[]
    @State private var filters:[String]=NotebookRelationships.presets
    @State private var filter:String?
    @State private var editing:NotebookPerson?
    @State private var adding=false
    @State private var selected:NotebookPerson?
    @State private var more=true
    @State private var loading=false
    @State private var loadGeneration=UUID()
    @State private var error:String?
    init(onOpenSource:@escaping(UUID)->Void) { self.onOpenSource=onOpenSource }
    var body:some View {
        List {
            Section {
                Button("添加联系人") { adding=true }
                Picker("关系筛选",selection:$filter) {
                    Text("全部关系").tag(String?.none)
                    ForEach(filters,id:\.self) { Text($0).tag(Optional($0)) }
                }
            }
            if let error { Text(error).foregroundStyle(DaybookStyle.red); Button("刷新") { Task { await load(reset:true) } } }
            if people.isEmpty && !loading { Text("暂无联系人，可添加本地联系人。").foregroundStyle(DaybookStyle.secondary) }
            ForEach(people) { person in
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        Text(person.name).font(.headline); Spacer()
                        Button("编辑") { editing=person }
                    }
                    if let organization=person.organization,!organization.isEmpty { Text(organization).font(.subheadline) }
                    if !person.relationships.isEmpty { Text(person.relationships.joined(separator:" · ")).font(.caption).foregroundStyle(DaybookStyle.accent) }
                    Button("关联录音") { selected=person }.font(.caption)
                }.padding(.vertical,6)
            }
            if more { Button(loading ? "读取中…" : "加载更多") { Task { await load(reset:false) } }.disabled(loading) }
        }.scrollContentBackground(.hidden).background(DaybookStyle.paper)
            .tint(DaybookStyle.accent)
            .task(id:filter) { await load(reset:true) }
            .sheet(isPresented:$adding) { NotebookPersonForm(person:nil) { adding=false; Task { await load(reset:true) } } }
            .sheet(item:$editing) { person in NotebookPersonForm(person:person) { editing=nil; Task { await load(reset:true) } } }
            .sheet(item:$selected) { person in NotebookPersonSourcesView(person:person,onOpenSource:onOpenSource) }
    }
    @MainActor private func load(reset:Bool) async {
        if loading && !reset { return }
        let generation=UUID();loadGeneration=generation;loading=true
        if reset { people=[]; more=false }
        let requestedFilter=filter,offset=reset ? 0 : people.count
        do {
            let result=try await Task.detached {
                let repo=try NotebookPeopleRepository(database:DaybookDatabase())
                return (try repo.page(relationship:requestedFilter,offset:offset),try repo.relationships())
            }.value
            guard generation==loadGeneration,requestedFilter==filter,!Task.isCancelled else { return }
            people=reset ? result.0 : people+result.0; more=result.0.count==40
            filters=NotebookRelationships.normalized(NotebookRelationships.presets+result.1); error=nil
        } catch {
            guard generation==loadGeneration,!Task.isCancelled else { return }
            self.error=error.localizedDescription
        }
        guard generation==loadGeneration else { return }
        loading=false
    }
}

private struct NotebookPersonForm:View {
    let person:NotebookPerson?
    let onSaved:()->Void
    @Environment(\.dismiss) private var dismiss
    @State private var name:String
    @State private var organization:String
    @State private var relationships:[String]
    @State private var saving=false
    @State private var error:String?
    init(person:NotebookPerson?,onSaved:@escaping()->Void) {
        self.person=person;self.onSaved=onSaved
        _name=State(initialValue:person?.name ?? "");_organization=State(initialValue:person?.organization ?? "")
        _relationships=State(initialValue:person?.relationships ?? [])
    }
    var body:some View {
        NavigationStack {
            Form {
                Section("联系人信息") { TextField("姓名",text:$name); TextField("公司",text:$organization) }
                NotebookRelationshipEditor(selection:$relationships)
                Text("仅保存在 WiseLife，不修改系统通讯录。").font(.caption)
                if let error { Text(error).foregroundStyle(DaybookStyle.red) }
            }.navigationTitle(person == nil ? "添加联系人" : "编辑联系人")
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement:.confirmationAction) { Button("保存") {
                        saving=true
                        let id=person?.id,revision=person?.revision,name=name,org=organization,relations=relationships
                        Task {
                            do {
                                _ = try await Task.detached { try NotebookPeopleRepository(database:DaybookDatabase()).save(id:id,expectedRevision:revision,name:name,organization:org,relationships:relations) }.value
                                onSaved()
                            } catch { self.error=error.localizedDescription; saving=false }
                        }
                    }.disabled(saving || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
                }
        }
    }
}
private struct NotebookPersonSourcesView:View {
    let person:NotebookPerson
    let onOpenSource:(UUID)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var sources:[NotebookPersonSource]=[]
    @State private var more=true
    @State private var loading=false
    @State private var error:String?
    var body:some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(DaybookStyle.red) }
                if sources.isEmpty && !loading { Text("暂无关联录音。解除关联或删除来源不会删除联系人。") }
                ForEach(sources) { source in
                    Button { dismiss(); onOpenSource(source.sourceID) } label: {
                        VStack(alignment:.leading,spacing:5) {
                            Text(source.capturedAt,format:.dateTime.year().month().day().hour().minute())
                            Text(speakerLabel(source.speakerID)).font(.caption)
                            if let start=source.start,let end=source.end { Text("发言范围 \(Int(start))–\(Int(end)) 秒").font(.caption) }
                            if source.needsReview { Text("说话人识别已变化，请复核关联").font(.caption).foregroundStyle(DaybookStyle.red) }
                        }
                    }
                }
                if more { Button(loading ? "读取中…" : "加载更多") { Task { await load() } }.disabled(loading) }
            }.navigationTitle(person.name).toolbar { Button("完成") { dismiss() } }
        }.task { await load() }
    }
    private func speakerLabel(_ id:String)->String {
        let suffix=id.hasPrefix("speaker-") ? String(id.dropFirst("speaker-".count)) : ""
        if !suffix.isEmpty,suffix.allSatisfy(\.isNumber) { return "说话人 \(suffix)" }
        return "说话人"
    }
    @MainActor private func load() async {
        guard !loading else { return }; loading=true
        let id=person.id,offset=sources.count
        do {
            let result=try await Task.detached { try NotebookPeopleRepository(database:DaybookDatabase()).sources(contactID:id,offset:offset) }.value
            sources+=result;more=result.count==30;error=nil
        } catch { self.error=error.localizedDescription }
        loading=false
    }
}
