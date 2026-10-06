// Reads the subtitle currently on screen and forwards it to the background
// worker, which relays it to the FloatSubs Mac app. Also pauses the video while
// the mouse is over the floating window, like LR does for its own subtitles.
// Source priority: Language Reactor's overlay, then YouTube's own captions.

(() => {
  const POLL_MS = 100;
  // Chinese/Japanese don't separate words with spaces (Korean does, so it's excluded).
  const CJK = '[\\u3000-\\u30ff\\u3400-\\u9fff\\uff00-\\uffef]';
  const cjkGap = new RegExp(`(?<=${CJK})\\s+(?=${CJK})`, 'g');

  const tidy = (s) => (s || '').replace(/\s+/g, ' ').trim().replace(cjkGap, '');
  const rendered = (el) => el.getClientRects().length > 0;

  // Text of an element minus LR's hidden tooltips ("...", "Save phrase") and
  // transliteration (pinyin/romaji) helpers.
  function cleanText(el) {
    const copy = el.cloneNode(true);
    copy.querySelectorAll('.tt, .translit, .lln-star-and-menu-buttons').forEach((n) => n.remove());
    return tidy(copy.textContent);
  }

  // Language Reactor: #lln-subs-content > .lln-subs-wrap > (.lln-subs = original,
  // #lln-translations .translationText = machine and/or human translation).
  function readLanguageReactor() {
    const root = document.getElementById('lln-subs-content');
    if (!root || !rendered(root)) return null;
    const originals = [...root.querySelectorAll('.lln-subs')]
      .filter((el) => !el.querySelector('.lln-sub-message'))
      .map(cleanText)
      .filter(Boolean);
    const translations = [...root.querySelectorAll('.lln-whole-title-translation .translationText')]
      .filter((el) => !el.querySelector('.lln-sub-message'))
      .map(cleanText)
      .filter((t) => t && t !== '-');
    return { orig: originals.join('\n'), trans: [...new Set(translations)] };
  }

  function readYouTube() {
    const container = document.querySelector('.ytp-caption-window-container');
    if (!container) return null;
    const lines = [...container.querySelectorAll('.caption-visual-line')].map((l) => tidy(l.textContent));
    return { orig: lines.filter(Boolean).join(' '), trans: [] };
  }

  const onVideoPage = () => /^\/(watch|shorts|live|embed)\b/.test(location.pathname);

  let lastRaw = null;
  let lastSent = null;

  // The extension was reloaded or removed; this copy of the script is orphaned.
  function stop() {
    clearInterval(timer);
    document.removeEventListener('timeupdate', tick, true);
  }

  function send(message) {
    const key = JSON.stringify(message);
    if (key === lastSent) return;
    lastSent = key;
    console.debug('[FloatSubs]', message);
    try {
      chrome.runtime.sendMessage(message).catch(() => {});
    } catch {
      stop(); // extension context invalidated
    }
  }

  function tick() {
    if (!chrome.runtime?.id) {
      stop();
      return;
    }
    // Cheap change check first; only re-parse when something on screen changed.
    const lr = document.getElementById('lln-subs-content');
    const yt = document.querySelector('.ytp-caption-window-container');
    const raw = `${location.pathname}|${lr ? lr.textContent : '-'}|${yt ? yt.textContent : '-'}`;
    if (raw === lastRaw) return;
    lastRaw = raw;

    const sub = readLanguageReactor() ?? readYouTube();
    if (sub && (sub.orig || sub.trans.length)) {
      send({ type: 'sub', ...sub });
    } else if (!onVideoPage()) {
      send({ type: 'clear' });
    } else {
      send({ type: 'sub', orig: '', trans: [] });
    }
  }

  const timer = setInterval(tick, POLL_MS);
  // Timers slow to ~1/s in a hidden, silent tab; video time updates keep coming.
  document.addEventListener('timeupdate', tick, true);

  // Hovering the floating window pauses; leaving resumes, but only a video we paused.
  let pausedByHover = null;
  chrome.runtime.onMessage.addListener((msg) => {
    if (msg.type !== 'hover') return;
    if (msg.on) {
      const video = [...document.querySelectorAll('video')].find((v) => !v.paused);
      if (video) {
        video.pause();
        pausedByHover = video;
      }
    } else if (pausedByHover) {
      if (pausedByHover.paused) pausedByHover.play().catch(() => {});
      pausedByHover = null;
    }
  });
})();
