/* Product review only: fictional records, in-memory edits, simulated AI. No data or location APIs. */
(() => {
  'use strict';
  window.createDaybookNotebook = ({root=document, getFlashEntries, saveFlashEntry, onModal=()=>{}}={}) => {
  const $ = id => document.getElementById(id);
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const paths = {
    plus:'M12 5v14M5 12h14', check:'m5 12 4 4L19 6', chevron:'m9 5 7 7-7 7', left:'m15 5-7 7 7 7',
    idea:'M9 18h6M10 21h4M8.5 14.5a6 6 0 1 1 7 0C14.6 15.1 15 17 15 17H9s.4-1.9-.5-2.5Z',
    spark:'m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5ZM20 2v4M18 4h4',
    mic:'M9 5a3 3 0 0 1 6 0v7a3 3 0 0 1-6 0ZM5 10v2a7 7 0 0 0 14 0v-2M12 19v3M8 22h8',
    pen:'m16 3 5 5-12 12-6 1 1-6ZM14 5l5 5', wallet:'M20 8H5a2 2 0 0 1 0-4h13v4M5 8H3v12h17V8M16 12h6v5h-6Z',
    person:'M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0ZM4 21v-2a8 8 0 0 1 16 0v2',
    pin:'M19 10c0 5-7 11-7 11S5 15 5 10a7 7 0 1 1 14 0ZM14.5 10a2.5 2.5 0 1 1-5 0 2.5 2.5 0 0 1 5 0Z',
    home:'m3 10 9-7 9 7M5 9v12h14V9M9 21v-8h6v8', office:'M5 21V3h14v18M3 21h18M9 7h1M14 7h1M9 11h1M14 11h1M10 21v-6h4v6',
    school:'m2 8 10-5 10 5-10 5ZM6 10v7c4 3 8 3 12 0v-7M22 8v8', coffee:'M4 8h12v7a5 5 0 0 1-5 5H9a5 5 0 0 1-5-5ZM16 9h2a3 3 0 0 1 0 6h-2M7 3v2M12 3v2M2 23h18',
    car:'m5 6-3 7v6h3v-3h14v3h3v-6l-3-7ZM3 12h18M6 14h1M17 14h1', shop:'M4 9v12h16V9M3 3h18l1 6H2ZM8 21v-7h8v7',
    food:'M5 3v6a3 3 0 0 0 6 0V3M8 3v18M18 3c-3 3-3 8 0 9h2V3ZM20 12v9', tree:'m12 3-7 8h3l-5 6h18l-5-6h3ZM12 17v5',
    photo:'M3 5h18v15H3ZM3 16l5-5 5 5 3-3 5 5M16 9h.01', calendar:'M4 5h16v16H4ZM4 10h16M8 3v4M16 3v4', info:'M12 8h.01M12 11v6M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0Z'
  };
  const icon = name => `<svg class="icon" aria-hidden="true" viewBox="0 0 24 24"><path d="${paths[name] || paths.idea}"></path></svg>`;
  const tabs = {
    ideas:{label:'灵感',subtitle:'想到的时候，留下来。',icon:'idea',review:'让想法继续生长',text:'打开一条灵感编辑，或点「选择」勾选两条，用 AI 发展新的想法。',steps:['主动闪念，自动保存','多选灵感，给 AI 一个方向','选中候选，另存为新灵感']},
    money:{label:'记账',subtitle:'一笔一笔，看清每月收支。',icon:'wallet',review:'把每月的账看明白',text:'切换月份，筛选支出或收入。点开任一账目修改，月度汇总同步变化。',steps:['按发生日期归入月份','待补充的账目不计入汇总','不同币种分别查看']},
    people:{label:'人物',subtitle:'让每一次谈话，都有迹可循。',icon:'person',review:'记住人，也记住聊过什么',text:'添加与编辑使用相同的五项表单：姓名、公司、邮箱、手机号、关系。关系支持多选，也可以添加自定义选项。',steps:['复用录音里绑定的联系人','家人、同事、朋友，可同时选择','新联系人可先保存，之后关联录音']},
    places:{label:'地点',subtitle:'看看经常出现的地方。',icon:'pin',review:'常去的地方，一目了然',text:'按近 30 天出现的天数排序。同一地点一天出现多次，只记 1 次；点开可查看日期或标记名称。',steps:['同一地点，每天最多记 1 次','按去重后的次数从多到少排列','名称和类型，由你标记']}
  };
  const makeIdeas = () => [
    {id:'i1',title:'让每次讨论，都能接着上次继续',body:'按人串起过去讨论过的内容。下次见面前，用一分钟找回我们上次停在哪里。',date:'2026-11-03',time:'08:42',origin:'闪念',device:'Apple Watch',quote:'记个想法，按人把讨论串起来，下次见面前就能知道上次聊到哪里。'},
    {id:'i2',title:'会议结束后，留一个小小的下一步',body:'讨论结束，只整理一件最值得推进的事。让行动足够小，今天就可以开始。',date:'2026-11-02',time:'18:26',origin:'闪念',device:'iPhone',quote:'记个想法，每次会议后只留一个最小的下一步，不要一口气列一堆任务。'},
    {id:'i3',title:'先听经历，再问观点',body:'访谈时，先请对方讲最近一次真实经历，再追问当时的选择。具体的故事，比抽象的喜好更有用。',date:'2026-11-02',time:'12:55',origin:'闪念',device:'Apple Watch',quote:'先听真实经历，再问为什么这样选。把这个访谈方法记下来。'},
    {id:'i4',title:'给散步留一点没有目的的时间',body:'不听播客，也不急着完成什么。走二十分钟，看看路上有没有新的想法。',date:'2026-11-01',time:'17:08',origin:'手动记录',quote:''},
    {id:'i5',title:'一本只记录问题的小册子',body:'先记住那些还没想清楚的问题。隔一周再翻一遍，可能会看到新的联系。',date:'2026-10-30',time:'21:16',origin:'闪念',device:'iPhone',quote:'做一本只记录问题的小册子，不急着填答案，每周看一下。'}
  ];
  const makeMoney = () => [
    {id:'m1',title:'午餐',direction:'expense',amount:3500,currency:'CNY',date:'2026-11-03',category:'餐饮',ready:true},
    {id:'m2',title:'去见林茜的车费',direction:'expense',amount:3800,currency:'CNY',date:'2026-11-03',category:'交通',ready:true},
    {id:'m3',title:'一杯拿铁',direction:'expense',amount:2800,currency:'CNY',date:'2026-11-02',category:'餐饮',ready:true},
    {id:'m4',title:'书店买书',direction:'expense',amount:12800,currency:'CNY',date:'2026-11-02',category:'购物',ready:true},
    {id:'m5',title:'项目咨询收入',direction:'income',amount:360000,currency:'CNY',date:'2026-11-01',category:'咨询',ready:true},
    {id:'m6',title:'房租',direction:'expense',amount:420000,currency:'CNY',date:'2026-11-01',category:'居住',ready:true},
    {id:'m7',title:'买咖啡，金额待补',direction:'expense',amount:null,currency:'CNY',date:'2026-11-03',category:'餐饮',ready:false},
    {id:'m8',title:'十月工资',direction:'income',amount:1850000,currency:'CNY',date:'2026-10-25',category:'工资',ready:true},
    {id:'m9',title:'房租',direction:'expense',amount:420000,currency:'CNY',date:'2026-10-01',category:'居住',ready:true},
    {id:'m10',title:'周末采购',direction:'expense',amount:26850,currency:'CNY',date:'2026-10-31',category:'购物',ready:true},
    {id:'m11',title:'晚餐',direction:'expense',amount:15600,currency:'CNY',date:'2026-10-31',category:'餐饮',ready:true},
    {id:'m12',title:'软件订阅',direction:'expense',amount:2000,currency:'USD',date:'2026-11-02',category:'订阅',ready:true}
  ];
  const makePeople = () => [
    {id:'p1',name:'林茜',company:'云间设计',email:'lin.qian@example.com',phone:'+86 138 0000 0000',relations:['同事','朋友'],color:'blue',sources:[['产品方向讨论','11月2日 · 09:40','03:20–04:08','先把一个流程做好，再看下一步该往哪里走。'],['周五的项目复盘','10月30日 · 15:00','12:10–12:46','用户需要的是能接着上次继续，而不是每次从头再来。']]},
    {id:'p2',name:'陈亦舟',company:'青禾工作室',relations:['同学','朋友'],color:'green',sources:[['午后的咖啡聊天','11月1日 · 14:30','05:18–06:02','那个想法可以先做一个很小的实验，找两个人试试看。']]},
    {id:'p3',name:'妈妈',company:'',relations:['家人'],color:'rose',sources:[['周末聊聊近况','10月31日 · 19:20','02:30–03:11','周末有空一起吃个饭，最近天气很好。']]},
    {id:'p4',name:'周予安',company:'拾光书店',relations:['客户'],color:'blue',sources:[['书店活动沟通','10月29日 · 11:00','08:45–09:23','希望大家来参加活动时，也能带走一个自己的新想法。']]}
  ];
  const makePlaces = () => [
    {id:'home',name:'家',address:'青禾里 · 住宅区',type:'家',symbol:'home'},
    {id:'office',name:'公司',address:'云间大厦 · 办公区',type:'公司',symbol:'office'},
    {id:'cafe',name:'梧桐路附近',address:'梧桐路 · 地址已归组',type:'',symbol:'pin'},
    {id:'park',name:'河畔公园',address:'河畔公园 · 南门附近',type:'公园',symbol:'tree'}
  ];
  function makeOccurrences(){
    const data=[], days=['12','13','14','15','16','19','20','21','22','23','26','27'];
    function add(place,date,time){const id=`loc-${data.length}`;data.push({id,place,date,time,media:[{kind:'录音',title:place==='home'?'在家随手录下的事':place==='office'?'项目讨论录音':'路上的随手记录'},...(data.length%2===0?[{kind:'照片',title:'随手拍下的一张照片'}]:[])]});}
    days.forEach(d=>{add('home',`2026-10-${d}`,'07:45');add('office',`2026-10-${d}`,'09:30');add('home',`2026-10-${d}`,'20:10');});
    ['05','06','07','08','09','28'].forEach(d=>add('office',`2026-10-${d}`,'11:20'));
    ['10','14','17','21','24','31'].forEach(d=>add('cafe',`2026-10-${d}`,'14:15'));
    ['10','17','24','31'].forEach(d=>add('park',`2026-10-${d}`,'16:40'));
    return data;
  }
  const defaultRelations=['家人','同事','同学','朋友','客户','路人','其他'];
  let ideas=makeIdeas(),money=makeMoney(),people=makePeople(),places=makePlaces(),occurrences=makeOccurrences();
  // In the main app, use the original flash records for these examples.
  if(getFlashEntries){ideas=ideas.filter(i=>!['i1','i3'].includes(i.id));money=money.filter(m=>!['m1','m2','m7'].includes(m.id));}
  const state={tab:['ideas','money','people','places'].includes(location.hash.slice(1))?location.hash.slice(1):'ideas',selecting:false,selected:new Set(),month:'2026-11',currency:'CNY',moneyFilter:'all',relationFilter:'全部',empty:false,seq:50};
  let modal=null,returnFocus=null,generation=0,aiDraft={prompt:'',ids:[],candidates:[],saved:false},toastTimer;
  const displayDate=d=>`${Number(d.slice(5,7))}月${Number(d.slice(8,10))}日`;
  const amount=n=>new Intl.NumberFormat('zh-CN',{minimumFractionDigits:2,maximumFractionDigits:2}).format(n/100);
  const symbol=()=>state.currency==='CNY'?'¥':'$';
  const byID=(list,id)=>list.find(x=>x.id===id);
  const sourceIcon=idea=>icon(idea.origin==='闪念'?'mic':idea.origin==='AI 再创作'?'spark':'pen');
  function toast(text){clearTimeout(toastTimer);$('nbToast').textContent=text;$('nbToast').hidden=false;toastTimer=setTimeout(()=>$('nbToast').hidden=true,2400);}
  function empty(iconName,title,text,action){return `<div class="nb-empty">${icon(iconName)}<h3>${title}</h3><p>${text}</p>${action||''}</div>`;}
  function render(){
    const t=tabs[state.tab];$('nbTitle').textContent=t.label;$('nbSubtitle').textContent=t.subtitle;
    $('nbTabs').innerHTML=Object.entries(tabs).map(([key,v])=>`<button id="nb-tab-${key}" role="tab" data-tab="${key}" aria-controls="nbContent" aria-selected="${state.tab===key}" tabindex="${state.tab===key?0:-1}">${v.label}</button>`).join('');
    $('nbContent').setAttribute('aria-labelledby',`nb-tab-${state.tab}`);
    $('nbAdd').innerHTML=icon('plus');$('nbAdd').hidden=state.tab==='places';$('nbAdd').setAttribute('aria-label',`新建${state.tab==='people'?'联系人':t.label}`);
    $('nbSelect').hidden=state.tab!=='ideas';$('nbSelect').textContent=state.selecting?'完成':'选择';
    document.querySelectorAll('.nb-chapters [data-tab]').forEach(b=>b.setAttribute('aria-current',String(b.dataset.tab===state.tab)));
    if($('nbReviewTitle')){$('nbReviewTitle').textContent=t.review;$('nbReviewText').textContent=t.text;$('nbReviewFlow').innerHTML=t.steps.map(s=>`<span>${s}</span>`).join('');}
    $('nbContent').innerHTML=state.empty?empty(t.icon,`还没有${t.label}`,{ideas:'主动录下一条闪念，<br>或者写下此刻的想法。',money:'记下一笔收入或支出，<br>每月收支会在这里汇总。',people:'在录音中为说话人关联联系人，<br>也可以先添加一个人。',places:'有地点记录后，<br>这里会按出现天数整理常去的地方。'}[state.tab],state.tab==='places'?'':`<button class="nb-secondary" data-action="new">${icon('plus')}添加${state.tab==='people'?'联系人':t.label}</button>`):({ideas:renderIdeas,money:renderMoney,people:renderPeople,places:renderPlaces}[state.tab])();
    $('nbDock').hidden=!(state.tab==='ideas'&&state.selecting&&!state.empty);
    $('nbDock').innerHTML=`<span>已选 ${state.selected.size} 条</span><button class="nb-primary" data-action="ai-start" ${state.selected.size<2?'disabled':''}>${icon('spark')}用 AI 发展想法</button>`;
    $('nbEmpty')?.setAttribute('aria-pressed',String(state.empty));
  }
  function renderIdeas(){return `<div class="nb-section-heading"><h3>${state.selecting?'选择想一起发展的灵感':'最近留下的想法'}</h3><span>${ideas.length} 条</span></div>${ideas.map(i=>`<button class="nb-idea" data-action="${state.selecting?'idea-select':'idea-open'}" data-id="${i.id}" ${state.selecting?`aria-pressed="${state.selected.has(i.id)}" aria-label="选择灵感：${esc(i.title)}"`:''}>${state.selecting?`<span class="nb-check">${state.selected.has(i.id)?icon('check'):''}</span>`:''}<span class="nb-idea-copy"><strong class="nb-idea-title">${esc(i.title)}</strong><span class="nb-idea-body">${esc(i.body)}</span><span class="nb-item-meta">${sourceIcon(i)}<span>${displayDate(i.date)} ${i.time}</span><span class="nb-dot"></span><span>${esc(i.origin)}</span>${i.origin==='AI 再创作'?'<span class="nb-mini-tag">新想法</span>':''}</span></span></button>`).join('')}<p class="nb-caption">主动记录的想法，慢慢积累。<br>普通长录音不会自动加入灵感。</p>${aiDraft.candidates.length&&!aiDraft.saved?'<button class="nb-text-button" data-action="ai-resume">继续上次的再创作草稿 →</button>':''}`;}
  function monthRows(){return money.filter(m=>m.date.startsWith(state.month)&&m.currency===state.currency);}
  function renderMoney(){
    const rows=monthRows(),ready=rows.filter(m=>m.ready),spend=ready.filter(m=>m.direction==='expense').reduce((n,m)=>n+m.amount,0),income=ready.filter(m=>m.direction==='income').reduce((n,m)=>n+m.amount,0);
    const shown=rows.filter(m=>state.moneyFilter==='pending'?!m.ready:state.moneyFilter==='all'?true:m.direction===state.moneyFilter&&m.ready).sort((a,b)=>b.date.localeCompare(a.date));
    let last='';const list=shown.map(m=>{const day=last!==m.date?`<h4 class="nb-ledger-day">${displayDate(m.date)}</h4>`:'';last=m.date;return `${day}<button class="nb-ledger-row" data-action="money-edit" data-id="${m.id}"><span class="nb-tile">${icon(({餐饮:'food',交通:'car',购物:'shop',居住:'home'})[m.category]||'wallet')}</span><span class="nb-ledger-copy"><strong>${esc(m.title)}</strong><small>${esc(m.category)} · ${m.ready?'已记录':'待补充'}</small></span>${m.ready?`<span class="nb-amount ${m.direction}">${m.direction==='income'?'+':'−'}${amount(m.amount)}</span>`:'<span class="nb-pending">补金额</span>'}</button>`;}).join('');
    return `<div class="nb-month"><button class="nb-icon-button" data-action="month-prev" aria-label="上个月">${icon('left')}</button><strong>${state.month.slice(0,4)} 年 ${Number(state.month.slice(5))} 月</strong><button class="nb-icon-button" data-action="month-next" aria-label="下个月" ${state.month==='2026-11'?'disabled':''}>${icon('chevron')}</button></div><div class="nb-money-summary"><span>本月已记录支出</span><strong class="nb-money-main"><small>${symbol()}</small>${amount(spend)}</strong><div class="nb-money-columns"><div><span>收入</span><strong class="income">${symbol()}${amount(income)}</strong></div><div><span>结余</span><strong>${symbol()}${amount(income-spend)}</strong></div></div></div><div class="nb-currency"><span>待补充的账目不计入汇总</span><select id="nbCurrency" aria-label="查看币种"><option value="CNY" ${state.currency==='CNY'?'selected':''}>人民币 CNY</option><option value="USD" ${state.currency==='USD'?'selected':''}>美元 USD</option></select></div><div class="nb-filters" aria-label="账目筛选">${[['all','全部'],['expense','支出'],['income','收入'],['pending',`待补充${rows.filter(m=>!m.ready).length?' · '+rows.filter(m=>!m.ready).length:''}`]].map(([k,v])=>`<button data-action="money-filter" data-id="${k}" aria-pressed="${state.moneyFilter===k}">${v}</button>`).join('')}</div>${list||'<p class="nb-hint">这个月份没有符合条件的账目。</p>'}`;
  }
  function renderPeople(){const list=people.filter(p=>state.relationFilter==='全部'||p.relations.includes(state.relationFilter));return `<div class="nb-section-heading"><h3>在生活里，留下交集的人</h3><span>${people.length} 人</span></div><div class="nb-filters" aria-label="人物关系筛选">${['全部',...new Set(people.flatMap(p=>p.relations))].map(r=>`<button data-action="person-filter" data-id="${esc(r)}" aria-pressed="${state.relationFilter===r}">${esc(r)}</button>`).join('')}</div>${list.map(p=>`<button class="nb-person" data-action="person-open" data-id="${p.id}"><span class="nb-avatar" data-color="${p.color}">${esc(p.name[0])}</span><span class="nb-person-main"><strong>${esc(p.name)}</strong><span class="nb-tags">${p.relations.map(r=>`<span class="nb-tag">${esc(r)}</span>`).join('')||'<span class="nb-tag">关系未设置</span>'}</span><p>${p.sources.length?`${p.sources.length} 段关联录音 · 最近 ${esc(p.sources[0][1].split(' · ')[0])}`:'尚未关联录音'}</p></span><span class="nb-chevron">${icon('chevron')}</span></button>`).join('')}<p class="nb-caption">来自录音中已绑定的联系人，<br>以及你主动添加的人。</p>`;}
  const placeName=id=>byID(places,id)?.name||'未标记地点';
  // Prototype dates are original local calendar dates; no UTC re-interpretation.
  function placeDays(id){
    const days=new Map();
    occurrences.filter(e=>e.place===id&&e.date>='2026-10-05'&&e.date<='2026-11-03').forEach(e=>{
      if(!days.has(e.date))days.set(e.date,[]);
      days.get(e.date).push(e);
    });
    return [...days].sort(([a],[b])=>b.localeCompare(a)).map(([date,records])=>({date,records:records.sort((a,b)=>a.time.localeCompare(b.time))}));
  }
  function renderPlaces(){
    const ordered=places.map(p=>({...p,count:placeDays(p.id).length})).sort((a,b)=>b.count-a.count),max=Math.max(1,...ordered.map(p=>p.count));
    return `<div class="nb-section-heading"><h3>高频地点</h3><span>近 30 天 · 按天去重</span></div>${ordered.map(p=>`<button class="nb-place" data-action="place-open" data-id="${p.id}"><span class="nb-tile">${icon(p.symbol)}</span><span class="nb-place-body"><strong>${esc(p.name)}</strong><p>${esc(p.address)}</p><span class="nb-place-bar"><span style="width:${p.count/max*100}%"></span></span>${!p.type?`<span class="nb-mark">${icon('pen')}标记这个地点</span>`:''}</span><span class="nb-place-count">${p.count}<small>次出现</small></span></button>`).join('')}<p class="nb-caption">同一地点，每天最多记 1 次。</p>`;
  }
  function showSheet(title,html,data={}){if($('nbOverlay').hidden){returnFocus=document.activeElement;$('nbApp').inert=true;onModal(true);}$('nbSheetTitle').textContent=title;$('nbSheetBody').innerHTML=html;$('nbSheetBody').scrollTop=0;$('nbOverlay').hidden=false;modal=data;$('nbOverlay').querySelector('.nb-sheet').focus();}
  function closeSheet(){generation++;$('nbOverlay').hidden=true;$('nbApp').inert=false;onModal(false);modal=null;if(returnFocus?.isConnected)returnFocus.focus();else $('nbTitle').focus();}
  function switchTab(tab){if(!tabs[tab])return;closeSheet();state.tab=tab;state.selecting=false;state.selected.clear();state.empty=false;if(root===document)location.hash=tab;render();$('nbContent').scrollTop=0;}
  function openIdea(id){const i=byID(ideas,id);if(!i)return;showSheet('灵感',`<div class="nb-item-meta">${sourceIcon(i)}${esc(i.origin)} · ${displayDate(i.date)} ${i.time}</div><h4>${esc(i.title)}</h4><p class="nb-prose">${esc(i.body)}</p>${i.quote?`<div class="nb-source-box"><small>录下时的原话 · ${esc(i.device)}</small><p>${esc(i.quote)}</p></div>`:''}${i.parents?`<div class="nb-section-heading"><h3>由这些灵感发展而来</h3></div>${i.parents.map(x=>`<button class="nb-source-button" data-action="idea-open" data-id="${x.id}">${esc(x.title)}${icon('chevron')}</button>`).join('')}`:''}<div class="nb-footer-actions"><button class="nb-secondary" data-action="idea-edit" data-id="${id}">${icon('pen')}编辑</button><button class="nb-primary" data-action="select-from" data-id="${id}">${icon('spark')}与其他灵感组合</button></div>`,{kind:'idea',id});}
  function editIdea(id){const i=byID(ideas,id)||{title:'',body:''};showSheet(id?'编辑灵感':'写下一个想法',`<form id="nbIdeaForm"><label class="nb-field">标题<input name="title" value="${esc(i.title)}" placeholder="给这个想法一个名字" maxlength="70" required></label><label class="nb-field">想法<textarea name="body" rows="6" required placeholder="想到什么，就写下来。">${esc(i.body)}</textarea></label>${i.quote?'<p class="nb-hint">编辑灵感会保留录下时的原话。</p>':''}<div class="nb-footer-actions"><button type="button" class="nb-secondary" data-action="close">取消</button><button class="nb-primary" type="submit">保存灵感</button></div></form>`,{kind:'idea-edit',id});}
  function startAI(){const ids=[...state.selected];if(ids.length<2)return;aiDraft={ids,prompt:'',candidates:[],saved:false};aiForm();}
  function aiForm(){showSheet('用 AI 发展想法',`<p class="nb-hint">把选中的想法放在一起，看看会长出什么。</p><div class="nb-selected-list">${aiDraft.ids.map(id=>`<span>${esc(byID(ideas,id).title)}</span>`).join('')}</div><form id="nbAIForm"><label class="nb-field">想往哪个方向发展？<textarea name="prompt" id="nbAIPrompt" rows="3" placeholder="例如：组合成一个本周可以尝试的小方案" required>${esc(aiDraft.prompt)}</textarea></label><div class="nb-choice-list">${['寻找共同点','组合成一个小方案','提出不同角度'].map(x=>`<button type="button" data-action="ai-prompt" data-value="${x}">${x}</button>`).join('')}</div><p class="nb-caption">仅使用选中的灵感。生成结果为演示。</p><div class="nb-footer-actions"><button type="button" class="nb-secondary" data-action="close">取消</button><button type="submit" class="nb-primary">${icon('spark')}生成新想法</button></div></form>`,{kind:'ai-form'});}
  function runAI(){const token=++generation;showSheet('正在发展想法',`<div class="nb-loading"><div class="nb-spinner"></div><h4>在想法之间，寻找新的联系</h4><p>正在结合 ${aiDraft.ids.length} 条灵感<br>方向：${esc(aiDraft.prompt)}</p></div><button class="nb-secondary nb-wide" data-action="close">取消生成</button>`,{kind:'ai-loading'});setTimeout(()=>{if(token!==generation)return;if($('nbFailAI')?.checked){$('nbFailAI').checked=false;showSheet('这次没有生成成功',`<div class="nb-empty">${icon('info')}<h3>连接暂时中断</h3><p>选中的灵感与输入方向已保留。<br>原来的想法没有变化。</p><button class="nb-primary" data-action="ai-retry">重试生成</button></div>`,{kind:'ai-error'});return;}const selected=aiDraft.ids.map(id=>byID(ideas,id));aiDraft.candidates=[{title:'把想法连成一个小实验',body:`围绕“${aiDraft.prompt}”，先从“${selected[0].title}”和“${selected[1].title}”各取一个最小步骤，组合成一次可以在本周完成的尝试。先观察实际反馈，再决定是否继续。`},{title:'给这些想法一个共同的问题',body:`把这 ${selected.length} 条想法放在一起，问自己：它们都想改善哪一个具体时刻？以“${aiDraft.prompt}”为方向，写下一个共同问题，保留不同答案，下次回看时再补充。`},{title:'从相反的方向再想一次',body:`暂时拿掉“${selected[0].title}”中的一个前提，再结合其余想法，尝试提出不同做法。沿着“${aiDraft.prompt}”继续追问：有没有更简单、更适合自己的方式？`}];aiResults();},900);}
  function aiResults(){showSheet('新的想法',`<p class="nb-hint">选中想留下的内容，另存为新的灵感。原有灵感保持不变。</p><form id="nbAIResults">${aiDraft.candidates.map((c,n)=>`<label class="nb-candidate"><span><input type="checkbox" name="candidate" value="${n}" ${n===0?'checked':''}>${esc(c.title)}</span><p>${esc(c.body)}</p></label>`).join('')}<p class="nb-caption">AI 再创作 · 示例结果，可保存后继续编辑。</p><div class="nb-footer-actions"><button type="button" class="nb-secondary" data-action="ai-revise">调整方向</button><button type="submit" class="nb-primary" id="nbSaveCandidates">保存 1 条灵感</button></div></form>`,{kind:'ai-results'});}
  function editMoney(id){const m=byID(money,id)||{title:'',direction:'expense',amount:null,currency:state.currency,date:'2026-11-03',category:'餐饮'};showSheet(id?'编辑账目':'记一笔',`<form id="nbMoneyForm"><div class="nb-field-row"><label class="nb-field">类型<select name="direction"><option value="expense" ${m.direction==='expense'?'selected':''}>支出</option><option value="income" ${m.direction==='income'?'selected':''}>收入</option></select></label><label class="nb-field">币种<select name="currency"><option value="CNY" ${m.currency==='CNY'?'selected':''}>人民币 CNY</option><option value="USD" ${m.currency==='USD'?'selected':''}>美元 USD</option></select></label></div><label class="nb-field">金额<input name="amount" inputmode="decimal" type="text" value="${m.amount===null?'':(m.amount/100).toFixed(2)}" placeholder="0.00" required pattern="[0-9]+([.][0-9]{1,2})?"></label><label class="nb-field">说明<input name="title" value="${esc(m.title)}" required maxlength="70"></label><div class="nb-field-row"><label class="nb-field">发生日期<input type="date" name="date" value="${m.date}" required max="2026-11-03"></label><label class="nb-field">分类<input name="category" value="${esc(m.category)}" required maxlength="20"></label></div><p class="nb-hint">按发生日期计入月份。保存后同步更新收支。</p><p id="nbMoneyError" class="nb-validation" hidden></p><div class="nb-footer-actions"><button type="button" class="nb-secondary" data-action="close">取消</button><button type="submit" class="nb-primary">保存账目</button></div></form>`,{kind:'money-edit',id});}
  function openPerson(id){const p=byID(people,id);showSheet('人物',`<div class="nb-person-detail"><span class="nb-avatar" data-color="${p.color}">${esc(p.name[0])}</span><div><h4>${esc(p.name)}</h4><p>${esc(p.company)||'未填写公司或组织'}</p><div class="nb-tags">${p.relations.map(r=>`<span class="nb-tag">${esc(r)}</span>`).join('')||'<span class="nb-tag">关系未设置</span>'}</div></div></div><dl class="nb-contact-info"><div><dt>邮箱</dt><dd>${esc(p.email)||'未填写'}</dd></div><div><dt>手机号</dt><dd>${esc(p.phone)||'未填写'}</dd></div></dl><button class="nb-secondary nb-wide" data-action="person-edit" data-id="${id}">${icon('pen')}编辑联系人</button><div class="nb-section-heading" style="margin-top:27px"><h3>关联的发言</h3><span>${p.sources.length} 段录音</span></div>${p.sources.map((s,n)=>`<button class="nb-source-button" data-action="speech" data-id="${id}" data-index="${n}"><span>${esc(s[0])}<small>${esc(s[1])} · ${esc(s[2])}</small></span>${icon('chevron')}</button>`).join('')||'<p class="nb-hint">在录音全文中，将说话人绑定到这位联系人后，相关发言会显示在这里。</p>'}<p class="nb-caption">只聚合明确绑定给这个人的发言。</p>`,{kind:'person',id});}
  function relationshipSummary(relations){return relations.size?[...relations].map(r=>`<span class="nb-relation-chip">${esc(r)}</span>`).join(''):'<span class="nb-field-placeholder">选择与我的关系</span>';}
  function updateRelationshipSummary(){$('nbRelationSummary').innerHTML=relationshipSummary(modal.relations);}
  function addRelationship(){
    const input=$('nbCustomRelation'),value=input.value.trim();if(!value){input.focus();return;}
    modal.relations.add(value);
    const match=[...$('nbRelationships').querySelectorAll('button')].find(b=>b.dataset.value===value);
    if(match)match.setAttribute('aria-pressed','true');
    else $('nbRelationships').insertAdjacentHTML('beforeend',`<button type="button" data-action="relation-toggle" data-value="${esc(value)}" aria-pressed="true">${esc(value)}</button>`);
    input.value='';updateRelationshipSummary();input.focus();
    $('nbRelationFeedback').textContent=match?`已选择“${value}”`:`已添加并选择“${value}”`;
  }
  function editPerson(id){
    const person=byID(people,id)||{name:'',company:'',email:'',phone:'',relations:[]};
    const selected=new Set(person.relations),relations=[...new Set([...defaultRelations,...people.flatMap(p=>p.relations)])];
    showSheet(id?'编辑联系人':'添加联系人',`<form id="nbPersonForm" class="nb-contact-form">
      <label class="nb-contact-field"><span class="nb-field-heading">姓名<small>必填</small></span><input name="name" autocomplete="name" value="${esc(person.name)}" placeholder="怎么称呼这个人" required maxlength="50"></label>
      <label class="nb-contact-field"><span class="nb-field-heading">公司</span><input name="company" autocomplete="organization" value="${esc(person.company)}" placeholder="公司或组织名称" maxlength="70"></label>
      <label class="nb-contact-field"><span class="nb-field-heading">邮箱</span><input name="email" type="email" autocomplete="email" inputmode="email" autocapitalize="none" spellcheck="false" value="${esc(person.email)}" placeholder="name@example.com" maxlength="254"></label>
      <label class="nb-contact-field"><span class="nb-field-heading">手机号</span><input name="phone" type="tel" autocomplete="tel" value="${esc(person.phone)}" placeholder="手机号，可含国家或地区代码" maxlength="40"></label>
      <div class="nb-contact-field"><div class="nb-field-heading"><span id="nbRelationshipLabel">关系</span><small>可多选</small></div>
        <details class="nb-relationship-picker"><summary aria-labelledby="nbRelationshipLabel nbRelationSummary"><span id="nbRelationSummary">${relationshipSummary(selected)}</span>${icon('chevron')}</summary>
          <div class="nb-relationship-options"><div class="nb-choice-list" id="nbRelationships" role="group" aria-label="关系选项">${relations.map(r=>`<button type="button" data-action="relation-toggle" data-value="${esc(r)}" aria-pressed="${selected.has(r)}">${esc(r)}</button>`).join('')}</div>
          <div class="nb-custom-relation"><input id="nbCustomRelation" aria-label="新的关系选项" placeholder="添加关系选项，如：跑友" maxlength="20"><button type="button" data-action="relation-add">添加</button></div><p id="nbRelationFeedback" class="nb-relation-feedback" role="status" aria-live="polite">可同时选择多个关系，也可以添加新选项。</p></div>
        </details>
      </div>
      <div class="nb-footer-actions"><button type="button" class="nb-secondary" data-action="close">取消</button><button type="submit" class="nb-primary">保存联系人</button></div>
    </form>`,{kind:'person-edit',id,relations:selected});
  }
  function openPlace(id){
    const p=byID(places,id),days=placeDays(id);
    showSheet('地点',`<div class="nb-person-detail"><span class="nb-tile">${icon(p.symbol)}</span><div><h4>${esc(p.name)}</h4><p>${esc(p.address)}</p></div></div><button class="nb-secondary nb-wide" data-action="place-edit" data-id="${id}">${icon('pen')}${p.type?'修改名称与类型':'标记这个地点'}</button><div class="nb-place-stat"><strong>${days.length}<small> 次</small></strong><span>近 30 天出现 · 同一天只记 1 次</span></div><div class="nb-section-heading"><h3>出现日期</h3><span>按天合并</span></div>${days.map(day=>`<button class="nb-source-button" data-action="place-day" data-id="${id}" data-date="${day.date}"><span>${displayDate(day.date)}<small>${day.records.reduce((n,e)=>n+e.media.length,0)} 条来源记录 · 计 1 次</small></span>${icon('chevron')}</button>`).join('')}`,{kind:'place',id});
  }
  function openPlaceDay(id,date){
    const day=placeDays(id).find(d=>d.date===date);if(!day)return;
    showSheet('当天的地点记录',`<h4>${esc(placeName(id))}</h4><p class="nb-hint">${displayDate(day.date)} · 当天共计 1 次出现</p>${day.records.flatMap(e=>e.media.map(m=>`<div class="nb-source-box"><small>${e.time} · ${esc(m.kind)}</small><p>${esc(m.title)}</p></div>`)).join('')}<p class="nb-hint">同一天多次出现、产生多条记录，都只计 1 次。</p><button class="nb-secondary nb-wide" data-action="place-open" data-id="${id}">返回地点</button>`,{kind:'place-day',id,date});
  }
  function editPlace(id){const p=byID(places,id);showSheet('标记地点',`<p class="nb-hint">${esc(p.address)}<br>给这个地方一个你熟悉的名字。</p><form id="nbPlaceForm"><label class="nb-field">地点名称<input name="name" value="${p.type?esc(p.name):''}" placeholder="例如：家、公司、梧桐咖啡" maxlength="40" required></label><label class="nb-field">地点类型</label><div class="nb-choice-list">${['家','公司','学校','商场','餐厅','咖啡馆','公园','健身房','其他'].map(t=>`<button type="button" data-action="place-type" data-value="${t}" aria-pressed="${p.type===t}">${t}</button>`).join('')}</div><p class="nb-hint">已有记录会沿用这个名称，出现次数不变。</p><p id="nbPlaceError" class="nb-validation" hidden>请选择一个地点类型。</p><div class="nb-footer-actions"><button type="button" class="nb-secondary" data-action="close">取消</button><button type="submit" class="nb-primary">保存地点</button></div></form>`,{kind:'place-edit',id,type:p.type});}
  root.addEventListener('click',event=>{
    const b=event.target.closest('button,a');if(!b)return;
    if(b.dataset.tab){switchTab(b.dataset.tab);return;}
    const {action,id,value}=b.dataset;if(!action)return;
    if(action==='close'){closeSheet();return;}
    if(action==='theme'){const dark=document.documentElement.dataset.appearance!=='dark';document.documentElement.dataset.appearance=dark?'dark':'light';$('nbTheme').textContent=dark?'切换浅色外观':'切换深色外观';return;}
    if(action==='compact'){const v=document.body.classList.toggle('nb-compact');$('nbCompact').setAttribute('aria-pressed',String(v));$('nbCompact').textContent=v?'恢复标准宽度 · 430 px':'查看窄屏 · 360 px';return;}
    if(action==='empty'){closeSheet();state.empty=!state.empty;state.selected.clear();state.selecting=false;render();return;}
    if(action==='reset'){closeSheet();ideas=makeIdeas();money=makeMoney();people=makePeople();places=makePlaces();occurrences=makeOccurrences();state.empty=false;state.selected.clear();state.selecting=false;state.moneyFilter='all';state.relationFilter='全部';state.month='2026-11';state.currency='CNY';aiDraft={ids:[],prompt:'',candidates:[],saved:false};render();toast('示例数据已重置');return;}
    if(action==='new'){if(state.tab==='ideas')editIdea();if(state.tab==='money')editMoney();if(state.tab==='people')editPerson();return;}
    if(action==='select'){state.selecting=!state.selecting;state.selected.clear();render();return;}
    if(action==='idea-select'){state.selected.has(id)?state.selected.delete(id):state.selected.add(id);const scroll=$('nbContent').scrollTop;render();$('nbContent').scrollTop=scroll;$('nbContent').querySelector(`[data-id="${id}"]`)?.focus({preventScroll:true});return;}
    if(action==='idea-open'){openIdea(id);return;}if(action==='idea-edit'){editIdea(id);return;}
    if(action==='select-from'){closeSheet();state.selecting=true;state.selected=new Set([id]);render();return;}
    if(action==='ai-start'){startAI();return;}if(action==='ai-resume'){aiResults();return;}if(action==='ai-revise'){aiForm();return;}if(action==='ai-retry'){runAI();return;}
    if(action==='ai-prompt'){$('nbAIPrompt').value=value;$('nbAIPrompt').focus();return;}
    if(action==='month-prev'||action==='month-next'){const [y,m]=state.month.split('-').map(Number),date=new Date(Date.UTC(y,m-1+(action==='month-next'?1:-1),1));state.month=date.toISOString().slice(0,7);render();return;}
    if(action==='money-filter'){state.moneyFilter=id;render();return;}if(action==='money-edit'){editMoney(id);return;}
    if(action==='person-filter'){state.relationFilter=id;render();return;}if(action==='person-open'){openPerson(id);return;}if(action==='person-edit'){editPerson(id);return;}
    if(action==='relation-toggle'){modal.relations.has(value)?modal.relations.delete(value):modal.relations.add(value);b.setAttribute('aria-pressed',String(modal.relations.has(value)));updateRelationshipSummary();return;}
    if(action==='relation-add'){addRelationship();return;}
    if(action==='speech'){const p=byID(people,id),s=p.sources[Number(b.dataset.index)];showSheet('关联发言',`<div class="nb-item-meta">${icon('mic')}${esc(s[0])}</div><h4>${esc(p.name)}</h4><p class="nb-hint">${esc(s[1])} · ${esc(s[2])}</p><p class="nb-prose">${esc(s[3])}</p><div class="nb-source-box"><small>录音中的说话人已绑定为 ${esc(p.name)}</small><p>这段发言保留原始时间范围。示例不播放真实录音。</p></div><button class="nb-secondary nb-wide" data-action="person-open" data-id="${id}">返回人物</button>`,{kind:'speech'});return;}
    if(action==='place-open'){openPlace(id);return;}if(action==='place-edit'){editPlace(id);return;}if(action==='place-day'){openPlaceDay(id,b.dataset.date);return;}
    if(action==='place-type'){modal.type=value;document.querySelectorAll('[data-action="place-type"]').forEach(x=>x.setAttribute('aria-pressed',String(x===b)));return;}
  });
  root.addEventListener('submit',event=>{
    const form=event.target;if(!form.id.startsWith('nb'))return;event.preventDefault();const data=Object.fromEntries(new FormData(form));
    if(form.id==='nbIdeaForm'){if(!data.title.trim()||!data.body.trim())return;const id=modal.id,i=id?byID(ideas,id):{id:`i${++state.seq}`,date:'2026-11-03',time:'09:41',origin:'手动记录',quote:''};i.title=data.title.trim();i.body=data.body.trim();if(!id)ideas.unshift(i);if(i.flashID)saveFlashEntry?.(i.flashID,{title:i.title,content:i.body});state.empty=false;render();openIdea(i.id);toast('灵感已保存');}
    if(form.id==='nbAIForm'){aiDraft.prompt=data.prompt.trim();if(aiDraft.prompt)runAI();}
    if(form.id==='nbAIResults'){const choices=new FormData(form).getAll('candidate').map(Number);if(!choices.length)return;const parents=aiDraft.ids.map(id=>({id,title:byID(ideas,id).title}));choices.reverse().forEach(n=>ideas.unshift({id:`i${++state.seq}`,...aiDraft.candidates[n],date:'2026-11-03',time:'09:41',origin:'AI 再创作',parents,quote:''}));aiDraft.saved=true;state.selecting=false;state.selected.clear();closeSheet();render();$('nbContent').scrollTop=0;toast(`已保存 ${choices.length} 条新灵感，原灵感保留`);}
    if(form.id==='nbMoneyForm'){const parts=data.amount.trim().split('.'),minor=Number(parts[0])*100+Number((parts[1]||'').padEnd(2,'0'));if(!/^\d+(\.\d{1,2})?$/.test(data.amount.trim())||!Number.isSafeInteger(minor)||minor<=0||!data.title.trim()||!data.category.trim()){$('nbMoneyError').textContent='请填写有效说明、分类与大于 0 的金额（最多两位小数）。';$('nbMoneyError').hidden=false;return;}const existing=byID(money,modal.id);const entry={id:existing?.id||`m${++state.seq}`,title:data.title.trim(),direction:data.direction,amount:minor,currency:data.currency,date:data.date,category:data.category.trim(),ready:true};if(existing){Object.assign(existing,entry);if(existing.flashID)saveFlashEntry?.(existing.flashID,{...entry,amount:(minor/100).toFixed(2),status:'ready'});}else money.unshift(entry);state.month=data.date.slice(0,7);state.currency=data.currency;state.moneyFilter='all';state.empty=false;closeSheet();render();toast('账目已保存，本月收支已更新');}
    if(form.id==='nbPersonForm'){if(!data.name.trim())return;const existing=byID(people,modal.id),p=existing||{id:`p${++state.seq}`,sources:[],color:'blue'};p.name=data.name.trim();p.company=data.company.trim();p.email=data.email.trim();p.phone=data.phone.trim();p.relations=[...modal.relations];if(!existing)people.unshift(p);state.empty=false;state.relationFilter='全部';render();openPerson(p.id);toast('联系人已保存');}
    if(form.id==='nbPlaceForm'){if(!modal.type){$('nbPlaceError').hidden=false;return;}if(!data.name.trim())return;const p=byID(places,modal.id);p.name=data.name.trim();p.type=modal.type;p.symbol=({家:'home',公司:'office',学校:'school',商场:'shop',咖啡馆:'coffee',餐厅:'food',公园:'tree'})[p.type]||'pin';render();openPlace(p.id);toast('地点标记已保存');}
  });
  root.addEventListener('change',event=>{if(event.target.id==='nbCurrency'){state.currency=event.target.value;render();}if(event.target.name==='candidate'){const count=$('nbAIResults').querySelectorAll('input:checked').length;$('nbSaveCandidates').disabled=!count;$('nbSaveCandidates').textContent=`保存 ${count} 条灵感`;}});
  root.addEventListener('keydown',event=>{
    if(event.target.id==='nbCustomRelation'&&event.key==='Enter'&&!event.isComposing){event.preventDefault();addRelationship();return;}
    if(!$('nbOverlay').hidden){if(event.key==='Escape'){event.preventDefault();closeSheet();return;}if(event.key==='Tab'){const nodes=[...$('nbOverlay').querySelectorAll('button:not(:disabled),input,textarea,select,a[href],summary')].filter(n=>!n.hidden&&n.getClientRects().length),first=nodes[0],last=nodes.at(-1);if(event.shiftKey&&(document.activeElement===first||document.activeElement.classList.contains('nb-sheet'))){event.preventDefault();last?.focus();}else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first?.focus();}}return;}
    const active=event.target.closest('#nbTabs [role="tab"]');if(active&&['ArrowRight','ArrowLeft','Home','End'].includes(event.key)){event.preventDefault();const keys=Object.keys(tabs),index=keys.indexOf(state.tab),next=event.key==='Home'?0:event.key==='End'?3:(index+(event.key==='ArrowRight'?1:3))%4;switchTab(keys[next]);$(`nb-tab-${keys[next]}`).focus();}
  });
  $('nbOverlay').addEventListener('click',event=>{if(event.target===$('nbOverlay'))closeSheet();});
  if(root===document)window.addEventListener('hashchange',()=>{const key=location.hash.slice(1);if(tabs[key]&&key!==state.tab)switchTab(key);});
  function syncFlashEntries(){
    if(!getFlashEntries)return;
    ideas=ideas.filter(i=>!i.flashID);money=money.filter(m=>!m.flashID);
    for(const a of getFlashEntries()){
      if(a.kind==='idea')ideas.push({id:`flash-${a.id}`,flashID:a.id,title:a.title,body:a.content,date:a.date,time:a.time,origin:'闪念',device:a.device,quote:a.quote});
      else money.push({id:`flash-${a.id}`,flashID:a.id,title:a.title,direction:a.direction||'expense',amount:a.status==='ready'?Math.round(Number(a.amount)*100):null,currency:a.currency||'CNY',date:a.date,category:a.category||'待分类',ready:a.status==='ready'});
    }
    ideas.sort((a,b)=>b.date.localeCompare(a.date)||b.time.localeCompare(a.time));
  }
  syncFlashEntries();render();
  return {open(tab='ideas'){syncFlashEntries();switchTab(tab);$('nbTitle').focus({preventScroll:true});},close:closeSheet};
  };
  if(document.body.classList.contains('notebook-review'))window.createDaybookNotebook();
})();
