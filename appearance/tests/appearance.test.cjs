// SPDX-License-Identifier: MIT
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');
const { trustedURL, CSS, VERSION } = require('../appearance.js');
const source = fs.readFileSync(path.join(__dirname, '../appearance.js'), 'utf8');

test('only exact main-app HTTPS origins with no credentials or alternate port are trusted', () => {
  for (const host of ['yapper.website', 'www.yapper.website', 'yapin.gg', 'www.yapin.gg']) assert.equal(trustedURL(`https://${host}/`), true);
  assert.equal(trustedURL('https://yapin.gg:443/'), true);
  for (const url of ['http://yapin.gg/', 'https://yapin.gg:444/', 'https://yapin.gg.evil.example/', 'https://user:password@yapin.gg/', 'file:///index.html', 'javascript:alert(1)']) assert.equal(trustedURL(url), false);
});

test('untrusted documents and subframes install no API, style, or observers', () => {
  for (const options of [{ url: 'https://evil.example/', frame: false }, { url: 'https://yapin.gg/', frame: true }]) {
    const window = { location: { href: options.url } }; window.top = options.frame ? {} : window;
    vm.runInNewContext(source, { window, URL });
    assert.equal(window.YapperAppearance, undefined);
  }
});

test('stylesheet inherits the original palette, fonts and user artwork without network styles', () => {
  assert.equal(VERSION, '0.1.0');
  for (const token of ['--bg-side', '--text', '--text-muted', '--border', '--accent']) assert.ok(CSS.includes(`var(${token}`));
  assert.ok(CSS.includes('env(safe-area-inset-bottom)'));
  assert.ok(CSS.includes('prefers-reduced-motion'));
  assert.doesNotMatch(CSS, /url\s*\(|@import|@font-face|font-family\s*:|#[a-f\d]{3,8}\b/i);
  assert.doesNotMatch(source, /\b(?:fetch|XMLHttpRequest|WebSocket|localStorage|sessionStorage)\s*(?:\(|\.)/);
  assert.doesNotMatch(source, /innerHTML\s*=|cloneNode\s*\(|__react|\.removeChild\s*\(/);
});
