/* Yapper's original 1.1.0 preload API, adapted to the iOS sandbox.
 * Inject at document start, in the main frame and page content world only.
 * Swift independently validates each message's frame and security origin.
 */
(() => {
  'use strict';

  const trustedHosts = new Set([
    'www.yapper.website', 'yapper.website',
    'www.yapin.gg', 'yapin.gg',
    'rt.yapper.website', 'lk.yapper.website',
  ]);
  try {
    if (window.top !== window.self || window.location.protocol !== 'https:' ||
        !trustedHosts.has(window.location.hostname.toLowerCase()) ||
        (window.location.port !== '' && window.location.port !== '443')) return;
  } catch { return; }
  if (Object.prototype.hasOwnProperty.call(window, 'yapperIOS')) return;

  const nativeHandler = window.webkit?.messageHandlers?.yapperNative;
  const nativeAvailable = typeof nativeHandler?.postMessage === 'function';
  const lifecycleListeners = new Set();
  const capabilities = Object.freeze({
    nativeBridge: nativeAvailable,
    badges: nativeAvailable,
    localNotifications: nativeAvailable,
    persistentSettings: nativeAvailable,
    notificationPermissionRequired: true,
    backgroundPush: false,
    screenPicker: false,
    screenCapture: false,
    systemAudioCapture: false,
    globalHotkeys: false,
    activityDetection: false,
    runningPrograms: false,
    systemIdle: false,
    automaticUpdates: false,
  });

  // Every invocation consumes native rejections, including ignored calls from
  // the desktop preload's fire-and-forget methods. A denied request never
  // becomes a successful permission grant or an unhandled Promise rejection.
  async function invoke(method, args, fallback) {
    if (!nativeAvailable) return fallback;
    try { return await nativeHandler.postMessage({ method, args }); }
    catch { return fallback; }
  }

  function defaultSettings() {
    return {
      platform: 'ios',
      nativeNotifications: false,
      closeToTray: false,
      openAtLogin: false,
      startMinimized: false,
      activity: false,
      customGames: [],
      hwAccel: false,
      hwAccelNow: true,
      capabilities,
    };
  }

  function nativeNotificationURL(value) {
    if (typeof value !== 'string' || value.length > 8192) return '/';
    try {
      const url = new URL(value, window.location.href);
      if (url.origin !== window.location.origin || url.username || url.password ||
          url.pathname.startsWith('//')) return '/';
      return url.pathname + url.search + url.hash;
    } catch { return '/'; }
  }

  function callListener(callback, ...args) {
    try { callback(...args); } catch { /* A page callback must not break the bridge. */ }
  }

  const desktopCompatibility = Object.freeze({
    version: '1.1.0',
    platform: 'ios',
    setBadge(count) {
      const number = typeof count === 'number' ? count : Number(typeof count === 'string' ? count : NaN);
      const normalized = Number.isFinite(number) ? Math.min(9999, Math.max(0, Math.floor(number))) : 0;
      return invoke('setBadge', { count: normalized }, false);
    },
    notify(notification) {
      const value = notification && typeof notification === 'object' ? notification : {};
      return invoke('notify', {
        title: typeof value.title === 'string' ? value.title.slice(0, 180) : 'Yapper',
        body: typeof value.body === 'string' ? value.body.slice(0, 2000) : '',
        url: nativeNotificationURL(value.url),
      }, false);
    },
    onActivity(callback) {
      // iOS cannot enumerate other apps. Clear any inherited desktop activity
      // once, without fabricating a game or a system-wide activity stream.
      let active = true;
      if (typeof callback === 'function') {
        Promise.resolve().then(() => { if (active) callListener(callback, null, undefined); });
      }
      return () => { active = false; };
    },
    screenPicker: false,
    screenSources: async () => [],
    pickScreenSource: async () => false,
    onUpdateReady: () => () => {},
    installUpdate: async () => false,
    setHotkeys: async () => ({ ptt: false, keys: false }),
    onPtt: () => () => {},
    onHotkey: () => () => {},
    onSystemIdle: () => () => {},
    async getSettings() {
      const settings = await invoke('getSettings', {}, null);
      return {
        ...defaultSettings(),
        nativeNotifications: nativeAvailable && settings?.nativeNotifications === true,
      };
    },
    setSettings(patch) {
      // Only this iOS setting exists. Desktop login/tray/game/hotkey settings
      // must never appear to work on iOS. Consent is requested by native code
      // only in response to an explicit nativeNotifications opt-in.
      if (!patch || typeof patch !== 'object' || Array.isArray(patch) ||
          typeof patch.nativeNotifications !== 'boolean') return Promise.resolve(false);
      return invoke('setSettings', { nativeNotifications: patch.nativeNotifications }, false);
    },
    listPrograms: async () => [],
  });

  const ios = Object.freeze({
    version: '1.1.0',
    platform: 'ios',
    capabilities,
    getSettings: desktopCompatibility.getSettings,
    setSettings: desktopCompatibility.setSettings,
    onLifecycle(callback) {
      if (typeof callback !== 'function') return () => {};
      lifecycleListeners.add(callback);
      return () => lifecycleListeners.delete(callback);
    },
  });

  Object.defineProperty(window, 'yapperDesktop', { value: desktopCompatibility, enumerable: true });
  Object.defineProperty(window, 'yapperIOS', { value: ios, enumerable: true });
  Object.defineProperty(window, '__yapperNativeEvent', {
    value(name, payload) {
      if (name !== 'lifecycle' || !payload || typeof payload !== 'object' ||
          !['active', 'inactive', 'background'].includes(payload.state)) return false;
      const detail = Object.freeze({ state: payload.state });
      for (const callback of [...lifecycleListeners]) callListener(callback, detail);
      try { document.dispatchEvent(new CustomEvent('yapper:ios:lifecycle', { detail })); }
      catch { /* Dispatch is optional while a document is being torn down. */ }
      return true;
    },
  });
})();
