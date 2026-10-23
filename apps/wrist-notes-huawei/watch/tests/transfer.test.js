import test from 'node:test';
import assert from 'node:assert/strict';
let TransferQueue, planFileParts;
try { ({ TransferQueue, planFileParts } = await import('../core/transfer.js')); } catch (error) { if(error.code !== 'ERR_MODULE_NOT_FOUND') throw error; }
const first = { id:'11111111-1111-4111-8111-111111111111', byteLength:5, sha256:'a'.repeat(64) };
const second = { id:'22222222-2222-4222-8222-222222222222', byteLength:9, sha256:'b'.repeat(64) };
const ack = r => ({version:1,type:'stored',...r});
function queue(snapshot) { assert.equal(typeof TransferQueue,'function','transfer queue must exist'); return new TransferQueue(snapshot); }
test('sends at most one recording and transport completion does not mean uploaded',()=>{
 const q=queue(); q.add(first); q.add(second); const attempt=q.startNext(); assert.equal(attempt.id,first.id); assert.equal(q.startNext(),null);
 q.transportFinished(attempt.token); assert.equal(q.snapshot().records[0].state,'awaitingAck'); assert.equal(q.startNext().id,second.id);
});
test('validated durable acknowledgement marks uploaded, duplicates harmless',()=>{
 const q=queue(); q.add(first); const a=q.startNext(); q.transportFinished(a.token);
 assert.equal(q.acknowledge({...ack(first),sha256:'c'.repeat(64)}),false);
 assert.equal(q.acknowledge(ack(first)),true); assert.equal(q.acknowledge(ack(first)),true); assert.equal(q.snapshot().records[0].state,'uploaded'); assert.equal(q.startNext(),null);
});
test('late send callbacks cannot corrupt a retry or a valid acknowledgement',()=>{
 const q=queue(); q.add(first); const a=q.startNext(); q.transportFailed(a.token); const b=q.startNext();
 assert.notEqual(a.token,b.token); assert.equal(q.transportFinished(a.token),false); assert.equal(q.snapshot().activeToken,b.token);
 q.acknowledge(ack(first)); assert.equal(q.transportFailed(b.token),false); assert.equal(q.snapshot().records[0].state,'uploaded');
});
test('restart retries interrupted transfers and preserves uploaded recordings',()=>{
 const q=queue(); q.add(first); q.add(second); const a=q.startNext(); q.acknowledge(ack(first)); q.transportFinished(a.token); q.startNext();
 const restored=queue(JSON.parse(JSON.stringify(q.snapshot()))); assert.equal(restored.startNext().id,second.id); assert.equal(restored.snapshot().records[0].state,'uploaded');
});
test('unknown or never sent acknowledgements cannot mark uploaded; in-flight delete blocked',()=>{
 const q=queue(); q.add(first); assert.equal(q.acknowledge(ack(first)),false); assert.equal(q.acknowledge(ack(second)),false);
 const a=q.startNext(); assert.throws(()=>q.remove(first.id),/in flight/); q.transportFailed(a.token); q.remove(first.id); assert.deepEqual(q.snapshot().records,[]);
});
test('conflicting duplicate recordings and corrupted snapshots rejected',()=>{
 const q=queue(); q.add(first); q.add(first); assert.equal(q.snapshot().records.length,1);
 assert.throws(()=>q.add({...first,byteLength:6}),/conflict/);
 assert.throws(()=>queue({version:1,records:[{...first,state:'uploaded',attempt:0}]}),/invalid/);
});
test('long files split below transport limit without gaps; empty files rejected',()=>{
 assert.equal(typeof planFileParts,'function');
 assert.deepEqual(planFileParts(6500000),[{index:0,offset:0,length:3000000},{index:1,offset:3000000,length:3000000},{index:2,offset:6000000,length:500000}]);
 assert.throws(()=>planFileParts(0)); assert.throws(()=>planFileParts(Infinity)); assert.throws(()=>planFileParts(-1));
});
test('early app acknowledgement must not allow overlapping SDK file sends',()=>{
 const q=queue(); q.add(first); q.add(second); const a=q.startNext();
 q.acknowledge(ack(first)); assert.equal(q.startNext(),null);
 q.transportFinished(a.token); assert.equal(q.snapshot().records[0].state,'uploaded'); assert.equal(q.startNext().id,second.id);
});
