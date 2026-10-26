import Foundation

@main struct ContentSegmentationV2ProductionSmoke {
    typealias V = ContentSegmentationV2
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw NSError(domain:"ContentV2Production",code:1,userInfo:[NSLocalizedDescriptionKey:name]) }
    }
    final class Memory: @unchecked Sendable {
        let lock=NSLock()
        var values:[String:Data]=[:]
        var publications:[V.Output]=[]
        func load(_ key:String)->Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
        func save(_ key:String,_ data:Data) { lock.lock(); defer { lock.unlock() }; values[key]=data }
        func publish(_ output:V.Output) { lock.lock(); defer { lock.unlock() }; publications.append(output) }
        func publicationCount()->Int { lock.lock(); defer { lock.unlock() }; return publications.count }
    }
    static func fixture()->V.Input {
        .init(sourceID:"production-source",sourceRevision:"rev-3",duration:300,
              spans:[.init(id:"row-a",start:10,end:60,text:"讨论产品定价与目标客户。"),.init(id:"row-b",start:100,end:120,text:"然后转到周末要去医院复诊。"),.init(id:"row-c",start:150,end:170,text:"确认周末出发。")],
              asrCoverage:[.init(start:0,end:300)],vadCoverage:[.init(start:0,end:300)],
              activities:[.init(start:0,end:300,kind:.speech)])
    }
    static func response(_ value:Encodable)throws->String { String(decoding:try JSONEncoder().encode(value),as:UTF8.self) }
    static func main() async throws {
        try check(V.LongRecordingTopicPolicy.action(duration:1_800,sourceComplete:false) == .waitForSourceCompletion,
                  "recordings at or below thirty minutes wait for source completion")
        try check(V.LongRecordingTopicPolicy.action(duration:2_400,sourceComplete:false) == .splitTopics,
                  "recordings longer than thirty minutes can be segmented while still uploading")
        try check(V.LongRecordingTopicPolicy.action(duration:1_800,sourceComplete:true) == .keepWholeRecording,
                  "completed recordings up to and including thirty minutes remain one item")
        try check(V.LongRecordingTopicPolicy.action(duration:1_801,sourceComplete:true) == .splitTopics,
                  "closed recordings beyond thirty minutes use topic segmentation")
        try check(V.LongRecordingTopicPolicy.action(duration:1_000,sourceComplete:true) == .keepWholeRecording,
                  "chunk count does not trigger topic segmentation below thirty minutes")

        let input=fixture(), plan=try V.prepare(input), ids=plan.blocks.map(\.id)
        let chapter=V.ChapterReply(chapterID:plan.chapters[0].id,segments:[
            .init(firstBlockID:ids[0],lastBlockID:ids[0],topic:"产品定价",rationale:"第一句明确讨论产品价格",contentKind:.discussion,confidence:.high,evidenceBlockIDs:[ids[0]]),
            .init(firstBlockID:ids[1],lastBlockID:ids[1],topic:"复诊安排",rationale:"第二句是独立安排",contentKind:.discussion,confidence:.high,evidenceBlockIDs:[ids[1]])])
        let replies=[try response(chapter),try response(V.MergeReply(merge:false,reason:"议题和行动对象不同")),
                     try response(V.FinalReply(title:"产品定价讨论",summary:"讨论了产品定价与目标客户。",shortSummary:"定价与客户",keyPoints:[],classification:.meaningful,contentKind:.discussion,confidence:.high,uncertainty:"",evidenceBlockIDs:[ids[0]])),
                     try response(V.FinalReply(title:"复诊安排",summary:"提到周末去医院复诊。",shortSummary:"周末复诊",keyPoints:[],classification:.meaningful,contentKind:.discussion,confidence:.high,uncertainty:"",evidenceBlockIDs:[ids[1]]))]
        let memory=Memory()
        let responseState=ResponseState(replies)
        let output=try await ContentSegmentationV2Production.run(input:input,modelIdentity:"fixture-model",maximumConcurrentFinalRequests:1,
            model:{ _,_ in try responseState.next() },loadCheckpoint:{ memory.load($0) },saveCheckpoint:{ memory.save($0,$1) },publish:{ value in
                try V.validateOutput(plan:value.plan,segments:value.segments,original:input.spans)
                memory.publish(value)
            })
        try check(output.segments.count==2,"production runner produces chapter-internal topic splits")
        try check(memory.publicationCount()==1,"publish occurs only once after validated complete output")
        try check(responseState.callCount==4,"chapter, merge and final requests run through production adapter")
        let resumed=try await ContentSegmentationV2Production.run(input:input,modelIdentity:"fixture-model",maximumConcurrentFinalRequests:1,
            model:{ _,_ in throw NSError(domain:"unexpectedModelRequest",code:1) },
            loadCheckpoint:{ memory.load($0) },saveCheckpoint:{ memory.save($0,$1) },publish:{ value in memory.publish(value) })
        try check(resumed.segments==output.segments && resumed.metrics.checkpointHits==4,"production retry reuses exact completed model checkpoints")
        let failed=Memory()
        do {
            _ = try await ContentSegmentationV2Production.run(input:input,modelIdentity:"failed-model",maximumConcurrentFinalRequests:1,
                model:{ _,_ in throw NSError(domain:"transport",code:1) },loadCheckpoint:{ failed.load($0) },
                saveCheckpoint:{ failed.save($0,$1) },publish:{ value in failed.publish(value) })
            throw NSError(domain:"expectedFailure",code:1)
        } catch V.Failure.stage {
            try check(failed.publicationCount()==0,"model failure never publishes partial content")
        }
        let singleInput=V.Input(sourceID:"metadata-pending-source",sourceRevision:"rev-1",duration:300,
            spans:[.init(id:"row-only",start:10,end:60,text:"讨论一个具体的产品定价问题。")],
            asrCoverage:[.init(start:0,end:300)],vadCoverage:[.init(start:0,end:300)],activities:[.init(start:0,end:300,kind:.speech)])
        let singlePlan=try V.prepare(singleInput), singleBlock=singlePlan.blocks[0]
        let singleChapter=V.ChapterReply(chapterID:singlePlan.chapters[0].id,segments:[.init(firstBlockID:singleBlock.id,lastBlockID:singleBlock.id,topic:"产品定价",rationale:"完整讨论一个定价问题",contentKind:.discussion,confidence:.high,evidenceBlockIDs:[singleBlock.id])])
        let pendingMetadata=Memory(), pendingMetadataReplies=ResponseState([
            try response(singleChapter),
            try response(V.FinalReply(title:"",summary:"",shortSummary:"",keyPoints:[],classification:.meaningful,contentKind:.discussion,confidence:.high,uncertainty:"",evidenceBlockIDs:[singleBlock.id])),
            try response(V.FinalReply(title:"",summary:"",shortSummary:"",keyPoints:[],classification:.meaningful,contentKind:.discussion,confidence:.high,uncertainty:"",evidenceBlockIDs:[singleBlock.id]))])
        let pendingMetadataOutput=try await ContentSegmentationV2Production.run(input:singleInput,modelIdentity:"metadata-pending-model",
            model:{ _,_ in try pendingMetadataReplies.next() },loadCheckpoint:{ pendingMetadata.load($0) },saveCheckpoint:{ pendingMetadata.save($0,$1) },
            publish:{ value in pendingMetadata.publish(value) })
        try check(pendingMetadataOutput.segments.count==1 && pendingMetadataOutput.segments[0].classification == .meaningful && pendingMetadataOutput.segments[0].title.isEmpty && pendingMetadataOutput.segments[0].summary.isEmpty,"classification finalizes independently while title and summary can remain pending")

        let wholeMemory=Memory(), wholeReplies=ResponseState([
            try response(V.FinalReply(title:"",summary:"",shortSummary:"",keyPoints:[],classification:.meaningful,contentKind:.discussion,confidence:.high,uncertainty:"",evidenceBlockIDs:[ids[0]]))])
        let wholeOutput=try await ContentSegmentationV2Production.run(input:input,modelIdentity:"whole-recording-model",topicSplitting:false,
            model:{ _,_ in try wholeReplies.next() },loadCheckpoint:{ wholeMemory.load($0) },saveCheckpoint:{ wholeMemory.save($0,$1) },publish:{ value in wholeMemory.publish(value) })
        try check(wholeOutput.segments.count==1 && wholeReplies.callCount==1,
                  "whole-recording path skips topic and merge requests, retaining final classification")
        print("ContentSegmentationV2ProductionSmoke: production routing, validation-before-publish, checkpoint resume, and failure atomicity passed")
    }
}
    final class ResponseState: @unchecked Sendable {
        private let lock=NSLock(); private var replies:[String]; private var calls=0
        init(_ replies:[String]) { self.replies=replies }
        var callCount:Int { lock.lock(); defer { lock.unlock() }; return calls }
        func next() throws -> String { lock.lock(); defer { lock.unlock() }; calls += 1; guard !replies.isEmpty else { throw NSError(domain:"fixture",code:1) }; return replies.removeFirst() }
    }
