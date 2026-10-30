import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmod, copyFile, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'darwin') throw new Error('The native installer must be built on macOS with Xcode.');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dist = path.join(root, 'dist');
const version = '0.1.0';
const args = process.argv.slice(2);
if (args.some(arg => !arg.startsWith('--yapper-app=') && !arg.startsWith('--yapper-zip=') && !arg.startsWith('--client-arch=') && arg !== '--archive-only')) throw new Error('Usage: node scripts/build-installer.mjs [--yapper-app=/path/Yapper.app | --yapper-zip=/path/built-yapper.zip] [--client-arch=arm64|x64] [--archive-only]');
const archiveOnly = args.includes('--archive-only');
const selectedApp = args.find(arg => arg.startsWith('--yapper-app='))?.slice(13);
const selectedZip = args.find(arg => arg.startsWith('--yapper-zip='))?.slice(13);
const requestedClientArch = args.find(arg => arg.startsWith('--client-arch='))?.slice(14);
if (selectedApp && selectedZip) throw new Error('Select either a locally built app or a locally built ZIP.');
if (requestedClientArch && !['arm64', 'x64'].includes(requestedClientArch)) throw new Error('Client architecture must be arm64 or x64.');
if (requestedClientArch && !selectedApp && !selectedZip) throw new Error('A client architecture requires a selected app or ZIP.');

execFileSync('/usr/bin/xcrun', ['swift', 'test', '--package-path', root], { stdio: 'inherit' });
const binaries = [];
for (const arch of ['arm64', 'x86_64']) {
  const options = ['swift', 'build', '--package-path', root, '--scratch-path', path.join(root, `.build-${arch}`), '-c', 'release', '--triple', `${arch}-apple-macosx13.0`, '--product', 'Yapinplugger'];
  execFileSync('/usr/bin/xcrun', options, { stdio: 'inherit' });
  const binPath = execFileSync('/usr/bin/xcrun', [...options, '--show-bin-path'], { encoding: 'utf8' }).trim().split('\n').at(-1);
  binaries.push(path.join(binPath, 'Yapinplugger'));
}

await mkdir(dist, { recursive: true });
const staging = await mkdtemp(path.join(os.tmpdir(), 'yapinplugger-installer-'));
try {
  const app = path.join(staging, 'Yapinplugger.app');
  const contents = path.join(app, 'Contents');
  const executable = path.join(contents, 'MacOS', 'Yapinplugger');
  await mkdir(path.dirname(executable), { recursive: true });
  await mkdir(path.join(contents, 'Resources'), { recursive: true });
  execFileSync('/usr/bin/lipo', ['-create', ...binaries, '-output', executable], { stdio: 'inherit' });
  await chmod(executable, 0o755);
  const info = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>website.yapper.yapinplugger</string>
<key>CFBundleName</key><string>Yapinplugger</string>
<key>CFBundleDisplayName</key><string>Yapinplugger</string>
<key>CFBundleExecutable</key><string>Yapinplugger</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>${version}</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>`;
  await writeFile(path.join(contents, 'Info.plist'), info);
  let source = selectedApp ? path.resolve(selectedApp) : null;
  let clientArch;
  let clientInspection;
  if (selectedZip) {
    const unpacked = path.join(staging, 'selected-build');
    await mkdir(unpacked);
    execFileSync('/usr/bin/ditto', ['-x', '-k', path.resolve(selectedZip), unpacked], { stdio: 'inherit' });
    source = path.join(unpacked, 'Yapper.app');
  }
  if (source) {
    clientInspection = JSON.parse(execFileSync(executable, ['inspect', '--app', source], { encoding: 'utf8' }));
    const nativeArch = execFileSync('/usr/bin/lipo', ['-archs', path.join(source, 'Contents', 'MacOS', 'Yapper')], { encoding: 'utf8' }).trim();
    clientArch = nativeArch === 'x86_64' ? 'x64' : nativeArch;
    if (!['arm64', 'x64'].includes(clientArch) || (requestedClientArch && requestedClientArch !== clientArch)) throw new Error('Bundled client does not match the selected architecture.');
    const bundled = path.join(contents, 'Resources', 'Yapper.app');
    execFileSync('/usr/bin/ditto', ['--rsrc', '--extattr', '--qtn', source, bundled], { stdio: 'inherit' });
    const bundledInspection = JSON.parse(execFileSync(executable, ['inspect', '--app', bundled], { encoding: 'utf8' }));
    if (clientInspection.asarSHA256 !== bundledInspection.asarSHA256 || clientInspection.runtimeBundleSHA256 !== bundledInspection.runtimeBundleSHA256) throw new Error('Bundled app differs from the selected compatible build.');
  }
  await copyFile(path.join(root, 'README.md'), path.join(contents, 'Resources', 'Installer README.md'));
  await copyFile(path.join(root, 'PROVENANCE.md'), path.join(contents, 'Resources', 'Installer Provenance.md'));
  await copyFile(path.join(root, 'LICENSE'), path.join(contents, 'Resources', 'LICENSE.Installer'));
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--options', 'runtime', '--timestamp=none', app], { stdio: 'inherit' });
  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], { stdio: 'inherit' });
  execFileSync(executable, ['--version'], { stdio: 'inherit' });
  const architecture = execFileSync('/usr/bin/lipo', ['-archs', executable], { encoding: 'utf8' }).trim();
  if (!architecture.includes('arm64') || !architecture.includes('x86_64')) throw new Error('Installer binary is not universal.');
  const name = clientArch ? `Yapinplugger-Setup-${version}-mac-${clientArch}.zip` : `Yapinplugger-Installer-${version}-mac-universal.zip`;
  const archive = path.join(dist, name);
  await rm(archive, { force: true });
  execFileSync('/usr/bin/ditto', ['-c', '-k', '--keepParent', '--sequesterRsrc', app, archive], { stdio: 'inherit' });
  const appFolder = clientArch ? path.join(dist, `setup-${clientArch}`) : dist;
  await mkdir(appFolder, { recursive: true });
  const finalApp = path.join(appFolder, 'Yapinplugger.app');
  if (!archiveOnly) {
    await rm(finalApp, { recursive: true, force: true });
    execFileSync('/usr/bin/ditto', ['-x', '-k', archive, appFolder], { stdio: 'inherit' });
  }
  const hash = createHash('sha256').update(await readFile(archive)).digest('hex');
  const checksumLines = [];
  for (const filename of (await readdir(dist)).filter(item => /^Yapinplugger-(Installer|Setup)-.+\.zip$/.test(item)).sort()) {
    checksumLines.push(`${createHash('sha256').update(await readFile(path.join(dist, filename))).digest('hex')}  ${filename}`);
  }
  await writeFile(path.join(dist, 'SHA256SUMS.txt'), checksumLines.join('\n') + '\n');
  await writeFile(path.join(dist, `verification${clientArch ? '-' + clientArch : ''}.json`), JSON.stringify({ installerVersion: version, architectures: ['arm64', 'x86_64'], minimumMacOS: '13.0', signature: 'ad-hoc; no publisher identity or notarization', bundledCompatibleYapper: Boolean(source), clientArchitecture: clientArch ?? null, clientAppVersion: clientInspection?.appVersion ?? null, clientASARSHA256: clientInspection?.asarSHA256 ?? null, yapinpluggerBundleSHA256: clientInspection?.runtimeBundleSHA256 ?? null, archiveSHA256: hash, validation: ['Swift tests', 'Nested codesign verification', 'Universal installer executable architecture', 'CLI version command', ...(source ? ['Bundled client architecture', 'Yapinplugger version marker', 'Bundled runtime checksum matches reviewed hash', 'Copied app ASAR matches selected source'] : [])], limitations: ['End-to-end GUI installation has not been automated.', 'Signature verification is not a malware-free guarantee.', 'No user app or user profile was installed or modified by the build.'] }, null, 2) + '\n');
  console.log(`${archiveOnly ? 'Archive only; existing unpacked installer preserved' : `Built ${finalApp}`}\nZIP ${archive}`);
} finally {
  await rm(staging, { recursive: true, force: true });
}
