import SwiftUI

extension Notification.Name {
    static let notebookReturnToSettings = Notification.Name("notebook.returnToSettings")
    static let notebookOpenSource = Notification.Name("notebook.openSource")
    static let notebookAssetSaved = Notification.Name("notebook.assetSaved")
}

struct FlashNotebookView: View {
    enum Tab: String, CaseIterable { case ideas, expenses, people, places
        var title: String { switch self { case .ideas: "灵感"; case .expenses: "记账"; case .people: "人物"; case .places: "地点" } }
        var subtitle: String { switch self {
        case .ideas: "想到的时候，留下来。"
        case .expenses: "每一笔，都有迹可循。"
        case .people: "记住与你相遇的人。"
        case .places: "那些经常出现的地方。"
        } }
    }
    var kind: FlashAsset.Kind? = nil
    let onClose: () -> Void
    let onOpenSource: (UUID) -> Void
    @AppStorage("notebook.lastTab") private var savedTab = Tab.ideas.rawValue
    @State private var tab = Tab.ideas
    var body: some View {
        VStack(spacing:0) {
            VStack(alignment:.leading,spacing:16) {
                HStack {
                    Button { onClose(); NotificationCenter.default.post(name:.notebookReturnToSettings,object:nil) } label: {
                        Label("设置",systemImage:"chevron.left").font(.system(size:15)).frame(minHeight:44)
                    }.accessibilityIdentifier("notebook.back")
                    Spacer(); Text("记事本").font(.system(size:13)).foregroundStyle(DaybookStyle.secondary)
                }
                VStack(alignment:.leading,spacing:8) {
                    Text(tab.title).font(.system(size:30,weight:.semibold)).accessibilityAddTraits(.isHeader)
                    Text(tab.subtitle).font(.system(size:14)).foregroundStyle(DaybookStyle.secondary)
                }
                Picker("记事本分类",selection:$tab) {
                    ForEach(Tab.allCases,id:\.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("notebook.tabs")
            }.padding(.horizontal,24).padding(.top,14).padding(.bottom,12)
            Group {
                switch tab {
                case .ideas: NotebookLedgerView(kind:.idea,onOpenSource:onOpenSource)
                case .expenses: NotebookLedgerView(kind:.expense,onOpenSource:onOpenSource)
                case .people: NotebookPeopleView(onOpenSource:onOpenSource)
                case .places: NotebookPlacesView(onOpenSource:onOpenSource)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        }.background(DaybookStyle.paper.ignoresSafeArea()).foregroundStyle(DaybookStyle.ink)
            .tint(DaybookStyle.accent).presentationCornerRadius(28).presentationDragIndicator(.visible)
            .onAppear { tab=kind.map { $0 == .idea ? .ideas : .expenses } ?? Tab(rawValue:savedTab) ?? .ideas }
            .onChange(of:tab) { _,value in savedTab=value.rawValue }
    }
}

struct NotebookLedgerView: View {
    let kind: FlashAsset.Kind
    let onOpenSource: (UUID) -> Void
    @StateObject private var model=NotebookIdeasModel()
    @State private var month=NotebookIdeasModel.currentMonth
    @State private var currency=""
    @State private var filter="all"
    @State private var showRevoked=false
    @State private var selecting=false
    @State private var selectedIDs=Set<UUID>()
    @State private var selected: FlashAsset?
    @State private var newAsset: FlashAsset?
    @State private var generationSeeds:[FlashAsset]=[]
    @State private var showGenerate=false
    private var filterKey: String { "\(kind.rawValue)|\(month)|\(currency)|\(filter)|\(showRevoked)" }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack {
                    if kind == .idea {
                        Button(selecting ? "取消选择" : "选择") { selecting.toggle(); selectedIDs=[] }
                        Spacer()
                    } else {
                        Picker("月份",selection:$month) { ForEach(Array(Set(model.months+[month])).sorted(by:>),id:\.self) { Text($0).tag($0) } }
                            .accessibilityIdentifier("notebook.month")
                        Spacer()
                    }
                    Button { newAsset=makeAsset() } label: { Label(kind == .idea ? "新建灵感" : "记一笔",systemImage:"plus") }
                        .accessibilityIdentifier("notebook.add")
                }.font(.system(size:14,weight:.medium)).frame(minHeight:44)
                if kind == .expense { ledgerSummary }
                if kind == .idea && !model.drafts.isEmpty {
                    Menu {
                        ForEach(model.drafts) { draft in
                            Button("\(RecordingFormat.date(draft.createdAt)) · \(draft.candidates.count - draft.savedCandidateIDs.count) 条未保存") { model.result=draft }
                        }
                    } label: { Label("AI 再创作草稿（\(model.drafts.count)）",systemImage:"sparkles").font(.system(size:13)) }
                }
                if model.loading && model.rows.isEmpty { ProgressView("正在读取记事本…").frame(maxWidth:.infinity) }
                else if model.rows.isEmpty {
                    DaybookQuietInfo(text:kind == .idea ? "还没有灵感。主动录下的闪念会自动保存，也可以手动新建。" : "这个月还没有符合条件的账目。")
                }
                LazyVStack(spacing:0) {
                    ForEach(model.rows) { item in
                        Button {
                            if selecting {
                                if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
                                else if selectedIDs.count < 10 && !item.revoked { selectedIDs.insert(item.id) }
                            } else { selected=item }
                        } label: { row(item) }.buttonStyle(.plain)
                            .accessibilityIdentifier("notebook.asset.\(item.id.uuidString)")
                    }
                    if model.canLoadMore { Button("加载更多") { Task { await model.reload(more:true) } }.padding(.vertical,18).disabled(model.loading) }
                }
                if selecting {
                    Button("让 AI 再创作 · 已选 \(selectedIDs.count) 条") {
                        generationSeeds=model.rows.filter { selectedIDs.contains($0.id) }; showGenerate=true
                    }.buttonStyle(DaybookPrimaryButtonStyle(wide:true)).disabled(selectedIDs.count < 2)
                    Text("选择 2 至 10 条灵感，生成结果另存，保留原想法。").font(.system(size:12)).foregroundStyle(DaybookStyle.secondary)
                }
                Toggle("显示已撤销",isOn:$showRevoked).font(.system(size:13))
                if kind == .idea { Text("普通长录音不会自动加入灵感。").font(.system(size:12)).foregroundStyle(DaybookStyle.secondary) }
                if let error=model.error {
                    Text(error).font(.system(size:13)).foregroundStyle(DaybookStyle.red)
                    Button("重新加载") { Task { await model.reload() } }
                }
            }.padding(.horizontal,24).padding(.vertical,4).padding(.bottom,24)
        }.scrollDismissesKeyboard(.interactively)
            .task(id:filterKey) {
                model.kind=kind; model.month=month; model.currency=currency.isEmpty ? nil : currency
                model.direction=FlashAsset.Direction(rawValue:filter); model.pending=filter == "pending"; model.showRevoked=showRevoked
                selectedIDs=[]; await model.reload()
            }
            .sheet(item:$selected) { item in NotebookAssetDetail(model:model,opening:item,onOpenSource:{ id in selected=nil; onOpenSource(id) }) }
            .sheet(item:$newAsset) { NotebookAssetEditor(model:model,item:$0,isNew:true) }
            .sheet(isPresented:$showGenerate,onDismiss:{ model.cancelGeneration() }) { NotebookGenerateView(model:model,seeds:generationSeeds) }
            .sheet(item:Binding(get:{ showGenerate ? nil : model.result },set:{ model.result=$0 })) { draft in NotebookCandidateView(model:model,draft:draft) }
            .onReceive(NotificationCenter.default.publisher(for:.notebookAssetSaved)) { _ in Task { await model.reload() } }
    }
    @ViewBuilder private var ledgerSummary: some View {
        VStack(alignment:.leading,spacing:14) {
            if model.totals.isEmpty { Text("本月暂无已确认收支").font(.system(size:14)).foregroundStyle(DaybookStyle.secondary) }
            ForEach(model.totals,id:\.currency) { total in
                VStack(alignment:.leading,spacing:10) {
                    Text(total.currency).font(.system(size:12,weight:.medium)).foregroundStyle(DaybookStyle.secondary)
                    HStack(alignment:.top) {
                        Button { currency=total.currency; filter="expense" } label: { metric("支出",value:total.expense,currency:total.currency) }
                        Spacer()
                        Button { currency=total.currency; filter="income" } label: { metric("收入",value:total.income,currency:total.currency) }
                    }.buttonStyle(.plain)
                    Text("结余 \(FlashMoney.decimalString(total.income-total.expense,currency:total.currency))").font(.system(size:13)).foregroundStyle(DaybookStyle.secondary)
                }.daybookRecordingCard(padding:16)
            }
            Picker("账目筛选",selection:$filter) {
                Text("全部").tag("all"); Text("支出").tag("expense"); Text("收入").tag("income"); Text("待补充").tag("pending")
            }.pickerStyle(.segmented)
            Picker("币种",selection:$currency) {
                Text("全部币种").tag("")
                ForEach(Array(Set(model.totals.map(\.currency)+(currency.isEmpty ? [] : [currency]))).sorted(),id:\.self) { Text($0).tag($0) }
            }.font(.system(size:13))
            Text("按账目发生月汇总，各币种分别计算；待补充与已撤销账目不计入。缺日期账目暂按录制月显示。").font(.system(size:12)).foregroundStyle(DaybookStyle.secondary)
        }
    }
    private func metric(_ title:String,value:Int64,currency:String) -> some View {
        VStack(alignment:.leading,spacing:6) { Text(title).font(.system(size:13)).foregroundStyle(DaybookStyle.secondary); Text(FlashMoney.decimalString(value,currency:currency)).font(.system(size:26,weight:.medium)).monospacedDigit().foregroundStyle(DaybookStyle.ink) }
    }
    private func row(_ item:FlashAsset) -> some View {
        HStack(alignment:.top,spacing:12) {
            if selecting { Image(systemName:selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(DaybookStyle.accent).padding(.top,3) }
            VStack(alignment:.leading,spacing:8) {
                HStack(alignment:.top) { Text(item.title).font(.system(size:16,weight:.medium)); if kind == .expense { Spacer(); Text(item.amountText).font(.system(size:15,weight:.medium)).monospacedDigit() } }
                if kind == .idea { Text(item.text).font(.system(size:14)).lineSpacing(5).lineLimit(3).foregroundStyle(DaybookStyle.bodyText) }
                Text(kind == .idea ? "\(RecordingFormat.date(item.source.capturedAt)) · \(item.origin == .generated ? "AI 再创作" : item.origin == .manual ? "手动记录" : "闪念")\(item.revoked ? " · 已撤销" : "")" : "\(item.date ?? "日期待补充") · \(item.category ?? "未分类") · \(item.statusTitle)")
                    .font(.system(size:12)).foregroundStyle(DaybookStyle.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.padding(.vertical,16).contentShape(Rectangle()).overlay(alignment:.bottom) { DaybookStyle.line.frame(height:0.5) }
    }
    private func makeAsset() -> FlashAsset {
        let now=Date.now, id=UUID()
        let source=ActionSource(id:id,title:"手动记录",quote:"",capturedAt:now,timeZoneID:TimeZone.current.identifier,recordingKind:"manual",timeZoneKnown:true)
        var item=FlashAsset(kind:kind,title:"",text:"",source:source); item.id=id; item.origin = .manual
        if kind == .expense { item.direction = .expense; item.currency=Locale.current.currency?.identifier ?? "CNY"; let formatter=DateFormatter(); formatter.locale=Locale(identifier:"en_US_POSIX"); formatter.dateFormat="yyyy-MM-dd"
            item.date=month == NotebookIdeasModel.currentMonth ? formatter.string(from:now) : month+"-01" }
        return item
    }
}

struct NotebookSourceView<Content:View>: View {
    let id:UUID
    let onClose:()->Void
    @ViewBuilder let content:(NotebookSourceLookup.Kind)->Content
    @State private var kind:NotebookSourceLookup.Kind?
    @State private var loading=true
    @State private var error:String?
    var body:some View {
        Group {
            if let kind { content(kind) }
            else {
                DaybookSheetLayout(title:"来源记录",onClose:onClose) {
                    if loading { ProgressView("正在读取来源…") }
                    else {
                        Text(error ?? "来源记录已不存在，记事本中保存的内容仍保留。").font(.system(size:14)).foregroundStyle(DaybookStyle.secondary)
                        if error != nil { Button("重试") { Task { await load() } } }
                    }
                }
            }
        }.task(id:id) { await load() }
    }
    private func load() async {
        loading=true
        do {
            let id=id
            let result=try await Task.detached { try NotebookSourceLookup.kind(id,database:DaybookDatabase()) }.value
            guard !Task.isCancelled else { return };kind=result;error=nil
        } catch { guard !Task.isCancelled else { return };self.error=error.localizedDescription }
        loading=false
    }
}
