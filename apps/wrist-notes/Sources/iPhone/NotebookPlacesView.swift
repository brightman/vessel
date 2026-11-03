import SwiftUI

struct NotebookPlacesView:View {
    let onOpenSource:(UUID)->Void
    @State private var places:[NotebookPlace]=[]
    @State private var selected:NotebookPlace?
    @State private var loading=false
    @State private var more=false
    @State private var generation=UUID()
    @State private var error:String?
    init(onOpenSource:@escaping(UUID)->Void) { self.onOpenSource=onOpenSource }
    var body:some View {
        List {
            Section {
                Text("近 30 天 · 同一地点每天计 1 次").font(.subheadline)
                Text("按记录中的位置归组，附近地点可能归为同一区域。").font(.caption).foregroundStyle(DaybookStyle.secondary)
                Button("刷新") { Task { await load(reset:true) } }.disabled(loading)
            }
            if let error { Text(error).foregroundStyle(DaybookStyle.red) }
            if places.isEmpty && !loading { Text("暂无含原始拍摄或录制位置的记录。").foregroundStyle(DaybookStyle.secondary) }
            ForEach(places) { place in
                Button { selected=place } label: {
                    HStack {
                        Image(systemName:"mappin.circle").foregroundStyle(DaybookStyle.accent)
                        VStack(alignment:.leading,spacing:6) {
                            Text(place.name).font(.headline)
                            if let type=place.type { Text(type).font(.caption).foregroundStyle(DaybookStyle.secondary) }
                        }
                        Spacer();Text("\(place.days) 天").font(.headline).foregroundStyle(DaybookStyle.accent)
                    }.padding(.vertical,6)
                }.foregroundStyle(DaybookStyle.ink)
            }
            if loading { ProgressView("正在整理地点…") }
            if more { Button("加载更多") { Task { await load(reset:false) } }.disabled(loading) }
        }.scrollContentBackground(.hidden).background(DaybookStyle.paper).tint(DaybookStyle.accent)
            .task { await load(reset:true) }
            .sheet(item:$selected,onDismiss:{ Task { await load(reset:true) } }) { place in
                NotebookPlaceDetail(place:place,onOpenSource:onOpenSource)
            }
    }
    @MainActor private func load(reset:Bool) async {
        if loading && !reset { return }
        let token=UUID();generation=token;loading=true
        if reset { places=[];more=false }
        let offset=reset ? 0 : places.count
        do {
            let result=try await Task.detached {
                let repo=try NotebookPlacesRepository(database:DaybookDatabase())
                if reset { try repo.rebuild() }
                return try repo.page(offset:offset)
            }.value
            guard generation==token,!Task.isCancelled else { return }
            places=reset ? result : places+result;more=result.count==40;error=nil
        } catch {
            guard generation==token,!Task.isCancelled else { return }
            self.error=error.localizedDescription
        }
        guard generation==token else { return };loading=false
    }
}

private struct NotebookPlaceDetail:View {
    let place:NotebookPlace
    let onOpenSource:(UUID)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var name:String
    @State private var type:String?
    @State private var revision:Int
    @State private var visits:[NotebookPlaceVisit]=[]
    @State private var more=true
    @State private var loading=false
    @State private var saving=false
    @State private var error:String?
    init(place:NotebookPlace,onOpenSource:@escaping(UUID)->Void) {
        self.place=place;self.onOpenSource=onOpenSource
        _name=State(initialValue:place.name == "未命名区域" ? "" : place.name)
        _type=State(initialValue:place.type);_revision=State(initialValue:place.revision)
    }
    private var days:[String] { Array(Set(visits.map(\.day))).sorted(by:>) }
    var body:some View {
        NavigationStack {
            List {
                Section("地点标记") {
                    TextField("地点名称",text:$name)
                    if let coordinateHint=place.coordinateHint { Text(coordinateHint).font(.caption).foregroundStyle(DaybookStyle.secondary) }
                    Picker("类型",selection:$type) {
                        Text("未标记").tag(String?.none)
                        ForEach(NotebookPlaceGrid.types,id:\.self) { Text($0).tag(Optional($0)) }
                    }
                    Button(saving ? "保存中…" : "保存标记") { save() }.disabled(saving)
                    Text("手动名称独立保存，更名不改变计数；来源删除后仍保留名称。").font(.caption).foregroundStyle(DaybookStyle.secondary)
                }
                if let error { Text(error).foregroundStyle(DaybookStyle.red) }
                ForEach(days,id:\.self) { day in
                    Section(day) {
                        ForEach(visits.filter{$0.day==day}) { visit in
                            Button { dismiss();onOpenSource(visit.sourceID) } label: {
                                VStack(alignment:.leading,spacing:5) {
                                    Text("\(visit.sourceKind) · \(time(visit))")
                                    if visit.dateBasis.contains("未知") { Text(visit.dateBasis).font(.caption).foregroundStyle(DaybookStyle.secondary) }
                                }
                            }
                        }
                    }
                }
                if loading { ProgressView() }
                if more { Button("加载更多来源") { Task { await load() } }.disabled(loading) }
            }.scrollContentBackground(.hidden).background(DaybookStyle.paper)
                .navigationTitle(place.name).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() }.disabled(saving) }
        }.tint(DaybookStyle.accent).task { await load() }
    }
    private func time(_ visit:NotebookPlaceVisit)->String {
        let formatter=DateFormatter();formatter.dateFormat="HH:mm:ss";formatter.timeZone=TimeZone(identifier:visit.timeZoneIdentifier) ?? TimeZone(secondsFromGMT:0)!
        return formatter.string(from:visit.capturedAt)
    }
    @MainActor private func load() async {
        guard !loading else { return };loading=true
        let id=place.id,offset=visits.count
        do {
            let result=try await Task.detached { try NotebookPlacesRepository(database:DaybookDatabase()).visits(placeID:id,offset:offset) }.value
            guard !Task.isCancelled else { return };visits+=result;more=result.count==50;error=nil
        } catch { self.error=error.localizedDescription }
        loading=false
    }
    private func save() {
        saving=true
        let id=place.id,name=name,type=type,revision=revision
        Task {
            do {
                try await Task.detached { try NotebookPlacesRepository(database:DaybookDatabase()).saveLabel(id:id,name:name,type:type,expectedRevision:revision) }.value
                self.revision=revision+1;error=nil
            } catch { self.error=error.localizedDescription }
            saving=false
        }
    }
}
