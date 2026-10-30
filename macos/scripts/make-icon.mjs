import { execFileSync } from 'node:child_process';
import { mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const iconset = path.join(root, 'build', 'Yapper.iconset');
const original = path.join(root, 'build', 'icon.png');
const output = path.join(root, 'build', 'icon.icns');

export async function makeIcon() {
  if (process.platform !== 'darwin') throw new Error('Icon generation requires macOS sips and iconutil.');
  await rm(iconset, { recursive: true, force: true });
  await mkdir(iconset, { recursive: true });
  try {
    for (const size of [16, 32, 128, 256, 512]) {
      for (const scale of [1, 2]) {
        const pixels = String(size * scale);
        const filename = `icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`;
        execFileSync('/usr/bin/sips', ['-z', pixels, pixels, original, '--out', path.join(iconset, filename)], { stdio: 'ignore' });
      }
    }
    execFileSync('/usr/bin/iconutil', ['-c', 'icns', iconset, '-o', output], { stdio: 'inherit' });
    return output;
  } finally {
    await rm(iconset, { recursive: true, force: true });
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  console.log(await makeIcon());
}
