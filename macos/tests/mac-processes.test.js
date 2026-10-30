'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { execFile } = require('node:child_process');
const { listMacProcesses, parseWorkspaceApplications, parsePsApplications } = require('../mac-processes');

test('NSWorkspace parses real executable identities, aliases, and literal display names', () => {
  const processes = parseWorkspaceApplications(JSON.stringify([
    { executable: '/Applications/Roblox.app/Contents/MacOS/RobloxPlayer', localizedName: 'Roblox' },
    { executable: '/Games/Stardew Valley.app/Contents/MacOS/StardewValley', localizedName: 'Stardew Valley' },
    { executable: '/Games/Terraria.app/Contents/MacOS/Terraria', localizedName: 'Terraria' },
    { executable: '/Games/BG3.app/Contents/MacOS/bg3', localizedName: "Baldur's Gate 3" },
    { executable: '/Games/Other.app/Contents/MacOS/Other', localizedName: 'RobloxPlayer' },
    { executable: '/Games/Odd.app/Contents/MacOS/odd$(touch sentinel)', localizedName: 'Quotes " and `backticks`' },
  ]));
  assert.deepEqual([...processes.keys()], ['robloxplayer', 'stardew valley', 'terraria', 'bg3.exe', 'other', 'odd$(touch sentinel)']);
  assert.deepEqual(processes.get('bg3.exe'), { name: 'bg3.exe', windowed: null, title: "Baldur's Gate 3" });
  assert.equal(processes.get('other').title, 'RobloxPlayer');
});

test('helper executables never become game activities and duplicates retain distinct names once', () => {
  const processes = parseWorkspaceApplications(JSON.stringify([
    { executable: '/Applications/Roblox.app/Contents/MacOS/RobloxPlayerLauncher', localizedName: 'Roblox' },
    { executable: '/Applications/Roblox.app/Contents/MacOS/RobloxPlayerInstaller', localizedName: 'Roblox' },
    { executable: '/Games/Terraria.app/Contents/MacOS/Terraria', localizedName: 'Terraria' },
    { executable: '/Games/Terraria.app/Contents/MacOS/Terraria', localizedName: 'Terraria' },
    { executable: '/Games/Terraria.app/Contents/MacOS/Terraria', localizedName: 'Terraria 2' },
    null, {}, { executable: 42 },
  ]));
  assert.equal(processes.size, 1);
  assert.equal(processes.get('terraria').title, 'Terraria\nTerraria 2');
  assert.equal(processes.get('terraria').windowed, null);
});

test('ps fallback keeps top-level app executables and rejects daemons, nested helpers, and path-derived aliases', () => {
  const processes = parsePsApplications([
    '  /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder',
    '/Applications/Stardew Valley.app/Contents/MacOS/StardewValley',
    '/Games/Baldur\'s Gate 3.app/Contents/MacOS/Baldur\'s Gate 3',
    '/Games/Counter-Strike 2.app/Contents/MacOS/Launcher',
    '/Games/Counter-Strike 2.app/Contents/MacOS/cs2',
    '/Applications/Roblox.app/Contents/MacOS/RobloxPlayer',
    '/Applications/Roblox.app/Contents/MacOS/RobloxPlayer',
    '/Applications/Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper',
    '/Applications/Foo.app/Contents/Helpers/Nested.app/Contents/MacOS/RealGame',
    '/Applications/Steam.app/Contents/MacOS/steam_osx',
    '/usr/libexec/gamecontrollerd',
    '/usr/bin/java',
    'RobloxPlayer',
    '/Games/NotAnApp/Contents/MacOS/Terraria',
    '/Games/Terraria.app/Contents/MacOS/Terraria/child',
    '/Games/Test Launcher.app/Contents/MacOS/executable',
    '/Games/Quotes " $(touch sentinel).app/Contents/MacOS/Quoted Game',
  ].join('\n'));
  assert.deepEqual([...processes.keys()], ['finder', 'stardew valley', 'baldursgate3', 'cs2.exe', 'robloxplayer', 'steam_osx', 'quoted game']);
  assert.equal(processes.get('quoted game').title, 'Quotes " $(touch sentinel)');
  assert.equal(processes.get('stardew valley').title, 'Stardew Valley');
});

test('JXA runs through fixed execFile arguments, never through a shell or dynamic process text', async () => {
  const calls = [];
  const processes = await listMacProcesses(async (...args) => {
    calls.push(args);
    return JSON.stringify([{ executable: '/Apps/Literal.app/Contents/MacOS/a";$(touch sentinel)', localizedName: 'Literal' }]);
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], '/usr/bin/osascript');
  assert.deepEqual(calls[0][1].slice(0, 3), ['-l', 'JavaScript', '-e']);
  assert.equal(calls[0][1].length, 4);
  assert.match(calls[0][1][3], /NSWorkspace/);
  assert.doesNotMatch(calls[0][1][3], /System Events|Application\(/);
  assert.equal(calls[0][2].timeout, 8_000);
  assert.ok(processes.has('a";$(touch sentinel)'));
});

test('valid empty NSWorkspace result is authoritative; malformed or failed queries use ps once', async () => {
  let calls = 0;
  assert.equal((await listMacProcesses(async () => { calls++; return '[]'; })).size, 0);
  assert.equal(calls, 1);
  for (const failure of [null, '', 'not JSON', '{}', new Error('unavailable')]) {
    const argumentsSeen = [];
    const processes = await listMacProcesses(async (command, args) => {
      argumentsSeen.push([command, args]);
      if (argumentsSeen.length === 1) {
        if (failure instanceof Error) throw failure;
        return failure;
      }
      return '/Applications/Terraria.app/Contents/MacOS/Terraria\n/usr/sbin/daemon';
    });
    assert.equal(argumentsSeen.length, 2);
    assert.deepEqual(argumentsSeen[1], ['/bin/ps', ['-axo', 'comm=']]);
    assert.deepEqual([...processes.keys()], ['terraria']);
  }
});

test('both enumeration backends failing returns an empty map', async () => {
  assert.equal((await listMacProcesses(async () => { throw new Error('blocked'); })).size, 0);
});

test('macOS NSWorkspace probe executes read-only and emits structured app rows', { skip: process.platform !== 'darwin' }, async () => {
  const calls = [];
  const processes = await listMacProcesses((command, args, options) => {
    calls.push(command);
    return new Promise((resolve, reject) => execFile(command, args, options, (error, output) => error ? reject(error) : resolve(output)));
  });
  assert.deepEqual(calls, ['/usr/bin/osascript'], 'NSWorkspace should work without needing the ps fallback');
  assert.ok(processes instanceof Map);
  for (const [key, process] of processes) {
    assert.equal(process.name, key);
    assert.equal(process.windowed, null);
    assert.equal(typeof process.title, 'string');
  }
});
