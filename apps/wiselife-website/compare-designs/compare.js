(() => {
  const frames = [...document.querySelectorAll('.preview-frame')];
  const tabs = [...document.querySelectorAll('[data-view]')];
  function scale(){frames.forEach(frame=>frame.style.setProperty('--scale',frame.clientWidth/1024));}
  new ResizeObserver(scale).observe(document.querySelector('.comparison'));
  window.addEventListener('resize',scale);scale();
  function select(view,update=true){
    const reference=view==='reference';
    tabs.forEach(button=>{const chosen=button.dataset.view===view;button.setAttribute('aria-selected',String(chosen));button.tabIndex=chosen?0:-1;});
    document.querySelector('#comparison').setAttribute('aria-labelledby',view+'-tab');
    document.querySelector('#left-frame iframe').hidden=reference;
    document.querySelector('#reference-image').hidden=!reference;
    document.querySelector('#left-tag').textContent=reference?'REF':'V1';
    document.querySelector('#left-title').textContent=reference?'Your life. Your AI. Your privacy.':'Your life, remembered.';
    document.querySelector('#left-subtitle').textContent=reference?'用户设计原图 · 1024 × 1536':'山野与行动 · 上一版';
    document.querySelector('#left-open').href=reference?'../design-preview-v2/evidence/reference.png':'../design-preview/';
    if(update)history.replaceState(null,'',reference?'#reference':location.pathname);
    scale();
  }
  tabs.forEach(button=>button.addEventListener('click',()=>select(button.dataset.view)));
  document.querySelector('.view-tabs').addEventListener('keydown',event=>{if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;event.preventDefault();const index=tabs.indexOf(document.activeElement);const next=event.key==='Home'?0:event.key==='End'?1:(index+1)%2;select(tabs[next].dataset.view);tabs[next].focus();});
  window.addEventListener('hashchange',()=>select(location.hash==='#reference'?'reference':'versions',false));
  select(location.hash==='#reference'?'reference':'versions',false);
})();
