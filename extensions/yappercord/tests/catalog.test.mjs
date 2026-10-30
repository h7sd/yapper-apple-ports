// SPDX-License-Identifier: GPL-3.0-or-later
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { dependencySignals, discoverPluginEntries, generateCatalog, parseAuthors, parsePluginMetadata, REPOSITORY } from '../generate-catalog.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const catalog = JSON.parse(readFileSync(join(root, 'catalog.json'), 'utf8'));
const authors = new Map([['Ven', { key: 'Ven', name: 'V', id: '343383572805058560' }]]);
const fixture = properties => `
// None of the text in this fixture is imported or executed.
throw new Error("EXECUTION IS FORBIDDEN");
export default definePlugin({
    name: "Fixture",
    description: "A static description with an escaped \\"quote\\".",
    authors: [Devs.Ven],
${properties}
});`;

test('pinned inventory covers all 167 public plugins, 14 API entries, and 5 core entries', () => {
  assert.equal(catalog.schemaVersion, 1);
  assert.equal(catalog.upstream.repository, REPOSITORY);
  assert.equal(catalog.upstream.commit, '644434941b515a2626a2161e219653cb36e723e7');
  assert.equal(catalog.plugins.length, 186);
  assert.deepEqual(catalog.coverage.kindCounts, { plugin: 167, api: 14, core: 5 });
  assert.equal(new Set(catalog.plugins.map(plugin => plugin.id)).size, 186);
  assert.equal(new Set(catalog.plugins.map(plugin => plugin.sourcePath)).size, 186);
  assert.equal(Object.values(catalog.coverage.targetCounts).reduce((sum, count) => sum + count, 0), 186);
  for (const [kind, count] of Object.entries(catalog.coverage.kindCounts)) {
    assert.equal(catalog.plugins.filter(plugin => plugin.kind === kind).length, count);
  }
});

test('every entry has immutable source provenance and no fabricated operational compatibility', () => {
  for (const plugin of catalog.plugins) {
    assert.ok(plugin.name && plugin.description && plugin.authors.length, plugin.id);
    assert.equal(plugin.status, 'requires-port', plugin.id);
    assert.match(plugin.sourceSha256, /^[a-f0-9]{64}$/);
    assert.equal(plugin.sourceUrl, `${REPOSITORY}/blob/${catalog.upstream.commit}/${plugin.sourcePath}`);
    assert.ok(plugin.signals.scopeFiles.some(file => file.path === plugin.sourcePath && file.sha256 === plugin.sourceSha256));
    assert.equal(plugin.signals.evidenceType, 'static-source-signals');
    assert.ok(plugin.blockers.some(blocker => blocker.code === 'vencord-plugin-runtime'));
    for (const blocker of plugin.blockers) {
      assert.ok(blocker.detail && blocker.evidence.length);
      for (const evidence of blocker.evidence) {
        assert.ok(plugin.signals.scopeFiles.some(file => file.path === evidence.path));
        assert.ok(Number.isInteger(evidence.line) && evidence.line > 0);
      }
    }
    assert.ok(!JSON.stringify(plugin).includes('/Users/'));
  }
});

test('reported blocker counts are computed from concrete per-entry evidence', () => {
  for (const [code, count] of Object.entries(catalog.coverage.blockerCounts)) {
    assert.equal(catalog.plugins.filter(plugin => plugin.blockers.some(blocker => blocker.code === code)).length, count);
  }
  assert.equal(catalog.coverage.publicPluginsWithDirectDiscordBindings, 161);
  assert.equal(catalog.coverage.directDiscordBindingEntries, 179);
  assert.equal(catalog.coverage.blockerCounts['discord-bundle-patches'], 146);
  assert.equal(catalog.coverage.blockerCounts['discord-webpack-imports'], 123);
  assert.equal(catalog.coverage.blockerCounts['upstream-native-module'], 9);
});

test('literal metadata parsing never runs plugin statements', () => {
  const parsed = parsePluginMetadata(fixture('    required: true,\n    tags: ["Utility"],'), authors);
  assert.equal(parsed.name, 'Fixture');
  assert.equal(parsed.description, 'A static description with an escaped "quote".');
  assert.deepEqual(parsed.authors, [...authors.values()]);
  assert.equal(parsed.required, true);
});

test('executable metadata expressions and unknown author references fail closed', () => {
  assert.throws(() => parsePluginMetadata(fixture('').replace('name: "Fixture",', 'name: process.exit(1),'), authors), /static quoted/);
  assert.throws(() => parsePluginMetadata(fixture('').replace('name: "Fixture",', 'name: "Fixture" + dangerous(),'), authors), /Nonliteral name/);
  assert.throws(() => parsePluginMetadata(fixture('').replace('[Devs.Ven]', '[Devs.Ven].map(execute)'), authors), /array expressions/);
  assert.throws(() => parsePluginMetadata(fixture('').replace('Devs.Ven', 'Devs.Unknown'), authors), /Unknown published author/);
  assert.throws(() => parsePluginMetadata(fixture('    description: "Ambiguous duplicate",'), authors), /Ambiguous duplicate/);
  const unknownFlag = parsePluginMetadata(fixture('    required: IS_VESKTOP,'), authors);
  assert.equal(unknownFlag.required, null);
  assert.equal(unknownFlag.requiredExpression, 'IS_VESKTOP');
});

test('published author identities are parsed as literals rather than importing constants', () => {
  const parsed = parseAuthors(`export const Devs = Object.freeze({
    Ven: {
        name: "V",
        id: 343383572805058560n
    }
});\nthrow new Error("do not execute");`);
  assert.deepEqual([...parsed.values()], [...authors.values()]);
});

test('entry selection includes API/core/targeted plugins and excludes hidden/helper/userplugin files', () => {
  const temporary = mkdtempSync(join(tmpdir(), 'yappercord-inventory-'));
  try {
    const files = [
      'src/plugins/index.ts', 'src/plugins/_ignored.ts', 'src/plugins/.hidden.ts',
      'src/plugins/public/index.tsx', 'src/plugins/public/helper.ts',
      'src/plugins/special.desktop/index.ts', 'src/plugins/oneFile.ts',
      'src/plugins/_api/commands.ts', 'src/plugins/_core/noTrack.ts',
      'src/userplugins/private/index.ts',
    ];
    for (const path of files) { mkdirSync(dirname(join(temporary, path)), { recursive: true }); writeFileSync(join(temporary, path), '// not executable'); }
    assert.deepEqual(discoverPluginEntries(temporary).map(entry => entry.path).sort(), [
      'src/plugins/_api/commands.ts', 'src/plugins/_core/noTrack.ts', 'src/plugins/oneFile.ts',
      'src/plugins/public/index.tsx', 'src/plugins/special.desktop/index.ts',
    ].sort());
  } finally { rmSync(temporary, { recursive: true, force: true }); }
});

test('dependency signals retain scope and distinguish explicit type-only imports', () => {
  const parsed = parsePluginMetadata(fixture('    patches: [],\n    flux: {},'), authors);
  const signals = dependencySignals([{ path: 'src/plugins/fixture/index.ts', content: 'import type { Store } from "@webpack/types";\nimport { UserStore, Flux } from "@webpack/common";\n// fetch is only a comment, not evidence of executed network traffic.' }], parsed);
  assert.equal(signals.evidenceType, 'static-source-signals');
  assert.equal(signals.importReferences[0].explicitlyTypeOnly, true);
  assert.equal(signals.importReferences[1].explicitlyTypeOnly, false);
  assert.equal(signals.patches, true);
  assert.ok(signals.referencedTokens.includes('fetch'), 'lexical false positives must remain documented as signals');
  assert.deepEqual(signals.storeIdentifiers, ['UserStore']);
});

test('explicit source checkout independently matches every shipped entry and the complete catalog', { skip: !process.env.VENCORD_SOURCE && 'Set VENCORD_SOURCE to the pinned source checkout for independent coverage verification.' }, () => {
  const source = resolve(process.env.VENCORD_SOURCE);
  const tracked = execFileSync('git', ['-c', 'core.fsmonitor=false', '-C', source, 'ls-tree', '-r', '--name-only', 'HEAD', '--', 'src/plugins'], { encoding: 'utf8' }).trim().split('\n');
  // Independent path selection from Git's tracked tree, rather than reusing
  // discoverPluginEntries, catches accidentally omitted API/core/directory entries.
  const selected = tracked.filter(path => /^src\/plugins\/(?:_(?:api|core)\/)?[^_.\/][^\/]*(?:\/index)?\.tsx?$/.test(path));
  assert.deepEqual(catalog.plugins.map(plugin => plugin.sourcePath).sort(), selected.sort());
  assert.deepEqual(generateCatalog(source), catalog);
});
