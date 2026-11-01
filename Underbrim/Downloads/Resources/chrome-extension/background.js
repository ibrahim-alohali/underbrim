// Underbrim: Chrome downloads relay. Sends a small summary of each download to the app's native
// host; nothing else is read (no history, tabs or cookies). onChanged doesn't report byte progress,
// so active downloads are polled once a second; with none active the native port is closed and
// Chrome can suspend this worker.

const HOST = "io.github.ibrahim_alohali.underbrim";
let port = null;
let timer = null;

function connect() {
  if (port) return port;
  try {
    port = chrome.runtime.connectNative(HOST);
    port.onDisconnect.addListener(() => {
      port = null;
      stopPolling();
    });
    port.postMessage({ type: "hello", version: 1 });
  } catch (error) {
    port = null;
  }
  return port;
}

function summarize(item) {
  return {
    type: "download",
    id: item.id,
    state: item.state,
    paused: item.paused,
    danger: item.danger,
    error: item.error || null,
    filename: item.filename,
    bytesReceived: item.bytesReceived,
    totalBytes: item.totalBytes,
    incognito: item.incognito,
  };
}

function send(item) {
  if (!item || item.incognito) return;
  const p = connect();
  if (p) p.postMessage(summarize(item));
}

async function pollActive() {
  const items = await chrome.downloads.search({ state: "in_progress" });
  items.forEach(send);
  if (items.length === 0) {
    stopPolling();
    if (port) {
      port.disconnect();
      port = null;
    }
  }
}

function startPolling() {
  if (!timer) timer = setInterval(pollActive, 1000);
}

function stopPolling() {
  if (timer) {
    clearInterval(timer);
    timer = null;
  }
}

chrome.downloads.onCreated.addListener((item) => {
  send(item);
  startPolling();
});

chrome.downloads.onChanged.addListener(async (delta) => {
  const [item] = await chrome.downloads.search({ id: delta.id });
  send(item);
  if (item && item.state === "in_progress") startPolling();
});

chrome.runtime.onStartup.addListener(pollActive);
chrome.runtime.onInstalled.addListener(() => {
  connect();
  pollActive();
});
