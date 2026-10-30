// The little bridge the website gets: window.yapperDesktop. Nothing else from Node reaches the page.
const { contextBridge, ipcRenderer } = require('electron');

/** The red circle with the unread count for the Windows taskbar icon (the main process has no canvas to draw it). */
function badgePng(count) {
  try {
    const c = document.createElement('canvas');
    c.width = 32; c.height = 32;
    const g = c.getContext('2d');
    if (!g) return null;
    g.fillStyle = '#f23f43';
    g.beginPath(); g.arc(16, 16, 15, 0, Math.PI * 2); g.fill();
    g.fillStyle = '#fff';
    const text = count > 99 ? '99+' : String(count);
    g.font = `bold ${text.length > 2 ? 14 : text.length > 1 ? 18 : 20}px system-ui, "Segoe UI", sans-serif`;
    g.textAlign = 'center'; g.textBaseline = 'middle';
    g.fillText(text, 16, 17);
    return c.toDataURL('image/png');
  } catch { return null; }
}

contextBridge.exposeInMainWorld('yapperDesktop', {
  version: (() => { try { return String(ipcRenderer.sendSync('yapper:version') || ''); } catch { return ''; } })(),
  platform: process.platform,
  /** Unread count for the taskbar/dock. */
  setBadge: (count) => { const n = Number(count) || 0; ipcRenderer.send('yapper:badge', n, n > 0 ? badgePng(n) : null); },
  /** A native notification; `url` is the in-app path to open on click (e.g. /?channel=...). */
  notify: (n) => ipcRenderer.send('yapper:notify', { title: n?.title, body: n?.body, url: n?.url }),
  /** The game (or app) the desktop app sees running, or null, and since when (ISO). Called whenever it changes. */
  onActivity: (cb) => { ipcRenderer.on('yapper:activity', (_e, name, since) => cb(name ?? null, typeof since === 'string' ? since : undefined)); ipcRenderer.send('yapper:activity:ask'); },
  /** This app has its own screen picker (screenSources + pickScreenSource). Not on Linux Wayland, where every
   *  listing pops the system's own share dialog, so the site keeps the plain flow there. */
  screenPicker: !(process.platform === 'linux' && process.env.XDG_SESSION_TYPE === 'wayland'),
  /** Screens and app windows to share: [{ id, name, kind: 'screen' | 'window', thumb, icon }] (images as data URLs). */
  screenSources: () => ipcRenderer.invoke('yapper:screen-sources'),
  /** Remember what to share; the next getDisplayMedia (within 30 s) uses it instead of the whole screen. */
  pickScreenSource: (id) => ipcRenderer.invoke('yapper:screen-pick', String(id ?? '')),
  /** Called once a new version has downloaded (with its version), so the site can offer a restart. */
  onUpdateReady: (cb) => { ipcRenderer.on('yapper:update-ready', (_e, v) => cb(String(v ?? ''))); ipcRenderer.send('yapper:update-ask'); },
  /** Quit, install the downloaded update and start again. */
  installUpdate: () => ipcRenderer.invoke('yapper:update-install'),

  // ---- 1.1.0: for gamers ----
  /** Keys that should work while another window (a game) has focus: { ptt: 'Backquote' | 'Mouse3' | null, mute: 'Mod+Shift+M' | null,
   *  deafen: ... | null }. Null for everything turns the hook off. Resolves { ptt, keys }: which of them really got hooked. */
  setHotkeys: (h) => ipcRenderer.invoke('yapper:hotkeys', { ptt: h?.ptt ?? null, mute: h?.mute ?? null, deafen: h?.deafen ?? null }),
  /** Push to talk key held (true) / let go (false), from anywhere on the computer. */
  onPtt: (cb) => { ipcRenderer.on('yapper:ptt', (_e, down) => cb(!!down)); },
  /** A mute / deafen shortcut pressed while another window had focus: 'toggleMute' | 'toggleDeafen'. */
  onHotkey: (cb) => { ipcRenderer.on('yapper:hotkey', (_e, action) => cb(String(action ?? ''))); },
  /** Seconds since the last mouse or key anywhere on the computer, every 15 s. */
  onSystemIdle: (cb) => { ipcRenderer.on('yapper:idle', (_e, s) => cb(Number(s) || 0)); },
  /** Settings -> Desktop app. */
  getSettings: () => ipcRenderer.invoke('yapper:settings-get'),
  setSettings: (p) => ipcRenderer.invoke('yapper:settings-set', p && typeof p === 'object' ? p : {}),
  /** Running programs with a window, for "Add a game": [{ proc, title }]. */
  listPrograms: () => ipcRenderer.invoke('yapper:programs'),
});
