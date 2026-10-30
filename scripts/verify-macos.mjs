import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { access, mkdir, mkdtemp, readFile, readdir, readlink, rm, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const macos = path.join(repository, 'macos');
const dist = path.join(repository, 'dist');
const args = process.argv.slice(2);
const architecture = args.find(arg => arg.startsWith('--arch='))?.slice(7);
if (args.some(arg => !arg.startsWith('--arch=')) || (architecture && !['arm64', 'x64'].includes(architecture))) {
  throw new Error('Usage: node scripts/verify-macos.mjs [--arch=arm64|x64]');
}

const checks = [];
const sourceHashes = {};
let archiveHash;
let temporary = '';
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const publicError = error => String(error?.message || error)
  .replaceAll(repository, '<repository>')
  .replaceAll(os.homedir(), '<home>')
  .replaceAll(temporary || '\0', '<temporary-staging>');

async function check(name, operation) {
  try {
    await operation();
    checks.push({ name, passed: true });
    console.log(`PASS ${name}`);
  } catch (error) {
    checks.push({ name, passed: false, detail: publicError(error) });
    console.error(`FAIL ${name}: ${publicError(error)}`);
  }
}

async function hashFile(filename) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(filename)) hash.update(chunk);
  return hash.digest('hex');
}

async function checkPortableLinks(app, directory = app) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const filename = path.join(directory, entry.name);
    if (entry.isSymbolicLink()) {
      const target = await readlink(filename);
      assert.equal(path.isAbsolute(target), false, 'App symlinks must remain relative');
      const relative = path.relative(app, path.resolve(directory, target));
      assert.ok(relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative), 'App symlink escapes the bundle');
      await access(filename);
    } else if (entry.isDirectory()) await checkPortableLinks(app, filename);
  }
}

const applicationFiles = ['main.js', 'preload.js', 'games.js', 'mac-processes.js', 'yappercord.js', 'yappercord/bundle.js', 'appearance/bundle.js'];
const syntaxFiles = [
  ...applicationFiles,
  'scripts/build-mac.mjs', 'scripts/make-icon.mjs',
  'tests/desktop-main.test.js', 'tests/mac-processes.test.js', 'tests/yappercord.test.js'
];

for (const filename of syntaxFiles) {
  await check(`syntax macos/${filename}`, async () => {
    execFileSync(process.execPath, ['--check', path.join(macos, filename)], { stdio: 'pipe' });
  });
}

const main = await readFile(path.join(macos, 'main.js'), 'utf8');
const preload = await readFile(path.join(macos, 'preload.js'), 'utf8');
const manifest = JSON.parse(await readFile(path.join(macos, 'package.json'), 'utf8'));
const provenance = JSON.parse(await readFile(path.join(macos, 'provenance.json'), 'utf8'));

await check('all declared webPreferences retain sandbox and isolation', () => {
  const preferences = [...main.matchAll(/webPreferences\s*:\s*\{([^}]+)\}/g)].map(match => match[1]);
  assert.equal(preferences.length, 2, 'Review every BrowserWindow and popup when window creation changes');
  for (const preferencesBlock of preferences) {
    assert.match(preferencesBlock, /\bcontextIsolation\s*:\s*true\b/);
    assert.match(preferencesBlock, /\bnodeIntegration\s*:\s*false\b/);
    assert.match(preferencesBlock, /\bsandbox\s*:\s*true\b/);
  }
  assert.doesNotMatch(main, /\b(?:webSecurity|contextIsolation|sandbox)\s*:\s*false\b/);
  assert.doesNotMatch(main, /\b(?:nodeIntegration|allowRunningInsecureContent)\s*:\s*true\b/);
  assert.doesNotMatch(main, /setCertificateVerifyProc|['"]certificate-error['"]/);
});

await check('native bridge retains its HTTPS hostname guard', () => {
  assert.match(main, /return u\.protocol === 'https:' && ALLOWED\.has\(u\.hostname\)/);
  assert.match(main, /return ownUrl\(e\.senderFrame\?\.url \?\? ''\)/);
  assert.match(main, /if \(!ownUrl\(req\.frame\?\.url \|\| req\.securityOrigin\)\) return cb\(\{\}\)/);
  assert.match(main, /ownUrl\(details\.requestingUrl \|\| wc\.getURL\(\)\) && OWN_PERMISSIONS\.includes\(permission\)/);
  const expected = "new Set(['www.yapin.gg', 'yapin.gg', 'www.yapper.website', 'yapper.website', 'rt.yapper.website', 'lk.yapper.website'])";
  assert.ok(main.includes(`const ALLOWED = ${expected};`), 'A trust-host change needs explicit security review');
});

await check('preload exposes the named bridge without a generic IPC or execution API', () => {
  assert.match(preload, /contextBridge\.exposeInMainWorld\('yapperDesktop', \{/);
  assert.doesNotMatch(preload, /(?:exposeInMainWorld\(['"](?:require|process|ipcRenderer)|(?:eval|exec|execFile|spawn)\s*\()/);
  const channels = [...main.matchAll(/ipcMain\.handle\('([^']+)'/g)].map(match => match[1]).sort();
  assert.deepEqual(channels, [
    'yapper:hotkeys', 'yapper:programs', 'yapper:screen-pick', 'yapper:screen-sources',
    'yapper:settings-get', 'yapper:settings-set', 'yapper:update-install'
  ].sort(), 'Review the native capability list whenever a handler is added');
});

await check('Mac binary updates remain disabled', () => {
  assert.match(main, /autoUpdater\.autoDownload = !IS_MAC;/);
  assert.match(main, /autoUpdater\.autoInstallOnAppQuit = !IS_MAC;/);
  assert.match(main, /if \(!IS_MAC\) \{\s*setTimeout\(check, 10_000\);\s*setInterval\(check, 4 \* 3600_000\);/);
});

await check('runtime and packaging dependencies remain pinned', async () => {
  assert.equal(manifest.devDependencies.electron, '45.1.0');
  assert.equal(manifest.devDependencies['@electron/packager'], '20.3.0');
  assert.equal(manifest.dependencies['electron-updater'], '6.8.9');
  assert.equal(manifest.dependencies['uiohook-napi'], '1.5.5');
  const lock = JSON.parse(await readFile(path.join(macos, 'package-lock.json'), 'utf8'));
  for (const [name, version] of Object.entries({ ...manifest.dependencies, ...manifest.devDependencies })) {
    assert.equal(lock.packages[`node_modules/${name}`].version, version);
  }
});

await check('preserved upstream files and assets match recorded hashes', async () => {
  for (const [filename, expected] of Object.entries(provenance.upstream_files)) {
    assert.equal(await hashFile(path.join(macos, 'upstream', filename)), expected, `upstream/${filename}`);
  }
  for (const [filename, expected] of Object.entries(provenance.unchanged_port_files)) {
    const actual = filename === 'icon.png' ? path.join(macos, 'build', filename) : path.join(macos, filename);
    assert.equal(await hashFile(actual), expected, filename);
  }
  for (const filename of applicationFiles) sourceHashes[filename] = await hashFile(path.join(macos, filename));
});

if (architecture) {
  await check(`archive content, architecture, and signatures (${architecture})`, async () => {
    assert.equal(process.platform, 'darwin', 'Archive verification requires macOS codesign, lipo, plutil, and ditto');
    const archiveName = `Yapper-${manifest.version}${manifest.yappercordVersion ? '-YapperCord-' + manifest.yappercordVersion : ''}-mac-${architecture}.zip`;
    const archive = path.join(dist, archiveName);
    archiveHash = await hashFile(archive);
    temporary = await mkdtemp(path.join(os.tmpdir(), 'yapper-verification-'));
    try {
      execFileSync('/usr/bin/ditto', ['-x', '-k', archive, temporary], { stdio: 'pipe' });
      const app = path.join(temporary, 'Yapper.app');
      await checkPortableLinks(app);
      execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], { stdio: 'pipe' });
      const signature = spawnSync('/usr/bin/codesign', ['--display', '--verbose=2', app], { encoding: 'utf8' });
      assert.equal(signature.status, 0);
      assert.match(signature.stderr, /Signature=adhoc/);
      assert.match(signature.stderr, /flags=.*\badhoc,runtime\b/);
      assert.match(signature.stderr, /TeamIdentifier=not set/);
      const executable = path.join(app, 'Contents', 'MacOS', 'Yapper');
      const actualArch = execFileSync('/usr/bin/lipo', ['-archs', executable], { encoding: 'utf8' }).trim();
      assert.equal(actualArch, architecture === 'x64' ? 'x86_64' : 'arm64');
      const info = path.join(app, 'Contents', 'Info.plist');
      const bundleID = execFileSync('/usr/bin/plutil', ['-extract', 'CFBundleIdentifier', 'raw', '-o', '-', info], { encoding: 'utf8' }).trim();
      assert.equal(bundleID, 'website.yapper.desktop');
      const frameworkInfo = path.join(app, 'Contents', 'Frameworks', 'Electron Framework.framework', 'Resources', 'Info.plist');
      const runtimeVersion = execFileSync('/usr/bin/plutil', ['-extract', 'CFBundleVersion', 'raw', '-o', '-', frameworkInfo], { encoding: 'utf8' }).trim();
      assert.equal(runtimeVersion, manifest.devDependencies.electron);
      const requireMacos = createRequire(path.join(macos, 'package.json'));
      const { extractFile, listPackage } = await import(pathToFileURL(requireMacos.resolve('@electron/asar')).href);
      const asar = path.join(app, 'Contents', 'Resources', 'app.asar');
      for (const filename of applicationFiles) assert.equal(sha256(extractFile(asar, filename)), sourceHashes[filename], filename);
      const members = listPackage(asar);
      const nativeMembers = members.filter(filename => filename.endsWith('.node'));
      assert.deepEqual(nativeMembers, [`/node_modules/uiohook-napi/prebuilds/darwin-${architecture}/uiohook-napi.node`]);
      assert.ok(!members.some(filename => /^\/(?:tests|scripts|upstream|evidence)\//.test(filename)));
      assert.ok(!members.some(filename => /^\/node_modules\/(?:electron\/|@electron\/packager\/)/.test(filename)));
      const nativeFile = path.join(app, 'Contents', 'Resources', 'app.asar.unpacked', nativeMembers[0].slice(1));
      const nativeArch = execFileSync('/usr/bin/lipo', ['-archs', nativeFile], { encoding: 'utf8' }).trim();
      assert.equal(nativeArch, actualArch);
      await writeFile(path.join(dist, `SHA256SUMS-${architecture}.txt`), `${archiveHash}  ${archiveName}\n`);
    } finally {
      await rm(temporary, { recursive: true, force: true });
    }
  });
  await check(`loose app has portable, non-dangling symlinks (${architecture})`, () =>
    checkPortableLinks(path.join(dist, `Yapper-darwin-${architecture}`, 'Yapper.app')));
}

await mkdir(dist, { recursive: true });
const report = {
  scope: 'Source invariants and optional macOS archive consistency; no malware-free certification',
  generatedAt: new Date().toISOString(),
  node: process.versions.node,
  architecture: architecture || null,
  declaredElectron: manifest.devDependencies.electron,
  passed: checks.every(entry => entry.passed),
  checks,
  sourceSHA256: sourceHashes,
  ...(archiveHash ? { archiveSHA256: archiveHash } : {}),
  limitations: [
    'Source guards check selected known invariants and are not a complete static security analysis.',
    'Regression tests, dependency advisory results, native permission flows, and live-service behavior have separate scopes.',
    'No application launch, real call, media recording, Accessibility grant, or login-item change is performed by this script.',
    'The live website and its network requests can change independently of these source and archive hashes.',
    'Checksums show integrity relative to this build; ad-hoc signatures do not identify a trusted publisher.'
  ]
};
await writeFile(path.join(dist, `macos-verification-${architecture || 'source'}.json`), `${JSON.stringify(report, null, 2)}\n`);
process.exitCode = report.passed ? 0 : 1;
