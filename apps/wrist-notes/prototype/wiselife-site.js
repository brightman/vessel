(() => {
  'use strict';
  const links = [...document.querySelectorAll('.site-nav a')];
  const sections = [...document.querySelectorAll('.site-screen')];
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

  document.querySelectorAll('[data-demo-view]').forEach(button => {
    button.addEventListener('click', () => {
      const target = button.dataset.demoView === 'data'
        ? document.getElementById('settingsButton')
        : document.querySelector('.bottom-nav [data-view="ai"]');
      target?.click();
      document.getElementById('product').scrollIntoView({behavior:'instant'});
      target?.focus({preventScroll:true});
    });
  });

  document.querySelectorAll('[data-data-mode]').forEach(button => {
    button.addEventListener('click', () => {
      const isLocal = button.dataset.dataMode === 'local';
      document.querySelectorAll('[data-data-mode]').forEach(option => {
        option.setAttribute('aria-pressed', String(option === button));
      });
      document.getElementById('localDataMode').hidden = !isLocal;
      document.getElementById('cloudDataMode').hidden = isLocal;
    });
  });

  if ('IntersectionObserver' in window) {
    const navigationObserver = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (!entry.isIntersecting) return;
        links.forEach(link => {
          if (link.hash === `#${entry.target.id}`) link.setAttribute('aria-current','location');
          else link.removeAttribute('aria-current');
        });
      });
    }, {rootMargin:'-20% 0px -65% 0px',threshold:0});
    sections.forEach(section => navigationObserver.observe(section));

    if (!reduceMotion.matches) {
      const revealObserver = new IntersectionObserver(entries => {
        entries.forEach(entry => {
          if (!entry.isIntersecting) return;
          entry.target.classList.remove('is-waiting');
          revealObserver.unobserve(entry.target);
        });
      }, {threshold:.08});
      document.querySelectorAll('.hardware-card,.ownership-feature,.data-choice').forEach(element => {
        element.classList.add('site-reveal','is-waiting');
        revealObserver.observe(element);
      });
    }
  }
})();
