import Foundation
import CryptoKit
import CoreFoundation

/// A run-local, read-only capability. Every operation intersects the prepared evidence scope.
@MainActor final class AskAIReadTools {
    struct ToolResult: Sendable { let text: String; let status: String; let evidenceIDs: [String] }
    struct Evidence: Sendable { let id: String; let source: DaybookRetrieval.Source }
    struct Finalized: Sendable { let text: String; let sources: [DaybookRetrieval.Source]; let prepared: DaybookRetrieval.Prepared }
    enum Failure: Error { case unknownTool, invalidArguments, callLimit, staleEvidence, invalidCitation }
    private let prepared: DaybookRetrieval.Prepared
    private let records: [DayRecord]
    private let history: [DaybookConversationTurn]
    private let semanticSearch: (any DaybookSemanticSearching)?
    private let recordsReader: (@MainActor () throws -> [DayRecord])?
    private let scopeIsCurrent: (@MainActor () -> Bool)?
    private(set) var evidence: [Evidence] = []
    private(set) var toolCallCount = 0
    private var evidenceKeys: [String: Int] = [:]

    init(prepared: DaybookRetrieval.Prepared, records: [DayRecord], history: [DaybookConversationTurn] = [],
         semanticSearch: (any DaybookSemanticSearching)? = nil,
         recordsReader: (@MainActor () throws -> [DayRecord])? = nil, scopeIsCurrent: (@MainActor () -> Bool)? = nil) {
        self.prepared = prepared; self.records = records; self.history = history; self.semanticSearch = semanticSearch
        self.recordsReader = recordsReader; self.scopeIsCurrent = scopeIsCurrent
        for source in prepared.sources { _ = register(source, key: source.id.uuidString + "|0") }
    }

    static var toolDefinitions: [[String: Any]] {
        let query: [String: Any] = ["type":"string", "maxLength":300, "description":"Literal topic to find in the original records"]
        let date: [String: Any] = ["type":"string", "description":"ISO 8601 timestamp, inside the initial allowed time range"]
        let kinds: [String: Any] = ["type":"array", "items":["type":"string", "enum":["voice","thought","image","activity","sleep","calendar","location"]]]
        let scope: [String: Any] = ["start":date,"end":date,"kinds":kinds]
        func definition(_ name: String, _ description: String, _ properties: [String:Any], _ required: [String]) -> [String:Any] {
            ["name":name,"description":description,"parameters":["type":"object","properties":properties,"required":required,"additionalProperties":false]]
        }
        var search = scope; search["query"] = query; search["limit"] = ["type":"integer","minimum":1,"maximum":8]
        var metrics = scope; metrics["metric"] = ["type":"string","enum":["recordCount","audioDurationSeconds","steps","sleepSeconds","workoutDurationSeconds"]]
        return [definition("searchRecords","Search allowed original records; cannot expand initial dates or permissions",search,["query"]),
                definition("readRecord","Read original text by record ID. Only first 200 characters of each window can be cited; choose offset near the fact. Speaker mode returns associated excerpt only",["id":["type":"string","format":"uuid"],"offset":["type":"integer","minimum":0],"limit":["type":"integer","minimum":1,"maximum":1200]],["id"]),
                definition("aggregateMetrics","Compute typed local observations; missing observations are not zero",metrics,["metric"]),
                definition("searchConversationHistory","Return prior user questions as background intent only; never factual evidence",["query":query,"limit":["type":"integer","minimum":1,"maximum":5]],["query"])]
    }

    func execute(name: String, arguments: Data) async throws -> ToolResult {
        try Task.checkCancellation()
        guard toolCallCount < 6 else { throw Failure.callLimit }
        toolCallCount += 1
        guard Self.toolDefinitions.contains(where: { $0["name"] as? String == name }) else { throw Failure.unknownTool }
        guard arguments.count <= 2048, let args = try? JSONSerialization.jsonObject(with: arguments) as? [String:Any] else { throw Failure.invalidArguments }
        let allowed: Set<String>
        switch name {
        case "searchRecords": allowed = ["query","start","end","kinds","limit"]
        case "readRecord": allowed = ["id","offset","limit"]
        case "aggregateMetrics": allowed = ["metric","start","end","kinds"]
        default: allowed = ["query","limit"]
        }
        guard Set(args.keys).isSubset(of:allowed) else { throw Failure.invalidArguments }
        let current = try currentRecords()
        if name == "searchConversationHistory" {
            let query = try string(args,"query",max:300)
            let limit = try integer(args,"limit",default:3,range:1...5)
            let turns = history.filter { $0.completionState == .completed && $0.evidence.allowedKinds.isSubset(of:prepared.evidence.allowedKinds) && $0.question.localizedCaseInsensitiveContains(query) }.suffix(limit)
            // Assistant prose and old numeric references are never carried forward as facts.
            let text = turns.map { stripCitations(String($0.question.prefix(300))) }.joined(separator:"\n")
            return .init(text:"Background user intent only; re-read current records for facts.\n" + text,status:"background",evidenceIDs:[])
        }
        if name == "readRecord" {
            let idText = try string(args,"id",max:36)
            guard let id = UUID(uuidString:idText) else { throw Failure.invalidArguments }
            let offset = try integer(args,"offset",default:0,range:0...1_000_000)
            let limit = try integer(args,"limit",default:800,range:1...1200)
            if prepared.evidence.speakerContactID != nil {
                guard let source = prepared.sources.first(where: { $0.id == id }) else { return empty() }
                guard offset == 0 else { return empty() }
                return result([register(source,key:id.uuidString + "|0")])
            }
            guard let record = scoped(current,start:prepared.dayStart,end:prepared.dayEnd,kinds:prepared.evidence.allowedKinds).first(where: { $0.id == id }) else { return empty() }
            guard offset < record.text.count else { return empty() }
            let window = String(record.text.dropFirst(offset).prefix(limit))
            let entry = register(source(record,text:window),key:id.uuidString + "|\(offset)")
            // The larger read window is tool context only; persisted final snippets remain <=200.
            return .init(text:"[\(entry.source.number)] id=\(id.uuidString) offset=\(offset)\n\(window)",status:"ok",evidenceIDs:[entry.id])
        }
        let (start,end,kinds) = try scope(args)
        if name == "searchRecords" {
            let query = try string(args,"query",max:300)
            let limit = try integer(args,"limit",default:5,range:1...8)
            if prepared.evidence.speakerContactID != nil {
                let matches = prepared.sources.filter { $0.capturedAt >= start && $0.capturedAt < end && kinds.contains($0.kind) && ($0.snippet.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query)) }.prefix(limit)
                return result(matches.map { register($0,key:$0.id.uuidString + "|0") })
            }
            let candidates = scoped(current,start:start,end:end,kinds:kinds)
            var semanticIDs: [UUID] = []
            if let semanticSearch {
                let found = await semanticSearch.search(query:query,records:current,dayStart:start,dayEnd:end,allowedKinds:kinds,limit:limit)
                _ = try currentRecords()
                if found.evidence.isCurrent(records:current,allowedKinds:kinds) { semanticIDs = found.hits.map(\.id) }
            }
            let terms = DaybookRetrieval.keywords(query)
            let ranked = candidates.compactMap { record -> (DayRecord,Int)? in
                let score = DaybookRetrieval.keywordScore(record,terms:terms)
                let semanticRank = semanticIDs.firstIndex(of:record.id).map { 100 - $0 } ?? 0
                return score > 0 || semanticRank > 0 ? (record,score * 100 + semanticRank) : nil
            }.sorted { $0.1 == $1.1 ? ($0.0.capturedAt == $1.0.capturedAt ? $0.0.id.uuidString < $1.0.id.uuidString : $0.0.capturedAt < $1.0.capturedAt) : $0.1 > $1.1 }
            return result(ranked.prefix(limit).map { register(source($0.0,text:$0.0.text),key:$0.0.id.uuidString + "|0") })
        }
        guard prepared.evidence.speakerContactID == nil else { return .init(text:"Metrics are unavailable in associated-speaker scope.",status:"unsupported",evidenceIDs:[]) }
        let metric = try string(args,"metric",max:40)
        guard ["recordCount","audioDurationSeconds","steps","sleepSeconds","workoutDurationSeconds"].contains(metric) else { throw Failure.invalidArguments }
        let records = scoped(current,start:start,end:end,kinds:kinds).sorted { $0.capturedAt == $1.capturedAt ? $0.id.uuidString < $1.id.uuidString : $0.capturedAt < $1.capturedAt }.filter { record in
            switch metric { case "steps","workoutDurationSeconds": return record.kind == .activity
            case "sleepSeconds": return record.kind == .sleep
            case "audioDurationSeconds": return record.kind.isAudio
            default: return true }
        }
        var values: [(DayRecord, Double)] = []; var missing = 0; var intervals: [DateInterval] = []
        for record in records {
            let value: Double?
            var interval: DateInterval?
            switch metric {
            case "recordCount": value = 1
            case "audioDurationSeconds": value = record.duration
            case "steps": value = record.lifeMoment?.steps?.count; interval = record.lifeMoment?.steps?.interval
            case "sleepSeconds": value = record.lifeMoment?.sleep?.asleepSeconds
                if let a = record.lifeMoment?.sleep?.startedAt, let b = record.lifeMoment?.sleep?.endedAt, b > a { interval = DateInterval(start:a,end:b) }
            default: value = record.lifeMoment?.workout?.duration
                if let workout = record.lifeMoment?.workout, workout.endedAt > workout.startedAt { interval = DateInterval(start:workout.startedAt,end:workout.endedAt) }
            }
            // Sleep belongs to its wake date and workouts to their start date (existing projection).
            // Steps need full interval containment; no health sample is prorated. Overlap is explicit missing coverage.
            if let interval {
                guard (metric != "steps" || (interval.start >= start && interval.end <= end)), !intervals.contains(where: { max($0.start,interval.start) < min($0.end,interval.end) }) else { missing += 1; continue }
                intervals.append(interval)
            }
            guard let value, value.isFinite, value >= 0 else { missing += 1; continue }
            values.append((record,value))
        }
        let included = Array(values.prefix(5))
        let omitted = values.count - included.count
        let total = included.reduce(0) { $0 + $1.1 }
        guard total.isFinite else { return .init(text:"Metric total is unavailable.",status:"unavailable",evidenceIDs:[]) }
        let status = values.isEmpty ? "unavailable" : (missing > 0 || omitted > 0) ? "partial" : "ok"
        let entries = included.map { register(source($0.0,text:"Program typed observation: \(metric)=\($0.1)"),key:$0.0.id.uuidString + "|metric|" + metric) }
        return .init(text:"Program aggregate \(metric): value=\(values.isEmpty ? "missing" : String(format:"%.12g",total)); observed=\(included.count); missing=\(missing); excludedByLimit=\(omitted). " + ((missing > 0 || omitted > 0) ? "Bounded observed subset only; not a complete total." : "") + "\n" + entries.map { "[\($0.source.number)] \($0.source.snippet)" }.joined(separator:"\n"),status:status,evidenceIDs:entries.map(\.id))
    }

    func finalize(answer: String) throws -> Finalized {
        _ = try currentRecords()
        guard !answer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, answer.count <= 8000 else { throw Failure.invalidCitation }
        let regex = try NSRegularExpression(pattern:#"\[(\d+)\]"#)
        let matches = regex.matches(in:answer,range:NSRange(answer.startIndex...,in:answer))
        guard evidence.isEmpty || !matches.isEmpty else { throw Failure.invalidCitation }
        var selected: [DaybookRetrieval.Source] = []; var mapping: [Int:Int] = [:]
        for match in matches {
            guard let range = Range(match.range(at:1),in:answer), let number = Int(answer[range]), let entry = evidence.first(where: { $0.source.number == number }) else { throw Failure.invalidCitation }
            if mapping[number] != nil { continue }
            guard !selected.contains(where: { $0.id == entry.source.id }) else { throw Failure.invalidCitation }
            guard selected.count < 5 else { throw Failure.invalidCitation }
            let final = renumber(entry.source,number:selected.count + 1)
            mapping[number] = final.number; selected.append(final)
        }
        var text = answer
        for match in matches.reversed() {
            guard let numberRange = Range(match.range(at:1),in:answer), let number = Int(answer[numberRange]), let range = Range(match.range,in:text) else { continue }
            text.replaceSubrange(range,with:mapping[number].map { "[\($0)]" } ?? "")
        }
        let context = selected.map { "[\($0.number)] \($0.capturedAt.ISO8601Format()) \($0.kind.rawValue) · \(prepared.evidence.speakerContactID == nil ? $0.title : "已关联说话人的发言")\n\($0.snippet)" }.joined(separator:"\n")
        return .init(text:text,sources:selected,prepared:prepared.projecting(sources:selected,context:context))
    }

    private func currentRecords() throws -> [DayRecord] {
        try Task.checkCancellation()
        if let scopeIsCurrent, !scopeIsCurrent() { throw Failure.staleEvidence }
        let value = LegacyAudioDeletionLedger.shared.filter(try recordsReader?() ?? records)
        if prepared.evidence.speakerContactID == nil && !prepared.isCurrent(records:value,allowedKinds:prepared.evidence.allowedKinds) { throw Failure.staleEvidence }
        if prepared.sources.contains(where: { source in source.provenance.map { $0.sourceKind == "legacyNote" && LegacyAudioDeletionLedger.shared.contains($0.sourceID) } ?? LegacyAudioDeletionLedger.shared.contains(source.id) }) { throw Failure.staleEvidence }
        return value
    }
    private func scope(_ args: [String:Any]) throws -> (Date,Date,Set<DayRecord.Kind>) {
        func date(_ key:String,_ fallback:Date) throws -> Date {
            guard let raw = args[key] else { return fallback }
            guard let text = raw as? String, let value = ISO8601DateFormatter().date(from:text) else { throw Failure.invalidArguments }
            return value
        }
        let start = try date("start",prepared.dayStart), end = try date("end",prepared.dayEnd)
        guard start >= prepared.dayStart, end <= prepared.dayEnd, start < end else { throw Failure.invalidArguments }
        var kinds = prepared.evidence.allowedKinds
        if let raw = args["kinds"] {
            guard let names = raw as? [String], !names.isEmpty else { throw Failure.invalidArguments }
            let values = names.compactMap(DayRecord.Kind.init(rawValue:))
            guard values.count == names.count, Set(values).isSubset(of:kinds) else { throw Failure.invalidArguments }
            kinds = Set(values)
        }
        return (start,end,kinds)
    }
    private func scoped(_ records:[DayRecord],start:Date,end:Date,kinds:Set<DayRecord.Kind>) -> [DayRecord] {
        DayRecord.evidenceRecords(records,scope:DateInterval(start:start,end:end)).filter { kinds.contains($0.kind) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private func string(_ args:[String:Any],_ key:String,max:Int) throws -> String {
        guard let value = args[key] as? String, !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, value.count <= max else { throw Failure.invalidArguments }
        return value
    }
    private func integer(_ args:[String:Any],_ key:String,default fallback:Int,range:ClosedRange<Int>) throws -> Int {
        guard let raw = args[key] else { return fallback }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue == Double(number.intValue), range.contains(number.intValue) else { throw Failure.invalidArguments }
        return number.intValue
    }
    private func source(_ record:DayRecord,text:String) -> DaybookRetrieval.Source {
        var provenance = record.contentProvenance; provenance?.transcript = []
        return .init(id:record.id,number:0,title:String(record.title.prefix(48)),capturedAt:record.capturedAt,kind:record.kind,snippet:String(text.prefix(200)),truncated:text.count > 200,provenance:provenance)
    }
    private func renumber(_ source:DaybookRetrieval.Source,number:Int) -> DaybookRetrieval.Source {
        var value = source
        var provenance = source.provenance; provenance?.transcript = []
        value = .init(id:value.id,number:number,title:prepared.evidence.speakerContactID == nil ? String(value.title.prefix(48)) : "已关联说话人的发言",capturedAt:value.capturedAt,kind:value.kind,snippet:String(value.snippet.prefix(200)),truncated:value.truncated || value.snippet.count > 200,provenance:provenance,sourceKey:value.sourceKey,speakerID:value.speakerID,speakerOffset:value.speakerOffset,speakerEndOffset:value.speakerEndOffset)
        return value
    }
    private func register(_ source:DaybookRetrieval.Source,key:String) -> Evidence {
        // Identity includes immutable initial scope/version and the specific text window.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity:"Infinity",negativeInfinity:"-Infinity",nan:"NaN")
        let sourceIdentity = (try? encoder.encode(renumber(source,number:0))) ?? Data()
        let identity = prepared.evidence.fingerprint + "|" + String(prepared.dayStart.timeIntervalSinceReferenceDate) + "|" + String(prepared.dayEnd.timeIntervalSinceReferenceDate) + "|" + key + "|" + sourceIdentity.base64EncodedString()
        if let index = evidenceKeys[identity] { return evidence[index] }
        let entry = Evidence(id:SHA256.hash(data:Data(identity.utf8)).map { String(format:"%02x",$0) }.joined(),source:renumber(source,number:evidence.count + 1))
        evidenceKeys[identity] = evidence.count; evidence.append(entry); return entry
    }
    private func result(_ entries:[Evidence]) -> ToolResult {
        .init(text:entries.map { "[\($0.source.number)] id=\($0.source.id.uuidString) \($0.source.capturedAt.ISO8601Format()) \($0.source.kind.rawValue) · \(prepared.evidence.speakerContactID == nil ? $0.source.title : "已关联说话人的发言")\n\($0.source.snippet)" }.joined(separator:"\n"),status:entries.isEmpty ? "empty" : "ok",evidenceIDs:entries.map(\.id))
    }
    private func empty() -> ToolResult { .init(text:"No allowed current record in this scope.",status:"empty",evidenceIDs:[]) }
    private func stripCitations(_ text:String) -> String { text.replacingOccurrences(of:#"\[\d+\]"#,with:"",options:.regularExpression) }
}
