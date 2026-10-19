/* Settings interaction demo. No downloads, provider calls or persistent secrets. */
window.createDaybookModelSettings=function(app){
  'use strict';
  const {$,esc,icon,toast,openSheet,closeSheet}=app;
  const catalog=window.daybookModelCatalog;
  const names=new Intl.DisplayNames(['zh-Hans'],{type:'language'});
  const languageName=code=>code==='auto'?'自动检测':names.of(code);
  const protocols={openai:{label:'OpenAI',name:'OpenAI Chat Completions',suffix:'/chat/completions'},anthropic:{label:'Anthropic',name:'Anthropic Messages',suffix:'/messages'}};
  const saved={asr:{engine:'apple',language:'zh-CN',size:'base',whisperLanguage:'auto'},ai:{mode:'local',protocol:'openai',model:'',url:'',key:''}};
  const resources=new Set(['apple:zh-CN','apple:en-US']);
  let asr,ai,downloadTimer=null,testTimer=null,percent=0,downloadError=false,testState='idle',testedSignature='',active=null;
  const option=(value,label,selected)=>`<option value="${esc(value)}" ${selected===value?'selected':''}>${esc(label)}</option>`;
  function labels(){
    $('dayASRLabel').textContent=saved.asr.engine==='apple'?`iPhone端上转写 · ${catalog.apple.find(l=>l.id===saved.asr.language).label}`:`Whisper ${saved.asr.size} · ${languageName(saved.asr.whisperLanguage)}`;
    $('dayAIModelLabel').textContent=saved.ai.mode==='local'?'Apple 本地模型':`${saved.ai.model} · ${protocols[saved.ai.protocol].label}`;
  }
  function cancelDownload(){clearInterval(downloadTimer);downloadTimer=null;percent=0;downloadError=false;}
  function cancelTest(){clearTimeout(testTimer);testTimer=null;testState='idle';testedSignature='';}
  function resource(){return asr.engine==='apple'?{key:`apple:${asr.language}`,name:`${catalog.apple.find(l=>l.id===asr.language).label}语言包`}:{key:`whisper:${asr.size}`,name:`Whisper ${asr.size} 多语言模型`};}
  function openASR(){
    cancelDownload();cancelTest();active='asr';asr={...saved.asr};
    openSheet('语音转写模型',`<p class="sheet-intro">先选择模型，再选择转写语言和离线资源。</p><div role="radiogroup" aria-label="转写模型"><label class="model-choice"><input type="radio" name="dayASREngine" value="apple" ${asr.engine==='apple'?'checked':''}><span><strong>iPhone端上转写</strong><small>iPhone系统语音模型，无需API Key，支持单语言转写，按需下载系统语言包</small></span></label><label class="model-choice"><input type="radio" name="dayASREngine" value="whisper" ${asr.engine==='whisper'?'checked':''}><span><strong>Whisper</strong><small>下载多语言模型后离线转写，可指定语言或自动检测，无需逐语言下载。</small></span></label></div><div id="dayASROptions"></div><div class="model-resource" id="dayASRResource" aria-live="polite"></div><p class="source-footnote">资源状态和下载为演示。iPhone 语言列表沿用现有原型的 30 项快照；实际 App 按当前设备支持情况显示。</p><details class="model-demo-options"><summary>下载演示选项</summary><label class="model-field"><span>模拟结果</span><select id="dayDownloadOutcome"><option value="success">成功</option><option value="error">网络失败</option></select></label></details><div class="model-actions"><button class="secondary-button" data-model-action="cancel">取消</button><button class="primary-button" id="daySaveASR" data-model-action="save-asr">${icon('Check')}保存设置</button></div>`);
    renderASR();
  }
  function renderASR(){
    const whisper=asr.engine==='whisper';
    $('dayASROptions').innerHTML=whisper?`<label class="model-field"><span>模型大小</span><select id="dayWhisperSize">${[['tiny','Tiny · 更轻量'],['base','Base · 均衡'],['small','Small · 更高精度']].map(([v,l])=>option(v,l,asr.size)).join('')}</select></label><label class="model-field"><span>转写语言</span><select id="dayWhisperLanguage">${['auto',...catalog.whisper].map(code=>option(code,languageName(code),asr.whisperLanguage)).join('')}</select></label><p class="source-footnote">多语言模型下载一次，其支持的语言共用；切换语言不需要重新下载。更大模型通常占用更多存储与内存。</p>`:`<label class="model-field"><span>转写语言</span><select id="dayAppleLanguage">${catalog.apple.map(l=>option(l.id,l.label,asr.language)).join('')}</select></label><p class="source-footnote">一次选择一种语言。系统已有语言资源可以复用，缺少时按需下载。</p>`;
    renderResource();
  }
  function renderResource(){
    if(active!=='asr'||!$('dayASRResource'))return;
    const r=resource(),ready=resources.has(r.key),running=downloadTimer!==null;
    $('dayASRResource').innerHTML=`<strong>${esc(r.name)} · ${ready?'已就绪':running?`${percent}%`:downloadError?'下载失败':'尚未下载'}</strong><p>${ready?'可保存设置，应用于后续转写任务。':running?'正在演示下载，关闭页面或切换资源会取消。':downloadError?'模拟网络错误，可重试，也可以修改演示结果。':'下载完成后才可保存；此原型不下载真实资源。'}</p>${running?`<progress max="100" value="${percent}" aria-label="资源下载演示进度"></progress><button class="secondary-button" data-model-action="cancel-download">取消下载</button>`:ready?'':`<button class="secondary-button" data-model-action="download">${downloadError?'重新下载':asr.engine==='apple'?'下载语言包':'下载多语言模型'}（演示）</button>`}`;
    $('daySaveASR').disabled=!ready;
  }
  function download(){
    if(downloadTimer!==null||resources.has(resource().key))return;
    const selected=resource(),fail=$('dayDownloadOutcome').value==='error';
    percent=0;downloadError=false;
    downloadTimer=setInterval(()=>{
      percent+=20;
      if(percent>=100){clearInterval(downloadTimer);downloadTimer=null;if(fail)downloadError=true;else resources.add(selected.key);}
      renderResource();
    },220);
    renderResource();
  }
  function openAI(){
    cancelDownload();cancelTest();active='ai';ai={...saved.ai};
    openSheet('AI 模型',`<p class="sheet-intro">用于笔记总结、跨记录洞察与 AI 对话。</p><div role="radiogroup" aria-label="AI 模型来源"><label class="model-choice"><input type="radio" name="dayAIMode" value="local" ${ai.mode==='local'?'checked':''}><span><strong>Apple 本地模型</strong><small>由 Apple Intelligence 提供，在 iPhone 上处理文本，无需 API Key。</small></span></label><label class="model-choice"><input type="radio" name="dayAIMode" value="custom" ${ai.mode==='custom'?'checked':''}><span><strong>自定义模型</strong><small>使用自己的服务与 Key，支持 OpenAI 或 Anthropic 兼容接口。</small></span></label></div><div id="dayLocalAI" class="local-banner">${icon('ShieldCheck')}<div><strong>需要 Apple Intelligence 可用</strong><p>在系统设置中启用并下载。可用性取决于设备、语言和地区；不可用时不自动切换远程服务。</p></div></div><div id="dayCustomAI"><label class="model-field"><span>API 接口兼容</span><select id="dayAIProtocol">${Object.entries(protocols).map(([v,p])=>option(v,p.label,ai.protocol)).join('')}</select></label><label class="model-field"><span>模型名称</span><input id="dayAIModel" maxlength="120" value="${esc(ai.model)}" placeholder="例如 my-model" autocomplete="off" autocapitalize="off" spellcheck="false"></label><label class="model-field"><span>服务地址 · Base URL</span><input id="dayAIURL" type="url" value="${esc(ai.url)}" placeholder="https://api.example.com/v1" autocomplete="off" autocapitalize="off" spellcheck="false"></label><p class="source-footnote" id="dayAIProtocolHint"></p><label class="model-field"><span>API Key</span><input id="dayAIKey" type="password" value="${esc(ai.key)}" placeholder="原型请填写虚构 Key" autocomplete="off" autocapitalize="off" spellcheck="false"></label><p class="source-footnote">正式 App 使用自定义模型时，会发送你允许用于本次任务的文本。此原型不发送数据，图片也不会上传；图片理解能力需按模型另行验证。</p><button class="secondary-button" id="dayTestAI" data-model-action="test-ai">模拟测试连接</button><p id="dayAITestStatus" class="model-status" role="status"></p><details class="model-demo-options"><summary>连接测试演示选项</summary><label class="model-field"><span>模拟结果</span><select id="dayAIOutcome"><option value="success">成功</option><option value="auth">Key 无效</option><option value="network">连接失败</option></select></label></details></div><p class="source-footnote">配置仅保留在本页，刷新后清空。保存不连接真实 AI，示例对话仍使用预设回答。</p><div class="model-actions"><button class="secondary-button" data-model-action="cancel">取消</button><button class="primary-button" id="daySaveAI" data-model-action="save-ai">${icon('Check')}保存设置</button></div>`);
    renderAI();
  }
  function renderAI(){
    const custom=ai.mode==='custom';$('dayCustomAI').hidden=!custom;$('dayLocalAI').hidden=custom;
    const p=protocols[ai.protocol];$('dayAIProtocolHint').textContent=`兼容 ${p.name}。填写 Base URL（通常以 /v1 结尾），不含末尾 ${p.suffix}。`;
    status('idle','原型不连接服务，请使用虚构的 Key。修改配置后需重新模拟测试。');
  }
  function readAI(){ai={...ai,protocol:$('dayAIProtocol').value,model:$('dayAIModel').value.trim(),url:$('dayAIURL').value.trim().replace(/\/+$/,''),key:$('dayAIKey').value.trim()};}
  function signature(){return JSON.stringify(ai);}
  function status(state,message){
    testState=state;$('dayAITestStatus').textContent=message;$('dayAITestStatus').dataset.state=state;
    $('dayTestAI').disabled=state==='testing';$('daySaveAI').disabled=ai.mode==='custom'&&state!=='success';
  }
  function validateAI(){
    if(!Object.hasOwn(protocols,ai.protocol))return '请选择 API 接口兼容协议。';
    if(!ai.model)return '请填写模型名称。';
    let url;try{url=new URL(ai.url);}catch{return '请填写完整的 Base URL。';}
    if(url.protocol!=='https:'&&!(url.protocol==='http:'&&['localhost','127.0.0.1','[::1]'].includes(url.hostname)))return '请使用 HTTPS；本机 localhost 可以使用 HTTP。';
    if(url.username||url.password||url.search||url.hash)return '地址中请勿包含账号、Key、查询参数或锚点。';
    if(/\/(chat\/completions|messages)\/?$/i.test(url.pathname))return '请填写 Base URL，去掉末尾的 /chat/completions 或 /messages。';
    if(!ai.key)return '请填写虚构的 API Key，用于演示配置流程。';
    return null;
  }
  function testAI(){
    cancelTest();readAI();const error=validateAI();if(error){status('error',error);return;}
    const expected=signature(),outcome=$('dayAIOutcome').value;
    status('testing','正在演示连接测试…');
    testTimer=setTimeout(()=>{
      testTimer=null;if(active!=='ai'||signature()!==expected||ai.mode!=='custom')return;
      if(outcome!=='success'){status('error',outcome==='auth'?'模拟失败：API Key 无效，请检查后重试。':'模拟失败：无法连接服务，请检查地址后重试。');return;}
      testedSignature=expected;status('success',`${protocols[ai.protocol].label} 模拟测试通过，可以保存。未连接真实服务。`);
    },700);
  }
  document.addEventListener('click',event=>{
    const b=event.target.closest('[data-model-action]');if(!b)return;
    const actions={
      cancel:closeSheet,download,'cancel-download':()=>{cancelDownload();renderResource();},'test-ai':testAI,
      'save-asr':()=>{if(!resources.has(resource().key))return;saved.asr={...asr};labels();closeSheet();toast('转写设置已保存（演示）。');},
      'save-ai':()=>{readAI();if(ai.mode==='custom'&&(testState!=='success'||signature()!==testedSignature||validateAI())){status('error','配置已变化，请重新模拟测试。');return;}saved.ai={...ai};labels();closeSheet();toast('AI 模型设置已保存（演示）。');}
    };
    actions[b.dataset.modelAction]?.();
  });
  document.addEventListener('change',event=>{
    const el=event.target;
    if(el.name==='dayASREngine'){cancelDownload();asr.engine=el.value;renderASR();}
    if(el.id==='dayAppleLanguage'){cancelDownload();asr.language=el.value;renderResource();}
    if(el.id==='dayWhisperSize'){cancelDownload();asr.size=el.value;renderResource();}
    if(el.id==='dayWhisperLanguage')asr.whisperLanguage=el.value;
    if(el.name==='dayAIMode'){readAI();cancelTest();ai.mode=el.value;renderAI();}
    if(el.id==='dayAIProtocol'||el.id==='dayAIOutcome'){readAI();cancelTest();renderAI();}
  });
  document.addEventListener('input',event=>{
    if(['dayAIModel','dayAIURL','dayAIKey'].includes(event.target.id)){readAI();cancelTest();status('idle','配置已修改，请重新模拟测试。');}
  });
  $('sheet').addEventListener('close',()=>{cancelDownload();cancelTest();active=null;ai=null;asr=null;});
  window.addEventListener('pagehide',()=>{cancelDownload();cancelTest();});
  labels();
  return {openASR,openAI};
};
