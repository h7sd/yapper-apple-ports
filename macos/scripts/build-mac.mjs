import { packager } from '@electron/packager';
import { execFileSync } from 'node:child_process';
import { access, cp, mkdir, mkdtemp, readdir, readFile, readlink, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { makeIcon } from './make-icon.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outputs = path.resolve(root, '..', 'dist');
const manifest = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
const electronVersion = manifest.devDependencies.electron;
const archArg = process.argv.slice(2).find(arg => arg.startsWith('--arch='));
const requestedArch = archArg ? archArg.slice('--arch='.length) : process.arch;
const architectures = requestedArch === 'all' ? ['arm64', 'x64'] : [requestedArch];

if (process.platform !== 'darwin') throw new Error('Build this macOS client on macOS.');
if (process.argv.slice(2).some(arg => !arg.startsWith('--arch='))) throw new Error('Usage: node scripts/build-mac.mjs [--arch=arm64|x64|all]');
if (architectures.some(arch => !['arm64', 'x64'].includes(arch))) throw new Error('Supported macOS architectures: arm64, x64, all.');
if (electronVersion !== '45.1.0') throw new Error('This reviewed release requires the pinned Electron version, 45.1.0.');

// Keep only application entry points, assets, and production dependencies.
// Packager's prune pass removes all devDependencies before ASAR creation.
const appRoots = new Set(['package.json', 'main.js', 'preload.js', 'games.js', 'mac-processes.js', 'build', 'node_modules']);
function ignoreSource(filename) {
  const normalized = filename.replaceAll('\\', '/').replace(/^\//, '');
  if (!normalized) return false;
  const segments = normalized.split('/');
  if (!appRoots.has(segments[0])) return true;
  if (segments[0] === 'build') return segments.length > 1 && !['icon.png', 'icon.icns'].includes(segments[1]);
  if (segments[0] !== 'node_modules') return false;
  return segments.some(segment => ['test', 'tests', '__tests__', '.git', '.github', '.cache', '.bin'].includes(segment));
}

// N-API prebuilds are portable across Electron versions, but only Darwin
// binaries for the requested architecture belong in each app bundle.
async function trimNativePrebuilds(directory, arch) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.isSymbolicLink()) continue;
    const entryPath = path.join(directory, entry.name);
    if (entry.name === 'prebuilds') {
      for (const prebuild of await readdir(entryPath, { withFileTypes: true })) {
        if (prebuild.isDirectory() && ![`darwin-${arch}`, 'darwin-universal'].includes(prebuild.name)) {
          await rm(path.join(entryPath, prebuild.name), { recursive: true, force: true });
        }
      }
    } else {
      await trimNativePrebuilds(entryPath, arch);
    }
  }
}

async function checkPortableLinks(app, directory = app) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const filename = path.join(directory, entry.name);
    if (entry.isSymbolicLink()) {
      const target = await readlink(filename);
      if (path.isAbsolute(target)) throw new Error(`Non-portable absolute symlink: ${path.relative(app, filename)}`);
      const resolved = path.resolve(directory, target);
      const relative = path.relative(app, resolved);
      if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) throw new Error('App symlink escapes its bundle');
      await access(filename);
    } else if (entry.isDirectory()) await checkPortableLinks(app, filename);
  }
}

const icon = await makeIcon();
await mkdir(outputs, { recursive: true });
const entitlements = path.join(root, 'build', 'entitlements.plist');
// Documents may be managed by a file provider that adds FinderInfo while we
// sign. Create and verify the distributable outside synced folders first.
const staging = await mkdtemp(path.join(os.tmpdir(), 'yapper-mac-'));

try {
for (const arch of architectures) {
  console.log(`Building Yapper ${manifest.version} for macOS ${arch} with Electron ${electronVersion}…`);
  const paths = await packager({
    dir: root,
    out: staging,
    name: manifest.productName,
    executableName: 'Yapper',
    platform: 'darwin',
    arch,
    electronVersion,
    appVersion: manifest.version,
    buildVersion: manifest.version,
    appBundleId: 'website.yapper.desktop',
    helperBundleId: 'website.yapper.desktop.helper',
    appCategoryType: 'public.app-category.social-networking',
    icon,
    overwrite: true,
    prune: true,
    asar: { unpack: '**/*.node' },
    ignore: ignoreSource,
    darwinDarkModeSupport: true,
    protocols: [{ name: 'Yapper', schemes: ['yapper'], role: 'Viewer' }],
    extendInfo: {
      NSCameraUsageDescription: 'Yapper uses your camera for video calls.',
      NSMicrophoneUsageDescription: 'Yapper uses your microphone for voice messages and calls.',
      NSScreenCaptureUsageDescription: 'Yapper shares your selected screen or window during calls.',
      NSAudioCaptureUsageDescription: 'Yapper captures shared system audio when you share your screen.',
      NSInputMonitoringUsageDescription: 'Yapper uses input monitoring for push-to-talk while another app is active.',
      NSAccessibilityUsageDescription: 'Yapper uses accessibility access for push-to-talk while another app is active.',
      LSApplicationCategoryType: 'public.app-category.social-networking'
    },
    afterPrune: [async ({ buildPath }) => {
      await trimNativePrebuilds(path.join(buildPath, 'node_modules'), arch);
      await access(path.join(buildPath, 'node_modules', 'uiohook-napi', 'prebuilds', `darwin-${arch}`, 'uiohook-napi.node'));
    }],
    osxSign: {
      continueOnError: false,
      identity: '-',
      identityValidation: false,
      preAutoEntitlements: false,
      preEmbedProvisioningProfile: false,
      optionsForFile: () => ({ entitlements, hardenedRuntime: true, timestamp: 'none' })
    }
  });

  for (const packagePath of paths) {
    const app = path.join(packagePath, 'Yapper.app');
    // Finder metadata is not part of the signed bundle and must not be shipped.
    execFileSync('/usr/bin/xattr', ['-cr', app], { stdio: 'inherit' });
    execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', app], { stdio: 'inherit' });
    const archive = path.join(outputs, `Yapper-${manifest.version}-mac-${arch}.zip`);
    await rm(archive, { force: true });
    execFileSync('/usr/bin/ditto', ['-c', '-k', '--keepParent', '--norsrc', '--noextattr', '--noqtn', app, archive], { stdio: 'inherit' });
    const finalPackage = path.join(outputs, path.basename(packagePath));
    await rm(finalPackage, { recursive: true, force: true });
    await cp(packagePath, finalPackage, { recursive: true, dereference: false, verbatimSymlinks: true });
    await checkPortableLinks(path.join(finalPackage, 'Yapper.app'));
    console.log(`App: ${path.join(finalPackage, 'Yapper.app')}\nZIP: ${archive}`);
  }
}
} finally {
  await rm(staging, { recursive: true, force: true });
}
