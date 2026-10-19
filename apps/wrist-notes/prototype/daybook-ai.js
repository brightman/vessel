/* Interactive concept only: deterministic example replies, memory-only reminders. */
window.createDaybookAI = function (app) {
  'use strict';
  const {$,esc,icon,toast,openSheet,closeSheet,openCalendar,showView,getDay,getView,getRecords,today}=app;
  const prefs={proactive:true,frequency:1,quiet:true,quietStart:'22:00',quietEnd:'08:00',audio:true,health:true,photo:true,journal:true};
  const conversations=new Map(), reminders=[];
  const clock={minutes:990}; // The entire prototype uses 2026-10-19, 16:30.
  let pending=null,sequence=0,draft=null,snoozedUntil=0,dismissed=false;
  const scopeNames={audio:'语音与闪念',photo:'图片与补充说明',health:'睡眠与活动'};
  const scopeOf=r=>r.kind==='image'?'photo':r.kind==='sleep'||r.kind==='activity'?'health':r.kind==='journal'?'journal':'audio';
  const allowed=r=>prefs[scopeOf(r)];
  const recordsFor=day=>getRecords(day).filter(allowed);
  const dateLabel=day=>`10月${day}日`;
  const hhmm=minutes=>`${String(Math.floor(minutes/60)).padStart(2,'0')}:${String(minutes%60).padStart(2,'0')}`;
  const asMinutes=value=>{const [h,m]=value.split(':').map(Number);return h*60+m;};
  const isQuiet=()=>{if(!prefs.quiet)return false;const start=asMinutes(prefs.quietStart),end=asMinutes(prefs.quietEnd);return start<end?clock.minutes>=start&&clock.minutes<end:clock.minutes>=start||clock.minutes<end;};
  const currentThread=()=>{if(!conversations.has(getDay()))conversations.set(getDay(),[]);return conversations.get(getDay());};
  const currentReminder=()=>reminders.find(r=>r.origin==='scope'&&!r.done);
  const dueReminder=()=>reminders.find(r=>!r.done&&r.date==='2026-10-19'&&asMinutes(r.time)<=clock.minutes);
  const reminderDate=r=>`${Number(r.date.slice(5,7))}月${Number(r.date.slice(8))}日 ${r.time}`;
  const sourcesMarkup=ids=>`<div class="ai-sources">${ids.map(id=>{
    const r=[...getRecords(19),...getRecords(18)].find(row=>row.id===id);
    return r&&allowed(r)?`<button data-record="${esc(id)}">${icon('Link2')}<span>${dateLabel(r.day)} ${r.time} · ${esc(r.title)}</span>${icon('ArrowUpRight')}</button>`:'';
  }).join('')}</div>`;
  const aiLink=subtitle=>`<button class="ai-home-link" data-view="ai">${icon('MessageCircle')}<span>问问我的 AI<small>${esc(subtitle)}</small></span>${icon('ArrowUpRight')}</button>`;
  function reminderMarkup(){
    const r=dueReminder();if(!r||getDay()!==today)return '';
    return `<article class="ai-nudge"><div class="ai-nudge-top"><span>${icon('Bell')}${r.time} · 你确认的提醒</span><span>时机演示</span></div><h3>${esc(r.title)}</h3><p>给这件小事留一点时间。现在不方便，也可以半小时后再看。</p><div class="ai-nudge-actions"><button class="primary-button" data-ai-done="${r.id}">${icon('Check')}已完成</button><button class="secondary-button" data-ai-delay="${r.id}">半小时后</button><button class="text-button" data-ai-edit="${r.id}">调整</button></div></article>`;
  }
  function proactiveMarkup(){
    if(getDay()!==today)return '';
    if(!prefs.proactive||!prefs.audio||isQuiet()||dismissed||snoozedUntil>clock.minutes||currentReminder())return '';
    return `<article class="ai-nudge"><div class="ai-nudge-top"><span>${icon('MessageCircle')}AI 留意到 · ${hhmm(clock.minutes)}</span><button data-ai-action="nudge-options" aria-label="管理这条主动建议">稍后 / 收起</button></div><h3>给反复想到的事，留一点时间。</h3><p>14:00 的讨论提到先列清首版范围。可以在今天收尾前，留 10 分钟把它写下来。</p><div class="ai-nudge-actions"><button class="primary-button" data-ai-remind="scope">${icon('Bell')}提醒我</button><button class="secondary-button" data-ai-ask="这一天最值得跟进什么？">和 AI 聊聊</button><button class="text-button" data-ai-action="nudge-why">为什么建议</button></div></article>`;
  }
  function renderHome(){
    const nudge=reminderMarkup()||proactiveMarkup();
    $('homeAI').innerHTML=nudge||aiLink(currentReminder()?'已安排提醒，可随时查看或调整。':isQuiet()?'免打扰中，想聊的时候我都在。':getDay()!==today?`一起回顾${dateLabel(getDay())}的记录。`:'从记录出发，理清接下来的一小步。');
  }
  function answerMarkup(turn){
    if(turn.pending)return `<div class="ai-thinking">${icon('AudioLines')}正在整理允许使用的示例记录…</div>`;
    const a=turn.answer;
    if(a.evidence.some(id=>{const r=[...getRecords(19),...getRecords(18)].find(row=>row.id===id);return r&&!allowed(r);})){
      return `<div class="ai-answer"><p>这条回答使用的数据已被你关闭，内容已收起。</p><button class="text-button" data-ai-ask="${esc(turn.question)}">使用当前允许的数据重新回答 ${icon('RotateCcw')}</button></div>`;
    }
    return `<div class="ai-answer"><div class="ai-answer-label">${icon('MessageCircle')}WiseLife AI<span>${esc(a.context)} · 示例回答</span></div><h3>${esc(a.title)}</h3>${a.paragraphs.map(p=>`<p>${esc(p)}</p>`).join('')}${sourcesMarkup(a.evidence)}${a.note?`<p class="ai-answer-note">${esc(a.note)}</p>`:''}<div class="ai-answer-actions">${a.remind?`<button class="secondary-button" data-ai-remind="${a.remind}">${icon('Bell')}设一个提醒</button>`:''}${a.followup?`<button class="text-button" data-ai-ask="${esc(a.followup)}">继续：${esc(a.followup)} ${icon('ArrowRight')}</button>`:''}${a.retry?`<button class="secondary-button" data-ai-ask="${esc(turn.question)}">${icon('RotateCcw')}重新回答</button>`:''}</div></div>`;
  }
  function render(){
    const list=recordsFor(getDay()),thread=currentThread();
    renderHome();
    $('aiContext').innerHTML=`${icon('CalendarDays')}${dateLabel(getDay())} · ${list.length} 条可用记录 ${icon('ChevronDown')}`;
    $('aiReminderCount').textContent=reminders.filter(r=>!r.done).length;
    $('aiWelcome').hidden=thread.length>0;
    $('aiProactive').innerHTML=reminderMarkup()||(thread.length?'':proactiveMarkup());
    $('aiPrompts').hidden=thread.length>0;
    const prompts=list.length?['这一天最值得跟进什么？','帮我回顾这一天',list.some(r=>r.kind==='image')?'这一天的图片记录了什么？':'最近的睡眠有什么变化？']:['这一天有哪些记录？','明天提醒我做个语音回顾'];
    $('aiPrompts').innerHTML=prompts.map(p=>`<button data-ai-ask="${p}">${p}${icon('ArrowUpRight')}</button>`).join('');
    $('aiConversation').innerHTML=thread.map(turn=>`<article class="ai-turn"><p class="ai-user-message">${esc(turn.question)}</p>${answerMarkup(turn)}</article>`).join('');
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
    const day=resolveDay(question,fallback),list=recordsFor(day),ids=list.map(r=>r.id);
    const has=id=>ids.includes(id);
    const result=(title,paragraphs,evidence=[],extra={})=>({title,paragraphs,evidence,context:dateLabel(day),...extra});
    if(/提醒/.test(question)){
      if(/日记|手记|写一句|语音回顾/.test(question))return result('把这个小习惯，留给明天。',['可以先拟一条“录一段今天的回顾”。点下方选择时间，确认后才会加入原型内的提醒。'],[],{remind:'journal'});
      if(/周五|反馈/.test(question)&&has('meeting'))return result('周五回顾反馈，可以先留个提醒。',['09:40 的碰头记录提到了周五集中回顾使用反馈。下面的时间只是建议，你可以调整。'],['meeting'],{remind:'review'});
      if(/首版|范围|做减法/.test(question)&&has('review'))return result('把首版范围写成 3 行。',['建议写下要做什么、暂缓什么、怎样算完成。先确认提醒时间，我再替你记下来。'],['review'],{remind:'scope'});
      return result('先把提醒说具体一点。',['这个原型支持“提醒我做个语音回顾”“提醒我写首版范围”和“周五回顾反馈”示例。也可以直接新建一条，自己填写内容与时间。'],[],{remind:'custom'});
    }
    if(!list.length)return result('这一天，还没有可用的记录。',[`${dateLabel(day)}没有允许 AI 使用的记录。我无法据此总结你的经历；你可以选择有记录的日期，或在 AI 偏好中调整数据范围。`],[],{note:'不会用其他日期的数据补齐这一天。'});
    if(/图片|照片|截图|白板|原图/.test(question)){
      const photos=list.filter(r=>r.kind==='image');
      if(!photos.length)return result('这一天，没有可用的图片记录。',['可以用“记此刻”拍照或从相册选择，也可以在 AI 偏好中允许使用图片。']);
      const descriptions=photos.map(r=>[r.caption?`你补充的说明：「${r.caption}」`:'没有补充说明。',r.ocr?`示例图中的预置文字：\n${r.ocr}`:'这条图片尚未识别，不能根据画面推断内容。'].join('\n'));
      return result(`这一天，留住了 ${photos.reduce((n,r)=>n+r.images.length,0)} 张图片。`,descriptions,photos.map(r=>r.id),{note:'原型仅引用你填写的说明和示例图的预置文字。点击来源可回看原图，未进行真实图片分析。'});
    }
    if(/最近|趋势|变化|几天|一周/.test(question)&&/睡|休息/.test(question)){
      const sleeps=[...recordsFor(day-1),...list].filter(r=>r.kind==='sleep').sort((a,b)=>a.day-b.day);
      if(sleeps.length<2)return result('记录还不够，先不判断趋势。',['目前允许使用的数据里，没有相邻两天的睡眠记录。可以允许“睡眠与活动”，或再积累一些记录。'],sleeps.map(r=>r.id));
      return result('比前一天少了 36 分钟，还不代表趋势。',['10月18日记录到 7 小时 48 分钟，10月19日为 7 小时 12 分钟。两条记录只能比较时长，不能判断睡眠质量或长期变化。','如果想观察，可以先固定几天的睡前回顾时间，再结合自己的感受。'],sleeps.map(r=>r.id),{context:'10月18–19日',note:'这里只比较示例时长，不作健康诊断。'});
    }
    if(/散步|步行|活动|运动|走了多久/.test(question)){
      const walks=list.filter(r=>r.kind==='activity');
      if(!walks.length)return result('没有可用的活动记录。',['这一天没有允许 AI 使用的活动数据，我无法判断你走了多久。']);
      const duration=walks.reduce((sum,r)=>sum+r.duration,0)/60;
      return result(`这一天，留下了 ${duration} 分钟步行。`,[`${walks.map(r=>`${r.time} 的步行 ${r.duration/60} 分钟`).join('，')}。${day===today&&has('thought-morning')?'早上的步行结束 6 分钟后，你记下了首版方向；这只是时间相邻，不能说明步行带来了灵感。':''}`],walks.map(r=>r.id).concat(day===today&&has('thought-morning')?['thought-morning']:[]),{followup:'帮我回顾这一天'});
    }
    if(/睡眠|睡了|睡得/.test(question)){
      const sleep=list.find(r=>r.kind==='sleep');
      return sleep?result('先看记录，再看自己的感受。',[sleep.summary],[sleep.id],{followup:'最近的睡眠有什么变化？'}):result('没有可用的睡眠记录。',['可以在 AI 偏好里允许“睡眠与活动”，或选择有记录的日期。']);
    }
    if(/周五|反馈/.test(question)&&has('meeting'))return result('周五，回顾这周的使用反馈。',['09:40 的项目碰头里约定，周五集中看看录音、转写和回顾路径的使用反馈。记录没有约定具体时间，可以先拟为 10月23日 16:00。'],['meeting'],{remind:'review'});
    if(/首版|范围|减法|跟进|重要|建议|下一步|计划|具体|怎么做|该做/.test(question)){
      if(has('thought-morning')&&has('thought-noon')&&has('review'))return result('先把首版范围写成 3 行。',['你在 08:36 和 11:18 的闪念里都提到收小范围；14:00 的讨论又落到了“先列清首版范围”。这是这一天值得继续推进的一条线索。','可以先写：\n1. 要做：跑通录音 → 转写 → 回顾。\n2. 暂缓：扩展更多数据来源。\n3. 完成标准：能从一条洞察回到原始记录。'],['thought-morning','thought-noon','review'],{remind:'scope',followup:'周五有什么需要跟进？',note:'这是基于记录的建议；我不知道你是否已完成，可以按实际情况调整。'});
      if(has('yesterday-note'))return result('先确定最重要的一件事。',['17:30 的记录里，你想在一天开始前先确定最重要的一件事，也留一点思考的空白。可以从写一句当天的重点开始。'],['yesterday-note'],{remind:'journal'});
      return result('目前还没有足够的内容判断优先级。',['可用记录里没有能支持这条建议的想法或讨论。你可以留下一段语音或图片，再查看现有记录。'],[],{followup:'帮我回顾这一天'});
    }
    if(/回顾|总结|记录|做了什么|发生|这一天/.test(question)){
      const voice=list.filter(r=>r.kind==='voice'||r.kind==='thought'),walks=list.filter(r=>r.kind==='activity'),sleep=list.find(r=>r.kind==='sleep'),journals=list.filter(r=>r.kind==='journal'),photos=list.filter(r=>r.kind==='image');
      const paragraphs=[];
      if(voice.length)paragraphs.push(`留下 ${voice.length} 条语音与闪念，共约 ${Math.round(voice.reduce((n,r)=>n+r.duration,0)/60)} 分钟。${has('review')?'其中产品讨论聚焦于录音、转写和回顾的路径。':has('yesterday-note')?'你提到想先确定每天最重要的一件事。':''}`);
      if(walks.length)paragraphs.push(`记录到 ${walks.length} 次步行，共 ${walks.reduce((n,r)=>n+r.duration,0)/60} 分钟。`);
      if(sleep)paragraphs.push(`睡眠记录为 ${Math.floor(sleep.duration/3600)} 小时 ${Math.round(sleep.duration%3600/60)} 分钟。`);
      if(journals.length)paragraphs.push(`你还写了 ${journals.length} 条手记。最新一条是「${journals[journals.length-1].title}」。`);
      if(photos.length)paragraphs.push(`还留下 ${photos.length} 条图片记录，共 ${photos.reduce((n,r)=>n+r.images.length,0)} 张图片。可以打开原图回看。`);
      return result(`${dateLabel(day)}，从 ${list.length} 条记录回看。`,paragraphs,list.map(r=>r.id),{note:day===today?'仅覆盖截至 16:30 的示例记录，未记录的时段无法还原。':'只描述已记录的部分。'});
    }
    const matched=list.filter(r=>question.length>=2&&(r.title.includes(question)||r.text.includes(question))).slice(0,3);
    if(matched.length)return result('找到几段可能相关的原文。',matched.map(r=>`「${r.preview}」`),matched.map(r=>r.id),{note:'这是原文匹配演示，尚未进行真实语义检索。'});
    return result('这个问题，原型还不能可靠回答。',['当前没有连接真实 AI。我可以演示按记录回顾、梳理首版方向、比较睡眠时长以及拟定提醒。你可以试试下方的问题。'],[],{followup:'帮我回顾这一天'});
  }
  function scrollToConversation(){
    if(getView()==='ai')$('screenScroll').scrollTop=$('screenScroll').scrollHeight;
  }
  function ask(question){
    question=question.trim().slice(0,600);if(!question||pending)return;
    showView('ai');
    const day=getDay(),turn={id:++sequence,question,pending:true};
    currentThread().push(turn);$('aiQuestion').value='';$('aiQuestion').style.height='';
    pending={turn,day,timer:setTimeout(()=>{
      try{turn.answer=reply(question,day);}
      catch{turn.answer={title:'这次回答没有完成。',paragraphs:['请重试，已确认的提醒仍然保留。'],evidence:[],context:dateLabel(day),retry:true};}
      turn.pending=false;pending=null;render();scrollToConversation();
    },650)};
    render();scrollToConversation();
  }
  function stop(){
    if(!pending)return;
    clearTimeout(pending.timer);pending.turn.pending=false;
    pending.turn.answer={title:'已停止这次回答。',paragraphs:['想继续时，可以重新回答。'],evidence:[],context:dateLabel(pending.day),retry:true};
    pending=null;render();
  }
  function openNudgeWhy(){
    openSheet('为什么现在建议',`<div class="insight-label">${icon('MessageCircle')}10月19日 · 示例洞察</div><h3 class="insight-detail-title">反复出现的方向，值得变成一个小行动。</h3><p class="sheet-intro">两次闪念都提到收小范围，下午的讨论进一步提到先列清首版要做的事。于是建议在收尾前留 10 分钟写下来。</p>${sourcesMarkup(['thought-morning','thought-noon','review'])}<div class="quiet-info">${icon('CircleHelp')}<p>记录没有告诉我这件事是否已完成。你可以收起建议；设置提醒前，也可以改内容和时间。</p></div><button class="primary-button wide" data-ai-remind="scope">${icon('Bell')}拟定一个提醒</button>`);
  }
  function openNudgeOptions(){
    openSheet('这条建议，按你的节奏',`<p class="sheet-intro">稍后再看，或告诉 AI 这件事已经处理好了。</p><button class="plain-row" data-ai-action="snooze"><span>${icon('Clock3')}1 小时后再看</span>${icon('ChevronRight')}</button><button class="plain-row" data-ai-action="dismiss"><span>${icon('Check')}已处理 / 今天不再建议</span>${icon('ChevronRight')}</button><button class="plain-row" data-ai-action="preferences"><span>${icon('Settings2')}调整主动建议与免打扰</span>${icon('ChevronRight')}</button><p class="source-footnote">原型只模拟时机，不会发出系统通知。</p>`);
  }
  function createDraft(kind,id){
    const existing=reminders.find(r=>r.id===id);
    if(existing){draft={...existing};}
    else {
      const same=kind==='scope'?currentReminder():null;
      if(same){openReminders();return;}
      const options={
        scope:{title:'把首版范围写成 3 行',date:clock.minutes>=1080?'2026-10-20':'2026-10-19',time:'18:00',evidence:['review'],origin:'scope'},
        review:{title:'回顾本周的使用反馈',date:'2026-10-23',time:'16:00',evidence:['meeting'],origin:'review'},
        journal:{title:'录一段今天的回顾',date:'2026-10-20',time:'20:30',evidence:[],origin:'journal'},
        custom:{title:'',date:'2026-10-20',time:'09:00',evidence:[],origin:'custom'}
      };
      draft={...options[kind],evidence:[...(options[kind]?.evidence||[])]};
    }
    renderDraft();
  }
  function renderDraft(){
    openSheet(draft.id?'修改提醒':'先确认，再替你记下',`<p class="sheet-intro">选一个适合自己的时刻。确认前，不会创建提醒。</p><form id="aiReminderForm"><label class="note-field"><span>提醒我</span><input id="aiReminderTitle" required maxlength="80" value="${esc(draft.title)}" placeholder="想提醒自己做什么"></label><div class="ai-field-grid"><label class="note-field"><span>日期</span><input id="aiReminderDate" type="date" required min="2026-10-19" value="${draft.date}"></label><label class="note-field"><span>时间</span><input id="aiReminderTime" type="time" required value="${draft.time}"></label></div>${draft.evidence.length?`<div class="ai-confirm-preview">来自你的记录${sourcesMarkup(draft.evidence)}</div>`:''}<p class="source-footnote ai-reminder-note">这是原型内的提醒，刷新后清空，不会发送系统通知。你确认的提醒与 AI 主动建议分别管理。</p><p id="aiReminderError" class="ai-inline-error" role="alert" hidden></p><div class="sheet-actions"><button class="secondary-button" type="button" data-ai-action="cancel-draft">取消</button><button class="primary-button" type="submit">${icon('Check')}${draft.id?'保存修改':'确认提醒'}</button></div></form>`);
  }
  function saveReminder(form){
    if(!draft||!form.reportValidity())return;
    const title=$('aiReminderTitle').value.trim(),date=$('aiReminderDate').value,time=$('aiReminderTime').value;
    const fail=message=>{$('aiReminderError').textContent=message;$('aiReminderError').hidden=false;};
    if(!title)return fail('请写下提醒内容。');
    if(!/^\d{4}-\d{2}-\d{2}$/.test(date)||!/^\d{2}:\d{2}$/.test(time)||date<'2026-10-19'||(date==='2026-10-19'&&asMinutes(time)<=clock.minutes))return fail('请选择晚于原型当前时刻的时间。');
    const duplicate=reminders.find(r=>!r.done&&r.id!==draft.id&&r.title===title&&r.date===date&&r.time===time);
    if(duplicate)return fail('同一时间已经有这条提醒，可以在提醒列表中修改。');
    const next={...draft,title,date,time,done:false,id:draft.id||`reminder-${++sequence}`};
    const index=reminders.findIndex(r=>r.id===draft.id);
    if(index>=0)reminders[index]=next;else reminders.push(next);
    draft=null;render();openReminders();toast('已加入原型内提醒，不会发送系统通知。');
  }
  function openReminders(){
    const sorted=[...reminders].sort((a,b)=>Number(a.done)-Number(b.done)||(a.date+a.time).localeCompare(b.date+b.time));
    openSheet('我的提醒',`<p class="sheet-intro">你确认过的小行动，都在这里。<br>原型当前：10月19日 ${hhmm(clock.minutes)}。</p>${sorted.length?sorted.map(r=>`<article class="ai-reminder-row"><h3>${r.done?'✓ ':''}${esc(r.title)}</h3><p>${reminderDate(r)} · ${r.done?'已完成':'已确认 · 仅原型内'}</p><div class="ai-reminder-actions">${r.done?'':`<button data-ai-edit="${r.id}">修改时间 / 内容</button><button data-ai-done="${r.id}">标记完成</button>`}<button data-ai-delete="${r.id}">${r.done?'移除':'取消提醒'}</button></div></article>`).join(''):`<div class="empty-state">${icon('Bell')}<h3>还没有安排提醒</h3><p>有值得跟进的事，再轻轻提醒你。</p></div>`}<button class="primary-button wide" data-ai-remind="custom">${icon('Plus')}新建提醒</button><p class="source-footnote">这里只保存本页内的提醒，不访问系统日历或通知。刷新后清空。</p>`);
  }
  function preferences(){
    openSheet('AI 偏好与提醒',`<div class="ai-prefs-row"><div><strong>主动给我建议</strong><p>发现值得跟进的线索时，在 App 内提醒我。</p></div><button class="switch" role="switch" aria-checked="${prefs.proactive}" aria-label="主动给我建议" data-ai-pref="proactive"></button></div><h3 class="sheet-section-title">建议频率</h3><div class="ai-settings-options" role="group" aria-label="建议频率"><button data-ai-frequency="1" aria-pressed="${prefs.frequency===1}">每天精选 1 条</button><button data-ai-frequency="3" aria-pressed="${prefs.frequency===3}">每天最多 3 条</button></div><p class="subtle">少而有用。当前仅提供 1 条主动建议示例。</p><div class="ai-prefs-row"><div><strong>免打扰时段</strong><p>此时收起主动建议，仍可主动向 AI 提问。</p></div><button class="switch" role="switch" aria-checked="${prefs.quiet}" aria-label="免打扰时段" data-ai-pref="quiet"></button></div><form id="aiQuietForm"><div class="ai-field-grid"><label class="note-field"><span>开始</span><input id="aiQuietStart" type="time" required value="${prefs.quietStart}"></label><label class="note-field"><span>结束（可跨天）</span><input id="aiQuietEnd" type="time" required value="${prefs.quietEnd}"></label></div><p id="aiQuietError" class="ai-inline-error" role="alert" hidden></p><button class="secondary-button" type="submit">保存时段</button></form><h3 class="sheet-section-title">允许 AI 使用的记录</h3>${Object.entries(scopeNames).map(([key,name])=>`<div class="ai-prefs-row"><div><strong>${name}</strong><p>${key==='audio'?'录音转写、讨论与随手说出的想法':key==='health'?'只描述记录，不推断健康状况':'你选择的图片与说明，未自动读取相册'}</p></div><button class="switch" role="switch" aria-checked="${prefs[key]}" aria-label="允许 AI 使用${name}" data-ai-pref="${key}"></button></div>`).join('')}<p class="source-footnote">关闭后，新回答不再使用该类记录，已有相关回答会收起。暂停数据采集则仍可回顾历史记录。已确认的提醒由你单独管理。</p><button class="plain-row" data-ai-action="reminders"><span>${icon('Bell')}管理已确认的提醒</span>${icon('ChevronRight')}</button><h3 class="sheet-section-title">预览建议出现的时机</h3><p class="subtle">演示时刻仅用于 AI 时机预览，首页记录仍截至 16:30。</p><div class="ai-settings-options" role="group" aria-label="演示时刻">${[990,1050,1080,1350].map(t=>`<button data-ai-clock="${t}" aria-pressed="${clock.minutes===t}">${hhmm(t)}</button>`).join('')}</div><p class="ai-preference-status">${isQuiet()?'当前处于免打扰时段。':snoozedUntil>clock.minutes?`这条建议将在 ${hhmm(snoozedUntil)} 再出现。`:'当前可展示主动建议。'}${dismissed?'这条示例建议已收起。':''}</p><button class="text-button" data-ai-action="reset-nudge">重新展示这条示例建议</button>`);
  }
  function setPreference(key){
    if(!(key in prefs))return;
    stop();prefs[key]=!prefs[key];render();preferences();
    // Replacing the sheet contents should not leave keyboard focus on <body>.
    document.querySelector(`[data-ai-pref="${key}"]`)?.focus();
  }
  document.addEventListener('click',event=>{
    const button=event.target.closest('button');if(!button)return;
    if(button.dataset.aiAsk){if($('sheet').open)closeSheet();ask(button.dataset.aiAsk);return;}
    if(button.dataset.aiRemind){createDraft(button.dataset.aiRemind);return;}
    if(button.dataset.aiEdit){createDraft(null,button.dataset.aiEdit);return;}
    if(button.dataset.aiDelay){
      const r=reminders.find(r=>r.id===button.dataset.aiDelay);
      if(r){const time=clock.minutes+30;r.time=hhmm(time%1440);if(time>=1440)r.date='2026-10-20';render();toast(`已改为 ${reminderDate(r)}，仅在原型内演示。`);}return;
    }
    if(button.dataset.aiDone){const r=reminders.find(r=>r.id===button.dataset.aiDone);if(r){r.done=true;if(r.origin==='scope')dismissed=true;render();openReminders();}return;}
    if(button.dataset.aiDelete){const index=reminders.findIndex(r=>r.id===button.dataset.aiDelete);if(index>=0){reminders.splice(index,1);render();openReminders();toast('这条提醒已移除。');}return;}
    if(button.dataset.aiPref){setPreference(button.dataset.aiPref);return;}
    if(button.dataset.aiFrequency){prefs.frequency=Number(button.dataset.aiFrequency);preferences();document.querySelector(`[data-ai-frequency="${prefs.frequency}"]`)?.focus();return;}
    if(button.dataset.aiClock){clock.minutes=Number(button.dataset.aiClock);render();preferences();document.querySelector(`[data-ai-clock="${clock.minutes}"]`)?.focus();return;}
    const actions={
      preferences,reminders:openReminders,stop,date:()=>{stop();openCalendar();},
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
  return {render};
};
