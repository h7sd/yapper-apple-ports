import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { access, mkdtemp, readFile, readdir, readlink, rm, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { extractAll, extractFile, listPackage } from '@electron/asar';
import { NtExecutable, NtExecutableResource, Resource } from 'resedit';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repo = path.dirname(root);
const require = createRequire(import.meta.url);
const sha256 = data => createHash('sha256').update(data).digest('hex');
const temporary = await mkdtemp(path.join(os.tmpdir(), 'yapinplugger-desktop-verify-'));
const checks = [];
function check(name, callback) { callback(); checks.push(name); }
function elf(bytes) {
  assert.equal(bytes.subarray(0, 4).toString('hex'), '7f454c46');
  assert.equal(bytes[4], 2, '64-bit ELF'); assert.equal(bytes[5], 1, 'Little-endian ELF');
  assert.equal(bytes.readUInt16LE(18), 62, 'x86-64 ELF machine');
}
function pe(bytes) {
  assert.equal(bytes.subarray(0, 2).toString(), 'MZ');
  const offset = bytes.readUInt32LE(0x3c);
  assert.equal(bytes.subarray(offset, offset + 4).toString('hex'), '50450000');
  assert.equal(bytes.readUInt16LE(offset + 4), 0x8664, 'AMD64 PE machine');
}
async function links(directory, base = directory) {
  for (const item of await readdir(directory, { withFileTypes: true })) {
    const file = path.join(directory, item.name);
    if (!item.isSymbolicLink()) assert.equal((await stat(file)).mode & 0o6022, 0, `Package entry is writable by others or setuid/setgid: ${file}`);
    if (item.isSymbolicLink()) {
      const target = await readlink(file);
      assert.equal(path.isAbsolute(target), false);
      const relative = path.relative(base, path.resolve(directory, target));
      assert.ok(relative !== '..' && !relative.startsWith(`..${path.sep}`));
      await access(file);
    } else if (item.isDirectory()) await links(file, base);
  }
}
try {
  for (const platform of ['linux', 'win32']) {
    const report = JSON.parse(await readFile(path.join(root, 'reports', `build-${platform}-x64.json`), 'utf8'));
    const app = path.join(repo, 'dist', `Yapinplugger-${platform}-x64`);
    const asar = path.join(app, 'resources', 'app.asar');
    const binary = await readFile(path.join(app, platform === 'linux' ? 'yapinplugger' : 'Yapinplugger.exe'));
    check(`${platform}: actual target executable header`, () => platform === 'linux' ? elf(binary) : pe(binary));
    if (platform === 'win32') {
      const resources = NtExecutableResource.from(NtExecutable.from(binary));
      const icon = (await readFile(path.join(root, 'build', 'icon.ico'))).subarray(22);
      check('Windows: executable product identity and Yapper icon resources', () => {
        const info = Resource.VersionInfo.fromEntries(resources.entries)[0];
        const values = info.getStringValues(info.getAllLanguagesForStringValues()[0]);
        assert.equal(values.ProductName, 'Yapinplugger');
        assert.equal(values.FileDescription, 'Yapinplugger community Yapper client');
        assert.ok(resources.entries.some(entry => entry.type === 3 && sha256(Buffer.from(entry.bin)) === sha256(icon)));
      });
      await access(path.join(app, 'LICENSE.NSIS'));
      checks.push('Windows: NSIS component notices included');
    }
    const names = listPackage(asar).map(name => name.replaceAll('\\', '/'));
    for (const [filename, expected] of Object.entries(report.sourceHashes)) {
      const bytes = extractFile(asar, filename);
      const current = await readFile(path.join(repo, 'macos', filename));
      check(`${platform}: current shared source ${filename}`, () => {
        assert.equal(sha256(bytes), expected);
        assert.equal(sha256(bytes), sha256(current));
      });
    }
    const extracted = path.join(temporary, platform);
    extractAll(asar, extracted);
    const addon = require(path.join(extracted, 'yappercord.js'));
    check(`${platform}: real addon checksum loader accepts BOTH bundled resources`, () => {
      assert.ok(addon.bundleSource(extracted).includes('Yapinplugger'));
      assert.ok(addon.appearanceSource(extracted).includes('YapperAppearance'));
      assert.equal(addon.readEnabled(path.join(temporary, 'absent-preference.json')), false);
      assert.equal(addon.readLayoutEnabled(path.join(temporary, 'absent-preference.json')), true);
    });
    const prebuildRoot = path.join(app, 'resources', 'app.asar.unpacked', 'node_modules', 'uiohook-napi', 'prebuilds');
    check(`${platform}: only the correct native hook prebuild is present`, () => assert.deepEqual(names.filter(name => /prebuilds\/[^/]+\/uiohook-napi\.node$/.test(name)), [`/node_modules/uiohook-napi/prebuilds/${platform}-x64/uiohook-napi.node`]));
    const native = await readFile(path.join(prebuildRoot, `${platform}-x64`, 'uiohook-napi.node'));
    check(`${platform}: unpacked hook has the target executable format`, () => platform === 'linux' ? elf(native) : pe(native));
    const main = extractFile(asar, 'main.js').toString('utf8');
    check(`${platform}: sandbox, origin guard and manual-only updates remain enabled`, () => {
      assert.match(main, /contextIsolation: true/); assert.match(main, /sandbox: true/);
      assert.match(main, /nodeIntegration: false/);
      assert.match(main, /autoUpdater\.autoDownload = false/);
      assert.match(main, /autoUpdater\.autoInstallOnAppQuit = false/);
      assert.doesNotMatch(main, /checkForUpdatesAndNotify\s*\(/);
      assert.match(main, /!u\.username && !u\.password/);
      assert.match(main, /u\.port === '443'/);
    });
    check(`${platform}: build tooling was pruned`, () => assert.equal(names.some(name => /^\/node_modules\/(?:electron|@electron\/packager|resedit)\//.test(name)), false));
    await links(app);
    checks.push(`${platform}: relative internal links only`);
    for (const filename of ['LICENSE', 'LICENSES.chromium.html', 'LICENSE.Vencord', 'YAPINPLUGGER-PROVENANCE.json']) await access(path.join(app, filename));
    checks.push(`${platform}: runtime and addon license notices included`);
    for (const artifact of report.artifacts) {
      const bytes = await readFile(path.join(repo, 'dist', artifact.name));
      check(`${platform}: artifact digest ${artifact.name}`, () => { assert.equal(bytes.length, artifact.bytes); assert.equal(sha256(bytes), artifact.sha256); });
      if (artifact.name.endsWith('.zip')) execFileSync('unzip', ['-tq', path.join(repo, 'dist', artifact.name)]);
      if (artifact.name.endsWith('.tar.gz')) execFileSync('tar', ['-tzf', path.join(repo, 'dist', artifact.name)], { maxBuffer: 2e6 });
      if (artifact.name.endsWith('-Setup.exe')) check('Windows: NSIS installer PE format', () => {
        assert.equal(bytes.subarray(0, 2).toString(), 'MZ');
        const peOffset = bytes.readUInt32LE(0x3c);
        assert.equal(bytes.subarray(peOffset, peOffset + 4).toString('hex'), '50450000');
      });
    }
    if (platform === 'linux') {
      const image = report.artifacts.find(file => file.name.endsWith('.AppImage'));
      const filename = path.join(repo, 'dist', image.name);
      const runtime = report.appImageRuntime;
      const bytes = await readFile(filename);
      check('Linux: AppImage runtime pin and embedded filesystem signature', () => {
        assert.equal(sha256(bytes.subarray(0, runtime.offset)), runtime.sha256);
        assert.equal(bytes.subarray(runtime.offset, runtime.offset + 4).toString(), 'hsqs');
      });
      const extractedImage = path.join(temporary, 'AppDir');
      execFileSync('unsquashfs', ['-q', '-o', String(runtime.offset), '-d', extractedImage, filename]);
      check('Linux: actual embedded ASAR equals the verified package', () => assert.equal(sha256(extractFile(path.join(extractedImage, 'resources', 'app.asar'), 'main.js')), report.sourceHashes['main.js']));
      const runtimeNotice = await readFile(path.join(extractedImage, 'LICENSE.AppImage-runtime'));
      check('Linux: AppImage runtime notices preserved inside the actual image', () => assert.ok(runtimeNotice.toString().includes('Copyright (c) 2004-23 probonopd')));
      const launcher = await readFile(path.join(extractedImage, 'AppRun'), 'utf8');
      check('Linux: launcher keeps Chromium sandbox intact', () => assert.doesNotMatch(launcher.replace(/^#.*$/gm, ''), /--no-sandbox/));
      assert.ok((await stat(path.join(extractedImage, 'AppRun'))).mode & 0o111);
      execFileSync('sh', ['-n', path.join(app, 'install-desktop.sh')]);
      checks.push('Linux: executable AppRun and valid local-integration shell script');
    }
  }
  execFileSync(process.execPath, ['--test', 'macos/tests/desktop-main.test.js'], { cwd: repo, stdio: 'inherit' });
  checks.push('18 main-process regression tests with mocked platform APIs');
  const result = { status: 'passed', checks, count: checks.length, targetDesktopRuntimeTested: false, scope: 'Cross-platform packaging, actual PE/ELF headers, archive integrity, pinned shared code and native prebuilds; mocked bridge regression. No Windows/Linux runtime or hardware calls were executed.' };
  await writeFile(path.join(root, 'reports', 'verification.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(`${checks.length} desktop package checks passed. Target desktop execution is not claimed.`);
} finally { await rm(temporary, { recursive: true, force: true }); }
