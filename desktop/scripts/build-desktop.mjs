import { packager } from '@electron/packager';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { access, chmod, cp, mkdir, mkdtemp, readFile, readdir, rm, stat, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repo = path.dirname(root);
const shared = path.join(repo, 'macos');
const output = path.join(repo, 'dist');
const manifest = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
const electronVersion = manifest.devDependencies.electron;
const arg = process.argv.slice(2);
const target = arg.find(value => value.startsWith('--platform='))?.slice(11) || process.platform;
if (arg.some(value => !value.startsWith('--platform=')) || !['all', 'linux', 'win32'].includes(target)) throw new Error('Usage: node scripts/build-desktop.mjs --platform=all|linux|win32');
if (!['darwin', 'linux'].includes(process.platform)) throw new Error('The cross-platform release script requires a macOS or Linux build host with zip, tar, mksquashfs and makensis.');
if (electronVersion !== '45.1.0') throw new Error('Reviewed runtime is pinned to Electron 45.1.0.');
const targets = target === 'all' ? ['linux', 'win32'] : [target];
const sharedFiles = ['main.js', 'preload.js', 'games.js', 'mac-processes.js', 'yappercord.js', 'yappercord/bundle.js', 'yappercord/bundle.sha256', 'yappercord/LICENSE.Vencord', 'yappercord/UPSTREAM.md', 'appearance/bundle.js', 'appearance/bundle.sha256', 'appearance/LICENSE', 'build/icon.png'];
const sha256 = data => createHash('sha256').update(data).digest('hex');
const execute = (command, args, options = {}) => execFileSync(command, args, { stdio: 'inherit', ...options });
const artifacts = [];
await mkdir(output, { recursive: true });
await mkdir(path.join(root, 'reports'), { recursive: true });
const staging = await mkdtemp(path.join(os.tmpdir(), 'yapinplugger-desktop-'));
const epoch = process.env.SOURCE_DATE_EPOCH || '1793318400';

async function trimPrebuilds(directory, platform) {
  for (const item of await readdir(directory, { withFileTypes: true })) {
    if (!item.isDirectory() || item.isSymbolicLink()) continue;
    const itemPath = path.join(directory, item.name);
    if (item.name === 'prebuilds') {
      for (const prebuild of await readdir(itemPath)) if (prebuild !== `${platform}-x64`) await rm(path.join(itemPath, prebuild), { recursive: true, force: true });
    } else await trimPrebuilds(itemPath, platform);
  }
}

async function treeFiles(directory, relative = '') {
  const files = [];
  for (const entry of await readdir(path.join(directory, relative), { withFileTypes: true })) {
    const name = path.posix.join(relative, entry.name);
    if (entry.isDirectory()) files.push(...await treeFiles(directory, name));
    else if (entry.isFile() || entry.isSymbolicLink()) files.push(name);
  }
  return files.sort();
}

async function normalizePermissions(directory) {
  await chmod(directory, 0o755);
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const filename = path.join(directory, entry.name);
    if (entry.isSymbolicLink()) continue;
    if (entry.isDirectory()) await normalizePermissions(filename);
    else await chmod(filename, (await stat(filename)).mode & 0o111 ? 0o755 : 0o644);
  }
}

async function appImage(appDir, filename) {
  // AppImage's continuous URL is mutable: pin the official asset ID and digest,
  // fail closed if the upstream URL changes rather than accepting new bytes.
  const runtime = {
    repository: 'AppImage/type2-runtime', commit: 'fedfad51acc2860b2916a1eef32ba4a500ff31ef',
    assetId: 657374641,
    url: 'https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64',
    sha256: '617aa77314d57c8b8e4fae9c3f0b35af7b30d5529cb69e98f64f92510ed98a46',
  };
  const cache = path.join(root, '.cache');
  await mkdir(cache, { recursive: true });
  const runtimePath = path.join(cache, `runtime-x86_64-${runtime.sha256}`);
  try { await access(runtimePath); } catch { execute('curl', ['--fail', '--location', '--proto', '=https', '--tlsv1.2', runtime.url, '--output', runtimePath]); }
  const runtimeBytes = await readFile(runtimePath);
  if (sha256(runtimeBytes) !== runtime.sha256) throw new Error('AppImage runtime digest changed. Review and pin a new official runtime before rebuilding.');
  if (runtimeBytes.subarray(0, 4).toString('hex') !== '7f454c46' || runtimeBytes.subarray(8, 11).toString('hex') !== '414902') throw new Error('Unexpected AppImage runtime format');
  const filesystem = path.join(staging, 'yapinplugger.squashfs');
  execute('mksquashfs', [appDir, filesystem, '-noappend', '-comp', 'xz', '-b', '1M', '-all-root', '-no-xattrs', '-mkfs-time', epoch, '-all-time', epoch, '-no-progress']);
  await writeFile(filename, Buffer.concat([runtimeBytes, await readFile(filesystem)]));
  await chmod(filename, 0o755);
  // Parse/list the actual embedded filesystem without executing the Linux runtime.
  execute('unsquashfs', ['-o', String(runtimeBytes.length), '-s', filename]);
  return { ...runtime, offset: runtimeBytes.length };
}

try {
  for (const platform of targets) {
    console.log(`Building Yapinplugger ${manifest.version} / plugins ${manifest.yapinpluggerVersion} for ${platform}-x64…`);
    const source = path.join(staging, `source-${platform}`);
    await mkdir(source, { recursive: true });
    for (const filename of sharedFiles) {
      await mkdir(path.dirname(path.join(source, filename)), { recursive: true });
      await cp(path.join(shared, filename), path.join(source, filename));
    }
    // Reuse the reviewed source. No separate, drifting Linux/Windows main process.
    const appManifest = { ...manifest, name: 'yapinplugger', scripts: undefined, devDependencies: undefined };
    await writeFile(path.join(source, 'package.json'), JSON.stringify(appManifest, null, 2) + '\n');
    await cp(path.join(root, 'node_modules'), path.join(source, 'node_modules'), { recursive: true, dereference: false, verbatimSymlinks: true });
    const packages = await packager({
      dir: source, out: staging, name: 'Yapinplugger',
      executableName: platform === 'linux' ? 'yapinplugger' : 'Yapinplugger',
      platform, arch: 'x64', electronVersion, appVersion: manifest.version,
      buildVersion: manifest.version, overwrite: true, prune: true,
      asar: { unpack: '**/*.node' },
      icon: platform === 'win32' ? path.join(root, 'build', 'icon.ico') : undefined,
      win32metadata: platform === 'win32' ? { CompanyName: 'Yapinplugger community port', FileDescription: 'Yapinplugger community Yapper client', 'requested-execution-level': 'asInvoker' } : undefined,
      ignore: filename => /(?:^|[/\\])(?:test|tests|__tests__|\.git|\.github|\.cache|\.bin)(?:[/\\]|$)/.test(filename),
      afterPrune: [async ({ buildPath }) => {
        await trimPrebuilds(path.join(buildPath, 'node_modules'), platform);
        await access(path.join(buildPath, 'node_modules', 'uiohook-napi', 'prebuilds', `${platform}-x64`, 'uiohook-napi.node'));
      }],
    });
    const packagePath = packages[0];
    const sourceHashes = Object.fromEntries(await Promise.all(sharedFiles.map(async filename => [filename, sha256(await readFile(path.join(shared, filename)))])));
    await writeFile(path.join(packagePath, 'YAPINPLUGGER-PROVENANCE.json'), JSON.stringify({
      project: 'https://github.com/h7sd/yapper-apple-ports', platform, arch: 'x64',
      version: manifest.version, yapinpluggerVersion: manifest.yapinpluggerVersion,
      electronVersion, originalAppImageSha256: 'e54f1d3f638caeae0302c6e56bbcf5c272a774862aecafd3d4959bb8e5095b12',
      officialUpstream: true, officialPort: false, automaticUpdates: false,
      compatibleLocalAdaptations: 6, unportedPublicPlugins: 161, sourceHashes,
    }, null, 2) + '\n');
    await cp(path.join(repo, 'extensions', 'yappercord', 'LICENSE.Vencord'), path.join(packagePath, 'LICENSE.Vencord'));
    // Official runtime ZIP entries may have permissive POSIX mode bits. Ship
    // readable files/executables without group/other write access or setuid.
    await normalizePermissions(packagePath);
    const prefix = `Yapinplugger-${manifest.version}-plugins-${manifest.yapinpluggerVersion}`;
    let runtime;
    if (platform === 'linux') {
      for (const file of ['AppRun', 'install-desktop.sh', 'yapinplugger.desktop', 'LICENSE.AppImage-runtime']) await cp(path.join(root, 'linux', file), path.join(packagePath, file));
      await cp(path.join(shared, 'build', 'icon.png'), path.join(packagePath, 'yapinplugger.png'));
      await symlink('yapinplugger.png', path.join(packagePath, '.DirIcon'));
      await chmod(path.join(packagePath, 'AppRun'), 0o755);
      await chmod(path.join(packagePath, 'install-desktop.sh'), 0o755);
      const tarball = path.join(output, `${prefix}-linux-x64.tar.gz`);
      execute('tar', ['-czf', tarball, '-C', path.dirname(packagePath), path.basename(packagePath)], { env: { ...process.env, COPYFILE_DISABLE: '1' } });
      artifacts.push(tarball);
      const image = path.join(output, `${prefix}-linux-x64.AppImage`);
      runtime = await appImage(packagePath, image);
      artifacts.push(image);
    } else {
      await cp(path.join(root, 'windows', 'LICENSE.NSIS'), path.join(packagePath, 'LICENSE.NSIS'));
      const archive = path.join(output, `${prefix}-windows-x64.zip`);
      await rm(archive, { force: true });
      execute('zip', ['-q', '-r', archive, path.basename(packagePath)], { cwd: path.dirname(packagePath) });
      artifacts.push(archive);
      const files = await treeFiles(packagePath);
      if (files.some(file => /["$\r\n]/.test(file))) throw new Error('Unsafe filename in NSIS uninstall manifest');
      const dirs = [...new Set(files.flatMap(file => {
        const components = file.split('/'); components.pop();
        return components.map((_, index) => components.slice(0, index + 1).join('\\'));
      }))].sort((a, b) => b.length - a.length);
      const uninstallManifest = path.join(staging, 'uninstall-files.nsh');
      await writeFile(uninstallManifest, files.map(file => `Delete "$INSTDIR\\${file.replaceAll('/', '\\')}"`).concat(dirs.map(dir => `RMDir "$INSTDIR\\${dir}"`)).join('\n') + '\n');
      const setup = path.join(output, `${prefix}-windows-x64-Setup.exe`);
      execute('makensis', ['-V2', `-DAPPDIR=${packagePath}`, `-DOUTPUT=${setup}`, `-DICON=${path.join(root, 'build', 'icon.ico')}`, `-DUNINSTALL_MANIFEST=${uninstallManifest}`, path.join(root, 'windows', 'setup.nsi')]);
      artifacts.push(setup);
    }
    const finalPackage = path.join(output, path.basename(packagePath));
    await rm(finalPackage, { recursive: true, force: true });
    await cp(packagePath, finalPackage, { recursive: true, dereference: false, verbatimSymlinks: true });
    await writeFile(path.join(root, 'reports', `build-${platform}-x64.json`), JSON.stringify({
      platform, architecture: 'x64', electronVersion, appVersion: manifest.version,
      yapinpluggerVersion: manifest.yapinpluggerVersion, buildHost: process.platform,
      runtimeTestedOnTarget: false, sourceHashes, appImageRuntime: runtime,
      artifacts: await Promise.all(artifacts.filter(file => platform === 'linux' ? file.includes('-linux-') : file.includes('-windows-')).map(async file => ({ name: path.basename(file), bytes: (await stat(file)).size, sha256: sha256(await readFile(file)) }))),
      limitations: ['Cross-compiled on macOS/Linux; no target desktop execution or hardware call test.', 'Windows binaries are unsigned; no publisher certificate is supplied.', 'Chromium sandbox remains enabled; Linux user-namespace policy and system libraries must support Electron.'],
    }, null, 2) + '\n');
  }
  console.log(`Artifacts:\n${artifacts.join('\n')}`);
} finally {
  await rm(staging, { recursive: true, force: true });
}
