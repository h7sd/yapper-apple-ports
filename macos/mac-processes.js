'use strict';

const path = require('node:path');

// NSWorkspace is a local AppKit query. It does not send Apple Events to other
// applications or need System Events, Automation, or Accessibility permission.
// A regular application may still have no visible windows, so windowed remains
// unknown. Its localized name is an application name, not a window title.
const WORKSPACE_SCRIPT = `ObjC.import('AppKit');
const applications = $.NSWorkspace.sharedWorkspace.runningApplications;
const result = [];
for (let i = 0; i < applications.count; i++) {
  const application = applications.objectAtIndex(i);
  if (Number(application.activationPolicy) !== 0 || application.terminated) continue;
  const executable = application.executableURL;
  if (!executable || executable.isNil()) continue;
  result.push({
    executable: ObjC.unwrap(executable.path),
    localizedName: ObjC.unwrap(application.localizedName) || ''
  });
}
JSON.stringify(result);`;

// Exact executable aliases bridge the existing cross-platform game catalog.
// Never infer a running game from an app display name, launcher, or parent path.
// In particular, cs2 is recognized only if that executable is actually running;
// this does not imply that Counter-Strike 2 has a native macOS release.
const EXECUTABLE_ALIASES = new Map([
  ['stardewvalley', 'stardew valley'],
  ['cs2', 'cs2.exe'],
  ['csgo_osx64', 'csgo.exe'],
  ['dota2', 'dota2.exe'],
  ['rust', 'rust.exe'],
  ['bg3', 'bg3.exe'],
  ["baldur's gate 3", 'baldursgate3'],
]);

const HELPER_NAME = /(?:helper|launcher|installer|updater|crashpad|crashreport|bootstrap|renderer|gpu process|plugin-container)/i;

function normalizedExecutable(executable) {
  const base = path.posix.basename(executable).toLowerCase();
  return EXECUTABLE_ALIASES.get(base) || base;
}

function addProcess(processes, executable, title) {
  if (typeof executable !== 'string' || !executable || executable.includes('\0')) return;
  const base = path.posix.basename(executable);
  if (!base || HELPER_NAME.test(base)) return;
  const name = normalizedExecutable(executable);
  const displayName = typeof title === 'string' ? title.trim() : '';
  const previous = processes.get(name);
  // Multiple instances are one program. Preserve distinct application names
  // without repeating the same title every time another instance is found.
  const titles = new Set((previous?.title || '').split('\n').filter(Boolean));
  if (displayName) titles.add(displayName);
  processes.set(name, { name, windowed: null, title: [...titles].join('\n') });
}

function parseWorkspaceApplications(output) {
  if (typeof output !== 'string') return null;
  let applications;
  try { applications = JSON.parse(output); } catch { return null; }
  if (!Array.isArray(applications)) return null;
  const processes = new Map();
  for (const application of applications) {
    if (!application || typeof application !== 'object') continue;
    addProcess(processes, application.executable, application.localizedName);
  }
  return processes;
}

function parsePsApplications(output) {
  const processes = new Map();
  for (const line of (typeof output === 'string' ? output : '').split(/\r?\n/)) {
    const executable = line.trim();
    // comm= is a path, not a shell command line: keep spaces and quotes literal.
    // Only the main executable directly in an application's MacOS directory is
    // eligible. Nested helper .apps and Frameworks must not become activities.
    const match = /^(\/.*\.app)\/Contents\/MacOS\/([^/]+)$/.exec(executable);
    if (!match || /\/Contents\//.test(match[1])) continue;
    const applicationName = path.posix.basename(match[1], '.app');
    if (HELPER_NAME.test(applicationName)) continue;
    addProcess(processes, executable, applicationName);
  }
  return processes;
}

async function listMacProcesses(run) {
  if (typeof run !== 'function') throw new TypeError('listMacProcesses requires an execFile-style run function');
  let workspaceOutput = null;
  try {
    workspaceOutput = await run('/usr/bin/osascript', ['-l', 'JavaScript', '-e', WORKSPACE_SCRIPT], { timeout: 8_000 });
  } catch { /* A missing/blocked JXA runtime uses the bounded ps fallback. */ }
  const applications = parseWorkspaceApplications(workspaceOutput);
  if (applications !== null) return applications;
  let psOutput = null;
  try { psOutput = await run('/bin/ps', ['-axo', 'comm='], { timeout: 8_000 }); } catch { /* Match the existing empty-list behavior. */ }
  return parsePsApplications(psOutput);
}

module.exports = { listMacProcesses, parseWorkspaceApplications, parsePsApplications };
