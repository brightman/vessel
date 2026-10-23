import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { fileURLToPath } from 'node:url';

const sourcePath = fileURLToPath(new URL('../../prototype/daybook-record-merge.js', import.meta.url));
const pageScriptPath = fileURLToPath(new URL('../../prototype/daybook.js', import.meta.url));
const pagePath = fileURLToPath(new URL('../../prototype/iphone-day.html', import.meta.url));
assert.ok(existsSync(sourcePath), 'prototype merge policy must exist before interaction wiring');
const context = { window: {} };
runInNewContext(readFileSync(sourcePath, 'utf8'), context);
const mergePolicy = context.window.createDaybookRecordMerge();
const pageScript = readFileSync(pageScriptPath, 'utf8');
const page = readFileSync(pagePath, 'utf8');
assert.ok(page.indexOf('daybook-record-merge.js') < page.indexOf('daybook.js'), 'merge policy loads before the daybook UI');
assert.match(pageScript, /addEventListener\('pointerdown'/, 'today list handles swipe gestures');
assert.match(pageScript, /data-swipe-action="delete"/, 'left swipe exposes delete action');
assert.match(pageScript, /data-swipe-action="select"/, 'right swipe exposes selection action');
assert.match(pageScript, /重新生成全文、摘要与标题/, 'merge flow describes regenerated outputs');

const rows = [
  { id: 'part-b', kind: 'voice', day: 19, start: 16.4, end: 16.57, time: '16:24', duration: 600 },
  { id: 'part-a', kind: 'voice', day: 19, start: 16.3, end: 16.5, time: '16:18', duration: 720 },
  { id: 'thought', kind: 'thought', day: 19, start: 16.2, duration: 45 },
  { id: 'other-long', kind: 'voice', day: 19, start: 15.9, duration: 900 },
  { id: 'short-voice', kind: 'voice', day: 19, start: 15.8, duration: 120 },
];

assert.equal(mergePolicy.isEligible(rows[0]), true, 'long voice recording can be merged');
assert.equal(mergePolicy.isEligible(rows[2]), false, 'short thought recording cannot be merged');
assert.equal(mergePolicy.isEligible(rows[4]), true, 'recording category, not an arbitrary duration threshold, defines eligibility');
assert.equal(mergePolicy.toggleSelection(rows, [], 'part-a').ok, true);
assert.equal(mergePolicy.toggleSelection(rows, ['part-a'], 'part-b').ok, true, 'adjacent long recordings can be selected');
assert.equal(mergePolicy.toggleSelection(rows, ['part-a'], 'other-long').ok, false, 'non-adjacent recording is rejected');
assert.equal(mergePolicy.toggleSelection(rows, [], 'short-voice').ok, true);
assert.equal(mergePolicy.canMerge(rows, ['part-a']), false, 'one recording is insufficient');
assert.equal(mergePolicy.canMerge(rows, ['part-a', 'part-b']), true);

const result = mergePolicy.merge(rows, ['part-b', 'part-a'], {
  id: 'merged-demo', title: '合并录音：用户访谈', preview: '模拟重生成的预览。',
  summary: '模拟重生成的摘要。', text: '模拟重生成的全文。', tags: ['演示'], source: 'Apple Watch · 原型演示',
});
assert.equal(result.record.start, 16.3);
assert.equal(result.record.time, '16:18');
assert.equal(result.record.duration, 1320);
assert.equal(result.record.end, 16.3 + 1320 / 3600);
assert.equal(result.records.some(row => row.id === 'part-a' || row.id === 'part-b'), false, 'source items are removed');
assert.equal(result.records.some(row => row.id === 'merged-demo'), true);

console.log('PASS long-recording eligibility, adjacency, minimum selection, duration and source replacement');
