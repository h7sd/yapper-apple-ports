// Optional, bundled page-only extensions. Never loads code from the user data directory.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

function readEnabled(configFile) {
  try {
    if (fs.statSync(configFile).size > 4096) return false;
    const config = JSON.parse(fs.readFileSync(configFile, 'utf8'));
    return config.schemaVersion === 1 && config.enabled === true;
  } catch { return false; }
}
function writeEnabled(configFile, enabled) {
  if (typeof enabled !== 'boolean') throw new TypeError('enabled must be boolean');
  fs.mkdirSync(path.dirname(configFile), { recursive: true });
  const temporary = `${configFile}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify({ schemaVersion: 1, enabled }, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
  try { fs.renameSync(temporary, configFile); } finally { try { fs.unlinkSync(temporary); } catch {} }
}
function readLayoutEnabled(configFile) {
  return fs.existsSync(configFile) ? readEnabled(configFile) : true;
}
function trustedPage(value) {
  try {
    const u = new URL(value);
    return u.protocol === 'https:' && ['yapper.website', 'www.yapper.website', 'yapin.gg', 'www.yapin.gg'].includes(u.hostname) && (!u.port || u.port === '443') && !u.username && !u.password;
  } catch { return false; }
}
function verifiedSource(root, name) {
  const folder = path.join(root, name);
  const source = fs.readFileSync(path.join(folder, 'bundle.js'), 'utf8');
  const expected = fs.readFileSync(path.join(folder, 'bundle.sha256'), 'utf8').trim().split(/\s+/)[0];
  if (!/^[a-f0-9]{64}$/.test(expected) || crypto.createHash('sha256').update(source).digest('hex') !== expected) throw new Error('Bundled extension checksum mismatch');
  return source;
}
function bundleSource(root = __dirname) { return verifiedSource(root, 'yappercord'); }
function appearanceSource(root = __dirname) { return verifiedSource(root, 'appearance'); }
module.exports = { readEnabled, writeEnabled, readLayoutEnabled, trustedPage, bundleSource, appearanceSource };
