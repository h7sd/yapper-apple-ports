#!/usr/bin/env node
// Static inventory only. This program never imports or evaluates plugin code.
// SPDX-License-Identifier: GPL-3.0-or-later
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { lstatSync, readFileSync, readdirSync, realpathSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

export const REPOSITORY = 'https://github.com/Vendicated/Vencord';
export const PLUGIN_ROOTS = ['src/plugins', 'src/plugins/_api', 'src/plugins/_core'];
const TARGETS = new Set(['web', 'browser', 'discordDesktop', 'vesktop', 'desktop', 'dev']);
const sha256 = value => createHash('sha256').update(value).digest('hex');
const posix = value => value.split(sep).join('/');
const escapeRegExp = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const immutableURL = (commit, path) => `${REPOSITORY}/blob/${commit}/${path.split('/').map(encodeURIComponent).join('/')}`;

function containedPath(sourceRoot, path) {
  const result = resolve(sourceRoot, path);
  const rel = relative(realpathSync(sourceRoot), realpathSync(result));
  if (rel.startsWith(`..${sep}`) || rel === '..' || isAbsolute(rel)) throw new Error(`Source path escaped the explicit source directory: ${path}`);
  if (lstatSync(result).isSymbolicLink()) throw new Error(`Symbolic source entries are unsupported: ${path}`);
  return result;
}

function readSource(sourceRoot, path) { return readFileSync(containedPath(sourceRoot, path), 'utf8'); }

// A deliberately limited literal reader, not a JavaScript interpreter. Changed
// upstream metadata formats fail closed instead of executing an expression.
export function readStringLiteral(source, start) {
  const quote = source[start];
  if (quote !== '"' && quote !== "'") throw new Error('Expected a static quoted string literal');
  let value = '';
  for (let index = start + 1; index < source.length; index++) {
    let char = source[index];
    if (char === quote) return { value, end: index + 1 };
    if (char === '\n' || char === '\r') throw new Error('Unescaped line break in string literal');
    if (char !== '\\') { value += char; continue; }
    char = source[++index];
    if (char === undefined) break;
    const escapes = { n: '\n', r: '\r', t: '\t', b: '\b', f: '\f', v: '\v', '0': '\0' };
    if (char in escapes) { value += escapes[char]; continue; }
    if (char === '\n') continue;
    if (char === '\r') { if (source[index + 1] === '\n') index++; continue; }
    if (char === 'x' || char === 'u') {
      let digits;
      if (char === 'u' && source[index + 1] === '{') {
        const end = source.indexOf('}', index + 2);
        if (end < 0) throw new Error('Unclosed Unicode escape');
        digits = source.slice(index + 2, end);
        index = end;
      } else {
        const length = char === 'x' ? 2 : 4;
        digits = source.slice(index + 1, index + 1 + length);
        if (digits.length !== length) throw new Error('Incomplete character escape');
        index += length;
      }
      if (!/^[0-9a-f]+$/i.test(digits)) throw new Error('Invalid character escape');
      value += String.fromCodePoint(Number.parseInt(digits, 16));
      continue;
    }
    if (/[1-9]/.test(char)) throw new Error('Legacy octal escape is unsupported');
    value += char;
  }
  throw new Error('Unclosed string literal');
}

function skipSpaceAndComments(source, start) {
  let index = start;
  while (index < source.length) {
    if (/\s/.test(source[index])) { index++; continue; }
    if (source.startsWith('//', index)) {
      const end = source.indexOf('\n', index + 2);
      index = end === -1 ? source.length : end + 1;
      continue;
    }
    if (source.startsWith('/*', index)) {
      const end = source.indexOf('*/', index + 2);
      if (end < 0) throw new Error('Unclosed metadata comment');
      index = end + 2;
      continue;
    }
    break;
  }
  return index;
}

function readStaticArray(source, start, kind) {
  let index = skipSpaceAndComments(source, start);
  if (source[index++] !== '[') throw new Error(`Expected a static ${kind} array`);
  const result = [];
  const finish = end => {
    const next = skipSpaceAndComments(source, end);
    if (![',', '}'].includes(source[next])) throw new Error('Metadata array expressions are not supported');
    return result;
  };
  while (index < source.length) {
    index = skipSpaceAndComments(source, index);
    if (source[index] === ']') return finish(index + 1);
    if (kind === 'authors') {
      const match = /^Devs\.([A-Za-z_$][\w$]*)/.exec(source.slice(index));
      if (!match) throw new Error('Only published Devs.NAME author references are supported');
      result.push(match[1]);
      index += match[0].length;
    } else {
      const literal = readStringLiteral(source, index);
      result.push(literal.value);
      index = literal.end;
    }
    index = skipSpaceAndComments(source, index);
    if (source[index] === ']') return finish(index + 1);
    if (source[index++] !== ',') throw new Error('Metadata expressions are not supported');
  }
  throw new Error('Unclosed static metadata array');
}

export function parseAuthors(source) {
  const result = new Map();
  const declaration = source.indexOf('export const Devs');
  if (declaration < 0) throw new Error('Missing published Devs declaration');
  const body = source.slice(declaration);
  for (const match of body.matchAll(/^    ([A-Za-z_$][\w$]*):\s*\{([\s\S]*?)^    \}/gm)) {
    const name = /\bname:\s*/.exec(match[2]);
    const id = /\bid:\s*(\d+)n\b/.exec(match[2]);
    if (!name || !id) throw new Error(`Nonliteral author metadata: ${match[1]}`);
    result.set(match[1], { key: match[1], name: readStringLiteral(match[2], name.index + name[0].length).value, id: id[1] });
  }
  if (!result.size) throw new Error('No published author literals found');
  return result;
}

export function parsePluginMetadata(source, authors) {
  const definition = /export\s+default\s+definePlugin\s*\(\s*\{/.exec(source);
  if (!definition) throw new Error('Missing default definePlugin object');
  const body = source.slice(definition.index + definition[0].length);
  const firstName = /^([\t ]+)(?:name|["']name["'])\s*:/m.exec(body);
  if (!firstName) throw new Error('Missing literal first-level plugin name');
  const indentation = firstName[1];
  // Upstream enforces literal metadata. This scanner also requires the existing
  // consistent top-level indentation; it deliberately rejects ambiguous changes.
  const field = (name, required = false) => {
    const matches = [...body.matchAll(new RegExp(`^${escapeRegExp(indentation)}(?:${name}|["']${name}["'])\\s*:\\s*`, 'gm'))];
    if (matches.length > 1) throw new Error(`Ambiguous duplicate first-level ${name}`);
    if (!matches.length) {
      if (required) throw new Error(`Missing ${name}`);
      return null;
    }
    return matches[0].index + matches[0][0].length;
  };
  const literalField = name => {
    const literal = readStringLiteral(body, field(name, true));
    if (![',', '}'].includes(body[skipSpaceAndComments(body, literal.end)])) throw new Error(`Nonliteral ${name} expression`);
    return literal.value;
  };
  const listField = (name, kind = 'strings') => {
    const start = field(name, name === 'authors');
    return start === null ? [] : readStaticArray(body, start, kind);
  };
  const authorKeys = listField('authors', 'authors');
  const authorList = authorKeys.map(key => {
    if (!authors.has(key)) throw new Error(`Unknown published author Devs.${key}`);
    return authors.get(key);
  });
  const boolField = name => {
    const start = field(name);
    if (start === null) return { value: false, expression: null };
    const match = /^(true|false)\s*(?=,|\r?\n)/.exec(body.slice(start));
    if (match) return { value: match[1] === 'true', expression: null };
    return { value: null, expression: body.slice(start).split(/\r?\n/, 1)[0].replace(/,\s*$/, '').trim() };
  };
  const required = boolField('required');
  const enabledByDefault = boolField('enabledByDefault');
  return {
    name: literalField('name'), description: literalField('description'), authors: authorList,
    tags: listField('tags'), dependencies: listField('dependencies'),
    required: required.value, requiredExpression: required.expression,
    enabledByDefault: enabledByDefault.value, enabledByDefaultExpression: enabledByDefault.expression,
    hasPatches: field('patches') !== null,
    hasFluxHandlers: field('flux') !== null,
    definitionOffset: definition.index,
    patchesOffset: field('patches'),
    definitionBodyOffset: definition.index + definition[0].length,
    messageHooks: [...body.matchAll(new RegExp(`^${escapeRegExp(indentation)}(onBeforeMessageSend|onBeforeMessageEdit|onMessageClick)\\s*(?:\\(|:)`, 'gm'))].map(match => ({ name: match[1], offset: definition.index + definition[0].length + match.index })),
  };
}

export function discoverPluginEntries(sourceRoot) {
  const result = [];
  for (const root of PLUGIN_ROOTS) {
    for (const entry of readdirSync(containedPath(sourceRoot, root), { withFileTypes: true })) {
      if (entry.name.startsWith('_') || entry.name.startsWith('.') || entry.name === 'index.ts') continue;
      const path = `${root}/${entry.name}`;
      if (entry.isSymbolicLink()) throw new Error(`Symbolic plugin entry is unsupported: ${path}`);
      if (entry.isFile()) {
        if (!/\.tsx?$/.test(entry.name)) throw new Error(`Unrecognized shipped plugin entry: ${path}`);
        result.push({ path, directory: null });
      } else if (entry.isDirectory()) {
        const entryFile = ['index.ts', 'index.tsx'].find(file => {
          try { return lstatSync(join(sourceRoot, path, file)).isFile(); } catch { return false; }
        });
        if (!entryFile) throw new Error(`No static entry point found: ${path}`);
        result.push({ path: `${path}/${entryFile}`, directory: path });
      } else throw new Error(`Unsupported source entry type: ${path}`);
    }
  }
  return result.sort((a, b) => a.path.localeCompare(b.path, 'en'));
}

function codeFiles(sourceRoot, entry) {
  if (!entry.directory) return [entry.path];
  const files = [];
  const visit = directory => {
    for (const child of readdirSync(containedPath(sourceRoot, directory), { withFileTypes: true })) {
      const path = `${directory}/${child.name}`;
      if (child.isSymbolicLink()) throw new Error(`Symbolic plugin helper is unsupported: ${path}`);
      if (child.isDirectory()) visit(path);
      else if (child.isFile() && /\.(?:[cm]?[jt]sx?|css)$/.test(child.name)) files.push(path);
    }
  };
  visit(entry.directory);
  return files.sort();
}

export function dependencySignals(sources, metadata) {
  const joined = sources.map(source => source.content).join('\n');
  const imports = [...new Set([...joined.matchAll(/\b(?:from\s+|import\s*\(\s*|import\s+)(["'])([^"'\r\n]+)\1/g)].map(match => match[2]))].sort();
  const tokenCandidates = ['Flux', 'FluxDispatcher', 'VencordNative', 'document', 'window', 'navigator', 'localStorage', 'sessionStorage', 'XMLHttpRequest', 'WebSocket', 'fetch', 'findByProps', 'findByCode', 'findStore'];
  const importReferences = sources.flatMap(({ path, content }) => {
    // Capture only source import declarations; no module resolution/execution.
    const references = [];
    for (const match of content.matchAll(/^import\b(?:(?!;)[\s\S])*?\bfrom\s*(["'])([^"'\r\n]+)\1/gm)) {
      references.push({ path, line: content.slice(0, match.index).split('\n').length, specifier: match[2], explicitlyTypeOnly: /^import\s+type\b/.test(match[0]) });
    }
    return references;
  });
  return {
    evidenceType: 'static-source-signals',
    imports,
    importReferences,
    webpackImports: imports.filter(value => value.startsWith('@webpack')),
    discordTypeImports: imports.filter(value => value.startsWith('@vencord/discord-types')),
    vencordApiImports: imports.filter(value => value.startsWith('@api/')),
    patches: metadata.hasPatches,
    fluxHandlers: metadata.hasFluxHandlers,
    storeIdentifiers: [...new Set(joined.match(/\b[A-Z][A-Za-z0-9_]*Store\b/g) ?? [])].sort(),
    referencedTokens: tokenCandidates.filter(token => new RegExp(`\\b${token}\\b`).test(joined)),
    nativeFiles: sources.filter(source => /(?:^|\/)native\.[cm]?[jt]s$/.test(source.path)).map(source => source.path),
    scopeFiles: sources.map(({ path, content }) => ({ path, sha256: sha256(content) })),
  };
}

export function portingBlockers(entry, source, metadata, signals, target) {
  const lineAt = offset => source.slice(0, offset).split('\n').length;
  const blockers = [{
    code: 'vencord-plugin-runtime',
    detail: 'This entry exports a Vencord definePlugin object; Yapper does not provide the upstream loader/lifecycle/import aliases.',
    evidence: [{ path: entry.path, line: lineAt(metadata.definitionOffset), symbol: 'definePlugin' }],
  }];
  const webpack = signals.importReferences.filter(reference => reference.specifier.startsWith('@webpack') && !reference.explicitlyTypeOnly);
  if (webpack.length) blockers.push({
    code: 'discord-webpack-imports',
    detail: 'The source declares Discord webpack/common module imports; these are not Yapper module identifiers or a demonstrated Yapper API.',
    evidence: webpack,
  });
  if (metadata.hasPatches) blockers.push({
    code: 'discord-bundle-patches',
    detail: 'The entry declares source patches consumed by Vencord’s Discord webpack patcher. Its find/replacement targets require a host-specific rewrite.',
    evidence: [{ path: entry.path, line: lineAt(metadata.definitionBodyOffset + metadata.patchesOffset), symbol: 'patches' }],
  });
  const discordUtilities = signals.importReferences.filter(reference => reference.specifier === '@utils/discord');
  if (discordUtilities.length) blockers.push({
    code: 'discord-utility-contract',
    detail: 'The source imports Vencord’s Discord utilities, which resolve Discord stores/components rather than Yapper DOM elements.',
    evidence: discordUtilities,
  });
  if (metadata.messageHooks.length) blockers.push({
    code: 'discord-message-lifecycle',
    detail: 'Vencord invokes these hooks through its patched Discord message lifecycle; Yapper has no verified equivalent hook contract.',
    evidence: metadata.messageHooks.map(hook => ({ path: entry.path, line: lineAt(hook.offset), symbol: hook.name })),
  });
  const apiImports = signals.importReferences.filter(reference => reference.specifier.startsWith('@api/') && !reference.explicitlyTypeOnly);
  if (apiImports.length) blockers.push({
    code: 'vencord-api-contract',
    detail: 'The declared Vencord settings/UI/event API imports need an explicit adapter; source presence does not show those APIs exist in Yapper.',
    evidence: apiImports,
  });
  if (signals.nativeFiles.length) blockers.push({
    code: 'upstream-native-module',
    detail: 'The plugin contains a native module compiled into Vencord’s native IPC implementation; this module is not part of the Yapper bridge.',
    evidence: signals.nativeFiles.map(path => ({ path, line: 1, symbol: 'native module' })),
  });
  if (target) blockers.push({
    code: 'upstream-build-target',
    detail: `The entry is gated to the upstream ${target} target. This tag is not a compatibility declaration for Yapper or iOS.`,
    evidence: [{ path: entry.path, line: 1, symbol: target }],
  });
  return blockers;
}

function git(sourceRoot, ...args) {
  return execFileSync('git', ['-c', 'core.fsmonitor=false', '-C', sourceRoot, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

export function generateCatalog(sourceDirectory) {
  const sourceRoot = realpathSync(sourceDirectory);
  const commit = git(sourceRoot, 'rev-parse', 'HEAD');
  if (!/^[a-f0-9]{40}$/.test(commit)) throw new Error('Expected an immutable 40-digit Git commit');
  const evidencePaths = ['src/plugins', 'src/utils/constants.ts', 'src/utils/pluginTargets.ts', 'scripts/build/common.mjs', 'scripts/utils.mjs', 'package.json', 'LICENSE'];
  if (git(sourceRoot, 'status', '--porcelain', '--untracked-files=all', '--', ...evidencePaths)) throw new Error('Refusing to attribute modified/untracked plugin metadata to an upstream commit');
  const manifest = JSON.parse(readSource(sourceRoot, 'package.json'));
  if (manifest.name !== 'vencord') throw new Error('The explicit source directory is not a Vencord source checkout');
  const authorSource = readSource(sourceRoot, 'src/utils/constants.ts');
  const authors = parseAuthors(authorSource);
  const entries = discoverPluginEntries(sourceRoot);
  const plugins = entries.map(entry => {
    const content = readSource(sourceRoot, entry.path);
    let metadata;
    try { metadata = parsePluginMetadata(content, authors); }
    catch (error) { throw new Error(`${entry.path}: ${error.message}`); }
    const id = entry.path.replace(/^src\/plugins\//, '').replace(/\/index\.tsx?$/, '').replace(/\.tsx?$/, '');
    const targetCandidate = id.split('/').at(-1).split('.');
    const target = targetCandidate.length > 1 ? targetCandidate.at(-1) : null;
    if (target !== null && !TARGETS.has(target)) throw new Error(`Unknown upstream build target ${target}: ${entry.path}`);
    const sources = codeFiles(sourceRoot, entry).map(path => ({ path, content: readSource(sourceRoot, path) }));
    const signals = dependencySignals(sources, metadata);
    return {
      id, name: metadata.name, description: metadata.description, authors: metadata.authors,
      kind: id.startsWith('_api/') ? 'api' : id.startsWith('_core/') ? 'core' : 'plugin',
      sourcePath: entry.path, sourceUrl: immutableURL(commit, entry.path), sourceSha256: sha256(content),
      upstreamTarget: target, status: 'requires-port',
      upstreamRequired: metadata.required, upstreamEnabledByDefault: metadata.enabledByDefault,
      upstreamRequiredExpression: metadata.requiredExpression, upstreamEnabledByDefaultExpression: metadata.enabledByDefaultExpression,
      tags: metadata.tags, dependencies: metadata.dependencies,
      signals,
      blockers: portingBlockers(entry, content, metadata, signals, target),
    };
  });
  if (new Set(plugins.map(plugin => plugin.id)).size !== plugins.length || new Set(plugins.map(plugin => plugin.name)).size !== plugins.length) throw new Error('Duplicate plugin identities in the inventory');
  const kindCounts = Object.fromEntries(['plugin', 'api', 'core'].map(kind => [kind, plugins.filter(plugin => plugin.kind === kind).length]));
  const discordBindingCodes = new Set(['discord-webpack-imports', 'discord-bundle-patches', 'discord-utility-contract', 'discord-message-lifecycle']);
  const directDiscordBinding = plugin => plugin.blockers.some(blocker => discordBindingCodes.has(blocker.code));
  return {
    schemaVersion: 1,
    upstream: {
      repository: REPOSITORY, commit, version: manifest.version, license: manifest.license,
      commitDate: git(sourceRoot, 'show', '-s', '--format=%cI', commit),
      licenseSha256: sha256(readSource(sourceRoot, 'LICENSE')),
      authorConstants: { path: 'src/utils/constants.ts', sha256: sha256(authorSource), sourceUrl: immutableURL(commit, 'src/utils/constants.ts') },
      selectionSources: ['scripts/build/common.mjs', 'scripts/utils.mjs', 'src/utils/pluginTargets.ts'].map(path => ({ path, sha256: sha256(readSource(sourceRoot, path)), sourceUrl: immutableURL(commit, path) })),
    },
    coverage: {
      roots: PLUGIN_ROOTS, totalEntries: plugins.length, kindCounts,
      directDiscordBindingEntries: plugins.filter(directDiscordBinding).length,
      publicPluginsWithDirectDiscordBindings: plugins.filter(plugin => plugin.kind === 'plugin' && directDiscordBinding(plugin)).length,
      discordTypeContractEntries: plugins.filter(plugin => plugin.signals.discordTypeImports.length).length,
      blockerCounts: Object.fromEntries([...new Set(plugins.flatMap(plugin => plugin.blockers.map(blocker => blocker.code)))].sort().map(code => [code, plugins.filter(plugin => plugin.blockers.some(blocker => blocker.code === code)).length])),
      targetCounts: Object.fromEntries([null, ...TARGETS].map(target => [target ?? 'unrestricted', plugins.filter(plugin => plugin.upstreamTarget === target).length])),
      selection: 'Union of tracked upstream plugin/API/core entry points, including target-gated entries; not optional local userplugins or a single platform build.',
      inventorySha256: sha256(plugins.map(plugin => `${plugin.sourcePath}\0${plugin.sourceSha256}\n`).join('')),
    },
    limitations: [
      'Plugin modules were read as text and were never imported, evaluated, built, or executed by this generator.',
      'Metadata uses the pinned source formatting and literal Devs references; unsupported formats fail closed instead of being evaluated.',
      'Dependency signals are lexical observations across each entry and its own code/CSS helpers. Tokens/comments/strings may produce false positives; no execution, capability, or transitive-dependency proof is implied.',
      'All upstream entries require a Yapper-specific port. A separately implemented Yapper feature with the same name is not execution of the upstream plugin.',
    ],
    plugins,
  };
}

function main(args) {
  const value = name => { const index = args.indexOf(name); return index >= 0 ? args[index + 1] : undefined; };
  const source = value('--source');
  const output = value('--output');
  const check = value('--check');
  if (!source || (!output && !check) || (output && check)) throw new Error('Usage: node generate-catalog.mjs --source /explicit/Vencord (--output catalog.json | --check catalog.json)');
  const serialized = JSON.stringify(generateCatalog(source), null, 2) + '\n';
  if (check) {
    if (readFileSync(check, 'utf8') !== serialized) throw new Error('Catalog differs from a fresh static inventory of the explicit source checkout');
    console.log('Catalog exactly matches all selected upstream entry points. No plugin code was executed.');
  } else {
    writeFileSync(output, serialized);
    console.log(`Wrote ${JSON.parse(serialized).plugins.length} static catalog entries.`);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
