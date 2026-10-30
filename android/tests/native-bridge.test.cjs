'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../app/src/main/assets/NativeBridge.js'), 'utf8');
const plain = value => JSON.parse(JSON.stringify(value));
function boot({ url = 'https://www.yapper.website/', frame = false, native = true, reply = true, throws = false, defer = false } = {}) {
  const calls = [], events = [], pageEvents = {};
  const location = new URL(url);
  const window = { location, addEventListener: (name, callback) => { pageEvents[name] = callback; } };
  window.self = window; window.top = frame ? {} : window;
  const handler = { postMessage(data) {
    if (throws) throw new Error('Unavailable');
    const request = JSON.parse(data); calls.push(request);
    if (!defer) handler.onmessage({ data: JSON.stringify({ id: request.id, result: reply }) });
  } };
  if (native) window.yapperNative = handler;
  const document = { dispatchEvent: event => events.push(event) };
  class CustomEvent { constructor(type, { detail }) { this.type = type; this.detail = detail; } }
  const context = vm.createContext({ window, location, document, URL, CustomEvent, setTimeout, clearTimeout });
  vm.runInContext(source, context);
  return { window, calls, events, context, handler, pageEvents };
}

test('original 17-member compatibility surface keeps truthful Android capabilities', () => {
  const { window } = boot();
  assert.equal(Object.keys(window.yapperDesktop).length, 17);
  assert.equal(window.yapperDesktop.platform, 'android');
  assert.ok(Object.isFrozen(window.yapperDesktop));
  assert.ok(Object.isFrozen(window.yapperAndroid.capabilities));
  for (const key of ['badges', 'backgroundPush', 'screenPicker', 'screenCapture', 'systemAudioCapture', 'globalHotkeys', 'activityDetection', 'runningPrograms', 'systemIdle', 'automaticUpdates'])
    assert.equal(window.yapperAndroid.capabilities[key], false, key);
  assert.equal(Object.getOwnPropertyDescriptor(window, 'yapperDesktop').writable, false);
});
test('installs only on the four exact HTTPS app origins in the main frame', () => {
  for (const host of ['www.yapper.website', 'yapper.website', 'www.yapin.gg', 'yapin.gg']) assert.ok(boot({ url: `https://${host}:443/` }).window.yapperAndroid);
  for (const url of ['http://www.yapper.website/', 'https://www.yapper.website:8443/', 'https://www.yapper.website.attacker.test/', 'https://user@www.yapper.website/', 'https://rt.yapper.website/', 'https://lk.yapper.website/', 'file:///tmp/page', 'about:blank'])
    assert.equal(boot({ url }).window.yapperDesktop, undefined, url);
  assert.equal(boot({ frame: true }).window.yapperDesktop, undefined);
});
test('repeated injection preserves the existing bridge', () => {
  const { window, context } = boot(); const initial = window.yapperAndroid;
  vm.runInContext(source, context); assert.equal(window.yapperAndroid, initial);
});
test('native settings cannot manufacture desktop features', async () => {
  const { window } = boot({ reply: { nativeNotifications: true, platform: 'win32', activity: true, openAtLogin: true } });
  const settings = await window.yapperDesktop.getSettings();
  assert.equal(settings.platform, 'android'); assert.equal(settings.nativeNotifications, true);
  assert.equal(settings.activity, false); assert.equal(settings.openAtLogin, false); assert.equal(settings.closeToTray, false);
});
test('settings forward only explicit Boolean notification consent', async () => {
  const { window, calls } = boot();
  for (const input of [null, [], { activity: true }, { nativeNotifications: 'yes' }]) assert.equal(await window.yapperDesktop.setSettings(input), false);
  assert.equal(await window.yapperDesktop.setSettings({ nativeNotifications: true, activity: true }), true);
  assert.deepEqual(calls.map(call => [call.method, call.args]), [['setSettings', { nativeNotifications: true }]]);
});
test('notifications bound text and keep destination on the current origin', async () => {
  const { window, calls } = boot();
  await window.yapperDesktop.notify({ title: 'x'.repeat(300), body: 'y'.repeat(3000), url: '/?channel=hello#latest' });
  assert.equal(calls[0].args.title.length, 180); assert.equal(calls[0].args.body.length, 2000);
  assert.equal(calls[0].args.url, '/?channel=hello#latest');
  for (const url of ['https://attacker.test/', '//attacker.test/', 'javascript:alert(1)', 'https://user@www.yapper.website/', 'https://www.yapper.website//attacker.test/']) await window.yapperDesktop.notify({ url });
  for (const call of calls.slice(1)) assert.equal(call.args.url, '/');
});
test('missing or throwing native handler never grants permission', async () => {
  for (const options of [{ native: false }, { throws: true }, { reply: false }]) {
    const { window } = boot(options);
    assert.equal(await window.yapperDesktop.notify({}), false);
    assert.equal(await window.yapperDesktop.setSettings({ nativeNotifications: true }), false);
    assert.equal((await window.yapperDesktop.getSettings()).nativeNotifications, false);
  }
});
test('pagehide settles pending requests and stale/native unknown IDs do not resolve another call', async () => {
  const { window, handler, calls, pageEvents } = boot({ defer: true });
  let resolved = false; const pending = window.yapperDesktop.setSettings({ nativeNotifications: true }).then(result => { resolved = true; return result; });
  handler.onmessage({ data: JSON.stringify({ id: 'unknown', result: true }) }); await Promise.resolve();
  assert.equal(resolved, false); assert.equal(calls.length, 1);
  pageEvents.pagehide(); assert.equal(await pending, false);
});
test('unsupported desktop APIs never call native', async () => {
  const { window, calls } = boot(); const api = window.yapperDesktop;
  assert.equal(await api.setBadge(9), false); assert.equal(api.screenPicker, false);
  assert.deepEqual(plain(await api.screenSources()), []); assert.equal(await api.pickScreenSource(), false);
  assert.equal(await api.installUpdate(), false); assert.deepEqual(plain(await api.listPrograms()), []);
  assert.deepEqual(plain(await api.setHotkeys({ ptt: 'Space' })), { ptt: false, keys: false });
  for (const method of ['onUpdateReady', 'onPtt', 'onHotkey', 'onSystemIdle']) assert.equal(typeof api[method](() => {}), 'function');
  assert.equal(calls.length, 0);
});
test('lifecycle subscribers receive bounded events and unsubscribe', () => {
  const { window, events } = boot(); const seen = [];
  const unsubscribe = window.yapperAndroid.onLifecycle(value => seen.push(value));
  window.yapperAndroid.onLifecycle(() => { throw new Error('Page callback'); });
  assert.equal(window.__yapperNativeEvent('lifecycle', { state: 'invalid' }), false);
  assert.equal(window.__yapperNativeEvent('lifecycle', { state: 'active', secret: true }), true);
  assert.deepEqual(plain(seen), [{ state: 'active' }]); assert.ok(Object.isFrozen(seen[0]));
  assert.equal(events[0].type, 'yapper:android:lifecycle'); unsubscribe();
  window.__yapperNativeEvent('lifecycle', { state: 'background' }); assert.equal(seen.length, 1);
});
test('activity clears inherited desktop state once and can be cancelled', async () => {
  const { window } = boot(); const calls = [];
  window.yapperDesktop.onActivity((...args) => calls.push(args));
  window.yapperDesktop.onActivity(() => assert.fail('Cancelled callback'))();
  await Promise.resolve(); assert.deepEqual(calls, [[null, undefined]]);
});
