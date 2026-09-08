// Each scene has its own transaction. A blocked theft never turns into an
// approved payment. Without JavaScript, all scenes show their final frame.
const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
document.querySelectorAll('.signing-story').forEach(story => {
  const controls = story.querySelector('fieldset');
  const scenes = [...story.querySelectorAll('.signing-scene')];
  const replay = story.querySelector('.signing-replay');
  let scene;
  let timers = [];
  const stop = () => {
    timers.forEach(clearTimeout);
    timers = [];
  };
  const play = () => {
    stop();
    observer.disconnect();
    if (reducedMotion.matches) return;
    scene.classList.remove('is-playing');
    scene.dataset.step = '0';
    // Reset without animating backwards before starting a new playback.
    void scene.offsetWidth;
    scene.classList.add('is-playing');
    [800, 2100, 3400].forEach((delay, index) => {
      timers.push(setTimeout(() => { scene.dataset.step = String(index + 1); }, delay));
    });
  };
  const observer = new IntersectionObserver(entries => {
    if (entries.some(entry => entry.target === scene && entry.isIntersecting)) {
      observer.disconnect();
      play();
    }
  }, { threshold: 0.6 });
  const selectScene = (animate = false) => {
    stop();
    observer.disconnect();
    const selected = controls.querySelector('input:checked').value;
    scenes.forEach(panel => {
      panel.hidden = panel.dataset.scene !== selected;
      panel.classList.remove('is-playing');
    });
    scene = scenes.find(panel => !panel.hidden);
    replay.hidden = reducedMotion.matches;
    scene.dataset.step = reducedMotion.matches ? '3' : '0';
    if (!reducedMotion.matches) {
      if (animate) play();
      else observer.observe(scene);
    }
  };
  story.classList.add('is-interactive');
  controls.hidden = false;
  controls.addEventListener('change', () => selectScene(true));
  replay.addEventListener('click', play);
  reducedMotion.addEventListener('change', () => selectScene());
  selectScene();
});

// Keep mobile browsing short; the same content stays one tap away.
const compact = window.matchMedia('(max-width: 40rem)');
const journeys = [...document.querySelectorAll('details.journey')];
const revealLinkedJourney = () => {
  const linked = document.getElementById(window.location.hash.slice(1));
  if (journeys.includes(linked)) linked.open = true;
};
const arrangeJourneys = () => {
  journeys.forEach(journey => { journey.open = !compact.matches; });
  revealLinkedJourney();
};
compact.addEventListener('change', arrangeJourneys);
window.addEventListener('hashchange', revealLinkedJourney);
arrangeJourneys();
