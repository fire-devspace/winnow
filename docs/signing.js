// Play each explanation once when it comes into view. No motion is needed
// to read it: the HTML starts with the completed diagram.
const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
document.querySelectorAll('.signing-demo').forEach(demo => {
  const replay = demo.querySelector('button');
  let timers = [];
  const stop = () => {
    timers.forEach(clearTimeout);
    timers = [];
  };
  const play = () => {
    stop();
    if (reducedMotion.matches) return;
    demo.classList.remove('is-playing');
    demo.dataset.step = '0';
    // Reset without animating backwards before starting a new playback.
    void demo.offsetWidth;
    demo.classList.add('is-playing');
    [700, 1900, 2900].forEach((delay, index) => {
      timers.push(setTimeout(() => { demo.dataset.step = String(index + 1); }, delay));
    });
  };
  const observer = new IntersectionObserver(entries => {
    if (entries.some(entry => entry.isIntersecting)) {
      observer.disconnect();
      play();
    }
  }, { threshold: 0.6 });
  const setMotion = () => {
    stop();
    demo.classList.remove('is-playing');
    replay.hidden = reducedMotion.matches;
    demo.dataset.step = reducedMotion.matches ? '3' : '0';
    observer.disconnect();
    if (!reducedMotion.matches) observer.observe(demo);
  };
  replay.addEventListener('click', play);
  reducedMotion.addEventListener('change', setMotion);
  setMotion();
});
