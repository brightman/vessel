/* Design-only fixtures. Edits live in memory; no model, storage or system APIs. */
(() => {
  'use strict';
  const kinds = {
    idea: {label:'想法',icon:'Lightbulb'}, knowledge:{label:'知识',icon:'BookOpen'},
    feeling:{label:'感受',icon:'Heart'}, expense:{label:'消费',icon:'NotebookPen'},
    person:{label:'人物',icon:'MessageCircle'}, reference:{label:'资料',icon:'Link2'}
  };
  const actionKinds = {todo:{label:'待办',icon:'CheckCheck'},reminder:{label:'提醒',icon:'Bell'},event:{label:'日程',icon:'CalendarDays'}};
  window.createDaybookFlashAssets = ({$,esc,icon,toast,openSheet,closeSheet,showView,openRecord,getRecord,refreshRecords}) => {
    const assets = [
      {id:'idea-people',kind:'idea',title:'按人回顾，让讨论接着走',content:'给 WiseLife 增加按人回顾，把与同一个人讨论过的内容串起来。',capture:'flash-mixed',quote:'想到可以给 WiseLife 做一个按人回顾，把和同一个人讨论过的内容串起来。',offset:'00:00–00:12',status:'ready'},
      {id:'expense-taxi',kind:'expense',title:'打车去见林茜',content:'今天打车去见林茜，花了三十八元人民币。',capture:'flash-mixed',quote:'今天打车去见林茜，花了三十八元人民币。',offset:'00:20–00:27',amount:'38.00',currency:'CNY',date:'2026-10-19',status:'review'},
      {id:'person-lin',kind:'person',title:'林茜 · 负责用户研究',content:'林茜负责这次用户研究。人物名称来自原话，尚未关联通讯录。',capture:'flash-mixed',quote:'林茜负责这次用户研究。',offset:'00:12–00:20',status:'ready'},
      {id:'knowledge-interview',kind:'knowledge',title:'先听经历，再问观点',content:'访谈时，先请对方讲最近一次真实经历，再追问当时的选择。把这句话留作自己的访谈方法。',capture:'flash-method',quote:'今天访谈学到一点：先让对方讲最近一次真实经历，再追问当时为什么这么选。',offset:'00:00–00:18',status:'ready'},
      {id:'feeling-morning',kind:'feeling',title:'醒来有点困，慢慢开始',content:'今天醒来还是有点困，想给自己一点缓冲。仅保留自述，不推断原因。',capture:'tired-19',quote:'今天醒来还是有点困，先慢慢开始。',offset:'00:00–00:12',status:'ready'},
      {id:'reference-watch',kind:'reference',title:'Apple Watch 支持资料',content:'研究手表适配时回看官方支持资料。原话只提到页面名称，链接待补充。',capture:'flash-method',quote:'顺便把 Apple Watch 的官方支持页面留作适配参考，链接等会儿补。',offset:'00:18–00:34',url:'',status:'review'}
    ];
    const actions = [
      {id:'sketch',kind:'todo',title:'画出按人回顾的草图',capture:'flash-mixed',asset:'idea-people',quote:'开会前把草图画好。',constraint:'原话：开会前；还没有指定截止时刻',start:'',end:'',status:'suggested'},
      {id:'discussion',kind:'event',title:'和林茜讨论按人回顾',capture:'flash-mixed',asset:'idea-people',quote:'明天下午三点和林茜讨论，结束时间还没定。',constraint:'结束时间待补充',start:'2026-10-20T15:00',end:'',status:'suggested'}
    ];
    let type='all',reviewOnly=false,insightTab='assets',actionFilter='all',sequence=0;
    const find = id => assets.find(a=>a.id===id);
    const shown = capture => assets.filter(a=>a.capture===capture&&a.status!=='ignored');
    const sourceName = a => getRecord(a.capture)?.title||'原始闪念';
    const flow = step => `<ol class="fa-flow" translate="no" aria-label="Capture → Insight → Action">${['Capture','Insight','Action'].map((s,i)=>`<li class="${i===step?'current':''}" ${i===step?'aria-current="step"':''}><span>${String(i+1).padStart(2,'0')}</span>${s}</li>`).join('')}</ol>`;
    const statusLabel = a => a.status==='ignored'?'已忽略':a.status==='review'?(a.kind==='reference'&&!a.url?'待补链接':'待确认'):'已整理';
    const sourceButton = a => `<button class="fa-source" data-fa-source="${a.capture}">${icon('AudioLines')}<span translate="no">${esc(sourceName(a))}</span>${icon('ArrowUpRight')}</button>`;
    const money = a => `${a.currency||'币种待补'} ${a.amount||'金额待补'}`;
    function seed(records) {
      records.push(
        {id:'flash-mixed',day:19,kind:'thought',start:15.7,end:15.7+58/3600,time:'15:42',duration:58,title:'关于按人回顾的一段闪念',preview:'一个产品想法，一次见面，还有接下来想做的事。',source:'EurekaRing',summary:'想到按人回顾的功能；林茜负责用户研究。\n记下打车支出 38 元人民币，以及画草图和讨论的打算。',text:'想到可以给 WiseLife 做一个按人回顾，把和同一个人讨论过的内容串起来。\n\n林茜负责这次用户研究。\n\n今天打车去见林茜，花了三十八元人民币。\n\n明天下午三点和林茜讨论，结束时间还没定。开会前把草图画好。',tags:['闪念','产品想法'],captureTimezone:'Asia/Shanghai'},
        {id:'flash-method',day:19,kind:'thought',start:10.2,end:10.2+34/3600,time:'10:12',duration:34,title:'访谈后留下的方法和资料',preview:'先听真实经历，再追问当时的选择。',source:'iPhone',summary:'记录访谈方法，以及待补链接的 Apple Watch 支持资料。',text:'今天访谈学到一点：先让对方讲最近一次真实经历，再追问当时为什么这么选。\n\n顺便把 Apple Watch 的官方支持页面留作适配参考，链接等会儿补。',tags:['闪念','访谈']}
      );
    }
    function card(a) {
      return `<button class="fa-card" data-fa-asset="${a.id}"><span class="fa-card-top"><span class="fa-kind" data-kind="${a.kind}">${icon(kinds[a.kind].icon)}${kinds[a.kind].label}</span><span class="fa-status ${a.status==='review'?'review':''}">${statusLabel(a)}</span></span><strong translate="no">${esc(a.title)}</strong>${a.kind==='expense'?`<span class="fa-money" translate="no">${esc(money(a))}</span>`:`<span class="fa-excerpt" translate="no">${esc(a.content)}</span>`}<span class="fa-card-bottom">${icon('AudioLines')}<span translate="no">${esc(sourceName(a))}</span>${icon('ChevronRight')}</span></button>`;
    }
    function render() {
      if(!$('flashAssetPanel'))return;
      const active=assets.filter(a=>a.status!=='ignored'),pending=active.filter(a=>a.status==='review');
      $('flashAssetPanel').hidden=insightTab!=='assets';$('lifeInsightPanel').hidden=insightTab!=='life';
      document.querySelectorAll('[data-fa-insight-tab]').forEach(b=>{b.setAttribute('aria-selected',String(b.dataset.faInsightTab===insightTab));b.tabIndex=b.dataset.faInsightTab===insightTab?0:-1;});
      $('flashAssetPanel').innerHTML=`${flow(1)}<div class="fa-heading"><span class="eyebrow">闪念留下，价值慢慢长出来</span><h2>说过的话，<br>成为自己的积累。</h2><p><span>${active.length}</span> <span>份资产</span> <span>·</span> <span>${new Set(active.map(a=>a.capture)).size}</span> <span>条闪念</span><span class="fa-scope">全部日期</span></p></div><button class="fa-feature" data-fa-capture="flash-mixed"><span class="fa-feature-icon">${icon('Lightbulb')}</span><span><strong>一条闪念，可以留下什么？</strong><small>查看 ${shown('flash-mixed').length} 份资产与 ${actions.filter(a=>a.capture==='flash-mixed').length} 项行动</small></span>${icon('ArrowUpRight')}</button><div class="fa-filter-row" role="group" aria-label="资产类型">${[['all','全部'],...Object.entries(kinds).map(([k,v])=>[k,v.label])].map(([k,label])=>`<button data-fa-filter="${k}" aria-pressed="${type===k}">${label}</button>`).join('')}</div><div class="fa-review-row"><span>${reviewOnly?'待你核对':'从闪念中提炼'}</span><button data-fa-review="toggle" aria-pressed="${reviewOnly}">${reviewOnly?'查看全部':`待确认 · ${pending.length}`}${icon('ChevronRight')}</button></div>${type==='expense'?expenseTotal():''}<div class="fa-cards">${active.filter(a=>(type==='all'||a.kind===type)&&(!reviewOnly||a.status==='review')).map(card).join('')||'<div class="fa-empty">没有待查看的资产。可以切换分类，或下次再来。</div>'}</div><div class="fa-library-footer"><span>示例整理 · 修改仅在本页保留</span>${assets.some(a=>a.status==='ignored')?'<button class="text-button" data-fa-ignored="open">查看已忽略</button>':''}</div>`;
      renderActions();refreshRecords?.();
    }
    function expenseTotal() {
      const totals={};assets.filter(a=>a.kind==='expense'&&a.status==='ready').forEach(a=>{totals[a.currency]=(totals[a.currency]||0)+Math.round(Number(a.amount)*100);});
      return `<div class="fa-total"><span>已确认支出</span><strong translate="no">${Object.entries(totals).map(([c,n])=>`${c} ${(n/100).toFixed(2)}`).join(' · ')||'—'}</strong><small>待确认的消费不计入汇总</small></div>`;
    }
    function entry(r) {
      if(r.kind!=='thought')return '';
      const list=shown(r.id),count=actions.filter(a=>a.capture===r.id&&a.status==='suggested').length;
      return `<button class="fa-record-entry" data-fa-capture="${r.id}"><span class="fa-kind">${icon('Lightbulb')}从这条闪念提炼</span><strong>${list.length?`${list.length} 份资产`:'查看整理状态'}${count?` · ${count} 项行动建议`:''}</strong><span>留住原话，也留下可以继续的线索 ${icon('ArrowUpRight')}</span></button>`;
    }
    function badge(r) {const n=shown(r.id).length;return n?`<span class="fa-timeline-badge">${n} 份资产</span>`:'';}
    function openCapture(id,mode='ready') {
      const r=getRecord(id);if(!r)return;
      const list=shown(id),related=actions.filter(a=>a.capture===id);
      let body='';
      if(mode!=='ready'||(!list.length&&!related.length)){
        const copy={waiting:['正在整理这条闪念','音频和全文已保留。整理完成后，资产会出现在洞察中。'],unavailable:['已保存，等待整理','本地模型暂不可用。你可以先回看全文，稍后再整理。'],empty:['这次，留下原话就好','没有需要单独整理的内容。并不是每条闪念都需要变成资产。']}[mode]||['还没有提炼结果','原始闪念已保留，可以先回看。'];
        body=`<div class="fa-state">${icon(mode==='waiting'?'Clock3':'BookOpen')}<h3>${copy[0]}</h3><p>${copy[1]}</p></div><button class="secondary-button wide" data-fa-source="${id}">查看原始闪念</button>`;
      }else{
        body=`<div class="fa-section-label"><h3>Insight · 闪念资产</h3><span>${list.length} 份</span></div><div class="fa-cards">${list.map(card).join('')}</div><div class="fa-action-section"><div class="fa-section-label"><h3>Action · 行动建议</h3><span>${related.length} 项</span></div><p>想做的时候，再安排。</p>${related.map(actionCard).join('')}</div>`;
      }
      openSheet('从闪念到积累',`${flow(1)}<div class="fa-origin"><span class="eyebrow">Capture · 原始闪念</span><h3 translate="no">${esc(r.title)}</h3><p translate="no">10月${r.day}日 ${r.time} · ${esc(r.source)} · ${r.duration} 秒</p><button class="text-button" data-fa-source="${id}">${icon('AudioLines')}回看原话${icon('ChevronRight')}</button></div>${body}<p class="fa-demo-note">交互原型 · 预设提炼结果，未运行 AI</p>`);
    }
    function openAsset(id) {
      const a=find(id);if(!a)return;
      const related=actions.filter(t=>t.asset===id&&t.status!=='suggested');
      openSheet('资产详情',`${flow(1)}<div class="fa-detail-top"><span class="fa-kind" data-kind="${a.kind}">${icon(kinds[a.kind].icon)}${kinds[a.kind].label}</span><span class="fa-status ${a.status==='review'?'review':''}">${statusLabel(a)}</span></div><h3 class="fa-detail-title" translate="no">${esc(a.title)}</h3>${a.kind==='expense'?`<div class="fa-detail-money" translate="no">${esc(money(a))}</div><p class="subtle" translate="no">${esc(a.date||'日期待补')} · ${a.status==='ready'?'已计入确认支出':'核对后才计入支出'}</p>`:''}<p class="fa-detail-copy" translate="no">${esc(a.content)}</p>${a.kind==='reference'&&a.url?`<a class="fa-url" href="${esc(a.url)}" target="_blank" rel="noopener noreferrer">${esc(a.url)} ${icon('ArrowUpRight')}</a>`:''}<div class="fa-evidence"><span class="eyebrow">原话依据 <span translate="no">${a.offset}</span></span><blockquote translate="no">“${esc(a.quote)}”</blockquote>${sourceButton(a)}</div>${a.kind==='person'?'<p class="fa-note">人物信息来自这段原话，尚未关联通讯录；提到的人不代表录音中的说话人。</p>':''}${a.kind==='reference'&&!a.url?'<p class="fa-note">原话没有实际链接。补充后可直接回看资料。</p>':''}${related.length?`<div class="fa-section-label"><h3>关联行动</h3></div>${related.map(actionCard).join('')}`:''}<div class="fa-detail-controls">${a.status==='review'?`<button class="primary-button wide" data-fa-edit="${a.id}">${icon('Check')}核对并确认</button>`:''}${a.status!=='ignored'?`<button class="${a.status==='review'?'secondary':'primary'}-button wide" data-fa-choose="${a.id}">${icon('ArrowUpRight')}转为行动</button><div class="fa-inline-actions"><button class="text-button" data-fa-edit="${a.id}">修改资产</button><button class="text-button" data-fa-ignore="${a.id}">忽略这份资产</button></div>`:`<button class="primary-button wide" data-fa-restore="${a.id}">恢复资产</button>`}</div>`);
    }
    function field(label,name,value,type='text',required=false,extra='') {
      return `<label class="fa-field"><span>${label}</span><input name="${name}" type="${type}" value="${esc(value||'')}" ${required?'required':''} ${extra}></label>`;
    }
    function actionField(label,name,value,type='text',required=false,extra='') {
      return `<label class="action-form-field"><span>${label}</span><input name="${name}" type="${type}" value="${esc(value||'')}" ${required?'required':''} ${extra}></label>`;
    }
    function editAsset(id) {
      const a=find(id);if(!a)return;
      openSheet(a.status==='review'?'核对资产':'修改资产',`<form id="faAssetForm" data-asset="${id}">${field('标题','title',a.title,'text',true,'maxlength="80"')}<label class="fa-field"><span>内容</span><textarea name="content" rows="4" maxlength="1000" required>${esc(a.content)}</textarea></label>${a.kind==='expense'?`<div class="fa-field-pair">${field('金额','amount',a.amount,'number',true,'min="0.01" max="999999999" step="0.01"')}<label class="fa-field"><span>币种</span><select name="currency" required><option value="">请选择币种</option>${['CNY','USD','SGD','EUR','JPY','HKD'].map(c=>`<option ${a.currency===c?'selected':''}>${c}</option>`).join('')}</select></label></div>${field('消费日期','date',a.date,'date',true)}`:''}${a.kind==='reference'?field('资料链接（可稍后补）','url',a.url,'url',false,'placeholder="https://"'):''}<div class="fa-evidence"><span class="eyebrow">原话依据</span><blockquote translate="no">“${esc(a.quote)}”</blockquote></div><p id="faFormError" class="fa-error" role="alert" hidden></p><button class="primary-button wide" type="submit">${a.status==='review'?'确认并保存':'保存修改'}</button><button class="plain-row" type="button" data-fa-asset="${id}">取消</button></form>`);
    }
    function chooseAction(id) {
      const a=find(id);if(!a)return;
      openSheet('把想法往前推一步',`${flow(2)}<p class="sheet-intro" translate="no">来自：${esc(a.title)}</p>${Object.entries(actionKinds).map(([k,v])=>`<button class="capture-option action-kind-option" data-fa-new-action="${k}" data-asset="${id}">${icon(v.icon)}<div><strong>${v.label}</strong><p>${{todo:'先记下要做的事，时间可以稍后再定',reminder:'在指定时间提醒自己',event:'为这件事留出一段时间'}[k]}</p></div>${icon('ChevronRight')}</button>`).join('')}`);
    }
    function actionCard(a) {
      const kind=actionKinds[a.kind];
      return `<button class="fa-action-card" data-fa-action="${a.id}"><span class="fa-action-symbol ${a.status==='done'?'done':''}">${icon(a.status==='done'?'Check':kind.icon)}</span><span class="fa-action-copy"><strong translate="no">${esc(a.title)}</strong><small translate="no">${esc(a.status==='suggested'?(a.constraint||'等待你的确认'):a.start?formatDate(a.start):'未设时间')}</small><span class="fa-action-state">${kind.label} · ${{suggested:'待确认',active:'已加入',done:'已完成'}[a.status]}</span></span>${icon('ChevronRight')}</button>`;
    }
    function formatDate(value) {return value.replace('2026-','').replace('T',' ');}
    function renderActions() {
      if(!$('flashActions'))return;
      const visible=actions.filter(a=>actionFilter==='all'||a.kind===actionFilter);
      const suggestions=visible.filter(a=>a.status==='suggested'),accepted=visible.filter(a=>a.status!=='suggested');
      $('flashActions').innerHTML=`${flow(2)}<div class="fa-heading"><span class="eyebrow">把理解，变成下一步</span><h2>从一件小事开始。</h2><p>待办、提醒、日程，由你来决定。</p></div><div class="fa-filter-row" role="group" aria-label="行动类型">${[['all','全部'],...Object.entries(actionKinds).map(([k,v])=>[k,v.label])].map(([k,v])=>`<button data-fa-action-filter="${k}" aria-pressed="${actionFilter===k}">${v}</button>`).join('')}</div><div class="fa-section-label"><h3>等你决定</h3><span>${suggestions.length} 项</span></div>${suggestions.map(actionCard).join('')||'<p class="fa-empty">暂时没有待确认建议。</p>'}<div class="fa-section-label"><h3>已加入行动</h3><span>${accepted.length} 项</span></div>${accepted.map(actionCard).join('')||'<div class="fa-empty">不必一次安排好所有事情。<br>确认一项建议，就从这里继续。</div>'}<p class="fa-demo-note">原型演示 · 不创建通知或写入系统</p>`;
    }
    function openAction(id) {
      const a=actions.find(t=>t.id===id);if(!a)return;
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
      openSheet(`添加${v.label}`,`<form class="action-form" id="faActionForm" data-action="${a.id}">${actionField('要做什么','title',a.title,'text',true,'maxlength="100"')}<fieldset class="action-form-section"><legend>安排时间</legend><div class="action-form-grid${a.kind==='event'?' stack':''}">${schedule}</div><p class="action-form-help">${scheduleNote}${timezoneNote?`<span class="action-form-help-detail">${timezoneNote}</span>`:''}</p></fieldset><section class="action-form-source"><p>来源</p><blockquote translate="no">“${esc(a.quote)}”</blockquote>${sourceButton(a)}</section><label class="action-form-sync"><span><strong>同时添加到 Apple ${externalTarget}</strong><small>可选 · 默认关闭</small></span><span class="action-form-toggle"><input type="checkbox" name="external"><span aria-hidden="true"></span></span></label><p id="faFormError" class="action-form-error" role="alert" hidden></p><div class="sheet-actions"><button class="secondary-button" type="button" data-fa-capture="${a.capture}">取消</button><button class="primary-button" type="submit">确认加入${v.label}</button></div></form>`);
    }
    function error(message) {$('faFormError').hidden=false;$('faFormError').textContent=message;$('faFormError').scrollIntoView({block:'nearest'});}
    document.addEventListener('submit',event=>{
      const form=event.target;if(!['faAssetForm','faActionForm'].includes(form.id))return;event.preventDefault();
      const data=Object.fromEntries(new FormData(form)),title=data.title?.trim();
      if(!title){error('请补充标题。');return;}
      if(form.id==='faAssetForm'){
        const a=find(form.dataset.asset);if(!a)return;
        if(!data.content?.trim()){error('请保留资产内容。');return;}
        if(a.kind==='expense'&&(!/^\d+(\.\d{1,2})?$/.test(data.amount)||Number(data.amount)<=0||!data.currency||!data.date)){error('请核对金额、币种与消费日期。');return;}
        if(a.kind==='reference'&&data.url&&!/^https?:\/\//i.test(data.url)){error('资料链接须以 https:// 或 http:// 开头。');return;}
        if(a.kind==='expense')data.amount=Number(data.amount).toFixed(2);
        Object.assign(a,data,{title,content:data.content.trim(),status:a.kind==='reference'&&!data.url?'review':'ready'});
        render();openAsset(a.id);toast('修改已保留在原型中，刷新后恢复示例。');
      }else{
        const a=actions.find(t=>t.id===form.dataset.action);if(!a||a.status!=='suggested')return;
        if(a.kind!=='todo'&&!data.start){error('请补充时间。');return;}
        if(a.kind==='event'&&(!data.end||data.end<=data.start)){error('结束时间需要晚于开始时间。');return;}
        Object.assign(a,{title,start:data.start||'',end:data.end||'',external:data.external==='on',status:'active'});
        render();openAction(a.id);toast('已加入原型行动列表，未写入系统。');
      }
    });
    function openLibrary() {insightTab='assets';closeSheet();showView('insights');render();}
    function handleClick(b) {
      const d=b.dataset;
      if(d.faInsightTab){insightTab=d.faInsightTab;render();}
      else if(d.faFilter){type=d.faFilter;render();}
      else if(d.faReview){reviewOnly=!reviewOnly;render();}
      else if(d.faAsset)openAsset(d.faAsset);
      else if(d.faCapture)openCapture(d.faCapture);
      else if(d.faSource)openRecord(d.faSource,'text');
      else if(d.faEdit)editAsset(d.faEdit);
      else if(d.faIgnore){const a=find(d.faIgnore);a.previousStatus=a.status;a.status='ignored';render();openAsset(a.id);toast('已忽略；原始闪念与已有行动仍保留。');}
      else if(d.faRestore){const a=find(d.faRestore);a.status=a.previousStatus||'ready';render();openAsset(a.id);}
      else if(d.faIgnored)openSheet('已忽略的资产',`<p class="sheet-intro">原始闪念仍保留，可以随时恢复。</p><div class="fa-cards">${assets.filter(a=>a.status==='ignored').map(card).join('')}</div>`);
      else if(d.faChoose)chooseAction(d.faChoose);
      else if(d.faNewAction){const a=find(d.asset);let item=actions.find(t=>t.asset===a.id&&t.kind===d.faNewAction);if(!item){item={id:`asset-action-${++sequence}`,asset:a.id,capture:a.capture,quote:a.quote,kind:d.faNewAction,title:a.title,start:'',end:'',status:'suggested'};actions.push(item);}render();openAction(item.id);}
      else if(d.faAction)openAction(d.faAction);
      else if(d.faActionFilter){actionFilter=d.faActionFilter;renderActions();}
      else if(d.faComplete){const a=actions.find(t=>t.id===d.faComplete);a.status=a.status==='done'?'active':'done';render();openAction(a.id);}
      else if(d.faPreview){$('product').scrollIntoView({block:'start'});if(d.faPreview==='assets')openLibrary();else openCapture(d.faPreview==='ready'?'flash-mixed':'thought-noon',d.faPreview);}
      else return false;
      return true;
    }
    document.addEventListener('keydown',event=>{
      if(!event.target.matches('[data-fa-insight-tab]')||!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
      event.preventDefault();const next=event.key==='Home'?'assets':event.key==='End'?'life':insightTab==='assets'?'life':'assets';
      const button=document.querySelector(`[data-fa-insight-tab="${next}"]`);button.click();button.focus();
    });
    return {seed,render,entry,badge,handleClick,openCapture,openLibrary};
  };
  window.daybookFlashAssetsCopy = [
    ['闪念资产','Thought assets','ひらめきの資産'],['生活洞察','Life insights','暮らしの気づき'],['行动','Actions','アクション'],
    ['想法','Ideas','アイデア'],['知识','Knowledge','知識'],['感受','Feelings','気持ち'],['消费','Expenses','支出'],['人物','People','人物'],['资料','References','資料'],
    ['待办','Tasks','タスク'],['日程','Events','予定'],['提醒','Reminders','リマインダー'],['待确认','Review needed','要確認'],['已整理','Organized','整理済み'],
    ['回看原话','View source','元の言葉を見る'],['资产详情','Asset details','資産の詳細'],['转为行动','Turn into action','行動に移す'],['修改资产','Edit asset','資産を編集'],
    ['忽略这份资产','Dismiss asset','この資産を非表示'],['恢复资产','Restore asset','資産を戻す'],['核对并确认','Review and confirm','確認して保存'],
    ['从这条闪念提炼','From this thought','このひらめきから'],['来源与理解','Sources and understanding','記録と理解'],['等你决定','For your decision','決めるのはあなた'],
    ['已加入行动','Your actions','追加したアクション'],['原话依据','Original wording','元の言葉'],['全部日期','All dates','すべての日付']
  ];
})();
