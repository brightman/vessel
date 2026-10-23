/* Run: node --test apps/wrist-notes/prototype/tests/record-management.test.cjs */
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const script = path.join(__dirname, '../daybook-record-management.js');
const context = {window: {}, structuredClone};
if (fs.existsSync(script)) vm.runInNewContext(fs.readFileSync(script, 'utf8'), context);
function setup() {
  assert.equal(typeof context.window.createDaybookRecordManagementModel, 'function', 'Range management model must be implemented');
  const records = [
    {id:'a', kind:'voice', day:19, start:14, end:14.5, time:'14:00', duration:1800, title:'讨论', text:'第一部分。第二部分。', summary:'旧总结', preview:'旧总结', tags:[], segment:{batchID:'session', start:0, end:1800}, textSpans:[{start:0,end:900,text:'第一部分。'},{start:900,end:1800,text:'第二部分。'}]},
    {id:'b', kind:'voice', day:19, start:14.5, end:15, time:'14:30', duration:1800, title:'行动', text:'安排后续。', summary:'旧总结', tags:[], segment:{batchID:'session',start:1800,end:3600},textSpans:[{start:1800,end:3600,text:'安排后续。'}]},
    {id:'unrelated', kind:'thought', title:'保留我的编辑', text:'无关记录'}
  ];
  const sessions = [{id:'session', startHours:14, duration:3600, day:19}];
  return {records, model:context.window.createDaybookRecordManagementModel(records,sessions)};
}
test('split preview is non-mutating; commit retains exact coverage and scoped text', () => {
  const {records, model} = setup();
  const before = JSON.stringify(records);
  const plan = model.previewSplit('a', 900);
  assert.equal(JSON.stringify(records), before, 'canceling a preview must leave all records intact');
  model.commit(plan);
  const first = records.find(r=>r.id==='a');
  const second = records.find(r=>r.segment?.start===900);
  assert.equal(first.duration, 900);
  assert.equal(first.text, '第一部分。');
  assert.equal(second.duration, 900);
  assert.equal(second.segment.end, 1800);
  assert.equal(second.text, '第二部分。');
  assert.equal(first.summary, '');
  assert.equal(second.summary, '');
});
test('merge produces a single content range and undo preserves unrelated edits', () => {
  const {records, model} = setup();
  model.commit(model.previewMerge('a','b'));
  const result=records.find(r=>r.id==='a');
  assert.equal(result.duration,3600);
  assert.equal(records.some(r=>r.id==='b'),false);
  assert.equal(result.text,'第一部分。\n\n第二部分。\n\n安排后续。');
  records.find(r=>r.id==='unrelated').text='修改后保留';
  model.undo('session');
  assert.equal(records.find(r=>r.id==='a').duration,1800);
  assert.equal(records.find(r=>r.id==='b').title,'行动');
  assert.equal(records.find(r=>r.id==='unrelated').text,'修改后保留');
});
test('bounds reject overlap and out-of-file ranges; accepted changes invalidate summary', () => {
  const {records,model}=setup();
  assert.throws(()=>model.previewBounds('a',0,1860),/重叠/);
  assert.throws(()=>model.previewBounds('a',-60,1200),/范围/);
  assert.throws(()=>model.previewSplit('a',0),/范围/);
  assert.throws(()=>model.previewSplit('a',NaN),/范围/);
  model.commit(model.previewBounds('a',60,1500));
  assert.equal(records.find(r=>r.id==='a').duration,1440);
  assert.equal(records.find(r=>r.id==='a').time,'14:01');
  assert.equal(records.find(r=>r.id==='a').summary,'');
});
test('stale previews and undo cannot overwrite a later record edit', () => {
  const {records,model}=setup();
  const plan=model.previewSplit('a',900);
  records[0].title='之后编辑的标题';
  assert.throws(()=>model.commit(plan),/已变化/);
  model.commit(model.previewSplit('a',900));
  records.find(r=>r.id==='a').text='之后编辑的全文';
  assert.equal(model.canUndo('session'),false);
  assert.throws(()=>model.undo('session'),/已变化/);
});
test('expanding a trimmed range restores the source text within that range', () => {
  const {records,model}=setup();
  model.commit(model.previewBounds('a',900,1800));
  assert.equal(records.find(r=>r.id==='a').text,'第二部分。');
  model.commit(model.previewBounds('a',0,1800));
  assert.equal(records.find(r=>r.id==='a').text,'第一部分。\n\n第二部分。');
});
test('merge refuses missing, non-adjacent, cross-session, or overlapping records', () => {
  const {records,model}=setup();
  assert.throws(()=>model.previewMerge('a','missing'));
  records.push({...structuredClone(records[1]),id:'c',segment:{batchID:'elsewhere',start:3600,end:4200}});
  assert.throws(()=>model.previewMerge('a','c'),/相邻/);
  records[1].segment.start=1700;
  assert.throws(()=>model.previewMerge('a','b'),/相邻/);
});
