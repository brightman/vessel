import Foundation

@main struct ContentSegmentationV2Smoke {
    typealias V = ContentSegmentationV2
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw NSError(domain: "ContentV2", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        checks += 1
    }
    static func fixture(duration: Double = 600, spans: [V.Span]? = nil, activities: [V.Activity]? = nil, vad: [V.Interval]? = nil, boundaries: [V.Boundary] = []) -> V.Input {
        V.Input(sourceID: "fixture-source", sourceRevision: "asr-1-vad-1", duration: duration,
                spans: spans ?? [.init(id: "row-a", start: 10, end: 20, text: "首句。"), .init(id: "row-b", start: 400, end: 420, text: "末句。")],
                asrCoverage: [.init(start: 0, end: duration)], vadCoverage: vad ?? [.init(start: 0, end: duration)],
                activities: activities ?? [.init(start: 0, end: duration, kind: .noSpeech)], boundaries: boundaries)
    }
    static func preparationTests() throws {
        let accepted = try V.prepare(fixture())
        try check(accepted.gaps.contains { $0.start == 20 && $0.end == 400 && $0.status == .verified }, "fully covered 380s blank is verified")
        try check(accepted.chapters.count == 2, "verified gap separates chapters")
        let speech = try V.prepare(fixture(activities: [.init(start: 0, end: 600, kind: .noSpeech), .init(start: 20, end: 200, kind: .speech)]))
        try check(speech.gaps.contains { $0.start == 20 && $0.status == .speechPresent && $0.speechRatio > 0.47 }, "overlapping speech outranks noSpeech and blocks silence inference")
        try check(speech.chapters.count == 1, "speech-filled ASR blank stays in one content region")
        let missing = try V.prepare(fixture(vad: [.init(start: 0, end: 100)]))
        try check(missing.gaps.contains { $0.start == 20 && $0.status == .pendingCoverage }, "missing VAD coverage remains pending")
        try check(missing.chapters.count == 2 && missing.chapters.allSatisfy(\.provisional), "pending blank cannot be crossed and adjacent chapters are provisional")
        let rows: [V.Span] = [.init(id: "x", start: 0, end: 50, text: "开始"), .init(id: "y", start: 50, end: 80, text: "中间。"), .init(id: "z", start: 79, end: 125, text: "重叠尾部"), .init(id: "empty", start: 126, end: 127, text: "")]
        let full = try V.prepare(fixture(duration: 150, spans: rows))
        try check(full.blocks.map(\.text).joined() == "开始中间。重叠尾部", "full transcript survives overlap without truncation")
        try check(full.blocks.flatMap(\.spanIDs) == ["x", "y", "z", "empty"], "each original row has one owner")
        try check(full.blocks.count == 1, "overlap is not a legal cut")
        var manual = fixture(duration: 150, spans: rows, boundaries: [.init(start: 79.5, end: 79.5, kind: .manual)])
        do { _ = try V.prepare(manual); throw NSError(domain: "expectedBoundaryFailure", code: 1) }
        catch V.Failure.boundaryRepairRequired { checks += 1 }
        manual.boundaries = [.init(start: 130, end: 130, kind: .manual)]
        _ = try V.prepare(manual)
        let exactBoundary = try V.prepare(fixture(duration: 100, spans: [.init(id: "left", start: 0, end: 30, text: "左侧"), .init(id: "point", start: 50, end: 50, text: "点"), .init(id: "right", start: 51, end: 90, text: "右侧")], boundaries: [.init(start: 50, end: 50, kind: .manual)]))
        try check(exactBoundary.blocks.flatMap(\.spanIDs) == ["left", "point", "right"], "zero-duration row at manual cut belongs to right side exactly once")
        let allEmpty = try V.prepare(fixture(duration: 600, spans: [.init(id: "empty-only", start: 100, end: 110, text: "")]))
        try check(allEmpty.blocks.isEmpty && allEmpty.retainedGapSpanIDs == ["empty-only"], "no transcript creates no blank content card while preserving empty rows")
    }
    final class MemoryCheckpoints {
        var values: [String: Data] = [:]
    }
    final class Replies {
        var calls: [(String, String)] = []
        var answers: [String]
        init(_ answers: [String]) { self.answers = answers }
        func call(_ instruction: String, _ content: String) throws -> String {
            calls.append((instruction, content))
            guard !answers.isEmpty else { throw NSError(domain: "unexpectedModelRequest", code: 1) }
            return answers.removeFirst()
        }
    }
    static func engine(_ replies: Replies, _ cache: MemoryCheckpoints = MemoryCheckpoints(), cap: Int = 24000, modelID: String = "fixture-model") -> V.Engine {
        V.Engine(configuration: .init(modelIdentity: modelID, requestCharacterLimit: cap, maximumConcurrentFinalRequests: 1), model: { try replies.call($0, $1) }, loadCheckpoint: { cache.values[$0] }, saveCheckpoint: { cache.values[$0] = $1 })
    }
    static func draft(_ first: String, _ last: String) -> V.Draft {
        .init(firstBlockID: first, lastBlockID: last, topic: "具体议题", rationale: "完整原文支持", contentKind: .discussion, confidence: .medium, evidenceBlockIDs: [first])
    }
    static func final(_ id: String, classification: V.Classification = .meaningful) -> V.FinalReply {
        .init(title: "有依据的内容", summary: "依据全部原文生成的摘要。", shortSummary: "简要概括。", keyPoints: [], classification: classification, contentKind: classification == .lowInformation ? .fragment : .discussion, confidence: .medium, uncertainty: "", evidenceBlockIDs: [id])
    }
    static func modelTests() async throws {
        let input = fixture(duration: 300, spans: [.init(id: "first-row", start: 0, end: 80, text: "FIRST 全文。"), .init(id: "last-row", start: 82, end: 150, text: "LAST 全文。")])
        let plan = try V.prepare(input); let ids = plan.blocks.map(\.id)
        try check(ids.count == 2, "fixture offers chapter-internal legal split")
        let chapter = V.ChapterReply(chapterID: plan.chapters[0].id, segments: [draft(ids[0], ids[0]), draft(ids[1], ids[1])])
        let replies = Replies([try V.canonical(chapter), try V.canonical(V.MergeReply(merge: false, reason: "明显议题转折")), try V.canonical(final(ids[0])), try V.canonical(final(ids[1], classification: .lowInformation))])
        let cache = MemoryCheckpoints(); let output = try await engine(replies, cache).run(input)
        try check(output.segments.count == 2, "chapter split remains two final segments")
        try check(output.segments.flatMap(\.spanIDs) == ["first-row", "last-row"], "final ranges completely own original rows")
        try check(output.segments[1].classification == .lowInformation, "low-information classification is retained")
        try check(replies.calls[0].1.contains("FIRST 全文。") && replies.calls[0].1.contains("LAST 全文。"), "chapter gets complete text")
        try check(replies.calls[2].1.contains("FIRST 全文。") && replies.calls[3].1.contains("LAST 全文。"), "final summaries see final segment full text")
        var forged = output.segments
        var forgedPlan = output.plan
        forgedPlan.blocks[0].text = "tampered transcript"
        do { try V.validateOutput(plan: forgedPlan, segments: forged, original: input.spans); throw NSError(domain: "expectedTextFailure", code: 1) }
        catch V.Failure.stage { checks += 1 }
        forged[0].evidenceBlockIDs = [ids[1]]
        do { try V.validateOutput(plan: output.plan, segments: forged, original: input.spans); throw NSError(domain: "expectedEvidenceFailure", code: 1) }
        catch V.Failure.stage { checks += 1 }
        let replay = Replies([]); let restored = try await engine(replay, cache).run(input)
        try check(restored.segments == output.segments && restored.metrics.checkpointHits == 4 && restored.metrics.modelRequests == 0, "validated durable checkpoints avoid repeated model calls")
        var changed = input; changed.spans[1].text = "修改后的 LAST 全文。"
        let changedReplies = Replies([try V.canonical(chapter), try V.canonical(V.MergeReply(merge: false, reason: "不同议题")), try V.canonical(final(ids[1], classification: .lowInformation))])
        let changedOutput = try await engine(changedReplies, cache).run(changed)
        try check(changedOutput.metrics.checkpointHits == 1 && changedOutput.metrics.modelRequests == 3, "changed block invalidates chapter/merge/affected final while unchanged final reuses checkpoint")
        let differentModelReplies = Replies([try V.canonical(chapter), try V.canonical(V.MergeReply(merge: false, reason: "不同议题")), try V.canonical(final(ids[0])), try V.canonical(final(ids[1]))])
        let differentModel = try await engine(differentModelReplies, cache, modelID: "new-model-generation").run(input)
        try check(differentModel.metrics.checkpointHits == 0 && differentModel.metrics.modelRequests == 4, "model identity prevents stale response reuse")
        let failedTransport = Replies([])
        do { _ = try await engine(failedTransport).run(input); throw NSError(domain: "expectedTransportFailure", code: 1) }
        catch V.Failure.stage(let stage, let reason) { try check(stage.hasPrefix("chapter") && reason.contains("transportFailed") && failedTransport.calls.count == 1, "transport failure is stage-specific without automatic repair or retry") }
        let tooManySplits = V.ChapterReply(chapterID: plan.chapters[0].id, segments: Array(repeating: draft(ids[0], ids[0]), count: 6))
        let tooMany = Replies([try V.canonical(tooManySplits), try V.canonical(tooManySplits)])
        do { _ = try await engine(tooMany).run(input); throw NSError(domain: "expectedSplitFailure", code: 1) }
        catch V.Failure.stage { try check(tooMany.calls.count == 2, "six chapter splits are rejected through one repair limit") }
        let one = fixture(duration: 100, spans: [.init(id: "only-row", start: 5, end: 20, text: "一个完整想法。")])
        let onePlan = try V.prepare(one), oneID = onePlan.blocks[0].id
        let oneChapter = try V.canonical(V.ChapterReply(chapterID: onePlan.chapters[0].id, segments: [draft(oneID, oneID)]))
        let partialCache = MemoryCheckpoints()
        var badEvidence = final("unowned-evidence")
        badEvidence.classification = .pendingConfirmation
        let badFinal = Replies([oneChapter, try V.canonical(badEvidence), try V.canonical(badEvidence)])
        do { _ = try await engine(badFinal, partialCache).run(one); throw NSError(domain: "expectedFinalFailure", code: 1) }
        catch V.Failure.stage(let stage, _) { try check(stage.hasPrefix("final") && partialCache.values.count == 1, "invalid final response preserves validated chapter checkpoint but no invalid final checkpoint") }
        let resumed = try await engine(Replies([try V.canonical(final(oneID))]), partialCache).run(one)
        try check(resumed.metrics.checkpointHits == 1 && resumed.segments.count == 1, "resume after final failure reuses completed chapter")
        let saveFailureReplies = Replies([oneChapter])
        var saveFailureEngine = engine(saveFailureReplies)
        saveFailureEngine.saveCheckpoint = { _, _ in throw NSError(domain: "disk-full-fixture", code: 1) }
        do { _ = try await saveFailureEngine.run(one); throw NSError(domain: "expectedCheckpointFailure", code: 1) }
        catch V.Failure.stage(let stage, let reason) { try check(stage.hasPrefix("chapter") && reason == "checkpointSaveFailed" && saveFailureReplies.calls.count == 1, "durable save failure stops processing before dependent stages") }
        let malformed = Replies(["{}", try V.canonical(chapter), try V.canonical(V.MergeReply(merge: true, reason: "同一件事")), try V.canonical(final(ids[0]))])
        let repaired = try await engine(malformed).run(input)
        try check(repaired.segments.count == 1 && repaired.segments[0].blockIDs == ids && repaired.metrics.repairRequests == 1, "one repair recovers then adjacent merge owns complete input")
        try check(malformed.calls.last!.1.contains("FIRST 全文。") && malformed.calls.last!.1.contains("LAST 全文。"), "merged final request contains both complete blocks")
        let omitted = V.ChapterReply(chapterID: plan.chapters[0].id, segments: [draft(ids[0], ids[0])])
        let invalid = Replies([try V.canonical(omitted), try V.canonical(V.ChapterReply(chapterID: plan.chapters[0].id, segments: [draft("invented-id", ids[1])]))])
        do { _ = try await engine(invalid).run(input); throw NSError(domain: "expectedInvalidPlan", code: 1) }
        catch V.Failure.stage(let stage, _) { try check(stage.hasPrefix("chapter") && invalid.calls.count == 2, "omitted/invented blocks get exactly one repair then explicit chapter failure") }
        let oversize = Replies([])
        do { _ = try await engine(oversize, cap: 50).run(input); throw NSError(domain: "expectedOversize", code: 1) }
        catch V.Failure.oversized { try check(oversize.calls.isEmpty, "oversized full text is rejected before transport") }
        let across = fixture(); let gapPlan = try V.prepare(across)
        var gapReplies: [String] = []
        for c in gapPlan.chapters { gapReplies.append(try V.canonical(V.ChapterReply(chapterID: c.id, segments: [draft(c.blockIDs[0], c.blockIDs.last!)]))) }
        for c in gapPlan.chapters { gapReplies.append(try V.canonical(final(c.blockIDs[0]))) }
        let noCross = Replies(gapReplies); let noCrossOutput = try await engine(noCross).run(across)
        try check(noCrossOutput.segments.count == 2 && noCrossOutput.metrics.modelRequests == 4, "cross-gap merging is refused without asking model")
        let longRows = (0..<30).map { i in V.Span(id: "long-row-\(i)", start: Double(i) * 120, end: Double(i) * 120 + 119, text: "完整长段\(i)。") }
        let long = fixture(duration: 3600, spans: longRows)
        let longPlan = try V.prepare(long); var longReplies: [String] = []
        for c in longPlan.chapters { longReplies.append(try V.canonical(V.ChapterReply(chapterID: c.id, segments: [draft(c.blockIDs[0], c.blockIDs.last!)]))) }
        for c in longPlan.chapters { longReplies.append(try V.canonical(final(c.blockIDs[0]))) }
        let overlong = Replies(longReplies); let longOutput = try await engine(overlong).run(long)
        try check(longOutput.segments.count == 2 && longOutput.segments.allSatisfy { $0.end - $0.start <= 2400 }, "overlong merge refused and all final durations capped")
    }
    static func evidenceAndCancellationTests() async throws {
        let rows = (0..<6).map { i in V.Span(id: "evidence-row-\(i)", start: Double(i) * 100, end: Double(i) * 100 + 80, text: "可追溯内容\(i)。") }
        let input = fixture(duration: 600, spans: rows)
        let plan = try V.prepare(input), ids = plan.blocks.map(\.id)
        try check(ids.count == 6, "fixture has six independently owned evidence blocks")
        var allEvidenceDraft = draft(ids[0], ids.last!); allEvidenceDraft.evidenceBlockIDs = ids
        let chapter = try V.canonical(V.ChapterReply(chapterID: plan.chapters[0].id, segments: [allEvidenceDraft]))
        var allEvidenceFinal = final(ids[0]); allEvidenceFinal.evidenceBlockIDs = ids
        let valid = try await engine(Replies([chapter, try V.canonical(allEvidenceFinal)])).run(input)
        try check(valid.segments[0].evidenceBlockIDs == ids, "more than four unique owned evidence IDs are accepted and preserved")
        for badIDs in [[ids[0], ids[0]], [ids[0], "unknown-evidence"]] {
            var bad = allEvidenceDraft; bad.evidenceBlockIDs = badIDs
            let badReply = try V.canonical(V.ChapterReply(chapterID: plan.chapters[0].id, segments: [bad]))
            do { _ = try await engine(Replies([badReply, badReply])).run(input); throw NSError(domain: "expectedEvidenceFailure", code: 1) }
            catch V.Failure.stage { checks += 1 }
        }
        let cache = MemoryCheckpoints()
        let replies = Replies([chapter, try V.canonical(allEvidenceFinal)])
        let canceled = Task {
            var subject = engine(replies, cache)
            subject.model = { instruction, content in
                let result = try replies.call(instruction, content)
                withUnsafeCurrentTask { $0?.cancel() }
                return result
            }
            return try await subject.run(input)
        }
        do { _ = try await canceled.value; throw NSError(domain: "expectedCancellation", code: 1) }
        catch is CancellationError { try check(cache.values.isEmpty && replies.calls.count == 1, "cancellation after model suspension prevents checkpoint save and dependent work") }
        let cached = MemoryCheckpoints()
        _ = try await engine(Replies([chapter, try V.canonical(allEvidenceFinal)]), cached).run(input)
        let unusedModel = Replies([])
        let canceledCache = Task {
            var subject = engine(unusedModel, cached)
            subject.loadCheckpoint = { key in
                withUnsafeCurrentTask { $0?.cancel() }
                return cached.values[key]
            }
            return try await subject.run(input)
        }
        do { _ = try await canceledCache.value; throw NSError(domain: "expectedCachedCancellation", code: 1) }
        catch is CancellationError { try check(unusedModel.calls.isEmpty, "cancellation after checkpoint load prevents cached output from reaching publisher") }
    }
    static func reviewRegressionTests() async throws {
        let leading = fixture(duration: 150, spans: [.init(id: "leading-empty", start: 0, end: 80, text: ""), .init(id: "following-text", start: 100, end: 110, text: "有内容。")])
        let leadingPlan = try V.prepare(leading)
        try check(leadingPlan.blocks.count == 1 && leadingPlan.blocks[0].spanIDs == ["leading-empty", "following-text"] && leadingPlan.blocks[0].text == "有内容。", "leading empty row is retained with content rather than forming an empty block")
        var whitespaceLeading = leading; whitespaceLeading.spans[0].text = " \n\t"
        let whitespacePlan = try V.prepare(whitespaceLeading)
        try check(whitespacePlan.blocks.count == 1 && whitespacePlan.blocks[0].spanIDs == ["leading-empty", "following-text"] && whitespacePlan.blocks[0].text == " \n\t有内容。", "leading whitespace stays with text and its exact original characters survive")
        let startpoint = fixture(duration: 600, spans: [.init(id: "source-start-text", start: 0, end: 0, text: "开头的明确内容。")])
        let startpointPlan = try V.prepare(startpoint)
        try check(startpointPlan.blocks.count == 1 && startpointPlan.blocks[0].start == 0 && startpointPlan.blocks[0].end == 0 && startpointPlan.blocks[0].spanIDs == ["source-start-text"], "nonempty source-start point remains owned before trailing blank")
        let empty = fixture(duration: 600, spans: [.init(id: "retained-row", start: 100, end: 110, text: "")])
        let emptyPlan = try V.prepare(empty)
        var changedOriginal = empty.spans; changedOriginal[0].text = "新增的非空文字不能被隐藏"
        do { try V.validateOutput(plan: emptyPlan, segments: [], original: changedOriginal); throw NSError(domain: "expectedRetainedTextFailure", code: 1) }
        catch V.Failure.stage { checks += 1 }
        let endpoint = fixture(duration: 600, spans: [.init(id: "source-end-text", start: 600, end: 600, text: "末尾的明确内容。")])
        let endpointPlan = try V.prepare(endpoint)
        try check(endpointPlan.blocks.count == 1 && endpointPlan.blocks[0].spanIDs == ["source-end-text"] && endpointPlan.blocks[0].text == "末尾的明确内容。", "nonempty zero-duration row at source end remains owned after leading blank")
        let chapter = endpointPlan.chapters[0], blockID = endpointPlan.blocks[0].id
        let output = try await engine(Replies([try V.canonical(V.ChapterReply(chapterID: chapter.id, segments: [draft(blockID, blockID)])), try V.canonical(final(blockID))])).run(endpoint)
        try check(output.segments.count == 1 && output.segments[0].spanIDs == ["source-end-text"] && output.segments[0].start == 600 && output.segments[0].end == 600, "source-end point text survives model stages and final ownership validation")
    }
    actor ConcurrentCheckpoints {
        var values: [String: Data] = [:]
        func load(_ key: String) -> Data? { values[key] }
        func save(_ key: String, _ value: Data) { values[key] = value }
    }
    actor ConcurrentModel {
        var active = 0
        var maximumActive = 0
        var finalStarts = 0
        var completions: [Int] = []
        var cancelFinals = false
        var allFinalsStarted: CheckedContinuation<Void, Never>?
        var finalIDs: [String] = []
        func waitForFinals() async {
            if finalStarts >= 3 { return }
            await withCheckedContinuation { allFinalsStarted = $0 }
        }
        func enableCancellationWait() { cancelFinals = true }
        func snapshot() -> (Int, [Int], Int) { (maximumActive, completions, active) }
        func call(_ instruction: String, _ content: String) async throws -> String {
            let object = try JSONSerialization.jsonObject(with: Data(content.utf8)) as! [String: Any]
            if let chapterID = object["chapterID"] as? String {
                let ids = (object["blocks"] as! [[String: Any]]).map { $0["id"] as! String }; finalIDs = ids
                return try V.canonical(V.ChapterReply(chapterID: chapterID, segments: ids.map { draft($0, $0) }))
            }
            if object["left"] != nil { return try V.canonical(V.MergeReply(merge: false, reason: "独立主题")) }
            let blockID = (object["blocks"] as! [[String: Any]])[0]["id"] as! String
            let index = finalIDs.firstIndex(of: blockID)!
            active += 1; maximumActive = max(maximumActive, active); finalStarts += 1
            if finalStarts >= 3 { allFinalsStarted?.resume(); allFinalsStarted = nil }
            defer { active -= 1 }
            if cancelFinals { try await Task.sleep(nanoseconds: 10_000_000_000) }
            else { try await Task.sleep(nanoseconds: [120_000_000, 10_000_000, 60_000_000, 30_000_000, 5_000_000][index]) }
            completions.append(index)
            return try V.canonical(final(blockID))
        }
    }
    static func concurrentFinalTests() async throws {
        let rows = (0..<5).map { i in V.Span(id: "parallel-row-\(i)", start: Double(i) * 100, end: Double(i) * 100 + 80, text: "独立主题\(i)。") }
        let input = fixture(duration: 500, spans: rows)
        let transport = ConcurrentModel(), cache = ConcurrentCheckpoints()
        let subject = V.Engine(configuration: .init(modelIdentity: "parallel-fixture"), model: { try await transport.call($0, $1) }, loadCheckpoint: { await cache.load($0) }, saveCheckpoint: { await cache.save($0, $1) })
        let output = try await subject.run(input)
        let (maximumActive, completions, remaining) = await transport.snapshot()
        try check(maximumActive == 3 && remaining == 0, "final summaries use at most three concurrent requests and complete every unit")
        try check(completions != [0, 1, 2, 3, 4] && output.segments.flatMap(\.spanIDs) == ["parallel-row-0", "parallel-row-1", "parallel-row-2", "parallel-row-3", "parallel-row-4"], "out-of-order final completions preserve original segment ownership order")
        try check(output.metrics.modelRequests == 10 && output.metrics.repairRequests == 0, "parallel per-unit metrics aggregate without lost updates")
        let canceledTransport = ConcurrentModel(), canceledCache = ConcurrentCheckpoints()
        await canceledTransport.enableCancellationWait()
        let canceledSubject = V.Engine(configuration: .init(modelIdentity: "parallel-cancellation"), model: { try await canceledTransport.call($0, $1) }, loadCheckpoint: { await canceledCache.load($0) }, saveCheckpoint: { await canceledCache.save($0, $1) })
        let canceled = Task { try await canceledSubject.run(input) }
        await canceledTransport.waitForFinals()
        canceled.cancel()
        do { _ = try await canceled.value; throw NSError(domain: "expectedGroupCancellation", code: 1) }
        catch is CancellationError {
            let (peak, completed, active) = await canceledTransport.snapshot()
            try check(peak == 3 && active == 0 && completed.isEmpty, "group cancellation stops all in-flight finals and returns no publishable output")
        }
    }
    static func repairDiagnosticTests() async throws {
        let input = fixture(duration: 100, spans: [.init(id: "repair-row", start: 1, end: 90, text: "不应出现在诊断中的完整原文。")])
        let plan = try V.prepare(input), blockID = plan.blocks[0].id
        let chapter = try V.canonical(V.ChapterReply(chapterID: plan.chapters[0].id, segments: [draft(blockID, blockID)]))
        var wrongEvidence = final(blockID); wrongEvidence.evidenceBlockIDs = ["block-not-allowed-9e90f99c"]
        let evidenceReplies = Replies([chapter, try V.canonical(wrongEvidence), try V.canonical(final(blockID))])
        let evidenceOutput = try await engine(evidenceReplies).run(input)
        let evidenceRepair = evidenceReplies.calls[2].0
        try check(evidenceRepair.contains("invalid IDs: [block-not-allowed-9e90f99c]") && evidenceRepair.contains("allowed IDs: [\(blockID)]"), "evidence repair instruction explicitly identifies invalid and exact allowed block IDs")
        try check(evidenceOutput.segments[0].evidenceBlockIDs == [blockID] && evidenceOutput.metrics.repairRequests == 1, "explicit ID repair accepts only the valid corrected evidence")
        var missing = try JSONSerialization.jsonObject(with: Data(try V.canonical(final(blockID)).utf8)) as! [String: Any]
        missing.removeValue(forKey: "evidenceBlockIDs"); missing["unexpectedField"] = true
        let missingJSON = String(decoding: try JSONSerialization.data(withJSONObject: missing, options: [.sortedKeys]), as: UTF8.self)
        let schemaReplies = Replies([chapter, missingJSON, try V.canonical(final(blockID))])
        let schemaOutput = try await engine(schemaReplies).run(input)
        let schemaRepair = schemaReplies.calls[2].0
        try check(schemaRepair.contains("missing fields: [evidenceBlockIDs]") && schemaRepair.contains("extra fields: [unexpectedField]") && schemaRepair.contains("allowed IDs: [\(blockID)]"), "schema repair lists exact missing/extra fields and allowed evidence IDs")
        try check(schemaRepair.contains("evidenceBlockIDs 必须独立于 keyPoints") && !schemaRepair.contains("不应出现在诊断中的完整原文"), "repair keeps evidence separate from key points without exposing source text in diagnostics")
        try check(schemaOutput.segments[0].evidenceBlockIDs == [blockID] && schemaOutput.metrics.repairRequests == 1, "missing evidence field can recover within one repair")
    }
    static func main() async throws {
        try preparationTests()
        try await modelTests()
        try await evidenceAndCancellationTests()
        try await reviewRegressionTests()
        try await concurrentFinalTests()
        try await repairDiagnosticTests()
        print("ContentSegmentationV2Smoke: \(checks) checks passed")
    }
}
