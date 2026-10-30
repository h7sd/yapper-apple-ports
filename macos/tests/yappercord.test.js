const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { readEnabled, writeEnabled, readLayoutEnabled, trustedPage, bundleSource } = require('../yappercord');
test('extension opt-in defaults off and round-trips atomically', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'yappercord-test-'));
  try {
    const file = path.join(dir, 'profile/yappercord.json');
    assert.equal(readEnabled(file), false);
    assert.equal(readLayoutEnabled(file), true);
    writeEnabled(file, true); assert.equal(readEnabled(file), true);
    writeEnabled(file, false); assert.equal(readEnabled(file), false);
    assert.equal(readLayoutEnabled(file), false);
    fs.writeFileSync(file, '{broken'); assert.equal(readEnabled(file), false);
    fs.writeFileSync(file, '{"enabled":true}'); assert.equal(readEnabled(file), false);
    assert.throws(() => writeEnabled(file, 'true'));
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
test('native extension guard excludes remote popups, credentials and nonstandard ports', () => {
  assert(trustedPage('https://yapin.gg/'));
  for (const url of ['https://discord.com', 'https://rt.yapper.website', 'https://yapin.gg:444', 'https://u:p@yapin.gg', 'file:///index.html', 'data:text/html,x']) assert.equal(trustedPage(url), false);
});
test('bundle integrity check rejects corruption', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'yappercord-bundle-'));
  try {
    fs.mkdirSync(path.join(root, 'yappercord'));
    const source = '/* local reviewed code */';
    fs.writeFileSync(path.join(root, 'yappercord/bundle.js'), source);
    fs.writeFileSync(path.join(root, 'yappercord/bundle.sha256'), crypto.createHash('sha256').update(source).digest('hex') + '  bundle.js\n');
    assert.equal(bundleSource(root), source);
    fs.appendFileSync(path.join(root, 'yappercord/bundle.js'), 'corrupt');
    assert.throws(() => bundleSource(root), /mismatch/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
