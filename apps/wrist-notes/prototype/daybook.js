/* Interactive concept: fictional records plus user-selected local images.
   No network, microphone, health, calendar, location or persistent storage APIs. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const esc = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const icon = name => `<svg class="icon" aria-hidden="true"><use href="#i-${name}"></use></svg>`;
  const TODAY = 19, NOW = 16.5;
  const sources = {
    watch:{name:'Apple Watch',icon:'Watch',enabled:true,description:'录音、闪念与同步状态',scope:'由你按下录音按钮开始，结束后传到 iPhone。'},
    health:{name:'Apple 健康',icon:'Heart',enabled:true,description:'步数、活动与睡眠',scope:'只读取你授权的步数、活动和睡眠，用来整理当天节奏。'},
    calendar:{name:'日历',icon:'CalendarDays',enabled:false,description:'为一天加上日程背景',scope:'读取所选日历的时间和标题，帮助你回顾一天的安排。'},
    places:{name:'地点',icon:'MapPin',enabled:false,description:'为片段补充地点，可随时关闭',scope:'为记录添加地点。你可以单独选择授权范围，也可以随时暂停。'}
  };
  const records = [
    {id:'review',day:19,kind:'voice',start:14,end:14+26/60,time:'14:00',duration:1560,title:'产品讨论：让记录更有用',preview:'先把录音和时间线做好，洞察要能回到原始记录。',source:'Apple Watch',summary:'先完成录音、转写和时间线的闭环。\n洞察需要能回到原始记录，让用户自己判断。\n下一步：列清首版范围，再讨论扩展数据源。',text:'我们先把录音和时间线做好。用户想回顾今天的时候，应该能找到具体发生的事情。\n\n每条洞察都要有依据，点进去能看到原始录音或文字。第一版不必做所有数据源，先把这个过程跑通。',tags:['产品讨论','1 个行动项']},
    {id:'walk-noon',day:19,kind:'activity',start:12.25,end:12.25+16/60,time:'12:15',duration:960,title:'午间走了走',preview:'16 分钟步行，给上午留一个停顿。',source:'Apple 健康',summary:'12:15 至 12:31，记录到 16 分钟步行。\n这里展示活动事实，不推断情绪或效率。',text:'来源：Apple 健康（示例）\n时间：12:15 至 12:31\n活动：步行 16 分钟',tags:['活动','16 分钟']},
    {id:'thought-noon',day:19,kind:'thought',start:11.3,end:11.3+48/3600,time:'11:18',duration:48,title:'先做小，再做好',preview:'“先把范围收小。每天只要有一条真的有用的建议，就够了。”',source:'Apple Watch',summary:'首版先收小范围。\n每天先提供一条有依据、有用的建议，再逐步丰富。',text:'刚才想了一下，先把范围收小。每天只要有一条真的有用的建议，就够了。不要一下子放十张卡片，让用户不知道该看什么。',tags:['闪念','做减法']},
    {id:'meeting',day:19,kind:'voice',start:9+40/60,end:10+22/60,time:'09:40',duration:2520,title:'周一的项目碰头',preview:'确认本周目标，先验证最核心的使用路径。',source:'Apple Watch',summary:'本周优先验证录音、转写、回顾的完整路径。\n界面上让用户能看到同步状态和转写进度。\n周五回顾使用反馈。',text:'今天先对一下本周的目标。我们优先验证录音、转写和回顾的路径。先保证录下来的东西能可靠保存，再看整理得好不好用。\n\n周五把这周的反馈集中看一下。',tags:['项目','42 分钟']},
    {id:'thought-morning',day:19,kind:'thought',start:8.6,end:8.62,time:'08:36',duration:72,title:'路上想到的首版方向',preview:'“第一版先把范围收小，让用户回顾一天时，能找到最有用的那一刻。”',source:'Apple Watch',summary:'首版聚焦“回顾一天，找到有用片刻”。\n先把范围收小，完成可靠的记录和回顾。',text:'第一版先把范围收小，让用户回顾一天时，能找到最有用的那一刻。录音只是一个入口，最终还是要帮人记住真正重要的事情。',tags:['闪念','首版方向']},
    {id:'walk-morning',day:19,kind:'activity',start:8.2,end:8.5,time:'08:12',duration:1080,title:'步行开启一天',preview:'18 分钟，走到附近的咖啡店。',source:'Apple 健康',summary:'08:12 至 08:30 记录到 18 分钟步行。\n地点描述是手动补充示例，并非已读取定位。',text:'来源：Apple 健康（示例）\n活动：步行 18 分钟\n地点：附近的咖啡店（手动备注示例）',tags:['活动','18 分钟']},
    {id:'sleep',day:19,kind:'sleep',start:0,end:7.2,time:'00:00',duration:25920,title:'昨夜睡眠',preview:'7 小时 12 分钟，给今天一个开始。',source:'Apple 健康',summary:'今日 00:00 至 07:12 记录到 7 小时 12 分钟睡眠。\n不据单日时长判断睡眠质量。',text:'来源：Apple 健康（示例）\n开始：10月19日 00:00\n结束：10月19日 07:12\n时长：7 小时 12 分钟',tags:['睡眠','已汇总']},
    {id:'yesterday-note',day:18,kind:'voice',start:17.5,end:17.55,time:'17:30',duration:180,title:'给新的一周留一点空白',preview:'下周想把每天最重要的一件事先确定下来。',source:'Apple Watch',summary:'尝试在一天开始前，写下最重要的一件事。',text:'下周想把每天最重要的一件事先确定下来。不要一下子排得太满，也留一点能想事情的时间。',tags:['周末回顾','3 分钟']},
    {id:'yesterday-walk',day:18,kind:'activity',start:16,end:16.7,time:'16:00',duration:2520,title:'周日下午的散步',preview:'42 分钟步行，慢一点也很好。',source:'Apple 健康',summary:'16:00 至 16:42 记录到 42 分钟步行。',text:'来源：Apple 健康（示例）\n活动：步行 42 分钟',tags:['活动','42 分钟']},
    {id:'yesterday-sleep',day:18,kind:'sleep',start:0,end:7.8,time:'00:00',duration:28080,title:'昨夜睡眠',preview:'7 小时 48 分钟。',source:'Apple 健康',summary:'00:00 至 07:48 记录到睡眠。',text:'来源：Apple 健康（示例）\n时长：7 小时 48 分钟',tags:['睡眠']}
  ];
  const dayTotals = {19:{steps:4860},18:{steps:6240}};
  const insights = [
    {id:'less',day:19,title:'两次闪念，<br>都在谈「做减法」。',plainTitle:'两次闪念，都在谈「做减法」。',description:'你反复提到先收小范围。也许下一步，是把首版要做的事写得更具体。',evidence:['thought-morning','thought-noon'],note:'这是两段记录中的共同主题，不代表你在其他时候也持有同样想法。',action:'把首版范围写成 3 行',actionDetail:'明天开始前，写下要做什么、先不做什么，以及怎样算完成。'},
    {id:'walk',day:19,title:'散步之后，<br>你留下了一个想法。',plainTitle:'散步之后，你留下了一个想法。',description:'早上的步行结束 6 分钟后，你记录了首版方向。这样的片刻，值得再留意。',evidence:['walk-morning','thought-morning'],note:'这里只是时间上的相邻，不能说明步行带来了灵感。可以再观察几天。',action:'给明天留 10 分钟散步',actionDetail:'在方便的时候走一走；如果有想法，就顺手记下来。'}
  ];
  const filters = [{id:'all',title:'全部'},{id:'audio',title:'语音'},{id:'image',title:'图片'},{id:'thought',title:'闪念'},{id:'life',title:'生活'}];
  const state = {day:TODAY,view:'today',filter:'all',query:'',plans:new Set(),dismissed:new Set(),recordingAt:null};
  let toastTimer,playerTimer,recordingTimer,activeRecord,playSeconds=0,sheetOpener=null,ai,photos,modelSettings;
  const dayRecords = () => records.filter(r=>r.day===state.day).sort((a,b)=>b.start-a.start);
  const audioRecord = r => r.kind==='voice'||r.kind==='thought';
  function formatDuration(seconds) {const m=Math.floor(seconds/60),s=seconds%60;return m?`${m} 分${s?` ${s} 秒`:'钟'}`:`${s} 秒`;}
  function timecode(s) {return `${Math.floor(s/60).toString().padStart(2,'0')}:${(s%60).toString().padStart(2,'0')}`;}
  const humanDate = day => `10月${day}日`;
  const week = day => ['星期日','星期一','星期二','星期三','星期四','星期五','星期六'][new Date(2026,9,day).getDay()];
  function toast(message) {clearTimeout(toastTimer);$('toast').textContent=message;$('toast').hidden=false;toastTimer=setTimeout(()=>$('toast').hidden=true,3000);}
  const currentInsight = () => insights.find(i=>i.day===state.day&&!state.dismissed.has(i.id));
  const empty = (title,text,glyph='BookOpen') => `<div class="empty-state">${icon(glyph)}<h3>${title}</h3><p>${text}</p></div>`;
  function filteredRecords() {
    return dayRecords().filter(r=>{
      const type=state.filter==='all'||(state.filter==='audio'&&audioRecord(r))||(state.filter==='image'&&r.kind==='image')||(state.filter==='thought'&&r.kind==='thought')||(state.filter==='life'&&['sleep','activity','journal'].includes(r.kind));
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
    $('dayRhythm').innerHTML=['sleep','activity','audio'].map(type=>`<div class="rhythm-track" role="group" aria-label="${{sleep:'睡眠',activity:'活动',audio:'语音'}[type]}时间轴">${list.filter(r=>type==='audio'?audioRecord(r):r.kind===type).map(r=>`<button class="rhythm-segment" data-record="${r.id}" data-kind="${r.kind}" style="left:${r.start/24*100}%;width:${Math.max(.75,(r.end-r.start)/24*100)}%" aria-label="${esc(r.time+' '+r.title)}" title="${esc(r.time+' '+r.title)}"></button>`).join('')}</div>`).join('');
    $('rhythmCaption').textContent=list.length?'上至下：睡眠 · 活动 · 语音，点击片段回看。':'有记录的时段会出现在这里。';
  }
  function insightCard(item,home=false) {
    return `<article class="insight-card"><div class="insight-label">${icon('Lightbulb')}今日洞察 <span>·</span> 从你的记录出发</div><h3>${item.title}</h3><p>${item.description}</p><div class="insight-footer"><button class="evidence-button" data-insight="${item.id}">${icon('Link2')}${item.evidence.length} 条记录支持${icon('ChevronRight')}</button><button class="primary-button" data-plan="${item.id}">${icon(state.plans.has(item.id)?'Check':'ArrowUpRight')}${state.plans.has(item.id)?'已记到明天':home?'给明天一步':'看看建议'}</button></div></article>`;
  }
  function renderHomeInsight() {
    const item=currentInsight();
    $('homeInsight').innerHTML=item?insightCard(item,true):`<div class="quiet-info">${icon('Lightbulb')}<p>${dayRecords().length?'多留下一些片段，线索会慢慢清晰。':'今天的故事还没开始。先记下一句话，或选择一个数据来源。'}</p></div>`;
  }
  function recordMarkup(r) {
    const glyph=audioRecord(r)?'AudioLines':r.kind==='image'?'Images':r.kind==='sleep'?'Moon':r.kind==='journal'?'NotebookPen':'Footprints';
    const thumbnails=r.kind==='image'?`<span class="moment-photos">${r.images.slice(0,3).map(p=>`<img src="${esc(p.url)}" alt="" loading="lazy">`).join('')}${r.images.length>3?`<span>+${r.images.length-3}</span>`:''}</span>`:'';
    return `<button class="moment" data-kind="${r.kind}" data-record="${r.id}"><span class="moment-time">${r.time}</span><span class="moment-main"><span class="moment-title">${esc(r.title)}${icon('ChevronRight')}</span><span class="moment-description">${esc(r.preview)}</span>${thumbnails}<span class="moment-meta"><span>${icon(glyph)}${esc(r.source)}</span><span>${esc(audioRecord(r)?formatDuration(r.duration):r.tags[0])}</span>${r.kind==='thought'?'<span>闪念</span>':''}</span></span></button>`;
  }
  function renderRecordLists() {
    const data=filteredRecords();
    ['homeFilters','libraryFilters'].forEach(id=>$(id).innerHTML=filters.map(f=>`<button class="filter" data-filter="${f.id}" aria-pressed="${state.filter===f.id}">${f.title}</button>`).join(''));
    $('homeMoments').innerHTML=data.length?data.slice(0,4).map(recordMarkup).join(''):empty('这里留了一点空白','可以换个筛选，或用右下角的“记此刻”留下今天。');
    $('libraryMoments').innerHTML=data.length?data.map(recordMarkup).join(''):empty(state.query?'没有找到这段记录':'还没有这样的片段',state.query?'试试更短的关键词，或切换记录类型。':'下一次记录，会出现在这里。','Search');
    $('libraryDate').textContent=`${humanDate(state.day)} · ${dayRecords().length} 条记录`;
    $('momentsTitle').textContent=state.day===TODAY?'今天的片段':`${humanDate(state.day)}的片段`;
  }
  function renderInsights() {
    $('insightsContext').textContent=`${humanDate(state.day)} · 把线索变成一个小行动。`;
    const data=insights.filter(i=>i.day===state.day&&!state.dismissed.has(i.id));
    $('insightList').innerHTML=data.length?data.map(i=>insightCard(i)).join(''):empty('先记录，再发现','当一天的记录足够丰富，这里会展示有出处的线索和建议。','Lightbulb');
    $('plansList').innerHTML=state.plans.size?[...state.plans].map(id=>{const item=insights.find(i=>i.id===id);return `<div class="plan-row">${icon('CheckCheck')}<div><strong>${item.action}</strong><p>10月20日 · 来自 10月19日的洞察</p></div><button class="text-button" data-remove-plan="${id}" aria-label="撤销${item.action}">撤销</button></div>`;}).join(''):`<div class="quiet-info">${icon('Sun')}<p>不必排满明天。采纳一条建议，就从一件小事开始。</p></div>`;
  }
  function renderSources() {
    renderMetrics();
    $('sourceList').innerHTML=Object.entries(sources).map(([id,s])=>`<div class="source-row">${icon(s.icon)}<div class="source-copy"><strong>${s.name}</strong><p>${s.description}<br>${s.enabled?'示例已连接':'尚未连接'}</p></div><button class="switch" role="switch" aria-checked="${s.enabled}" aria-label="${s.enabled?'暂停':'连接'}${s.name}" data-source="${id}"></button></div>`).join('');
    $('watchButton').classList.toggle('disconnected',!sources.watch.enabled);
    $('watchLabel').textContent=sources.watch.enabled?'已连接':'已暂停';
    $('watchButton').setAttribute('aria-label',sources.watch.enabled?'查看 Apple Watch 连接状态':'查看已暂停的 Apple Watch');
    ai?.render();
  }
  function renderDay() {
    $('dayEyebrow').textContent=`${state.day===TODAY?'今天':state.day===18?'昨天':'回顾'} · ${week(state.day)}`;
    $('dayTitle').textContent=humanDate(state.day);$('calendarNumber').textContent=state.day;
    $('daySubtitle').textContent=dayRecords().length?'把值得记住的，留在今天。':'留白，也是一天的一部分。';
    renderMetrics();renderRhythm();renderHomeInsight();renderRecordLists();renderInsights();renderSources();
  }
  function showView(name,{focusSearch=false}={}) {
    if(name==='today'&&state.query){state.query='';$('searchInput').value='';renderRecordLists();}
    state.view=name;['today','ai','insights','library','data'].forEach(v=>$(v+'View').hidden=v!==name);
    $('aiComposerDock').hidden=name!=='ai';
    document.querySelectorAll('[data-view]').forEach(b=>{const active=b.dataset.view===name||(name==='library'&&b.dataset.view==='today');b.classList.toggle('active',active);active?b.setAttribute('aria-current','page'):b.removeAttribute('aria-current');});
    $('screenScroll').scrollTop=0;if(focusSearch)$('searchInput').focus();
    ai?.render();
  }
  function positionSheet() {
    if(!$('sheet').open)return;
    const r=document.querySelector('.phone-screen').getBoundingClientRect();
    Object.assign($('sheet').style,{position:'fixed',left:`${r.left}px`,right:'auto',bottom:`${Math.max(0,window.innerHeight-r.bottom)}px`,width:`${r.width}px`,maxHeight:`${Math.max(250,r.height*.87)}px`});
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
    }).join('')}</div><p class="calendar-legend">圆点表示这天有记录。原型提供 18 日、19 日示例。</p>`);
  }
  function openInsight(id) {
    const item=insights.find(i=>i.id===id);
    openSheet('这条洞察从哪里来',`<div class="insight-label">${icon('Lightbulb')}10月19日 · 今日线索</div><h3 class="insight-detail-title">${item.plainTitle}</h3><p class="sheet-intro">${item.description}</p><h4 class="sheet-section-title">回到原始记录</h4>${item.evidence.map(id=>{const r=records.find(r=>r.id===id);return `<button class="evidence" data-record="${id}"><small>${icon(audioRecord(r)?'AudioLines':'Footprints')}${r.time} · ${r.source}${icon('ArrowUpRight')}</small><blockquote>${esc(r.preview)}</blockquote></button>`;}).join('')}<div class="quiet-info">${icon('CircleHelp')}<p>${item.note}</p></div><div class="sheet-actions"><button class="secondary-button" data-dismiss-insight="${id}">不太符合</button><button class="primary-button" data-plan="${id}">${state.plans.has(id)?'查看已采纳建议':'看看行动建议'}${icon('ArrowRight')}</button></div>`);
  }
  function openPlan(id) {
    const item=insights.find(i=>i.id===id),saved=state.plans.has(id);
    openSheet('给明天，一小步',`<div class="insight-label">${icon('Sun')}10月20日 · 明天</div><h3 class="insight-detail-title">${item.action}</h3><p class="sheet-intro">${item.actionDetail}</p><div class="quiet-info">${icon('Link2')}<p>来自：${item.plainTitle}<br>只加入原型内的计划，不写入系统日历。</p></div><button class="primary-button wide" data-confirm-plan="${id}">${icon(saved?'Check':'Plus')}${saved?'已记到明天':'记到明天'}</button>${saved?`<button class="plain-row" data-remove-plan="${id}"><span>撤销这条计划</span>${icon('RotateCcw')}</button>`:''}`);
  }
  function openRecord(id) {
    const r=records.find(r=>r.id===id);if(!r)return;activeRecord=r;playSeconds=0;
    if(r.kind==='image'){photos.openRecord(r);return;}
    const wave=Array.from({length:46},(_,i)=>`<span style="height:${4+Math.round(Math.abs(Math.sin(i*1.17)*Math.cos(i*.41))*32)}px"></span>`).join('');
    openSheet(r.title,`<div class="detail-meta">${humanDate(r.day)} ${r.time} · ${esc(r.source)}${audioRecord(r)?' · '+formatDuration(r.duration):''}</div>${audioRecord(r)?`<div class="audio-player" aria-label="录音播放进度演示"><div class="audio-wave" aria-hidden="true">${wave}</div><div class="audio-controls"><span id="playerTime">00:00</span><button class="play-button" id="playButton" aria-label="演示播放进度">${icon('Play')}</button><span>${timecode(r.duration)}</span></div><p class="subtle" style="margin:12px 0 0;text-align:center">示例录音，仅演示进度，不播放声音</p></div>`:''}<div class="detail-tabs" role="tablist" aria-label="记录内容"><button role="tab" id="recordSummaryTab" data-detail-tab="summary" aria-selected="true" aria-controls="recordContent">总结</button><button role="tab" id="recordTextTab" data-detail-tab="text" aria-selected="false" aria-controls="recordContent">全文</button></div><div id="recordContent" class="detail-content" role="tabpanel" aria-labelledby="recordSummaryTab">${esc(r.summary)}</div>`);
  }
  function stopPlayback(){clearInterval(playerTimer);playerTimer=null;}
  function togglePlayback(){
    if(playerTimer){stopPlayback();$('playButton').innerHTML=icon('Play');$('playButton').setAttribute('aria-label','演示播放进度');return;}
    if(playSeconds>=activeRecord.duration)playSeconds=0;
    $('playButton').innerHTML=icon('Pause');$('playButton').setAttribute('aria-label','暂停进度演示');
    playerTimer=setInterval(()=>{playSeconds=Math.min(playSeconds+1,activeRecord.duration);if(!$('playerTime')){stopPlayback();return;}$('playerTime').textContent=timecode(playSeconds);if(playSeconds>=activeRecord.duration){stopPlayback();$('playButton').innerHTML=icon('Play');$('playButton').setAttribute('aria-label','演示播放进度');}},1000);
  }
  function openCapture(){
    if(state.recordingAt){toast('模拟录音正在进行，点击底部“结束并保存”。');return;}
    openSheet('记此刻',`<p class="sheet-intro">说出一个想法，或留住眼前的画面。</p><button class="capture-option" id="startRecordingButton">${icon('Mic')}<div><strong>语音</strong><p>记下闪念、对话和此刻的感受。</p></div>${icon('ChevronRight')}</button><button class="capture-option" id="captureImagesButton">${icon('Images')}<div><strong>图片</strong><p>拍一张照片，或从相册选择。</p></div>${icon('ChevronRight')}</button><p class="source-footnote">语音演示计时；图片仅在当前页面预览，刷新后清空，不会上传。</p>`);
  }
  function resetToToday(){state.day=TODAY;state.filter='all';state.query='';$('searchInput').value='';renderDay();showView('today');}
  function startRecording(){
    closeSheet();state.recordingAt=Date.now();$('recordingBanner').hidden=false;$('recordingClock').textContent='00:00';
    recordingTimer=setInterval(()=>$('recordingClock').textContent=timecode(Math.floor((Date.now()-state.recordingAt)/1000)),1000);toast('正在演示录音计时，未启用麦克风。');
  }
  function finishRecording(){
    if(!state.recordingAt)return;const duration=Math.max(1,Math.floor((Date.now()-state.recordingAt)/1000));clearInterval(recordingTimer);state.recordingAt=null;$('recordingBanner').hidden=true;
    records.push({id:`recording-${Date.now()}`,day:TODAY,kind:'voice',start:NOW,end:Math.min(24,NOW+duration/3600),time:'16:30',duration,title:'刚刚的语音记录（演示）',preview:'这是一段计时演示，没有实际音频或转写。',source:'iPhone · 演示',summary:'此条目展示录音保存后的界面，未生成真实总结。',text:'没有录制真实音频，因此没有转写文本。',tags:['演示录音']});resetToToday();toast('计时演示已保存，未录制真实声音。');
  }
  function openWatch(){
    const connected=sources.watch.enabled;
    openSheet('手表状态',`<div class="watch-status-large">${icon('Watch')}</div><div class="watch-copy"><h3>Apple Watch SE</h3><p>${connected?'示例已连接，录音按需开始。':'示例连接已暂停，历史记录仍可回看。'}</p></div><div class="watch-facts"><div><span>上次同步</span><strong>${connected?'16:28':'已暂停'}</strong></div><div><span>手表电量</span><strong>68%（示例）</strong></div><div><span>待同步录音</span><strong>0 条</strong></div></div><button class="primary-button wide" data-source="watch">${icon(connected?'Pause':'Link2')}${connected?'暂停示例连接':'恢复示例连接'}</button><p class="source-footnote">此页只演示状态，不操作真实手表。</p>`);
  }
  function openSource(id){
    const source=sources[id];
    if(source.enabled){source.enabled=false;renderSources();closeSheet();toast(`${source.name}示例连接已暂停，历史记录保留。`);return;}
    openSheet(`连接${source.name}`,`<div class="watch-status-large">${icon(source.icon)}</div><p class="sheet-intro">${source.scope}</p><div class="local-banner">${icon('ShieldCheck')}<div><strong>你可以随时暂停</strong><p>这里只演示连接流程，不发起真实授权，不读取数据。</p></div></div><button class="primary-button wide" data-connect-source="${id}">${icon('Link2')}连接示例来源</button>`);
  }
  document.addEventListener('click',event=>{
    const b=event.target.closest('button');if(!b)return;
    if(b.dataset.view){showView(b.dataset.view);return;}
    if(b.dataset.day){const returnView=state.view==='ai'?'ai':'today';state.day=Number(b.dataset.day);state.filter='all';state.query='';$('searchInput').value='';closeSheet();renderDay();showView(returnView);return;}
    if(b.dataset.record){openRecord(b.dataset.record);return;}
    if(b.dataset.insight){openInsight(b.dataset.insight);return;}
    if(b.dataset.plan){openPlan(b.dataset.plan);return;}
    if(b.dataset.filter){state.filter=b.dataset.filter;renderRecordLists();return;}
    if(b.dataset.confirmPlan){state.plans.add(b.dataset.confirmPlan);closeSheet();renderHomeInsight();renderInsights();toast('已记到明天，可在“洞察”页查看或撤销。');return;}
    if(b.dataset.removePlan){state.plans.delete(b.dataset.removePlan);if($('sheet').open)closeSheet();renderHomeInsight();renderInsights();toast('已撤销这条计划。');return;}
    if(b.dataset.dismissInsight){state.dismissed.add(b.dataset.dismissInsight);closeSheet();renderHomeInsight();renderInsights();toast('已收起这条洞察，谢谢你的反馈。');return;}
    if(b.dataset.detailTab){document.querySelectorAll('[data-detail-tab]').forEach(tab=>tab.setAttribute('aria-selected',String(tab===b)));$('recordContent').textContent=activeRecord[b.dataset.detailTab];$('recordContent').setAttribute('aria-labelledby',b.id);return;}
    if(b.dataset.source){openSource(b.dataset.source);return;}
    if(b.dataset.connectSource){sources[b.dataset.connectSource].enabled=true;renderSources();closeSheet();toast('示例来源已连接，未读取真实数据。');return;}
    const actions={watchButton:openWatch,dateButton:openCalendar,searchButton:()=>showView('library',{focusSearch:true}),settingsButton:()=>showView('data'),allMomentsButton:()=>showView('library'),captureButton:openCapture,closeSheet,captureImagesButton:()=>photos.openCapture(),asrSettingsButton:()=>modelSettings.openASR(),aiModelSettingsButton:()=>modelSettings.openAI(),startRecordingButton:startRecording,finishRecording,playButton:togglePlayback,clearDayButton:()=>{state.day=17;state.filter='all';state.query='';$('searchInput').value='';renderDay();showView('today');}};
    actions[b.id]?.();
  });
  $('searchInput').addEventListener('input',event=>{state.query=event.target.value;renderRecordLists();});
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
  photos=window.createDaybookPhotos({...sharedUI,onSave:record=>{records.push({...record,day:TODAY,start:NOW,end:NOW,time:'16:30',duration:0});closeSheet();resetToToday();toast('图片已留在今天，刷新后清空。');}});
  modelSettings=window.createDaybookModelSettings(sharedUI);
  ai=window.createDaybookAI({
    $,esc,icon,toast,openSheet,closeSheet,openCalendar,showView,
    getDay:()=>state.day,getView:()=>state.view,
    getRecords:day=>records.filter(r=>r.day===day).map(r=>({...r})),
    today:TODAY
  });
  renderDay();
})();
