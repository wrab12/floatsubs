// Relays subtitles from YouTube tabs to the FloatSubs Mac app over native
// messaging, and the app's hover events back to the playing tab. Chrome starts
// the app on the first non-empty subtitle and the app exits when this port
// closes. Clicking the toolbar icon turns the feature on/off.

const HOST = 'io.github.wrab12.floatsubs';
const IDLE_CLOSE_MS = 60_000; // close the app a minute after the last video goes away

let port = null;
let retryAt = 0;
let activeTab = null; // tab whose subtitles are on screen
let lastSub = null;
let idleTimer = null;
let enabled = true;

const ready = chrome.storage.local.get({ enabled: true }).then((v) => {
  enabled = v.enabled;
  updateBadge();
});

function updateBadge(error) {
  chrome.action.setBadgeBackgroundColor({ color: error ? '#d93025' : '#5f6368' });
  chrome.action.setBadgeText({ text: error ? '!' : enabled ? '' : 'OFF' });
  chrome.action.setTitle({
    title: error
      ? `悬浮字幕：无法启动 Mac 小程序（${error}）`
      : enabled
        ? '悬浮字幕：已开启（点击关闭）'
        : '悬浮字幕：已关闭（点击开启）',
  });
}

function connect() {
  if (port) return port;
  if (Date.now() < retryAt) return null;
  port = chrome.runtime.connectNative(HOST);
  port.onMessage.addListener((msg) => {
    if (msg.type === 'hello') updateBadge();
    if (msg.type === 'quit') setEnabled(false);
    if (msg.type === 'hover' && activeTab !== null) chrome.tabs.sendMessage(activeTab, msg).catch(() => {});
  });
  port.onDisconnect.addListener(() => {
    const error = chrome.runtime.lastError?.message;
    port = null;
    if (error) {
      console.warn('[FloatSubs] native host error:', error);
      retryAt = Date.now() + 5000;
      updateBadge(error);
    }
  });
  return port;
}

function disconnect() {
  if (port) port.disconnect();
  port = null;
}

function post(msg, { launch }) {
  const p = launch ? connect() : port;
  if (!p) return;
  try {
    p.postMessage(msg);
  } catch {
    port = null;
  }
}

async function setEnabled(value) {
  enabled = value;
  await chrome.storage.local.set({ enabled });
  updateBadge();
  if (!enabled) disconnect();
  else if (lastSub) post(lastSub, { launch: true });
}

function goIdle() {
  activeTab = null;
  lastSub = null;
  post({ type: 'clear' }, { launch: false });
  clearTimeout(idleTimer);
  idleTimer = setTimeout(disconnect, IDLE_CLOSE_MS);
}

chrome.runtime.onMessage.addListener((msg, sender) => {
  const tab = sender.tab?.id;
  ready.then(() => {
    if (msg.type === 'sub') {
      const hasText = Boolean(msg.orig || msg.trans?.length);
      if (hasText) activeTab = tab;
      else if (tab !== activeTab) return; // an idle tab shouldn't blank the playing one
      clearTimeout(idleTimer);
      lastSub = msg;
      if (enabled) post(msg, { launch: hasText });
    } else if (msg.type === 'clear' && tab === activeTab) {
      goIdle();
    }
  });
});

chrome.tabs.onRemoved.addListener((tabId) => {
  if (tabId === activeTab) goIdle();
});

chrome.action.onClicked.addListener(() => {
  ready.then(() => setEnabled(!enabled));
});
