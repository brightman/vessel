/* Product design only: fictional health and capture locations, memory-only state.
   Does not query HealthKit, location, a server, or an AI model. */
window.createDaybookLifeMoments = function(app) {
  'use strict';
  const {esc,icon,openSheet,toast,getRecords,refresh,showTimeline} = app;
  let wakeConfirmed = false;
  let scenario = 'ready';
  const stepsID = 'yesterday-steps-total', moveID = 'city-change';
  const record = id => getRecords().find(r => r.id === id);
  const sampleSleep = {startLabel:'昨天 23:42',endLabel:'今天 07:18',asleep:438,awake:18,deep:72,core:268,rem:98};
  const distanceKM = (a,b) => {
    const rad = value => value*Math.PI/180;
    const deltaLat=rad(b.lat-a.lat), deltaLon=rad(b.lon-a.lon);
    const h=Math.sin(deltaLat/2)**2+Math.cos(rad(a.lat))*Math.cos(rad(b.lat))*Math.sin(deltaLon/2)**2;
    return 6371*2*Math.atan2(Math.sqrt(h),Math.sqrt(Math.max(0,1-h)));
  };
  function seed(records) {
    const sleep=records.find(r=>r.id==='sleep');
    Object.assign(sleep,{lifeMoment:'wake',start:7.3,end:7.3,time:'07:18',duration:26280,
      sleepRange:{start:0,end:7.3},title:'07:18 起床 · 估计',preview:'昨晚 23:42 入睡 · 实际睡眠 7小时18分',
      summary:'昨晚 23:42 至今天 07:18 的主睡眠中，实际睡眠合计 7小时18分，清醒合计 18分。07:18 是睡眠结束时间，起床时间待本人确认。',
      text:'Apple 健康示例：10月18日 23:42 入睡；10月19日 07:18 睡眠结束；实际睡眠 438分钟；清醒 18分钟。无睡眠质量评分。',tags:['睡眠','起床待确认']});
    records.push({id:stepsID,lifeMoment:'steps',day:19,kind:'activity',start:0,end:0,time:'00:00',duration:0,
      title:'昨天走了 6,240 步',preview:'10月18日全天累计 · 已更新',source:'Apple 健康',
      summary:'10月18日 00:00 至 10月19日 00:00，累计 6,240 步。此条在次日零点归档，数据实际更新于 07:22。',
      text:'统计日期：10月18日；昨日累计：6240步；归档时间：10月19日00:00；实际更新：10月19日07:22。',tags:['昨日汇总','已更新']});
    // Both coordinates are fictional capture metadata. The bridge never implies a route.
    Object.assign(records.find(r=>r.id==='board-photo').place,{lat:31.188,lon:121.437,city:'上海',accuracy:30});
    records.push({id:'suzhou-arrival',day:19,kind:'thought',start:16.2,end:16.2+48/3600,time:'16:12',duration:48,
      title:'把下午的问题先记下来',preview:'“到了苏州，先把下午要聊的三个问题记下来。”',source:'iPhone',captureDevice:'iphone',
      summary:'到苏州后，先整理下午想聊的三个问题。',text:'到了苏州，先把下午要聊的三个问题记下来，等见面时一件件聊。',tags:['闪念','问题'],
      place:{name:'苏州 · 姑苏区',area:'苏州 · 姑苏区',city:'苏州',lat:31.299,lon:120.585,source:'recordingPhone',time:'16:12',accuracy:25}});
    const from=records.find(r=>r.id==='board-photo'),to=records.find(r=>r.id==='suzhou-arrival');
    const distance=distanceKM(from.place,to.place);
    if(distance>50)records.push({id:moveID,lifeMoment:'move',day:19,kind:'location',start:to.start,end:to.start,time:to.time,duration:0,
      title:'从上海到苏州',preview:`两次记录相距约 ${Math.round(distance)} km · 14:28 → 16:12`,source:'片段地点',
      summary:'14:28 的照片位于上海，16:12 的录音位于苏州。两处直线距离超过 50 km；具体出发、抵达时间与路线未知。',
      text:'位置变化来自两条片段的位置。上海：14:28 照片；苏州：16:12 录音。',tags:['位置变化','2 条依据'],fromID:from.id,toID:to.id,distance});
  }
  function applyScenario(next) {
    scenario=next;wakeConfirmed=false;
    const steps=record(stepsID),sleep=record('sleep'),move=record(moveID);
    const pending=next==='pending',basic=next==='basic',unresolved=next==='unresolved';
    Object.assign(steps,{title:pending?'昨日步数 · 待同步':'昨天走了 6,240 步',preview:pending?'10月18日全天累计 · 等待健康数据':'10月18日全天累计 · 已更新',tags:['昨日汇总',pending?'待同步':'已更新']});
    steps.text=steps.summary=pending?'10月18日累计步数待同步，尚无可读数值。':'10月18日全天累计 6,240 步，10月19日 07:22 更新。';
    Object.assign(sleep,{title:pending?'昨夜睡眠 · 待同步':'07:18 起床 · 估计',preview:pending?'等待昨夜的完整睡眠记录':basic?'昨晚 23:42 入睡 · 7小时18分 · 暂无分期':'昨晚 23:42 入睡 · 实际睡眠 7小时18分',duration:pending?0:26280,
      time:pending?'—':'07:18',sleepRange:pending?null:{start:0,end:7.3},tags:['睡眠',pending?'待同步':'起床待确认']});
    sleep.text=sleep.summary=pending?'昨夜睡眠待同步，暂无入睡、醒来或时长数据。':`昨晚 23:42 入睡，今天 07:18 睡眠结束；实际睡眠 7小时18分，起床时间尚待本人确认。${basic?'当前来源未提供睡眠分期。':'清醒 18分钟。'}暂无质量评分。`;
    Object.assign(move,{title:unresolved?'位置变化 · 地点待解析':'从上海到苏州',preview:unresolved?`两次记录相距约 ${Math.round(move.distance)} km · 城市待确认`:`两次记录相距约 ${Math.round(move.distance)} km · 14:28 → 16:12`});
    Object.assign(record(move.fromID).place,{name:unresolved?'地点待解析':'办公室',area:unresolved?'31.188, 121.437':'上海 · 徐汇区',city:unresolved?null:'上海'});
    Object.assign(record(move.toID).place,{name:unresolved?'地点待解析':'苏州 · 姑苏区',area:unresolved?'31.299, 120.585':'苏州 · 姑苏区',city:unresolved?null:'苏州'});
    refresh();
  }
  function markup(r) {
    if(!r.lifeMoment)return '';
    const glyph={steps:'Footprints',wake:'Sun',move:'MapPin'}[r.lifeMoment];
    const pending=scenario==='pending'&&r.lifeMoment!=='move';
    return `<button class="moment lm-moment" data-kind="${r.kind}" data-record="${r.id}"><span class="moment-time">${r.time}${r.lifeMoment==='steps'?'<small>归档</small>':''}</span><span class="moment-main"><span class="lm-eyebrow">${icon(glyph)}<span>${{steps:'昨日步数',wake:'起床与睡眠',move:'位置变化'}[r.lifeMoment]}</span>${pending?'<span class="lm-status">待同步</span>':''}</span><span class="moment-title"><span>${esc(r.title)}</span>${icon('ChevronRight')}</span><span class="moment-description">${esc(r.preview)}</span><span class="moment-meta"><span>${esc(r.source)}</span><span>${esc(r.tags[1])}</span></span></span></button>`;
  }
  const info = text => `<div class="quiet-info">${icon('CircleHelp')}<p>${text}</p></div>`;
  const facts = rows => `<dl class="lm-facts">${rows.map(([key,value])=>`<div><dt>${key}</dt><dd>${value}</dd></div>`).join('')}</dl>`;
  const badge = (glyph,text) => `<div class="lm-detail-label">${icon(glyph)}${text}</div>`;
  function openSteps() {
    const pending=scenario==='pending';
    openSheet('昨日步数',`${badge('Footprints','10月18日 · 全天累计')}<div class="lm-hero">${pending?'<strong>待同步</strong>':'<strong>6,240</strong><span>步</span>'}</div><p class="lm-support">${pending?'还没有读到昨日步数，暂不显示为 0。':'一天走过的步数，留在今天的开始。'}</p>${facts([['统计范围','10月18日 00:00–24:00'],['归档时间','10月19日 00:00'],['数据来源','Apple 健康'],['最近更新',pending?'等待数据':'10月19日 07:22']])}${info(pending?'健康数据可能还未同步，也可能尚未允许读取。下次打开 App 或收到健康更新时补齐。':'每天 00:00 归档昨日累计。数据有延迟时会补齐并更新同一条记录，实际更新时间以这里为准。')}<p class="source-footnote">昨日步数不会计入今天的累计步数。</p>${pending?'<button class="secondary-button wide" data-lm-action="health">查看健康连接</button>':''}`);
  }
  function openSleep() {
    if(scenario==='pending') {
      openSheet('起床与昨夜睡眠',`${badge('Moon','10月18日 → 10月19日')}<div class="lm-hero"><strong>等待睡眠记录</strong></div><p class="sheet-intro">昨夜的睡眠还没有出现在这里。数据同步后，入睡、醒来与实际睡眠时长会一起补齐。</p>${info('暂不推测起床时间或睡眠质量。健康中没有可读数据，不能据此判断你没有睡觉或没有授权。')}<button class="secondary-button wide" data-lm-action="health">查看健康连接</button>`);
      return;
    }
    const basic=scenario==='basic';
    const stages=basic?'<p class="lm-support">当前来源未提供睡眠分期。</p>':`<div class="lm-stage-bar" role="img" aria-label="实际睡眠7小时18分：深睡1小时12分，核心睡眠4小时28分，REM睡眠1小时38分"><span class="deep" style="flex:${sampleSleep.deep}"></span><span class="core" style="flex:${sampleSleep.core}"></span><span class="rem" style="flex:${sampleSleep.rem}"></span></div><div class="lm-stage-legend"><span><i class="deep"></i>深睡 <b>1小时12分</b></span><span><i class="core"></i>核心 <b>4小时28分</b></span><span><i class="rem"></i>REM <b>1小时38分</b></span></div>`;
    openSheet('起床与昨夜睡眠',`${badge('Sun',wakeConfirmed?'本人已确认':'根据睡眠结束时间估计')}<div class="lm-hero"><strong>07:18</strong><span>起床${wakeConfirmed?'':' · 估计'}</span></div><div class="lm-sleep-pair"><div><span>昨晚入睡</span><strong>23:42</strong><small>10月18日</small></div>${icon('ArrowRight')}<div><span>今早醒来</span><strong>07:18</strong><small>10月19日</small></div></div>${facts([['实际睡眠','7小时18分'],['清醒时长',basic?'未提供':'18分'],['睡眠质量','暂无质量评分'],['数据来源','Apple 健康 · Apple Watch'],['最近更新','今天 07:22']])}${stages}${info('睡眠结束时间不一定是离床时间。确认后会作为你登记的起床时间，健康中的原始睡眠记录保持原样。')}<p class="source-footnote">${basic?'只展示来源提供的时长，睡眠分期和质量缺失时留空。':'分期表示各阶段累计时长，不是整夜的先后顺序；实际睡眠已扣除清醒时间。'} 仅在来源提供且可以读取时显示质量评价，并注明来源。</p><button class="${wakeConfirmed?'secondary-button':'primary-button'} wide" data-lm-action="${wakeConfirmed?'reset-wake':'confirm-wake'}">${icon(wakeConfirmed?'RotateCcw':'Check')}${wakeConfirmed?'撤销起床确认':'我在 07:18 起床'}</button><p class="source-footnote">原型确认只在当前页面生效，不写入健康。</p>`);
  }
  function openMove() {
    const r=record(moveID),unresolved=scenario==='unresolved';
    const from=record(r.fromID),to=record(r.toID);
    const evidence=(row,city)=>`<button class="lm-location-evidence" data-record="${row.id}"><span class="lm-evidence-point">${icon(row.kind==='image'?'Images':'AudioLines')}</span><span><small>${row.time} · ${city}</small><strong>${esc(row.title)}</strong><small>${row.kind==='image'?'照片原始位置':'录音开始位置'} · 约 ${row.place.accuracy} 米精度</small></span>${icon('ChevronRight')}</button>`;
    openSheet('位置变化',`${badge('MapPin','10月19日 · 由两条片段发现')}<h3 class="lm-route-title">${unresolved?'地点待解析':'上海 <span>→</span> 苏州'}</h3><p class="lm-support">两处直线距离约 <strong>${Math.round(r.distance)} km</strong></p>${facts([['前一条地点记录','14:28'],['后一条地点记录','16:12'],['位置变化条件','相距超过 50 km']])}<h4 class="sheet-section-title">两条地点依据</h4><div class="lm-route-evidence">${evidence(from,unresolved?'31.188, 121.437':'上海 · 徐汇区')}${evidence(to,unresolved?'31.299, 120.585':'苏州 · 姑苏区')}</div>${info(unresolved?'坐标已保存，城市名称暂未解析成功。解析后会更新这条位置变化，当前不推测城市。':'14:28 在上海留下照片，16:12 在苏州开始录音。变化发生在两次记录之间，无法确定具体出发、抵达时间或交通方式。')}<p class="source-footnote">来自片段已有的位置，不持续追踪。距离是两点间直线距离，不代表实际行程。地点均为示例。</p>`);
  }
  function open(r) {
    if(!r.lifeMoment)return false;
    ({steps:openSteps,wake:openSleep,move:openMove})[r.lifeMoment]();return true;
  }
  function preview(value='ready') {
    document.body.dataset.lifeMomentsPreview='true';
    applyScenario(['pending','basic','unresolved'].includes(value)?value:'ready');
    showTimeline();
    if(['steps','sleep','move'].includes(value))({steps:openSteps,sleep:openSleep,move:openMove})[value]();
    else if(value==='basic')openSleep();
    else if(value==='unresolved')openMove();
    document.querySelectorAll('[data-lm-preview]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.lmPreview===value)));
  }
  function handleClick(b) {
    if(b.dataset.lmPreview){preview(b.dataset.lmPreview);return true;}
    if(b.dataset.lmAction==='confirm-wake'||b.dataset.lmAction==='reset-wake'){
      wakeConfirmed=b.dataset.lmAction==='confirm-wake';
      const sleep=record('sleep');sleep.title=wakeConfirmed?'07:18 起床':'07:18 起床 · 估计';sleep.tags[1]=wakeConfirmed?'本人确认':'起床待确认';
      sleep.text=sleep.summary=`昨晚 23:42 入睡，今天 07:18 睡眠结束；实际睡眠 7小时18分。${wakeConfirmed?'本人确认 07:18 起床。':'起床时间尚待本人确认。'}暂无质量评分。`;
      refresh();openSleep();toast(wakeConfirmed?'起床时间已在原型中确认。':'已恢复为估计时间。');return true;
    }
    if(b.dataset.lmAction==='health'){
      openSheet('Apple 健康',`${badge('Heart','健康数据连接')}<p class="sheet-intro">读取你选择分享的步数与睡眠。数据暂未出现时，可检查「健康」中的记录和 WiseLife 的读取权限。</p>${info('本原型没有连接 Apple 健康，也不发起权限请求。真实 App 可在系统允许刷新时补齐数据，无法保证零点准时刷新。')}`);return true;
    }
    return false;
  }
  return {seed,markup,open,preview,handleClick};
};

window.daybookLifeMomentsCopy = [
  ['昨日步数','Yesterday’s steps','昨日の歩数'],['起床与睡眠','Wake-up & sleep','起床と睡眠'],
  ['位置变化','Location change','場所の変化'],['归档','Filed','記録'],['昨日汇总','Yesterday’s total','昨日の合計'],
  ['起床待确认','Confirm wake-up','起床未確認'],['本人确认','Confirmed by you','本人確認済み'],
  ['待同步','Awaiting sync','同期待ち'],['已更新','Updated','更新済み'],['2 条依据','2 source records','2件の根拠'],
  ['统计范围','Date range','集計期間'],['归档时间','Filed at','記録日時'],['最近更新','Last updated','最終更新'],
  ['实际睡眠','Time asleep','実際の睡眠'],['清醒时长','Time awake','覚醒時間'],['睡眠质量','Sleep quality','睡眠の質'],
  ['暂无质量评分','No quality score available','品質スコアなし'],['昨晚入睡','Fell asleep','昨夜の入眠'],['今早醒来','Woke up','今朝の覚醒'],
  ['未提供','Not provided','データなし'],['两条地点依据','Two source locations','2件の位置記録'],
  ['前一条地点记录','Earlier location record','前の位置記録'],['后一条地点记录','Later location record','後の位置記録']
];
