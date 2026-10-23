import Foundation

private func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
@main struct ContentEnrichmentAuthorizationSmoke {
    static func main() throws {
        let db = try DaybookDatabase(inMemory:true), id=AudioSourceID(kind:.session,id:UUID())
        let processing=AudioProcessingRepository(database:db)
        try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)",[.text(id.id.uuidString)])
        let range=try AudioSourceRange(range:.init(chunkID:UUID(),url:URL(fileURLWithPath:"/synthetic/sample.m4a"),startFrame:0,endFrame:160000,sampleRate:16000),contentHash:String(repeating:"a",count:64))
        let source=try AudioSourceSnapshot(id:id,capturedAt:Date(timeIntervalSinceReferenceDate:800000000),title:"一次录音",ranges:[range],complete:true)
        try processing.register(source:source,configurationKey:"test",windows:AudioWindowPlanner.plan(source:source,configurationKey:"test"))
        let job=try processing.claimNext()!
        try processing.commit(job:job,result:.init(spans:[.init(start:0,end:5,text:"确认材料")],activities:[],asr:.success,vad:.success,speaker:.notRequested,asrCoverage:[.init(start:0,end:10)],vadCoverage:[.init(start:0,end:10)]))
        try ContentSegmentRepository(database:db).reconcile(sourceID:id)
        let a=try ContentEnrichmentAuthorization.scope(database:db,sourceID:id)!
        expect(try ContentEnrichmentAuthorization.transcriptPage(database:db,scope:a,offset:0).first?.text == "确认材料","preview reads the actual current transcript")
        let point=CaptureLocation(latitude:40,longitude:116,accuracy:100,measuredAt:source.capturedAt,source:.watchRecording)!
        let sample=RecordingLocationSample(id:UUID(),sessionID:id.id,sessionOffset:0,requestedAt:source.capturedAt,location:point,sourceDevice:"Watch")
        try db.execute("INSERT INTO recording_location_samples(id,session_id,session_offset,requested_at,payload) VALUES (?,?,?,?,?)",[.text(sample.id.uuidString),.text(id.id.uuidString),.real(0),.real(source.capturedAt.timeIntervalSinceReferenceDate),try DaybookDatabase.json(sample)])
        let b=try ContentEnrichmentAuthorization.scope(database:db,sourceID:id)!
        expect(a != b,"late location invalidates a previously displayed consent snapshot")
        do { _ = try ContentEnrichmentAuthorization.transcriptPage(database:db,scope:a,offset:0); fatalError("stale preview must fail") } catch ContentSegmentError.staleRevision {}
        expect(try ContentEnrichmentAuthorization.contextPage(database:db,scope:b,offset:0).contains("100"),"preview discloses accuracy with observed position")
        let address=CaptureAddress(text:"地点测试楼",localeIdentifier:"zh-CN")!
        try db.execute("INSERT INTO recording_location_addresses(sample_id,payload) VALUES (?,?)",[.text(sample.id.uuidString),try DaybookDatabase.json(address)])
        let c=try ContentEnrichmentAuthorization.scope(database:db,sourceID:id)!
        expect(c != b,"new resolved address invalidates consent before it can be sent")
        expect(try ContentEnrichmentAuthorization.contextPage(database:db,scope:c,offset:0).contains("地点测试楼"),"confirmation previews the address used by AI")
        let preview=try ContentEnrichmentAuthorization.contextPage(database:db,scope:c,offset:0)
        expect(preview.contains("40.0000, 116.0000") && preview.contains("请求时间"),"address does not hide transmitted coordinates or request time")
        try processing.delete(sourceID:id)
        expect(try ContentEnrichmentAuthorization.scope(database:db,sourceID:id) == nil,"deleted source cannot keep an authorization")
        print("Content enrichment authorization: actual transcript preview, late GPS invalidation, stale preview and deletion passed")
    }
}
