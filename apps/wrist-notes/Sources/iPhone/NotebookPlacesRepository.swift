import Foundation

/// A rebuildable evidence index plus independent manual labels. Run on a background worker.
final class NotebookPlacesRepository {
    private let db:DaybookDatabase
    init(database:DaybookDatabase) throws {
        db=database
        try db.transaction {
            try db.execute("CREATE TABLE IF NOT EXISTS notebook_place_labels (place_id TEXT PRIMARY KEY,name TEXT NOT NULL,type TEXT,revision INTEGER NOT NULL DEFAULT 0)")
            try db.execute("CREATE TABLE IF NOT EXISTS notebook_place_evidence (id TEXT PRIMARY KEY,place_id TEXT NOT NULL,source_id TEXT NOT NULL,source_kind TEXT NOT NULL,captured_at REAL NOT NULL,day TEXT NOT NULL,time_zone TEXT NOT NULL,date_basis TEXT NOT NULL,display_label TEXT,coordinate_label TEXT)")
            let columns=try db.query("PRAGMA table_info(notebook_place_evidence)").compactMap{$0["name"]?.string}
            if !columns.contains("display_label") { try db.execute("ALTER TABLE notebook_place_evidence ADD COLUMN display_label TEXT") }
            if !columns.contains("coordinate_label") { try db.execute("ALTER TABLE notebook_place_evidence ADD COLUMN coordinate_label TEXT") }
            try db.execute("CREATE INDEX IF NOT EXISTS notebook_places_day ON notebook_place_evidence(place_id,day,source_id)")
        }
    }
    func replaceEvidence(_ evidence:[NotebookPlaceEvidence]) throws {
        try db.transaction {
            try db.execute("CREATE TEMP TABLE IF NOT EXISTS notebook_place_seen (id TEXT PRIMARY KEY)")
            try db.execute("DELETE FROM notebook_place_seen")
            for item in evidence {
                guard item.capturedAt.timeIntervalSinceReferenceDate.isFinite else { continue }
                let prior=try db.query("SELECT day,time_zone,date_basis FROM notebook_place_evidence WHERE id=?",[.text(item.id)]).first
                let zone:String,basis:String,day:String
                if let prior {
                    zone=prior["time_zone"]?.string ?? "UTC";basis=prior["date_basis"]?.string ?? "UTC 日期（原始时区未知）";day=prior["day"]?.string ?? NotebookPlaceGrid.day(item.capturedAt,zone:zone)
                } else if let original=item.originalLocalDate,NotebookPlaceGrid.validDay(original) {
                    zone=item.timeZoneIdentifier.flatMap{TimeZone(identifier:$0)}?.identifier ?? "UTC"
                    basis=item.timeZoneIdentifier.flatMap{TimeZone(identifier:$0)} == nil ? "照片原始自然日期（原始时区未知，时间按 UTC 显示）" : "照片原始自然日期";day=original
                } else if let known=item.timeZoneIdentifier,TimeZone(identifier:known) != nil {
                    zone=known;basis="来源保存的时区：\(known)";day=NotebookPlaceGrid.day(item.capturedAt,zone:zone)
                } else {
                    zone="UTC";basis="UTC 日期（原始时区未知，首次索引后固定）";day=NotebookPlaceGrid.day(item.capturedAt,zone:zone)
                }
                try db.execute("INSERT INTO notebook_place_evidence(id,place_id,source_id,source_kind,captured_at,day,time_zone,date_basis,display_label,coordinate_label) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET place_id=excluded.place_id,source_id=excluded.source_id,source_kind=excluded.source_kind,captured_at=excluded.captured_at,display_label=excluded.display_label,coordinate_label=excluded.coordinate_label",[.text(item.id),.text(NotebookPlaceGrid.id(item.location)),.text(item.sourceID.uuidString),.text(item.sourceKind),.real(item.capturedAt.timeIntervalSinceReferenceDate),.text(day),.text(zone),.text(basis),item.location.address.map{.text($0.text)} ?? .null,.text(String(format:"约 %.3f°, %.3f°",item.location.latitude,item.location.longitude))])
                try db.execute("INSERT OR IGNORE INTO notebook_place_seen(id) VALUES(?)",[.text(item.id)])
            }
            try db.execute("DELETE FROM notebook_place_evidence WHERE id NOT IN (SELECT id FROM notebook_place_seen)")
            try db.execute("DELETE FROM notebook_place_seen")
        }
    }
    /// Decode only capture projections; voice-note transcript payloads are never materialized as strings.
    func rebuild(now:Date = .now) throws {
        let lower=now.addingTimeInterval(-32*86400).timeIntervalSinceReferenceDate
        let upper=now.addingTimeInterval(2*86400).timeIntervalSinceReferenceDate
        struct LegacyCapture:Decodable { let capturedAt:Date;let location:CaptureLocation?;let origin:RecordingOrigin? }
        struct ChunkCapture:Decodable { let capturedAt:Date;let location:CaptureLocation? }
        var evidence:[NotebookPlaceEvidence]=[]
        func batches(_ sql:String,_ consume:(DaybookDatabase.Row)throws->Void) throws {
            var offset=0
            while true {
                let rows=try db.query(sql+" LIMIT 256 OFFSET ?",[.real(lower),.real(upper),.integer(Int64(offset))])
                for row in rows { try consume(row) };if rows.count<256 { break };offset+=rows.count
            }
        }
        try db.transaction {
            try batches("SELECT id,payload FROM voice_notes WHERE captured_at BETWEEN ? AND ? ORDER BY id") { row in
                guard let id=row["id"]?.string.flatMap(UUID.init(uuidString:)),let payload=row["payload"]?.data else { return }
                let capture=try JSONDecoder().decode(LegacyCapture.self,from:payload)
                if let point=capture.location { evidence.append(.init(id:"note:\(id)",sourceID:id,sourceKind:"录音",capturedAt:capture.capturedAt,timeZoneIdentifier:capture.origin?.timeZoneIdentifier,location:point)) }
            }
            try batches("SELECT c.id,c.session_id,c.payload,s.time_zone_identifier FROM recording_chunks c JOIN recording_sessions s ON s.id=c.session_id WHERE c.captured_at BETWEEN ? AND ? ORDER BY c.id") { row in
                guard let id=row["session_id"]?.string.flatMap(UUID.init(uuidString:)),let payload=row["payload"]?.data else { return }
                let capture=try JSONDecoder().decode(ChunkCapture.self,from:payload)
                if let point=capture.location { evidence.append(.init(id:"chunk:"+(row["id"]?.string ?? ""),sourceID:id,sourceKind:"录音",capturedAt:point.measuredAt ?? capture.capturedAt,timeZoneIdentifier:row["time_zone_identifier"]?.string,location:point)) }
            }
            try batches("SELECT l.id,l.session_id,l.session_offset,l.requested_at,l.payload,s.time_zone_identifier,a.payload AS address FROM recording_location_samples l JOIN recording_sessions s ON s.id=l.session_id LEFT JOIN recording_location_addresses a ON a.sample_id=l.id WHERE l.requested_at BETWEEN ? AND ? ORDER BY l.id") { row in
                let sample=try DaybookDatabase.decode(RecordingLocationSample.self,row["payload"])
                // A cache belongs to this exact immutable sample, never a neighbouring cell.
                guard row["id"] == .text(sample.id.uuidString),row["session_id"] == .text(sample.sessionID.uuidString),
                      row["session_offset"]?.double == sample.sessionOffset,
                      row["requested_at"]?.double == sample.requestedAt.timeIntervalSinceReferenceDate else { throw NotebookPlacesError.invalidEvidence }
                var point=sample.location
                if let address=try? DaybookDatabase.decode(CaptureAddress.self,row["address"]) { point.address=address }
                evidence.append(.init(id:"sample:\(sample.id)",sourceID:sample.sessionID,sourceKind:"录音",capturedAt:point.measuredAt ?? sample.requestedAt,timeZoneIdentifier:row["time_zone_identifier"]?.string,location:point))
            }
            try batches("SELECT a.id,a.moment_id,a.capture FROM photo_attachments a JOIN photo_moments m ON m.id=a.moment_id WHERE a.capture IS NOT NULL AND m.captured_at BETWEEN ? AND ? ORDER BY a.id") { row in
                let capture=try DaybookDatabase.decode(PhotoCaptureMetadata.self,row["capture"])
                guard let date=capture.capturedAt,let point=capture.location,let id=row["moment_id"]?.string.flatMap(UUID.init(uuidString:)) else { return }
                evidence.append(.init(id:"photo:"+(row["id"]?.string ?? ""),sourceID:id,sourceKind:"照片",capturedAt:date,timeZoneIdentifier:capture.capturedTimeZoneIdentifier,location:point,originalLocalDate:capture.originalLocalDate))
            }
            try replaceEvidence(evidence)
        }
    }
    func saveLabel(id:String,name:String,type:String?,expectedRevision:Int? = nil) throws {
        try db.transaction {
            let prior=try db.query("SELECT revision FROM notebook_place_labels WHERE place_id=?",[.text(id)]).first
            if let expectedRevision,Int(prior?["revision"]?.double ?? 0) != expectedRevision { throw NotebookPlacesError.conflict }
            try db.execute("INSERT INTO notebook_place_labels(place_id,name,type,revision) VALUES(?,?,?,1) ON CONFLICT(place_id) DO UPDATE SET name=excluded.name,type=excluded.type,revision=revision+1",[.text(id),.text(name.trimmingCharacters(in:.whitespacesAndNewlines)),type.map{.text($0)} ?? .null])
        }
    }
    private func recent(_ row:DaybookDatabase.Row,now:Date)->Bool {
        guard let day=row["day"]?.string else { return false }
        let zone=row["time_zone"]?.string ?? "UTC"
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:zone) ?? TimeZone(secondsFromGMT:0)!
        let today=calendar.startOfDay(for:now),start=calendar.date(byAdding:.day,value:-29,to:today)!
        return day >= NotebookPlaceGrid.day(start,zone:zone) && day <= NotebookPlaceGrid.day(now,zone:zone)
    }
    func page(now:Date = .now,limit:Int = 40,offset:Int = 0) throws -> [NotebookPlace] {
        var dates:[String:Set<String>]=[:]
        for row in try db.query("SELECT DISTINCT place_id,day,time_zone FROM notebook_place_evidence") where recent(row,now:now) {
            if let id=row["place_id"]?.string,let day=row["day"]?.string { dates[id,default:[]].insert(day) }
        }
        var fallbacks:[String:DaybookDatabase.Row]=[:]
        for row in try db.query("SELECT place_id,display_label,coordinate_label FROM notebook_place_evidence ORDER BY captured_at DESC,id") {
            if let id=row["place_id"]?.string, fallbacks[id] == nil || (fallbacks[id]?["display_label"]?.string == nil && row["display_label"]?.string != nil) { fallbacks[id]=row }
        }
        let labels=try db.query("SELECT * FROM notebook_place_labels")
        let map=Dictionary(uniqueKeysWithValues:labels.compactMap { row -> (String,DaybookDatabase.Row)? in guard let id=row["place_id"]?.string else { return nil };return (id,row) })
        let places:[NotebookPlace]=dates.map { id,days in
            let row=map[id]
            let savedName=row?["name"]?.string ?? ""
            let name=savedName.isEmpty ? (fallbacks[id]?["display_label"]?.string ?? "未命名区域") : savedName
            return NotebookPlace(id:id,name:name,type:row?["type"]?.string,days:days.count,revision:Int(row?["revision"]?.double ?? 0),coordinateHint:fallbacks[id]?["coordinate_label"]?.string)
        }
        let ordered=places.sorted { $0.days == $1.days ? $0.id < $1.id : $0.days > $1.days }
        return Array(ordered.dropFirst(max(0,offset)).prefix(max(1,min(100,limit))))
    }
    func visits(placeID:String,now:Date = .now,limit:Int = 50,offset:Int = 0) throws -> [NotebookPlaceVisit] {
        let rows=try db.query("SELECT * FROM notebook_place_evidence WHERE place_id=? ORDER BY day DESC,captured_at DESC,id",[.text(placeID)])
        // Keep every different-time observation; the list groups by day without inflating day counts.
        return rows.filter{recent($0,now:now)}.compactMap { row in
            guard let id=row["source_id"]?.string,let uuid=UUID(uuidString:id),let day=row["day"]?.string else { return nil }
            return NotebookPlaceVisit(id:row["id"]?.string ?? day+":"+id,sourceID:uuid,sourceKind:row["source_kind"]?.string ?? "来源",capturedAt:Date(timeIntervalSinceReferenceDate:row["captured_at"]?.double ?? 0),day:day,dateBasis:row["date_basis"]?.string ?? "UTC 日期",timeZoneIdentifier:row["time_zone"]?.string ?? "UTC")
        }.dropFirst(max(0,offset)).prefix(max(1,min(100,limit))).map{$0}
    }
}
