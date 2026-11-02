(() => {
  'use strict';
  const $ = selector => document.querySelector(selector);
  const $$ = selector => [...document.querySelectorAll(selector)];
  const escape = text => String(text).replace(/[&<>"']/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));
  const menu = $('.menu-button');
  menu.addEventListener('click', () => { const open = menu.getAttribute('aria-expanded') !== 'true'; menu.setAttribute('aria-expanded', String(open)); $('#navigation').classList.toggle('open', open); });
  $('#navigation').addEventListener('click', event => { if (event.target.closest('a')) { menu.setAttribute('aria-expanded', 'false'); $('#navigation').classList.remove('open'); } });
  document.addEventListener('keydown', event => { if (event.key === 'Escape' && menu.getAttribute('aria-expanded') === 'true') { menu.setAttribute('aria-expanded', 'false'); $('#navigation').classList.remove('open'); menu.focus(); } });
  let dialogOpener;
  $$('[data-dialog]').forEach(button => button.addEventListener('click', () => { dialogOpener = button; document.getElementById(button.dataset.dialog).showModal(); }));
  $$('dialog').forEach(dialog => {
    dialog.querySelector('.close-dialog').addEventListener('click', () => dialog.close());
    dialog.addEventListener('click', event => { if (event.target === dialog) { const r = dialog.getBoundingClientRect(); if (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) dialog.close(); } });
    dialog.addEventListener('close', () => { dialog.querySelector('video')?.pause(); dialogOpener?.focus(); });
  });
  function wireTabs(selector, select) {
    const buttons = $$(selector);
    const activate = button => { buttons.forEach(tab => { const active = tab === button; tab.setAttribute('aria-selected', String(active)); tab.tabIndex = active ? 0 : -1; }); select(button); };
    buttons.forEach((button, index) => {
      button.addEventListener('click', () => activate(button));
      button.addEventListener('keydown', event => { let next; if (['ArrowRight','ArrowDown'].includes(event.key)) next = (index + 1) % buttons.length; if (['ArrowLeft','ArrowUp'].includes(event.key)) next = (index + buttons.length - 1) % buttons.length; if (event.key === 'Home') next = 0; if (event.key === 'End') next = buttons.length - 1; if (next !== undefined) { event.preventDefault(); buttons[next].focus(); activate(buttons[next]); } });
    });
  }
  const devices = {
    watch: {image:'assets/watch.webp', className:'watch-visual', description:'A quick thought or a longer conversation, captured from your wrist. Recordings transfer to your paired iPhone for review and transcription.', link:'demos/watch.html', label:'Explore the Watch demo', alt:'Actual WiseLife Watch recording prototype'},
    iphone: {image:'assets/iphone.webp', className:'iphone-visual', description:'Your recordings, transcripts and meaningful moments in one timeline. Ask questions, follow the sources, and choose your next step.', link:'demos/iphone.html#product', label:'Explore the iPhone demo', alt:'Actual WiseLife iPhone daily records prototype'},
    mac: {image:'assets/companion.webp', className:'mac-visual', description:'Companion is in development: run local models and explore your personal knowledge on a Mac you control. The knowledge-base experience shown here is a prototype.', link:'demos/mac/index.html#knowledge', label:'Explore the Mac prototype', alt:'Actual WiseLife Companion knowledge-base prototype'}
  };
  wireTabs('[data-device]', button => { const d = devices[button.dataset.device]; $('#device-image').src = d.image; $('#device-image').alt = d.alt; $('#device-image').className = d.className; $('#device-description').textContent = d.description; $('#device-demo').href = d.link; $('#device-demo').innerHTML = `${d.label} <span aria-hidden="true">↗</span>`; $('#device-panel').setAttribute('aria-labelledby', button.id); });
  function showContext(type) {
    const panel = $('#today-context');
    const contents = {
      sleep:['Sleep context', 'Sample Apple Health sleep data: 7h 18m. Sleep duration alone does not determine your energy or health. No medical score is inferred.'],
      schedule:['Calendar context', 'Three sample events are on the calendar. The next one starts at 3:30 PM. Calendar availability is a clue, not proof that you are free.'],
      suggestion:['From your sample records', 'The next calendar event is at 3:30 PM. A voice note mentions a proposal draft you want to finish. A free calendar slot does not guarantee you are available.']
    };
    const [title, text] = contents[type]; panel.innerHTML = `<strong>${title}</strong><p>${text}</p>`; panel.hidden = false; $('#context-button').setAttribute('aria-expanded','true');
  }
  $$('[data-context]').forEach(button => button.addEventListener('click', () => showContext(button.dataset.context)));
  $('#context-button').addEventListener('click', () => { if ($('#today-context').hidden) showContext('suggestion'); else { $('#today-context').hidden = true; $('#context-button').setAttribute('aria-expanded','false'); } });
  $('#preview-today').addEventListener('click', () => { showContext('suggestion'); $('#today-context').focus({preventScroll:true}); $('#today-context').scrollIntoView({block:'center',behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth'}); });
  let reminder = {title:'Prepare the new design',date:'2026-11-02',saved:false};
  const memory = {
    record: () => `<div class="memory-explainer"><small>Capture the original thought</small><h3>A moment you can return to.</h3><p>Keep the voice and the words together. A useful memory starts with what was actually said.</p></div><div class="record-example"><small>10:30 AM · Product discussion · Apple Watch</small><blockquote>“I should prepare the new design before our next meeting.”</blockquote><button class="text-link" data-step="ask">Ask about this memory <span aria-hidden="true">↗</span></button></div>`,
    ask: () => `<div class="memory-explainer"><small>Ask with context</small><h3>Find the thread worth following.</h3><p>A grounded answer points back to the record. You can always read the original words.</p></div><div><div class="question-bubble">What do I need to prepare for our next meeting?</div><div class="answer-text"><p>You mentioned preparing a new design. You could start with a first draft and review it before the meeting.</p><button class="source-button" data-step="record">[1] Product discussion · 10:30 AM ↗</button></div><button class="text-link" data-step="action" style="margin-top:20px">Review the next step <span aria-hidden="true">↗</span></button></div>`,
    action: () => `<div class="memory-explainer"><small>You decide what happens</small><h3>A suggestion.<br>Your next step.</h3><p>Edit the title and date, then confirm. Nothing is added on your behalf.</p><button class="source-button" data-step="record">Source: Product discussion ↗</button></div>${reminder.saved?`<div class="reminder-success" role="status"><strong>Added to this demo.</strong><p>${escape(reminder.title)}<br>${escape(reminder.date)}</p><p>This stays in the preview only. Apple Reminders was not changed.</p><button class="text-link" data-edit-reminder>Edit the example <span aria-hidden="true">↗</span></button></div>`:`<form class="reminder-form" id="reminder-form"><label>Reminder<input id="reminder-title" value="${escape(reminder.title)}" maxlength="120" required></label><label>Your chosen date<input id="reminder-date" type="date" value="${escape(reminder.date)}" required></label><button class="button" type="submit">Confirm in demo <span aria-hidden="true">↗</span></button></form>`}`
  };
  function renderMemory(key) { $('#memory-panel').innerHTML = memory[key](); $('#memory-panel').setAttribute('aria-labelledby','memory-tab-'+key); }
  wireTabs('[data-memory]', button => renderMemory(button.dataset.memory)); renderMemory('record');
  $('#memory-panel').addEventListener('click', event => { const step = event.target.closest('[data-step]'); if (step) { const tab = $(`[data-memory="${step.dataset.step}"]`); tab.click(); tab.focus(); } if (event.target.closest('[data-edit-reminder]')) { reminder.saved = false; renderMemory('action'); $('#reminder-title').focus(); } });
  $('#memory-panel').addEventListener('input', event => { if (event.target.id === 'reminder-title') reminder.title = event.target.value; if (event.target.id === 'reminder-date') reminder.date = event.target.value; });
  $('#memory-panel').addEventListener('submit', event => { if (event.target.id === 'reminder-form') { event.preventDefault(); const title = $('#reminder-title'); if (!title.value.trim()) { title.setCustomValidity('Enter a reminder title.'); title.reportValidity(); title.addEventListener('input',()=>title.setCustomValidity(''),{once:true}); return; } reminder.saved = true; renderMemory('action'); $('#memory-panel').focus(); } });
  const modes = {
    phone: {route:`<div class="route-node"><img src="../assets/brand/app-icon.png" alt="" width="32" height="32"><strong>Your iPhone</strong><small>Records + local AI</small></div>`, title:'Your memories stay close.', text:'Supported transcription and AI models process on your iPhone. Model downloads may require internet access. Your personal content is not sent to WiseLife servers.'},
    mac: {route:`<div class="route-node"><strong>Your iPhone</strong><small>Selected content</small></div><div class="route-arrow"><span>↔</span><small>Your local network</small></div><div class="route-node"><strong>Your Mac</strong><small>Local model</small></div>`,title:'More room to think. Still your devices.',text:'Companion is in development. When you choose Mac processing, the content needed for the request goes to your authorized Mac on the local network. It does not pass through a WiseLife cloud.'},
    external: {route:`<div class="route-node"><strong>Your iPhone</strong><small>Selected text</small></div><div class="route-arrow"><span>→</span><small>Your permission</small></div><div class="route-node"><strong>Your provider</strong><small>External AI</small></div>`,title:'A choice you make explicitly.',text:'If you enable an external provider, selected text leaves your devices and follows that provider’s policies. Sharing asks for confirmation unless you choose to remember your permission. Audio and photos are not sent through this text integration.'}
  };
  function renderMode(key) {const mode=modes[key];$('#privacy-panel').innerHTML=`<div class="data-route">${mode.route}</div><div class="route-description"><h3>${mode.title}</h3><p>${mode.text}</p></div>`;$('#privacy-panel').setAttribute('aria-labelledby','mode-'+key);}
  wireTabs('[data-mode]',button=>renderMode(button.dataset.mode));renderMode('phone');
  let selectedInterest = null;
  $$('[data-interest]').forEach(link=>link.addEventListener('click',()=>{selectedInterest=link.dataset.interest;$$('#launch-success input').forEach(input=>input.checked=input.value===selectedInterest);}));
  $('#launch-form').addEventListener('submit', event => {
    event.preventDefault(); const email = $('#launch-email'); const consent = $('#launch-consent'); const error = $('#email-error');
    email.removeAttribute('aria-invalid'); consent.removeAttribute('aria-invalid'); error.hidden = true;
    if (!email.validity.valid || !email.value.trim()) { error.textContent = 'Please enter a valid email address.'; error.hidden=false; email.setAttribute('aria-invalid','true');email.focus();return; }
    if (!consent.checked) {error.textContent='Please choose whether to receive launch news.';error.hidden=false;consent.setAttribute('aria-invalid','true');consent.focus();return;}
    // Local demonstration: never persist, log or transmit the submitted email.
    email.value = ''; consent.checked = false; $('#launch-form').hidden=true;$('#launch-success').hidden=false;$('#launch-success').focus();
    if(selectedInterest)$$('#launch-success input').forEach(input=>input.checked=input.value===selectedInterest);
  });
  $('#reset-launch').addEventListener('click',()=>{$('#launch-success').hidden=true;$('#launch-form').hidden=false;$('#launch-email').focus();});
  $('#theme-button').addEventListener('click',()=>{const dark=document.documentElement.dataset.theme!=='dark';document.documentElement.dataset.theme=dark?'dark':'light';$('#theme-button').setAttribute('aria-pressed',String(dark));$('#theme-button').textContent=dark?'Light appearance':'Dark appearance';});
  if('IntersectionObserver' in window&&!matchMedia('(prefers-reduced-motion: reduce)').matches){const observer=new IntersectionObserver(entries=>entries.forEach(entry=>{if(entry.isIntersecting){entry.target.classList.add('visible');observer.unobserve(entry.target);}}),{threshold:.12});$$('.reveal').forEach(element=>observer.observe(element));}
})();
