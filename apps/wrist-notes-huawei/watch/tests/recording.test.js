import test from 'node:test';
import assert from 'node:assert/strict';
let RecordingInteraction;
try { ({ RecordingInteraction } = await import('../core/recording.js')); } catch (error) { if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error; }
function interaction() { assert.equal(typeof RecordingInteraction, 'function', 'recording state machine must exist'); return new RecordingInteraction(); }
test('tap starts then a short press stops long recording', () => {
  const p=interaction(); p.begin(0,false); assert.equal(p.end(100),'startLong');
  p.begin(2000,true); assert.equal(p.end(2100),'stopLong');
});
test('holding during a long recording does not accidentally stop it', () => {
  const p=interaction(); p.begin(0,true); assert.equal(p.hold(500),null); assert.equal(p.end(800),null);
});
test('hold triggers once and release only saves a thought', () => {
  const p=interaction(); p.begin(0,false); assert.equal(p.hold(300),null); assert.equal(p.hold(450),'startThought');
  assert.equal(p.hold(600),null); assert.equal(p.end(900),'saveThought'); assert.equal(p.end(920),null);
});
test('short thought discarded and upward swipe cancels', () => {
  const p=interaction(); p.begin(0,false); p.hold(450); assert.equal(p.end(600),'discardShortThought');
  p.begin(1000,false); p.hold(1450); p.move(0,-40); assert.equal(p.end(2000),'cancelThought');
});
test('scrolling outside a press never starts recording; interrupted thought cancels', () => {
  const p=interaction(); p.move(0,-80); assert.equal(p.end(100),null);
  p.begin(1000,false); p.move(30,0); assert.equal(p.hold(1600),null); assert.equal(p.end(1700),null);
  p.begin(2000,false); p.hold(2450); assert.equal(p.interrupt(),'cancelThought'); assert.equal(p.end(2800),null);
});
