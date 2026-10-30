import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root = path.dirname(fileURLToPath(import.meta.url));
const catalog = JSON.parse(await readFile(path.join(root, 'catalog.json'), 'utf8'));
if (catalog.schemaVersion !== 1 || !Array.isArray(catalog.plugins) || !/^[a-f0-9]{40}$/.test(catalog.upstream.commit)) throw new Error('Invalid pinned upstream catalog');
const runtime = await readFile(path.join(root, 'runtime.js'), 'utf8');
const bundle = `/* Yapinplugger: GPL-3.0-or-later. See LICENSE.Vencord and UPSTREAM.md. */\n(function(){\nconst YAPPERCORD_CATALOG = ${JSON.stringify(catalog)};\n${runtime}\n})();\n`;
const hash = createHash('sha256').update(bundle).digest('hex');
if (process.argv.includes('--check')) {
    for (const file of ['bundle.js', '../../macos/yappercord/bundle.js', '../../ios/Yapper/resources/YapperCord.js']) {
        if (await readFile(path.join(root, file), 'utf8') !== bundle) throw new Error(`Stale generated bundle: ${file}`);
    }
    console.log(`Generated bundles match runtime and catalog: ${hash}`);
    process.exit(0);
}
await writeFile(path.join(root, 'bundle.js'), bundle);
await writeFile(path.join(root, 'bundle.sha256'), `${hash}  bundle.js\n`);
await mkdir(path.join(root, '../../macos/yappercord'), { recursive: true });
await writeFile(path.join(root, '../../macos/yappercord/bundle.js'), bundle);
await writeFile(path.join(root, '../../macos/yappercord/bundle.sha256'), `${hash}  bundle.js\n`);
for (const name of ['LICENSE.Vencord', 'UPSTREAM.md']) await writeFile(path.join(root, '../../macos/yappercord', name), await readFile(path.join(root, name)));
console.log(`Yapinplugger bundle: ${catalog.plugins.length} catalog entries, sha256 ${hash}`);
