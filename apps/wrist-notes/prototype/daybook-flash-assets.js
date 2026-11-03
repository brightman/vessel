/* Design-only fixtures. Edits live in memory; no model, storage or system APIs. */
(() => {
  'use strict';
  const ACTION_TODAY = '2026-10-19';
  const kinds = {
    idea:{label:'想法',icon:'Lightbulb'}, expense:{label:'记账',icon:'NotebookPen'}
  };
  const actionKinds = {todo:{label:'待办',icon:'CheckCheck'},reminder:{label:'提醒',icon:'Bell'},event:{label:'日程',icon:'CalendarDays'}};
  window.createDaybookFlashAssets = ({$,esc,icon,toast,openSheet,closeSheet,showView,openRecord,getRecord,refreshRecords,showTimeline,openNotebook}) => {
    const assets = [
      {id:'idea-people',kind:'idea',title:'让每次讨论，都能接着上次继续',content:'给 WiseLife 增加「按人回顾」，把与同一个人讨论过的内容串起来。',capture:'flash-mixed',quote:'记个想法，给 WiseLife 做一个按人回顾，把和同一个人讨论过的内容串起来。',offset:'00:00–00:16',status:'ready'},
      {id:'expense-taxi',kind:'expense',title:'打车去见林茜',content:'打车去见林茜，支出三十八元人民币。',capture:'flash-mixed',quote:'再记一笔，今天打车去见林茜花了三十八元人民币。',offset:'00:16–00:27',amount:'38.00',currency:'CNY',date:'2026-10-19',direction:'expense',category:'交通',status:'ready'},
      {id:'idea-interview',kind:'idea',title:'先听经历，再问观点',content:'访谈时，先请对方讲最近一次真实经历，再追问当时的选择。',capture:'flash-method',quote:'记一个访谈的想法：先让对方讲最近一次真实经历，再追问当时为什么这么选。',offset:'00:00–00:18',status:'ready'},
      {id:'expense-lunch',kind:'expense',title:'今天的午餐',content:'今天午餐支出三十五元人民币。',capture:'flash-expense',quote:'记一笔，今天午餐花了三十五元人民币。',offset:'00:00–00:09',amount:'35.00',currency:'CNY',date:'2026-10-19',direction:'expense',category:'餐饮',status:'ready'},
      {id:'expense-missing',kind:'expense',title:'买咖啡',content:'记录今天买咖啡的支出，原话未说明金额和币种。',capture:'flash-incomplete',quote:'记一笔今天买咖啡的钱，金额等下补。',offset:'00:00–00:10',amount:'',currency:'',date:'2026-10-19',direction:'expense',category:'餐饮',status:'review'}
    ];
    const actions = [
      {id:'sketch',kind:'todo',title:'画出按人回顾的草图',capture:'flash-mixed',asset:'idea-people',quote:'帮我加个待办，画出按人回顾的草图。',start:'',end:'',status:'active',automatic:true},
      {id:'call-lin',kind:'reminder',title:'给林茜打电话',capture:'flash-mixed',quote:'明天上午九点提醒我给林茜打电话。',start:'2026-10-20T09:00',end:'',status:'active',automatic:true},
      {id:'discussion',kind:'event',title:'和林茜讨论按人回顾',capture:'flash-mixed',asset:'idea-people',quote:'再加一个日程，明天下午三点到三点半和林茜讨论这个功能。',start:'2026-10-20T15:00',end:'2026-10-20T15:30',status:'active',automatic:true},
      {id:'design-review',kind:'event',title:'和设计师过一遍首页',capture:'flash-event',quote:'帮我加一个日程，明天下午两点到两点半和设计师过一遍首页。',start:'2026-10-20T14:00',end:'2026-10-20T14:30',status:'active',automatic:true},
      {id:'missing-time',kind:'reminder',title:'给林茜发草图',capture:'flash-incomplete',quote:'提醒我给林茜发草图，时间还没想好。',start:'',end:'',status:'needsInput',automatic:true},
      {id:'failed-notification',kind:'reminder',title:'带上采访提纲',capture:'flash-failed',quote:'明天早上八点提醒我带上采访提纲。',start:'2026-10-20T08:00',end:'',status:'failed',automatic:true,failure:'通知未获授权，尚未安排提醒。内容已保留。'},
      {id:'todo-overdue',kind:'todo',title:'整理昨天的访谈纪要',capture:'review',quote:'周五把这周的反馈集中看一下。',start:'2026-10-18T18:00',status:'active'},
      {id:'todo-today',kind:'todo',title:'列出首版流程的三件事',capture:'review',quote:'下一步：列清首版范围，再讨论扩展数据源。',start:'2026-10-19T20:00',status:'active'},
      {id:'reminder-today',kind:'reminder',title:'回看用户访谈原文',capture:'review',quote:'每条洞察都要有依据，点进去能看到原始录音或文字。',start:'2026-10-19T18:00',status:'active'},
      {id:'event-tomorrow',kind:'event',title:'首版流程复盘',capture:'review',quote:'第一版不必做所有数据源，先把这个过程跑通。',start:'2026-10-20T15:00',end:'2026-10-20T15:30',status:'active'},
      {id:'reminder-yesterday',kind:'reminder',title:'昨天回看访谈记录',capture:'review',quote:'昨天的提醒示例。',start:'2026-10-18T09:00',status:'active'},
      {id:'event-older',kind:'event',title:'上周的流程讨论',capture:'review',quote:'更早的日程示例。',start:'2026-10-17T15:00',end:'2026-10-17T15:30',status:'active'}
    ];
    const recordingSuggestions = {
      review: [
        {id:'scope',kind:'todo',title:'跑通录音、转写到回看原文的首版流程',evidence:'第一版不必做所有数据源，先把这个过程跑通。',constraint:'从全文中的首版范围讨论提炼'},
        {id:'evidence',kind:'reminder',title:'回看洞察是否能找到对应原文',evidence:'每条洞察都要有依据，点进去能看到原始录音或文字。',constraint:'提醒时间由你选择'},
        {id:'review-session',kind:'event',title:'安排一次首版流程复盘',evidence:'第一版不必做所有数据源，先把这个过程跑通。',constraint:'建议安排 30 分钟；时间由你选择'}
      ]
    };
    let type='idea',reviewOnly=false,insightTab='assets',actionFilter='all',sequence=0;
    const captureModes=new Map();
    const find = id => assets.find(a=>a.id===id);
    const shown = capture => assets.filter(a=>a.capture===capture&&a.status!=='ignored');
    const sourceName = a => getRecord(a.capture)?.title||'原始闪念';
    const flow = step => `<ol class="fa-flow" translate="no" aria-label="Capture → Insight → Action">${['Capture','Insight','Action'].map((s,i)=>`<li class="${i===step?'current':''}" ${i===step?'aria-current="step"':''}><span>${String(i+1).padStart(2,'0')}</span>${s}</li>`).join('')}</ol>`;
    const statusLabel = a => a.status==='ignored'?'已撤销':a.status==='review'?'待补充':a.kind==='expense'?'已记账':'已保存';
    const sourceButton = a => `<button class="fa-source" data-fa-source="${a.capture}">${icon('AudioLines')}<span translate="no">${esc(sourceName(a))}</span>${icon('ArrowUpRight')}</button>`;
    const money = a => `${a.currency||'币种待补'} ${a.amount||'金额待补'}`;
    function seed(records) {
      const mixed=assets.filter(a=>a.capture==='flash-mixed').map(a=>a.quote).concat(actions.filter(a=>a.capture==='flash-mixed').map(a=>a.quote));
      const specs=[
        ['flash-mixed','一个想法，一笔支出，三件事',78,'Apple Watch',mixed.join('\n\n'),'1 个想法 · 支出 ¥38.00 · 3 项行动已创建'],
        ['flash-event','随手安排明天的讨论',12,'iPhone',actions.find(a=>a.id==='design-review').quote,'日程已创建 · 明天和设计师讨论首页'],
        ['flash-method','访谈时，先听真实经历',18,'iPhone',assets.find(a=>a.id==='idea-interview').quote,'想法已保存 · 先听经历，再问观点'],
        ['flash-expense','今天的午餐',9,'Apple Watch',assets.find(a=>a.id==='expense-lunch').quote,'支出 ¥35.00 · 餐饮 · 已记账'],
        ['flash-incomplete','有两项内容，稍后补充',24,'iPhone',assets.find(a=>a.id==='expense-missing').quote+'\n\n'+actions.find(a=>a.id==='missing-time').quote,'咖啡金额、币种与提醒时间待补充'],
        ['flash-failed','明早带上采访提纲',10,'Apple Watch',actions.find(a=>a.id==='failed-notification').quote,'已保留提醒 · 通知权限待开启']
      ];
      const times={'flash-mixed':'15:42','flash-event':'15:18','flash-failed':'14:50','flash-incomplete':'13:30','flash-method':'12:55','flash-expense':'12:20'};
      for(const [id,title,duration,source,text,preview] of specs){
        const time=times[id],start=Number(time.slice(0,2))+Number(time.slice(3))/60;
        records.push({id,day:19,kind:'thought',start,end:start+duration/3600,time,duration,title,preview,source,text,summary:'',tags:['闪念'],captureTimezone:'Asia/Shanghai'});
      }
      assets.forEach(a=>{const r=getRecord(a.capture);if(r)a.recordedAt=`2026-10-${String(r.day).padStart(2,'0')}T${r.time}:00+08:00`;});
    }
    function card(a) {
      if(a.kind==='idea'){
        const recorded=a.recordedAt||'',label=recorded?`${Number(recorded.slice(5,7))}月${Number(recorded.slice(8,10))}日 ${recorded.slice(11,16)}`:'时间未记录';
        return `<button class="fa-idea-row" data-fa-asset="${a.id}"><span class="fa-idea-text" translate="no">${esc(a.content)}</span><time datetime="${esc(recorded)}" translate="no">${label}</time>${a.status==='ignored'?'<span class="fa-idea-revoked">已撤销</span>':''}</button>`;
      }
      return `<button class="fa-card" data-fa-asset="${a.id}"><span class="fa-card-top"><span class="fa-kind" data-kind="${a.kind}">${icon(kinds[a.kind].icon)}${kinds[a.kind].label}</span><span class="fa-status ${a.status==='review'?'review':''}">${statusLabel(a)}</span></span><strong translate="no">${esc(a.title)}</strong>${a.kind==='expense'?`<span class="fa-money" translate="no">${a.direction==='income'?'+':'−'} ${esc(money(a))}</span>`:`<span class="fa-excerpt" translate="no">${esc(a.content)}</span>`}<span class="fa-card-bottom">${icon('AudioLines')}<span translate="no">${esc(sourceName(a))}</span>${icon('ChevronRight')}</span></button>`;
    }
    function render() {
      if(!$('flashAssetPanel'))return;
      const active=assets.filter(a=>a.status!=='ignored'),pending=active.filter(a=>a.status==='review');
      $('flashAssetPanel').hidden=insightTab!=='assets';$('lifeInsightPanel').hidden=insightTab!=='life';
      document.querySelectorAll('[data-fa-insight-tab]').forEach(b=>{b.setAttribute('aria-selected',String(b.dataset.faInsightTab===insightTab));b.tabIndex=b.dataset.faInsightTab===insightTab?0:-1;});
      const selected=active.filter(a=>a.kind===type),visible=selected.filter(a=>!reviewOnly||a.status==='review').sort((a,b)=>(b.recordedAt||'').localeCompare(a.recordedAt||''));
      $('flashAssetPanel').innerHTML=`<div class="fa-notebook-tabs" role="tablist" aria-label="记事本分类">${[['idea','我的想法'],['expense','我的记账']].map(([key,label])=>`<button role="tab" data-fa-filter="${key}" aria-selected="${type===key}" tabindex="${type===key?0:-1}">${label}</button>`).join('')}</div><div class="fa-notebook-meta"><span>${selected.length} ${type==='idea'?'条想法':'笔账目'} · 全部日期</span>${type==='expense'?`<button data-fa-review="toggle" aria-pressed="${reviewOnly}">${reviewOnly?'查看全部':`待补充 · ${pending.filter(a=>a.kind==='expense').length}`}</button>`:''}</div><div class="fa-notebook-content" role="tabpanel" aria-label="${type==='idea'?'我的想法':'我的记账'}">${type==='expense'?expenseTotal():''}<div class="${type==='idea'?'fa-idea-list':'fa-cards'}">${visible.map(card).join('')||`<p class="fa-empty">${reviewOnly?'没有待补充的账目。':type==='idea'?'还没有想法。下次想到时，说下来就好。':'还没有记账记录。'}</p>`}</div></div><div class="fa-library-footer"><span>示例内容 · 修改仅在本页保留</span>${assets.some(a=>a.status==='ignored')?'<button class="text-button" data-fa-ignored="open">查看已撤销</button>':''}</div>`;
      if($('faLibraryContent'))$('faLibraryContent').innerHTML=$('flashAssetPanel').innerHTML;
      renderActions();refreshRecords?.();
    }
    function expenseTotal() {
      const totals={};assets.filter(a=>a.kind==='expense'&&a.status==='ready').forEach(a=>{const group=totals[a.currency] ||= {income:0,expense:0};group[a.direction||'expense']+=Math.round(Number(a.amount)*100);});
      return `<div class="fa-total"><span>已记录收支 · 全部日期</span>${Object.entries(totals).map(([c,v])=>`<strong translate="no">${c} · 支出 ${(v.expense/100).toFixed(2)}</strong><small translate="no">收入 ${(v.income/100).toFixed(2)}</small>`).join('')||'<strong>—</strong>'}<small>待补充及已撤销的账目不计入；币种分别汇总</small></div>`;
    }
    function entry() {return '';}
    function badge(r) {
      const rows=shown(r.id),related=actions.filter(a=>a.capture===r.id&&a.automatic),labels=[];
      const ideas=rows.filter(a=>a.kind==='idea'&&a.status==='ready').length,expenses=rows.filter(a=>a.kind==='expense'&&a.status==='ready').length;
      if(ideas)labels.push(`${ideas} 个想法`);if(expenses)labels.push(`${expenses} 笔账目`);
      if(related.some(a=>a.status==='active'))labels.push(`${related.filter(a=>a.status==='active').length} 项行动`);
      if(rows.some(a=>a.status==='review')||related.some(a=>['needsInput','failed'].includes(a.status)))labels.push('待补充 / 处理');
      return labels.length?`<span class="fa-timeline-badge">${labels.join(' · ')}</span>`:'';
    }
    function timelineDate(value) {
      const [date,time]=value.split('T'),parts=date.split('-');
      return `${parts[0]!==ACTION_TODAY.slice(0,4)?parts[0]+'年':''}${Number(parts[1])}月${Number(parts[2])}日${time?' '+time:''}`;
    }
    function timelineAction(a) {
      const kind=actionKinds[a.kind],warning=['needsInput','failed'].includes(a.status);
      const time=a.start?`${a.kind==='todo'?'截止 ':''}${timelineDate(a.start)}${a.end?`–${a.end.slice(0,10)===a.start.slice(0,10)?a.end.slice(11):timelineDate(a.end)}`:''}`:a.kind==='todo'?'未设截止时间':'补充时间后安排';
      const hint=a.status==='failed'?'通知权限未开启，提醒尚未安排':a.status==='needsInput'?'尚未安排':a.status==='active'&&a.kind==='todo'?'待完成':'';
      return `<button class="fa-timeline-result ${warning?'needs-attention':''} ${a.status==='cancelled'?'is-revoked':''}" data-fa-action="${esc(a.id)}"><span class="fa-timeline-symbol">${icon(kind.icon)}</span><span class="fa-timeline-copy"><span class="fa-timeline-type">${kind.label}<span class="fa-timeline-status">${autoStatus(a)}</span></span><strong translate="no">${esc(a.title)}</strong><span class="fa-timeline-schedule" translate="no">${esc(time)}</span>${hint?`<span class="fa-timeline-hint">${hint}</span>`:''}</span>${icon('ChevronRight')}</button>`;
    }
    function timelineAsset(a) {
      const expense=a.kind==='expense',revoked=a.status==='ignored';
      const title=expense?`${a.title}${a.amount&&a.currency?` · ${a.direction==='income'?'+':'−'} ${money(a)}`:''}`:a.content;
      return `<button class="fa-timeline-result ${a.status==='review'?'needs-attention':''} ${revoked?'is-revoked':''}" data-fa-asset="${esc(a.id)}"><span class="fa-timeline-symbol">${icon(kinds[a.kind].icon)}</span><span class="fa-timeline-copy"><span class="fa-timeline-type">${kinds[a.kind].label}<span class="fa-timeline-status">${statusLabel(a)}</span></span><strong class="${expense?'':'fa-timeline-idea'}" translate="no">${esc(title)}</strong>${expense?`<span class="fa-timeline-schedule">${a.status==='review'?'金额、币种待补充 · 未计入账目':esc(`${a.category} · ${timelineDate(a.date)}`)}</span>`:''}</span>${icon('ChevronRight')}</button>`;
    }
    function timelineMarkup(r) {
      if(r.kind!=='thought'||(captureModes.get(r.id)||'ready')!=='ready')return '';
      const related=actions.filter(a=>a.capture===r.id&&a.automatic),rows=assets.filter(a=>a.capture===r.id);
      if(!related.length&&!rows.length)return '';
      const duration=`${Math.floor(r.duration/60)}:${String(r.duration%60).padStart(2,'0')}`;
      return `<article class="moment fa-timeline-group" data-kind="thought" data-flash-group="${esc(r.id)}" aria-label="${r.time} 录下的闪念整理结果"><div class="moment-time"><time>${r.time}</time><span>录下</span></div><div class="moment-main"><div class="fa-timeline-results">${related.map(timelineAction).join('')}${rows.map(timelineAsset).join('')}</div><button class="fa-timeline-source" data-fa-capture="${esc(r.id)}" aria-label="查看 ${r.time} 的原话与录音"><span>${icon('AudioLines')}<span translate="no">${esc(r.source==='Apple Watch'?'Watch':r.source)} · ${duration}</span></span><span>原话与录音 ${icon('ChevronRight')}</span></button></div></article>`;
    }
    function searchText(r) {
      return [...assets.filter(a=>a.capture===r.id).map(a=>`${a.title} ${a.content} ${a.currency||''} ${a.amount||''}`),...actions.filter(a=>a.capture===r.id&&a.automatic).map(a=>`${actionKinds[a.kind].label} ${a.title} ${a.start||''} ${autoStatus(a)}`)].join(' ');
    }
    function openCapture(id,mode='ready') {
      if(!getRecord(id))return;
      captureModes.set(id,mode);openRecord(id);
    }
    const autoStatus=a=>({active:a.kind==='reminder'?'已安排':'已创建',needsInput:'待补充时间',failed:'未安排',cancelled:'已撤销',done:'已完成'}[a.status]||'处理中');
    const assetButtons=a=>`<button data-fa-edit="${a.id}">${a.status==='review'?'补充信息':'编辑'}</button><button data-fa-source="${a.capture}">原话</button><button data-fa-result-undo="${a.id}">撤销</button>`;
    function resultAsset(a) {
      const expense=a.kind==='expense';
      return `<article class="fa-result-card" data-result-id="${a.id}" data-kind="${a.kind}"><div class="fa-result-top"><span class="fa-kind">${icon(kinds[a.kind].icon)}${kinds[a.kind].label}</span><span class="fa-result-status ${a.status==='review'?'pending':''}">${icon(a.status==='review'?'CircleHelp':'Check')}${statusLabel(a)}</span></div><h3 translate="no">${esc(a.title)}</h3>${expense?`<div class="fa-result-amount" translate="no">${a.amount?`${a.direction==='income'?'+':'−'} ${esc(a.amount)} <small>${esc(a.currency)}</small>`:'金额待补充'}</div><div class="fa-result-tags"><span>${a.direction==='income'?'收入':'支出'}</span><span>${esc(a.category||'未分类')}</span><span translate="no">${esc(a.date)}</span></div>${a.status==='review'?'<p class="fa-result-hint">金额和币种补齐后自动记账，目前不计入汇总。</p>':''}`:`<p translate="no">${esc(a.content)}</p>`}<div class="fa-result-controls">${assetButtons(a)}</div></article>`;
    }
    function resultAction(a) {
      const warning=['needsInput','failed'].includes(a.status),cancelled=a.status==='cancelled';
      return `<article class="fa-result-card fa-result-action ${cancelled?'is-cancelled':''}" data-result-id="${a.id}"><div class="fa-result-top"><span class="fa-kind">${icon(actionKinds[a.kind].icon)}${actionKinds[a.kind].label}</span><span class="fa-result-status ${warning?'pending':''}">${icon(warning?'CircleHelp':cancelled?'RotateCcw':'Check')}${autoStatus(a)}</span></div><h3 translate="no">${esc(a.title)}</h3><p class="fa-result-time" translate="no">${a.start?formatDate(a.start):a.kind==='todo'?'未设截止时间':'尚未指定提醒时间'}${a.end?' — '+a.end.split('T')[1]:''}</p>${a.status==='failed'?`<p class="fa-result-hint">${esc(a.failure)}</p>`:a.status==='needsInput'?'<p class="fa-result-hint">已记住要做的事，补上时间后即可安排。</p>':''}<div class="fa-result-controls">${cancelled?'<span>已停止此项行动，不会再次自动创建</span>':`<button data-fa-auto-edit="${a.id}">${a.status==='needsInput'?'补充时间':'编辑'}</button><button data-fa-source="${a.capture}">原话</button><button data-fa-auto-undo="${a.id}">撤销</button>${a.status==='failed'?`<button data-fa-auto-retry="${a.id}">处理权限</button>`:''}`}</div></article>`;
    }
    function resultMarkup(r) {
      const mode=captureModes.get(r.id)||'ready',rows=shown(r.id),related=actions.filter(a=>a.capture===r.id&&a.automatic);
      if(mode!=='ready'||(!rows.length&&!related.length&&!assets.some(a=>a.capture===r.id&&a.status==='ignored'))){
        const copy={waiting:['正在整理','原音频已保存。想法、账目和明确指令会在这里分别呈现。'],unavailable:['已保存，稍后继续整理','模型暂不可用。原音频和全文都在，恢复后继续处理。'],empty:['这次，留住原话就好','没有需要单独保存的想法、账目或创建指令。']}[mode]||['这次，留住原话就好','没有需要单独整理的内容，可以切换到全文回看。'];
        return `<div class="fa-organized"><div class="fa-state">${icon(mode==='waiting'?'Clock3':'BookOpen')}<h3>${copy[0]}</h3><p>${copy[1]}</p></div></div>`;
      }
      const completed=rows.filter(a=>a.status==='ready').length+related.filter(a=>['active','done'].includes(a.status)).length;
      const pending=rows.filter(a=>a.status==='review').length+related.filter(a=>['needsInput','failed'].includes(a.status)).length;
      const removed=assets.filter(a=>a.capture===r.id&&a.status==='ignored');
      const description=pending?'内容已保留，补齐信息或处理权限后继续。':!completed?'整理项已撤销，原话仍保留。':related.length?'明确指令已处理，结果可以编辑或撤销。':rows.some(a=>a.kind==='expense')?'账目已留在 WiseLife，可随时核对和修改。':'想法已留在 WiseLife，随时可以补充。';
      return `<section class="fa-organized" aria-label="闪念整理结果"><div class="fa-organized-heading"><span class="fa-organized-icon">${icon(pending?'CircleHelp':'CheckCheck')}</span><div><strong>${pending?`${completed} 项已完成 · ${pending} 项待补充 / 处理`:`已整理 ${completed} 项`}</strong><p>${description}</p></div></div>${rows.map(resultAsset).join('')}${related.length?`<div class="fa-result-section"><h3>已识别的创建指令</h3><span>${related.length} 项</span></div>${related.map(resultAction).join('')}`:''}${removed.length?`<div class="fa-removed">${removed.map(a=>`<p><span>${esc(a.title)} · 已撤销</span><button data-fa-result-restore="${a.id}">恢复</button></p>`).join('')}</div>`:''}<div class="fa-result-footer">${icon('LockKeyhole')}原音频与全文保留，随时可回看</div><div class="fa-result-links"><button data-fa-library-kind="idea">查看我的想法 ${icon('ChevronRight')}</button><button data-fa-library-kind="expense">查看我的记账 ${icon('ChevronRight')}</button></div></section>`;
    }
    function autoActionEditor(id) {
      const a=actions.find(item=>item.id===id);if(!a||a.status==='cancelled')return;
      openSheet(a.status==='needsInput'?'补充时间':'编辑'+actionKinds[a.kind].label,`<form class="action-form" id="faAutoForm" data-action="${a.id}">${actionField('内容','title',a.title,'text',true,'maxlength="100"')}${actionField(a.kind==='todo'?'截止时间（选填）':a.kind==='event'?'开始时间':'提醒时间','start',a.start,'datetime-local',a.kind!=='todo')}${a.kind==='event'?actionField('结束时间','end',a.end,'datetime-local',true):''}<p class="action-form-help">时间使用录制时区 · Asia/Shanghai。补齐必要信息后直接生效。</p><p id="faFormError" class="action-form-error" role="alert" hidden></p><div class="sheet-actions"><button type="button" class="secondary-button" data-fa-capture="${a.capture}">取消</button><button class="primary-button" type="submit">${a.status==='needsInput'?'保存并安排':'保存修改'}</button></div></form>`);
    }
    function autoActionDetail(a) {
      openSheet(actionKinds[a.kind].label,`<div class="fa-organized">${resultAction(a)}</div><div class="fa-evidence"><span class="eyebrow">原话依据</span><blockquote translate="no">${esc(a.quote)}</blockquote>${sourceButton(a)}</div>${a.kind==='todo'&&['active','done'].includes(a.status)?`<button class="primary-button wide" data-fa-complete="${a.id}">${a.status==='done'?'恢复为未完成':'标记已完成'}</button>`:''}<button class="secondary-button wide" data-fa-capture="${a.capture}">查看全部整理结果</button>`);
    }
    function openAsset(id) {
      const a=find(id);if(!a)return;
      openSheet(kinds[a.kind].label,`<button class="rm-back" data-fa-library-kind="${a.kind}">${icon('ChevronLeft')}返回记事本</button><div class="fa-organized">${a.status==='ignored'?`<p class="fa-empty">这项内容已撤销，原话仍保留。</p><button class="secondary-button wide" data-fa-result-restore="${a.id}">恢复</button>`:resultAsset(a)}</div><div class="fa-evidence"><span class="eyebrow">原话依据 <span translate="no">${a.offset}</span></span><blockquote translate="no">“${esc(a.quote)}”</blockquote>${sourceButton(a)}</div>${a.kind==='idea'&&a.status!=='ignored'?`<button class="plain-row" data-fa-choose="${a.id}"><span>从这个想法创建行动</span>${icon('ArrowUpRight')}</button>`:''}<button class="secondary-button wide" data-fa-capture="${a.capture}">返回闪念整理</button>`);
    }
    function field(label,name,value,type='text',required=false,extra='') {
      return `<label class="fa-field"><span>${label}</span><input name="${name}" type="${type}" value="${esc(value||'')}" ${required?'required':''} ${extra}></label>`;
    }
    function actionField(label,name,value,type='text',required=false,extra='') {
      return `<label class="action-form-field"><span>${label}</span><input name="${name}" type="${type}" value="${esc(value||'')}" ${required?'required':''} ${extra}></label>`;
    }
    function editAsset(id) {
      const a=find(id);if(!a)return;
      openSheet(a.status==='review'?'补充账目':'编辑'+kinds[a.kind].label,`<form id="faAssetForm" data-asset="${id}">${field('标题','title',a.title,'text',true,'maxlength="80"')}<label class="fa-field"><span>内容</span><textarea name="content" rows="3" maxlength="1000" required>${esc(a.content)}</textarea></label>${a.kind==='expense'?`<div class="fa-field-pair"><label class="fa-field"><span>收支方向</span><select name="direction"><option value="expense" ${a.direction!=='income'?'selected':''}>支出</option><option value="income" ${a.direction==='income'?'selected':''}>收入</option></select></label>${field('类别','category',a.category,'text',true,'maxlength="20"')}</div><div class="fa-field-pair">${field('金额','amount',a.amount,'number',true,'min="0.01" max="999999999" step="0.01"')}<label class="fa-field"><span>币种</span><select name="currency" required><option value="">请选择</option>${['CNY','USD','SGD','JPY','EUR','HKD'].map(c=>`<option ${a.currency===c?'selected':''}>${c}</option>`).join('')}</select></label></div>${field('发生日期','date',a.date,'date',true)}<p class="fa-note">保存后计入对应币种的收支汇总，原始录音不变。</p>`:''}<p id="faFormError" class="fa-error" role="alert" hidden></p><div class="sheet-actions"><button type="button" class="secondary-button" data-fa-capture="${a.capture}">取消</button><button type="submit" class="primary-button">${a.status==='review'?'保存并记账':'保存修改'}</button></div></form>`);
    }
    function chooseAction(id) {
      const a=find(id);if(!a)return;
      openSheet('把想法往前推一步',`${flow(2)}<p class="sheet-intro" translate="no">来自：${esc(a.title)}</p>${Object.entries(actionKinds).map(([k,v])=>`<button class="capture-option action-kind-option" data-fa-new-action="${k}" data-asset="${id}">${icon(v.icon)}<div><strong>${v.label}</strong><p>${{todo:'先记下要做的事，时间可以稍后再定',reminder:'在指定时间提醒自己',event:'为这件事留出一段时间'}[k]}</p></div>${icon('ChevronRight')}</button>`).join('')}`);
    }
    function actionCard(a) {
      const kind=actionKinds[a.kind];
      if(a.automatic)return `<button class="fa-action-card" data-fa-action="${a.id}"><span class="fa-action-symbol">${icon(kind.icon)}</span><span class="fa-action-copy"><strong>${esc(a.title)}</strong><small>${a.start?esc(formatDate(a.start)):'未设时间'}</small><span class="fa-action-state">${kind.label} · ${autoStatus(a)} · 来自闪念指令</span></span>${icon('ChevronRight')}</button>`;
      return `<button class="fa-action-card" data-fa-action="${a.id}"><span class="fa-action-symbol ${a.status==='done'?'done':''}">${icon(a.status==='done'?'Check':kind.icon)}</span><span class="fa-action-copy"><strong translate="no">${esc(a.title)}</strong><small translate="no">${esc(a.status==='suggested'?(a.constraint||'等待你的确认'):a.start?formatDate(a.start):'未设时间')}</small><span class="fa-action-state">${kind.label} · ${{suggested:'待确认',active:'已加入',done:'已完成'}[a.status]}</span></span>${icon('ChevronRight')}</button>`;
    }
    function recordSuggestions(record) {
      const candidates=(recordingSuggestions[record.id]||[]).filter(item=>record.text?.includes(item.evidence));
      if(!candidates.length)return '';
      const kindLabels={todo:'待办',reminder:'提醒',event:'日程'};
      const kindIcons={todo:'CheckCheck',reminder:'Bell',event:'CalendarDays'};
      const rows=candidates.map(item=>{
        const actionID=`record-${record.id}-${item.id}`,existing=actions.find(action=>action.id===actionID);
        const button=existing?`<button type="button" class="record-suggestion-action is-added" data-fa-action="${esc(actionID)}">${existing.status==='suggested'?'继续编辑':'查看行动'}</button>`:`<button type="button" class="record-suggestion-action" data-record-suggestion-add="${esc(record.id)}" data-suggestion-id="${esc(item.id)}">添加</button>`;
        return `<article class="record-suggestion ${existing?'is-added':''}"><div class="record-suggestion-body"><span class="record-suggestion-type">${icon(kindIcons[item.kind])}${kindLabels[item.kind]}</span><strong>${esc(item.title)}</strong><small>${esc(item.constraint)}</small><span class="record-suggestion-evidence">来自全文：“${esc(item.evidence)}”</span></div>${button}</article>`;
      }).join('');
      return `<section class="record-suggestions" aria-labelledby="recordSuggestionsTitle"><div class="record-suggestions-heading"><div><h3 id="recordSuggestionsTitle">建议</h3><p>从这条记录的全文中提炼，是否采纳由你决定。</p></div><span>${icon('Lightbulb')}AI 建议</span></div><div class="record-suggestion-list">${rows}</div><p class="record-suggestions-note">添加时可以修改；确认后才加入“行动”，不会自动创建系统提醒或日历事件。</p></section>`;
    }
    function addRecordSuggestion(recordID,itemID) {
      const record=getRecord(recordID),item=recordingSuggestions[recordID]?.find(candidate=>candidate.id===itemID);
      if(!record||!item||!record.text?.includes(item.evidence)){toast('这条建议已不适用于当前全文。');return true;}
      const id=`record-${record.id}-${item.id}`;
      let action=actions.find(candidate=>candidate.id===id);
      if(!action){
        action={id,kind:item.kind,title:item.title,capture:record.id,quote:item.evidence,constraint:item.constraint,start:'',end:'',status:'suggested',recordSuggestion:true,recordSuggestionDraft:true};
        actions.push(action);
      }
      actionEditor(action);
      return true;
    }
    function formatDate(value) {return value.replace('2026-','').replace('T',' ');}
    function actionVisible(a) {
      if(!['reminder','event'].includes(a.kind)||a.status==='suggested')return true;
      const date=(a.start||'').slice(0,10);
      return !date||date>=ACTION_TODAY;
    }
    function swipeableAction(a) {
      const todo=a.kind==='todo';
      return `<div class="fa-action-swipe-row" data-fa-action-row="${esc(a.id)}" data-action-kind="${a.kind}" data-revealed="none"><div class="fa-action-swipe-actions" aria-label="${todo?'待办操作':'删除操作'}">${todo?`<button type="button" data-fa-swipe-complete="${esc(a.id)}">${icon(a.status==='done'?'RotateCcw':'Check')}<span>${a.status==='done'?'撤销':'完成'}</span></button>`:''}<button type="button" class="fa-action-swipe-delete" data-fa-swipe-delete="${esc(a.id)}">${icon('X')}<span>删除</span></button></div>${actionCard(a,true)}</div>`;
    }
    function renderActions() {
      if(!$('flashActions'))return;
      const visible=actions.filter(actionVisible).filter(a=>actionFilter==='all'||a.kind===actionFilter);
      const suggestions=visible.filter(a=>a.status==='suggested'),pending=visible.filter(a=>['needsInput','failed'].includes(a.status)),cancelled=visible.filter(a=>a.status==='cancelled'),accepted=visible.filter(a=>['active','done'].includes(a.status));
      $('flashActions').innerHTML=`${flow(2)}<div class="fa-heading"><span class="eyebrow">把理解，变成下一步</span><h2>从一件小事开始。</h2><p>明确指令已自动加入，一般建议等你决定。</p></div><p class="fa-action-list-note">待办会保留到完成或删除；提醒与日程仅显示今天及未来。</p><div class="fa-filter-row" role="group" aria-label="行动类型">${[['all','全部'],...Object.entries(actionKinds).map(([k,v])=>[k,v.label])].map(([k,v])=>`<button data-fa-action-filter="${k}" aria-pressed="${actionFilter===k}">${v}</button>`).join('')}</div><div class="fa-section-label"><h3>等你决定</h3><span>${suggestions.length} 项</span></div>${suggestions.map(actionCard).join('')||'<p class="fa-empty">暂时没有待确认建议。</p>'}${pending.length?`<div class="fa-section-label"><h3>待补充 / 处理</h3><span>${pending.length} 项</span></div>${pending.map(actionCard).join('')}`:''}${cancelled.length?`<div class="fa-section-label"><h3>已撤销</h3></div>${cancelled.map(actionCard).join('')}`:''}<div class="fa-section-label"><h3>已加入行动</h3><span>${accepted.length} 项</span></div>${accepted.map(swipeableAction).join('')||'<div class="fa-empty">不必一次安排好所有事情。<br>确认一项建议，就从这里继续。</div>'}<p class="fa-demo-note">左划查看操作 · 原型演示，不创建通知或写入系统</p>`;
    }
    function openAction(id) {
      const a=actions.find(t=>t.id===id);if(!a)return;
      if(a.automatic){autoActionDetail(a);return;}
      if(a.status==='suggested'){actionEditor(a);return;}
      openSheet(actionKinds[a.kind].label,`${flow(2)}<h3 class="fa-detail-title" translate="no">${esc(a.title)}</h3><p class="fa-detail-copy" translate="no">${a.start?esc(formatDate(a.start)):'未设时间'}${a.end?` — ${esc(formatDate(a.end))}`:''}</p><div class="fa-evidence"><span class="eyebrow">来自闪念</span><blockquote translate="no">“${esc(a.quote)}”</blockquote>${sourceButton(a)}</div>${a.asset?`<button class="plain-row" data-fa-asset="${a.asset}"><span>查看关联资产</span>${icon('ChevronRight')}</button>`:''}<div class="fa-note">${a.external?'已演示添加到 Apple '+(a.kind==='event'?'日历':'提醒事项')+'；未实际写入系统。':'仅加入原型行动列表，未创建系统通知。'}</div><button class="primary-button wide" data-fa-complete="${id}">${icon(a.status==='done'?'RotateCcw':'Check')}${a.status==='done'?'恢复为未完成':'标记已完成'}</button>`);
    }
    function actionEditor(a) {
      const v=actionKinds[a.kind];
      const schedule=a.kind==='event'
        ? `${actionField('开始时间','start',a.start,'datetime-local',true)}${actionField('结束时间','end',a.end,'datetime-local',true)}`
        : actionField(a.kind==='todo'?'截止时间（选填）':'提醒时间','start',a.start,'datetime-local',a.kind!=='todo');
      const scheduleNote=a.kind==='event'?'原话只确定了开始时间，请补充结束时间。':a.kind==='todo'?'可以先保存待办，不设截止时间，也不会自动提醒。':'选择明确的时间，确认后加入提醒。';
      const timezoneNote=a.capture==='flash-mixed'&&a.id==='discussion'?'“明天”按录制时的 10月19日解析 · 中国标准时间。':'';
      const externalTarget=a.kind==='event'?'日历':'提醒事项';
      const cancelButton=a.recordSuggestion?`<button class="secondary-button" type="button" data-fa-cancel-record-action="${a.id}">取消</button>`:`<button class="secondary-button" type="button" data-fa-capture="${a.capture}">取消</button>`;
      openSheet(`添加${v.label}`,`<form class="action-form" id="faActionForm" data-action="${a.id}">${actionField('要做什么','title',a.title,'text',true,'maxlength="100"')}<fieldset class="action-form-section"><legend>安排时间</legend><div class="action-form-grid${a.kind==='event'?' stack':''}">${schedule}</div><p class="action-form-help">${scheduleNote}${timezoneNote?`<span class="action-form-help-detail">${timezoneNote}</span>`:''}</p></fieldset><section class="action-form-source"><p>来源</p><blockquote translate="no">“${esc(a.quote)}”</blockquote>${sourceButton(a)}</section><label class="action-form-sync"><span><strong>同时添加到 Apple ${externalTarget}</strong><small>可选 · 默认关闭</small></span><span class="action-form-toggle"><input type="checkbox" name="external"><span aria-hidden="true"></span></span></label><p id="faFormError" class="action-form-error" role="alert" hidden></p><div class="sheet-actions">${cancelButton}<button class="primary-button" type="submit">确认加入${v.label}</button></div></form>`);
    }
    function error(message) {$('faFormError').hidden=false;$('faFormError').textContent=message;$('faFormError').scrollIntoView({block:'nearest'});}
    let actionSwipe=null,suppressActionTapUntil=0;
    const actionList=$('flashActions');
    actionList?.addEventListener('pointerdown',event=>{
      const row=event.target.closest('[data-fa-action-row]');
      if(!row||event.target.closest('[data-fa-swipe-complete],[data-fa-swipe-delete]')||(event.pointerType==='mouse'&&event.button!==0))return;
      actionSwipe={row,id:event.pointerId,x:event.clientX,y:event.clientY,moved:false};
    });
    actionList?.addEventListener('pointermove',event=>{
      if(!actionSwipe||event.pointerId!==actionSwipe.id)return;
      const dx=event.clientX-actionSwipe.x,dy=event.clientY-actionSwipe.y;
      if(Math.abs(dx)>8&&Math.abs(dx)>Math.abs(dy)){actionSwipe.moved=true;event.preventDefault();}
    });
    actionList?.addEventListener('pointerup',event=>{
      if(!actionSwipe||event.pointerId!==actionSwipe.id)return;
      const {row,moved}=actionSwipe,dx=event.clientX-actionSwipe.x;
      actionSwipe=null;
      if(!moved)return;
      suppressActionTapUntil=Date.now()+450;
      document.querySelectorAll('.fa-action-swipe-row[data-revealed="open"]').forEach(other=>{if(other!==row)other.dataset.revealed='none';});
      if(dx< -42)row.dataset.revealed='open';
      else if(dx>35)row.dataset.revealed='none';
    });
    actionList?.addEventListener('pointercancel',()=>{actionSwipe=null;});
    document.addEventListener('submit',event=>{
      const form=event.target;if(!['faAssetForm','faActionForm','faAutoForm'].includes(form.id))return;event.preventDefault();
      const data=Object.fromEntries(new FormData(form)),title=data.title?.trim();
      if(!title){error('请补充标题。');return;}
      if(form.id==='faAutoForm'){
        const a=actions.find(t=>t.id===form.dataset.action);if(!a||a.status==='cancelled')return;
        if(a.kind!=='todo'&&!data.start){error('请补充时间。');return;}
        if(a.kind==='event'&&(!data.end||data.end<=data.start)){error('结束时间需要晚于开始时间。');return;}
        if(a.kind==='reminder'&&data.start<='2026-10-19T16:30'){error('请选择晚于示例当前时间 10月19日 16:30 的提醒时间。');return;}
        Object.assign(a,{title,start:data.start||'',end:data.end||'',status:a.status==='failed'?'failed':'active'});
        render();openCapture(a.capture);toast('已保存修改。');return;
      }
      if(form.id==='faAssetForm'){
        const a=find(form.dataset.asset);if(!a)return;
        if(!data.content?.trim()){error('请保留资产内容。');return;}
        if(a.kind==='expense'&&(!/^\d+(\.\d{1,2})?$/.test(data.amount)||Number(data.amount)<=0||!data.currency||!data.date)){error('请核对金额、币种与消费日期。');return;}
        if(a.kind==='reference'&&data.url&&!/^https?:\/\//i.test(data.url)){error('资料链接须以 https:// 或 http:// 开头。');return;}
        if(a.kind==='expense')data.amount=Number(data.amount).toFixed(2);
        Object.assign(a,data,{title,content:data.content.trim(),status:a.kind==='reference'&&!data.url?'review':'ready'});
        render();openCapture(a.capture);toast(a.kind==='expense'?'账目已保存。':'想法已保存。');
      }else{
        const a=actions.find(t=>t.id===form.dataset.action);if(!a||a.status!=='suggested')return;
        if(a.kind!=='todo'&&!data.start){error('请补充时间。');return;}
        if(a.kind==='event'&&(!data.end||data.end<=data.start)){error('结束时间需要晚于开始时间。');return;}
        Object.assign(a,{title,start:data.start||'',end:data.end||'',external:data.external==='on',status:'active'});
        delete a.recordSuggestionDraft;
        render();openAction(a.id);toast('已加入原型行动列表，未写入系统。');
      }
    });
    $('sheet').addEventListener('close',()=>{
      const drafts=actions.filter(action=>action.recordSuggestionDraft);
      if(!drafts.length)return;
      const draftIDs=new Set(drafts.map(action=>action.id));
      for(let i=actions.length-1;i>=0;i--)if(draftIDs.has(actions[i].id))actions.splice(i,1);
      renderActions();
    });
    function openLibrary() {if(openNotebook){openNotebook(type==='expense'?'money':'ideas');return;}insightTab='assets';render();openSheet('记事本',`<div id="faLibraryContent">${$('flashAssetPanel').innerHTML}</div>`);}
    function handleClick(b) {
      const d=b.dataset;
      if(d.faTimeline){showTimeline(d.faTimeline);return true;}
      if(d.faNotebook){type='idea';reviewOnly=false;openLibrary();return true;}
      if(d.faLibraryKind){type=d.faLibraryKind;reviewOnly=false;openLibrary();return true;}
      if(d.faAutoEdit){autoActionEditor(d.faAutoEdit);return true;}
      if(d.faAutoUndo){const a=actions.find(t=>t.id===d.faAutoUndo);if(a){a.status='cancelled';render();openCapture(a.capture);toast('已撤销，不会因重新打开而再次创建。');}return true;}
      if(d.faResultUndo){const a=find(d.faResultUndo);if(a){a.previousStatus=a.status;a.status='ignored';render();openCapture(a.capture);toast('已撤销，原话仍保留。');}return true;}
      if(d.faResultRestore){const a=find(d.faResultRestore);if(a){a.status=a.previousStatus||'ready';render();openCapture(a.capture);}return true;}
      if(d.faAutoRetry){openSheet('提醒尚未安排',`<p class="sheet-intro">需要通知权限，才能在指定时间提醒你。内容已经保留。</p><p class="fa-demo-note">权限状态演示，不会请求真实系统权限。</p><button class="primary-button wide" data-fa-permission-demo="${d.faAutoRetry}">模拟已授权并重试</button><button class="plain-row" data-fa-capture="flash-failed">稍后处理</button>`);return true;}
      if(d.faPermissionDemo){const a=actions.find(t=>t.id===d.faPermissionDemo);if(a){a.status='active';render();openCapture(a.capture);toast('已演示安排成功。');}return true;}

      if(Date.now()<suppressActionTapUntil&&b.matches('.fa-action-card[data-fa-action]')&&b.closest('[data-fa-action-row]')){suppressActionTapUntil=0;return true;}
      if(d.faSwipeComplete){const item=actions.find(a=>a.id===d.faSwipeComplete);if(item){item.status=item.status==='done'?'active':'done';render();toast(item.status==='done'?'已标记完成。':'已恢复为未完成。');}return true;}
      if(d.faSwipeDelete){const item=actions.find(a=>a.id===d.faSwipeDelete);if(item)openSheet('删除这项行动？','<p class="sheet-intro">“'+esc(item.title)+'”将从原型示例中移除。</p><div class="sheet-actions"><button type="button" class="secondary-button" data-fa-delete-cancel>取消</button><button type="button" class="danger-button" data-fa-delete-confirm="'+esc(item.id)+'">删除</button></div>');return true;}
      if(d.faDeleteCancel){closeSheet();return true;}
      if(d.faDeleteConfirm){const index=actions.findIndex(a=>a.id===d.faDeleteConfirm);if(index>=0){if(actions[index].automatic)actions[index].status='cancelled';else actions.splice(index,1);closeSheet();render();toast('已从原型中删除，来源保留撤销记录。');}return true;}
      if(d.recordSuggestionAdd)return addRecordSuggestion(d.recordSuggestionAdd,d.suggestionId);
      if(d.faInsightTab){insightTab=d.faInsightTab;render();}
      else if(d.faFilter){type=d.faFilter;reviewOnly=false;render();$('faLibraryContent')?.querySelector(`[data-fa-filter="${type}"]`)?.focus();}
      else if(d.faReview){reviewOnly=!reviewOnly;render();}
      else if(d.faAsset)openAsset(d.faAsset);
      else if(d.faCapture)openCapture(d.faCapture);
      else if(d.faSource)openRecord(d.faSource,'text');
      else if(d.faEdit)editAsset(d.faEdit);
      else if(d.faIgnore){const a=find(d.faIgnore);a.previousStatus=a.status;a.status='ignored';render();openAsset(a.id);toast('已忽略；原始闪念与已有行动仍保留。');}
      else if(d.faRestore){const a=find(d.faRestore);a.status=a.previousStatus||'ready';render();openAsset(a.id);}
      else if(d.faIgnored)openSheet('已撤销的内容',`<p class="sheet-intro">原始闪念仍保留，可以随时恢复。</p><div class="fa-cards">${assets.filter(a=>a.status==='ignored').map(card).join('')}</div>`);
      else if(d.faChoose)chooseAction(d.faChoose);
      else if(d.faNewAction){const a=find(d.asset);let item=actions.find(t=>t.asset===a.id&&t.kind===d.faNewAction);if(!item){item={id:`asset-action-${++sequence}`,asset:a.id,capture:a.capture,quote:a.quote,kind:d.faNewAction,title:a.title,start:'',end:'',status:'suggested'};actions.push(item);}render();openAction(item.id);}
      else if(d.faCancelRecordAction){const item=actions.find(action=>action.id===d.faCancelRecordAction);if(item?.recordSuggestionDraft){actions.splice(actions.indexOf(item),1);renderActions();}openRecord(item?.capture||'review');}
      else if(d.faAction)openAction(d.faAction);
      else if(d.faActionFilter){actionFilter=d.faActionFilter;renderActions();}
      else if(d.faComplete){const a=actions.find(t=>t.id===d.faComplete);a.status=a.status==='done'?'active':'done';render();openAction(a.id);}
      else if(d.faPreview){$('product').scrollIntoView({block:'start'});if(d.faPreview==='assets')openLibrary();else {const id={ready:'flash-mixed',idea:'flash-method',expense:'flash-expense',incomplete:'flash-incomplete',failed:'flash-failed'}[d.faPreview];openCapture(id||'thought-noon',id?'ready':d.faPreview);}}
      else return false;
      return true;
    }
    document.addEventListener('keydown',event=>{
      if(event.target.matches('[data-fa-filter]')&&['ArrowLeft','ArrowRight','Home','End'].includes(event.key)){
        event.preventDefault();const next=event.key==='Home'?'idea':event.key==='End'?'expense':type==='idea'?'expense':'idea';
        $('faLibraryContent')?.querySelector(`[data-fa-filter="${next}"]`)?.click();return;
      }
      if(!event.target.matches('[data-fa-insight-tab]')||!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
      event.preventDefault();const next=event.key==='Home'?'assets':event.key==='End'?'life':insightTab==='assets'?'life':'assets';
      const button=document.querySelector(`[data-fa-insight-tab="${next}"]`);button.click();button.focus();
    });
    function notebookEntries(){return assets.filter(a=>a.status!=='ignored').map(a=>{const r=getRecord(a.capture);return {...a,date:a.date||`2026-10-${String(r?.day||19).padStart(2,'0')}`,time:r?.time||'16:30',device:r?.source||'Apple Watch'};});}
    function saveNotebookEntry(id,change){const a=find(id);if(!a)return;const {title,content,amount,currency,date,direction,category,status}=change;for(const [key,value] of Object.entries({title,content,amount,currency,date,direction,category,status}))if(value!==undefined)a[key]=value;render();}
    return {seed,render,entry,badge,timelineMarkup,searchText,resultMarkup,recordSuggestions,handleClick,openCapture,openLibrary,notebookEntries,saveNotebookEntry};
  };
  window.daybookFlashAssetsCopy = [
    ['记事本','Notebook','ノート'],['我的想法','My ideas','私のアイデア'],['我的记账','My ledger','私の家計簿'],
    ['闪念资产','Thought assets','ひらめきの資産'],['生活洞察','Life insights','暮らしの気づき'],['行动','Actions','アクション'],
    ['想法','Ideas','アイデア'],['知识','Knowledge','知識'],['感受','Feelings','気持ち'],['记账','Ledger','家計簿'],['整理','Organized','整理'],['已保存','Saved','保存済み'],['已记账','Recorded','記帳済み'],['待补充','Needs details','要追記'],['人物','People','人物'],['资料','References','資料'],
    ['待办','Tasks','タスク'],['日程','Events','予定'],['提醒','Reminders','リマインダー'],['待确认','Review needed','要確認'],['已整理','Organized','整理済み'],
    ['回看原话','View source','元の言葉を見る'],['资产详情','Asset details','資産の詳細'],['转为行动','Turn into action','行動に移す'],['修改资产','Edit asset','資産を編集'],
    ['忽略这份资产','Dismiss asset','この資産を非表示'],['恢复资产','Restore asset','資産を戻す'],['核对并确认','Review and confirm','確認して保存'],
    ['从这条闪念提炼','From this thought','このひらめきから'],['来源与理解','Sources and understanding','記録と理解'],['等你决定','For your decision','決めるのはあなた'],
    ['已加入行动','Your actions','追加したアクション'],['原话依据','Original wording','元の言葉'],['全部日期','All dates','すべての日付']
    ,['待办会保留到完成或删除；提醒与日程仅显示今天及未来。','Tasks stay until completed or deleted; reminders and events show today and future only.','タスクは完了または削除まで表示され、リマインダーと予定は今日以降のみ表示されます。'],['左划查看操作 · 原型演示，不创建通知或写入系统','Swipe left for actions · Prototype only; no notifications or system writes','左にスワイプして操作 · プロトタイプのみ。通知やシステムへの書き込みはありません'],['待办操作','Task actions','タスクの操作'],['删除操作','Delete action','削除操作'],['完成','Complete','完了'],['撤销','Undo','元に戻す'],['已标记完成。','Marked complete.','完了にしました。'],['已恢复为未完成。','Marked incomplete.','未完了に戻しました。'],['删除这项行动？','Delete this action?','このアクションを削除しますか？'],['将从原型示例中移除。','It will be removed from this prototype.','このプロトタイプから削除されます。'],['已从原型中删除。','Removed from the prototype.','プロトタイプから削除しました。']
  ];
})();
