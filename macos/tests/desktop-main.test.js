'use strict';

const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'main.js'), 'utf8');
const SITE = 'https://www.yapper.website';
const plain = (value) => JSON.parse(JSON.stringify(value));

// Run the shipped entry point while keeping every native effect inside this
// fixture. Readiness and timers are controlled explicitly; no Electron process,
// permission dialog, login item, file write, or child process can be created.
function desktop(options = {}) {
  const state = {
    windows: [], timers: [], nativeLoads: 0, hookStarts: 0,
    accessibilityCalls: [], mediaRequests: [], captures: [],
    updateChecks: 0, externalUrls: [], writes: [], loginChanges: [],
  };
  let ready = false;
  let resolveReady;
  const readiness = new Promise((resolve) => { resolveReady = resolve; });
  const app = Object.assign(new EventEmitter(), {
    userAgentFallback: 'Electron test',
    requestSingleInstanceLock: () => true,
    getPath: () => '/virtual/yapper-profile',
    getVersion: () => '1.1.0',
    isReady: () => ready,
    whenReady: () => readiness,
    getLoginItemSettings: () => ({ openAtLogin: false, wasOpenedAtLogin: !!options.atLogin }),
    setLoginItemSettings: (value) => state.loginChanges.push(value),
    setAsDefaultProtocolClient: () => true,
    disableHardwareAcceleration() {}, quit() {}, exit() {},
    dock: { setMenu() {}, setBadge() {} },
  });
  class BrowserWindow extends EventEmitter {
    constructor(windowOptions) {
      super();
      this.options = windowOptions;
      this.urls = [];
      this.visible = false;
      this.focused = false;
      this.webContents = Object.assign(new EventEmitter(), {
        getURL: () => this.urls.at(-1) || '',
        setWindowOpenHandler: (handler) => { this.openHandler = handler; },
        setZoomFactor() {}, send() {},
        session: { addWordToSpellCheckerDictionary() {} },
      });
      state.windows.push(this);
    }
    loadURL(url) { this.urls.push(url); return Promise.resolve(); }
    show() { this.visible = true; this.emit('show'); }
    hide() { this.visible = false; }
    focus() { this.focused = true; }
    isVisible() { return this.visible; }
    isFocused() { return this.focused; }
    isMinimized() { return false; }
    isDestroyed() { return false; }
    isFullScreen() { return false; }
    getMediaSourceId() { return 'window:99:0'; }
    restore() {}
    flashFrame() {}
  }
  class Tray extends EventEmitter {
    setContextMenu(menu) { this.menu = menu; }
    setToolTip() {}
  }
  class Notification extends EventEmitter {
    static isSupported() { return true; }
    show() {}
  }
  const ipcMain = Object.assign(new EventEmitter(), {
    handle: (channel, handler) => state.handlers.set(channel, handler),
  });
  state.handlers = new Map();
  const session = {
    setPermissionRequestHandler: (handler) => { state.permissionRequest = handler; },
    setPermissionCheckHandler: (handler) => { state.permissionCheck = handler; },
    setDisplayMediaRequestHandler: (handler) => { state.displayRequest = handler; },
  };
  const autoUpdater = Object.assign(new EventEmitter(), {
    checkForUpdatesAndNotify: async () => { state.updateChecks++; },
    quitAndInstall: () => assert.fail('A Mac test must never install an update'),
  });
  const image = { resize() { return this; } };
  const hook = Object.assign(new EventEmitter(), {
    start: () => { state.hookStarts++; }, stop() {},
  });
  const sources = options.sources || [
    { id: 'screen:1:0', name: 'Display 1' },
    { id: 'window:2:0', name: 'Shared application' },
  ];
  const electron = {
    app, BrowserWindow, Tray, Notification, ipcMain,
    Menu: {
      buildFromTemplate: (items) => ({ items, popup() {} }),
      setApplicationMenu: (menu) => { state.menu = menu; },
    },
    nativeImage: { createFromPath: () => image },
    shell: { openExternal: async (url) => { state.externalUrls.push(url); } },
    session: { defaultSession: session },
    desktopCapturer: { getSources: async (captureOptions) => {
      state.captures.push(captureOptions);
      if (options.captureError) throw new Error('Capture denied');
      return sources;
    } },
    powerMonitor: { getSystemIdleTime: () => 0 },
    systemPreferences: {
      isTrustedAccessibilityClient: (prompt) => {
        state.accessibilityCalls.push(prompt);
        return !!options.accessibility;
      },
      askForMediaAccess: async (type) => {
        state.mediaRequests.push(type);
        return options.mediaGranted !== false;
      },
    },
  };
  function schedule(kind, callback, delay) {
    const timer = { kind, callback, delay, active: true, unref() { return this; } };
    state.timers.push(timer);
    return timer;
  }
  const context = vm.createContext({
    __dirname: root, URL, Buffer,
    console: { warn() {}, log() {}, error() {} },
    process: { platform: 'darwin', argv: options.argv || ['Yapper'], env: {} },
    setTimeout: (callback, delay) => schedule('timeout', callback, delay),
    setInterval: (callback, delay) => schedule('interval', callback, delay),
    setImmediate: (callback) => schedule('immediate', callback, 0),
    clearTimeout: (timer) => { if (timer) timer.active = false; },
    require: (name) => {
      if (name === 'electron') return electron;
      if (name === 'electron-updater') return { autoUpdater };
      if (name === 'node:path') return path;
      if (name === 'node:fs') return {
        readFileSync: (file) => file.endsWith('settings.json')
          ? JSON.stringify(options.settings || {}) : '{}',
        writeFileSync: (...args) => state.writes.push(args),
      };
      if (name === 'node:child_process') return {
        execFile: () => assert.fail('Unexpected child process in desktop regression test'),
      };
      if (name === './games') return { games: [], tools: [] };
      if (name === './mac-processes') return { listMacProcesses: async () => new Map() };
      if (name === 'uiohook-napi') {
        state.nativeLoads++;
        return { uIOhook: hook, UiohookKey: { Backquote: 41, M: 50 } };
      }
      throw new Error(`Unexpected module in desktop test: ${name}`);
    },
  });
  vm.runInContext(source, context, { filename: path.join(root, 'main.js') });
  const event = (url = SITE) => ({ senderFrame: { url }, sender: { send() {} } });
  return {
    state, app, autoUpdater,
    get window() { return state.windows[0]; },
    async ready() { ready = true; resolveReady(); await readiness; await Promise.resolve(); },
    invoke: (channel, value, url = SITE) => state.handlers.get(channel)(event(url), value),
    permission: (permission, mediaTypes, requestingUrl = SITE) => new Promise((resolve) => {
      state.permissionRequest({ getURL: () => SITE }, permission, resolve, { requestingUrl, mediaTypes });
    }),
    async display(overrides = {}) {
      let calls = 0;
      let result;
      await state.displayRequest({
        frame: { url: SITE }, securityOrigin: SITE,
        videoRequested: true, audioRequested: true, userGesture: true,
        ...overrides,
      }, (streams) => { calls++; result = streams; });
      assert.equal(calls, 1, 'Each display request must be settled once');
      return result;
    },
  };
}

test('an invite that launches the Mac app survives until the first window exists', async () => {
  const client = desktop();
  let prevented = false;
  client.app.emit('open-url', { preventDefault() { prevented = true; } }, 'yapper://invite/example?from=desktop');
  assert.equal(prevented, true);
  assert.equal(client.state.windows.length, 0);
  await client.ready();
  assert.equal(client.window.urls.at(-1), `${SITE}/invite/example?from=desktop`);
  assert.equal(client.window.visible, true);
});

test('deep links cannot turn their path into foreign hosts or URL credentials', async () => {
  const client = desktop();
  await client.ready();
  for (const url of [
    'yapper://@attacker.example/invite',
    'yapper:////attacker.example/invite',
    'yapper://user:password@attacker.example/invite',
    'yapper://https://attacker.example/invite',
    'yapper://\\attacker.example/invite',
    'yapper://%2f%2fattacker.example/invite',
  ]) {
    client.app.emit('open-url', { preventDefault() {} }, url);
    const loaded = new URL(client.window.urls.at(-1));
    assert.equal(loaded.origin, SITE, url);
    assert.equal(loaded.username, '', url);
    assert.equal(loaded.password, '', url);
  }
  const previous = client.window.urls.length;
  client.app.emit('open-url', { preventDefault() {} }, 'https://attacker.example');
  assert.equal(client.window.urls.length, previous);
  client.window.openHandler({ url: 'https://user:password@www.yapper.website/invite', frameName: '' });
  assert.equal(client.window.urls.at(-1), SITE);
});

test('denied Accessibility keeps native hooks unloaded and reports unavailable hotkeys', async () => {
  const client = desktop({ accessibility: false });
  await client.ready();
  const hotkeys = { ptt: 'Backquote', mute: 'Mod+Shift+M', deafen: null };
  assert.deepEqual(plain(client.invoke('yapper:hotkeys', hotkeys)), { ptt: false, keys: false });
  assert.deepEqual(plain(client.invoke('yapper:hotkeys', hotkeys)), { ptt: false, keys: false });
  assert.equal(client.state.nativeLoads, 0);
  assert.equal(client.state.hookStarts, 0);
  assert.equal(client.state.accessibilityCalls.filter(Boolean).length, 1, 'Repeated calls must not repeat the consent prompt');
  const previous = client.state.accessibilityCalls.length;
  assert.equal(client.invoke('yapper:hotkeys', hotkeys, 'https://attacker.example'), false);
  assert.equal(client.state.accessibilityCalls.length, previous);
});

test('Mac media consent is limited to the requesting origin and requested devices', async () => {
  const client = desktop();
  await client.ready();
  assert.equal(await client.permission('media', ['audio'], 'https://attacker.example'), false);
  assert.equal(await client.permission('media', ['audio'], 'http://www.yapper.website'), false);
  assert.deepEqual(client.state.mediaRequests, []);
  assert.equal(await client.permission('media', ['audio', 'audio']), true);
  assert.deepEqual(client.state.mediaRequests, ['microphone']);
  client.state.mediaRequests.length = 0;
  assert.equal(await client.permission('media', ['video']), true);
  assert.deepEqual(client.state.mediaRequests, ['camera']);
  client.state.mediaRequests.length = 0;
  assert.equal(await client.permission('notifications', []), true);
  assert.equal(await client.permission('geolocation', []), false);
  assert.deepEqual(client.state.mediaRequests, []);
});

test('OS media denial propagates to the renderer without requesting another device', async () => {
  const client = desktop({ mediaGranted: false });
  await client.ready();
  assert.equal(await client.permission('media', ['audio', 'video']), false);
  assert.deepEqual(client.state.mediaRequests, ['microphone']);
});

test('Mac capture uses the selected source once and never grants Windows loopback audio', async () => {
  const client = desktop();
  await client.ready();
  assert.equal(client.invoke('yapper:screen-pick', 'window:2:0'), true);
  const chosen = await client.display();
  assert.equal(chosen.video.id, 'window:2:0');
  assert.equal(Object.hasOwn(chosen, 'audio'), false);
  const next = await client.display();
  assert.equal(next.video.id, 'screen:1:0', 'A consumed pick must not be reused');
  assert.equal(Object.hasOwn(next, 'audio'), false);
  assert.equal(client.invoke('yapper:screen-pick', 'screen:1:0'), true);
  const selectedScreen = await client.display();
  assert.equal(selectedScreen.video.id, 'screen:1:0');
  assert.equal(Object.hasOwn(selectedScreen, 'audio'), false, 'Selecting a whole screen must not enable unsupported Mac loopback');
});

test('foreign and navigated capture requests are denied before enumerating screens', async () => {
  const client = desktop();
  await client.ready();
  assert.deepEqual(plain(await client.display({ frame: { url: 'https://attacker.example' }, securityOrigin: 'https://attacker.example' })), {});
  assert.deepEqual(plain(await client.display({ frame: null, securityOrigin: 'https://attacker.example' })), {});
  assert.deepEqual(plain(await client.display({ frame: { url: 'https://attacker.example' }, securityOrigin: SITE })), {});
  assert.equal(client.state.captures.length, 0);
});

test('capture failures settle the request as denied', async () => {
  const client = desktop({ captureError: true });
  await client.ready();
  assert.deepEqual(plain(await client.display()), {});
});

test('login hiding does not hide normal manual launches', async () => {
  for (const [atLogin, startMinimized, visible] of [[true, true, false], [false, true, true], [true, false, true]]) {
    const client = desktop({ atLogin, settings: { startMinimized } });
    await client.ready();
    client.window.emit('ready-to-show');
    assert.equal(client.window.visible, visible, `atLogin=${atLogin}, startMinimized=${startMinimized}`);
    assert.deepEqual(client.state.loginChanges, [], 'Startup must not change the system login-item setting');
  }
});

test('Mac startup and background timers cannot initiate unsigned automatic updates', async () => {
  const client = desktop();
  await client.ready();
  assert.equal(client.autoUpdater.autoDownload, false);
  assert.equal(client.autoUpdater.autoInstallOnAppQuit, false);
  for (const timer of client.state.timers.filter((entry) => entry.active)) await timer.callback();
  await Promise.resolve();
  assert.equal(client.state.updateChecks, 0);
  assert.equal(await client.invoke('yapper:update-install'), false);
});
