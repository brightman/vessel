/* Fictional record management. All changes stay in page memory; no audio or AI requests. */
(() => {
  'use strict';
  const copy = value => JSON.parse(JSON.stringify(value));
  const clock = seconds => {
    const n = Math.round(seconds);
    return `${String(Math.floor(n / 3600) % 24).padStart(2, '0')}:${String(Math.floor(n / 60) % 60).padStart(2, '0')}${n % 60 ? ':' + String(n % 60).padStart(2, '0') : ''}`;
  };
  const duration = seconds => `${Math.floor(seconds / 60)} 分${seconds % 60 ? ` ${seconds % 60} 秒` : ''}`;
  const spansFor = record => {
    if (record.textSpans) return record.textSpans;
    const lines = (record.text || '').split(/\n+|(?<=[。！？])/u).map(t => t.trim()).filter(Boolean);
    const {start, end} = record.segment;
    return lines.map((text, i) => ({text, start: start + (end - start) * i / lines.length, end: start + (end - start) * (i + 1) / lines.length}));
  };

  window.seedDaybookRecordManagement = records => {
    const sessions = [
      {id:'watch-pm', day:19, startHours:14, duration:2400, source:'Apple Watch', title:'下午的产品讨论'},
      {id:'watch-am', day:19, startHours:9 + 40 / 60, duration:2520, source:'Apple Watch', title:'上午的项目碰头'}
    ];
    for (const [id, batchID, end] of [['review','watch-pm',1560],['meeting','watch-am',2520]]) {
      const r = records.find(r => r.id === id);
      if (r) { r.segment = {batchID, start:0, end}; r.textSpans = spansFor(r); }
    }
    const review = records.find(r => r.id === 'review');
    if (review && !records.some(r => r.id === 'review-followup')) {
      const r = {...copy(review), id:'review-followup', start:14 + 26 / 60, end:14 + 40 / 60, time:'14:26', duration:840,
        title:'上线前，再走一遍真实流程', preview:'用真实录音验证保存、同步和回听，周五一起复盘。',
        summary:'上线前，用一段真实录音验证保存、同步和片段回听。\n把发现的问题记下来，周五一起复盘。',
        text:'上线前，我们再用真实录音走一遍保存、同步和回听。\n\n把遇到的问题记下来，周五一起看，先修影响记录可靠性的问题。',
        tags:['验证流程'], segment:{batchID:'watch-pm', start:1560, end:2400}};
      delete r.textSpans;
      r.textSpans = spansFor(r);
      records.push(r);
    }
    // A second detail state for reviewing the inline summary action.
    const thought = records.find(r => r.id === 'thought-noon');
    if (thought) thought.summary = '';
    return sessions;
  };

  window.createDaybookRecordManagementModel = (records, sessions) => {
    let serial = 0;
    const history = new Map();
    const find = id => {
      const r = records.find(r => r.id === id);
      if (!r?.segment) throw new Error('找不到可调整的内容片段。');
      return r;
    };
    const batch = id => records.filter(r => r.segment?.batchID === id).sort((a,b) => a.segment.start - b.segment.start);
    const fingerprint = id => JSON.stringify(batch(id));
    const sessionFor = r => sessions.find(s => s.id === r.segment.batchID);
    const range = (r, start, end, title = r.title) => {
      const session = sessionFor(r);
      if (!session || !Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end > session.duration || end - start < 30) throw new Error('请选择有效范围，每段至少保留 30 秒。');
      const sourceSpans = r.sourceSpans || spansFor(r);
      const spans = sourceSpans.filter(s => s.start < end && s.end > start).map(s => ({...s, start:Math.max(s.start,start), end:Math.min(s.end,end)}));
      return {...copy(r), title, segment:{...r.segment,start,end}, start:session.startHours + start / 3600, end:session.startHours + end / 3600,
        time:clock(session.startHours * 3600 + start), duration:end-start, sourceSpans:copy(sourceSpans), textSpans:spans, text:spans.map(s => s.text).join('\n\n'),
        summary:'', summaryState:'changed', preview:'片段已调整，待生成总结。', transcriptAdjusted:true};
    };
    const plan = (type, before, after) => ({type, before:copy(before), after, batchID:before[0].segment.batchID, basis:fingerprint(before[0].segment.batchID)});
    function previewSplit(id, point) {
      const r = find(id), {start,end} = r.segment;
      if (!Number.isFinite(point) || point - start < 30 || end - point < 30) throw new Error('请选择片段内部的范围，每段至少保留 30 秒。');
      return plan('split',[r],[range(r,start,point,`${r.title} · 1`), {...range(r,point,end,`${r.title} · 2`),id:`segment-demo-${++serial}`}]);
    }
    function neighbors(id) {
      const r = find(id), list = batch(r.segment.batchID), i = list.findIndex(x => x.id === id);
      return [list[i-1],list[i+1]].filter(other => other && (other.segment.end === r.segment.start || other.segment.start === r.segment.end));
    }
    function previewMerge(id, otherID) {
      const r = find(id), other = neighbors(id).find(r => r.id === otherID);
      if (!other) throw new Error('只能合并同次录制中时间连续的相邻片段。');
      const ordered = [r,other].sort((a,b) => a.segment.start-b.segment.start);
      const combined = {...copy(r), sourceSpans:ordered.flatMap(spansFor)};
      return plan('merge',ordered,[range(combined,ordered[0].segment.start,ordered[1].segment.end,ordered[0].title)]);
    }
    function previewBounds(id, start, end) {
      const r = find(id), next = range(r,start,end);
      if (batch(r.segment.batchID).some(o => o.id !== id && o.segment.start < end && o.segment.end > start)) throw new Error('范围与相邻片段重叠，请先合并或缩短边界。');
      return plan('bounds',[r],[next]);
    }
    function replace(before, after) {
      const removed = new Set(before.map(r => r.id));
      for (let i=records.length-1;i>=0;i--) if (removed.has(records[i].id)) records.splice(i,1);
      records.push(...copy(after));
    }
    function commit(change) {
      if (!change || fingerprint(change.batchID) !== change.basis) throw new Error('片段已变化，请重新预览。');
      replace(change.before,change.after);
      history.set(change.batchID,{...copy(change), result:fingerprint(change.batchID)});
      return change;
    }
    const canUndo = batchID => history.has(batchID) && history.get(batchID).result === fingerprint(batchID);
    function undo(batchID) {
      if (!canUndo(batchID)) throw new Error('片段已变化，无法撤销之前的调整。');
      const change = history.get(batchID);
      replace(change.after,change.before); history.delete(batchID);
      return {before:change.after,after:change.before};
    }
    return {previewSplit,previewMerge,previewBounds,neighbors,commit,undo,canUndo,sessionFor};
  };

  window.createDaybookRecordManagement = app => {
    const {$,esc,icon,toast,openSheet,openRecord,getRecords,sessions,refresh,removeRecord} = app;
    const model = window.createDaybookRecordManagementModel(getRecords(),sessions);
    const pending = new Map();
    let currentID = null, adjustment = null, plan = null;
    const get = id => getRecords().find(r => r.id === id);
    const eligible = r => r && ['voice','thought','image'].includes(r.kind) && !r.lifeMoment;
    const audio = r => ['voice','thought'].includes(r.kind);
    const more = $('recordMoreButton'), menu = $('recordManagementMenu');
    const action = (name,label,id,extra='') => `<button type="button" data-rm-action="${name}" data-rm-id="${esc(id || '')}" ${extra}>${label}</button>`;
    const back = id => action('back',`${icon('ChevronLeft')}<span>返回记录</span>`,id,'class="rm-back"');
    const note = '<p class="source-footnote">原型演示：修改仅保留在本页，刷新后恢复。</p>';
    const rangeLabel = r => `${clock(r.start*3600)}–${clock(r.end*3600)}`;
    function closeMenu(focus=false) { menu.hidden=true; more.setAttribute('aria-expanded','false'); if(focus)more.focus(); }
    function setRecord(record) {
      closeMenu(); currentID=eligible(record)?record.id:null; more.hidden=!currentID;
      if (!currentID) return;
      const busy=pending.has(record.id), summaryLabel=busy?'正在生成总结…':record.summary?'重新生成总结':'生成总结';
      const items=[['edit','编辑记录','NotebookPen'],['summary',summaryLabel,'Lightbulb'],...(record.segment?[['adjust','调整片段','Settings2']]:[]),...(audio(record)?[['status','查看处理状态','Activity']]:[]),['delete',record.segment?'删除此片段':record.kind==='image'?'删除图片记录':'删除录音','X']];
      menu.innerHTML=items.map(([name,label,glyph])=>action(name,`${icon(glyph)}<span>${label}</span>`,record.id,`role="menuitem" tabindex="-1" ${name==='summary'&&busy?'disabled':''} class="${name==='delete'?'rm-destructive':''}"`)).join('');
    }
    function toggleMenu() {
      if (!currentID) return;
      if (!menu.hidden) { closeMenu(true); return; }
      setRecord(get(currentID));menu.hidden=false;more.setAttribute('aria-expanded','true');menu.querySelector('button:not(:disabled)')?.focus();
    }
    function summaryMarkup(r) {
      if(pending.has(r.id))return '<div class="rm-empty-summary" role="status"><span class="rm-processing-dot"></span><strong>正在生成总结…</strong><p>仅整理当前记录的示例文字。</p></div>';
      if(r.summary)return `${esc(r.summary)}${r.summaryDemo?'<p class="source-footnote">总结演示 · 根据本条文字整理，未调用 AI。</p>':''}`;
      return `<div class="rm-empty-summary"><strong>${r.summaryState==='changed'?'内容已更新':'还没有总结'}</strong><p>为当前记录整理重点，方便下次回看。</p>${action('summary',`${icon('Lightbulb')}生成总结`,r.id,'class="secondary-button"')}</div>`;
    }
    const segmentInfo = r => r.segment?`<div class="rm-segment-context"><span>内容片段</span><span>${rangeLabel(r)}</span><small>仅播放此片段 · 可跨多个录音文件</small></div>`:'';
    function openEdit(r) {
      openSheet('编辑记录',`${back(r.id)}<form id="rmEditForm" data-rm-id="${esc(r.id)}"><label class="note-field"><span>标题</span><input id="rmTitle" maxlength="80" required value="${esc(r.title)}"></label><label class="note-field"><span>${r.kind==='image'?'补充说明':'全文'}</span><textarea id="rmText" rows="8" maxlength="12000">${esc(r.kind==='image'?r.caption||'':r.text||'')}</textarea></label><p class="source-footnote">只修改当前记录。文字更改后，可重新生成总结。</p>${note}<div class="sheet-actions">${action('back','取消',r.id,'class="secondary-button"')}<button type="submit" class="primary-button">保存修改</button></div></form>`);
    }
    function generate(r) {
      if (pending.has(r.id)) return;
      const source=r.kind==='image'?[r.caption,r.ocr].filter(Boolean).join('\n'):r.text;
      if(!source?.trim()){toast('还没有可总结的文字，请先补充内容。');return;}
      const before=JSON.stringify(r);
      pending.set(r.id,setTimeout(()=>{
        pending.delete(r.id);
        if(get(r.id)!==r||JSON.stringify(r)!==before)return;
        const sentences=source.split(/\n+|(?<=[。！？])/u).map(s=>s.trim()).filter(Boolean);
        r.summary=sentences.slice(0,3).map(s=>s.length>100?s.slice(0,100)+'…':s).join('\n');
        r.summaryDemo=true;r.summaryState='ready';r.preview=r.summary.replace(/\n/g,' ').slice(0,90);
        refresh();
        if(currentID===r.id&&$('sheet').open)openRecord(r.id);
      },900));
      openRecord(r.id);
    }
    const previewCard = r => `<div class="rm-preview-card"><span>${rangeLabel(r)}<strong>${duration(r.duration)}</strong></span><p>${esc(r.title)}</p></div>`;
    function openAdjust(r,mode='split') {
      if(!r.segment)return;
      adjustment={id:r.id,mode};plan=null;
      const neighbors=model.neighbors(r.id),session=model.sessionFor(r),undo=model.canUndo(r.segment.batchID);
      const fields=mode==='split'?`<label class="note-field"><span>在本段第几分钟拆分</span><input id="rmSplitMinute" type="number" min="0.5" max="${r.duration/60-.5}" step="0.5" value="${Math.floor(r.duration/60)/2}"></label>`:
        mode==='merge'?`<label class="note-field"><span>选择相邻片段</span><select id="rmMergeTarget">${neighbors.length?neighbors.map(n=>`<option value="${esc(n.id)}">${rangeLabel(n)} · ${esc(n.title)}</option>`).join(''):'<option value="">没有连续的相邻片段</option>'}</select></label>`:
        `<div class="rm-bound-fields"><label class="note-field"><span>开始时间</span><input type="time" id="rmRangeStart" step="1" value="${clock(r.start*3600)}"></label><label class="note-field"><span>结束时间</span><input type="time" id="rmRangeEnd" step="1" value="${clock(r.end*3600)}"></label></div><p class="source-footnote">可用录音 ${clock(session.startHours*3600)}–${clock(session.startHours*3600+session.duration)}，范围不能与其他片段重叠。</p>`;
      openSheet('调整片段',`${back(r.id)}${previewCard(r)}<div class="rm-adjust-tabs" role="group" aria-label="调整方式">${[['split','拆分'],['merge','合并相邻'],['bounds','调整边界']].map(([modeID,label])=>action('mode',label,r.id,`data-rm-mode="${modeID}" aria-pressed="${modeID===mode}"`)).join('')}</div><div id="rmAdjustFields">${fields}</div><h3 class="sheet-section-title">调整后预览</h3><div id="rmAdjustmentPreview" aria-live="polite"></div><p class="source-footnote">确认后更新当前片段的全文，总结需重新生成。原始音频保留。</p><div class="sheet-actions">${action('back','取消',r.id,'class="secondary-button"')}${action('commit','确认调整',r.id,'id="rmConfirmAdjustment" class="primary-button"')}</div>${action('undo',`${icon('RotateCcw')}撤销上次调整`,r.id,`class="rm-undo" ${undo?'':'disabled'}`)}${note}`);
      updatePreview();
    }
    function updatePreview() {
      if(!$('rmAdjustmentPreview')||!adjustment)return;
      const r=get(adjustment.id);if(!r)return;
      try {
        if(adjustment.mode==='split')plan=model.previewSplit(r.id,r.segment.start+Number($('rmSplitMinute').value)*60);
        else if(adjustment.mode==='merge')plan=model.previewMerge(r.id,$('rmMergeTarget').value);
        else {
          const offset=id=>{const parts=$(id).value.split(':').map(Number);return parts[0]*3600+parts[1]*60+(parts[2]||0)-model.sessionFor(r).startHours*3600;};
          plan=model.previewBounds(r.id,offset('rmRangeStart'),offset('rmRangeEnd'));
        }
        $('rmAdjustmentPreview').innerHTML=plan.after.map(previewCard).join('');$('rmConfirmAdjustment').disabled=false;
      } catch(error) { plan=null;$('rmAdjustmentPreview').innerHTML=`<p class="rm-validation">${esc(error.message)}</p>`;$('rmConfirmAdjustment').disabled=true; }
    }
    function openStatus(r) {
      const stages=[['录音已保存',r.segment?'本段所需的原始录音文件已在本机保存。':'音频与这条记录关联保存。'],['转写已完成','当前记录的全文可查看和编辑。'],...(r.segment?[['内容分段已完成',`当前范围 ${rangeLabel(r)}，${duration(r.duration)}。`]]:[]),[r.summary?'总结已就绪':pending.has(r.id)?'总结生成中':'总结待生成',r.summary?'可以手动重新生成。':'可从详情页生成本条总结。']];
      openSheet('处理状态',`${back(r.id)}<p class="rm-status-title">${esc(r.title)}</p><ol class="rm-status-list">${stages.map(([title,text],i)=>`<li>${icon(i===stages.length-1&&!r.summary?'Clock3':'Check')}<div><strong>${title}</strong><p>${esc(text)}</p></div></li>`).join('')}</ol><p class="source-footnote">示例处理状态；原型未处理真实音频。</p>`);
    }
    function confirmDelete(r) {
      const label=r.segment?'删除此片段':r.kind==='image'?'删除图片记录':'删除录音';
      openSheet(`${label}？`,`${back(r.id)}<p class="sheet-intro">${esc(r.title)}</p><div class="rm-delete-note">${r.segment?'此片段将从时间轴移除。原始录音文件仍保留，其他片段不受影响。':r.kind==='image'?'移除这条图片记录；系统相册中的照片不受影响。':'移除此录音记录及其全文、总结。'}</div>${note}<div class="sheet-actions">${action('back','取消',r.id,'class="secondary-button"')}${action('confirm-delete',label,r.id,'class="danger-button"')}</div>`);
    }
    function openRaw(batchID) {
      const session=sessions.find(s=>s.id===batchID);
      if(!session){
        openSheet('原始录音',`<p class="sheet-intro">按录制批次保留原始文件，用于片段回听和重新整理。</p><div class="rm-source-batches">${sessions.map(s=>action('raw',`${icon('Watch')}<span><strong>10月${s.day}日 ${clock(s.startHours*3600)}</strong><small>${esc(s.title)} · ${duration(s.duration)}</small><small>${Math.ceil(s.duration/600)} 个文件 · 已保存到 iPhone</small></span>${icon('ChevronRight')}`,s.id,'class="rm-batch"')).join('')}</div><p class="source-footnote">原型展示 Apple Watch 的两次录制示例。</p>`);return;
      }
      const segments=getRecords().filter(r=>r.segment?.batchID===batchID).sort((a,b)=>a.start-b.start);
      const files=Array.from({length:Math.ceil(session.duration/600)},(_,i)=>({start:i*600,end:Math.min(session.duration,(i+1)*600),name:`watch_202610${session.day}_${clock(session.startHours*3600).replace(':','')}_${i}.m4a`}));
      openSheet('录制批次',`${action('raw',`${icon('ChevronLeft')}返回原始录音`,'','class="rm-back"')}<div class="rm-batch-heading"><span>${esc(session.source)} · 10月${session.day}日</span><h3>${clock(session.startHours*3600)}–${clock(session.startHours*3600+session.duration)}</h3><p>${files.length} 个文件 · ${duration(session.duration)} · 已保存到 iPhone</p></div><h3 class="sheet-section-title">原始文件</h3><div class="rm-file-list">${files.map(f=>`<div><span>${clock(session.startHours*3600+f.start)}–${clock(session.startHours*3600+f.end)}<b>${duration(f.end-f.start)}</b></span><small>${f.name}</small><em>${icon('Check')}已保存 · 已转写</em></div>`).join('')}</div><p class="source-footnote">每 10 分钟保存一个文件，结束时保留末尾短片。内容片段可以跨文件回听。</p><h3 class="sheet-section-title">关联内容片段</h3>${segments.length?segments.map(r=>action('back',`<span>${esc(r.title)}<small>${rangeLabel(r)} · ${duration(r.duration)}</small></span>${icon('ChevronRight')}`,r.id,'class="rm-related"')).join(''):'<p class="sheet-intro">时间轴中已无关联片段，原始文件仍保留。</p>'}`);
    }
    function preview(kind) {
      $('product').scrollIntoView({block:'start'});
      if(kind==='raw-recordings'){openRaw();return;}
      openRecord(kind==='record-image'?'board-photo':kind==='record-voice'?'merge-first':kind==='record-thought'?'thought-noon':'review');
    }
    document.addEventListener('click',event=>{
      const b=event.target.closest('button');
      if(!event.target.closest('.rm-menu-wrap'))closeMenu();
      if(!b)return;
      if(b.id==='recordMoreButton'){toggleMenu();return;}
      if(b.dataset.rmPreview){preview(b.dataset.rmPreview);return;}
      const name=b.dataset.rmAction;if(!name)return;
      const r=get(b.dataset.rmId);
      closeMenu();
      if(name==='raw'){openRaw(b.dataset.rmId);return;}
      if(!r){toast('这条记录已移除。');return;}
      try {
        if(name==='back')openRecord(r.id);
        if(name==='edit')openEdit(r);
        if(name==='summary')generate(r);
        if(name==='adjust'||name==='mode')openAdjust(r,b.dataset.rmMode||'split');
        if(name==='status')openStatus(r);
        if(name==='delete')confirmDelete(r);
        if(name==='confirm-delete'){clearTimeout(pending.get(r.id));pending.delete(r.id);removeRecord(r.id);}
        if(name==='commit'&&plan){const change=model.commit(plan);refresh(change);openRecord(change.after[0].id);}
        if(name==='undo'){const change=model.undo(r.segment.batchID);refresh(change);openRecord(change.after[0].id);}
      } catch(error) {toast(error.message);}
    });
    document.addEventListener('submit',event=>{
      if(event.target.id!=='rmEditForm')return;event.preventDefault();
      const r=get(event.target.dataset.rmId),title=$('rmTitle').value.trim(),text=$('rmText').value.trim();
      if(!r||!title){$('rmTitle').focus();return;}
      const changed=text!==(r.kind==='image'?r.caption||'':r.text||'');
      r.title=title;
      if(changed){
        if(r.kind==='image'){r.caption=text;r.text=[text,r.ocr].filter(Boolean).join('\n\n');}else r.text=text;
        if(r.segment){delete r.textSpans;delete r.sourceSpans;r.textSpans=spansFor(r);r.transcriptAdjusted=true;}
        r.summary='';r.summaryState='changed';r.preview=text.slice(0,90)||'内容已更新，待生成总结。';
      }
      clearTimeout(pending.get(r.id));pending.delete(r.id);
      refresh();openRecord(r.id);
    });
    document.addEventListener('input',event=>{if(event.target.closest('#rmAdjustFields'))updatePreview();});
    document.addEventListener('change',event=>{if(event.target.closest('#rmAdjustFields'))updatePreview();});
    $('sheet').addEventListener('keydown',event=>{
      if(menu.hidden)return;
      const buttons=[...menu.querySelectorAll('button:not(:disabled)')],index=buttons.indexOf(document.activeElement);
      if(event.key==='Escape'){event.preventDefault();event.stopPropagation();closeMenu(true);}
      else if(['ArrowDown','ArrowUp','Home','End'].includes(event.key)){
        event.preventDefault();buttons[event.key==='Home'?0:event.key==='End'?buttons.length-1:(index+(event.key==='ArrowDown'?1:-1)+buttons.length)%buttons.length]?.focus();
      } else if(event.key==='Tab')closeMenu();
    },true);
    $('sheet').addEventListener('cancel',event=>{if(!menu.hidden){event.preventDefault();closeMenu(true);}});
    $('sheet').addEventListener('close',()=>{setRecord(null);adjustment=null;plan=null;});
    window.addEventListener('pagehide',()=>{pending.forEach(clearTimeout);pending.clear();});
    return {setRecord,summaryMarkup,segmentInfo,openRaw,preview,confirmDelete};
  };

  window.daybookRecordManagementCopy = [
    ['管理记录','Manage record','記録を管理'],['编辑记录','Edit record','記録を編集'],['生成总结','Generate summary','要約を作成'],['重新生成总结','Regenerate summary','要約を再作成'],
    ['调整片段','Adjust segment','区間を調整'],['查看处理状态','View processing status','処理状況を確認'],['删除此片段','Delete segment','この区間を削除'],['删除录音','Delete recording','録音を削除'],['删除图片记录','Delete photo record','写真記録を削除'],
    ['返回记录','Back to record','記録に戻る'],['保存修改','Save changes','変更を保存'],['内容片段','Content segment','内容の区間'],['还没有总结','No summary yet','要約はまだありません'],['内容已更新','Content updated','内容を更新しました'],
    ['正在生成总结…','Generating summary…','要約を作成中…'],['为当前记录整理重点，方便下次回看。','Summarize this record for your next review.','この記録の要点を整理して振り返りやすくします。'],
    ['仅播放此片段 · 可跨多个录音文件','Play this segment only · across source files','この区間のみ再生 · 複数の録音ファイルに対応'],
    ['数据管理','Data management','データ管理'],['原始录音','Source recordings','元の録音'],['按录制批次查看原始文件','View original files by session','録音セッション別に元ファイルを確認'],
    ['拆分','Split','分割'],['合并相邻','Merge adjacent','隣接区間を結合'],['调整边界','Adjust boundaries','境界を調整'],['调整后预览','Preview changes','変更をプレビュー'],['确认调整','Apply changes','変更を適用'],['撤销上次调整','Undo last adjustment','前の調整を元に戻す'],
    ['开始时间','Start time','開始時刻'],['结束时间','End time','終了時刻'],['在本段第几分钟拆分','Split at minute within this segment','この区間の分割位置（分）'],['选择相邻片段','Choose adjacent segment','隣接する区間を選択'],
    ['原始文件','Source files','元のファイル'],['关联内容片段','Related segments','関連する区間'],['录制批次','Recording session','録音セッション'],['返回原始录音','Back to source recordings','元の録音に戻る'],
    ['原型演示：修改仅保留在本页，刷新后恢复。','Prototype: edits stay on this page and reset on refresh.','プロトタイプ：変更はこのページ内のみで、再読み込みで戻ります。'],
    ['详情页 · 管理入口','Record details · management','記録の詳細 · 管理'],['查看内容片段','Review a segment','内容の区間を確認'],['普通语音','Voice record','音声記録'],['闪念 · 无总结','Thought · no summary','ひらめき · 要約なし'],['图片记录','Photo record','写真記録']
  ];
})();
