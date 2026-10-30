#!/usr/bin/env node
import { readFile, writeFile, rename } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import vm from 'node:vm';

const source = new URL('../../appearance/appearance.js', import.meta.url);
const target = new URL('../Yapper/resources/YapperAppearance.js', import.meta.url);
const licenseSource = new URL('../../appearance/LICENSE', import.meta.url);
const licenseTarget = new URL('../Yapper/resources/LICENSE.Appearance', import.meta.url);
const [text, license] = await Promise.all([readFile(source, 'utf8'), readFile(licenseSource, 'utf8')]);
if (!text.includes('YapperAppearance') || !text.trim()) throw new Error('The shared appearance adapter is missing.');
new vm.Script(text, { filename: 'YapperAppearance.js' });
const temporary = new URL(`YapperAppearance.js.tmp-${process.pid}`, target);
await writeFile(temporary, text);
await rename(temporary, target);
await writeFile(licenseTarget, license);
console.log(`Synced YapperAppearance.js (${createHash('sha256').update(text).digest('hex')})`);
