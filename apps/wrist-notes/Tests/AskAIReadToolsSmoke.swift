import Foundation

@main struct AskAIReadToolsSmoke {
    struct Failed: Error { let message: String }
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failed(message: message) } }
    @MainActor static func main() async throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let records = (0..<8).map { DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(Double($0)), kind: .voice, title: String(repeating:"title",count:20), text: "project evidence \($0) " + String(repeating:"正文",count:200)) }
        let denied = DayRecord(id: UUID(), capturedAt: day, kind: .image, title: "private", text: "DENIED")
        let past = DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(-100), kind: .voice, title: "past", text: "OUTSIDE")
        var retrieval = DaybookRetrieval(); retrieval.calendar = calendar
        let prepared = try retrieval.prepare(question: "project", records: records + [denied,past], selectedDate: day, allowedKinds: [.voice])
        let old = DaybookConversationTurn(id:UUID(),question:"project before [1]",text:"OLD FACT [1]",generated:true,provider:"fixture",evidence:prepared.evidence,sources:prepared.sources,scopeDescription:"",state:.completed)
        let tools = AskAIReadTools(prepared:prepared, records:records + [denied,past], history:[old])
        let result = try await tools.execute(name:"searchRecords",arguments:Data(#"{"query":"project","limit":8}"#.utf8))
        try check(result.status == "ok" && result.evidenceIDs.count == 8, "search only scoped allowed evidence")
        try check(!result.text.contains("DENIED") && !result.text.contains("OUTSIDE"), "search cannot expand date or permissions")
        let same = try await tools.execute(name:"readRecord",arguments:Data("{\"id\":\"\(records[0].id.uuidString)\"}".utf8))
        try check(same.evidenceIDs == [result.evidenceIDs.first!], "same record retains source identity")
        let searchNumbers = result.evidenceIDs.map { id in tools.evidence.first(where: { $0.id == id })!.source.number }
        let answer = try tools.finalize(answer:searchNumbers.prefix(5).map { "[\($0)]" }.joined(separator:" "))
        try check(answer.sources.count == 5 && answer.sources.map(\.number) == [1,2,3,4,5], "final source cap and contiguous labels")
        try check(answer.sources.allSatisfy { $0.title.count <= 48 && $0.snippet.count <= 200 }, "final bounds")
        try check(answer.prepared.evidence == prepared.evidence, "projection preserves complete original scope")
        do { _ = try tools.finalize(answer:searchNumbers.prefix(6).map { "[\($0)]" }.joined(separator:" ")); throw Failed(message:"six cited assertions silently stripped") } catch AskAIReadTools.Failure.invalidCitation { }
        do { _ = try tools.finalize(answer:"Uncited factual assertion"); throw Failed(message:"uncited answer accepted") } catch AskAIReadTools.Failure.invalidCitation { }
        do { _ = try tools.finalize(answer:"invented [999]"); throw Failed(message:"invented citation accepted") } catch AskAIReadTools.Failure.invalidCitation { }
        let history = try await tools.execute(name:"searchConversationHistory",arguments:Data(#"{"query":"project"}"#.utf8))
        try check(history.status == "background" && history.evidenceIDs.isEmpty && !history.text.contains("OLD FACT") && !history.text.contains("[1]"), "history is user intent only without evidence")
        for (name,json) in [("writeRecord","{}"),("searchRecords",#"{"query":"project","start":"2026-10-01"}"#),("searchRecords",#"{"query":"project","kinds":["image"]}"#),("readRecord",#"{"id":"bad"}"#)] {
            let fresh = AskAIReadTools(prepared:prepared, records:records)
            do { _ = try await fresh.execute(name:name,arguments:Data(json.utf8)); throw Failed(message:"invalid tool accepted") }
            catch is AskAIReadTools.Failure { }
        }
        let windows = AskAIReadTools(prepared:prepared,records:records)
        let firstWindow = try await windows.execute(name:"readRecord",arguments:Data("{\"id\":\"\(records[0].id.uuidString)\",\"offset\":0,\"limit\":800}".utf8))
        let laterWindow = try await windows.execute(name:"readRecord",arguments:Data("{\"id\":\"\(records[0].id.uuidString)\",\"offset\":220,\"limit\":200}".utf8))
        try check(firstWindow.text.count > 200 && firstWindow.evidenceIDs != laterWindow.evidenceIDs, "larger scoped reads have distinct window evidence")
        let firstNumber = windows.evidence.first(where: { $0.id == firstWindow.evidenceIDs[0] })!.source.number
        let laterNumber = windows.evidence.first(where: { $0.id == laterWindow.evidenceIDs[0] })!.source.number
        do { _ = try windows.finalize(answer:"[\(firstNumber)] [\(laterNumber)]"); throw Failed(message:"duplicate UUID citation windows accepted") } catch AskAIReadTools.Failure.invalidCitation { }
        let capped = AskAIReadTools(prepared:prepared,records:records)
        for _ in 0..<6 { _ = try await capped.execute(name:"searchRecords",arguments:Data(#"{"query":"project"}"#.utf8)) }
        do { _ = try await capped.execute(name:"searchRecords",arguments:Data(#"{"query":"project"}"#.utf8)); throw Failed(message:"tool limit bypass") } catch AskAIReadTools.Failure.callLimit { }
        var zero = DayRecord(id:UUID(),capturedAt:day,kind:.activity,title:"steps",text:"steps")
        zero.lifeMoment = LifeMomentDetails(steps:StepMoment(interval:DateInterval(start:day,duration:3600),count:0,updatedAt:nil,archived:false))
        let missing = DayRecord(id:UUID(),capturedAt:day.addingTimeInterval(3601),kind:.activity,title:"unknown",text:"steps 9000",metricValue:9000)
        let health = try retrieval.prepare(question:"steps",records:[zero,missing],selectedDate:day,allowedKinds:[.activity])
        let metrics = AskAIReadTools(prepared:health,records:[zero,missing])
        let metric = try await metrics.execute(name:"aggregateMetrics",arguments:Data(#"{"metric":"steps"}"#.utf8))
        try check(metric.status == "partial" && metric.text.contains("value=0") && metric.text.contains("missing=1"), "typed zero differs from unavailable; prose/metricValue cannot create health facts")
        let missingOnly = AskAIReadTools(prepared:try retrieval.prepare(question:"steps",records:[missing],selectedDate:day,allowedKinds:[.activity]),records:[missing])
        let unavailable = try await missingOnly.execute(name:"aggregateMetrics",arguments:Data(#"{"metric":"steps"}"#.utf8))
        try check(unavailable.status == "unavailable" && unavailable.text.contains("value=missing"), "no observations are not zero")
        var sleep = DayRecord(id:UUID(),capturedAt:day.addingTimeInterval(7*3600),kind:.sleep,title:"last night",text:"sleep")
        sleep.lifeMoment = LifeMomentDetails(sleep:SleepMoment(startedAt:day.addingTimeInterval(-3600),endedAt:sleep.capturedAt,asleepSeconds:28000,awakeSeconds:800,stages:[:],sourceName:nil,isMain:true))
        let sleepTools = AskAIReadTools(prepared:try retrieval.prepare(question:"sleep",records:[sleep],selectedDate:day,allowedKinds:[.sleep]),records:[sleep])
        let sleepResult = try await sleepTools.execute(name:"aggregateMetrics",arguments:Data(#"{"metric":"sleepSeconds"}"#.utf8))
        try check(sleepResult.status == "ok" && sleepResult.text.contains("value=28000"), "whole last-night sleep is attributed to wake day")
        let subsetTools = AskAIReadTools(prepared:prepared,records:records)
        let subset = try await subsetTools.execute(name:"aggregateMetrics",arguments:Data(#"{"metric":"recordCount"}"#.utf8))
        try check(subset.status == "partial" && subset.evidenceIDs.count == 5 && subset.text.contains("value=5") && subset.text.contains("excludedByLimit=3") && subset.text.contains("not a complete total"), "bounded total never claims uncited rows")
        let speakerItem = SpeakerAskEvidence(id:records[0].id,sourceKey:"fixture",speakerID:"speaker",speakerLabel:"Speaker",title:"speaker",capturedAt:day,kind:.voice,start:0,end:2,text:"ASSOCIATED")
        let speaker = try retrieval.prepareSpeaker(question:"说了什么",items:[speakerItem],records:records,contactID:"contact",fingerprint:"revision1",selectedDate:day)
        let speakerTools = AskAIReadTools(prepared:speaker,records:records)
        let speech = try await speakerTools.execute(name:"readRecord",arguments:Data("{\"id\":\"\(records[0].id.uuidString)\"}".utf8))
        try check(speech.text.contains("ASSOCIATED") && !speech.text.contains("project evidence"), "speaker tool never exposes other speech from whole record")
        var freshRecords = records
        let freshTools = AskAIReadTools(prepared:prepared,records:records,recordsReader:{ freshRecords })
        freshRecords[0].text = "edited"
        do { _ = try await freshTools.execute(name:"readRecord",arguments:Data("{\"id\":\"\(records[0].id.uuidString)\"}".utf8)); throw Failed(message:"stale edit read") } catch AskAIReadTools.Failure.staleEvidence { }
        let revokedSpeaker = AskAIReadTools(prepared:speaker,records:records,scopeIsCurrent:{false})
        do { _ = try await revokedSpeaker.execute(name:"readRecord",arguments:Data("{\"id\":\"\(records[0].id.uuidString)\"}".utf8)); throw Failed(message:"revoked speaker read") } catch AskAIReadTools.Failure.staleEvidence { }
        print("Ask AI read tools: scope, identity, citations, typed metrics, history and limits passed")
    }
}
