// Runs in the page's own JavaScript world, before YouTube and Language Reactor.
// LR redraws its subtitles from a requestAnimationFrame loop, and Chrome stops
// running animation frames whenever the page is hidden (another tab in front,
// window covered or minimized), so the subtitles freeze. While the page is
// hidden, drive frame callbacks from a timer instead so they keep updating.

(() => {
  const HIDDEN_FRAME_MS = 100;
  const nativeRequest = window.requestAnimationFrame.bind(window);
  const nativeCancel = window.cancelAnimationFrame.bind(window);
  const jobs = new Map(); // id -> { callback, frame, timer }
  let lastId = 0;

  function run(id, time) {
    const job = jobs.get(id);
    if (!job) return;
    jobs.delete(id);
    job.callback(time);
  }

  function schedule(id, job) {
    if (document.hidden) {
      job.frame = null;
      job.timer = setTimeout(() => run(id, performance.now()), HIDDEN_FRAME_MS);
    } else {
      job.timer = null;
      job.frame = nativeRequest((time) => run(id, time));
    }
  }

  function unschedule(job) {
    if (job.frame !== null) nativeCancel(job.frame);
    if (job.timer !== null) clearTimeout(job.timer);
  }

  window.requestAnimationFrame = function requestAnimationFrame(callback) {
    const id = ++lastId;
    const job = { callback, frame: null, timer: null };
    jobs.set(id, job);
    schedule(id, job);
    return id;
  };

  window.cancelAnimationFrame = function cancelAnimationFrame(id) {
    const job = jobs.get(id);
    if (!job) return;
    jobs.delete(id);
    unschedule(job);
  };

  // Callbacks already waiting when visibility flips would otherwise stall
  // (a hidden page never fires them), so move them to the other mechanism.
  document.addEventListener('visibilitychange', () => {
    for (const [id, job] of jobs) {
      unschedule(job);
      schedule(id, job);
    }
  });

  // In a hidden page that is silent (muted video, quiet stretch) Chrome only fires
  // timers about once a second, but the video still reports its time ~4x a second.
  document.addEventListener(
    'timeupdate',
    () => {
      if (!document.hidden) return;
      const due = [...jobs].filter(([, job]) => job.timer !== null); // callbacks may queue new frames
      for (const [id, job] of due) {
        clearTimeout(job.timer);
        run(id, performance.now());
      }
    },
    true,
  );
})();
