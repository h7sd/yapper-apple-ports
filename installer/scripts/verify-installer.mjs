import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { access, mkdir, mkdtemp, open, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'darwin') throw new Error('Verification requires macOS.');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const filename = process.argv[2];
if (!filename || process.argv.length !== 3) throw new Error('Usage: node scripts/verify-installer.mjs /path/installer-or-setup.zip');
const archive = path.resolve(filename);
const name = path.basename(archive);
const variant = /^Yapinplugger-Setup-0\.1\.0-mac-(arm64|x64)\.zip$/.exec(name)?.[1];
assert.ok(variant || name === 'Yapinplugger-Installer-0.1.0-mac-universal.zip', 'Unexpected installer artifact name');
const staging = await mkdtemp(path.join(os.tmpdir(), 'yapinplugger-verify-'));
const report = { schemaVersion: 1, artifact: name, passed: false, checks: [], limitations: ['No installer GUI interaction or real installation is performed.', 'Ad-hoc signatures do not identify a trusted publisher; these checks are not a malware-free guarantee.'] };

// Bounded, non-executing ASAR reads independently compare shipped script bytes.
async function packedMember(archivePath, member) {
  const file = await open(archivePath, 'r');
  try {
    const total = (await file.stat()).size;
    const prefix = Buffer.alloc(8);
    assert.equal((await file.read(prefix, 0, 8, 0)).bytesRead, 8, 'Truncated ASAR prefix');
    assert.equal(prefix.readUInt32LE(0), 4, 'Invalid ASAR header');
    const headerSize = prefix.readUInt32LE(4);
    assert.ok(headerSize >= 8 && headerSize <= 16 * 1024 * 1024 && 8 + headerSize <= total, 'ASAR header exceeds bound');
    const header = Buffer.alloc(headerSize);
    assert.equal((await file.read(header, 0, headerSize, 8)).bytesRead, headerSize);
    const jsonSize = header.readUInt32LE(4);
    assert.ok(jsonSize <= headerSize - 8);
    let entry = JSON.parse(header.subarray(8, 8 + jsonSize).toString('utf8'));
    for (const component of member.split('/')) {
      assert.ok(component !== '.' && component !== '..');
      entry = entry.files?.[component];
      assert.ok(entry, 'Missing required packed script');
    }
    assert.ok(!entry.unpacked && !entry.link && /^\d+$/.test(entry.offset), 'Required script is not packed');
    const offset = Number(entry.offset);
    assert.ok(Number.isSafeInteger(offset) && Number.isSafeInteger(entry.size) && entry.size > 0 && entry.size <= 16 * 1024 * 1024);
    const start = 8 + headerSize + offset;
    assert.ok(Number.isSafeInteger(start) && start >= 8 + headerSize && start + entry.size <= total, 'ASAR member exceeds archive');
    const bytes = Buffer.alloc(entry.size);
    assert.equal((await file.read(bytes, 0, bytes.length, start)).bytesRead, bytes.length);
    return bytes;
  } finally {
    await file.close();
  }
}

try {
  execFileSync('/usr/bin/ditto', ['-x', '-k', archive, staging], { stdio: 'pipe' });
  const app = path.join(staging, 'Yapinplugger.app');
  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], { stdio: 'pipe' });
  const signature = spawnSync('/usr/bin/codesign', ['-d', '-vv', app], { encoding: 'utf8' });
  assert.equal(signature.status, 0);
  assert.match(signature.stderr, /Signature=adhoc/);
  report.checks.push('Extracted installer and nested code signatures verify; installer is ad-hoc signed');
  const executable = path.join(app, 'Contents', 'MacOS', 'Yapinplugger');
  for (const key of ['CFBundleName', 'CFBundleDisplayName', 'CFBundleExecutable']) {
    assert.equal(execFileSync('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, path.join(app, 'Contents', 'Info.plist')], { encoding: 'utf8' }).trim(), 'Yapinplugger');
  }
  const architectures = execFileSync('/usr/bin/lipo', ['-archs', executable], { encoding: 'utf8' }).trim().split(/\s+/).sort();
  assert.deepEqual(architectures, ['arm64', 'x86_64']);
  assert.equal(execFileSync(executable, ['--version'], { encoding: 'utf8' }).trim(), '0.1.0');
  report.checks.push('Universal arm64/x86_64 native installer and CLI version 0.1.0');
  assert.match(await readFile(path.join(app, 'Contents', 'Resources', 'LICENSE.Installer'), 'utf8'), /^MIT License\n/);
  report.checks.push('Installer MIT license and provenance documentation included');
  await access(path.join(app, 'Contents', 'Resources', 'Installer Provenance.md'));
  const bundled = path.join(app, 'Contents', 'Resources', 'Yapper.app');
  let containsApp = true;
  try { await access(bundled); } catch { containsApp = false; }
  assert.equal(containsApp, Boolean(variant), 'Setup must contain a client; standalone artifact must not');
  if (containsApp) {
    const inspection = JSON.parse(execFileSync(executable, ['inspect', '--app', bundled], { encoding: 'utf8' }));
    assert.equal(inspection.yapinpluggerVersion, '0.1.0');
    assert.equal(inspection.runtimeBundleSHA256, 'de53f573bfa5fb3fdbcd8d35e710ef5805bae60284603a519c7c3850ab28e2a7');
    const arch = execFileSync('/usr/bin/lipo', ['-archs', path.join(bundled, 'Contents', 'MacOS', 'Yapper')], { encoding: 'utf8' }).trim();
    assert.equal(arch, variant === 'x64' ? 'x86_64' : 'arm64');
    report.clientArchitecture = variant;
    report.clientASARSHA256 = inspection.asarSHA256;
    report.yapinpluggerBundleSHA256 = inspection.runtimeBundleSHA256;
    const defaultSource = JSON.parse(execFileSync(executable, ['inspect-bundled'], { encoding: 'utf8' }));
    assert.equal(await realpath(defaultSource.path), await realpath(bundled));
    assert.equal(defaultSource.asarSHA256, inspection.asarSHA256);
    report.checks.push('Default source resolves to the included compatible client');
    report.checks.push('Bundled client version marker, architecture, portable links, signatures, and reviewed runtime bundle checksum');
    for (const [directory, expected] of [
      ['yappercord', 'de53f573bfa5fb3fdbcd8d35e710ef5805bae60284603a519c7c3850ab28e2a7'],
      ['appearance', '52c19429daee71e0eda97b95b9605aaf8090367626569df101ce19a2f4a3fdf6']
    ]) {
      const bytes = await packedMember(path.join(bundled, 'Contents', 'Resources', 'app.asar'), `${directory}/bundle.js`);
      const hash = createHash('sha256').update(bytes).digest('hex');
      assert.equal(hash, expected, `Bundled ${directory} script differs from reviewed release`);
      assert.deepEqual(bytes, await readFile(path.join(root, '..', 'macos', directory, 'bundle.js')), `Bundled ${directory} script differs from source`);
      report[directory === 'yappercord' ? 'yapinpluggerBundleSHA256' : 'appearanceBundleSHA256'] = hash;
    }
    report.checks.push('Independent packed-ASAR reads match reviewed Yapinplugger and appearance script hashes and current source bytes');
  }
  const hasher = createHash('sha256');
  for await (const chunk of createReadStream(archive)) hasher.update(chunk);
  report.archiveSHA256 = hasher.digest('hex');
  report.passed = true;
} catch (error) {
  report.error = String(error.message).replaceAll(staging, '<temporary-staging>').replaceAll(os.homedir(), '<home>');
  process.exitCode = 1;
} finally {
  await rm(staging, { recursive: true, force: true });
  await mkdir(path.join(root, 'dist'), { recursive: true });
  const outputName = `verified-${variant || 'standalone'}.json`;
  await writeFile(path.join(root, 'dist', outputName), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report, null, 2));
}
