// Website-only entry: use the existing prototype controls and preserve its UI and sample state.
(() => {
  if (location.hash !== '#models') return;
  document.querySelector('#navigation [data-page="models"]')?.click();
  const main = document.querySelector('#main');
  const services = main?.querySelector('.api-grid')?.closest('.card');
  if (services) main.scrollTop = services.getBoundingClientRect().top - main.getBoundingClientRect().top - 24;
})();
