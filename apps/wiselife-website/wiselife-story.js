/* Website-only interactions; the embedded app remains the source of demo state. */
(() => {
  'use strict';
  const reduceMotion=window.matchMedia('(prefers-reduced-motion: reduce)');
  const tabs=[...document.querySelectorAll('[data-story]')];
  const stackedTabs=window.matchMedia('(min-width: 901px)');
  const orientTabs=()=>document.querySelector('.story-tabs').setAttribute('aria-orientation',stackedTabs.matches?'vertical':'horizontal');
  orientTabs();stackedTabs.addEventListener('change',orientTabs);
  const activateStory=tab=>{
    tabs.forEach(button=>{
      const active=button===tab;
      button.setAttribute('aria-selected',String(active));button.tabIndex=active?0:-1;
      const panel=document.getElementById(button.getAttribute('aria-controls'));
      panel.getAnimations().forEach(animation=>animation.cancel());panel.hidden=!active;
      if(active&&!reduceMotion.matches)panel.animate([{opacity:0,transform:'translateY(10px)'},{opacity:1,transform:'none'}],{duration:320,easing:'ease-out'});
    });
  };
  tabs.forEach(tab=>{
    tab.addEventListener('click',()=>activateStory(tab));
    tab.addEventListener('keydown',event=>{
      const offset=['ArrowDown','ArrowRight'].includes(event.key)?1:['ArrowUp','ArrowLeft'].includes(event.key)?-1:0;
      if(!offset&&!['Home','End'].includes(event.key))return;
      event.preventDefault();
      const next=event.key==='Home'?tabs[0]:event.key==='End'?tabs.at(-1):tabs[(tabs.indexOf(tab)+offset+tabs.length)%tabs.length];
      activateStory(next);next.focus();
    });
  });
  const product=document.getElementById('product');
  document.querySelectorAll('[data-site-record]').forEach(button=>button.addEventListener('click',()=>{
    product.scrollIntoView({behavior:'instant',block:'start'});
    document.getElementById('dateButton').click();
    document.querySelector('#sheet [data-day="19"]').click();
    document.getElementById('allMomentsButton').click();
    document.querySelector(`#libraryMoments [data-record="${button.dataset.siteRecord}"]`)?.click();
  }));
  document.querySelectorAll('[data-demo-hardware]').forEach(button=>button.addEventListener('click',()=>{
    product.scrollIntoView({behavior:'instant',block:'start'});
    document.getElementById('watchButton').click();
    document.querySelector(`#sheet [data-hardware="${button.dataset.demoHardware}"]`)?.click();
  }));
  const video=document.getElementById('productFilm');
  const start=document.getElementById('filmStart');
  const error=document.getElementById('filmError');
  const chapters=[...document.querySelectorAll('[data-film-time]')];
  let seekOnLoad=null;
  const play=seconds=>{
    error.hidden=true;
    video.scrollIntoView({behavior:'instant',block:'center'});
    if(Number.isFinite(seconds)){
      if(video.readyState>=1)video.currentTime=Math.min(seconds,video.duration||seconds);
      else seekOnLoad=seconds;
    }
    video.play().catch(()=>{error.hidden=false;start.hidden=false;});
  };
  document.querySelectorAll('[data-play-film]').forEach(button=>button.addEventListener('click',()=>play(video.ended?0:undefined)));
  chapters.forEach(button=>button.addEventListener('click',()=>play(Number(button.dataset.filmTime))));
  video.addEventListener('loadedmetadata',()=>{if(seekOnLoad!==null){video.currentTime=Math.min(seekOnLoad,video.duration);seekOnLoad=null;}});
  video.addEventListener('play',()=>{start.hidden=true;error.hidden=true;});
  video.addEventListener('ended',()=>{start.hidden=false;});
  video.addEventListener('error',()=>{error.hidden=false;start.hidden=false;});
  video.addEventListener('timeupdate',()=>{
    let current=chapters[0];
    for(const chapter of chapters)if(Number(chapter.dataset.filmTime)<=video.currentTime)current=chapter;
    chapters.forEach(chapter=>chapter.setAttribute('aria-pressed',String(chapter===current)));
  });
  new IntersectionObserver(entries=>{if(!entries[0].isIntersecting)video.pause();},{threshold:0}).observe(video);
  document.addEventListener('visibilitychange',()=>{if(document.hidden)video.pause();});
  window.addEventListener('pagehide',()=>video.pause());
  const captions=()=>{
    const selected=document.documentElement.lang.startsWith('zh')?'zh':document.documentElement.lang;
    for(const track of video.textTracks)track.mode=track.language===selected?'showing':'disabled';
  };
  new MutationObserver(captions).observe(document.documentElement,{attributes:true,attributeFilter:['lang']});
  video.addEventListener('loadedmetadata',captions);
  if('IntersectionObserver' in window){
    const reveal=new IntersectionObserver(entries=>entries.forEach(entry=>{
      if(entry.isIntersecting){entry.target.classList.remove('is-waiting');reveal.unobserve(entry.target);}
    }),{threshold:.08});
    if(!reduceMotion.matches)document.querySelectorAll('.moments-copy,.story-stage,.film-heading,.film-frame,.questions-layout,.closing-screen .site-container').forEach(element=>{
      element.classList.add('site-reveal','is-waiting');reveal.observe(element);
    });
    reduceMotion.addEventListener('change',()=>{if(reduceMotion.matches)document.querySelectorAll('.site-reveal.is-waiting').forEach(element=>element.classList.remove('is-waiting'));});
  }
})();
