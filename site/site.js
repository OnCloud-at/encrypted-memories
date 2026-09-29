(() => {
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

  if (stage) {
    const layers = ['--mac-y', '--ipad-y', '--phone-y'];

    const render = () => {
      frame = 0;

      if (reducedMotion.matches) {
        layers.forEach((layer) => stage.style.setProperty(layer, '0px'));
        return;
      }

      // Whole-pixel translation only: fractional movement makes the screenshot text shimmer.
      const rect = stage.getBoundingClientRect();
      const progress = clamp((window.innerHeight - rect.top) / (window.innerHeight + rect.height), 0, 1);
      const drift = (0.5 - progress) * 2 * clamp(rect.width * 0.02, 6, 22);

      stage.style.setProperty('--mac-y', `${Math.round(-0.4 * drift)}px`);
      stage.style.setProperty('--ipad-y', `${Math.round(0.7 * drift)}px`);
      stage.style.setProperty('--phone-y', `${Math.round(drift)}px`);
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
