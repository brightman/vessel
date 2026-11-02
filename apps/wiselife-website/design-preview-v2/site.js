(() => {
  'use strict';
  const $ = selector => document.querySelector(selector);
  const $$ = selector => [...document.querySelectorAll(selector)];
  const dialog = $('#site-dialog');
  const content = $('#dialog-content');
  const menu = $('#main-nav');
  const toggle = $('.menu-toggle');
  const escape = value => String(value).replace(/[&<>"']/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));
  const tag = text => `<span class="dialog-tag">${text}</span>`;
  const siteRoot = new URL('../', document.currentScript.src).href;
  const mediaRoot = new URL('assets/hd/', document.currentScript.src).href;
  const artworkRoot = new URL('assets/', document.currentScript.src).href;
  const appLink = `<a class="button blue-button" href="${siteRoot}product-demos/iphone/">Explore the iPhone demo ↗</a>`;
  const footerLinks = `<div class="dialog-links"><a href="${siteRoot}privacy/">Privacy policy</a><a href="${siteRoot}terms/">Terms</a></div>`;
  const routes = {download:'download',video:'video',signin:'signin',pricing:'pricing',faq:'faq',privacy:'privacy-details',capture:'capture',insights:'insights',action:'action',clarity:'clarity',today:'today',work:'work',rhythm:'rhythm',remember:'remember','iphone-screen':'iphone-screen','ai-screen':'ai-screen','mac-screen':'mac-screen','watch-screen':'watch-screen'};
  let current = null;
  let opener = null;
  let ownsHistoryEntry = false;
  let activeMode = 'phone';
  const action = {title:'Prepare the first design draft',date:'',saved:false};
  const stories = {
    clarity:['A clearer day starts with a little context.','Return to the moments that mattered, connect ideas across your records, and choose what deserves your attention.','See your memories in the iPhone prototype. The website reads no personal records.'],
    today:['See your day, at a glance.','Bring your captured moments, activity, sleep, and daily recap into one calm view. Explore the current Day prototype.','These are genuine product prototype screens with sample data, not screenshots from an installed native app.'],
    work:['Be present. Keep what matters.','A conversation becomes a record you can return to. Find decisions, revisit a useful idea, and review the next step before acting.','Recording starts and stops with you. This preview does not access the microphone.'],
    rhythm:['Find your own rhythm.','With your permission, Apple Health activity, sleep, and training records can sit alongside the moments you capture. Ask what changed, or look back on a week.','Health records depend on your device, Apple Health permissions, and the data available. AI suggestions are for reflection, not medical advice.'],
    remember:['A thought today. Something useful tomorrow.','Keep conversations, ideas, and reflections together. Ask your own records a question, then follow the answer back to the original words.','The linked prototype uses example data. No personal information is sent from this page.']
  };
  const screens = {
    'iphone-screen': ['Your day, in focus.', 'iphone-day.webp', 'iphone/', 'Daily rhythm, voice records, steps, sleep, and yesterday’s recap — captured from the current Day prototype.', true],
    'ai-screen': ['Ask your own life a question.', 'iphone-ai.webp', 'iphone/', 'The current iPhone Ask AI view. Explore the questions and follow answers back to their records.', true],
    'mac-screen': ['On-Device LLM', 'mac-models.webp', 'mac/#models', 'Host your LLM on Mac and make it available to your paired iPhone. The current prototype shows Qwen3-4B loaded, the LLM API available, and the local service enabled.', false],
    'watch-screen': ['A thought, kept in a tap.', 'watch-recording.webp', 'watch/', 'The current Watch prototype: start or stop a recording, capture a quick thought, and see saved notes.', true]
  };
  function view(type) {
    if (screens[type]) {
      const [title, file, route, description, portrait] = screens[type];
      const screen = type === 'watch-screen'
        ? `<span class="watch-hardware"><img class="watch-frame" src="${artworkRoot}watch-hardware.svg" width="260" height="560" alt="" aria-hidden="true"><img class="watch-screen" src="${mediaRoot}${file}" alt="${description}"></span>`
        : `<img src="${mediaRoot}${file}" alt="${description}">`;
      return `<div class="screenshot-layout"><div class="screenshot-view ${portrait?'portrait':''} ${type==='watch-screen'?'watch-view':''}">${screen}</div><div class="screenshot-details">${tag('Inside WiseLife')}<h2 id="dialog-title">${title}</h2><p>${description}</p><div class="dialog-actions"><a class="button blue-button" href="${siteRoot}product-demos/${route}">Try the interactive prototype ↗</a></div><a class="source-link" href="${mediaRoot}${file}" target="_blank" rel="noopener">View full-resolution image ↗</a><p class="dialog-note">Actual product prototype · sample data. Captured at 3× resolution; not a native device screenshot.</p></div></div>`;
    }
    if (stories[type]) {const [title,body,note] = stories[type];return `${tag('Your life with WiseLife')}<h2 id="dialog-title">${title}</h2><p>${body}</p><div class="dialog-actions">${appLink}</div><p class="dialog-note">${note}</p>`;}
    if(type==='download') return `${tag('Explore WiseLife')}<h2 id="dialog-title">Meet your private AI companion.</h2><p>Try the current product prototypes. Capture a thought on Watch, return to your day on iPhone, and run your own LLM on Mac.</p><div class="dialog-actions"><a class="button outline-button" href="${siteRoot}product-demos/watch/">Try the Watch demo ↗</a>${appLink}<a class="button outline-button" href="${siteRoot}product-demos/mac/#models">Explore Mac Companion ↗</a></div><p class="dialog-note">Try the iPhone beta on <a href="https://testflight.apple.com/join/HjdCdWJu" target="_blank" rel="noopener">TestFlight ↗</a>. These interactive previews use sample data. Public Mac download links will appear here when available.</p>`;
    if(type==='signin') return `${tag('No account required')}<h2 id="dialog-title">You already have what you need.</h2><p>No WiseLife cloud account is required for local records or local AI. Get to know the app with the interactive prototypes.</p><div class="dialog-actions">${appLink}<button class="button outline-button" data-open="privacy">How privacy works</button></div>`;
    if(type==='video') return `${tag('Product walkthrough')}<h2 id="dialog-title">A day with WiseLife.</h2><video controls playsinline preload="metadata" poster="${siteRoot}assets/wiselife/film-poster.webp"><source src="${siteRoot}assets/wiselife/wiselife-walkthrough.mp4" type="video/mp4"><track kind="captions" src="${siteRoot}assets/wiselife/walkthrough-en.vtt" srclang="en" label="English" default></video><p class="dialog-note">27-second walkthrough of the interactive prototype. Example records; not a live device recording.</p>`;
    if(type==='pricing') return `${tag('Choose your WiseLife experience')}<h2 id="dialog-title">Your data. Your AI. Yours.</h2><div class="plan-grid"><article class="plan-card"><h3>WiseLife App</h3><p class="price">$9.90</p><p>Planned one-time App price.<br>Apple Watch + iPhone.</p></article><article class="plan-card"><h3>Mac Companion</h3><p class="price">Preview</p><p>Host your LLM locally and serve your paired iPhone.</p></article></div><div class="dialog-actions"><button class="button blue-button" data-open="download">Explore the apps</button></div><p class="dialog-note">Design-stage pricing, not a live offer. Final availability, pricing, and purchase terms will be confirmed at launch. This page collects no payments.</p>`;
    if(type==='privacy') return `${tag('Private by design')}<h2 id="dialog-title">Choose where your AI runs.</h2><p>Your records stay on your devices by default. Local processing does not need a WiseLife cloud account.</p><div class="privacy-tabs" role="tablist" aria-label="AI processing mode"><button id="tab-phone" role="tab" aria-controls="privacy-panel" aria-selected="true" data-mode="phone">iPhone</button><button id="tab-mac" role="tab" aria-controls="privacy-panel" aria-selected="false" tabindex="-1" data-mode="mac">Your Mac</button><button id="tab-external" role="tab" aria-controls="privacy-panel" aria-selected="false" tabindex="-1" data-mode="external">External AI</button></div><div id="privacy-panel" class="privacy-panel" role="tabpanel" aria-labelledby="tab-phone" tabindex="0"></div><p class="dialog-note">Local models keep processing on your devices. If you choose an external AI provider, selected content leaves your devices with your permission. iCloud backup, Apple Health, Calendar, and Reminders follow your Apple settings. There is no automatic cloud AI fallback.</p>${footerLinks}`;
    if(type==='capture') return `${tag('01 · Capture')}<h2 id="dialog-title">Let the thought stay.</h2><p>Tap to start a longer recording, or hold to capture a quick thought. With permission, activity and sleep records add context to the moments you keep.</p><div class="sample-record"><small>Example voice note · 10:30 AM</small><blockquote>“I should prepare the first design draft before our next meeting.”</blockquote></div><div class="dialog-actions"><button class="button blue-button" data-open="insights">See the insight</button><a class="button outline-button" href="${siteRoot}product-demos/watch/">Try recording on Watch ↗</a></div><p class="dialog-note">You start and stop voice recording. This website demonstrates the flow without recording audio.</p>`;
    if(type==='insights') return `${tag('02 · Insight')}<h2 id="dialog-title">Find the next useful step.</h2><div class="sample-record"><small>Based on your example voice note</small><blockquote>Prepare a first draft before the next meeting.</blockquote><button class="source-link" data-open="capture">Read the original words ↗</button></div><p>Check the source and decide whether this suggestion is right for you.</p><div class="dialog-actions"><button class="button blue-button" data-open="action">Review the suggested action</button></div>`;
    if(type==='action') return `${tag('03 · Action')}<h2 id="dialog-title">A next step you choose.</h2><p>Review the title and choose a date before adding the example reminder.</p>${action.saved?`<div class="confirmation" role="status"><strong>Added to this preview.</strong><p>${escape(action.title)}<br>${escape(action.date)}</p><p>Apple Reminders was not changed.</p></div><button class="button outline-button" data-edit-action>Edit this reminder</button>`:`<form class="action-form" id="action-form"><label for="action-title">Reminder<input id="action-title" name="title" maxlength="120" value="${escape(action.title)}" required></label><label for="action-date">Your chosen date<input id="action-date" name="date" type="date" value="${escape(action.date)}" required></label><button class="button blue-button" type="submit">Confirm in preview</button></form>`}<div class="sample-record"><small>Source: your example voice note</small><br><button class="source-link" data-open="capture">Return to the original capture ↗</button></div>`;
    if(type==='faq') return `${tag('A few helpful answers')}<h2 id="dialog-title">Made for your own life.</h2><div class="faq-list"><details open><summary>Do I need a cloud account?</summary><p>No WiseLife cloud account is needed for local records and local AI.</p></details><details><summary>Does all AI processing stay on my devices?</summary><p>When you choose supported on-device models, yes. Your authorized Mac can also serve local models. If you configure an external AI provider, selected content is sent to that provider with your permission. iCloud backup follows your Apple settings.</p></details><details><summary>Can I download WiseLife from this page?</summary><p>Yes. Try the iPhone beta on <a href="https://testflight.apple.com/join/HjdCdWJu" target="_blank" rel="noopener">TestFlight ↗</a>. You can also explore the Apple Watch, iPhone, and Mac prototypes. Public Mac download links will be added when available.</p></details><details><summary>Do I need to buy new hardware?</summary><p>Begin with your iPhone. Apple Watch, EurekaRing, and Mac Companion are optional ways to capture or process your records. Local AI availability depends on your model and OS.</p></details><details><summary>Are these real product screens?</summary><p>Yes. The screens are captured directly from the current WiseLife Apple Watch, iPhone, and Mac product prototypes at 3× resolution. They show sample records, not private user data or installed native apps. Click a screen to enlarge it or explore the matching interactive prototype.</p></details><details><summary>What does this website save?</summary><p>The landing-page action example stays in page memory and resets on reload. Linked product prototypes may remember demonstration preferences in your browser. No account, payment, or microphone recording is required.</p></details></div>${footerLinks}`;
    return '';
  }
  function closeMenu(){toggle.setAttribute('aria-expanded','false');menu.classList.remove('open');}
  function mode(type){
    activeMode=type;
    const data={phone:['On your iPhone','Supported local models process your records on iPhone. Model downloads may need an internet connection; your private records are not sent to WiseLife servers.'],mac:['On your authorized Mac','Mac Companion can provide local model APIs over your own network. The content needed for a request goes to the Mac you choose for local processing.'],external:['Only when you choose','Selected text leaves your devices and is sent to your configured AI provider. Permission is requested unless you have chosen to remember that permission.']};
    $$('[data-mode]').forEach(button=>{const selected=button.dataset.mode===type;button.setAttribute('aria-selected',String(selected));button.tabIndex=selected?0:-1;});
    $('#privacy-panel').setAttribute('aria-labelledby','tab-'+type);
    $('#privacy-panel').innerHTML=`<h3>${data[type][0]}</h3><p>${data[type][1]}</p>`;
  }
  function render(type){
    dialog.querySelector('video')?.pause();current=type;content.innerHTML=view(type);dialog.classList.toggle('video-mode',type==='video');dialog.classList.toggle('screen-mode',Boolean(screens[type]));if(!dialog.open)dialog.showModal();if(type==='privacy')mode(activeMode);dialog.scrollTop=0;$('#close-dialog').focus({preventScroll:true});
  }
  function open(type,source){
    if(!routes[type])return;
    closeMenu();
    if(!dialog.open){opener=source||document.activeElement;history.pushState({wiselifePreviewDialog:true},'','#'+routes[type]);ownsHistoryEntry=true;}
    else history.replaceState(history.state,'','#'+routes[type]);
    render(type);
  }
  function close(){
    if(!dialog.open)return;
    dialog.close();
    if(ownsHistoryEntry){ownsHistoryEntry=false;history.back();}
    else if(Object.values(routes).includes(location.hash.slice(1)))history.replaceState(history.state,'',location.pathname+location.search);
  }
  function syncRoute(){
    const type=Object.keys(routes).find(key=>routes[key]===location.hash.slice(1));
    if(type){if(type!==current||!dialog.open)render(type);}
    else if(dialog.open){ownsHistoryEntry=false;dialog.close();}
  }
  document.addEventListener('click',event=>{
    const trigger=event.target.closest('[data-open]');if(trigger){event.preventDefault();open(trigger.dataset.open,trigger);return;}
    if(event.target.closest('[data-edit-action]')){action.saved=false;render('action');$('#action-title').focus();}
    const tab=event.target.closest('[data-mode]');if(tab)mode(tab.dataset.mode);
  });
  toggle.addEventListener('click',()=>{const expanded=toggle.getAttribute('aria-expanded')!=='true';toggle.setAttribute('aria-expanded',String(expanded));menu.classList.toggle('open',expanded);});
  menu.addEventListener('click',event=>{if(event.target.closest('a'))closeMenu();});
  document.addEventListener('click',event=>{if(!event.target.closest('.header'))closeMenu();});
  document.addEventListener('keydown',event=>{if(event.key==='Escape'&&toggle.getAttribute('aria-expanded')==='true'){closeMenu();toggle.focus();}});
  $('#close-dialog').addEventListener('click',close);
  dialog.addEventListener('cancel',event=>{event.preventDefault();close();});
  dialog.addEventListener('click',event=>{if(event.target!==dialog)return;const rect=dialog.getBoundingClientRect();if(event.clientX<rect.left||event.clientX>rect.right||event.clientY<rect.top||event.clientY>rect.bottom)close();});
  dialog.addEventListener('close',()=>{dialog.querySelector('video')?.pause();current=null;if(opener?.isConnected)opener.focus({preventScroll:true});});
  dialog.addEventListener('keydown',event=>{
    const tab=event.target.closest('[data-mode]');if(!tab)return;
    const tabs=$$('[data-mode]');let index=tabs.indexOf(tab);
    if(event.key==='ArrowRight')index=(index+1)%tabs.length;else if(event.key==='ArrowLeft')index=(index+tabs.length-1)%tabs.length;else if(event.key==='Home')index=0;else if(event.key==='End')index=tabs.length-1;else return;
    event.preventDefault();mode(tabs[index].dataset.mode);tabs[index].focus();
  });
  dialog.addEventListener('input',event=>{if(event.target.id==='action-title'){action.title=event.target.value;event.target.setCustomValidity('');}if(event.target.id==='action-date')action.date=event.target.value;});
  dialog.addEventListener('submit',event=>{if(event.target.id!=='action-form')return;event.preventDefault();const title=$('#action-title');if(!title.value.trim()){title.setCustomValidity('Enter a reminder title.');title.reportValidity();return;}action.title=title.value.trim();action.saved=true;render('action');});
  window.addEventListener('popstate',syncRoute);
  window.addEventListener('hashchange',syncRoute);
  syncRoute();
})();
