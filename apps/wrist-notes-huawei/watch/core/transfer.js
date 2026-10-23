// Transport-independent state only. Persist snapshot after every transition before I/O.
// The SDK adapter must authenticate the peer before delivering acknowledgements here.
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function valid(record) {
  return record && typeof record.id === 'string' && uuid.test(record.id) &&
    Number.isSafeInteger(record.byteLength) && record.byteLength > 0 && record.byteLength <= 1073741824 &&
    typeof record.sha256 === 'string' && /^[a-f0-9]{64}$/.test(record.sha256);
}
function copy(value) { return JSON.parse(JSON.stringify(value)); }
export function planFileParts(byteLength) {
  if (!Number.isSafeInteger(byteLength) || byteLength < 1 || byteLength > 1073741824) throw new Error('invalid file size');
  const result = [];
  for (let offset=0; offset<byteLength; offset+=3000000) result.push({index:result.length,offset:offset,length:Math.min(3000000,byteLength-offset)});
  return result;
}
export class TransferQueue {
  constructor(snapshot) {
    this.records=[]; this.activeToken=null; this.sequence=0;
    if (!snapshot) return;
    if (snapshot.version!==1 || !Array.isArray(snapshot.records) || !Number.isSafeInteger(snapshot.sequence) || snapshot.sequence<0) throw new Error('invalid queue snapshot');
    this.sequence=snapshot.sequence;
    snapshot.records.forEach(record=>{
      if (!valid(record) || !['queued','sending','awaitingAck','uploaded'].includes(record.state) ||
          !Number.isSafeInteger(record.attempt) || record.attempt<0 || (record.state!=='queued' && record.attempt===0) || this.records.some(r=>r.id===record.id)) throw new Error('invalid queue record');
      const restored=copy(record);
      if (restored.state!=='uploaded') restored.state='queued';
      this.records.push(restored);
    });
  }
  add(record) {
    if (!valid(record)) throw new Error('invalid recording');
    const existing=this.records.find(r=>r.id===record.id);
    if (existing) {
      if (existing.sha256!==record.sha256 || existing.byteLength!==record.byteLength) throw new Error('conflicting recording');
      return;
    }
    this.records.push({id:record.id,byteLength:record.byteLength,sha256:record.sha256,state:'queued',attempt:0});
  }
  startNext() {
    if (this.activeToken) return null;
    const record=this.records.find(r=>r.state==='queued');
    if (!record) return null;
    record.state='sending'; record.attempt++;
    this.sequence++;
    this.activeToken=record.id+':'+this.sequence;
    return {id:record.id,token:this.activeToken,parts:planFileParts(record.byteLength)};
  }
  active(token) {
    return token===this.activeToken ? this.records.find(r=>token.indexOf(r.id+':')===0) : null;
  }
  transportFinished(token) {
    const record=this.active(token); if(!record) return false;
    this.activeToken=null;
    if(record.state==='uploaded') return false;
    record.state='awaitingAck'; return true;
  }
  transportFailed(token) {
    const record=this.active(token); if(!record) return false;
    this.activeToken=null;
    if(record.state==='uploaded') return false;
    record.state='queued'; return true;
  }
  retryUnacknowledged() {
    this.records.forEach(record=>{if(record.state==='awaitingAck') record.state='queued';});
  }
  acknowledge(ack) {
    if (!valid(ack) || ack.version!==1 || ack.type!=='stored') return false;
    const record=this.records.find(r=>r.id===ack.id);
    if (!record || !record.attempt || record.byteLength!==ack.byteLength || record.sha256!==ack.sha256) return false;
    record.state='uploaded'; return true;
  }
  remove(id) {
    const record=this.records.find(r=>r.id===id);
    if(record && this.activeToken && this.activeToken.indexOf(record.id+':')===0) throw new Error('recording is in flight');
    this.records=this.records.filter(r=>r.id!==id);
  }
  snapshot() { return copy({version:1,sequence:this.sequence,activeToken:this.activeToken,records:this.records}); }
}
