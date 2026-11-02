import Foundation

@main
struct SpeakerAskRetrievalSmoke {
    static func main() throws {
        let db = try DaybookDatabase(inMemory: true)
        let repository = try DaybookSpeakerAskRepository(database: db)
        try db.execute("INSERT INTO contacts(id,origin_type,display_name,emails_json,sync_state,created_at,updated_at) VALUES ('kate','manual','Kate Bell','[\"private@example.invalid\"]','manual',0,0)")

        // The original simulator question must reach the speaker route even before
        // an association exists. A vector index cannot resolve this relationship.
        for question in ["What’s Kate Bell’s opinion in today’s recording?",
                         "What did Kate Bell say today?", "KATE BELL'S views?", "Kate Bell今天的观点是什么？"] {
            guard case .unlinked("Kate Bell") = try repository.resolve(question: question, priorTurns: []) else {
                preconditionFailure("Named speaker intent was missed: \(question)")
            }
        }
        guard case .unrelated = try repository.resolve(question: "What did Kate Bella say?", priorTurns: []) else {
            preconditionFailure("A contact name must not match part of another name")
        }
        guard case .unrelated = try repository.resolve(question: "What is Kate Bell's email?", priorTurns: []) else {
            preconditionFailure("A contact detail request is not a request for recorded speech")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        let now = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00+08:00")!
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let retrieval = DaybookRetrieval(calendar: calendar)
        for phrase in ["today", "TODAY", "today's", "today’s"] {
            let scope = try retrieval.automaticScope("Kate Bell's opinion in \(phrase) recording?", now: now)
            precondition(scope.start == today && scope.end == tomorrow && !scope.canExpand,
                         "An explicit English date must be a hard calendar boundary")
            precondition(DaybookRetrieval.hasExplicitDate(phrase))
            precondition(!scope.topic.lowercased().contains("today"))
        }
        let previous = try retrieval.automaticScope("What did Kate Bell say YESTERDAY?", now: now)
        precondition(previous.start == yesterday && previous.end == today)
        let before = try retrieval.automaticScope("the day before yesterday's recording", now: now)
        precondition(before.start == calendar.date(byAdding: .day, value: -2, to: today)!)
        precondition(before.end == yesterday)
        precondition(!DaybookRetrieval.hasExplicitDate("todayish"))

        let currentID = try addRecording(db, date: today.addingTimeInterval(36000), text: "We should ship Friday.")
        _ = try addRecording(db, date: yesterday.addingTimeInterval(36000), text: "Yesterday-only speech.")
        _ = try addRecording(db, date: tomorrow, text: "Tomorrow-only speech.")
        guard case .contact(id: "kate", name: "Kate Bell") = try repository.resolve(
            question: "What’s Kate Bell’s opinion in today’s recording?", priorTurns: []) else {
            preconditionFailure("The persisted contact binding must select Kate")
        }
        let snapshot = try repository.snapshot(contactID: "kate")
        precondition(snapshot.items.count == 3, "Only the linked speaker's active transcript is eligible")
        let prepared = try retrieval.prepareSpeaker(question: "What’s Kate Bell’s opinion in today’s recording?",
            items: snapshot.items, records: [], contactID: "kate", contactName: "Kate Bell", fingerprint: snapshot.fingerprint,
            selectedDate: yesterday, now: now)
        precondition(prepared.sources.map(\.id) == [currentID], "Today must ignore yesterday's selected homepage date")
        precondition(prepared.dayStart == today && prepared.dayEnd == tomorrow)
        precondition(prepared.context.contains("We should ship Friday."))
        let dated = try retrieval.prepareSpeaker(question: "Kate Bell 2026-10-31 说了什么？",
            items: snapshot.items, records: [], contactID: "kate", contactName: "Kate Bell", fingerprint: snapshot.fingerprint,
            selectedDate: yesterday)
        precondition(dated.sources.map(\.id) == [currentID])
        precondition(dated.context.contains("Kate Bell") && dated.context.contains("We should ship Friday."))
        precondition(!dated.context.contains("other-speaker-private") && !dated.context.contains("private@example.invalid"))
        precondition(!dated.context.contains("Yesterday-only") && !dated.context.contains("Tomorrow-only"))
        precondition(dated.evidence.speakerContactID == "kate")
        let empty = try retrieval.prepareSpeaker(question: "What did Kate Bell say today?",
            items: [], records: [], contactID: "kate", contactName: "Kate Bell", fingerprint: "empty",
            selectedDate: yesterday, now: now)
        precondition(empty.sources.isEmpty && empty.directResponse != nil && empty.dayStart == today && empty.dayEnd == tomorrow,
                     "Missing speech must not broaden or mislabel the requested date")

        // Apple ASR often stores individual words. Repeating timestamp/name for
        // every word must not consume the context budget before the actual point.
        let words = (0..<80).map { _ in "测试" } + ["最终建议是周五发布。"]
        let wordEvidence = words.enumerated().map { index, word in
            SpeakerAskEvidence(id: currentID, sourceKey: "session:words", speakerID: "speaker-1", speakerLabel: "说话人 1",
                title: "Another speaker's conclusion", capturedAt: now, kind: .voice, start: Double(index), end: Double(index+1), text: word)
        }
        let compact = try retrieval.prepareSpeaker(question: "What’s Kate Bell’s opinion in today’s recording?",
            items: wordEvidence, records: [], contactID: "kate", contactName: "Kate Bell", fingerprint: "words",
            selectedDate: yesterday, now: now)
        precondition(compact.context.contains("最终建议是周五发布。"), "Word-level timestamps must not hide a short recording's final opinion")
        precondition(compact.context.count <= retrieval.limits.maxContextCharacters)
        precondition(!compact.context.contains("Another speaker's conclusion"),
                     "A recording-wide generated title is not evidence of the linked speaker's opinion")
        let numberWords = ["2", "0", "2", "6"].enumerated().map { index, word in
            SpeakerAskEvidence(id: currentID, sourceKey: "session:numbers", speakerID: "speaker-1", speakerLabel: "说话人 1",
                title: "Numbers", capturedAt: now, kind: .voice, start: Double(index), end: Double(index+1), text: word)
        }
        let numberContext = try retrieval.prepareSpeaker(question: "Kate Bell说了什么？", items: numberWords, records: [],
            contactID: "kate", contactName: "Kate Bell", fingerprint: "numbers", selectedDate: now)
        precondition(numberContext.context.contains("2026"), "Adjacent digit spans keep the original number")

        try db.execute("INSERT INTO contacts(id,origin_type,display_name,sync_state,created_at,updated_at) VALUES ('duplicate','manual','Kate Bell','manual',0,0)")
        guard case .ambiguous = try repository.resolve(question: "What did Kate Bell say today?", priorTurns: []) else {
            preconditionFailure("Duplicate names require disambiguation")
        }
        try db.execute("UPDATE recording_speaker_contacts SET speaker_revision='stale'")
        let stale = try repository.snapshot(contactID: "kate")
        precondition(stale.items.isEmpty,
                     "Reprocessed speakers cannot reuse an obsolete association")
        print("SpeakerAskRetrievalSmoke passed: English/Chinese intent, exact names, dates, SQLite association, speaker isolation, privacy and stale revisions")
    }

    private static func addRecording(_ db: DaybookDatabase, date: Date, text: String) throws -> UUID {
        let id = UUID(), sourceID = AudioSourceID(kind: .session, id: id)
        let range = try AudioSourceRange(range: .init(chunkID: UUID(), url: URL(fileURLWithPath: "/fixture.wav"),
            startFrame: 0, endFrame: 600, sampleRate: 10), contentHash: String(repeating: "a", count: 64))
        let source = try AudioSourceSnapshot(id: sourceID, capturedAt: date, title: "Planning recording", ranges: [range], complete: true)
        try db.execute("INSERT INTO recording_sessions(id,started_at,created_at) VALUES (?,?,?)",
                       [.text(id.uuidString), .real(date.timeIntervalSinceReferenceDate), .real(date.timeIntervalSinceReferenceDate)])
        try db.execute("INSERT INTO audio_processing_sources(source_key,kind,source_id,session_id,descriptor,fingerprint,configuration_key) VALUES (?,'session',?,?,?,?, 'test')",
                       [.text(sourceID.key), .text(id.uuidString), .text(id.uuidString), try DaybookDatabase.json(source), .text(source.fingerprint)])
        let window = try AudioWindowPlanner.plan(source: source, configurationKey: "test")[0]
        let result = AudioWindowResult(spans: [.init(start: 1, end: 10, text: text, speakerID: "speaker-1")],
                                      activities: [], asr: .success, vad: .success, speaker: .success, asrCoverage: [], vadCoverage: [])
        let hash = AudioStableID.make(result)
        try db.execute("INSERT INTO audio_processing_jobs(id,source_key,configuration_key,core_start,core_end,window,state,result,result_hash) VALUES (?,?,'test',0,60,?,'completed',?,?)",
                       [.text(window.id), .text(sourceID.key), try DaybookDatabase.json(window), try DaybookDatabase.json(result), .text(hash)])
        try db.execute("INSERT INTO audio_transcript_spans(job_id,position,start,end,text,speaker_id) VALUES (?,0,1,10,?,'speaker-1')", [.text(window.id), .text(text)])
        try db.execute("INSERT INTO audio_transcript_spans(job_id,position,start,end,text,speaker_id) VALUES (?,1,11,20,'other-speaker-private','speaker-2')", [.text(window.id)])
        let revision = AudioStableID.make([window.id, hash, "0.0", "1.0", "10.0", text])
        try db.execute("INSERT INTO recording_speaker_contacts(source_key,speaker_id,contact_id,linked_at,speaker_revision) VALUES (?,'speaker-1','kate',0,?)",
                       [.text(sourceID.key), .text(revision)])
        return id
    }
}
