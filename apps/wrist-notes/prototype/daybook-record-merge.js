/* Prototype-only long-recording selection and merge rules. No audio files are read or changed. */
window.createDaybookRecordMerge = function() {
  'use strict';

  const isEligible = record => record?.kind === 'voice' && Number(record.duration) > 0 && !record.lifeMoment;

  function selectionIndices(records, selectedIds) {
    const indexes = selectedIds.map(id => records.findIndex(record => record.id === id));
    return indexes.every(index => index >= 0) ? indexes.sort((a, b) => a - b) : [];
  }

  function canMerge(records, selectedIds) {
    if (selectedIds.length < 2) return false;
    const indexes = selectionIndices(records, selectedIds);
    if (indexes.length !== selectedIds.length) return false;
    if (indexes.some((index, offset) => !isEligible(records[index]) || (offset > 0 && index !== indexes[offset - 1] + 1))) return false;
    return new Set(selectedIds.map(id => records.find(record => record.id === id).day)).size === 1;
  }

  function toggleSelection(records, selectedIds, id) {
    if (selectedIds.includes(id)) return { ok: true, selectedIds: selectedIds.filter(selectedId => selectedId !== id) };
    const candidate = records.find(record => record.id === id);
    if (!isEligible(candidate)) return { ok: false, reason: 'long-recording' };
    const nextIds = [...selectedIds, id];
    if (selectedIds.length && !canMerge(records, nextIds)) return { ok: false, reason: 'adjacent' };
    return { ok: true, selectedIds: nextIds };
  }

  function merge(records, selectedIds, generatedRecord) {
    if (!canMerge(records, selectedIds)) throw new Error('Only adjacent long recordings can be merged.');
    const selected = records.filter(record => selectedIds.includes(record.id)).sort((a, b) => a.start - b.start);
    const first = selected[0];
    const duration = selected.reduce((total, record) => total + record.duration, 0);
    const record = {
      ...generatedRecord,
      kind: 'voice',
      day: first.day,
      start: first.start,
      end: first.start + duration / 3600,
      time: first.time,
      duration,
    };
    const removed = new Set(selectedIds);
    const nextRecords = records.filter(item => !removed.has(item.id)).concat(record).sort((a, b) => b.start - a.start);
    return { record, records: nextRecords, sourceIds: selected.map(item => item.id) };
  }

  return { isEligible, canMerge, toggleSelection, merge };
};

window.daybookRecordMergeCopy = [
  ['合并录音 · 原型演示', 'Merge recordings · prototype demo', '録音を結合 · プロトタイプ'],
  ['条长录音已选', 'long recordings selected', '件の長時間録音を選択'],
  ['选择', 'Select', '選択'],
  ['已选中', 'Selected', '選択済み'],
  ['合并所选', 'Merge selected', '選択項目を結合'],
  ['删除记录', 'Delete record', '記録を削除'],
  ['删除这条记录？', 'Delete this record?', 'この記録を削除しますか？'],
  ['将', 'Merge', '次の録音'],
  ['条相邻长录音按顺序拼接为一条。', ' adjacent long recordings in order.', '件の隣接する長時間録音を順に結合します。'],
  ['将从当前原型示例中移除。', 'will be removed from this prototype sample.', 'はこのプロトタイプのサンプルから削除されます。'],
  ['仅影响原型演示', 'Prototype only', 'プロトタイプのみ'],
  ['不会删除 iPhone 上的录音或任何真实数据。', 'No iPhone recordings or real data will be deleted.', 'iPhoneの録音や実データは削除されません。'],
  ['模拟完整处理流程', 'Simulated processing', '処理フローのシミュレーション'],
  ['这里会演示拼接音频，并重新生成全文、摘要和标题；不会读取或拼接真实音频，也不会调用 AI。完成后会移除上面的原型条目。', 'This demo simulates joining audio and regenerating the transcript, summary and title. It does not read or join real audio or call AI. The sample rows are removed when it finishes.', '音声の結合と全文・要約・タイトルの再生成をシミュレーションします。実際の音声を読み込んだり結合したり、AIを呼び出したりはしません。完了後、上のサンプル項目を削除します。'],
  ['开始模拟合并', 'Start demo merge', '結合をシミュレーション'],
  ['正在模拟合并录音…', 'Simulating recording merge…', '録音の結合をシミュレーション中…'],
  ['拼接音频片段', 'Joining audio clips', '音声クリップを結合'],
  ['重新生成全文、摘要与标题', 'Regenerating transcript, summary and title', '全文・要約・タイトルを再生成'],
  ['原型演示 · 不处理真实音频', 'Prototype demo · no real audio processed', 'プロトタイプ · 実際の音声は処理しません'],
  ['模拟合并完成：音频、全文、摘要与标题已更新。', 'Demo merge complete: audio, transcript, summary and title updated.', 'デモ結合完了：音声、全文、要約、タイトルを更新しました。'],
  ['已从原型示例中删除。', 'Removed from the prototype sample.', 'プロトタイプのサンプルから削除しました。'],
  ['请在今天的“全部”列表中选择相邻长录音。', 'Select adjacent long recordings in today’s All list.', '今日の「すべて」から隣接する長時間録音を選択してください。'],
  ['只能选择长录音。', 'Only long recordings can be selected.', '長時間録音のみ選択できます。'],
  ['只能选择时间线上相邻的长录音。', 'Only adjacent long recordings can be selected.', '時間軸で隣接する長時間録音のみ選択できます。'],
  ['右划选择仅适用于长录音。', 'Swipe right to select long recordings only.', '右スワイプで選択できるのは長時間録音のみです。'],
  ['请选择至少两条相邻的长录音。', 'Select at least two adjacent long recordings.', '隣接する長時間録音を2件以上選択してください。'],
  ['所选条目已变化，请重新选择相邻长录音。', 'The selected items changed. Select adjacent recordings again.', '選択項目が変わりました。隣接する録音をもう一度選択してください。'],
];
