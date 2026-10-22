/* Interactive concept: fictional records plus user-selected local images.
   No network, microphone, health, calendar, location or persistent storage APIs. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const esc = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const icon = name => `<svg class="icon" aria-hidden="true"><use href="#i-${name}"></use></svg>`;
  const TODAY = 19, NOW = 16.5;
  const sources = {
    health:{name:'Apple 健康',icon:'Heart',enabled:true,description:'步数、活动与睡眠',scope:'只读取你授权的步数、活动和睡眠，用来整理当天节奏。'},
    calendar:{name:'日历',icon:'CalendarDays',enabled:false,description:'为一天加上日程背景',scope:'读取所选日历的时间和标题，帮助你回顾一天的安排。'},
    places:{name:'地点',icon:'MapPin',enabled:true,description:'录音与照片的地点，随片段一起保存',scope:'为记录添加地点。你可以单独选择授权范围，也可以随时暂停。'}
  };
  const records = [
    {id:'merge-continuation',day:19,kind:'voice',start:16+24/60,end:16+34/60,time:'16:24',duration:600,title:'用户访谈 · 续录',preview:'继续记录对体验流程和首次使用的反馈。',source:'Apple Watch',summary:'模拟合并后的摘要：访谈中，用户谈到首次使用的步骤与主要疑问。',text:'模拟合并后的全文：\n\n第二段录音继续讨论体验流程和首次使用反馈。',tags:['访谈','续录']},
    {id:'merge-first',day:19,kind:'voice',start:16+18/60,end:16+30/60,time:'16:18',duration:720,title:'用户访谈 · 第一段',preview:'关于记录习惯、语音录制与回顾流程的访谈。',source:'Apple Watch',summary:'访谈先讨论记录习惯，再讨论语音录制和回顾流程。',text:'第一段录音示例：\n\n用户介绍了记录习惯，并分享了对语音录制和每日回顾的想法。',tags:['访谈','第一段']},
    {id:'review',day:19,kind:'voice',start:14,end:14+26/60,time:'14:00',duration:1560,title:'产品讨论：让记录更有用',preview:'先把录音和时间线做好，洞察要能回到原始记录。',source:'Apple Watch',summary:'先完成录音、转写和时间线的闭环。\n洞察需要能回到原始记录，让用户自己判断。\n下一步：列清首版范围，再讨论扩展数据源。',text:'我们先把录音和时间线做好。用户想回顾今天的时候，应该能找到具体发生的事情。\n\n每条洞察都要有依据，点进去能看到原始录音或文字。第一版不必做所有数据源，先把这个过程跑通。',tags:['产品讨论','1 个行动项']},
    {id:'walk-noon',day:19,kind:'activity',start:12.25,end:12.25+16/60,time:'12:15',duration:960,title:'午间走了走',preview:'12:15–12:31 记录到 16 分钟步行。',source:'Apple 健康',summary:'12:15 至 12:31，记录到 16 分钟步行。\n这里展示活动事实，不推断情绪或效率。',text:'来源：Apple 健康（示例）\n时间：12:15 至 12:31\n活动：步行 16 分钟',tags:['活动','16 分钟']},
    {id:'thought-noon',day:19,kind:'thought',start:11.3,end:11.3+48/3600,time:'11:18',duration:48,title:'先做小，再做好',preview:'“先把范围收小。每天只要有一条真的有用的建议，就够了。”',source:'Apple Watch',summary:'首版先收小范围。\n每天先提供一条有依据、有用的建议，再逐步丰富。',text:'刚才想了一下，先把范围收小。每天只要有一条真的有用的建议，就够了。不要一下子放十张卡片，让用户不知道该看什么。',tags:['闪念','做减法']},
    {id:'walk-intent',day:19,kind:'thought',start:11+50/60,end:11+51/60,time:'11:50',duration:60,title:'午休出去走走',preview:'“午休想出去走二十分钟，回来再把首版要做的事写清楚。”',source:'Apple Watch',summary:'午休想步行约二十分钟；回来后整理首版范围。',text:'午休想出去走二十分钟，回来再把首版要做的事写清楚。',tags:['闪念','计划']},
    {id:'walk-followup',day:19,kind:'thought',start:12+40/60,end:12+41/60,time:'12:40',duration:60,title:'走回来后的一句话',preview:'“刚才走了一圈，回来想先把首版范围收成三件事。”',source:'Apple Watch',summary:'在午间步行后，想把首版范围缩成三件事。',text:'刚才走了一圈，回来想先把首版范围收成三件事。',tags:['闪念','回顾']},
    {id:'meeting',day:19,kind:'voice',start:9+40/60,end:10+22/60,time:'09:40',duration:2520,title:'周一的项目碰头',preview:'确认本周目标，先验证最核心的使用路径。',source:'Apple Watch',summary:'本周优先验证录音、转写、回顾的完整路径。\n界面上让用户能看到同步状态和转写进度。\n周五回顾使用反馈。',text:'今天先对一下本周的目标。我们优先验证录音、转写和回顾的路径。先保证录下来的东西能可靠保存，再看整理得好不好用。\n\n周五把这周的反馈集中看一下。',tags:['项目','42 分钟']},
    {id:'thought-morning',day:19,kind:'thought',start:8.6,end:8.62,time:'08:36',duration:72,title:'路上想到的首版方向',preview:'“第一版先把范围收小，让用户回顾一天时，能找到最有用的那一刻。”',source:'Apple Watch',summary:'首版聚焦“回顾一天，找到有用片刻”。\n先把范围收小，完成可靠的记录和回顾。',text:'第一版先把范围收小，让用户回顾一天时，能找到最有用的那一刻。录音只是一个入口，最终还是要帮人记住真正重要的事情。',tags:['闪念','首版方向']},
    {id:'walk-morning',day:19,kind:'activity',start:8.2,end:8.5,time:'08:12',duration:1080,title:'步行开启一天',preview:'18 分钟，走到附近的咖啡店。',source:'Apple 健康',summary:'08:12 至 08:30 记录到 18 分钟步行。\n地点描述是手动补充示例，并非已读取定位。',text:'来源：Apple 健康（示例）\n活动：步行 18 分钟\n地点：附近的咖啡店（手动备注示例）',tags:['活动','18 分钟']},
    {id:'sleep',day:19,kind:'sleep',start:0,end:7.2,time:'00:00',duration:25920,title:'昨夜睡眠',preview:'00:00–07:12 的睡眠片段合计 7 小时 12 分钟。',source:'Apple 健康',summary:'今日 00:00 至 07:12 记录到 7 小时 12 分钟睡眠。\n不据单日时长判断睡眠质量。',text:'来源：Apple 健康（示例）\n开始：10月19日 00:00\n结束：10月19日 07:12\n时长：7 小时 12 分钟',tags:['睡眠','已汇总']},
    {id:'tired-19',day:19,kind:'thought',start:7+35/60,end:7+36/60,time:'07:35',duration:55,title:'醒来还是有点困',preview:'“今天醒来还是有点困，先慢慢开始。”',source:'Apple Watch',summary:'醒来后主动记录了有点困的感受。',text:'今天醒来还是有点困，先慢慢开始。',tags:['晨间','自述']},
    {id:'yesterday-note',day:18,kind:'voice',start:17.5,end:17.55,time:'17:30',duration:180,title:'给新的一周留一点空白',preview:'下周想把每天最重要的一件事先确定下来。',source:'Apple Watch',summary:'尝试在一天开始前，写下最重要的一件事。',text:'下周想把每天最重要的一件事先确定下来。不要一下子排得太满，也留一点能想事情的时间。',tags:['周末回顾','3 分钟']},
    {id:'yesterday-walk',day:18,kind:'activity',start:16,end:16.7,time:'16:00',duration:2520,title:'周日下午的散步',preview:'42 分钟步行，慢一点也很好。',source:'Apple 健康',summary:'16:00 至 16:42 记录到 42 分钟步行。',text:'来源：Apple 健康（示例）\n活动：步行 42 分钟',tags:['活动','42 分钟']},
    {id:'yesterday-sleep',day:18,kind:'sleep',start:0,end:7.8,time:'00:00',duration:28080,title:'昨夜睡眠',preview:'7 小时 48 分钟。',source:'Apple 健康',summary:'00:00 至 07:48 记录到睡眠。',text:'来源：Apple 健康（示例）\n时长：7 小时 48 分钟',tags:['睡眠']},
    {id:'tired-18',day:18,kind:'thought',start:8+2/60,end:8+3/60,time:'08:02',duration:48,title:'早上的身体感受',preview:'“今天醒来还是觉得困，想先留一点缓冲。”',source:'Apple Watch',summary:'醒来后主动记录了觉得困的感受。',text:'今天醒来还是觉得困，想先留一点缓冲。',tags:['晨间','自述']},
    {id:'sleep-17',day:17,kind:'sleep',start:0,end:8,time:'00:00',duration:28800,title:'10月17日睡眠记录',preview:'睡眠片段合计 8 小时。',source:'Apple 健康',summary:'10月17日睡眠片段合计 8 小时。',text:'来源：Apple 健康（示例）\n时长：8 小时',tags:['睡眠']},
    {id:'sleep-16',day:16,kind:'sleep',start:0,end:6+20/60,time:'00:00',duration:22800,title:'10月16日睡眠记录',preview:'睡眠片段合计 6 小时 20 分钟。',source:'Apple 健康',summary:'10月16日睡眠片段合计 6 小时 20 分钟。',text:'来源：Apple 健康（示例）\n时长：6 小时 20 分钟',tags:['睡眠']},
    {id:'tired-16',day:16,kind:'thought',start:6+50/60,end:6+51/60,time:'06:50',duration:42,title:'醒来仍有点困',preview:'“起床了，但还是觉得有点困。”',source:'Apple Watch',summary:'醒来后主动记录了有点困的感受。',text:'起床了，但还是觉得有点困。',tags:['晨间','自述']},
    {id:'sleep-15',day:15,kind:'sleep',start:0,end:8+5/60,time:'00:00',duration:29100,title:'10月15日睡眠记录',preview:'睡眠片段合计 8 小时 5 分钟。',source:'Apple 健康',summary:'10月15日睡眠片段合计 8 小时 5 分钟。',text:'来源：Apple 健康（示例）\n时长：8 小时 5 分钟',tags:['睡眠']},
    {id:'sleep-14',day:14,kind:'sleep',start:0,end:6+40/60,time:'00:00',duration:24000,title:'10月14日睡眠记录',preview:'睡眠片段合计 6 小时 40 分钟。',source:'Apple 健康',summary:'10月14日睡眠片段合计 6 小时 40 分钟。',text:'来源：Apple 健康（示例）\n时长：6 小时 40 分钟',tags:['睡眠']},
    {id:'tired-14',day:14,kind:'thought',start:7+5/60,end:7+6/60,time:'07:05',duration:46,title:'今早醒来还有点困',preview:'“今天醒来还有点困，先喝杯水。”',source:'Apple Watch',summary:'醒来后主动记录了有点困的感受。',text:'今天醒来还有点困，先喝杯水。',tags:['晨间','自述']},
    {id:'sleep-13',day:13,kind:'sleep',start:0,end:7+35/60,time:'00:00',duration:27300,title:'10月13日睡眠记录',preview:'睡眠片段合计 7 小时 35 分钟。',source:'Apple 健康',summary:'10月13日睡眠片段合计 7 小时 35 分钟。',text:'来源：Apple 健康（示例）\n时长：7 小时 35 分钟',tags:['睡眠']}
  ];
  const flashAssets=window.createDaybookFlashAssets({$,esc,icon,toast,openSheet,closeSheet,showView,openRecord,getRecord:id=>records.find(r=>r.id===id),refreshRecords:renderRecordLists});
  flashAssets.seed(records);
  const places=window.createDaybookPlaces({$,esc,icon,openSheet,getDay:()=>state.day,getRecords:()=>records,isEnabled:()=>sources.places.enabled});
  places.seed(records);
  const lifeMoments=window.createDaybookLifeMoments({esc,icon,openSheet,toast,getRecords:()=>records,refresh:renderDay,showTimeline:()=>{
    state.day=TODAY;state.filter='life';state.query='';$('searchInput').value='';
    closeSheet();renderDay();showView('today');
    $('product').scrollIntoView({block:'start',behavior:'instant'});
    const section=document.querySelector('.moments-section'),scroll=$('screenScroll');
    scroll.scrollTo({top:scroll.scrollTop+section.getBoundingClientRect().top-scroll.getBoundingClientRect().top-12,behavior:'instant'});
  }});
  lifeMoments.seed(records);
  const recordSources=window.createDaybookRecordSources({esc,icon});
  const dayTotals = {19:{steps:4860},18:{steps:6240}};
  // Recaps are fixed prototype snapshots. A later local record marks the snapshot as waiting to be refreshed.
  const recapCopy = {
    19:'早晨留下了醒来仍困的感受、睡眠与步行记录，也记下了首版方向。午间说想出去走走，随后有步行记录和走回后的补充。下午的讨论聚焦录音、转写与可回到原文的洞察。',
    18:'早晨记下醒来仍困的感受，也有一段睡眠记录。下午散步 42 分钟，傍晚录下了给新一周留一点空白、每天先确定一件重要事情的想法。',
    17:'这一天留下了一段睡眠记录，尚无语音或图片片段。',
    16:'早晨记录了醒来仍困的感受，同一天还有一段睡眠记录。',
    15:'这一天留下了一段睡眠记录，尚无语音或图片片段。',
    14:'早晨说醒来还有点困，同一天还留下了一段睡眠记录。',
    13:'这一天留下了一段睡眠记录，尚无语音或图片片段。'
  };
  const recaps = Object.entries(recapCopy).map(([day,text])=>({day:Number(day),text,sourceIds:records.filter(r=>r.day===Number(day)).sort((a,b)=>b.start-a.start).map(r=>r.id)})).sort((a,b)=>b.day-a.day);
  const insights = [
    {id:'followthrough',day:19,type:'洞察 · 可选建议',title:'午间想走走，后来有了步行记录。',description:'11:50 你说想在午休走 20 分钟；12:15–12:31 记录到步行；12:40 你又录下走回来后的想法。',evidence:['walk-intent','walk-noon','walk-followup'],note:'三段记录串起你的计划、活动和回顾；不能据此说步行带来了新想法。',action:'给明天午休留一点空白',actionDetail:'如果愿意，明天午休再留一段走走和回顾的时间。'}
  ];
  const filters = [{id:'all',title:'全部'},{id:'audio',title:'语音'},{id:'image',title:'图片'},{id:'thought',title:'闪念'},{id:'life',title:'生活'}];
  const state = {day:TODAY,view:'today',filter:'all',query:'',plans:new Set(),dismissed:new Set(),recordingAt:null};
  const recordMerge=window.createDaybookRecordMerge();
  const mergeSelection=new Set();
  let toastTimer,playerTimer,recordingTimer,activeRecord,playSeconds=0,sheetOpener=null,ai,photos,modelSettings,hardware,myVoice,speakerContacts;
  const dayRecords = () => records.filter(r=>r.day===state.day).sort((a,b)=>b.start-a.start);
  const audioRecord = r => r.kind==='voice'||r.kind==='thought';
  function formatDuration(seconds) {const n=Number.isFinite(seconds)?Math.max(0,Math.floor(seconds)):0;return `${Math.floor(n/3600)}小时${Math.floor(n/60)%60}分${n%60}秒`;}
  const humanDate = day => `10月${day}日`;
  const week = day => ['星期日','星期一','星期二','星期三','星期四','星期五','星期六'][new Date(2026,9,day).getDay()];
  function toast(message) {clearTimeout(toastTimer);$('toast').textContent=message;$('toast').hidden=false;toastTimer=setTimeout(()=>$('toast').hidden=true,3000);}
  const recapForDay = day => recaps.find(r=>r.day===day);
  const recapPending = recap => records.some(r=>r.day===recap.day&&!recap.sourceIds.includes(r.id));
  const dayHasNewRecords = day => {const recap=recapForDay(day);return recap&&recapPending(recap);};
  const currentInsight = () => !dayHasNewRecords(state.day)&&insights.find(i=>i.day===state.day&&!state.dismissed.has(i.id));
  const empty = (title,text,glyph='BookOpen') => `<div class="empty-state">${icon(glyph)}<h3>${title}</h3><p>${text}</p></div>`;
  function filteredRecords() {
    return dayRecords().filter(r=>{
      const type=state.filter==='all'||(state.filter==='audio'&&audioRecord(r))||(state.filter==='image'&&r.kind==='image')||(state.filter==='thought'&&r.kind==='thought')||(state.filter==='life'&&['sleep','activity','journal','location'].includes(r.kind));
      return type&&`${r.title} ${r.text} ${r.preview} ${r.tags.join(' ')}`.toLocaleLowerCase().includes(state.query.toLocaleLowerCase().trim());
    });
  }
  function renderMetrics() {
    const list=dayRecords(),total=list.filter(audioRecord).reduce((s,r)=>s+r.duration,0),sleep=list.filter(r=>r.kind==='sleep').reduce((s,r)=>s+r.duration,0);
    const thoughtCount=list.filter(r=>r.kind==='thought').length;
    const photoCount=list.filter(r=>r.kind==='image').reduce((sum,r)=>sum+(r.images?.length??0),0);
    const healthFigures=sources.health.enabled
      ? [['Footprints','步数',dayTotals[state.day]?.steps.toLocaleString()??'暂无',''],['Moon','睡眠',sleep?`${Math.floor(sleep/3600)}<small>时</small> ${Math.floor(sleep%3600/60)}<small>分</small>`:'暂无','']]
      : [['Lightbulb','闪念',thoughtCount,'条'],['Images','图片',photoCount,'张']];
    const figures=[['AudioLines','声音',Math.round(total/60),'分钟'],...healthFigures];
    $('metrics').innerHTML=figures.map(([i,label,value,unit])=>`<div class="metric"><div class="metric-label">${icon(i)}${label}</div><div class="metric-value">${value}${unit?`<small>${unit}</small>`:''}</div></div>`).join('');
  }
  function renderRhythm() {
    const list=dayRecords();
    $('dayRhythm').className=`rhythm ${state.day!==TODAY?'past':''} ${list.length?'':'empty'}`;
    $('rhythmUntil').textContent=state.day===TODAY?'截至 16:30':list.length?'全天回顾':'暂无记录';
    $('dayRhythm').innerHTML=['sleep','activity','audio'].map(type=>`<div class="rhythm-track" role="group" aria-label="${{sleep:'睡眠',activity:'活动',audio:'语音'}[type]}时间轴">${list.filter(r=>type==='audio'?audioRecord(r):r.kind===type).filter(r=>!r.lifeMoment||r.lifeMoment==='wake'&&r.sleepRange).map(r=>`<button class="rhythm-segment" data-record="${r.id}" data-kind="${r.kind}" style="left:${(r.sleepRange?.start??r.start)/24*100}%;width:${Math.max(.75,((r.sleepRange?.end??r.end)-(r.sleepRange?.start??r.start))/24*100)}%" aria-label="${esc(r.time+' '+r.title)}" title="${esc(r.time+' '+r.title)}"></button>`).join('')}</div>`).join('');
    const placeTrack=places.rhythm(list);
    $('dayRhythm').insertAdjacentHTML('beforeend',placeTrack);
    $('rhythmCaption').textContent=list.length?(placeTrack?'上至下：睡眠 · 活动 · 语音 · 地点，点击回看。':'上至下：睡眠 · 活动 · 语音，点击片段回看。'):'有记录的时段会出现在这里。';
    places.render(list);
  }
  function insightCard(item) {
    const action = `<button class="primary-button" data-plan="${item.id}">${icon(state.plans.has(item.id)?'Check':'ArrowUpRight')}${state.plans.has(item.id)?'已记到明天':'看看建议'}</button>`;
    return `<article class="insight-card"><div class="insight-label">${icon('Lightbulb')}<span>${esc(item.type)}</span><span class="insight-preview-tag">内容预览</span></div><h3>${esc(item.title)}</h3><p>${esc(item.description)}</p><div class="insight-source-line">${icon('AudioLines')}语音转写 <span>×</span> ${icon('Footprints')}活动</div><div class="insight-footer"><button class="evidence-button" data-insight="${item.id}">${icon('Link2')}${esc(item.evidenceLabel||`${item.evidence.length} 条记录支持`)}${icon('ChevronRight')}</button>${action}</div></article>`;
  }
  function recapCard(recap,home=false) {
    const pending=recapPending(recap);
    return `<article class="recap-card"><div class="recap-label">${icon('BookOpen')}<span>${home&&recap.day===TODAY-1?'昨日回顾':`${humanDate(recap.day)} · `}<span>${home&&recap.day===TODAY-1?'':'回顾'}</span></span><span class="recap-status">${pending?'有新记录 · 待更新':'每日记录'}</span></div><p>${esc(recap.text)}</p><button class="recap-open" data-recap="${recap.day}"><span>${pending?'新记录加入后将重新生成':`<span>来自</span> ${recap.sourceIds.length} <span>条记录</span>`}</span><span><span>查看回顾</span> ${icon('ArrowUpRight')}</span></button></article>`;
  }
  function renderHomeRecap() {
    const recapDay=state.day===TODAY?TODAY-1:state.day;
    const recap=recapForDay(recapDay);
    $('homeRecap').innerHTML=recap?recapCard(recap,true):`<div class="quiet-info">${icon('BookOpen')}<p>${records.some(r=>r.day===recapDay)?'记录正在整理，回顾生成后会出现在这里。':state.day===TODAY?'昨天还没有可回顾的记录。':'这一天还没有可回顾的记录。'}</p></div>`;
  }
  function recordingContentTitle(r) {
    const title=(r.title||'').trim().replace(/^长录音\s*·\s*/u,'');
    // The timeline owns the start time. Legacy timestamp defaults are not content titles.
    return /^\d{1,2}月\d{1,2}日\s+\d{1,2}:\d{2}$/u.test(title)?'':title;
  }
  function recordMarkup(r,swipeable=false) {
    let markup;
    if(r.lifeMoment)markup=lifeMoments.markup(r);
    else {
    const title=r.kind==='voice'?recordingContentTitle(r):r.title;
    const titleMarkup=title?esc(title):'<span data-recording-kind>待生成标题</span>';
    const glyph=audioRecord(r)?'AudioLines':r.kind==='image'?'Images':r.kind==='sleep'?'Moon':r.kind==='journal'?'NotebookPen':'Footprints';
    const thumbnails=r.kind==='image'?`<span class="moment-photos">${r.images.slice(0,3).map(p=>`<img src="${esc(p.url)}" alt="" loading="lazy">`).join('')}${r.images.length>3?`<span>+${r.images.length-3}</span>`:''}</span>`:'';
    markup=`<button class="moment" data-kind="${r.kind}" data-record="${esc(r.id)}"><span class="moment-time">${r.time}</span><span class="moment-main"><span class="moment-title"><span>${r.kind==='voice'?'<span data-recording-kind>长录音·</span>':''}${titleMarkup}</span>${icon('ChevronRight')}</span><span class="moment-description">${esc(r.preview)}</span>${thumbnails}<span class="moment-meta">${recordSources.line(r,glyph)}<span>${esc(audioRecord(r)?formatDuration(r.duration):r.tags[0])}</span>${r.kind==='thought'?'<span>闪念</span>':''}</span>${flashAssets.badge(r)}${places.line(r)}</span></button>`;
    }
    if(!swipeable)return markup;
    const selected=mergeSelection.has(r.id);
    const eligible=recordMerge.isEligible(r);
    return `<div class="moment-swipe-row" data-swipe-row="${esc(r.id)}" data-record-id="${esc(r.id)}" data-selectable="${eligible}" data-selected="${selected}" data-revealed="none" ${r.id.startsWith('merged-demo-')?'data-merged-record="true"':''}><button class="swipe-action swipe-select" data-swipe-action="select" role="checkbox" aria-checked="${selected}" ${eligible?'':'disabled'}>${icon(selected?'Check':'Square')}<span>${selected?'已选中':'选择'}</span></button><button class="swipe-action swipe-delete" data-swipe-action="delete">${icon('X')}<span>删除</span></button>${markup}</div>`;
  }
  function mergeToolbarMarkup() {
    const count=mergeSelection.size;
    const canMerge=recordMerge.canMerge(dayRecords(),[...mergeSelection]);
    return `<div class="merge-toolbar" data-merge-toolbar ${count?'':'hidden'}><span><strong>${count}</strong> <span>条长录音已选</span></span><div><button class="secondary-button" data-merge-cancel>取消</button><button class="primary-button" data-merge-submit ${canMerge?'':'disabled'} ${canMerge?'':'aria-disabled="true"'}>${icon('AudioLines')}合并所选</button></div></div>`;
  }
  function renderRecordLists() {
    const data=filteredRecords();
    $('homeFilters').innerHTML=filters.map(f=>`<button class="filter" data-filter="${f.id}" aria-pressed="${state.filter===f.id}">${f.title}</button>`).join('');
    $('libraryFilters').innerHTML=[...filters,{id:'recap',title:'回顾'}].map(f=>`<button class="filter" data-filter="${f.id}" aria-pressed="${state.filter===f.id}">${f.title}</button>`).join('');
    $('homeMoments').innerHTML=data.length?mergeToolbarMarkup()+(state.filter==='life'?data:data.slice(0,4)).map(r=>recordMarkup(r,true)).join(''):empty('这里留了一点空白','可以换个筛选，或用右下角的“记此刻”留下今天。');
    if(state.filter==='recap'){
      const query=state.query.toLocaleLowerCase().trim();
      const matches=recaps.filter(r=>`${humanDate(r.day)} ${r.text}`.toLocaleLowerCase().includes(query));
      $('libraryMoments').innerHTML=matches.length?matches.map(r=>recapCard(r)).join(''):empty('没有找到每日回顾','试试其他日期或关键词。','Search');
      $('libraryDate').innerHTML=`<span>按日期查看每日回顾</span> · ${recaps.length} <span>天</span>`;
      $('searchInput').placeholder='搜索每日回顾';
    } else {
      $('libraryMoments').innerHTML=data.length?data.map(recordMarkup).join(''):empty(state.query?'没有找到这段记录':'还没有这样的片段',state.query?'试试更短的关键词，或切换记录类型。':'下一次记录，会出现在这里。','Search');
      $('libraryDate').textContent=`${humanDate(state.day)} · ${dayRecords().length} 条记录`;
      $('searchInput').placeholder='搜索想法、片段或关键词';
    }
    $('momentsTitle').textContent=state.day===TODAY?'今天的片段':`${humanDate(state.day)}的片段`;
  }
  function renderInsights() {
    const pending=dayHasNewRecords(state.day);
    $('insightsContext').textContent=pending?'有新记录加入 · 等待回顾更新后再判断。':state.day===TODAY?'有可靠线索和可选建议时才出现 · 今日 1 条示例。':`${humanDate(state.day)} · 没有合适建议的日子可以没有洞察。`;
    const data=pending?[]:insights.filter(i=>i.day===state.day&&!state.dismissed.has(i.id));
    $('insightList').innerHTML=data.length?data.map(i=>insightCard(i)).join(''):empty(pending?'先等记录补齐':'这天没有新洞察',pending?'新增记录尚未处理完，不急着给出洞察或建议。':'只有录音转写与生活记录相互印证，且有值得提出的建议时，才会在这里出现。','Lightbulb');
  }
  function renderSources() {
    renderMetrics();
    $('sourceList').innerHTML=Object.entries(sources).map(([id,s])=>`<div class="source-row">${icon(s.icon)}<div class="source-copy"><strong>${s.name}</strong><p>${s.description}<br>${s.enabled?'示例已连接':'尚未连接'}</p>${id==='places'?`<button class="place-settings-link" data-place-action="settings">查看地点设置${icon('ChevronRight')}</button>`:''}</div><button class="switch" role="switch" aria-checked="${s.enabled}" aria-label="${s.enabled?'暂停':'连接'}${s.name}" data-source="${id}"></button></div>`).join('');
    ai?.render();
  }
  function renderDay() {
    $('dayEyebrow').textContent=`${state.day===TODAY?'今天':state.day===18?'昨天':'回顾'} · ${week(state.day)}`;
    $('dayTitle').textContent=humanDate(state.day);$('calendarNumber').textContent=state.day;
    $('daySubtitle').textContent=dayRecords().length?'把值得记住的，留在今天。':'留白，也是一天的一部分。';
    renderMetrics();renderRhythm();renderHomeRecap();renderRecordLists();renderInsights();renderSources();flashAssets.render();
  }
  function showView(name,{focusSearch=false}={}) {
    if(name!=='today'&&mergeSelection.size){mergeSelection.clear();renderRecordLists();}
    if(name==='actions'||name==='insights')flashAssets.render();
    if(name==='today'&&(state.query||state.filter==='recap')){state.query='';state.filter='all';$('searchInput').value='';renderRecordLists();}
    state.view=name;['today','ai','insights','actions','library','data'].forEach(v=>$(v+'View').hidden=v!==name);
    $('aiComposerDock').hidden=name!=='ai';
    document.querySelectorAll('[data-view]').forEach(b=>{const active=b.dataset.view===name||(name==='library'&&b.dataset.view==='today');b.classList.toggle('active',active);active?b.setAttribute('aria-current','page'):b.removeAttribute('aria-current');});
    $('screenScroll').scrollTop=0;if(focusSearch)$('searchInput').focus();
    ai?.render();
  }
  function positionSheet() {
    if(!$('sheet').open)return;
    const r=document.querySelector('.phone-screen').getBoundingClientRect();
    // Resizing the surrounding website can leave the phone partly above the viewport.
    // Keep the complete sheet (including its close button) inside the visible window.
    const width=Math.min(r.width,window.innerWidth);
    const maxHeight=Math.min(Math.max(250,r.height*.87),window.innerHeight-16);
    const left=Math.max(0,Math.min(r.left,window.innerWidth-width));
    const bottom=Math.max(0,Math.min(window.innerHeight-r.bottom,window.innerHeight-maxHeight-8));
    Object.assign($('sheet').style,{position:'fixed',left:`${left}px`,right:'auto',bottom:`${bottom}px`,width:`${width}px`,maxHeight:`${maxHeight}px`});
  }
  function openSheet(title,body) {
    stopPlayback();$('sheetTitle').textContent=title;$('sheetBody').innerHTML=body;
    if(!$('sheet').open){sheetOpener=document.activeElement;$('sheet').showModal();}
    positionSheet();$('sheet').scrollTop=0;$('closeSheet').focus();
  }
  function closeSheet(){stopPlayback();$('sheet').close();}
  function openCalendar() {
    openSheet('回看某一天',`<div class="calendar-heading"><strong>2026年10月</strong><span>今天是 19 日</span></div><div class="calendar-week">${['一','二','三','四','五','六','日'].map(d=>`<span>${d}</span>`).join('')}</div><div class="calendar-days">${'<span></span>'.repeat(3)}${Array.from({length:31},(_,i)=>{
      const d=i+1;return `<button data-day="${d}" ${d>TODAY?'disabled':''} class="${state.day===d?'current ':''}${records.some(r=>r.day===d)?'has-data':''}" aria-label="10月${d}日${records.some(r=>r.day===d)?'，有记录':''}" ${state.day===d?'aria-current="date"':''}>${d}</button>`;
    }).join('')}</div><p class="calendar-legend">圆点表示这天有记录。原型提供 13–19 日示例。</p>`);
  }
  function openInsight(id) {
    const item=insights.find(i=>i.id===id);
    const evidence=item.evidence.map(sourceID=>{const r=records.find(record=>record.id===sourceID);if(!r)return '';const symbol=audioRecord(r)?'AudioLines':r.kind==='sleep'?'Moon':'Footprints';return `<button class="evidence" data-record="${sourceID}"><small>${icon(symbol)}${humanDate(r.day)} ${r.time} · ${esc(r.source)}${icon('ArrowUpRight')}</small><blockquote>${esc(r.preview)}</blockquote></button>`;}).join('');
    const action=item.action?`<button class="primary-button" data-plan="${id}">${state.plans.has(id)?'查看已采纳建议':'看看行动建议'}${icon('ArrowRight')}</button>`:'';
    openSheet('这条洞察从哪里来',`<div class="insight-label">${icon('Lightbulb')}${esc(item.type)} · 内容预览</div><h3 class="insight-detail-title">${esc(item.title)}</h3><p class="sheet-intro">${esc(item.description)}</p><h4 class="sheet-section-title">回到原始记录</h4>${evidence}<div class="quiet-info">${icon('CircleHelp')}<p>${esc(item.note)}</p></div><div class="sheet-actions"><button class="secondary-button" data-dismiss-insight="${id}">不太符合</button>${action}</div>`);
  }
  function openRecap(day) {
    const recap=recapForDay(day);if(!recap)return;
    const pending=recapPending(recap);
    const evidence=recap.sourceIds.map(id=>{const r=records.find(row=>row.id===id);return r?`<button class="evidence" data-record="${id}"><small>${icon(audioRecord(r)?'AudioLines':r.kind==='sleep'?'Moon':r.kind==='image'?'Images':'Footprints')}${r.time} · ${esc(r.source)}${icon('ArrowUpRight')}</small><blockquote>${esc(r.title)}</blockquote></button>`:'';}).join('');
    openSheet(`${humanDate(day)} · 回顾`,`<div class="insight-label">${icon('BookOpen')}<span>每日回顾</span> · <span>内容预览</span></div><p class="sheet-intro recap-detail">${esc(recap.text)}</p><div class="quiet-info">${icon(pending?'Clock3':'CircleHelp')}<p>${pending?'有新记录加入。这篇示例回顾仍是旧版本，等待新记录处理后重新生成。':'这段回顾概括当天已有记录，不提供建议；点击下面的条目可查看原始记录。'}</p></div><h4 class="sheet-section-title">来自当天 ${recap.sourceIds.length} 条记录</h4>${evidence}`);
  }
  function openPlan(id) {
    const item=insights.find(i=>i.id===id);if(!item?.action)return;
    const saved=state.plans.has(id);
    openSheet('给明天，一小步',`<div class="insight-label">${icon('Sun')}10月20日 · 明天</div><h3 class="insight-detail-title">${esc(item.action)}</h3><p class="sheet-intro">${esc(item.actionDetail)}</p><div class="quiet-info">${icon('Link2')}<p>来自：${esc(item.title)}<br>只加入原型内的计划，不写入系统日历。</p></div><button class="primary-button wide" data-confirm-plan="${id}">${icon(saved?'Check':'Plus')}${saved?'已记到明天':'记到明天'}</button>${saved?`<button class="plain-row" data-remove-plan="${id}"><span>撤销这条计划</span>${icon('RotateCcw')}</button>`:''}`);
  }
  function openRecord(id, detailTab = 'summary') {
    const r=records.find(r=>r.id===id);if(!r)return;activeRecord=r;playSeconds=0;
    if(lifeMoments.open(r))return;
    if(r.kind==='image'){photos.openRecord(r);return;}
    const wave=Array.from({length:46},(_,i)=>`<span style="height:${4+Math.round(Math.abs(Math.sin(i*1.17)*Math.cos(i*.41))*32)}px"></span>`).join('');
    openSheet(r.title,`<div class="detail-meta">${humanDate(r.day)} ${r.time} · ${esc(r.source)}${audioRecord(r)?' · '+formatDuration(r.duration):''}</div>${recordSources.detail(r)}${places.detail(r)}${audioRecord(r)?`<div class="audio-player" aria-label="录音播放进度演示"><div class="audio-wave" aria-hidden="true">${wave}</div><div class="audio-controls"><span id="playerTime">${formatDuration(0)}</span><button class="play-button" id="playButton" aria-label="演示播放进度">${icon('Play')}</button><span>${formatDuration(r.duration)}</span></div><p class="subtle" style="margin:12px 0 0;text-align:center">示例录音，仅演示进度，不播放声音</p></div>`:''}${speakerContacts.overview(r)}<div class="detail-tabs" role="tablist" aria-label="记录内容"><button role="tab" id="recordSummaryTab" data-detail-tab="summary" aria-selected="true" aria-controls="recordContent">总结</button><button role="tab" id="recordTextTab" data-detail-tab="text" aria-selected="false" aria-controls="recordContent">全文</button></div><div id="recordContent" class="detail-content" role="tabpanel" aria-labelledby="recordSummaryTab">${esc(r.summary)}</div>${flashAssets.entry(r)}`);
    if(detailTab==='text'){$('recordTextTab').click();$('recordTextTab').scrollIntoView({block:'nearest'});}
  }
  function stopPlayback(){clearInterval(playerTimer);playerTimer=null;}
  function togglePlayback(){
    if(playerTimer){stopPlayback();$('playButton').innerHTML=icon('Play');$('playButton').setAttribute('aria-label','演示播放进度');return;}
    if(playSeconds>=activeRecord.duration)playSeconds=0;
    $('playButton').innerHTML=icon('Pause');$('playButton').setAttribute('aria-label','暂停进度演示');
    playerTimer=setInterval(()=>{playSeconds=Math.min(playSeconds+1,activeRecord.duration);if(!$('playerTime')){stopPlayback();return;}$('playerTime').textContent=formatDuration(playSeconds);if(playSeconds>=activeRecord.duration){stopPlayback();$('playButton').innerHTML=icon('Play');$('playButton').setAttribute('aria-label','演示播放进度');}},1000);
  }
  function openCapture(){
    if(state.recordingAt){toast('模拟录音正在进行，点击底部“结束并保存”。');return;}
    openSheet('记此刻',`<p class="sheet-intro">说出一个想法，或留住眼前的画面。</p><button class="capture-option" id="startRecordingButton">${icon('Mic')}<div><strong>语音</strong><p>记下闪念、对话和此刻的感受。</p></div>${icon('ChevronRight')}</button><button class="capture-option" id="captureImagesButton">${icon('Images')}<div><strong>图片</strong><p>拍一张照片，或从相册选择。</p></div>${icon('ChevronRight')}</button><p class="source-footnote">语音演示计时；图片仅在当前页面预览，刷新后清空，不会上传。</p>`);
  }
  function resetToToday(){mergeSelection.clear();state.day=TODAY;state.filter='all';state.query='';$('searchInput').value='';renderDay();showView('today');}
  function startRecording(){
    closeSheet();state.recordingAt=Date.now();$('recordingBanner').hidden=false;$('recordingClock').textContent='00:00';
    recordingTimer=setInterval(()=>$('recordingClock').textContent=formatDuration(Math.floor((Date.now()-state.recordingAt)/1000)),1000);toast('正在演示录音计时，未启用麦克风。');
  }
  function finishRecording(){
    if(!state.recordingAt)return;const duration=Math.max(1,Math.floor((Date.now()-state.recordingAt)/1000));clearInterval(recordingTimer);state.recordingAt=null;$('recordingBanner').hidden=true;
    records.push({id:`recording-${Date.now()}`,day:TODAY,kind:'voice',start:NOW,end:Math.min(24,NOW+duration/3600),time:'16:30',duration,title:'刚刚的语音记录（演示）',preview:'这是一段计时演示，没有实际音频或转写。',source:'iPhone · 演示',summary:'此条目展示录音保存后的界面，未生成真实总结。',text:'没有录制真实音频，因此没有转写文本。',tags:['演示录音'],place:places.forDemoRecording()});resetToToday();toast('计时演示已保存，未录制真实声音。');
  }
  function openSource(id){
    const source=sources[id];
    if(source.enabled){source.enabled=false;renderSources();renderRhythm();closeSheet();toast(`${source.name}示例连接已暂停，历史记录保留。`);return;}
    if(id==='places'){places.openSettings();return;}
    openSheet(`连接${source.name}`,`<div class="watch-status-large">${icon(source.icon)}</div><p class="sheet-intro">${source.scope}</p><div class="local-banner">${icon('ShieldCheck')}<div><strong>你可以随时暂停</strong><p>这里只演示连接流程，不发起真实授权，不读取数据。</p></div></div><button class="primary-button wide" data-connect-source="${id}">${icon('Link2')}连接示例来源</button>`);
  }
  function removeRecordFromDemo(id) {
    const index=records.findIndex(record=>record.id===id);
    if(index<0)return;
    records.splice(index,1);
    recaps.filter(recap=>recap.day===state.day).forEach(recap=>{recap.sourceIds=recap.sourceIds.filter(sourceId=>sourceId!==id);});
    mergeSelection.clear();closeSheet();renderDay();toast('已从原型示例中删除。');
  }
  function confirmRecordDelete(id) {
    const record=records.find(item=>item.id===id);if(!record)return;
    openSheet('删除这条记录？',`<p class="sheet-intro"><span>“</span><strong>${esc(record.title)}</strong><span>”</span> <span>将从当前原型示例中移除。</span></p><div class="local-banner">${icon('CircleHelp')}<div><strong>仅影响原型演示</strong><p>不会删除 iPhone 上的录音或任何真实数据。</p></div></div><div class="sheet-actions"><button class="secondary-button" data-cancel-delete>取消</button><button class="danger-button" data-confirm-delete="${esc(id)}">删除记录</button></div>`);
  }
  function toggleMergeSelection(id) {
    if(state.day!==TODAY||state.filter!=='all'||state.query.trim()){
      toast('请在今天的“全部”列表中选择相邻长录音。');return;
    }
    const outcome=recordMerge.toggleSelection(dayRecords(),[...mergeSelection],id);
    if(!outcome.ok){toast(outcome.reason==='long-recording'?'只能选择长录音。':'只能选择时间线上相邻的长录音。');return;}
    mergeSelection.clear();outcome.selectedIds.forEach(selectedId=>mergeSelection.add(selectedId));
    renderRecordLists();
  }
  function openMergeConfirmation() {
    const selected=dayRecords().filter(record=>mergeSelection.has(record.id));
    if(!recordMerge.canMerge(dayRecords(),[...mergeSelection])){toast('请选择至少两条相邻的长录音。');return;}
    openSheet('合并录音 · 原型演示',`<p class="sheet-intro">将 <strong>${selected.length}</strong> 条相邻长录音按顺序拼接为一条。</p><div class="merge-source-list">${selected.slice().sort((a,b)=>a.start-b.start).map(record=>`<div><span>${esc(record.time)} · ${esc(record.title)}</span><small>${formatDuration(record.duration)}</small></div>`).join('')}</div><div class="local-banner">${icon('CircleHelp')}<div><strong>模拟完整处理流程</strong><p>这里会演示拼接音频，并重新生成全文、摘要和标题；不会读取或拼接真实音频，也不会调用 AI。完成后会移除上面的原型条目。</p></div></div><div class="sheet-actions"><button class="secondary-button" data-cancel-merge>取消</button><button class="primary-button" data-confirm-merge>${icon('AudioLines')}开始模拟合并</button></div>`);
  }
  function simulateSelectedMerge() {
    const sourceIds=[...mergeSelection];
    if(!recordMerge.canMerge(dayRecords(),sourceIds)){closeSheet();toast('所选条目已变化，请重新选择相邻长录音。');return;}
    $('sheetBody').innerHTML=`<div class="merge-progress" role="status" aria-live="polite"><div class="merge-spinner"></div><strong>正在模拟合并录音…</strong><p>拼接音频片段</p><p>重新生成全文、摘要与标题</p><small>原型演示 · 不处理真实音频</small></div>`;
    window.setTimeout(()=>{
      const id=`merged-demo-${Date.now()}`;
      const generated={id,title:'用户访谈 · 合并版',preview:'两段录音已在原型中合并，并模拟重新生成了文字和摘要。',source:'Apple Watch · 原型演示',summary:'模拟重新生成的摘要：访谈先谈到记录习惯，再讨论语音录制和回顾流程；后半段补充了首次使用时的体验反馈。',text:'模拟重新生成的全文：\n\n第一段：用户介绍了记录习惯，并分享了对语音录制和每日回顾的想法。\n\n第二段：继续讨论首次使用的步骤、主要疑问和体验流程。\n\n以上文字仅为原型示例，没有真实音频参与。',tags:['合并录音','原型演示']};
      const dayRows=dayRecords();
      const merged=recordMerge.merge(dayRows,sourceIds,generated);
      const originalDayIds=new Set(dayRows.map(record=>record.id));
      records.splice(0,records.length,...records.filter(record=>!originalDayIds.has(record.id)),...merged.records);
      const recap=recapForDay(state.day);
      if(recap){recap.sourceIds=recap.sourceIds.filter(sourceId=>!sourceIds.includes(sourceId));recap.sourceIds.push(id);}
      mergeSelection.clear();closeSheet();renderDay();toast('模拟合并完成：音频、全文、摘要与标题已更新。');
    },650);
  }
  let swipeGesture=null,suppressMomentTap=false;
  $('homeMoments').addEventListener('pointerdown',event=>{
    const row=event.target.closest('[data-swipe-row]');
    if(!row||event.target.closest('[data-swipe-action]')||(event.pointerType==='mouse'&&event.button!==0))return;
    swipeGesture={row,id:event.pointerId,x:event.clientX,y:event.clientY,moved:false};
    row.setPointerCapture?.(event.pointerId);
  });
  $('homeMoments').addEventListener('pointermove',event=>{
    if(!swipeGesture||event.pointerId!==swipeGesture.id)return;
    const dx=event.clientX-swipeGesture.x,dy=event.clientY-swipeGesture.y;
    if(Math.abs(dx)>8&&Math.abs(dx)>Math.abs(dy)){swipeGesture.moved=true;event.preventDefault();}
  });
  $('homeMoments').addEventListener('pointerup',event=>{
    if(!swipeGesture||event.pointerId!==swipeGesture.id)return;
    const {row,x,y,moved}=swipeGesture,dx=event.clientX-x,dy=event.clientY-y;
    swipeGesture=null;
    if(!moved||Math.abs(dx)<42||Math.abs(dx)<Math.abs(dy))return;
    suppressMomentTap=true;window.setTimeout(()=>{suppressMomentTap=false;},0);
    if(dx<0){row.dataset.revealed='delete';return;}
    const record=records.find(item=>item.id===row.dataset.recordId);
    if(state.day!==TODAY||state.filter!=='all'||state.query.trim()){
      toast('请在今天的“全部”列表中选择相邻长录音。');return;
    }
    if(!recordMerge.isEligible(record)){toast('右划选择仅适用于长录音。');return;}
    row.dataset.revealed='select';
  });
  $('homeMoments').addEventListener('pointercancel',()=>{swipeGesture=null;});
  document.addEventListener('click',event=>{
    const b=event.target.closest('button');if(!b)return;
    if(b.dataset.swipeAction==='delete'){confirmRecordDelete(b.closest('[data-swipe-row]')?.dataset.recordId);return;}
    if(b.dataset.swipeAction==='select'){toggleMergeSelection(b.closest('[data-swipe-row]')?.dataset.recordId);return;}
    if(b.hasAttribute('data-confirm-delete')){removeRecordFromDemo(b.dataset.confirmDelete);return;}
    if(b.hasAttribute('data-cancel-delete')||b.hasAttribute('data-cancel-merge')){closeSheet();return;}
    if(b.hasAttribute('data-confirm-merge')){simulateSelectedMerge();return;}
    if(b.hasAttribute('data-merge-cancel')){mergeSelection.clear();renderRecordLists();return;}
    if(b.hasAttribute('data-merge-submit')){openMergeConfirmation();return;}
    if(lifeMoments.handleClick(b))return;
    if(flashAssets.handleClick(b))return;
    if(places.handleClick(b))return;
    if(hardware?.handleClick(b))return;
    if(b.dataset.view){showView(b.dataset.view);return;}
    if(b.dataset.day){const returnView=state.view==='ai'?'ai':'today';mergeSelection.clear();state.day=Number(b.dataset.day);state.filter='all';state.query='';$('searchInput').value='';closeSheet();renderDay();showView(returnView);return;}
    if(b.dataset.record){if(suppressMomentTap){suppressMomentTap=false;return;}const row=b.closest('[data-swipe-row]');if(row?.dataset.revealed&&row.dataset.revealed!=='none'){row.dataset.revealed='none';return;}openRecord(b.dataset.record);return;}
    if(b.dataset.recap){openRecap(Number(b.dataset.recap));return;}
    if(b.dataset.insight){openInsight(b.dataset.insight);return;}
    if(b.dataset.plan){openPlan(b.dataset.plan);return;}
    if(b.dataset.filter){mergeSelection.clear();state.filter=b.dataset.filter;renderRecordLists();return;}
    if(b.dataset.confirmPlan){state.plans.add(b.dataset.confirmPlan);closeSheet();renderInsights();toast('已记到明天，可回到这条洞察查看或撤销。');return;}
    if(b.dataset.removePlan){state.plans.delete(b.dataset.removePlan);if($('sheet').open)closeSheet();renderInsights();toast('已撤销这条计划。');return;}
    if(b.dataset.dismissInsight){state.dismissed.add(b.dataset.dismissInsight);closeSheet();renderInsights();ai?.render();toast('已收起这条洞察，谢谢你的反馈。');return;}
    if(b.dataset.prototypeFlow){if(b.dataset.prototypeFlow==='contacts')openRecord('review','text');else ai.createDraft('scope');return;}
    if(b.dataset.detailTab){document.querySelectorAll('[data-detail-tab]').forEach(tab=>tab.setAttribute('aria-selected',String(tab===b)));$('recordContent').innerHTML=b.dataset.detailTab==='text'?speakerContacts.transcript(activeRecord):esc(activeRecord.summary);$('recordContent').setAttribute('aria-labelledby',b.id);return;}
    if(b.dataset.source){openSource(b.dataset.source);return;}
    if(b.dataset.connectSource){sources[b.dataset.connectSource].enabled=true;renderSources();renderRhythm();closeSheet();toast('示例来源已连接，未读取真实数据。');return;}
    const actions={watchButton:()=>hardware.open(),dateButton:openCalendar,searchButton:()=>showView('library',{focusSearch:true}),settingsButton:()=>showView('data'),allMomentsButton:()=>showView('library'),captureButton:openCapture,closeSheet,captureImagesButton:()=>photos.openCapture(),asrSettingsButton:()=>modelSettings.openASR(),myVoiceSettingsButton:()=>myVoice.open(),aiModelSettingsButton:()=>modelSettings.openAI(),startRecordingButton:startRecording,finishRecording,playButton:togglePlayback,clearDayButton:()=>{mergeSelection.clear();state.day=17;state.filter='all';state.query='';$('searchInput').value='';renderDay();showView('today');}};
    actions[b.id]?.();
  });
  $('searchInput').addEventListener('input',event=>{mergeSelection.clear();state.query=event.target.value;renderRecordLists();});
  $('sheet').addEventListener('close',()=>{stopPlayback();if(sheetOpener?.isConnected&&!sheetOpener.closest('[hidden]'))sheetOpener.focus();else document.querySelector('.nav-item.active')?.focus();});
  $('sheet').addEventListener('cancel',stopPlayback);
  $('sheet').addEventListener('keydown',event=>{
    const tab=event.target.closest('[data-detail-tab]');
    if(!tab||!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
    event.preventDefault();
    const next=event.key==='Home'?'recordSummaryTab':event.key==='End'?'recordTextTab':tab.id==='recordSummaryTab'?'recordTextTab':'recordSummaryTab';
    $(next).click();$(next).focus();
  });
  $('sheet').addEventListener('click',event=>{if(event.target!==$('sheet'))return;const r=$('sheet').getBoundingClientRect();if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom)closeSheet();});
  window.addEventListener('resize',positionSheet);
  window.addEventListener('pagehide',()=>{stopPlayback();clearInterval(recordingTimer);clearTimeout(toastTimer);});
  const sharedUI={$,esc,icon,toast,openSheet,closeSheet};
  speakerContacts=window.createDaybookSpeakerContacts({...sharedUI,getRecord:id=>records.find(record=>record.id===id),returnToRecord:id=>openRecord(id,'text')});
  hardware=window.createDaybookHardware(sharedUI);
  photos=window.createDaybookPhotos({...sharedUI,placeDetail:places.detail,sourceDetail:recordSources.detail,onSave:record=>{records.push({...record,day:TODAY,start:NOW,end:NOW,time:'16:30',duration:0});closeSheet();resetToToday();toast('图片已留在今天，刷新后清空。');}});
  modelSettings=window.createDaybookModelSettings(sharedUI);
  myVoice=window.createDaybookVoiceProfile(sharedUI);
  ai=window.createDaybookAI({
    $,esc,icon,toast,openSheet,closeSheet,openCalendar,showView,
    getDay:()=>state.day,getView:()=>state.view,
    getProvider:modelSettings.getProvider,setRemoteConfirmationRequired:modelSettings.setRemoteConfirmationRequired,openModelSettings:modelSettings.openAI,usageLink:modelSettings.usageLink,
    getRecords:day=>records.filter(r=>r.day===day&&r.kind!=='location'&&r.lifeMoment!=='steps'&&!(r.lifeMoment==='wake'&&!r.duration)).map(r=>({...r})),
    getInsight:currentInsight,
    today:TODAY
  });
  renderDay();
  const preview=new URLSearchParams(window.location.search).get('preview');
  if(preview?.startsWith('moments'))requestAnimationFrame(()=>lifeMoments.preview(preview.split('-')[1]||'ready'));
  if(['assets','flash','flash-waiting','flash-unavailable','flash-empty','actions'].includes(preview))requestAnimationFrame(()=>{
    $('product').scrollIntoView({block:'start'});
    if(preview==='assets')flashAssets.openLibrary();
    else if(preview==='actions')showView('actions');
    else {showView('insights');flashAssets.openCapture(preview==='flash'?'flash-mixed':'thought-noon',preview==='flash'?'ready':preview.replace('flash-',''));}
  });
  if(['contacts','reminders'].includes(preview))requestAnimationFrame(()=>{
    $('product').scrollIntoView({block:'start'});
    if(preview==='contacts')openRecord('review','text');else ai.createDraft('scope');
  });
})();
