import Foundation
@main struct NotebookPlacesSmoke {
 static func main() throws {
  let db=try DaybookDatabase(inMemory:true)
  let repo=try NotebookPlacesRepository(database:db)
  let at=ISO8601DateFormatter().date(from:"2026-11-03T00:30:00Z")!
  let a=CaptureLocation(latitude:1.3,longitude:103.8,source:.photoMetadata)!
  let b=CaptureLocation(latitude:1.4,longitude:103.8,source:.photoMetadata)!
  func evidence(_ key:String,_ point:CaptureLocation,_ date:Date,_ zone:String? = "Asia/Singapore") -> NotebookPlaceEvidence {
   .init(id:key,sourceID:UUID(),sourceKind:"photo",capturedAt:date,timeZoneIdentifier:zone,location:point)
  }
  try repo.replaceEvidence([evidence("a",a,at),evidence("b",b,at),evidence("c",a,at),evidence("d",a,at.addingTimeInterval(-86400))])
  let places=try repo.page(now:at)
  precondition(places.count==2 && places[0].days==2)
  let id=NotebookPlaceGrid.id(a)
  try repo.saveLabel(id:id,name:"家",type:"家")
  try repo.replaceEvidence([evidence("a",a,at)])
  do { try repo.saveLabel(id:id,name:"stale",type:nil,expectedRevision:0);preconditionFailure("label conflict accepted") } catch NotebookPlacesError.conflict {}
  let renamed=try repo.page(now:at)
  precondition(renamed[0].id==id && renamed[0].name=="家" && renamed[0].days==1)
  try repo.replaceEvidence([])
  let empty=try repo.page(now:at);precondition(empty.isEmpty)
  try repo.replaceEvidence([evidence("a",a,at)])
  let restored=try repo.page(now:at);precondition(restored[0].name=="家")
  // Inclusive 30 natural days: today and day -29 count, day -30 and tomorrow do not.
  try repo.replaceEvidence([evidence("today",a,at),evidence("edge",a,at.addingTimeInterval(-29*86400)),evidence("old",a,at.addingTimeInterval(-30*86400)),evidence("future",a,at.addingTimeInterval(86400))])
  let window=try repo.page(now:at);precondition(window.first?.days==2)
  // First unknown timezone uses UTC, and later browser/default timezone changes do not shift it.
  try repo.replaceEvidence([evidence("unknown",a,at,nil)])
  let first=try repo.visits(placeID:id,now:at)
  precondition(first[0].day=="2026-11-03" && first[0].dateBasis.contains("UTC"))
  try repo.replaceEvidence([evidence("unknown",a,at,"America/Los_Angeles")])
  let fixed=try repo.visits(placeID:id,now:at);precondition(fixed[0].day==first[0].day)
  var original=evidence("original",a,at,nil);original.originalLocalDate="2026-11-02"
  try repo.replaceEvidence([original])
  let originalVisit=try repo.visits(placeID:id,now:at);precondition(originalVisit[0].day=="2026-11-02" && originalVisit[0].dateBasis.contains("原始自然日期"))
  var addressed=b
  addressed.address=CaptureAddress(text:"示例街道 1 号",localeIdentifier:"zh_CN")
  try repo.replaceEvidence([evidence("address",addressed,at)])
  let fallback=try repo.page(now:at);precondition(fallback[0].name=="示例街道 1 号" && fallback[0].coordinateHint != nil)
  try repo.saveLabel(id:fallback[0].id,name:"公司",type:"公司",expectedRevision:0)
  addressed.address=CaptureAddress(text:"更新后的地址",localeIdentifier:"zh_CN")
  try repo.replaceEvidence([evidence("address",addressed,at)])
  let manual=try repo.page(now:at);precondition(manual[0].name=="公司")
  let negative=CaptureLocation(latitude:-0.0001,longitude:-0.0001,source:.photoMetadata)!
  precondition(NotebookPlaceGrid.id(negative)=="grid-v1:-1:-1")
  // Real-source rebuild excludes photos without original capture time and never uses import time.
  let moment=UUID().uuidString
  try db.execute("INSERT INTO photo_moments(id,captured_at,caption,recognized_text,imported_at) VALUES(?,?,'','',?)",[.text(moment),.real(at.timeIntervalSinceReferenceDate),.real(at.timeIntervalSinceReferenceDate)])
  var photo=PhotoCaptureMetadata(capturedAt:at,device:nil,importMethod:.library,location:a)
  photo.originalLocalDate="2026-11-03"
  try db.execute("INSERT INTO photo_attachments(id,moment_id,position,filename,recognized_text,capture) VALUES('photo1',?,0,'one.jpg','',?)",[.text(moment),try DaybookDatabase.json(photo)])
  photo.capturedAt=nil
  try db.execute("INSERT INTO photo_attachments(id,moment_id,position,filename,recognized_text,capture) VALUES('photo2',?,1,'two.jpg','',?)",[.text(moment),try DaybookDatabase.json(photo)])
  try repo.rebuild(now:at)
  let actual=try repo.page(now:at),actualVisits=try repo.visits(placeID:id,now:at)
  precondition(actual.count==1 && actual[0].days==1 && actualVisits.count==1 && actualVisits[0].sourceID.uuidString==moment)
  try db.execute("DELETE FROM photo_moments WHERE id=?",[.text(moment)])
  try repo.rebuild(now:at)
  let deleted=try repo.page(now:at);precondition(deleted.isEmpty)
  // Session samples and multiple chunk files retain source identity, deduplicate day counts.
  let session=UUID(),samplePoint=CaptureLocation(latitude:1.3,longitude:103.8,accuracy:5,measuredAt:at,source:.phoneRecording)!
  try db.execute("INSERT INTO recording_sessions(id,started_at,time_zone_identifier,created_at) VALUES(?,?,'Asia/Singapore',?)",[.text(session.uuidString),.real(at.timeIntervalSinceReferenceDate),.real(at.timeIntervalSinceReferenceDate)])
  let sample=RecordingLocationSample(sessionID:session,sessionOffset:0,requestedAt:at,location:samplePoint,sourceDevice:"fixture")
  try db.execute("INSERT INTO recording_location_samples(id,session_id,session_offset,requested_at,payload) VALUES(?,?,0,?,?)",[.text(sample.id.uuidString),.text(session.uuidString),.real(at.timeIntervalSinceReferenceDate),try DaybookDatabase.json(sample)])
  try db.execute("DELETE FROM notebook_place_labels WHERE place_id=?",[.text(id)])
  let cached=CaptureAddress(text:"采样位置缓存地址",localeIdentifier:"zh_CN")!
  try db.execute("INSERT INTO recording_location_addresses(sample_id,payload) VALUES(?,?)",[.text(sample.id.uuidString),try DaybookDatabase.json(cached)])
  struct ChunkProjection:Encodable { let capturedAt:Date;let location:CaptureLocation }
  for ordinal in 0...1 {
   try db.execute("INSERT INTO recording_chunks(id,session_id,ordinal,filename,captured_at,session_start_offset,frame_count,sample_rate,byte_count,sha256,payload) VALUES(?,?,?,?,?,0,1,1,1,?,?)",[.text(UUID().uuidString),.text(session.uuidString),.integer(Int64(ordinal)),.text("fixture-\(ordinal).m4a"),.real(at.timeIntervalSinceReferenceDate),.text(String(repeating:"0",count:64)),try DaybookDatabase.json(ChunkProjection(capturedAt:at,location:samplePoint))])
  }
  try repo.rebuild(now:at)
  let sessions=try repo.page(now:at),sessionVisits=try repo.visits(placeID:id,now:at)
  precondition(sessions[0].name=="采样位置缓存地址")
  precondition(sessions[0].days==1 && sessionVisits.count==3 && sessionVisits.allSatisfy{$0.sourceID==session})
  let separatePoint=CaptureLocation(latitude:1.6,longitude:103.8,accuracy:5,measuredAt:at,source:.phoneRecording)!
  let separateSample=RecordingLocationSample(sessionID:session,sessionOffset:0,requestedAt:at,location:separatePoint,sourceDevice:"fixture")
  try db.execute("INSERT INTO recording_location_samples(id,session_id,session_offset,requested_at,payload) VALUES(?,?,0,?,?)",[.text(separateSample.id.uuidString),.text(session.uuidString),.real(at.timeIntervalSinceReferenceDate),try DaybookDatabase.json(separateSample)])
  try repo.rebuild(now:at)
  let separated=try repo.page(now:at)
  precondition(separated.first(where:{$0.id==NotebookPlaceGrid.id(separatePoint)})?.name=="未命名区域")
  precondition(separated.first(where:{$0.id==id})?.name=="采样位置缓存地址")
  try db.execute("DELETE FROM recording_sessions WHERE id=?",[.text(session.uuidString)])
  // Legacy note capture metadata is decoded without requiring transcript content.
  struct NoteProjection:Encodable { let capturedAt:Date;let location:CaptureLocation;let origin:RecordingOrigin? }
  let note=UUID()
  try db.execute("INSERT INTO voice_notes(id,captured_at,kind,title,transcript,summary,duration,audio_filename,payload) VALUES(?,?,'long','','','',1,'legacy.m4a',?)",[.text(note.uuidString),.real(at.timeIntervalSinceReferenceDate),try DaybookDatabase.json(NoteProjection(capturedAt:at,location:a,origin:nil))])
  try repo.rebuild(now:at)
  let notes=try repo.visits(placeID:id,now:at);precondition(notes.count==1 && notes[0].sourceID==note && notes[0].dateBasis.contains("UTC"))
  try db.execute("DELETE FROM voice_notes WHERE id=?",[.text(note.uuidString)])
  try repo.rebuild(now:at)
  let noSources=try repo.page(now:at);precondition(noSources.isEmpty)
  print("Notebook places smoke passed")
 }
}
