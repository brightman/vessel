import Foundation
@main struct NotebookPeopleSmoke {
 static func main() throws {
  let db = try DaybookDatabase(inMemory:true)
  let repo = try NotebookPeopleRepository(database:db)
  let a = try repo.save(id:nil, expectedRevision:nil, name:"Alice", organization:"Acme", relationships:["朋友"," 同学 ","朋友",""])
  precondition(a.relationships == ["朋友","同学"])
  let b = try repo.save(id:nil, expectedRevision:nil, name:"Alice", organization:nil, relationships:[])
  precondition(a.id != b.id && b.relationships.isEmpty)
  let filtered = try repo.page(relationship:"同学"); precondition(filtered.count == 1)
  let edited = try repo.save(id:a.id,expectedRevision:a.revision,name:"Alice 2",organization:nil,relationships:["自定义"])
  precondition(edited.revision == a.revision+1)
  do { _ = try repo.save(id:a.id,expectedRevision:a.revision,name:"stale",organization:nil,relationships:[]); preconditionFailure("conflict accepted") } catch NotebookPeopleError.conflict {}
  let reopened = try NotebookPeopleRepository(database:db)
  let all = try reopened.page(); precondition(all.first(where:{$0.id == a.id})?.relationships == ["自定义"])
  let next = try reopened.page(limit:1,offset:1); precondition(next.count == 1)
  // Old contacts without metadata remain editable; external contact saves invalidate stale editors.
  try db.execute("INSERT INTO contacts(id,origin_type,display_name,sync_state,created_at,updated_at) VALUES('manual:old','manual','Old','manual',0,0)")
  let old = try repo.page().first(where:{$0.id == "manual:old"})!
  precondition(old.revision == 0 && old.relationships.isEmpty)
  try db.execute("UPDATE contacts SET display_name='External edit' WHERE id=?",[.text(a.id)])
  do { _ = try repo.save(id:a.id,expectedRevision:edited.revision,name:"stale",organization:nil,relationships:[]); preconditionFailure("external conflict accepted") } catch NotebookPeopleError.conflict {}
  let saved = try repo.createContact(name:"New",organization:nil,email:"a@example.test",phone:"123",relationships:["朋友","朋友"])
  precondition(saved.emails.first?.value == "a@example.test")
  let session=UUID().uuidString,key="session:"+session
  try db.execute("INSERT INTO recording_sessions(id,started_at,created_at) VALUES(?,100,100)",[.text(session)])
  try db.execute("INSERT INTO audio_processing_sources(source_key,kind,source_id,session_id,descriptor,fingerprint,configuration_key) VALUES(?,'session',?,?,?,'f','c')",[.text(key),.text(session),.text(session),.blob(Data())])
  try db.execute("INSERT INTO audio_processing_jobs(id,source_key,configuration_key,core_start,core_end,window,state,result) VALUES('j',?,'c',0,20,?,'completed',?)",[.text(key),.blob(Data()),.blob(Data())])
  try db.execute("INSERT INTO audio_transcript_spans(job_id,position,start,end,text,speaker_id) VALUES('j',0,2,7,'hello','speaker-1')")
  try db.execute("INSERT INTO recording_speaker_contacts(source_key,speaker_id,contact_id,linked_at,speaker_revision) VALUES(?,'speaker-1',?,0,'outdated')",[.text(key),.text(b.id)])
  let sources=try repo.sources(contactID:b.id)
  precondition(sources.count == 1 && sources[0].sourceID.uuidString == session && sources[0].start == 2 && sources[0].end == 7 && sources[0].needsReview)
  try db.execute("DELETE FROM recording_speaker_contacts WHERE contact_id=?",[.text(b.id)])
  let unbound=try repo.page(); precondition(unbound.contains(where:{$0.id==b.id}))
  try db.execute("INSERT INTO recording_speaker_contacts(source_key,speaker_id,contact_id,linked_at,speaker_revision) VALUES(?,'speaker-1',?,0,'outdated')",[.text(key),.text(b.id)])
  try db.execute("DELETE FROM recording_sessions WHERE id=?",[.text(session)])
  let remaining=try repo.page(),deletedSources=try repo.sources(contactID:b.id)
  precondition(remaining.contains(where:{$0.id==b.id}) && deletedSources.isEmpty)
  print("Notebook people smoke passed")
 }
}
