(() => {
  const showcase = document.querySelector('[data-scroll-showcase]');
  const stage = document.querySelector('[data-scroll-stage]');
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  let frame = 0;

  const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value));
  const listenForMotionChanges = (listener) => {
    if (typeof reducedMotion.addEventListener === 'function') {
      reducedMotion.addEventListener('change', listener);
    } else {
      reducedMotion.addListener(listener);
    }
  };

  if (showcase && stage) {
    const render = () => {
      frame = 0;

      if (reducedMotion.matches) {
        stage.style.setProperty('--mac-x', '0px');
        stage.style.setProperty('--mac-y', '0px');
        stage.style.setProperty('--phone-x', '0px');
        stage.style.setProperty('--phone-y', '0px');
        stage.style.setProperty('--ipad-x', '0px');
        stage.style.setProperty('--ipad-y', '0px');
        stage.style.setProperty('--caption-opacity', '1');
        return;
      }

      const rect = showcase.getBoundingClientRect();
      const travel = Math.max(1, rect.height - window.innerHeight);
      const progress = clamp(-rect.top / travel, 0, 1);
      const eased = 1 - Math.pow(1 - progress, 3);

      stage.style.setProperty('--mac-x', `${Math.round(-30 * eased)}px`);
      stage.style.setProperty('--mac-y', `${Math.round(-14 * eased)}px`);
      stage.style.setProperty('--phone-x', `${Math.round(-54 * eased)}px`);
      stage.style.setProperty('--phone-y', `${Math.round(24 - 62 * eased)}px`);
      stage.style.setProperty('--ipad-x', `${Math.round(48 * eased)}px`);
      stage.style.setProperty('--ipad-y', `${Math.round(18 - 44 * eased)}px`);
      stage.style.setProperty('--caption-opacity', clamp((progress - 0.42) / 0.28, 0, 1).toFixed(3));
    };

    const requestRender = () => {
      if (frame) return;
      frame = window.requestAnimationFrame(render);
    };

    window.addEventListener('scroll', requestRender, { passive: true });
    window.addEventListener('resize', requestRender);
    listenForMotionChanges(requestRender);
    render();
  }

})();
