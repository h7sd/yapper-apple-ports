/* SPDX-License-Identifier: GPL-3.0-or-later
 * Original Yapper 1.1.0 desktop API, adapted to the Android sandbox.
 * The native listener independently validates exact origin and main frame.
 */
(() => {
  'use strict';
  const hosts = ['www.yapper.website', 'yapper.website', 'www.yapin.gg', 'yapin.gg'];
  try {
    const url = new URL(location.href);
    if (window.top !== window.self || url.protocol !== 'https:' || url.username || url.password ||
        (url.port && url.port !== '443') || !hosts.includes(url.hostname)) return;
  } catch { return; }
  if (Object.hasOwn(window, 'yapperAndroid')) return;
  const handler = window.yapperNative;
  const nativeAvailable = typeof handler?.postMessage === 'function';
  const waiting = new Map();
  let sequence = 0;
  const listeners = new Set();
  const capabilities = Object.freeze({
    nativeBridge: nativeAvailable, badges: false, localNotifications: nativeAvailable,
    persistentSettings: nativeAvailable, notificationPermissionRequired: true,
    backgroundPush: false, screenPicker: false, screenCapture: false,
    systemAudioCapture: false, globalHotkeys: false, activityDetection: false,
    runningPrograms: false, systemIdle: false, automaticUpdates: false,
  });
  if (nativeAvailable) handler.onmessage = event => {
    try {
      const message = JSON.parse(event.data);
      const pending = waiting.get(message.id);
      if (!pending) return;
      clearTimeout(pending.timeout); waiting.delete(message.id); pending.resolve(message.result);
    } catch { /* Invalid responses cannot resolve arbitrary pending requests. */ }
  };
  function invoke(method, args, fallback) {
    if (!nativeAvailable) return Promise.resolve(fallback);
    return new Promise(resolve => {
      const id = String(++sequence);
      const timeout = setTimeout(() => { waiting.delete(id); resolve(fallback); }, 120000);
      waiting.set(id, { resolve, timeout });
      try { handler.postMessage(JSON.stringify({ id, method, args })); }
      catch { clearTimeout(timeout); waiting.delete(id); resolve(fallback); }
    });
  }
  const defaults = () => ({ platform: 'android', nativeNotifications: false, closeToTray: false,
    openAtLogin: false, startMinimized: false, activity: false, customGames: [], hwAccel: true,
    hwAccelNow: true, capabilities });
  function notificationPath(value) {
    if (typeof value !== 'string' || value.length > 8192) return '/';
    try {
      const url = new URL(value, location.href);
      if (url.origin !== location.origin || url.username || url.password || url.pathname.startsWith('//')) return '/';
      return url.pathname + url.search + url.hash;
    } catch { return '/'; }
  }
  function call(callback, ...args) { try { callback(...args); } catch {} }
  const desktop = Object.freeze({
    version: '1.1.0', platform: 'android',
    setBadge: async () => false,
    notify(value) {
      const notification = value && typeof value === 'object' ? value : {};
      return invoke('notify', { title: typeof notification.title === 'string' ? notification.title.slice(0, 180) : 'Yapper',
        body: typeof notification.body === 'string' ? notification.body.slice(0, 2000) : '',
        url: notificationPath(notification.url) }, false);
    },
    onActivity(callback) {
      let active = true;
      if (typeof callback === 'function') Promise.resolve().then(() => { if (active) call(callback, null, undefined); });
      return () => { active = false; };
    },
    screenPicker: false, screenSources: async () => [], pickScreenSource: async () => false,
    onUpdateReady: () => () => {}, installUpdate: async () => false,
    setHotkeys: async () => ({ ptt: false, keys: false }), onPtt: () => () => {},
    onHotkey: () => () => {}, onSystemIdle: () => () => {},
    async getSettings() {
      const settings = await invoke('getSettings', {}, null);
      return { ...defaults(), nativeNotifications: nativeAvailable && settings?.nativeNotifications === true };
    },
    setSettings(patch) {
      if (!patch || typeof patch !== 'object' || Array.isArray(patch) || typeof patch.nativeNotifications !== 'boolean') return Promise.resolve(false);
      return invoke('setSettings', { nativeNotifications: patch.nativeNotifications }, false);
    },
    listPrograms: async () => [],
  });
  Object.defineProperty(window, 'yapperDesktop', { value: desktop, enumerable: true });
  Object.defineProperty(window, 'yapperAndroid', { value: Object.freeze({ version: '1.1.0', platform: 'android', capabilities,
    getSettings: desktop.getSettings, setSettings: desktop.setSettings,
    openSettings: () => invoke('openSettings', {}, false),
    onLifecycle(callback) { if (typeof callback !== 'function') return () => {}; listeners.add(callback); return () => listeners.delete(callback); },
  }), enumerable: true });
  Object.defineProperty(window, '__yapperNativeEvent', { value(name, payload) {
    if (name !== 'lifecycle' || !payload || !['active', 'inactive', 'background'].includes(payload.state)) return false;
    const detail = Object.freeze({ state: payload.state });
    for (const callback of [...listeners]) call(callback, detail);
    document.dispatchEvent(new CustomEvent('yapper:android:lifecycle', { detail })); return true;
  } });
  window.addEventListener('pagehide', () => {
    for (const pending of waiting.values()) { clearTimeout(pending.timeout); pending.resolve(false); }
    waiting.clear(); listeners.clear();
  }, { once: true });
})();
