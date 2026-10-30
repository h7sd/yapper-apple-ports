// Yapper desktop: a window around www.yapper.website with the things a browser tab can't do well:
// a tray icon, "start minimised", notifications that open the right chat, screen sharing without
// the browser's picker, yapper:// links, and updates that install themselves (GitHub releases).
const { app, BrowserWindow, Menu, Tray, nativeImage, shell, session, desktopCapturer, ipcMain, Notification, powerMonitor, systemPreferences } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const { autoUpdater } = require('electron-updater');
const { execFile } = require('node:child_process');
const { games: GAMES, tools: TOOLS } = require('./games');
const { listMacProcesses } = require('./mac-processes');
const yappercord = require('./yappercord');
const IS_MAC = process.platform === 'darwin';

const SITE = 'https://www.yapper.website';
const ALLOWED = new Set(['www.yapin.gg', 'yapin.gg', 'www.yapper.website', 'yapper.website', 'rt.yapper.website', 'lk.yapper.website']);
const ICON = path.join(__dirname, 'build', 'icon.png');

// One copy of the app at a time: a second launch (or a yapper:// link) goes to the running one.
if (!app.requestSingleInstanceLock()) { app.quit(); }

// Settings the site can change (Settings -> Desktop app), kept in settings.json next to zoom.json.
const DEFAULTS = {
  closeToTray: true,     // closing the window keeps Yapin' in the tray (off: closing quits)
  startMinimized: false, // with "start with Windows": start in the tray
  hwAccel: true,         // graphics card drawing (off helps some PCs with black screens or stutter; needs a restart)
  activity: true,        // "Playing X"
  customGames: [],       // [{ proc: 'game.exe', name: 'Game' }] added from the running programs
  trayNoticeShown: false,
};
const SETTINGS_FILE = () => path.join(app.getPath('userData'), 'settings.json');
let settings = { ...DEFAULTS };
try { settings = { ...DEFAULTS, ...JSON.parse(fs.readFileSync(SETTINGS_FILE(), 'utf8')) }; } catch { /* first run */ }
function saveSettings(patch) {
  settings = { ...settings, ...patch };
  try { fs.writeFileSync(SETTINGS_FILE(), JSON.stringify(settings)); } catch { /* read-only profile: still works this run */ }
}
// Has to happen before the app is ready, so it's read from the file, not asked for later. What this run started
// with is remembered, so Settings can say "quit and open again" until it really changed.
const HW_AT_START = settings.hwAccel !== false;
if (!HW_AT_START) app.disableHardwareAcceleration();

let win = null;
let tray = null;
let quitting = false;
let updateReady = null; // version string once a new version has downloaded
let pendingDeepLink = null;

function openDeepLink(url) {
  // yapper://invite/abc  ->  https://www.yapper.website/invite/abc
  if (typeof url !== 'string' || !url.startsWith('yapper://')) return;
  if (!win) { pendingDeepLink = url; return; }
  pendingDeepLink = null;
  const rest = url.slice('yapper://'.length).replace(/^\/+/, '');
  loadSite(siteUrl(rest));
  show();
}

function show() {
  // The window can be gone while the app still runs (a quit or update install that got stuck): opening Yapper
  // again then did nothing at all, the only fix was ending it in Task Manager. Make a new window instead.
  if (!win) {
    if (!app.isReady()) return;
    quitting = false;
    createWindow();
    win?.once('ready-to-show', () => { win?.show(); win?.focus(); });
    return;
  }
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
}

// Never an endless blank window: if the site fails to load (offline, DNS, proxy, certificate, antivirus),
// the page crashes, hangs, or simply hasn't shown up after 20 s, show our own little screen with Retry
// and a link to open Yapper in the browser. It retries by itself when the connection comes back.
const LOAD_TIMEOUT = 20_000;
let loadTimer = null;
let lastUrl = SITE;
let errorPage = false;
// The error screen is a page of its own in the window's history. After a slow start (it shows after 20 s) and a
// Retry, the mouse's back button went right back to it: "taking too long to load" out of nowhere, and only the
// forward button got you out. Once the site is back up, that history is wiped.
let errorInHistory = false;
let everShown = false;
const startHidden = process.argv.includes('--hidden') || (() => {
  try { return IS_MAC && settings.startMinimized && app.getLoginItemSettings().wasOpenedAtLogin; }
  catch { return false; }
})();

// Zoom: Ctrl + / Ctrl - / Ctrl 0 and Ctrl + mouse wheel, like a browser (the app has no menu, so Chromium's own
// shortcuts were gone). Kept in zoom.json so it's the same next time.
const ZOOM_FILE = () => path.join(app.getPath('userData'), 'zoom.json');
const ZOOM_MIN = 0.5;
const ZOOM_MAX = 2;
let zoom = 1;
try { zoom = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, Number(JSON.parse(fs.readFileSync(ZOOM_FILE(), 'utf8')).factor) || 1)); } catch { /* first run */ }
function setZoom(next) {
  zoom = Math.round(Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, next)) * 10) / 10;
  win?.webContents.setZoomFactor(zoom);
  try { fs.writeFileSync(ZOOM_FILE(), JSON.stringify({ factor: zoom })); } catch { /* read-only profile: still works this run */ }
}

function esc(t) {
  return String(t).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}

function errorHtml(title, detail, retryUrl) {
  return `<!doctype html><html><head><meta charset="utf-8"><title>Yapin’</title><style>
html,body{margin:0;height:100%;background:#141519;color:#e6e6ea;font:15px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
body{display:flex;align-items:center;justify-content:center;padding:24px;box-sizing:border-box;text-align:center}
.card{max-width:380px}h1{font-size:22px;margin:0 0 8px}p{margin:0 0 20px;color:#a3a6ad}
a.btn{display:inline-block;padding:10px 22px;border-radius:8px;background:#ff6b4a;color:#fff;font-weight:600;text-decoration:none}
a.btn:hover{background:#ff8264}.alt{display:block;margin-top:14px;color:#a3a6ad;font-size:13px}.alt a{color:#ff8264}
code{display:block;margin-top:22px;color:#6c6f77;font-size:12px}
</style></head><body><div class="card">
<h1>${esc(title)}</h1>
<p>Check your internet connection. A VPN, proxy or antivirus can also block Yapin’.</p>
<a class="btn" id="retry" href="${esc(retryUrl)}">Retry</a>
<span class="alt">Still stuck? <a href="${esc(SITE)}" target="_blank">Open Yapin’ in your browser</a></span>
${detail ? `<code>${esc(detail)}</code>` : ''}
</div><script>
var go=function(){location.href=document.getElementById('retry').href};
addEventListener('online',go);setTimeout(go,60000);
</script></body></html>`;
}

function showLoadError(title, detail) {
  if (!win || win.isDestroyed()) return;
  clearTimeout(loadTimer);
  loadTimer = null;
  errorPage = true;
  errorInHistory = true;
  const retry = lastUrl && ownUrl(lastUrl) ? lastUrl : SITE;
  win.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(errorHtml(title, detail, retry))}`).catch(() => undefined);
  // Pop up only on first start (not a "start minimised" one) or when it's already open, never out of the tray.
  if (win.isVisible() || (!startHidden && !everShown)) show();
}

/**
 * A path from a notification or a yapper:// link as an address on our own site, never another one. "@example.com"
 * glued onto the site address used to read as a login name in front of example.com (the window went there with the
 * desktop bridge attached), so the path is rebuilt from the site and the origin is checked.
 */
function siteUrl(p) {
  const rest = String(p ?? '').replace(/^[\\/\s]+/, '');
  try {
    const u = new URL(`/${rest}`, SITE);
    return u.origin === SITE ? u.href : SITE;
  } catch { return SITE; }
}

/** Every load of the site goes through here, so a failed one always ends on the error screen. */
function loadSite(url) {
  if (!win) return;
  // Whatever calls this, only our own pages load in this window (it carries the desktop bridge).
  try {
    const u = new URL(url);
    if (u.protocol !== 'https:' || !ALLOWED.has(u.hostname) || u.username || u.password) url = SITE;
  } catch { url = SITE; }
  lastUrl = url;
  win.loadURL(url).catch(() => undefined); // failures land in did-fail-load
}

function createWindow() {
  win = new BrowserWindow({
    width: 1200,
    height: 800,
    minWidth: 480,
    minHeight: 360,
    backgroundColor: '#141519',
    icon: ICON,
    autoHideMenuBar: true,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: true,
      // A minimised window got its timers slowed down, so the presence heartbeat came late and people showed offline.
      backgroundThrottling: false,
    },
  });
  win.once('ready-to-show', () => { if (!startHidden) win.show(); });
  win.on('show', () => { everShown = true; });

  const wc = win.webContents;
  wc.on('did-finish-load', () => {
    if (yappercord.readLayoutEnabled(path.join(app.getPath('userData'), 'appearance.json')) && yappercord.trustedPage(wc.getURL())) {
      try { wc.executeJavaScript(yappercord.appearanceSource()).catch(error => console.error('Profile layout failed to start:', error.message)); }
      catch (error) { console.error('Profile layout rejected:', error.message); }
    }
    if (yappercord.readEnabled(path.join(app.getPath('userData'), 'yappercord.json')) && yappercord.trustedPage(wc.getURL())) {
      try { wc.executeJavaScript(yappercord.bundleSource()).catch(error => console.error('YapperCord failed to start:', error.message)); }
      catch (error) { console.error('YapperCord bundle rejected:', error.message); }
    }
  });
  // Right-click in a text box: spelling suggestions, Add to dictionary, Cut / Copy / Paste. Spellcheck was on but
  // had no menu to show its answers in, and with no app menu there was no Paste to click either.
  wc.on('context-menu', (_e, params) => {
    // A stream, video or picture (not inside a text box) is the page's to handle: a selection left over from somewhere
    // else used to pop our Copy menu up over a stream tile instead of the site's own menu.
    if (!params.isEditable && params.mediaType && params.mediaType !== 'none') return;
    const items = [];
    if (params.misspelledWord) {
      for (const s of (params.dictionarySuggestions || []).slice(0, 5)) items.push({ label: s, click: () => wc.replaceMisspelling(s) });
      if (!params.dictionarySuggestions?.length) items.push({ label: 'No suggestions', enabled: false });
      items.push({ label: 'Add to dictionary', click: () => wc.session.addWordToSpellCheckerDictionary(params.misspelledWord) });
      items.push({ type: 'separator' });
    }
    if (params.isEditable) {
      items.push({ role: 'cut', enabled: params.editFlags.canCut }, { role: 'copy', enabled: params.editFlags.canCopy }, { role: 'paste', enabled: params.editFlags.canPaste });
      // A double-click on empty space selects nothing but whitespace: no Copy that copies a blank.
    } else if (params.selectionText?.trim()) items.push({ role: 'copy' });
    if (items.length) Menu.buildFromTemplate(items).popup();
  });
  // A fresh load of the site: start the 20 s clock. It stops once the page has its HTML (the site's own
  // start-up screen takes it from there and says so itself if it takes too long).
  wc.on('did-start-navigation', (d) => {
    if (!d.isMainFrame || d.isSameDocument || d.url.startsWith('data:')) return;
    lastUrl = d.url;
    errorPage = false;
    clearTimeout(loadTimer);
    loadTimer = setTimeout(() => showLoadError('Yapin’ is taking too long to load', 'Timed out after 20 s'), LOAD_TIMEOUT);
  });
  wc.on('zoom-changed', (_e, dir) => setZoom(zoom + (dir === 'in' ? 0.1 : -0.1))); // Ctrl + mouse wheel
  wc.on('dom-ready', () => {
    wc.setZoomFactor(zoom); // every load, the error screen too
    if (errorPage) return;
    clearTimeout(loadTimer);
    loadTimer = null;
    if (errorInHistory) {
      errorInHistory = false;
      try {
        if (wc.navigationHistory?.clear) wc.navigationHistory.clear();
        else wc.clearHistory?.();
      } catch { /* older Electron: nothing to clear with */ }
    }
    // ready-to-show can be skipped after a failed first try; make sure the window shows up.
    if (!startHidden && !everShown) win.show();
  });
  // A page brought back by the back / forward buttons can come out of the cache without a dom-ready: the load is done
  // all the same, so the 20 s clock must not run on and swap it for the error screen.
  wc.on('did-stop-loading', () => {
    if (errorPage) return;
    clearTimeout(loadTimer);
    loadTimer = null;
  });
  wc.on('did-fail-load', (_e, code, desc, url, isMainFrame) => {
    // -3 is "aborted": another navigation replaced this one, nothing went wrong.
    if (!isMainFrame || code === -3 || String(url).startsWith('data:')) return;
    showLoadError('Can\'t reach Yapin’', `${desc || 'Load failed'} (${code})`);
  });
  wc.on('render-process-gone', (_e, d) => {
    if (d.reason === 'clean-exit') return;
    showLoadError('Yapin’ stopped working', `Page ${d.reason}${d.exitCode ? ` (${d.exitCode})` : ''}`);
  });
  // Hung for 15 s straight (not just a busy moment): offer the way out instead of a frozen window.
  let hangTimer = null;
  win.on('unresponsive', () => {
    clearTimeout(hangTimer);
    hangTimer = setTimeout(() => showLoadError('Yapin’ stopped responding', 'Page unresponsive'), 15_000);
  });
  win.on('responsive', () => { clearTimeout(hangTimer); hangTimer = null; });
  // Full screen always has a way out: Esc leaves a stream / video full screen (it hid everything else and people
  // got stuck), and F11 toggles window full screen like any desktop app (the app has no menu, so there was no shortcut).
  win.webContents.on('before-input-event', (e, input) => {
    if (input.type !== 'keyDown') return;
    if ((input.control || input.meta) && !input.alt) {
      // '=' and '+' both zoom in (with or without Shift, and the numpad's), '-' out, '0' back to 100%.
      const k = input.key;
      const step = k === '=' || k === '+' || input.code === 'NumpadAdd' ? 0.1 : k === '-' || k === '_' || input.code === 'NumpadSubtract' ? -0.1 : 0;
      if (step) { e.preventDefault(); setZoom(zoom + step); return; }
      if (k === '0' || input.code === 'Numpad0') { e.preventDefault(); setZoom(1); return; }
    }
    if (input.key === 'F11') {
      e.preventDefault();
      win.setFullScreen(!win.isFullScreen());
    } else if (input.key === 'Escape' && win.isFullScreen()) {
      // Only a stream / video full screen: Esc in F11 full screen still closes popups like normal.
      win.webContents.executeJavaScript('!!document.fullscreenElement && (document.exitFullscreen().catch(() => {}), true)', true)
        .then((wasHtml) => { if (wasHtml && win.isFullScreen()) win.setFullScreen(false); })
        .catch(() => undefined);
    }
  });
  loadSite(SITE);

  // Links to other sites open in the normal browser; Yapper itself stays in the app.
  win.webContents.setWindowOpenHandler(({ url, frameName }) => {
    // The error screen's "Open Yapper in your browser" link.
    if (errorPage) { if (/^https:\/\//.test(url)) void shell.openExternal(url); return { action: 'deny' }; }
    // Import from Discord's "Connect Discord" sign-in (lib/servers.ts connectDiscordForImport): a small app window
    // that goes to discord.com and back to our callback, which hands the result to this window and closes itself.
    if (frameName === 'yapin-discord' && url === 'about:blank') {
      return { action: 'allow', overrideBrowserWindowOptions: { width: 520, height: 760, autoHideMenuBar: true, webPreferences: { nodeIntegration: false, contextIsolation: true, sandbox: true } } };
    }
    try {
      if (ownUrl(url)) { loadSite(url); return { action: 'deny' }; }
    } catch { /* not a URL */ }
    // Only web and mail links go to the system: anything else (file:, a custom scheme) could start a program.
    if (/^(https?|mailto):/i.test(url)) void shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('will-navigate', (e, url) => {
    if (!ownUrl(url)) { e.preventDefault(); if (/^https?:\/\//.test(url)) void shell.openExternal(url); }
  });
  // Same rule for redirects: a link to one of our pages that redirects somewhere else (the download links go on to
  // files.yapper.website) must not land another site in this window, which carries the desktop bridge.
  win.webContents.on('will-redirect', (e, url, _inPlace, isMainFrame) => {
    if (isMainFrame === false || ownUrl(url)) return;
    e.preventDefault();
    if (/^https:\/\//.test(url)) void shell.openExternal(url);
  });

  // Closing the window keeps Yapper in the tray (calls keep running), like Discord. Quit from the tray, or turn
  // "Close to tray" off in Settings -> Desktop app. The first time, a small notice says where it went.
  win.on('close', (e) => {
    if (quitting) return;
    if (!settings.closeToTray) { quitting = true; app.quit(); return; }
    e.preventDefault();
    win.hide();
    if (!settings.trayNoticeShown && Notification.isSupported()) {
      saveSettings({ trayNoticeShown: true });
      const note = new Notification({ title: 'Yapin’ is still running', body: IS_MAC ? 'Calls and notifications keep working. Reopen Yapper from the Dock or menu bar. Choose Yapper > Quit Yapper to quit.' : 'It’s in the tray, so calls and notifications keep working. Right-click the tray icon to quit, or change this in Settings > Desktop app.', icon: ICON, silent: true });
      note.on('click', show);
      note.show();
    }
  });
  win.on('closed', () => { win = null; });
}

/** Start with Windows (and in the tray if asked): one place that sets it, for the tray menu and the site's settings. */
function setLoginItem(openAtLogin, startMinimized) {
  if (process.platform !== 'win32' && process.platform !== 'darwin') return;
  saveSettings({ startMinimized: !!startMinimized });
  app.setLoginItemSettings(IS_MAC ? { openAtLogin: !!openAtLogin } : { openAtLogin: !!openAtLogin, args: startMinimized ? ['--hidden'] : [] });
}
function openAtLogin() {
  try { return !!app.getLoginItemSettings().openAtLogin; } catch { return false; }
}

function trayMenu() {
  return Menu.buildFromTemplate([
    { label: 'Open Yapin’', click: show },
    { type: 'separator' },
    ...(updateReady ? [{ label: `Restart to update (${updateReady})`, click: () => { quitting = true; setImmediate(() => autoUpdater.quitAndInstall(true, true)); } }] : []),
    IS_MAC ? { label: 'Yapper downloads…', click: () => shell.openExternal(`${SITE}/download`) } : { label: 'Check for updates', click: () => autoUpdater.checkForUpdatesAndNotify().catch(() => undefined) },
    { label: IS_MAC ? 'Open at Login' : 'Start with Windows', type: 'checkbox', checked: openAtLogin(), visible: IS_MAC || process.platform === 'win32',
      click: (item) => setLoginItem(item.checked, settings.startMinimized) },
    { type: 'separator' },
    { label: 'Quit Yapin’', click: () => { quitting = true; app.quit(); } },
  ]);
}
function createTray() {
  const img = nativeImage.createFromPath(ICON).resize({ width: 16, height: 16 });
  tray = new Tray(img);
  tray.setToolTip('Yapin’');
  tray.setContextMenu(trayMenu());
  tray.on('click', show);
  tray.on('double-click', show);
}

// Standard Mac commands keep editing, closing, hiding and quitting available from the keyboard.
function createMacMenu() {
  const privacy = (label, pane) => ({ label, click: () => shell.openExternal(`x-apple.systempreferences:com.apple.preference.security?${pane}`) });
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: 'Yapper', submenu: [
      { role: 'about' }, { type: 'separator' }, { role: 'services' }, { type: 'separator' },
      { role: 'hide' }, { role: 'hideOthers' }, { role: 'unhide' }, { type: 'separator' }, { role: 'quit' },
    ] },
    { label: 'File', submenu: [{ label: 'Open Yapper', click: show }, { role: 'close' }] },
    { role: 'editMenu' },
    { label: 'View', submenu: [
      { role: 'reload' }, { type: 'separator' },
      { label: 'Actual Size', accelerator: 'Command+0', click: () => setZoom(1) },
      { label: 'Zoom In', accelerator: 'Command+Plus', click: () => setZoom(zoom + 0.1) },
      { label: 'Zoom Out', accelerator: 'Command+-', click: () => setZoom(zoom - 0.1) },
      { type: 'separator' }, { role: 'togglefullscreen' },
      { type: 'separator' },
      { label: 'Enhanced Profile Layout', type: 'checkbox', checked: yappercord.readLayoutEnabled(path.join(app.getPath('userData'), 'appearance.json')), click: item => {
        try {
          yappercord.writeEnabled(path.join(app.getPath('userData'), 'appearance.json'), item.checked);
          if (win && !win.isDestroyed()) win.webContents.executeJavaScript('window.YapperAppearance?.destroy()').catch(() => {}).finally(() => { if (win && !win.isDestroyed()) win.reload(); });
          createMacMenu();
        } catch (error) { console.error('Could not save layout preference:', error.message); createMacMenu(); }
      } },
    ] },
    { role: 'windowMenu' },
    { label: 'YapperCord', submenu: [
      { label: 'Enable YapperCord', type: 'checkbox', checked: yappercord.readEnabled(path.join(app.getPath('userData'), 'yappercord.json')), click: item => {
        try {
          yappercord.writeEnabled(path.join(app.getPath('userData'), 'yappercord.json'), item.checked);
          if (win && !win.isDestroyed()) {
            // Remove live effects immediately, then reload with the new opt-in state.
            win.webContents.executeJavaScript('window.YapperCord?.destroy()').catch(() => {}).finally(() => { if (win && !win.isDestroyed()) win.reload(); });
          }
          createMacMenu();
        } catch (error) { console.error('Could not save YapperCord preference:', error.message); createMacMenu(); }
      } },
      { label: 'Open Plugin Manager', accelerator: 'Command+Shift+P', enabled: yappercord.readEnabled(path.join(app.getPath('userData'), 'yappercord.json')), click: () => {
        show(); if (win && yappercord.trustedPage(win.webContents.getURL())) win.webContents.executeJavaScript('window.YapperCord?.open()').catch(() => {});
      } },
      { label: 'Source & Compatibility', click: () => shell.openExternal('https://github.com/h7sd/yapper-apple-ports/tree/main/extensions/yappercord') },
    ] },
    { role: 'help', submenu: [
      { label: 'Yapper website', click: () => shell.openExternal(SITE) },
      { label: 'Yapper downloads…', click: () => shell.openExternal(`${SITE}/download`) },
      { label: 'Mac Permissions', submenu: [
        privacy('Microphone', 'Privacy_Microphone'), privacy('Camera', 'Privacy_Camera'),
        privacy('Screen & System Audio Recording', 'Privacy_ScreenCapture'),
        privacy('Accessibility (global hotkeys)', 'Privacy_Accessibility'),
      ] },
    ] },
  ]));
  app.dock?.setMenu(Menu.buildFromTemplate([{ label: 'Open Yapper', click: show }]));
}

// Native consent is requested only when the site actually asks to use the device.
async function allowMacMedia(mediaTypes = []) {
  for (const type of new Set(mediaTypes)) {
    const device = type === 'audio' ? 'microphone' : type === 'video' ? 'camera' : null;
    if (!device) continue;
    if (!await systemPreferences.askForMediaAccess(device)) return false;
  }
  return true;
}

// ---------- Hotkeys that work while a game has focus (push to talk, mute, deafen) ----------
// The page's own key events stop the moment another window has focus, so push to talk was useless in a game.
// A low-level hook (uiohook-napi) sees keys everywhere; it runs only while the site asks for it (in a call with
// a key set) and only looks for the keys the site named. Nothing typed is kept or sent anywhere.
let hook = null;       // the uIOhook module, loaded on first use (null = not available on this computer)
let hookOn = false;
let hotkeys = { ptt: null, mute: null, deafen: null }; // DOM codes / combos from the site, or null
const DOM_TO_UIO = { Backquote: 'Backquote', Space: 'Space', CapsLock: 'CapsLock', Tab: 'Tab', Enter: 'Enter', Backspace: 'Backspace', Escape: 'Escape',
  ShiftLeft: 'Shift', ShiftRight: 'ShiftRight', ControlLeft: 'Ctrl', ControlRight: 'CtrlRight', AltLeft: 'Alt', AltRight: 'AltRight', MetaLeft: 'Meta', MetaRight: 'MetaRight',
  Semicolon: 'Semicolon', Equal: 'Equal', Comma: 'Comma', Minus: 'Minus', Period: 'Period', Slash: 'Slash', BracketLeft: 'BracketLeft', BracketRight: 'BracketRight', Backslash: 'Backslash', Quote: 'Quote',
  Insert: 'Insert', Delete: 'Delete', Home: 'Home', End: 'End', PageUp: 'PageUp', PageDown: 'PageDown', ArrowUp: 'ArrowUp', ArrowDown: 'ArrowDown', ArrowLeft: 'ArrowLeft', ArrowRight: 'ArrowRight',
  NumpadAdd: 'NumpadAdd', NumpadSubtract: 'NumpadSubtract', NumpadMultiply: 'NumpadMultiply', NumpadDivide: 'NumpadDivide', NumpadDecimal: 'NumpadDecimal', NumpadEnter: 'NumpadEnter', NumLock: 'NumLock', ScrollLock: 'ScrollLock' };
/** A DOM KeyboardEvent.code ("KeyA", "Digit1", "F5", "Backquote") as a uiohook keycode, or null. */
function uioCode(code) {
  if (!hook || typeof code !== 'string') return null;
  const K = hook.UiohookKey;
  let name = DOM_TO_UIO[code];
  if (!name) {
    if (/^Key[A-Z]$/.test(code)) name = code.slice(3);
    else if (/^Digit\d$/.test(code)) name = code.slice(5);
    else if (/^Numpad\d$/.test(code) || /^F\d{1,2}$/.test(code)) name = code;
  }
  const v = name ? K[name] : undefined;
  return typeof v === 'number' ? v : null;
}
/** "Mouse3" / "Mouse4" (the side buttons, as the page numbers them) as uiohook's button number. */
function uioMouse(code) {
  const m = /^Mouse(\d)$/.exec(String(code));
  if (!m) return null;
  return [1, 3, 2, 4, 5][Number(m[1])] ?? null; // DOM: 0 left, 1 middle, 2 right, 3 back, 4 forward. uiohook: 1 left, 2 right, 3 middle, 4, 5.
}
/** "Mod+Shift+M" as { ctrl, alt, shift, key: uiohook keycode }, or null. */
function uioCombo(combo) {
  if (!hook || typeof combo !== 'string' || !combo) return null;
  const parts = combo.split('+');
  const key = parts.pop();
  const K = hook.UiohookKey;
  let code = null;
  if (/^[A-Z0-9]$/.test(key)) code = K[key];
  else if (key === 'Space') code = K.Space;
  else if (key === '/') code = K.Slash;
  else if (key === 'Plus') code = K.Equal;
  else if (/^F\d{1,2}$/.test(key) || /^Arrow/.test(key) || ['Escape', 'Enter', 'Tab', 'Backspace', 'Home', 'End', 'PageUp', 'PageDown', 'Insert', 'Delete'].includes(key)) code = K[key];
  if (typeof code !== 'number') return null;
  return { ctrl: parts.includes('Mod'), alt: parts.includes('Alt'), shift: parts.includes('Shift'), key: code };
}
function comboHit(e, c) {
  return !!c && e.keycode === c.key && (e.ctrlKey || e.metaKey) === c.ctrl && e.altKey === c.alt && e.shiftKey === c.shift;
}
let want = { pttKey: null, pttMouse: null, mute: null, deafen: null };
function loadHook() {
  if (hook !== null) return hook;
  try {
    // Wayland has no global key events for apps; the page keeps its in-window keys there.
    if (process.platform === 'linux' && process.env.XDG_SESSION_TYPE === 'wayland') throw new Error('wayland');
    const m = require('uiohook-napi');
    hook = { UiohookKey: m.UiohookKey, io: m.uIOhook };
    const io = hook.io;
    const send = (ch, v) => { if (win && !win.isDestroyed()) win.webContents.send(ch, v); };
    // The page handles its own keys while it has focus (it knows when a letter is being typed into a box); the hook
    // only steps in for other windows (a game). A key let go after switching windows is still seen by one side.
    const away = () => !(win && !win.isDestroyed() && win.isFocused());
    io.on('keydown', (e) => {
      if (!away()) return;
      if (want.pttKey !== null && e.keycode === want.pttKey) send('yapper:ptt', true);
      if (comboHit(e, want.mute)) send('yapper:hotkey', 'toggleMute');
      else if (comboHit(e, want.deafen)) send('yapper:hotkey', 'toggleDeafen');
    });
    io.on('keyup', (e) => { if (away() && want.pttKey !== null && e.keycode === want.pttKey) send('yapper:ptt', false); });
    io.on('mousedown', (e) => { if (away() && want.pttMouse !== null && e.button === want.pttMouse) send('yapper:ptt', true); });
    io.on('mouseup', (e) => { if (away() && want.pttMouse !== null && e.button === want.pttMouse) send('yapper:ptt', false); });
  } catch (err) {
    console.warn('global hotkeys off:', err?.message ?? err);
    hook = false;
  }
  return hook;
}
/**
 * The site says which keys matter right now (null for none). Answers { ptt, keys }: whether the push to talk key is
 * really hooked (a key the hook has no code for, like a media key, isn't) and whether the mute / deafen ones are.
 */
const OFF = { ptt: false, keys: false };
let promptedAccessibility = false;
function setHotkeys(h) {
  hotkeys = { ptt: typeof h?.ptt === 'string' ? h.ptt : null, mute: typeof h?.mute === 'string' ? h.mute : null, deafen: typeof h?.deafen === 'string' ? h.deafen : null };
  const any = hotkeys.ptt || hotkeys.mute || hotkeys.deafen;
  if (!any) { stopHook(); return OFF; }
  if (IS_MAC && !systemPreferences.isTrustedAccessibilityClient(false)) {
    stopHook();
    if (!promptedAccessibility) {
      promptedAccessibility = true;
      systemPreferences.isTrustedAccessibilityClient(true);
    }
    return OFF;
  }
  if (!loadHook()) return OFF;
  want = { pttKey: hotkeys.ptt ? uioCode(hotkeys.ptt) : null, pttMouse: hotkeys.ptt ? uioMouse(hotkeys.ptt) : null, mute: uioCombo(hotkeys.mute), deafen: uioCombo(hotkeys.deafen) };
  const ptt = want.pttKey !== null || want.pttMouse !== null;
  const keys = !!(want.mute || want.deafen);
  if (!ptt && !keys) { stopHook(); return OFF; }
  if (!hookOn) {
    try { hook.io.start(); hookOn = true; } catch (err) { console.warn('global hotkeys failed to start:', err?.message ?? err); return OFF; }
  }
  return { ptt, keys };
}
function stopHook() {
  if (!hookOn || !hook) return;
  try { hook.io.stop(); } catch { /* already stopped */ }
  hookOn = false;
}
/** The red dot on the taskbar icon while there's something unread (Windows overlay icon, 16 x 16). */
let dotImage = null;
function unreadDot() {
  if (dotImage) return dotImage;
  const size = 16;
  const buf = Buffer.alloc(size * size * 4);
  const c = (size - 1) / 2;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      // Soft edge: full inside, fading over the last pixel. Premultiplied BGRA.
      const a = Math.max(0, Math.min(1, c + 0.5 - Math.hypot(x - c, y - c)));
      const i = (y * size + x) * 4;
      buf[i] = Math.round(0x43 * a); buf[i + 1] = Math.round(0x3f * a); buf[i + 2] = Math.round(0xf2 * a); buf[i + 3] = Math.round(255 * a);
    }
  }
  dotImage = nativeImage.createFromBitmap(buf, { width: size, height: size });
  return dotImage;
}

// Screen picker helpers. A pick is good for one getDisplayMedia call within 30 s.
const SOURCE_ID = /^(screen|window):[\w:-]{1,64}$/;
const PICK_TTL = 30_000;
let pendingPick = null;

/** True for an https page on one of our own hosts. Everything that trusts a page (navigation, IPC, permissions)
 *  goes through this, so a plain-http copy of the site (someone on the network answering before the redirect to
 *  https) never gets the desktop bridge. */
function ownUrl(url) {
  try { const u = new URL(url); return u.protocol === 'https:' && ALLOWED.has(u.hostname); } catch { return false; }
}
/** Only the Yapper site itself may list or pick screens. */
function fromYapper(e) {
  return ownUrl(e.senderFrame?.url ?? '');
}
function takePick(req) {
  const p = pendingPick;
  pendingPick = null;
  if (!p || Date.now() - p.at > PICK_TTL) return null;
  if (req?.frame && !ownUrl(req.frame.url)) return null;
  return p.id;
}
/** "window:1234:0" -> "window:1234", so our own window matches whatever suffix the capturer uses. */
function windowKey(id) {
  return String(id).split(':').slice(0, 2).join(':');
}
function ownWindowKey() {
  try { return win && typeof win.getMediaSourceId === 'function' ? windowKey(win.getMediaSourceId()) : ''; } catch { return ''; }
}

app.setAsDefaultProtocolClient('yapper');
app.on('second-instance', (_e, argv) => { show(); openDeepLink(argv.find((a) => a.startsWith('yapper://'))); });
app.on('open-url', (e, url) => { e.preventDefault(); openDeepLink(url); });

app.whenReady().then(() => {
  // So the site knows it's inside the desktop app (lib/desktop.ts can check navigator.userAgent).
  app.userAgentFallback = `${app.userAgentFallback} YapperDesktop/${app.getVersion()}`;
  if (process.platform === 'win32') app.setAppUserModelId('website.yapper.desktop');

  const ses = session.defaultSession;
  // Everything Yapper's own pages may ask for; nothing else, and nothing at all for other origins.
  const OWN_PERMISSIONS = ['media', 'notifications', 'display-capture', 'clipboard-read', 'clipboard-sanitized-write', 'fullscreen'];
  // Mic, camera and notifications: yes for Yapper, no for anything else.
  ses.setPermissionRequestHandler((wc, permission, cb, details) => {
    const allowed = ownUrl(details.requestingUrl || wc.getURL()) && OWN_PERMISSIONS.includes(permission);
    if (allowed && IS_MAC && permission === 'media') {
      allowMacMedia(details.mediaTypes).then(cb).catch(() => cb(false));
    } else cb(allowed);
  });
  ses.setPermissionCheckHandler((wc, permission, origin) => {
    return ownUrl(origin) && OWN_PERMISSIONS.includes(permission);
  });
  // Screen sharing: the site shows our own picker (window.yapperDesktop.screenSources), sends the pick
  // (yapper:screen-pick), then calls getDisplayMedia, which lands here. No fresh pick (an older site, or
  // something else asking): the whole screen, like before. useSystemPicker stays off so ours always wins.
  ses.setDisplayMediaRequestHandler(async (req, cb) => {
    try {
      if (!ownUrl(req.frame?.url || req.securityOrigin)) return cb({});
      const picked = takePick(req);
      const sources = await desktopCapturer.getSources({ types: ['screen', 'window'], thumbnailSize: { width: 0, height: 0 } });
      const chosen = picked && sources.find((s) => s.id === picked);
      if (chosen) {
        // System sound only works for whole screens on Windows; a single app goes without (like Discord).
        const loopback = req.audioRequested && chosen.id.startsWith('screen:') && process.platform === 'win32';
        return cb(loopback ? { video: chosen, audio: 'loopback' } : { video: chosen });
      }
      const screen = sources.find((s) => s.id.startsWith('screen')) ?? sources[0];
      if (!screen) return cb({});
      const loopback = req.audioRequested && process.platform === 'win32';
      cb(loopback ? { video: screen, audio: 'loopback' } : { video: screen });
    } catch { cb({}); }
  }, { useSystemPicker: false });

  createWindow();
  createTray();
  if (IS_MAC) createMacMenu();
  else Menu.setApplicationMenu(null);

  // Only the Yapper site itself may use the bridge: a page the window ended up on must not set badges or make notifications.
  // The preload draws the little red number (it has a canvas, this process doesn't) and sends it along as a PNG.
  ipcMain.on('yapper:badge', (e, count, png) => {
    if (!fromYapper(e) || typeof count !== 'number') return;
    // Windows only ever cleared the overlay (it was never set), so the taskbar showed no sign of unread messages.
    if (process.platform === 'darwin') app.dock?.setBadge(count > 0 ? String(count) : '');
    else if (process.platform === 'win32') {
      if (win) {
        // 1.1.0: the number the preload drew; an older preload sends none, then the plain red dot.
        const img = count > 0 && typeof png === 'string' && png.startsWith('data:image/png;base64,') && png.length < 20000 ? nativeImage.createFromDataURL(png) : null;
        win.setOverlayIcon(count > 0 ? (img && !img.isEmpty() ? img : unreadDot()) : null, count > 0 ? `${count} unread` : '');
      }
    } else { try { app.setBadgeCount(count > 0 ? count : 0); } catch { /* desktop without launcher badges */ } }
    if (win && count > 0 && !win.isFocused()) win.flashFrame(true);
  });
  ipcMain.on('yapper:version', (e) => { e.returnValue = app.getVersion(); });
  ipcMain.handle('yapper:settings-get', (e) => {
    if (!fromYapper(e)) return null;
    const { trayNoticeShown: _n, ...rest } = settings;
    return { ...rest, openAtLogin: openAtLogin(), platform: process.platform, hwAccelNow: HW_AT_START };
  });
  ipcMain.handle('yapper:settings-set', (e, p) => {
    if (!fromYapper(e) || !p || typeof p !== 'object') return false;
    const patch = {};
    for (const k of ['closeToTray', 'hwAccel', 'activity']) if (typeof p[k] === 'boolean') patch[k] = p[k];
    if (Array.isArray(p.customGames)) {
      patch.customGames = p.customGames
        .filter((g) => g && typeof g.proc === 'string' && typeof g.name === 'string')
        .map((g) => ({ proc: g.proc.toLowerCase().slice(0, 80), name: g.name.slice(0, 60) }))
        .slice(0, 50);
    }
    saveSettings(patch);
    if (typeof p.openAtLogin === 'boolean' || typeof p.startMinimized === 'boolean') {
      setLoginItem(typeof p.openAtLogin === 'boolean' ? p.openAtLogin : openAtLogin(), typeof p.startMinimized === 'boolean' ? p.startMinimized : settings.startMinimized);
      tray?.setContextMenu(trayMenu());
    }
    if ('activity' in patch || 'customGames' in patch) { misses = 0; pollGames().catch(() => undefined); }
    return true;
  });
  // Global hotkeys (push to talk, mute, deafen): the page says which keys, we say whether the hook runs.
  ipcMain.handle('yapper:hotkeys', (e, h) => (fromYapper(e) ? setHotkeys(h) : false));
  // Running programs with a window, for "Add a game" in Settings -> Desktop app.
  ipcMain.handle('yapper:programs', async (e) => {
    if (!fromYapper(e)) return [];
    const procs = await listProcesses();
    const known = new Set([...GAMES, ...TOOLS].map(([k]) => k));
    return [...procs.entries()]
      .filter(([, p]) => p.windowed !== false && !HELPER.test(p.name) && !known.has(p.name) && !/^(explorer|yapper|yapin|electron|svchost|dwm|csrss)/.test(p.name))
      .map(([name, p]) => ({ proc: name, title: String(p.title || '').slice(0, 80) }))
      .slice(0, 80);
  });
  // How long the computer has been idle (no mouse or keyboard anywhere, not only in Yapin'): every 15 s, so the
  // page doesn't show Idle while you're in a game with Yapin' in the tray.
  setInterval(() => { if (win && !win.isDestroyed()) win.webContents.send('yapper:idle', powerMonitor.getSystemIdleTime()); }, 15_000);
  ipcMain.on('yapper:notify', (e, n) => {
    if (!fromYapper(e)) return;
    if (!Notification.isSupported() || (win && win.isFocused())) return;
    const note = new Notification({ title: String(n?.title ?? 'Yapin’').slice(0, 80), body: String(n?.body ?? '').slice(0, 180), icon: ICON, silent: true });
    note.on('click', () => { show(); if (n?.url) loadSite(siteUrl(n.url)); });
    note.show();
  });

  // The screen picker's list: screens and app windows with small live thumbnails (not our own window).
  ipcMain.handle('yapper:screen-sources', async (e) => {
    if (!fromYapper(e)) return [];
    const own = ownWindowKey();
    const sources = await desktopCapturer.getSources({ types: ['screen', 'window'], thumbnailSize: { width: 320, height: 180 }, fetchWindowIcons: true });
    return sources
      .filter((s) => !(own && s.id.startsWith('window:') && windowKey(s.id) === own))
      .map((s) => ({
        id: s.id,
        name: String(s.name || '').slice(0, 120),
        kind: s.id.startsWith('screen:') ? 'screen' : 'window',
        // JPEG keeps the list small; it's refreshed every few seconds while the picker is open.
        thumb: s.thumbnail && !s.thumbnail.isEmpty() ? `data:image/jpeg;base64,${s.thumbnail.toJPEG(70).toString('base64')}` : null,
        icon: s.appIcon && !s.appIcon.isEmpty() ? s.appIcon.resize({ width: 32, height: 32 }).toDataURL() : null,
      }));
  });
  ipcMain.handle('yapper:screen-pick', (e, id) => {
    if (!fromYapper(e) || typeof id !== 'string' || !SOURCE_ID.test(id)) { pendingPick = null; return false; }
    pendingPick = { id, at: Date.now() };
    return true;
  });

  // Updates: check at start and every 4 hours; installs when you quit, or right away from the site's
  // "Restart to update" bar (people keep the app in the tray and rarely quit, so updates sat waiting).
  // The supplied feed publishes Linux/Windows builds. A Mac port has no signed Mac update feed.
  autoUpdater.autoDownload = !IS_MAC;
  autoUpdater.autoInstallOnAppQuit = !IS_MAC;
  autoUpdater.on('update-downloaded', (info) => {
    updateReady = String(info?.version || 'new');
    win?.webContents.send('yapper:update-ready', updateReady);
    tray?.setContextMenu(trayMenu()); // "Restart to update" in the tray too
  });
  ipcMain.on('yapper:update-ask', (e) => { if (fromYapper(e) && updateReady) e.sender.send('yapper:update-ready', updateReady); });
  ipcMain.handle('yapper:update-install', (e) => {
    if (!fromYapper(e) || !updateReady) return false;
    quitting = true;
    setImmediate(() => autoUpdater.quitAndInstall(true, true)); // silent install, then start again
    return true;
  });
  const check = () => autoUpdater.checkForUpdatesAndNotify().catch(() => undefined);
  if (!IS_MAC) {
    setTimeout(check, 10_000);
    setInterval(check, 4 * 3600_000);
  }

  openDeepLink(pendingDeepLink || process.argv.find((a) => a.startsWith('yapper://')));
});

// "Playing X": every 20 s look at the running processes for a known game (desktop/games.js) and tell
// the page. Only the game's name leaves this machine, and only while it runs.
let lastGame = null;
// When this app first saw it running. Sent along so a page reload doesn't start "Playing for ..." over.
let lastGameSince = null;
// Polls in a row that found no game while one was showing. A failed process list or a loading screen (no window yet)
// reset "playing since" after one empty poll, so the game only counts as closed after two.
let misses = 0;
/**
 * Everything running: Map of program name (lower case, "game.exe" on Windows) -> { name, windowed, title }.
 * Windows: one PowerShell call gives the names and whether each has a visible window (Roblox keeps running in
 * the background after you close it, Spotify sits in the tray: neither is being played). It used to be tasklist
 * plus a second PowerShell for the window check, every 20 s. If PowerShell is blocked, tasklist, as before
 * (windowed unknown = null).
 */
function run(cmd, args, opts) {
  return new Promise((resolve) => execFile(cmd, args, { windowsHide: true, maxBuffer: 8e6, ...opts }, (err, out) => resolve(err ? null : String(out))));
}
async function listProcesses() {
  if (IS_MAC) return listMacProcesses(run);
  const procs = new Map();
  if (process.platform === 'win32') {
    const out = await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
      'Get-Process | ForEach-Object { "{0}`t{1}`t{2}" -f $_.ProcessName, [int]($_.MainWindowHandle -ne 0), $_.MainWindowTitle }; exit 0'], { timeout: 15_000 });
    if (out !== null) {
      for (const line of out.split(/\r?\n/)) {
        const [name, windowed, ...title] = line.split('\t');
        if (!name) continue;
        const key = `${name.toLowerCase()}.exe`;
        const cur = procs.get(key);
        // Several copies of a program: windowed if any of them has a window.
        // Every window title of the program, one per line (several Java windows: the Minecraft one must still match).
        const t = windowed === '1' ? title.join('\t').trim() : '';
        procs.set(key, { name: key, windowed: windowed === '1' || !!cur?.windowed, title: [cur?.title, t].filter(Boolean).join('\n') });
      }
      return procs;
    }
    const csv = await run('tasklist', ['/FO', 'CSV', '/NH']);
    for (const line of (csv ?? '').split(/\r?\n/)) {
      const raw = (/^"([^"]+)"/.exec(line) || [])[1];
      if (raw) procs.set(raw.toLowerCase(), { name: raw.toLowerCase(), windowed: null, title: '' });
    }
    return procs;
  }
  const out = await run('ps', ['-axo', 'comm=']);
  for (const line of (out ?? '').split(/\r?\n/)) {
    const raw = line.trim().split('/').pop(); // a name, or a full path on macOS
    if (raw) procs.set(raw.toLowerCase(), { name: raw.toLowerCase(), windowed: null, title: '' });
  }
  return procs;
}
// Launchers, installers, updaters and other helpers that keep running without the game or app being open:
// "RobloxPlayerLauncher", "RobloxPlayerInstaller", "SpotifyWidgetProvider" (Windows widgets, always on).
const HELPER = /launch|install|update|crash|helper|service|setup|bootstrap|widget|provider|uninst|webview|handler|tray|agent|server|report/;
/**
 * Does this program name belong to this games.js entry? It used to be a substring search over the whole process
 * list, so any program with a game's name somewhere inside it (a launcher, an updater, an unrelated tool) showed
 * "Playing ..." while the game itself was closed.
 */
function matchGame(proc, key) {
  const base = proc.replace(/\.exe$/, '');
  // On Linux "dolphin" is the KDE file manager (the emulator there is "dolphin-emu", its own entry).
  if (key === 'dolphin.exe' && process.platform === 'linux') return false;
  if (key.endsWith('.exe')) return base === key.slice(0, -4);
  // Linux cuts process names to 15 characters.
  if (process.platform === 'linux' && proc.length === 15 && key.startsWith(proc)) return true;
  return base.startsWith(key) && !HELPER.test(base.slice(key.length));
}
/**
 * Programs that are too generic to trust by name: they only count when one of their windows has a title that
 * matches. javaw.exe runs every Java app (Burp Suite, JDownloader), not just Minecraft.
 */
const NEEDS_TITLE = { 'javaw.exe': /minecraft|lunar client|badlion/i };
let polling = false;
async function pollGames() {
  if (polling) return;
  polling = true;
  try {
    let found = null;
    if (settings.activity !== false) {
      const procs = await listProcesses();
      // Your own added games first (exact program name), then games.js in order (first match wins). Only a program
      // with a visible window counts when we can tell. Tools (OBS, VS Code, Blender) are no longer "Playing".
      // Generic programs (NEEDS_TITLE: javaw runs every Java app) also need a matching window title; without window
      // info (PowerShell blocked) they are skipped.
      const list = [...(settings.customGames || []).map((g) => [g.proc, g.name]), ...GAMES];
      const hits = [];
      for (const [key, name] of list) {
        for (const p of procs.values()) {
          if (!matchGame(p.name, key) || p.windowed === false) continue;
          if (NEEDS_TITLE[key] && !(p.windowed && NEEDS_TITLE[key].test(p.title || ''))) continue;
          hits.push(name);
        }
      }
      found = hits[0] ?? null;
    }
    if (found === lastGame) misses = 0;
    else if (found === null && ++misses < 2) { /* keep showing it for now */ }
    else { misses = 0; lastGame = found; lastGameSince = found ? new Date().toISOString() : null; win?.webContents.send('yapper:activity', found, lastGameSince); }
  } finally {
    polling = false;
  }
}
ipcMain.on('yapper:activity:ask', (e) => { if (fromYapper(e)) e.sender.send('yapper:activity', lastGame, lastGameSince); });
setInterval(() => { pollGames().catch(() => undefined); }, 20_000);
setTimeout(() => { pollGames().catch(() => undefined); }, 3000);

app.on('before-quit', () => { quitting = true; stopHook(); });
// Quitting must really end the app. If something holds it up (a call still closing, a stuck update check),
// it sat in the background with no window, holding the one-copy lock so Yapper wouldn't open again.
app.on('will-quit', () => { setTimeout(() => app.exit(0), 8_000).unref?.(); });
app.on('window-all-closed', () => { /* stays in the tray */ });
app.on('activate', () => { if (win) show(); else createWindow(); });
