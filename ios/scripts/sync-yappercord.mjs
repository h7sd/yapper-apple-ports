#!/usr/bin/env node
import { readFile, writeFile, rename } from 'node:fs/promises';
import vm from 'node:vm';
import { createHash } from 'node:crypto';

const source = new URL('../../extensions/yappercord/bundle.js', import.meta.url);
const target = new URL('../Yapper/resources/YapperCord.js', import.meta.url);
const licenseSource = new URL('../../extensions/yappercord/LICENSE.Vencord', import.meta.url);
const licenseTarget = new URL('../Yapper/resources/LICENSE.Vencord', import.meta.url);
const [bundle, license] = await Promise.all([readFile(source, 'utf8'), readFile(licenseSource, 'utf8')]);
if (!bundle.includes('YapperCord') || !bundle.trim()) throw new Error('Build the shared YapperCord bundle before syncing iOS resources.');
new vm.Script(bundle, { filename: 'YapperCord.js' });
const temporary = new URL(`YapperCord.js.tmp-${process.pid}`, target);
await writeFile(temporary, bundle);
await rename(temporary, target);
await writeFile(licenseTarget, license);
console.log(`Synced YapperCord.js (${createHash('sha256').update(bundle).digest('hex')})`);
