/* Alternate homepage. No AI calls, tracking, recording or personal data collection. */
(() => {
  'use strict';
  // Add verified public URLs here when acquisition opens. Empty values remain unavailable.
  const destinations = Object.freeze({ appStore:'', testFlight:'', macDownload:'', appFunding:'', ringFunding:'' });
  const labels = { appStore:'前往 App Store ↗', testFlight:'加入 TestFlight ↗', macDownload:'下载 Mac 伴侣 ↗', appFunding:'前往 App 众筹 ↗', ringFunding:'前往 Ring 众筹 ↗' };
  document.querySelectorAll('[data-destination]').forEach(link => {
    const value = destinations[link.dataset.destination];
    if (value && /^https:\/\//.test(value)) {
      link.href = value; link.removeAttribute('aria-disabled'); link.textContent = labels[link.dataset.destination];
      link.target = '_blank'; link.rel = 'noopener noreferrer';
    }
  });
  const models = {
    '16': { summary:'轻量起步。首选 4B，给系统与日常应用留出余量；9B 建议短上下文评估。', list:[
      ['Qwen3.5 4B','首选 · 轻量中文问答与记录整理','3.3–4.0 GB','qwen3.5:4b'],
      ['Qwen3.5 9B','进阶 · 中文理解，需更多运行余量','6.6–7.6 GB','qwen3.5:9b'],
      ['Gemma 4 E2B','备选 · 轻量多语言个人助手','4.6–7.5 GB','gemma4:e2b']] },
    '24': { summary:'日常均衡。优先 9B／12B；20B 推理模型建议短上下文、关闭高占用应用后评估。', list:[
      ['Qwen3.5 9B','首选 · 中文回顾与日常问答','6.6–7.6 GB','qwen3.5:9b'],
      ['Gemma 4 12B','备选 · 多语言理解与内容整理','7.7–8.0 GB','gemma4:12b'],
      ['gpt-oss 20B','进阶 · 任务推理，内存余量较小','14 GB','gpt-oss:20b']] },
    '32': { summary:'更深入地分析。27B／26B 是进阶候选，建议单模型、4K 上下文起步。', list:[
      ['Qwen3.6 27B','首选 · 中文复杂任务与推理候选','18–19 GB','qwen3.6:27b'],
      ['Gemma 4 26B A4B','备选 · MoE 架构的效率与质量平衡','16–19 GB','gemma4:26b'],
      ['gpt-oss 20B','备选 · 推理与结构化行动提取','14 GB','gpt-oss:20b']] },
    '64': { summary:'更充裕的本地算力。可评估更强的模型与更长上下文；更大并不总是更快。', list:[
      ['Qwen3.6 35B-A3B','首选 · MoE 架构，复杂个人助理任务','23–24 GB','qwen3.6:35b'],
      ['Gemma 4 31B','备选 · 优先考虑回答质量的稠密模型','19–20 GB','gemma4:31b'],
      ['Qwen3.6 27B','备选 · 中文推理与内存余量平衡','18–19 GB','qwen3.6:27b']] }
  };
  function renderModels(memory) {
    const data=models[memory]; if(!data)return;
    document.querySelectorAll('[data-memory]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.memory===memory)));
    const target=document.getElementById('model-results'); target.replaceChildren();
    const summary=document.createElement('p'); summary.className='model-summary'; summary.textContent=`${memory}GB 统一内存 · ${data.summary}`; target.append(summary);
    const list=document.createElement('div'); list.className='model-list';
    data.list.forEach(([name,use,size,tag])=>{
      const article=document.createElement('article');article.className='model';
      const heading=document.createElement('h4');heading.textContent=name;
      const description=document.createElement('p');description.textContent=use;
      const weight=document.createElement('small');weight.textContent=`模型下载体积约 ${size}`;
      const link=document.createElement('a');link.href=`https://ollama.com/library/${tag}`;link.target='_blank';link.rel='noopener noreferrer';link.textContent='模型与版本说明 ↗';link.setAttribute('aria-label',`${name} 模型与版本说明`);
      article.append(heading,description,weight,link);list.append(article);
    });target.append(list);
  }
  document.querySelectorAll('[data-memory]').forEach(b=>b.addEventListener('click',()=>renderModels(b.dataset.memory)));renderModels('16');
  const routes={
    phone:['记录 → iPhone 本地模型 → 本机保存','使用已下载且可用的本地模型，个人记录无需发送给 WiseLife 或外部 AI 服务。'],
    mac:['iPhone → 你授权的 Mac → 结果回到 iPhone','规划中的局域网方案：只把必要文字发给自己的 Mac，在 Mac 上运行开放模型。Mac 伴侣开发中，需设备在线；远程连接方式尚未提供。'],
    external:['选中的文字 → 你配置的 AI → 结果保存回本机','可选模式。你授权后，相关文字直接发送给所选服务商；若选择“下次不再提示”，后续沿用授权。此模式不属于纯端处理。']
  };
  document.querySelectorAll('[data-route]').forEach(button=>button.addEventListener('click',()=>{
    const data=routes[button.dataset.route];if(!data)return;
    document.querySelectorAll('[data-route]').forEach(b=>b.setAttribute('aria-pressed',String(b===button)));
    document.querySelector('#route-result h3').textContent=data[0];document.querySelector('#route-result p').textContent=data[1];
  }));
  document.querySelectorAll('a[href="#compatibility"]').forEach(link=>link.addEventListener('click',()=>{document.getElementById('compatibility').open=true;}));
  const menu=document.querySelector('.menu-toggle'),nav=document.getElementById('navigation');
  function closeMenu(){menu.setAttribute('aria-expanded','false');nav.classList.remove('open');}
  menu.addEventListener('click',()=>{const open=menu.getAttribute('aria-expanded')!=='true';menu.setAttribute('aria-expanded',String(open));nav.classList.toggle('open',open);});
  nav.querySelectorAll('a').forEach(a=>a.addEventListener('click',closeMenu));
  document.addEventListener('keydown',event=>{if(event.key==='Escape'&&menu.getAttribute('aria-expanded')==='true'){closeMenu();menu.focus();}});
  const video=document.querySelector('video');
  document.addEventListener('visibilitychange',()=>{if(document.hidden)video.pause();});
  if('IntersectionObserver' in window)new IntersectionObserver(entries=>{entries.forEach(entry=>{if(!entry.isIntersecting)video.pause();});},{threshold:.1}).observe(video);
})();
