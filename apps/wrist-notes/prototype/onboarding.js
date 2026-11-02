/* Review-only first-run flow. All resources, checks and connections are in-memory simulations. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const esc = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const paths = {
    mic:'<rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10v2a7 7 0 0 0 14 0v-2M12 19v3m-4 0h8"/>',
    sparkle:'<path d="m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5L12 3Z"/>',
    search:'<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
    check:'<path d="m5 12 4 4L19 6"/>',
    arrow:'<path d="m9 5 7 7-7 7"/>',
    back:'<path d="m15 5-7 7 7 7"/>',
    shield:'<path d="M12 3 4 6v6c0 5 8 9 8 9s8-4 8-9V6l-8-3Z"/><path d="m8 12 3 3 5-5"/>',
    clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    settings:'<path d="M4 7h16M4 17h16"/><circle cx="9" cy="7" r="3"/><circle cx="16" cy="17" r="3"/>',
    sun:'<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1 1m12 12 1 1M5 19l1-1M18 6l1-1"/>',
    photo:'<rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="9" cy="9" r="2"/><path d="m21 15-5-5L5 21"/>',
    heart:'<path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1.1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8Z"/>',
    calendar:'<rect x="3" y="5" width="18" height="16" rx="3"/><path d="M3 10h18M8 3v4m8-4v4m-9 8h3m4 0h3"/>',
    pin:'<path d="M20 10c0 6-8 12-8 12S4 16 4 10a8 8 0 1 1 16 0Z"/><circle cx="12" cy="10" r="2.5"/>',
    chat:'<path d="M21 11.5a8.5 8.5 0 0 1-8.5 8.5 10 10 0 0 1-4-.8L3 21l1.8-5.5a10 10 0 0 1-.8-4A8.5 8.5 0 0 1 21 11.5Z"/>'
  };
  const icon = name => `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true">${paths[name] || paths.sparkle}</svg>`;
  const catalog = window.daybookModelCatalog;
  const languageNames = new Intl.DisplayNames(['zh-Hans'], {type:'language'});
  const vectorLanguages = {'zh-Hans':'简体中文',en:'English','zh-Hant':'繁體中文',ja:'日本語'};
  const appleReasons = {
    'not-enabled':'尚未开启 Apple Intelligence', preparing:'Apple 系统模型仍在准备中',
    unsupported:'此设备不支持 Apple Intelligence', language:'当前语言不支持 Apple 本地模型'
  };
  const capabilities = [
    {id:'asr', title:'语音转写', model:'语音转写模型', icon:'mic', description:'把录音变成文字，留住你的原话。', missing:'录音可以保存和回听，暂时不能转成文字。'},
    {id:'ai', title:'AI 理解', model:'AI 模型', icon:'sparkle', description:'整理重点、生成回顾，回答你的问题。', missing:'暂时不能生成 AI 总结、建议或 Ask AI 回答。'},
    {id:'retrieval', title:'AI 检索', model:'AI 检索模型', icon:'search', description:'理解问题的意思，找到相关的记录。', missing:'仍可按日期、关键词查找，暂时不能按语义检索。'}
  ];
  const steps = [capabilities[0], {id:'ai',title:'AI 能力',icon:'sparkle',description:'理解与检索一起准备，让回答有据可依。'}, {id:'data', title:'数据授权', icon:'shield', description:'由你决定，让 AI 了解哪些生活线索。'}, {id:'usage',title:'使用说明',icon:'photo',description:'用 iPhone 或 Apple Watch，留下第一条记录。'}];
  const dataSources = [
    {id:'health',title:'健康',icon:'heart',purpose:'结合睡眠与活动，帮你看见作息变化，给出更贴近状态的建议。',scope:'读取你选择的步数、睡眠、运动与活动能量，不写入健康数据。',missing:'不使用未获授权的健康信息，仍可从你的笔记生成回顾。'},
    {id:'calendar',title:'日历',icon:'calendar',purpose:'把一天的安排与记录放在一起，回顾会议、规划时间。',scope:'访问事件标题、时间与地点；仅在你明确要求创建日程时写入。',missing:'不展示日历安排；记录和 AI 问答仍可使用。'},
    {id:'location',title:'地点',icon:'pin',purpose:'为录音和照片补充地点，帮你想起在哪里发生了什么。',scope:'使用 App 时获取位置；录音采集地点按记录场景处理，不开启全天持续追踪。',missing:'没有地点的记录照常保存，不猜测你的位置。'},
    {id:'reminders',title:'提醒事项',icon:'check',purpose:'把「明天提醒我」这样的明确指令，变成可跟进的事项。',scope:'读取提醒事项；按你的明确指令创建待办与提醒，不擅自完成或删除。',missing:'想法仍可保存在 WiseLife，暂不能写入 Apple 提醒事项。'}
  ];
  const labels = {missing:'待准备',ready:'已就绪',reviewed:'已确认选择',optional:'可选授权',unread:'待了解',read:'已了解',error:'准备失败',downloading:'下载中',checking:'检查中',validating:'校验中',paused:'已暂停',unsupported:'不可用'};
  const jobs = new Map();
  let state, dialogReturnFocus;

  function initial() {
    return {page:'overview', resources:{}, asr:{engine:'apple',apple:'zh-CN',size:'base',whisper:'auto'},
      ai:{mode:'local',protocol:'openai',model:'',url:'',key:'',status:'missing',tested:''},
      retrieval:{language:'zh-Hans'}, data:{reviewed:false,health:'unrequested',calendar:'unrequested',location:'unrequested',reminders:'unrequested'}, usage:{reviewed:false,device:'iphone',topic:'record'}, translation:false, scenario:'fresh'};
  }
  function asrKey() { return state.asr.engine === 'apple' ? `apple:${state.asr.apple}` : `whisper:${state.asr.size}`; }
  function vectorKey() { return `vector:${state.retrieval.language}`; }
  function resource(key) { return state.resources[key] || {status:'missing',percent:0}; }
  function signature() { const {mode,protocol,model,url,key}=state.ai; return JSON.stringify({mode,protocol,model,url,key}); }
  function currentAIStatus() {
    if (state.ai.mode === 'local' && $('demoApple').value !== 'available') return state.ai.status === 'checking' ? 'checking' : 'unsupported';
    return state.ai.status === 'ready' && state.ai.tested !== signature() ? 'missing' : state.ai.status;
  }
  function status(id) { return id === 'usage' ? (state.usage.reviewed?'read':'unread') : id === 'data' ? (state.data.reviewed?'reviewed':'optional') : id === 'asr' ? resource(asrKey()).status : id === 'retrieval' ? resource(vectorKey()).status : currentAIStatus(); }
  function count() { return capabilities.filter(c => status(c.id) === 'ready').length; }
  function aiReady() { return currentAIStatus()==='ready'&&status('retrieval')==='ready'; }
  function stepStatus(id) {
    if(id!=='ai')return status(id);
    if(aiReady())return 'ready';
    const values=[currentAIStatus(),status('retrieval')];
    return ['error','unsupported','checking','downloading','validating','paused'].find(value=>values.includes(value)) || 'missing';
  }
  function stepCount() { return Number(status('asr')==='ready')+Number(aiReady())+Number(state.data.reviewed)+Number(state.usage.reviewed); }
  function firstPending() { return status('asr')!=='ready'?'asr':!aiReady()?'ai':!state.data.reviewed?'data':!state.usage.reviewed?'usage':'review'; }
  function localPromise() { return state.ai.mode==='local'?'你的数据和 AI 能力，都在你的设备上。':'转写、检索与记录保存在本机；AI 理解使用你选择的服务。'; }
  function purpose(text, privacy) { return `<div class="setup-purpose"><strong>为什么要设置</strong><p>${text}</p><div>${icon('shield')}<span>${privacy}</span></div></div>`; }
  function dataSummary() {
    const chosen=dataSources.filter(d=>['granted','configured'].includes(state.data[d.id])).map(d=>d.title);
    return chosen.length?`已设置：${chosen.join('、')}。${state.data.health==='configured'?'健康以系统允许读取的项目为准。':''}`:'暂不使用额外数据；仍可使用你的语音与图片记录。';
  }
  function busy(value) { return ['downloading','checking','validating'].includes(value); }
  function badge(value) { return `<span class="setup-status" data-state="${value}">${labels[value]}</span>`; }
  function announce(text) { $('setupAnnouncement').textContent = text; }
  function option(value, title, selected) { return `<option value="${esc(value)}" ${value===selected?'selected':''}>${esc(title)}</option>`; }
  function description(id) {
    if (id === 'asr') return state.asr.engine === 'apple' ? `iPhone端上转写 · ${catalog.apple.find(l=>l.id===state.asr.apple).label}` : `Whisper ${state.asr.size} · ${state.asr.whisper==='auto'?'自动检测':languageNames.of(state.asr.whisper)}`;
    if (id === 'ai') return state.ai.mode === 'local' ? 'Apple Intelligence · 本机处理' : `${state.ai.model || '自定义模型'} · ${state.ai.protocol==='openai'?'OpenAI':'Anthropic'} 兼容`;
    return `Apple 上下文向量 · ${vectorLanguages[state.retrieval.language]}`;
  }
  function cards() {
    return `<div class="setup-capabilities">${steps.map(c=>`<button class="setup-capability" data-go="${c.id}"><span class="capability-icon">${icon(c.icon)}</span><div><strong>${c.title}</strong><p>${c.description}</p>${badge(stepStatus(c.id))}</div>${icon('arrow')}</button>`).join('')}</div>`;
  }
  function overview() {
    return `<div class="setup-hero-line"><img class="setup-logo" src="assets/brand/app-icon.png" alt="WiseLife"><span class="setup-mini-badge">${state.ai.mode==='local'?'默认全端上':'已选择自定义 AI'}</span></div><p class="setup-kicker">你好，欢迎来到 WiseLife</p><h2 id="setupHeading" tabindex="-1">懂你的AI，更懂保护你的隐私</h2><p class="setup-lead">四步开始：准备 AI、选择数据，再学会留下第一条记录。</p><div class="setup-readiness"><span>首次使用准备</span><strong>${stepCount()} / 4</strong></div>${cards()}<p class="setup-privacy">${icon('shield')}<span><strong>${localPromise()}</strong><br>${state.ai.mode==='local'?'使用端上模型时，个人记录无需上传到 WiseLife 服务器。':'仅发送你允许的文字，不会自动改用其他云端服务。'}</span></p>`;
  }
  function resourceBox(key, title, note) {
    const r=resource(key), running=busy(r.status);
    const error=r.error==='storage'?'可用空间不足。请清理空间后重试，或选择更轻量的模型。':'网络暂时不可用。已完成的其他设置会保留，连接网络后可以重试。';
    return `<div class="setup-resource" data-state="${r.status}" role="status"><div class="setup-resource-head"><strong>${esc(title)}</strong>${badge(r.status)}</div><p>${r.status==='ready'?'资源检查通过，可在本机使用。':r.status==='error'?error:r.status==='validating'?'下载完成，正在校验资源是否可用…':r.status==='downloading'?`正在下载 · ${r.percent}%` : r.status==='paused'?'准备已暂停，可以继续；已就绪的其他资源会保留。':note}</p>${running?`<progress max="100" value="${r.percent || 0}" aria-label="资源准备进度"></progress><button class="setup-inline" data-cancel-job="${key}">暂停准备</button>`:''}${r.status==='error'&&r.error==='storage'&&state.page==='asr'&&state.asr.engine==='whisper'&&state.asr.size!=='tiny'?'<button class="setup-inline" data-action="lighter">改用 Whisper Tiny</button>':''}</div>`;
  }
  function asrPage() {
    const a=state.asr, whisper=a.engine==='whisper';
    return `<p class="setup-kicker">01 / 让 WiseLife 听懂你</p><h2 id="setupHeading" tabindex="-1">把说过的话，<br>留下文字。</h2><p class="setup-lead">先让语音成为可以阅读、搜索的文字。</p>${purpose('录音自动转成文字，让 AI 更好地理解。原始录音可以设置保留 7 天／14 天。','Apple 转写或 Whisper 都在 iPhone 上运行，音频无需上传。')}<div role="radiogroup" aria-label="语音转写模型"><label class="setup-choice"><input type="radio" name="asrEngine" value="apple" ${!whisper?'checked':''}><span><strong>iPhone端上转写<span class="choice-tag">推荐</span></strong><small>iPhone系统语音模型，无需API Key，支持单语言转写，按需下载系统语言包。</small></span></label><label class="setup-choice"><input type="radio" name="asrEngine" value="whisper" ${whisper?'checked':''}><span><strong>Whisper</strong><small>下载一个多语言模型，可指定语言或自动检测。多种语言共用，不逐语言下载。</small></span></label></div>${whisper?`<label class="setup-field">模型大小<select id="setupWhisperSize">${[['tiny','Tiny · 更轻量'],['base','Base · 均衡'],['small','Small · 更高精度']].map(([v,l])=>option(v,l,a.size)).join('')}</select></label><label class="setup-field">转写语言<select id="setupWhisperLanguage">${option('auto','自动检测',a.whisper)}${catalog.whisper.map(v=>option(v,languageNames.of(v),a.whisper)).join('')}</select></label>`:`<label class="setup-field">转写语言<select id="setupAppleLanguage">${catalog.apple.map(l=>option(l.id,l.label,a.apple)).join('')}</select></label>`}${resourceBox(asrKey(),whisper?`Whisper ${a.size} 多语言模型`:`${catalog.apple.find(l=>l.id===a.apple).label}语言包`,'先检查已有资源；缺少时下载，完成校验后才算就绪。')}<p class="setup-note">${whisper?'切换语言不需要重下模型。开始下载前检查可用空间，模型越大，通常占用越多。':'语言列表以当前设备支持情况为准。Apple 负责管理语言资源，已有资源可复用。'}</p>`;
  }
  function aiPage() {
    const local=state.ai.mode==='local';
    return `<p class="setup-kicker">02 / 准备你的 AI 能力</p><h2 id="setupHeading" tabindex="-1">懂你的记录，<br>给有依据的回应。</h2><p class="setup-lead">理解与检索，一起成为你的个人 AI。</p>${purpose('先找到与你有关的记录，再理解其中的重点，生成总结、回顾与贴近你习惯的建议。',local?'默认全端上：AI 推理、语义检索与记录索引都在设备上。':'检索留在本机；获准的文字会发送至你选择的 AI 服务。')}<div class="setup-ai-flow"><span>找到相关记录</span>${icon('arrow')}<span>理解与生成</span></div><section class="setup-ai-section">${aiModelSection()}${currentAIStatus()!=='ready'?`<button class="secondary-button setup-section-action" data-action="check-ai" ${busy(currentAIStatus())?'disabled':''}>${busy(currentAIStatus())?'正在检查…':local?'检查本机模型':'测试连接并保存'}</button>`:''}</section><section class="setup-ai-section">${retrievalSection()}${status('retrieval')!=='ready'?`<button class="secondary-button setup-section-action" data-action="prepare-retrieval" ${busy(status('retrieval'))?'disabled':''}>${busy(status('retrieval'))?'正在准备…':status('retrieval')==='error'?'重试检索资源':'准备检索模型'}</button>`:''}</section>`;
  }
  function aiModelSection() {
    const a=state.ai, local=a.mode==='local', unavailable=$('demoApple').value!=='available', s=currentAIStatus();
    return `<div class="setup-ai-section-head"><span class="capability-icon">${icon('sparkle')}</span><div><h3>理解与生成</h3><p>总结、每日回顾、建议与 Ask AI</p></div>${badge(s)}</div><div role="radiogroup" aria-label="AI 模型"><label class="setup-choice ${unavailable?'is-disabled':''}"><input type="radio" name="aiMode" value="local" ${local?'checked':''} ${unavailable?'disabled':''}><span><strong>Apple Intelligence<span class="choice-tag">本机</span></strong><small>${unavailable?appleReasons[$('demoApple').value]:'无需 API Key，在 iPhone 上理解文字。WiseLife 端上 AI 要求 iOS 27.3 及以上、iPhone 15 Pro／Pro Max 或更新的支持机型。'}</small></span></label><label class="setup-choice"><input type="radio" name="aiMode" value="custom" ${!local?'checked':''}><span><strong>自定义 AI 模型</strong><span class="setup-model-english" lang="en">Bring Your Own Model</span><small>使用自己的模型地址与 API Key。选择云端服务时，允许的文字会发送给该服务。</small></span></label></div>${local?`<div class="setup-resource" role="status"><div class="setup-resource-head"><strong>系统能力检查</strong>${badge(s)}</div><p>${s==='ready'?'Apple 本地模型已就绪。后续总结与问答在本机处理。':s==='checking'?'正在检查本机模型是否可用…':unavailable?`${appleReasons[$('demoApple').value]}。转写与检索的准备仍可继续，不自动改用云端 AI。`:'由 iOS 管理开启和下载；实际可用性还取决于语言、地区与系统模型状态。'}</p>${unavailable?'<button class="setup-inline" data-action="system-help">查看准备方式</button>':''}</div>`:customFields()}<p class="setup-privacy">${icon('shield')}<span>${local?'本机模型不可用时，你可以主动选择自定义模型，或暂时使用基础记录功能。':'连接测试只使用固定测试文字，不携带个人记录。原始录音、图片和声音档案留在本机。'}</span></p>`;
  }
  function customFields() {
    const a=state.ai,s=currentAIStatus();
    return `<div class="setup-custom-fields"><label class="setup-field">API 接口兼容<select id="setupProtocol">${option('openai','OpenAI',a.protocol)}${option('anthropic','Anthropic',a.protocol)}</select></label><label class="setup-field">模型名称<input id="setupModel" value="${esc(a.model)}" placeholder="服务支持的模型 ID" maxlength="120" autocomplete="off" autocapitalize="off" spellcheck="false"></label><label class="setup-field">服务地址 · Base URL<input id="setupURL" type="url" value="${esc(a.url)}" placeholder="https://api.example.com/v1" autocomplete="off" autocapitalize="off" spellcheck="false"></label><label class="setup-field">API Key<input id="setupKey" type="password" value="${esc(a.key)}" placeholder="原型只填写虚构 Key" autocomplete="off"></label><p class="setup-note">允许的文字将发送给你选择的服务。API Key 应安全保存在本机，可随时更换或删除。</p><div class="setup-resource" data-state="${s}" role="status"><div class="setup-resource-head"><strong>连接测试</strong>${badge(s)}</div><p>${s==='ready'?'连接检查通过，已保存模型选择。':s==='checking'?'正在使用固定测试文字检查连接…':a.error?esc(a.error):'填写配置并测试成功后，AI 理解能力才会标为就绪。'}</p></div></div>`;
  }
  function retrievalSection() {
    const eligible=['zh-Hans','en'].includes(state.retrieval.language), t=resource('translation:zh-en');
    return `<div class="setup-ai-section-head"><span class="capability-icon">${icon('search')}</span><div><h3>检索你的记录</h3><p>找到相关经历，让回答有据可依</p></div>${badge(status('retrieval'))}</div><div class="setup-benefit">问「上次聊的旅行计划」<br>也能找到写着「周末去哪儿」的相关记录。</div><label class="setup-field">记录主要语言<select id="setupVectorLanguage">${Object.entries(vectorLanguages).map(([v,l])=>option(v,l,state.retrieval.language)).join('')}</select></label>${resourceBox(vectorKey(),'Apple 上下文向量','准备所选语言的检索资源，在本机理解问题与记录的含义。')}<p class="setup-note">资源未就绪时，仍可按日期和原文关键词查找。新增记录后在本机建立索引；现在没有记录，也可以完成设置。</p><div class="setup-enhancement"><div><strong>中英跨语言检索</strong><span class="setup-optional">增强选项</span></div><p class="setup-note">中文提问，也能找到英文记录；姓名、日期和关键词仍使用原问题。</p>${eligible?`${t.status==='ready'?`${badge('ready')}<p class="setup-note">中英翻译语言包可用，翻译在本机完成。</p>`:busy(t.status)||t.status==='error'||t.status==='paused'?resourceBox('translation:zh-en','中英翻译语言包',''):''}${!busy(t.status)&&t.status!=='ready'?`<button class="secondary-button" data-action="translation">${t.status==='error'?'重试准备':'准备中英翻译语言包'}</button>`:''}`:'<p class="setup-note">目前这项增强适用于简体中文与英文。所选语言的语义检索不受影响。</p>'}</div><p class="setup-privacy">${icon('shield')}<span>索引保存在 iPhone，只用于寻找相关记录。翻译增强不影响完成 AI 能力设置。</span></p>`;
  }
  function finalRows() {
    return capabilities.map(c=>`<div class="setup-final-row ${status(c.id)==='ready'?'':'is-missing'}">${icon(status(c.id)==='ready'?'check':'clock')}<div><strong>${c.title} · ${status(c.id)==='ready'?'已就绪':'待完成'}</strong><p>${status(c.id)==='ready'?esc(description(c.id)):c.missing}</p></div><button data-go="${c.id==='retrieval'?'ai':c.id}">${status(c.id)==='ready'?'查看':'去设置'}</button></div>`).join('');
  }
  function dataPage() {
    return `<p class="setup-kicker">03 / 让建议更贴近你的生活</p><h2 id="setupHeading" tabindex="-1">选择你的生活线索。</h2><p class="setup-lead">健康、日历与地点，帮 AI 理解你的生活。每项可选，随时调整。</p>${purpose('让回顾与建议结合你的作息和安排，而不只是一段对话。','数据默认留在设备上。系统授权不等于云端发送授权。')}<div class="setup-data-list">${dataSources.map(d=>{
      const value=state.data[d.id], granted=value==='granted', configured=value==='configured';
      const label=granted?'已允许':configured?'已完成权限选择':value==='denied'?'未授权':'未设置';
      const detail=granted?(d.id==='location'?'使用 App 期间；精确程度以系统设置为准。':'随时可在系统设置中撤销访问。'):configured?'健康项目由你在系统中选择；没有可读取数据，不代表你拒绝了授权。':value==='denied'?d.missing:'仅在点击下方按钮后，才申请这一项权限。';
      return `<section class="setup-data-card"><header><span class="capability-icon">${icon(d.icon)}</span><h3>${d.title}</h3><span class="setup-data-state ${granted||configured?'is-set':''}">${label}</span></header><p class="setup-data-purpose">${d.purpose}</p><p class="setup-note">${d.scope}</p><p class="setup-data-detail">${detail}</p><button class="setup-inline" data-permission="${d.id}">${granted||configured?'管理授权':value==='denied'?'去设置中开启':`设置${d.title}权限`} ${icon('arrow')}</button></section>`;
    }).join('')}</div><div class="setup-local-card">${icon('shield')}<div><strong>${localPromise()}</strong><p>${state.ai.mode==='local'?'个人记录保存在本机，转写、理解、检索都由设备上的模型完成。下载模型需要联网，使用模型无需上传个人记录。':'转写和检索仍在本机。健康、日历和地点默认不外发；如需用于云端问答，会先展示数据范围，由你另行允许。'}</p></div></div><p class="setup-note">可在「设置 → 数据来源」调整。麦克风、相机、照片与通知，在你首次使用对应功能时再申请。系统日历／健康已有的 iCloud 同步遵循你的系统设置。</p>`;
  }
  function guideImage(name, alt, caption, detail=true) {
    return `<figure class="usage-figure"><button class="usage-image-button" data-guide-image="${name}" data-guide-alt="${esc(alt)}" aria-label="放大查看：${esc(alt)}"><img src="assets/onboarding/${name}${detail?'-detail':''}.webp" alt="${esc(alt)}" loading="lazy"></button><figcaption>${caption}<span>轻点放大</span></figcaption></figure>`;
  }
  function usagePage() {
    const phone=state.usage.device==='iphone';
    return `<p class="setup-kicker">04 / 使用说明</p><h2 id="setupHeading" tabindex="-1">记录，从这里开始。</h2><p class="setup-lead">没有手表，一部 iPhone 就能录音和拍照。</p><div class="usage-device-switch" role="group" aria-label="选择设备使用说明"><button data-guide-device="iphone" aria-pressed="${phone}">使用 iPhone</button><button data-guide-device="watch" aria-pressed="${!phone}">使用 Apple Watch</button></div>${phone?iphoneGuide():watchGuide()}<p class="setup-note usage-provenance">图示来自 WiseLife 原生 App 模拟器截图。</p>`;
  }
  function iphoneGuide() {
    const topic=state.usage.topic;
    const tabs=[['record','开始录音'],['save','结束保存'],['photo','拍照与相册']];
    const body=topic==='record'?`<h3>1. 从「记此刻」开始</h3><p>在首页右下角轻点「＋ 记此刻」，再选择「语音」，就会开始录音。</p>${guideImage('iphone-home','首页底部的记此刻按钮','首页 · 右下角入口')}${guideImage('iphone-capture','记此刻菜单中的语音、记一条闪念与图片入口','记此刻 · 选择语音')}<div class="usage-tip"><strong>只想记一个想法？</strong><p>点「记一条闪念 →」。说完后，同样点「结束并保存」。iPhone 这里不需要一直按住按钮。</p></div>`:topic==='save'?`<h3>2. 说完，点「结束并保存」</h3><p>录音时，页面底部会出现红色计时条。轻点「结束并保存」，等待保存完成。</p>${guideImage('iphone-recording','录音中的红色计时条和结束并保存按钮','录音中 · 结束并保存')}<div class="usage-tip"><strong>之后在哪里看？</strong><p>图片和闪念可在「一天」查看；长录音加工后的内容片段也会进入时间轴。完整录音可从「查看全部 → 原始录音」查找。</p></div><p class="setup-note">模型尚未就绪时，原始录音仍可保存。转写和整理需要等待相应模型准备好，不代表保存失败。</p>`:`<h3>3. 用图片，留下眼前的画面</h3><p>轻点「记此刻 → 图片」。拍下眼前，或从相册选取已有照片。</p>${guideImage('iphone-photo','用图片记此刻页面的拍照和从相册选择按钮','图片 · 拍照或从相册选择')}<ol class="usage-instructions"><li><strong>拍照</strong><p>选择「拍照」，首次允许相机访问；拍摄后确认使用这张照片。</p></li><li><strong>从相册选择</strong><p>只选择你想记录的图片，一次最多 6 张；确认前可以移除。</p></li><li><strong>确认并保存</strong><p>预览图片，可补充一句话。文字识别完成后，点「保存记录」，回到「一天」查看。</p></li></ol><p class="setup-note">图片与识别文字保存在 iPhone。模拟器展示的是图片入口，实际拍摄需要在真机上完成。</p>`;
    return `<nav class="usage-topics" aria-label="iPhone 使用主题">${tabs.map(([id,title])=>`<button data-guide-topic="${id}" aria-pressed="${topic===id}">${title}</button>`).join('')}</nav><article class="usage-article">${body}</article><p class="setup-note">麦克风、相机权限在首次使用时申请。若未允许，可在 iPhone「设置 → App → WiseLife」中调整。</p>`;
  }
  function watchGuide() {
    return `<article class="usage-article"><h3>先把 WiseLife 装到手表</h3><ol class="usage-instructions"><li><strong>打开 iPhone 自带的 Watch App</strong><p>先完成 Apple Watch 与这部 iPhone 的配对，再进入「我的手表」。</p></li><li><strong>找到 WiseLife，轻点「安装」</strong><p>进入 App 列表，在「可用 App」中找到 WiseLife。部分系统版本直接在「我的手表」下显示此列表。</p></li><li><strong>在手表上打开 WiseLife</strong><p>若已自动安装，可在「已安装在 Apple Watch 上」查看。首次录音时，允许手表的麦克风权限。</p></li></ol><p class="setup-note">没有找到 WiseLife？确认 iPhone 已安装包含 Watch App 的版本、手表系统兼容，并等待安装完成。阅读说明不会自动安装或配对。</p><a class="setup-inline" href="https://support.apple.com/zh-cn/109023" target="_blank" rel="noopener noreferrer">Apple 官方安装说明 ↗</a><h3 class="usage-subheading">一个红色按钮，两种记录</h3>${guideImage('watch-recorder','Apple Watch 上的 WiseLife 红色录音按钮','Apple Watch · 原生录音页面',false)}<div class="usage-gestures"><div><span class="usage-record-dot" aria-hidden="true"></span><strong>轻点：持续录音</strong><p>点一下开始；再次点按停止按钮，结束并保存。</p></div><div>${icon('mic')}<strong>按住：记录闪念</strong><p>按住红色按钮，震动后说话；松手保存。向上滑再松手可取消。</p></div></div><div class="usage-tip"><strong>录音先保存在手表，再同步到 iPhone</strong><p>让两台设备靠近，保持蓝牙与 Wi-Fi 开启。无需在同一个 Wi-Fi；系统会安排传输，可能需要等待。</p><p>在 iPhone 首页点左上角手表状态，查看「待同步」或「最近同步」。已配对不等于文件已传完，也不代表 Watch App 已安装。</p></div><p class="setup-note">可选：长按表盘 → 编辑 → 复杂功能，添加 WiseLife 录音入口。轻点入口可开始录音；已经录音时只打开 App，结束仍需点停止按钮。</p><button class="setup-inline" data-guide-device="iphone">没有手表？查看 iPhone 录音与拍照 ${icon('arrow')}</button></article>`;
  }
  function reviewPage() {
    const full=count()===3, complete=full&&state.data.reviewed&&state.usage.reviewed;
    return `<div class="setup-success-mark ${complete?'':'is-partial'}">${icon(complete?'check':'clock')}</div><p class="setup-kicker">准备结果 · ${stepCount()} / 4 步完成</p><h2 id="setupHeading" tabindex="-1">${complete?'准备好了。<br>从你的第一条记录开始。':full?'AI 已就绪。<br>再完成使用准备。':'记录可以先开始。<br>AI 还需要一点准备。'}</h2><p class="setup-lead">${full?'语音转写与 AI 能力已就绪。数据授权按你的选择，不要求全部开启。':'没有准备完整的模型，WiseLife 的智能整理与问答体验会受限。已完成的设置会保留。'}</p>${finalRows()}<div class="setup-final-row ${state.data.reviewed?'':'is-pending'}">${icon(state.data.reviewed?'check':'clock')}<div><strong>数据授权 · ${state.data.reviewed?'已确认选择':'待选择（可跳过）'}</strong><p>${state.data.reviewed?dataSummary():'健康、日历、地点与提醒事项，由你逐项决定。'}</p></div><button data-go="data">${state.data.reviewed?'查看':'去选择'}</button></div><div class="setup-final-row ${state.usage.reviewed?'':'is-pending'}">${icon(state.usage.reviewed?'check':'clock')}<div><strong>使用说明 · ${state.usage.reviewed?'已了解':'待了解'}</strong><p>iPhone 录音与拍照；Apple Watch 安装与录音。</p></div><button data-go="usage">${state.usage.reviewed?'再看看':'去了解'}</button></div><p class="setup-privacy">${icon('shield')}<span>${localPromise()}${state.ai.mode==='custom'?' 数据授权不等于云端发送授权。':''}</span></p>${!full?'<div class="setup-warning"><strong>基础记录仍可使用</strong><p>你可以继续录音、拍照和查看已有内容。之后可在设置的「语言与 AI」中调整模型，在「数据来源」中管理授权。</p></div>':''}<p class="setup-note">模型或服务状态变化时，会提示你重新检查。</p>`;
  }
  function footer() {
    const page=state.page, ready=status(page)==='ready', s=status(page);
    if (page==='overview') return `<button class="primary-button" data-go="${firstPending()}">${stepCount()===0?'开始准备':stepCount()===4?'查看准备结果':'继续准备'} ${icon('arrow')}</button><button class="setup-secondary" data-action="skip">稍后设置，先记录</button>`;
    if (page==='review') return `<button class="primary-button" ${stepCount()===4?'data-go="home"':'data-action="resume"'}>${stepCount()===4?'开始使用 WiseLife':count()===3?(state.data.reviewed?'查看使用说明':'选择数据范围'):'继续完成设置'}</button>${stepCount()<4?'<button class="setup-secondary" data-action="skip">先使用基础记录功能</button>':'<p>以后可随时在设置中调整</p>'}`;
    if (page==='usage') return '<button class="primary-button" data-action="confirm-usage">我知道怎么记录了 '+icon('arrow')+'</button><p>无需拥有 Apple Watch，也能完成这一步</p>';
    if (page==='data') return '<button class="primary-button" data-action="confirm-data">按当前选择继续 '+icon('arrow')+'</button><p>可以一项也不开启，不影响完成这一步</p>';
    if (page==='ai') {
      const running=busy(currentAIStatus())||busy(status('retrieval'));
      return `<button class="primary-button" data-action="prepare-ai" ${running?'disabled':''}>${aiReady()?'下一步：数据授权':running?'正在准备 AI 能力…':'检查并准备 AI 能力'} ${!running?icon('arrow'):''}</button>${!aiReady()?'<button class="setup-secondary" data-action="next">稍后完成，先选数据范围</button>':'<p>理解与检索均已就绪</p>'}`;
    }
    const title=ready?'下一步：AI 能力':busy(s)?'正在准备…':s==='error'?'重新准备':s==='paused'?'继续准备':state.asr.engine==='apple'?'检查并准备语言包':'检查并下载多语言模型';
    return `<button class="primary-button" data-action="primary" ${busy(s)?'disabled':''}>${title}${ready?icon('arrow'):''}</button>${!ready?'<button class="setup-secondary" data-action="next">稍后设置此项</button>':'<p>模型已就绪，语音可在本机转写</p>'}`;
  }
  function render(moveFocus=false) {
    const previousScroll=$('setupContent')?.scrollTop || 0, focus=document.activeElement, focusID=focus?.id;
    const selection=focus?.tagName==='INPUT'&&typeof focus.selectionStart==='number'?[focus.selectionStart,focus.selectionEnd]:null;
    const page=state.page, step=steps.some(c=>c.id===page);
    const contents={overview,asr:asrPage,ai:aiPage,data:dataPage,usage:usagePage,review:reviewPage};
    $('setupApp').innerHTML=`<header class="setup-topbar">${page==='overview'?'<span>WiseLife</span>':`<button class="setup-back" data-go="${page==='settings'?'home':page==='home'?'overview':'overview'}" aria-label="返回准备清单">${icon('back')}</button><span>${page==='home'?'WiseLife':page==='settings'?'设置':'准备你的 WiseLife'}</span>`}${page==='home'?`<button data-go="settings" aria-label="设置">${icon('settings')}</button>`:page==='overview'?'<span class="setup-mini-badge">首次使用</span>':page==='settings'?'<span></span>':'<button data-action="skip">稍后</button>'}</header>${step?`<nav class="setup-steps" aria-label="设置步骤">${steps.map((c,i)=>`<button data-go="${c.id}" class="${['ready','reviewed','read'].includes(stepStatus(c.id))?'is-ready':''}" ${c.id===page?'aria-current="step"':''}>${i+1} ${c.title}</button>`).join('')}</nav>`:''}<div class="setup-content" id="setupContent" data-page="${page}">${contents[page]()}</div>${page==='home'?`<nav class="setup-home-nav" aria-label="底部导航"><button data-go="home">${icon('sun')}一天</button><button data-action="ask">${icon('chat')}AI</button><button data-go="settings">${icon('settings')}设置</button><button data-action="capture">${icon('mic')}记一刻</button></nav>`:`<footer class="setup-footer">${footer()}</footer>`}`;
    if (!moveFocus) {
      $('setupContent').scrollTop=previousScroll;
      if (focusID && $(focusID)) { $(focusID).focus({preventScroll:true}); if(selection) $(focusID).setSelectionRange(...selection); }
    } else { $('setupHeading').focus({preventScroll:true}); }
  }
  function go(page) {
    if(page==='home'){window.location.assign('iphone-day.html?preview=today#product');return;}
    state.page=page;render(true);
  }
  function next() { go(({asr:'ai',ai:'data',data:'usage',usage:'review'})[state.page] || 'review'); }
  function stopJob(key, paused=true) {
    const job=jobs.get(key); if(!job)return;
    clearInterval(job.timer); clearTimeout(job.finish); jobs.delete(key);
    if(key==='ai') { state.ai.status='missing'; state.ai.error=''; }
    else if(paused) state.resources[key]={...resource(key),status:'paused'};
  }
  function startResource(key) {
    if (jobs.has(key)||resource(key).status==='ready') return;
    const job={percent:0,outcome:$('demoOutcome').value,timer:null,finish:null}; jobs.set(key,job);
    state.resources[key]={status:'checking',percent:0}; render();
    job.timer=setInterval(()=>{
      if(jobs.get(key)!==job)return;
      job.percent+=10;
      if(job.percent>=60&&job.outcome!=='success') {
        clearInterval(job.timer); jobs.delete(key); state.resources[key]={status:'error',error:job.outcome,percent:0};
        announce('资源准备失败，请查看原因并重试。'); render(); return;
      }
      state.resources[key]={status:job.percent>=100?'validating':'downloading',percent:job.percent};
      if(job.percent>=100) {
        clearInterval(job.timer);
        job.finish=setTimeout(()=>{
          if(jobs.get(key)!==job)return;
          jobs.delete(key);state.resources[key]={status:'ready',percent:100};render();announce('资源已就绪，可以继续下一步。');
        },650);
      }
      render();
    },200);
  }
  function validateCustom() {
    const a=state.ai;
    if(!a.model.trim())return '请填写模型名称。';
    let u;try {u=new URL(a.url.trim());}catch{return '请填写完整的 Base URL。';}
    if(u.protocol!=='https:')return '请使用 HTTPS 服务地址。';
    if(u.username||u.password||u.search||u.hash)return '地址中不要包含账号、Key、查询参数或锚点。';
    if(/\/(chat\/completions|messages)\/?$/i.test(u.pathname))return '请使用 Base URL，去掉 /chat/completions 或 /messages 后缀。';
    if(!a.key.trim())return '请填写虚构的 API Key 来体验原型。';
    return null;
  }
  function checkAI() {
    if(jobs.has('ai'))return;
    const a=state.ai;
    if(a.mode==='custom') {
      const error=validateCustom();if(error){a.error=error;a.status='error';render();return;}
    }
    const expected=signature(), outcome=$('demoConnection').value, job={};jobs.set('ai',job);
    a.status='checking';a.error='';render();
    job.finish=setTimeout(()=>{
      if(jobs.get('ai')!==job||signature()!==expected)return;
      jobs.delete('ai');
      if(a.mode==='local'&&$('demoApple').value!=='available'){a.status='unsupported';}
      else if(a.mode==='custom'&&outcome!=='success'){a.status='error';a.error=outcome==='auth'?'API Key 无效，请检查后重新测试。':'暂时无法连接服务，请检查地址与网络后重试。';}
      else{a.status='ready';a.tested=expected;}
      render();announce(a.status==='ready'?'AI 模型已就绪。':'AI 模型尚未就绪，请查看提示。');
    },850);
  }
  function dialog(title, content, buttons) {
    dialogReturnFocus=document.activeElement;
    $('setupDialogLayer').innerHTML=`<section class="setup-dialog" role="dialog" aria-modal="true" aria-labelledby="setupDialogTitle" tabindex="-1"><h3 id="setupDialogTitle">${title}</h3>${content}${buttons}</section>`;
    $('setupDialogLayer').hidden=false;$('setupApp').inert=true;
    $('setupDialogLayer').querySelector('.setup-dialog').focus();
  }
  function closeDialog() { $('setupDialogLayer').hidden=true;$('setupDialogLayer').innerHTML='';$('setupApp').inert=false;if(dialogReturnFocus?.isConnected)dialogReturnFocus.focus(); }
  function skip() {
    if(stepCount()===4){go('home');return;}
    const missing=capabilities.filter(c=>status(c.id)!=='ready');
    dialog(missing.length?'AI 还没准备完整':'先开始记录',`<p>${missing.length?'WiseLife 仍可保存录音、图片和已有记录，但以下能力会受限：':'语音转写与 AI 能力已就绪，会先根据你自己记录的内容工作。'}</p>${missing.length?`<ul>${missing.map(c=>`<li>${c.missing}</li>`).join('')}</ul>`:''}${!state.data.reviewed?'<p>数据授权还未确认。未授权的健康、日历和地点不会被使用，之后可逐项开启。</p>':''}${!state.usage.reviewed?'<p>没有手表也可以记录：从首页右下角「记此刻」录音或添加图片。</p>':''}<p>已完成的设置会保留。之后可在设置的「语言与 AI」中调整模型，在「数据来源」中管理授权。</p>`, '<button class="primary-button" data-action="return-setup">继续设置</button><button class="setup-secondary" data-action="confirm-skip">先使用基础记录</button>');
  }
  function permissionDialog(id) {
    const d=dataSources.find(item=>item.id===id); if(!d)return;
    const managed=state.data[id]!=='unrequested';
    dialog(`${d.title}权限`, `<p>${d.purpose}</p><p>${d.scope}</p><div class="setup-benefit">${d.missing}</div><p class="setup-note">原型演示：正式 App ${managed?'会引导你到系统中管理权限':'会请求对应的系统权限'}。此页面不读取任何真实数据。${id==='health'?'健康项目逐项选择，App 不会获知你拒绝了哪些读取权限。':''}</p>`, `<button class="primary-button" data-permission-result="${id}" data-result="${id==='health'?'configured':'granted'}">${id==='health'?'模拟完成系统选择':'模拟允许访问'}</button><button class="setup-secondary" data-permission-result="${id}" data-result="${id==='health'?'configured':'denied'}">${id==='health'?'模拟未选择健康项目':managed?'模拟关闭访问':'模拟不允许'}</button><button class="setup-secondary" data-action="return-setup">返回，不修改</button>`);
  }
  function reset(scenario) {
    jobs.forEach((_,key)=>stopJob(key,false));closeDialog();state=initial();state.scenario=scenario;
    $('demoApple').value='available';$('demoOutcome').value='success';$('demoConnection').value='success';
    document.querySelectorAll('[data-scenario]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.scenario===scenario)));
    if(scenario==='unsupported') {state.page='ai';$('demoApple').value='unsupported';}
    if(scenario==='failed'){state.page='asr';state.resources[asrKey()]={status:'error',error:'network'};}
    if(scenario==='partial'){state.page='review';state.resources[asrKey()]={status:'ready',percent:100};}
    if(scenario==='ready') {
      state.page='review';state.resources[asrKey()]={status:'ready',percent:100};state.resources[vectorKey()]={status:'ready',percent:100};state.ai.status='ready';state.ai.tested=signature();
      state.data.reviewed=true;state.usage.reviewed=true;
    }
    if(scenario==='data'){state.page='data';state.resources[asrKey()]={status:'ready',percent:100};state.resources[vectorKey()]={status:'ready',percent:100};state.ai.status='ready';state.ai.tested=signature();}
    if(scenario==='usage'){state.page='usage';state.resources[asrKey()]={status:'ready',percent:100};state.resources[vectorKey()]={status:'ready',percent:100};state.ai.status='ready';state.ai.tested=signature();state.data.reviewed=true;}
    if(scenario==='downloading')state.page='asr';
    announce('');render(true); if(scenario==='downloading')startResource(asrKey());
  }
  document.addEventListener('click', event=>{
    const b=event.target.closest('button');if(!b||b.disabled)return;
    if(b.dataset.scenario){reset(b.dataset.scenario);return;}
    if(b.dataset.go){go(b.dataset.go);return;}
    if(b.dataset.guideDevice){state.usage.device=b.dataset.guideDevice;render();$('setupContent').scrollTop=0;document.querySelector(`[data-guide-device="${state.usage.device}"]`)?.focus({preventScroll:true});return;}
    if(b.dataset.guideTopic){state.usage.topic=b.dataset.guideTopic;render();$('setupContent').scrollTop=0;document.querySelector(`[data-guide-topic="${state.usage.topic}"]`)?.focus({preventScroll:true});return;}
    if(b.dataset.guideImage){dialog('界面截图',`<img class="guide-full-image" src="assets/onboarding/${esc(b.dataset.guideImage)}.webp" alt="${esc(b.dataset.guideAlt)}"><p class="setup-note">模拟器中的原生 App 截图，点击下方返回说明。</p>`,'<button class="primary-button" data-action="return-setup">返回使用说明</button>');return;}
    if(b.dataset.permission){permissionDialog(b.dataset.permission);return;}
    if(b.dataset.permissionResult){state.data[b.dataset.permissionResult]=b.dataset.result;closeDialog();render();announce('权限选择已更新；由系统决定实际可读的数据。');return;}
    if(b.dataset.cancelJob){stopJob(b.dataset.cancelJob);render();return;}
    const action=b.dataset.action;
    if(action==='primary'){if(status(state.page)==='ready')next();else if(state.page==='ai')checkAI();else startResource(state.page==='asr'?asrKey():vectorKey());}
    if(action==='next')next();
    if(action==='check-ai')checkAI();
    if(action==='prepare-retrieval')startResource(vectorKey());
    if(action==='prepare-ai'){if(aiReady())next();else{if(currentAIStatus()!=='ready')checkAI();if(status('retrieval')!=='ready')startResource(vectorKey());}}
    if(action==='skip')skip();
    if(action==='confirm-data'){state.data.reviewed=true;go('usage');}
    if(action==='confirm-usage'){state.usage.reviewed=true;go('review');}
    if(action==='return-setup')closeDialog();
    if(action==='confirm-skip'){closeDialog();go('home');}
    if(action==='resume')go(firstPending());
    if(action==='translation')startResource('translation:zh-en');
    if(action==='lighter'){stopJob(asrKey());state.asr.size='tiny';render();}
    if(action==='fill-example'){stopJob('ai');state.page='ai';Object.assign(state.ai,{mode:'custom',model:'my-demo-model',url:'https://api.example.com/v1',key:'demo-not-a-real-key',status:'missing',tested:'',error:''});render();}
    if(action==='system-help')dialog('准备 Apple Intelligence','<p>打开 iPhone「设置 → Apple Intelligence 与 Siri」，查看开启条件和系统下载状态。</p><p>若设备、地区或所需语言不支持，可主动配置自定义 AI，或稍后再设置。回到 WiseLife 后会重新检查。</p><p class="setup-note">这里是原型说明，不会打开真实系统设置。右侧演示控制可以模拟系统状态变化。</p>','<button class="primary-button" data-action="return-setup">知道了</button>');
    if(action==='capture')dialog('记一刻',`<p>AI 未准备好也可以保存原始记录。</p><button class="secondary-button" data-action="capture-demo">${icon('mic')}录一段语音</button><button class="secondary-button" data-action="capture-demo">${icon('photo')}拍照或选择图片</button><p class="setup-note">本页只评审引导，不调用麦克风或相册。完整记录流程见主原型。</p>`,'<button class="setup-secondary" data-action="return-setup">返回</button>');
    if(action==='capture-demo'){closeDialog();announce('这里只演示入口，不采集真实数据。');}
    if(action==='ask')dialog(currentAIStatus()==='ready'?'从第一条记录开始':'先准备 AI 模型',`<p>${currentAIStatus()==='ready'?'现在还没有个人记录，AI 暂时没有可引用的生活信息。先留下一条语音或图片。':'你还没有可用的 AI 模型，暂时无法生成回答。已有记录仍可查看。'}</p>`, `${currentAIStatus()==='ready'?'<button class="primary-button" data-action="return-setup">知道了</button>':'<button class="primary-button" data-action="configure-ai">去设置 AI 模型</button><button class="setup-secondary" data-action="return-setup">稍后</button>'}`);
    if(action==='configure-ai'){closeDialog();go('ai');}
    if(b.id==='demoTheme'){const dark=document.documentElement.dataset.appearance!=='dark';document.documentElement.dataset.appearance=dark?'dark':'light';b.setAttribute('aria-pressed',String(dark));b.textContent=dark?'切换浅色外观':'切换深色外观';}
  });
  document.addEventListener('change',event=>{
    const el=event.target;
    if(el.name==='asrEngine'){stopJob(asrKey());state.asr.engine=el.value;render();}
    if(el.id==='setupAppleLanguage'){stopJob(asrKey());state.asr.apple=el.value;render();}
    if(el.id==='setupWhisperSize'){stopJob(asrKey());state.asr.size=el.value;render();}
    if(el.id==='setupWhisperLanguage'){state.asr.whisper=el.value;render();}
    if(el.name==='aiMode'){stopJob('ai');state.ai.mode=el.value;state.ai.status='missing';state.ai.error='';render();}
    if(el.id==='setupProtocol'){stopJob('ai');state.ai.protocol=el.value;state.ai.status='missing';state.ai.error='';render();}
    if(el.id==='setupVectorLanguage'){stopJob(vectorKey());state.retrieval.language=el.value;render();}
    if(el.id==='demoApple'){stopJob('ai');if(state.ai.mode==='local'){state.ai.status='missing';state.ai.tested='';}render();}
  });
  document.addEventListener('input',event=>{
    const field={setupModel:'model',setupURL:'url',setupKey:'key'}[event.target.id];
    if(field){stopJob('ai');state.ai[field]=event.target.value;state.ai.status='missing';state.ai.tested='';state.ai.error='';render();}
  });
  document.addEventListener('keydown',event=>{
    if($('setupDialogLayer').hidden)return;
    if(event.key==='Escape'){event.preventDefault();closeDialog();}
    if(event.key==='Tab'){
      const elements=Array.from($('setupDialogLayer').querySelectorAll('button,a,input,select'));
      const first=elements[0],last=elements.at(-1);
      if(event.shiftKey&&(!elements.includes(document.activeElement)||document.activeElement===first)){event.preventDefault();last?.focus();}
      else if(!event.shiftKey&&(!elements.includes(document.activeElement)||document.activeElement===last)){event.preventDefault();first?.focus();}
    }
  });
  window.addEventListener('pagehide',()=>jobs.forEach((_,key)=>stopJob(key,false)));
  const requested=new URLSearchParams(window.location.search).get('state');
  reset(['fresh','downloading','failed','unsupported','partial','ready','data','usage'].includes(requested)?requested:'fresh');
})();
