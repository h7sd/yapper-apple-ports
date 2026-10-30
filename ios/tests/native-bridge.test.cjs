'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../Yapper/resources/NativeBridge.js'), 'utf8');

function boot({ url = 'https://www.yapper.website/', frame = false, native = true, reply, throws = false } = {}) {
  const calls = [];
  const events = [];
  const location = new URL(url);
  const window = { location };
  window.self = window;
  window.top = frame ? {} : window;
  if (native) window.webkit = { messageHandlers: { yapperNative: {
    postMessage(message) {
      calls.push(message);
      if (throws) throw new Error('Native handler unavailable');
      return reply ? reply(message) : Promise.resolve(true);
    },
  } } };
  const document = { dispatchEvent: event => events.push(event) };
  class CustomEvent { constructor(type, { detail }) { this.type = type; this.detail = detail; } }
  const context = vm.createContext({ window, document, URL, CustomEvent });
  vm.runInContext(source, context, { filename: 'NativeBridge.js' });
  return { window, calls, events, context };
}

const plain = value => JSON.parse(JSON.stringify(value));

test('installs the exact original 17-member compatibility surface with truthful iOS identity', () => {
  const { window } = boot();
  assert.equal(Object.keys(window.yapperDesktop).length, 17);
  assert.equal(window.yapperDesktop.version, '1.1.0');
  assert.equal(window.yapperDesktop.platform, 'ios');
  assert.equal(window.yapperIOS.platform, 'ios');
  assert.ok(Object.isFrozen(window.yapperDesktop));
  assert.ok(Object.isFrozen(window.yapperIOS.capabilities));
  assert.equal(Object.getOwnPropertyDescriptor(window, 'yapperDesktop').writable, false);
  assert.equal(window.navigator, undefined, 'does not manufacture a desktop UA');
});

test('installs on every explicitly trusted HTTPS host', () => {
  for (const host of ['www.yapper.website', 'yapper.website', 'www.yapin.gg', 'yapin.gg', 'rt.yapper.website', 'lk.yapper.website']) {
    assert.ok(boot({ url: `https://${host}/` }).window.yapperIOS, host);
  }
  assert.ok(boot({ url: 'https://www.yapper.website:443/' }).window.yapperIOS);
});

test('never installs in an iframe, an untrusted origin, an insecure origin, or a nonstandard port', () => {
  for (const url of ['http://www.yapper.website/', 'https://www.yapper.website.attacker.example/', 'https://attacker.example/', 'https://www.yapper.website:8443/', 'file:///index.html', 'about:blank']) {
    assert.equal(boot({ url }).window.yapperDesktop, undefined, url);
  }
  assert.equal(boot({ frame: true }).window.yapperDesktop, undefined);
});

test('repeated injection leaves the original bridge and callbacks intact', () => {
  const { window, context } = boot();
  const original = window.yapperIOS;
  vm.runInContext(source, context);
  assert.equal(window.yapperIOS, original);
});

test('badge calls use the reply handler contract and clamp invalid/oversized counts', async () => {
  const { window, calls } = boot();
  await window.yapperDesktop.setBadge(12.8);
  await window.yapperDesktop.setBadge(-5);
  await window.yapperDesktop.setBadge(Infinity);
  await window.yapperDesktop.setBadge(100000);
  await window.yapperDesktop.setBadge('7');
  await window.yapperDesktop.setBadge(Symbol('not a number'));
  assert.deepEqual(plain(calls), [12, 0, 0, 9999, 7, 0].map(count => ({ method: 'setBadge', args: { count } })));
});

test('notifications contain bounded text and only a same-origin in-app destination', async () => {
  const { window, calls } = boot();
  await window.yapperDesktop.notify({ title: 'a'.repeat(300), body: 'b'.repeat(3000), url: '/?channel=abc#latest' });
  await window.yapperDesktop.notify({ url: 'https://attacker.example/phishing' });
  await window.yapperDesktop.notify({ url: 'javascript:alert(1)' });
  await window.yapperDesktop.notify({ url: '//attacker.example/' });
  await window.yapperDesktop.notify({ url: 'https://user:pass@www.yapper.website/private' });
  await window.yapperDesktop.notify({ url: 'https://www.yapper.website//attacker.example/' });
  assert.equal(calls[0].method, 'notify');
  assert.equal(calls[0].args.title.length, 180);
  assert.equal(calls[0].args.body.length, 2000);
  assert.equal(calls[0].args.url, '/?channel=abc#latest');
  for (const call of calls.slice(1)) assert.equal(call.args.url, '/');
});

test('normalizes native settings and does not propagate desktop support claims', async () => {
  const { window, calls } = boot({ reply: () => Promise.resolve({ nativeNotifications: true, platform: 'win32', activity: true, openAtLogin: true, closeToTray: true, customGames: [{ name: 'Fake game' }] }) });
  const settings = await window.yapperDesktop.getSettings();
  assert.equal(settings.nativeNotifications, true);
  assert.equal(settings.platform, 'ios');
  assert.equal(settings.activity, false);
  assert.equal(settings.openAtLogin, false);
  assert.equal(settings.closeToTray, false);
  assert.deepEqual(plain(settings.customGames), []);
  assert.deepEqual(plain(calls), [{ method: 'getSettings', args: {} }]);
});

test('settings forward only the explicit iOS notification opt-in', async () => {
  const { window, calls } = boot();
  assert.equal(await window.yapperDesktop.setSettings({ activity: true, openAtLogin: true }), false);
  assert.equal(await window.yapperDesktop.setSettings(null), false);
  assert.equal(await window.yapperDesktop.setSettings([]), false);
  assert.equal(await window.yapperDesktop.setSettings({ nativeNotifications: 'yes' }), false);
  assert.equal(await window.yapperIOS.setSettings({ nativeNotifications: true, activity: true, arbitrary: 'ignored' }), true);
  assert.deepEqual(plain(calls), [{ method: 'setSettings', args: { nativeNotifications: true } }]);
});

test('a denied request or missing native bridge resolves safely and never grants a setting', async () => {
  for (const options of [{ native: false }, { throws: true }, { reply: () => Promise.reject(new Error('Denied')) }]) {
    const { window } = boot(options);
    assert.equal(await window.yapperDesktop.setBadge(1), false);
    assert.equal(await window.yapperDesktop.notify({ title: 'test' }), false);
    assert.equal(await window.yapperDesktop.setSettings({ nativeNotifications: true }), false);
    assert.equal((await window.yapperDesktop.getSettings()).nativeNotifications, false);
  }
  const { window } = boot({ native: false });
  assert.equal(window.yapperIOS.capabilities.nativeBridge, false);
  assert.equal(window.yapperIOS.capabilities.badges, false);
  assert.equal(window.yapperIOS.capabilities.localNotifications, false);
});

test('unsupported desktop features are explicit, silent, and never call native', async () => {
  const { window, calls } = boot();
  const desktop = window.yapperDesktop;
  assert.equal(desktop.screenPicker, false);
  assert.deepEqual(plain(await desktop.screenSources()), []);
  assert.equal(await desktop.pickScreenSource('screen:1'), false);
  assert.equal(await desktop.installUpdate(), false);
  assert.deepEqual(plain(await desktop.setHotkeys({ ptt: 'Space' })), { ptt: false, keys: false });
  assert.deepEqual(plain(await desktop.listPrograms()), []);
  for (const subscribe of ['onUpdateReady', 'onPtt', 'onHotkey', 'onSystemIdle']) {
    desktop[subscribe](() => assert.fail(`${subscribe} cannot generate a fake event`));
  }
  await Promise.resolve();
  assert.equal(calls.length, 0);
  for (const key of ['backgroundPush', 'screenPicker', 'screenCapture', 'systemAudioCapture', 'globalHotkeys', 'activityDetection', 'runningPrograms', 'systemIdle', 'automaticUpdates']) {
    assert.equal(window.yapperIOS.capabilities[key], false, key);
  }
});

test('activity subscription clears inherited activity exactly once and supports unsubscribe', async () => {
  const { window } = boot();
  const calls = [];
  window.yapperDesktop.onActivity((...args) => calls.push(args));
  const unsubscribe = window.yapperDesktop.onActivity(() => assert.fail('unsubscribed callback'));
  unsubscribe();
  window.yapperDesktop.onActivity(() => { throw new Error('Page callback'); });
  await Promise.resolve();
  await Promise.resolve();
  assert.deepEqual(calls, [[null, undefined]]);
});

test('only validated native lifecycle events reach subscribers and the DOM', () => {
  const { window, events } = boot();
  const received = [];
  const unsubscribe = window.yapperIOS.onLifecycle(value => received.push(value));
  window.yapperIOS.onLifecycle(() => { throw new Error('Page callback'); });
  assert.equal(window.__yapperNativeEvent('ptt', { down: true }), false);
  assert.equal(window.__yapperNativeEvent('lifecycle', { state: 'unknown' }), false);
  assert.equal(window.__yapperNativeEvent('lifecycle', { state: 'active', privileged: true }), true);
  assert.deepEqual(plain(received), [{ state: 'active' }]);
  assert.ok(Object.isFrozen(received[0]));
  assert.equal(events[0].type, 'yapper:ios:lifecycle');
  assert.deepEqual(plain(events[0].detail), { state: 'active' });
  unsubscribe();
  window.__yapperNativeEvent('lifecycle', { state: 'background' });
  assert.equal(received.length, 1);
});
