import CryptoKit
import Foundation

/// Authorization names the current source data, not a mutable segment or an app-wide
/// Boolean. Topic edits may change segment IDs; new ASR or location invalidates consent.
struct ContentEnrichmentScope: Equatable, Sendable {
    let sourceID: AudioSourceID
    let fingerprint: String
    let title: String
}

enum ContentEnrichmentAuthorization {
    static let pageSize = 100
    static func scope(database db: DaybookDatabase, sourceID: AudioSourceID) throws -> ContentEnrichmentScope? {
        try db.transaction {
            guard try db.query("SELECT source_key FROM audio_source_tombstones WHERE source_key=?",[.text(sourceID.key)]).isEmpty else { return nil }
            if sourceID.kind == .session {
                guard try db.query("SELECT session_id FROM recording_session_tombstones WHERE session_id=?",[.text(sourceID.id.uuidString)]).isEmpty else { return nil }
            } else {
                guard try db.query("SELECT id FROM media_tombstones WHERE kind='voice' AND id=?",[.text(sourceID.id.uuidString)]).isEmpty else { return nil }
            }
            let processing=AudioProcessingRepository(database:db)
            guard let source=try processing.currentSource(sourceID) else { return nil }
            let progress=try processing.progress(sourceID:sourceID)
            var digest=SHA256()
            digest.update(data:Data([source.contentIdentity,progress.configurationKey ?? "",String(progress.revision)].joined(separator:"|").utf8))
            for row in try db.query("SELECT result_hash FROM audio_processing_jobs WHERE source_key=? AND active=1 ORDER BY id",[.text(sourceID.key)]) {
                digest.update(data:Data((row["result_hash"]?.string ?? "pending").utf8))
            }
            if sourceID.kind == .session {
                var offset=0
                while true {
                    let rows=try locationRows(db,sourceID:sourceID,offset:offset)
                    for row in rows {
                        if let data=row["payload"]?.data { digest.update(data:data) }
                        if let address=row["address_payload"]?.data { digest.update(data:address) }
                    }
                    offset += rows.count; if rows.count < pageSize { break }
                }
            }
            return .init(sourceID:sourceID,fingerprint:digest.finalize().map { String(format:"%02x",$0) }.joined(),title:source.title)
        }
    }
    static func transcriptPage(database db: DaybookDatabase, scope expected: ContentEnrichmentScope, offset: Int) throws -> [AudioTranscriptSpan] {
        try db.transaction {
            guard offset >= 0, try scope(database:db,sourceID:expected.sourceID) == expected else { throw ContentSegmentError.staleRevision }
            return try AudioProcessingRepository(database:db).spans(sourceID:expected.sourceID,limit:pageSize,offset:offset)
        }
    }
    static func contextPage(database db: DaybookDatabase, scope expected: ContentEnrichmentScope, offset: Int) throws -> String {
        try db.transaction {
            guard offset >= 0, try scope(database:db,sourceID:expected.sourceID) == expected,
                  let source=try AudioProcessingRepository(database:db).currentSource(expected.sourceID) else { throw ContentSegmentError.staleRevision }
            let date=ISO8601DateFormatter()
            var lines = offset == 0 ? ["录音开始：\(date.string(from:source.capturedAt))", "地点是稀疏采样，不能证明完整路线。"] : []
            if offset == 0, let point=source.location { lines.append(describe(point,device:source.origin?.device ?? "录音设备",date:date)) }
            if expected.sourceID.kind == .session {
                for row in try locationRows(db,sourceID:expected.sourceID,offset:offset) {
                    let sample=try DaybookDatabase.decode(RecordingLocationSample.self,row["payload"])
                    var point=sample.location
                    if let address=row["address_payload"], address != .null { point.address=try DaybookDatabase.decode(CaptureAddress.self,address) }
                    lines.append("录音内 \(Int(sample.sessionOffset)) 秒；请求时间 \(date.string(from:sample.requestedAt))："+describe(point,device:sample.sourceDevice,date:date))
                }
            }
            return lines.joined(separator:"\n")
        }
    }
    private static func describe(_ point: CaptureLocation, device: String, date: ISO8601DateFormatter) -> String {
        let measured=point.measuredAt.map { date.string(from:$0) } ?? "时间未知"
        let accuracy=point.accuracy.map { String(format:"%.1f 米",$0) } ?? "未知"
        let address=point.address.map { " · "+$0.text } ?? ""
        return "\(measured) · \(device)（\(point.source.rawValue)） · \(point.title)\(address) · 精度约 \(accuracy)"
    }
    private static func locationRows(_ db: DaybookDatabase, sourceID: AudioSourceID, offset: Int) throws -> [DaybookDatabase.Row] {
        try db.query("SELECT s.payload,a.payload AS address_payload FROM recording_location_samples s LEFT JOIN recording_location_addresses a ON a.sample_id=s.id WHERE s.session_id=? ORDER BY s.session_offset,s.requested_at,s.id LIMIT ? OFFSET ?",[.text(sourceID.id.uuidString),.integer(Int64(pageSize)),.integer(Int64(offset))])
    }
}
