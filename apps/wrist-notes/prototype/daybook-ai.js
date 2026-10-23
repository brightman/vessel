/* Interactive concept only: deterministic example replies, memory-only reminders. */
window.createDaybookAI = function (app) {
  'use strict';
  const {$,esc,icon,toast,openSheet,closeSheet,showView,getDay,getView,getRecords,getInsight,today,getProvider,setRemoteConfirmationRequired,openModelSettings,usageLink}=app;
  const prefs={proactive:true,frequency:1,quiet:true,quietStart:'22:00',quietEnd:'08:00',audio:true,health:true,photo:true,journal:true};
  const conversations=new Map(), reminders=[];
  const apple=window.createDaybookAppleReminders(app);
  const clock={minutes:990}; // The entire prototype uses 2026-10-19, 16:30.
  let pending=null,sequence=0,draft=null,snoozedUntil=0,dismissed=false,remotePreview=null;
  const scopeNames={audio:'语音与闪念',photo:'图片与补充说明',health:'睡眠与活动'};
  const scopeOf=r=>r.kind==='image'?'photo':r.kind==='sleep'||r.kind==='activity'?'health':r.kind==='journal'?'journal':'audio';
  const allowed=r=>prefs[scopeOf(r)];
  // Dates intentionally follow the prototype's fixed October 2026 clock.
  const demoToday=`2026-10-${String(today).padStart(2,'0')}`;
  const shifted=(iso,days)=>{const d=new Date(iso+'T12:00:00Z');d.setUTCDate(d.getUTCDate()+days);return d.toISOString().slice(0,10);};
  let range={start:shifted(demoToday,-6),end:demoToday};
  const rangeKey=()=>`${range.start}/${range.end}`;
  const isoFor=day=>`2026-10-${String(day).padStart(2,'0')}`;
  const recordsFor=day=>isoFor(day)>=range.start&&isoFor(day)<=range.end?getRecords(day).filter(allowed):[];
  const rangeRecords=()=>Array.from({length:31},(_,i)=>recordsFor(i+1)).flat();
  const shortDate=iso=>`${iso.slice(0,4)}年${Number(iso.slice(5,7))}月${Number(iso.slice(8))}日`;
  const rangeLabel=()=>range.start===range.end?shortDate(range.start):`${shortDate(range.start)}–${shortDate(range.end)}`;
  const allRecords=()=>Array.from({length:today},(_,i)=>getRecords(i+1)).flat().filter(allowed);
  let lastTopic='';
  function inferScope(question){
    const weekStart=shifted(demoToday,-((new Date(demoToday+'T12:00:00Z').getUTCDay()+6)%7));
    const dayMatch=question.match(/(\d{1,2})月(\d{1,2})[日号]?/);
    let label='全部获准使用的示例记录';
    range={start:'0001-01-01',end:demoToday};
    if(dayMatch){const date=`2026-${dayMatch[1].padStart(2,'0')}-${dayMatch[2].padStart(2,'0')}`;range={start:date,end:date};label=rangeLabel();}
    else if(/昨天|今天/.test(question)){const date=/昨天/.test(question)?shifted(demoToday,-1):demoToday;range={start:date,end:date};label=rangeLabel();}
    else if(/上个月/.test(question)){range={start:'2026-09-01',end:'2026-09-30'};label='上个月 · 2026年9月';}
    else if(/上周/.test(question)){range={start:shifted(weekStart,-7),end:shifted(weekStart,-1)};label='上周 · '+rangeLabel();}
    else if(/再往前|更早|全部|之前|以前/.test(question)){label='跨时间查找获准使用的记录';}
    else if(/最近|这段时间|近一周/.test(question)){range={start:shifted(demoToday,-6),end:demoToday};label='最近 7 天 · '+rangeLabel();}
    return label;
  }
  const dateLabel=day=>`10月${day}日`;
  const hhmm=minutes=>`${String(Math.floor(minutes/60)).padStart(2,'0')}:${String(minutes%60).padStart(2,'0')}`;
  const asMinutes=value=>{const [h,m]=value.split(':').map(Number);return h*60+m;};
  const isQuiet=()=>{if(!prefs.quiet)return false;const start=asMinutes(prefs.quietStart),end=asMinutes(prefs.quietEnd);return start<end?clock.minutes>=start&&clock.minutes<end:clock.minutes>=start||clock.minutes<end;};
  const currentThread=()=>{if(!conversations.has('main'))conversations.set('main',[]);return conversations.get('main');};
  const currentReminder=()=>reminders.find(r=>r.origin==='walk'&&!r.done);
  const dueReminder=()=>reminders.find(r=>!r.done&&!r.appleId&&r.date==='2026-10-19'&&asMinutes(r.time)<=clock.minutes);
  const reminderDate=r=>`${Number(r.date.slice(5,7))}月${Number(r.date.slice(8))}日 ${r.time}`;
  const sourcesMarkup=ids=>`<div class="ai-sources">${ids.map(id=>{
    const r=allRecords().find(row=>row.id===id);
    return r&&allowed(r)?`<button data-record="${esc(id)}">${icon('Link2')}<span>${dateLabel(r.day)} ${r.time} · ${esc(r.title)}</span>${icon('ArrowUpRight')}</button>`:'';
  }).join('')}</div>`;
  function reminderMarkup(){
    const r=dueReminder();if(!r||getDay()!==today)return '';
    return `<article class="ai-nudge"><div class="ai-nudge-top"><span>${icon('Bell')}${r.time} · 你确认的提醒</span><span>时机演示</span></div><h3>${esc(r.title)}</h3><p>给这件小事留一点时间。现在不方便，也可以半小时后再看。</p><div class="ai-nudge-actions"><button class="primary-button" data-ai-done="${r.id}">${icon('Check')}已完成</button><button class="secondary-button" data-ai-delay="${r.id}">半小时后</button><button class="text-button" data-ai-edit="${r.id}">调整</button></div></article>`;
  }
  function proactiveMarkup(){return ''; /* Proactive Insights are deferred. */}
  function renderHome(){
    const nudge=reminderMarkup()||proactiveMarkup();
    $('homeAI').innerHTML=nudge;
    $('homeAI').hidden=!nudge;
  }
  function answerMarkup(turn){
    if(turn.pending)return `<div class="ai-thinking">${icon('AudioLines')}${esc(turn.searchStatus)}</div>`;
    const a=turn.answer;
    if(a.evidence.some(id=>{const r=Array.from({length:today},(_,i)=>getRecords(i+1)).flat().find(row=>row.id===id);return !r||!allowed(r);})){
      return `<div class="ai-answer"><p>这条回答使用的数据已被你关闭，内容已收起。</p><button class="text-button" data-ai-ask="${esc(turn.question)}">使用当前允许的数据重新回答 ${icon('RotateCcw')}</button></div>`;
    }
    return `<div class="ai-answer"><div class="ai-answer-label">${icon('MessageCircle')}WiseLife AI<span>${esc(a.context)} · 示例回答</span></div><div class="ai-provider-provenance"><span>${esc(turn.provider.label)}</span>${turn.provider.id==='chatgpt'?`<span>·</span><span>${esc(turn.provider.model)}</span>`:''}</div><h3>${esc(a.title)}</h3>${a.paragraphs.map(p=>`<p>${esc(p)}</p>`).join('')}${a.search?`<p class="ai-answer-note">查找范围：${esc(a.search)}<br>引用记录：${esc(a.coverage)}</p>`:''}${sourcesMarkup(a.evidence)}${a.note?`<p class="ai-answer-note">${esc(a.note)}</p>`:''}<div class="ai-answer-actions">${a.remind?`<button class="secondary-button" data-ai-remind="${a.remind}">${icon('Bell')}设一个提醒</button>`:''}${a.followup?`<button class="text-button" data-ai-ask="${esc(a.followup)}">继续：${esc(a.followup)} ${icon('ArrowRight')}</button>`:''}${a.retry?`<button class="secondary-button" data-ai-ask="${esc(turn.question)}">${icon('RotateCcw')}重新回答</button>`:''}</div></div>`;
  }
  function render(){
    const list=allRecords(),thread=currentThread();
    const provider=getProvider();
    $('aiProvider').innerHTML=`<button class="ai-provider-button" data-ai-action="models">${icon(provider.remote?'MessageCircle':'ShieldCheck')}<span><span>${esc(provider.label)}</span><small>${!provider.ready?'模型暂不可用':provider.id==='chatgpt'?'使用 ChatGPT 套餐':provider.remote?'通过自定义服务处理':'在本机处理'}</small></span>${icon('ChevronDown')}</button>${provider.id==='chatgpt'?usageLink():''}`;
    renderHome();
    $('aiContext').textContent='按问题查找相关记录';
    $('aiReminderCount').textContent=reminders.filter(r=>!r.done).length;
    $('aiWelcome').hidden=thread.length>0;
    $('aiProactive').innerHTML=reminderMarkup()||(thread.length?'':proactiveMarkup());
    $('aiPrompts').hidden=thread.length>0;
    const prompts=list.length?['昨天有哪些值得跟进的事？','我之前记下过哪些想法？','最近的睡眠有什么变化？']:['这段时间有哪些记录？','明天提醒我做个语音回顾'];
    $('aiPrompts').innerHTML=prompts.map(p=>`<button data-ai-ask="${p}">${p}${icon('ArrowUpRight')}</button>`).join('');
    $('aiConversation').innerHTML=thread.map(turn=>`<article class="ai-turn"><p class="ai-user-message" translate="no">${esc(turn.question)}</p>${answerMarkup(turn)}</article>`).join('');
    $('aiConversation').setAttribute('aria-busy',String(!!pending));
    $('aiSend').hidden=!!pending;$('aiStop').hidden=!pending;
    $('aiSend').disabled=!$('aiQuestion').value.trim();
    $('aiComposerHint').textContent=pending?'正在演示回答过程，可随时停止':'仅使用你允许的记录 · 示例回答';
    document.querySelectorAll('[data-ai-ask]').forEach(b=>b.disabled=!!pending);
  }
  function resolveDay(question,fallback){
    const match=question.match(/10\s*月\s*(\d{1,2})\s*[日号]/);
    if(match)return Number(match[1]);
    if(/昨天/.test(question))return today-1;
    if(/今天/.test(question))return today;
    return fallback;
  }
  function reply(question,fallback){
    const day=resolveDay(question,fallback),explicit=/10\s*月\s*\d{1,2}|昨天|今天/.test(question),list=explicit?recordsFor(day):rangeRecords(),ids=list.map(r=>r.id);
    const period=explicit?dateLabel(day):range.start==='0001-01-01'?'已有记录':rangeLabel();
    const has=id=>ids.includes(id);
    const result=(title,paragraphs,evidence=[],extra={})=>({title,paragraphs,evidence,context:period,...extra});
    if(/提醒/.test(question)){
      if(/日记|手记|写一句|语音回顾/.test(question))return result('把这个小习惯，留给明天。',['可以先拟一条“录一段今天的回顾”。点下方选择时间，确认后才会加入原型内的提醒。'],[],{remind:'journal'});
      if(/周五|反馈/.test(question)&&has('meeting'))return result('周五回顾反馈，可以先留个提醒。',['09:40 的碰头记录提到了周五集中回顾使用反馈。下面的时间只是建议，你可以调整。'],['meeting'],{remind:'review'});
      if(/首版|范围|做减法/.test(question)&&has('review'))return result('把首版范围写成 3 行。',['建议写下要做什么、暂缓什么、怎样算完成。先确认提醒时间，我再替你记下来。'],['review'],{remind:'scope'});
      return result('先把提醒说具体一点。',['这个原型支持“提醒我做个语音回顾”“提醒我写首版范围”和“周五回顾反馈”示例。也可以直接新建一条，自己填写内容与时间。'],[],{remind:'custom'});
    }
    if(!list.length)return result('这次查找没有找到可用的记录。',[`${period}没有允许 AI 使用的记录。我无法据此总结你的经历；你可以说“再往前找找”，或在 AI 偏好中检查数据权限。`],[],{note:'不会用其他日期的记录替代你明确指定的时间。'});
    if(/想法|创业|灵感/.test(question)){
      const ideas=list.filter(r=>r.kind==='thought'&&(!/创业/.test(question)||/创业/.test([r.title,r.text,r.summary].join(' '))));
      return ideas.length?result('这些想法，值得再看一眼。',ideas.map(r=>`${dateLabel(r.day)}：${r.preview||r.text||r.title}`),ideas.map(r=>r.id),{note:'按示例类型与关键词查找，未进行真实语义检索。'}):result('没有找到匹配的想法。',['现有示例记录不足以回答，不会用无关内容补齐。']);
    }
    if(/图片|照片|截图|白板|原图/.test(question)){
      const photos=list.filter(r=>r.kind==='image');
      if(!photos.length)return result('查找范围没有可用的图片记录。',['可以用“记此刻”拍照或从相册选择，也可以在 AI 偏好中允许使用图片。']);
      const descriptions=photos.map(r=>[r.caption?`你补充的说明：「${r.caption}」`:'没有补充说明。',r.ocr?`示例图中的预置文字：\n${r.ocr}`:'这条图片尚未识别，不能根据画面推断内容。'].join('\n'));
      return result(`${period}，留住了 ${photos.reduce((n,r)=>n+r.images.length,0)} 张图片。`,descriptions,photos.map(r=>r.id),{note:'原型仅引用你填写的说明和示例图的预置文字。点击来源可回看原图，未进行真实图片分析。'});
    }
    if(/最近|趋势|变化|几天|一周/.test(question)&&/睡|休息/.test(question)){
      const sleeps=list.filter(r=>r.kind==='sleep').sort((a,b)=>a.day-b.day);
      if(sleeps.length<2)return result('记录还不够，先不判断趋势。',['目前允许使用的数据里，没有相邻两天的睡眠记录。可以允许“睡眠与活动”，或再积累一些记录。'],sleeps.map(r=>r.id));
      return result('比前一天少了 30 分钟，还不代表趋势。',['10月18日记录到 7 小时 48 分钟，10月19日为 7 小时 18 分钟。两条记录只能比较时长，不能判断睡眠质量或长期变化。','如果想观察，可以先固定几天的睡前回顾时间，再结合自己的感受。'],sleeps.map(r=>r.id),{context:'10月18–19日',note:'这里只比较示例时长，不作健康诊断。'});
    }
    if(/散步|步行|活动|运动|走了多久/.test(question)){
      const walks=list.filter(r=>r.kind==='activity');
      if(!walks.length)return result('没有可用的活动记录。',['查找范围没有允许 AI 使用的活动数据，我无法判断你走了多久。']);
      const duration=walks.reduce((sum,r)=>sum+r.duration,0)/60;
      return result(`${period}，留下了 ${duration} 分钟步行。`,[`${walks.map(r=>`${r.time} 的步行 ${r.duration/60} 分钟`).join('，')}。${day===today&&has('thought-morning')?'早上的步行结束 6 分钟后，你记下了首版方向；这只是时间相邻，不能说明步行带来了灵感。':''}`],walks.map(r=>r.id).concat(day===today&&has('thought-morning')?['thought-morning']:[]),{followup:'帮我回顾这段时间'});
    }
    if(/睡眠|睡了|睡得/.test(question)){
      const sleep=list.find(r=>r.kind==='sleep');
      return sleep?result('先看记录，再看自己的感受。',[sleep.summary],[sleep.id],{followup:'最近的睡眠有什么变化？'}):result('没有可用的睡眠记录。',['可以在 AI 偏好里允许“睡眠与活动”，或说“再往前找找”。']);
    }
    if(/周五|反馈/.test(question)&&has('meeting'))return result('周五，回顾这周的使用反馈。',['09:40 的项目碰头里约定，周五集中看看录音、转写和回顾路径的使用反馈。记录没有约定具体时间，可以先拟为 10月23日 16:00。'],['meeting'],{remind:'review'});
    if(/首版|范围|减法|跟进|重要|建议|下一步|计划|具体|怎么做|该做/.test(question)){
      if(has('thought-morning')&&has('thought-noon')&&has('review'))return result('先把首版范围写成 3 行。',['你在 08:36 和 11:18 的闪念里都提到收小范围；14:00 的讨论又落到了“先列清首版范围”。这是这一天值得继续推进的一条线索。','可以先写：\n1. 要做：跑通录音 → 转写 → 回顾。\n2. 暂缓：扩展更多数据来源。\n3. 完成标准：能从一条洞察回到原始记录。'],['thought-morning','thought-noon','review'],{remind:'scope',followup:'周五有什么需要跟进？',note:'这是基于记录的建议；我不知道你是否已完成，可以按实际情况调整。'});
      if(has('yesterday-note'))return result('先确定最重要的一件事。',['17:30 的记录里，你想在一天开始前先确定最重要的一件事，也留一点思考的空白。可以从写一句当天的重点开始。'],['yesterday-note'],{remind:'journal'});
      return result('目前还没有足够的内容判断优先级。',['可用记录里没有能支持这条建议的想法或讨论。你可以留下一段语音或图片，再查看现有记录。'],[],{followup:'帮我回顾这段时间'});
    }
    if(/回顾|总结|记录|做了什么|发生|这一天/.test(question)){
      const voice=list.filter(r=>r.kind==='voice'||r.kind==='thought'),walks=list.filter(r=>r.kind==='activity'),sleeps=list.filter(r=>r.kind==='sleep'),journals=list.filter(r=>r.kind==='journal'),photos=list.filter(r=>r.kind==='image');
      const paragraphs=[];
      if(voice.length)paragraphs.push(`留下 ${voice.length} 条语音与闪念，共约 ${Math.round(voice.reduce((n,r)=>n+r.duration,0)/60)} 分钟。${has('review')?'其中产品讨论聚焦于录音、转写和回顾的路径。':has('yesterday-note')?'你提到想先确定每天最重要的一件事。':''}`);
      if(walks.length)paragraphs.push(`记录到 ${walks.length} 次步行，共 ${walks.reduce((n,r)=>n+r.duration,0)/60} 分钟。`);
      if(sleeps.length)paragraphs.push(sleeps.map(sleep=>`${dateLabel(sleep.day)}睡眠 ${Math.floor(sleep.duration/3600)} 小时 ${Math.round(sleep.duration%3600/60)} 分钟。`).join("\n"));
      if(journals.length)paragraphs.push(`你还写了 ${journals.length} 条手记。最新一条是「${journals[journals.length-1].title}」。`);
      if(photos.length)paragraphs.push(`还留下 ${photos.length} 条图片记录，共 ${photos.reduce((n,r)=>n+r.images.length,0)} 张图片。可以打开原图回看。`);
      return result(`${period}，从 ${list.length} 条记录回看。`,paragraphs,list.map(r=>r.id),{note:day===today?'仅覆盖截至 16:30 的示例记录，未记录的时段无法还原。':'只描述已记录的部分。'});
    }
    const matched=list.filter(r=>question.length>=2&&(r.title.includes(question)||r.text.includes(question))).slice(0,3);
    if(matched.length)return result('找到几段可能相关的原文。',matched.map(r=>`「${r.preview}」`),matched.map(r=>r.id),{note:'这是原文匹配演示，尚未进行真实语义检索。'});
    return result('这个问题，原型还不能可靠回答。',['当前没有连接真实 AI。我可以演示按记录回顾、梳理首版方向、比较睡眠时长以及拟定提醒。你可以试试下方的问题。'],[],{followup:'帮我回顾这段时间'});
  }
  function scrollToConversation(){
    if(getView()==='ai')$('screenScroll').scrollTop=$('screenScroll').scrollHeight;
  }
  function ask(question){
    question=question.trim().slice(0,600);if(!question||pending||remotePreview)return;
    showView('ai');
    const provider=getProvider();
    if(!provider.ready){
      $('aiQuestion').value=question;
      openSheet('检查 ChatGPT 连接',`<div class="chatgpt-card"><h3>${provider.state==='limited'?'ChatGPT 用量已达上限':provider.state==='expired'?'授权已过期':'模型暂不可用'}</h3><p>当前选择不可用。请重新连接、管理用量，或在设置中主动切换模型。</p>${provider.state==='limited'?usageLink(true):''}</div><button class="secondary-button wide" data-ai-action="models">打开 AI 模型设置</button>`);render();return;
    }
    let search=inferScope(question);
    if(search.startsWith('最近 7 天')){
      const recent=rangeRecords();
      const insufficient=/睡|休息/.test(question)?recent.filter(r=>r.kind==='sleep').length<2:recent.length===0;
      if(insufficient){range={start:'0001-01-01',end:demoToday};search='最近 7 天记录不足，已扩大到全部获准使用的示例记录';}
    }
    const isFollowup=/^(只看|再往前|更早)/.test(question);
    const effectiveQuestion=isFollowup&&lastTopic?`${question}，${lastTopic}`:question;
    if(!isFollowup)lastTopic=question.replace(/昨天|今天|上个月|上周|最近|这段时间|\d{1,2}月\d{1,2}[日号]?/g,'');
    const day=today,answer=reply(effectiveQuestion,day);
    const used=allRecords().filter(r=>answer.evidence.includes(r.id));
    const dates=[...new Set(used.map(r=>r.day))].sort((a,b)=>a-b);
    answer.search=search;
    answer.coverage=dates.length?`${dateLabel(dates[0])}${dates.length>1?'–'+dateLabel(dates.at(-1)):''} · ${used.length} 条`:'未引用记录';
    answer.context=dates.length?answer.coverage:'未找到可引用记录';
    if(provider.remote&&provider.requiresConfirmation!==false){
      $('aiQuestion').value=question;
      const available=rangeRecords();
      // Only text and safe metadata for the evidence used by this deterministic answer.
      // Never copy a full record object: it can contain image/audio blobs or local URLs.
      const texts=answer.evidence.map(id=>available.find(r=>r.id===id)).filter(Boolean).map(r=>({
        id:r.id,title:r.title,day:r.day,time:r.time,
        text:[r.source,`${r.duration||0} s`,r.kind==='image'?`${r.images?.length||0} images`:'',r.summary,r.preview,r.text,r.caption,r.ocr].filter(Boolean).filter((v,i,a)=>a.indexOf(v)===i).join('\n\n')
      }));
      remotePreview={question,day,provider,answer,rangeKey:rangeKey(),scope:JSON.stringify(prefs)};
      openSheet('发送前，确认这次使用的文字',`<p class="sheet-intro"><span>处理服务</span> · <strong>${esc(provider.destination)}</strong></p><p class="source-footnote">${provider.id==='chatgpt'?'使用 ChatGPT 套餐':'通过自定义服务处理'}</p><div class="ai-remote-preview"><p class="source-footnote">自动查找范围：${esc(answer.search)}</p><h3>你的问题</h3><p id="aiOutgoingQuestion" translate="no">${esc(question)}</p></div><div class="ai-remote-records"><h3><span>本次引用的记录</span> · ${texts.length}</h3>${texts.length?texts.map(r=>`<details data-outgoing-record="${esc(r.id)}"><summary translate="no">${dateLabel(r.day)} ${esc(r.time)} · ${esc(r.title)}</summary><pre translate="no">${esc(r.text)}</pre></details>`).join(''):'<p class="source-footnote">没有引用记录，仅使用你的问题。</p>'}</div><p class="source-footnote">录音、图片文件和“我的声音”档案不会发送。原型仅模拟，不进行网络请求。</p><label class="ai-send-preference"><input id="aiDoNotAskAgain" type="checkbox"><span>下次不再提示</span></label><p class="source-footnote">适用于外部 AI 问答、总结与长录音标题。开启免提示后，长录音标题会自动生成；可在「设置 → AI 模型」中恢复确认。</p><div class="model-actions chatgpt-preview-actions"><button class="secondary-button" data-ai-action="cancel-send">取消并保留问题</button><button class="primary-button" data-ai-action="confirm-send">确认并模拟发送</button></div>`);
      return;
    }
    startAnswer({question,day,provider,answer});
  }
  function startAnswer({question,day,provider,answer}){
    const turn={id:++sequence,question,pending:true,searchStatus:`正在查找相关记录 · ${answer.search}…`,provider:{...provider}};
    currentThread().push(turn);$('aiQuestion').value='';$('aiQuestion').style.height='';
    pending={turn,day,context:answer.context,timer:setTimeout(()=>{
      turn.answer=answer;
      turn.pending=false;pending=null;render();scrollToConversation();
    },650)};
    render();scrollToConversation();
  }
  function confirmSend(){
    if(!remotePreview)return;
    const request=remotePreview,provider=getProvider();remotePreview=null;
    if(provider.revision!==request.provider.revision||!provider.ready||JSON.stringify(prefs)!==request.scope||rangeKey()!==request.rangeKey){
      closeSheet();toast('模型或数据范围已变化，请重新预览后再发送。');return;
    }
    if($('aiDoNotAskAgain')?.checked)setRemoteConfirmationRequired(false);
    closeSheet();startAnswer(request);
  }
  function stop(){
    if(!pending)return;
    clearTimeout(pending.timer);pending.turn.pending=false;
    pending.turn.answer={title:'已停止这次回答。',paragraphs:['想继续时，可以重新回答。'],evidence:[],context:pending.context,retry:true};
    pending=null;render();
  }
  function openNudgeWhy(){
    openSheet('为什么现在建议',`<div class="insight-label">${icon('Lightbulb')}10月19日 · 示例洞察</div><h3 class="insight-detail-title">午间的想法，有了后续记录。</h3><p class="sheet-intro">11:50 说想出去走走，12:15–12:31 有步行记录，12:40 又留下了走回后的想法。建议仅是明天再留一点空白，可由你决定要不要采纳。</p>${sourcesMarkup(['walk-intent','walk-noon','walk-followup'])}<div class="quiet-info">${icon('CircleHelp')}<p>这三段记录不能证明步行带来了新想法，也不能判断活动对健康的影响。</p></div><button class="primary-button wide" data-ai-remind="walk">${icon('Bell')}拟定一个提醒</button>`);
  }
  function openNudgeOptions(){
    openSheet('这条建议，按你的节奏',`<p class="sheet-intro">稍后再看，或告诉 AI 这件事已经处理好了。</p><button class="plain-row" data-ai-action="snooze"><span>${icon('Clock3')}1 小时后再看</span>${icon('ChevronRight')}</button><button class="plain-row" data-ai-action="dismiss"><span>${icon('Check')}已处理 / 今天不再建议</span>${icon('ChevronRight')}</button><button class="plain-row" data-ai-action="preferences"><span>${icon('Settings2')}调整主动建议与免打扰</span>${icon('ChevronRight')}</button><p class="source-footnote">原型只模拟时机，不会发出系统通知。</p>`);
  }
  function createDraft(kind,id){
    const existing=reminders.find(r=>r.id===id);
    if(existing){draft={...existing,evidence:[...existing.evidence]};}
    else {
      const same=reminders.find(r=>r.origin===kind&&!r.done);
      if(same){openReminders();return;}
      const options={
        walk:{title:'午休留一点走走和回顾的时间',date:'2026-10-20',time:'12:00',evidence:['walk-intent','walk-noon','walk-followup'],origin:'walk'},
        scope:{title:'把首版范围写成 3 行',date:clock.minutes>=1080?'2026-10-20':'2026-10-19',time:'18:00',evidence:['review'],origin:'scope'},
        review:{title:'回顾本周的使用反馈',date:'2026-10-23',time:'16:00',evidence:['meeting'],origin:'review'},
        journal:{title:'录一段今天的回顾',date:'2026-10-20',time:'20:30',evidence:[],origin:'journal'},
        custom:{title:'',date:'2026-10-20',time:'09:00',evidence:[],origin:'custom'}
      };
      draft={appleEnabled:false,appleList:'WiseLife',...options[kind||'custom'],evidence:[...(options[kind]?.evidence||[])]};
    }
    renderDraft();
  }
  function captureDraft(){
    if(!draft||!$('aiReminderForm'))return;
    draft.title=$('aiReminderTitle').value;draft.date=$('aiReminderDate').value;draft.time=$('aiReminderTime').value;
    if($('appleDemoResult'))apple.setResult($('appleDemoResult').value);
  }
  document.addEventListener('change',event=>{if(event.target.id==='appleDemoResult')apple.setResult(event.target.value);});
  function renderDraft(){
    openSheet(draft.id?'修改提醒':'先确认，再替你记下',`<p class="sheet-intro">选一个适合自己的时刻。确认前，不会创建提醒。</p><form id="aiReminderForm"><label class="note-field"><span>提醒我</span><input id="aiReminderTitle" required maxlength="80" value="${esc(draft.title)}" placeholder="想提醒自己做什么"></label><div class="ai-field-grid"><label class="note-field"><span>日期</span><input id="aiReminderDate" type="date" required min="2026-10-19" value="${draft.date}"></label><label class="note-field"><span>时间</span><input id="aiReminderTime" type="time" required value="${draft.time}"></label></div>${draft.evidence.length?`<div class="ai-confirm-preview">来自你的记录${sourcesMarkup(draft.evidence).replaceAll('data-record=', 'data-apple-evidence=')}</div>`:''}${apple.controls(draft)}<p class="source-footnote ai-reminder-note">这是原型内的提醒，刷新后清空，不会发送系统通知。你确认的提醒与 AI 主动建议分别管理。</p><p id="aiReminderError" class="ai-inline-error" role="alert" hidden></p><div class="sheet-actions"><button class="secondary-button" type="button" data-ai-action="cancel-draft">取消</button><button class="primary-button" type="submit">${icon('Check')}${draft.id?'保存修改':'确认提醒'}</button></div></form>`);
  }
  function saveReminder(form){
    if(!draft||!form.reportValidity())return;
    const title=$('aiReminderTitle').value.trim(),date=$('aiReminderDate').value,time=$('aiReminderTime').value;
    const fail=message=>{$('aiReminderError').textContent=message;$('aiReminderError').hidden=false;};
    if(!title)return fail('请写下提醒内容。');
    if(!/^\d{4}-\d{2}-\d{2}$/.test(date)||!/^\d{2}:\d{2}$/.test(time)||date<'2026-10-19'||(date==='2026-10-19'&&asMinutes(time)<=clock.minutes))return fail('请选择晚于原型当前时刻的时间。');
    const duplicate=reminders.find(r=>!r.done&&r.id!==draft.id&&r.title===title&&r.date===date&&r.time===time);
    if(duplicate)return fail('同一时间已经有这条提醒，可以在提醒列表中修改。');
    const next={...draft,title,date,time,done:draft.done||false,id:draft.id||`reminder-${++sequence}`};
    apple.write(next);
    const index=reminders.findIndex(r=>r.id===draft.id);
    if(index>=0)reminders[index]=next;else reminders.push(next);
    draft=null;render();openReminders();toast(next.appleStatus==='pending'?'Apple 更新待重试，原任务可能仍提醒。':next.appleStatus==='failed'?'已保留 WiseLife 提醒，可重试添加 Apple。':'已保存示例提醒，不会发送系统通知。');
  }
  function openReminders(){
    const sorted=[...reminders].sort((a,b)=>Number(a.done)-Number(b.done)||(a.date+a.time).localeCompare(b.date+b.time));
    openSheet('我的提醒',`<p class="sheet-intro">你确认过的小行动，都在这里。<br>原型当前：10月19日 ${hhmm(clock.minutes)}。</p>${sorted.length?sorted.map(r=>`<article class="ai-reminder-row"><h3>${r.done?'✓ ':''}${esc(r.title)}</h3><p>${reminderDate(r)} · ${r.done?'已完成':'已确认'}</p><p class="apple-reminder-status">${apple.status(r)}</p><div class="ai-reminder-actions">${r.appleId?`<button data-apple-preview="${r.id}">Apple 只读预览</button>`:''}${['failed','pending'].includes(r.appleStatus)?`<button data-apple-retry="${r.id}">重试添加 Apple</button>`:''}${r.done?'':`<button data-ai-edit="${r.id}">修改时间 / 内容</button><button data-ai-done="${r.id}">标记完成</button>`}<button data-ai-delete="${r.id}">${r.appleId?'删除两处示例任务':r.done?'移除':'取消提醒'}</button></div></article>`).join(''):`<div class="empty-state">${icon('Bell')}<h3>还没有安排提醒</h3><p>有值得跟进的事，再轻轻提醒你。</p></div>`}<button class="primary-button wide" data-ai-remind="custom">${icon('Plus')}新建提醒</button><p class="source-footnote">所有操作仅在本页内演示，刷新后清空。已添加 Apple 的任务仅由 Apple 提醒（概念演示），WiseLife 不重复提醒。修改、完成、删除会同步更新关联的两处示例；失败时保留 WiseLife 提醒并可重试。</p>`);
  }
  function preferences(){
    openSheet('AI 偏好与提醒',`<div class="ai-prefs-row"><div><strong>主动给我建议</strong><p>发现值得跟进的线索时，在 App 内提醒我。</p></div><button class="switch" role="switch" aria-checked="${prefs.proactive}" aria-label="主动给我建议" data-ai-pref="proactive"></button></div><h3 class="sheet-section-title">建议上限</h3><div class="ai-settings-options" role="group" aria-label="建议上限"><button data-ai-frequency="1" aria-pressed="${prefs.frequency===1}">有合适内容时最多 1 条</button><button data-ai-frequency="3" aria-pressed="${prefs.frequency===3}">有合适内容时最多 3 条</button></div><p class="subtle">没有可靠联系或有用建议时，不生成洞察，也不提醒。</p><div class="ai-prefs-row"><div><strong>免打扰时段</strong><p>此时收起主动建议，仍可主动向 AI 提问。</p></div><button class="switch" role="switch" aria-checked="${prefs.quiet}" aria-label="免打扰时段" data-ai-pref="quiet"></button></div><form id="aiQuietForm"><div class="ai-field-grid"><label class="note-field"><span>开始</span><input id="aiQuietStart" type="time" required value="${prefs.quietStart}"></label><label class="note-field"><span>结束（可跨天）</span><input id="aiQuietEnd" type="time" required value="${prefs.quietEnd}"></label></div><p id="aiQuietError" class="ai-inline-error" role="alert" hidden></p><button class="secondary-button" type="submit">保存时段</button></form><h3 class="sheet-section-title">允许 AI 使用的记录</h3>${Object.entries(scopeNames).map(([key,name])=>`<div class="ai-prefs-row"><div><strong>${name}</strong><p>${key==='audio'?'录音转写、讨论与随手说出的想法':key==='health'?'只描述记录，不推断健康状况':'你选择的图片与说明，未自动读取相册'}</p></div><button class="switch" role="switch" aria-checked="${prefs[key]}" aria-label="允许 AI 使用${name}" data-ai-pref="${key}"></button></div>`).join('')}<p class="source-footnote">关闭后，新回答不再使用该类记录，已有相关回答会收起。暂停数据采集则仍可回顾历史记录。已确认的提醒由你单独管理。</p><button class="plain-row" data-ai-action="reminders"><span>${icon('Bell')}管理已确认的提醒</span>${icon('ChevronRight')}</button><h3 class="sheet-section-title">预览建议出现的时机</h3><p class="subtle">演示时刻仅用于 AI 时机预览，首页记录仍截至 16:30。</p><div class="ai-settings-options" role="group" aria-label="演示时刻">${[990,1050,1080,1350].map(t=>`<button data-ai-clock="${t}" aria-pressed="${clock.minutes===t}">${hhmm(t)}</button>`).join('')}</div><p class="ai-preference-status">${isQuiet()?'当前处于免打扰时段。':snoozedUntil>clock.minutes?`这条建议将在 ${hhmm(snoozedUntil)} 再出现。`:'当前可展示主动建议。'}${dismissed?'这条示例建议已收起。':''}</p><button class="text-button" data-ai-action="reset-nudge">重新展示这条示例建议</button>`);
  }
  function setPreference(key){
    if(!(key in prefs))return;
    stop();prefs[key]=!prefs[key];render();preferences();
    // Replacing the sheet contents should not leave keyboard focus on <body>.
    document.querySelector(`[data-ai-pref="${key}"]`)?.focus();
  }
  document.addEventListener('click',event=>{
    const button=event.target.closest('button');if(!button)return;
    if(button.dataset.appleEvidence){
      captureDraft();const r=[...getRecords(19),...getRecords(18)].find(row=>row.id===button.dataset.appleEvidence);
      if(r)openSheet('提醒来源',`<button class="text-button" data-apple-action="back">← 返回提醒草稿</button><h3>${esc(r.title)}</h3><p class="sheet-intro" translate="no">${esc(r.text||r.preview||r.summary||'')}</p><p class="source-footnote">来源留在 WiseLife，不添加到 Apple 提醒事项。</p>`);return;
    }
    if(button.dataset.applePreview){const r=reminders.find(r=>r.id===button.dataset.applePreview);if(r)apple.preview(r);return;}
    if(button.dataset.appleRetry){const r=reminders.find(r=>r.id===button.dataset.appleRetry);if(r){if(apple.needsPermission()){draft={...r,evidence:[...r.evidence]};apple.permissionSheet();}else{apple.write(r);render();openReminders();}}return;}
    if(button.dataset.appleAction||button.dataset.appleList){
      if(!draft)return;
      captureDraft();
      if(button.dataset.appleList){draft.appleList=button.dataset.appleList;renderDraft();return;}
      const action=button.dataset.appleAction;
      if(action==='toggle'){draft.appleEnabled=!draft.appleEnabled;if(draft.appleEnabled&&apple.needsPermission())apple.permissionSheet();else renderDraft();}
      if(action==='back')renderDraft();
      if(action==='lists')apple.choose(draft);
      if(action==='allow'){apple.setPermission('allowed');renderDraft();}
      if(action==='decline'){apple.setPermission('denied');apple.denied();}
      if(action==='local'){draft.appleEnabled=false;renderDraft();}
      if(action==='settings')apple.settings();
      return;
    }
    if(button.dataset.aiAsk){if($('sheet').open)closeSheet();ask(button.dataset.aiAsk);return;}
    if(button.dataset.aiRemind){createDraft(button.dataset.aiRemind);return;}
    if(button.dataset.aiEdit){createDraft(null,button.dataset.aiEdit);return;}
    if(button.dataset.aiDelay){
      const r=reminders.find(r=>r.id===button.dataset.aiDelay);
      if(r){const time=clock.minutes+30;r.time=hhmm(time%1440);if(time>=1440)r.date='2026-10-20';render();toast(`已改为 ${reminderDate(r)}，仅在原型内演示。`);}return;
    }
    if(button.dataset.aiDone){const r=reminders.find(r=>r.id===button.dataset.aiDone);if(r){r.done=true;apple.write(r);if(r.origin==='scope')dismissed=true;render();openReminders();}return;}
    if(button.dataset.aiDelete){const r=reminders.find(r=>r.id===button.dataset.aiDelete);if(!r)return;if(r.appleId){openSheet('删除关联提醒？',`<p class="sheet-intro">确认后删除 WiseLife 和 Apple 中的两处示例任务。Apple 删除失败时，两处任务都会保留，可以重试。</p><div class="sheet-actions"><button class="secondary-button" data-ai-action="reminders">返回我的提醒</button><button class="primary-button" data-apple-delete-confirm="${r.id}">确认删除两处示例任务</button></div>`);}else{reminders.splice(reminders.indexOf(r),1);render();openReminders();}return;}
    if(button.dataset.appleDeleteConfirm){const r=reminders.find(r=>r.id===button.dataset.appleDeleteConfirm);if(!r)return;if(apple.remove(r)){reminders.splice(reminders.indexOf(r),1);toast('已删除两处示例任务。');}else{toast('Apple 删除失败，两处示例任务仍保留，请重试。');}render();openReminders();return;}
    if(button.dataset.aiPref){setPreference(button.dataset.aiPref);return;}
    if(button.dataset.aiFrequency){prefs.frequency=Number(button.dataset.aiFrequency);preferences();document.querySelector(`[data-ai-frequency="${prefs.frequency}"]`)?.focus();return;}
    if(button.dataset.aiClock){clock.minutes=Number(button.dataset.aiClock);render();preferences();document.querySelector(`[data-ai-clock="${clock.minutes}"]`)?.focus();return;}
    const actions={
      preferences,reminders:openReminders,stop,
      models:()=>{remotePreview=null;openModelSettings();},
      'cancel-send':()=>{remotePreview=null;closeSheet();},'confirm-send':confirmSend,
      'nudge-why':openNudgeWhy,'nudge-options':openNudgeOptions,
      snooze:()=>{snoozedUntil=Math.min(1439,clock.minutes+60);render();closeSheet();toast(`已稍后再看，可在 AI 偏好中预览 ${hhmm(snoozedUntil)} 的状态。`);},
      dismiss:()=>{dismissed=true;render();closeSheet();toast('今天不再展示这条建议。');},
      'cancel-draft':()=>{draft=null;closeSheet();},
      'reset-nudge':()=>{dismissed=false;snoozedUntil=0;render();preferences();toast(currentReminder()?'已确认提醒，可先在提醒列表中调整。':'已重置示例建议，仍遵守偏好与免打扰设置。');}
    };
    actions[button.dataset.aiAction]?.();
  });
  document.addEventListener('submit',event=>{
    if(event.target.id==='aiChatForm'){event.preventDefault();ask($('aiQuestion').value);}
    if(event.target.id==='aiReminderForm'){event.preventDefault();saveReminder(event.target);}
    if(event.target.id==='aiQuietForm'){
      event.preventDefault();if(!event.target.reportValidity())return;
      const start=$('aiQuietStart').value,end=$('aiQuietEnd').value;
      if(start===end){$('aiQuietError').textContent='开始和结束时间需要不同。';$('aiQuietError').hidden=false;return;}
      prefs.quietStart=start;prefs.quietEnd=end;render();preferences();toast('已更新免打扰时段。');
    }
  });
  $('aiQuestion').addEventListener('input',()=>{$('aiSend').disabled=!$('aiQuestion').value.trim();$('aiQuestion').style.height='auto';$('aiQuestion').style.height=`${Math.min(104,Math.max(29,$('aiQuestion').scrollHeight))}px`;});
  $('aiQuestion').addEventListener('keydown',event=>{
    if(event.key==='Enter'&&!event.shiftKey&&!event.isComposing){event.preventDefault();ask($('aiQuestion').value);}
  });
  window.addEventListener('pagehide',()=>{clearTimeout(pending?.timer);});
  $('sheet').addEventListener('close',()=>{if(!$('sheet').open)remotePreview=null;});
  document.addEventListener('daybook-provider-change',()=>{
    if(pending&&pending.turn.provider.revision!==getProvider().revision){stop();toast('服务或授权已变化，请重新提问。');}
    render();
  });
  return {render,openReminders,createDraft};
};
