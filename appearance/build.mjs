#!/usr/bin/env node
// SPDX-License-Identifier: MIT
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const directory = dirname(fileURLToPath(import.meta.url));
const root = resolve(directory, '..');
const source = readFileSync(resolve(directory, 'appearance.js'));
const license = readFileSync(resolve(directory, 'LICENSE'));
const hash = createHash('sha256').update(source).digest('hex');
const files = [
  [resolve(root, 'macos/appearance/bundle.js'), source],
  [resolve(root, 'macos/appearance/bundle.sha256'), Buffer.from(`${hash}  bundle.js\n`)],
  [resolve(root, 'macos/appearance/LICENSE'), license],
  [resolve(root, 'ios/Yapper/resources/YapperAppearance.js'), source],
  [resolve(root, 'ios/Yapper/resources/LICENSE.Appearance'), license],
];
for (const [path, bytes] of files) {
  if (process.argv.includes('--check')) {
    if (!readFileSync(path).equals(bytes)) throw new Error(`Appearance copy is stale: ${path.slice(root.length + 1)}`);
  } else { mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, bytes); }
}
console.log(JSON.stringify({ version: '0.1.0', sha256: hash, bytes: source.length, mode: process.argv.includes('--check') ? 'verified' : 'copied', outputs: files.map(([path]) => path.slice(root.length + 1)) }));
