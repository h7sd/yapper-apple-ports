'use strict';

// The runner exports the actual Swift source. There is deliberately no second
// implementation of the shipping bridge in this test file.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const test = require('node:test');
const vm = require('node:vm');

for (const name of ['BROWSER_LOGIN_SCRIPT_PATH', 'BROWSER_LOGIN_API_HOST', 'BROWSER_LOGIN_FLOW_ID']) {
  assert.ok(process.env[name], `Run scripts/test-web-login-bridge.py (${name} missing)`);
}
const source = fs.readFileSync(process.env.BROWSER_LOGIN_SCRIPT_PATH, 'utf8');
const apiOrigin = `https://${process.env.BROWSER_LOGIN_API_HOST}`;
const tokenURL = `${apiOrigin}/auth/v1/token?grant_type=password`;
const flowID = process.env.BROWSER_LOGIN_FLOW_ID;
const tokens = {access_token: 'a'.repeat(64), refresh_token: 'r'.repeat(32)};

function forbidden(object, name, reads) {
  Object.defineProperty(object, name, {
    configurable: true,
    get() { reads.push(name); throw new Error(`Forbidden read: ${name}`); },
  });
}

function reply(url = tokenURL, options = {}) {
  const counters = {clone: 0, text: 0, originalRead: 0};
  const body = options.text ?? JSON.stringify(options.data ?? tokens);
  const response = {
    url,
    ok: options.ok ?? true,
    redirected: options.redirected ?? false,
    bodyUsed: false,
    clone() {
      counters.clone++;
      return {
        headers: {get(name) { assert.equal(name, 'content-length'); return options.length ?? null; }},
        async text() { counters.text++; return body; },
      };
    },
    async text() { counters.originalRead++; throw new Error('Original body must stay unread'); },
    async json() { counters.originalRead++; throw new Error('Original body must stay unread'); },
  };
  return {response, counters, body};
}

function createHarness(options = {}) {
  const messages = [];
  const reads = [];
  const calls = [];
  const elements = new Map();
  const attributes = new Map();
  const location = new URL(options.pageURL ?? 'https://yapin.gg/');
  class MetadataOnlyRequest {
    constructor(url, method = 'POST') {
      this.url = url;
      this.method = method;
      for (const name of ['body', 'bodyUsed', 'headers', 'text', 'json', 'formData', 'clone']) forbidden(this, name, reads);
    }
  }
  const document = {
    getElementById(id) { assert.equal(id, 'yapin-native-handoff-shield'); return elements.get(id); },
    createElement(tag) { assert.equal(tag, 'style'); return {}; },
    head: {appendChild(element) { elements.set(element.id, element); }},
    documentElement: {
      setAttribute(name, value) { attributes.set(name, value); },
      removeAttribute(name) { attributes.delete(name); },
    },
  };
  for (const name of ['cookie', 'forms', 'querySelector', 'querySelectorAll', 'getElementsByTagName']) forbidden(document, name, reads);
  const originalFetch = options.originalFetch ?? async function(...args) {
    calls.push({thisValue: this, args});
    return options.reply?.response ?? reply().response;
  };
  const context = {location, document, URL, Request: MetadataOnlyRequest, fetch: originalFetch};
  context.window = context;
  context.top = options.mainFrame === false ? {} : context;
  context.webkit = {messageHandlers: {yapinNativeSignIn: {postMessage(message) {
    messages.push(JSON.parse(JSON.stringify(message)));
  }}}};
  for (const name of ['localStorage', 'sessionStorage', 'indexedDB', 'cookieStore', 'password', 'credentials']) forbidden(context, name, reads);
  vm.runInNewContext(source, context, {timeout: 1000, filename: 'BrowserLoginScript.exported.js'});
  return {context, originalFetch, messages, reads, calls, elements, attributes, Request: MetadataOnlyRequest};
}

async function settle() {
  // clone.text(), JSON decode and its catch are intentionally detached from fetch.
  for (let turn = 0; turn < 6; turn++) await Promise.resolve();
}

async function invoke(harness, input = tokenURL, init = {method: 'POST'}) {
  const response = await harness.context.fetch(input, init);
  await settle();
  return response;
}

test('exports the actual Swift bridge with the current host and per-flow nonce', () => {
  assert.ok(source.includes(apiOrigin.slice('https://'.length)));
  assert.ok(source.includes(flowID));
  assert.ok(!source.includes('__NATIVE_'));
});

test('installs only in the main frame of an exact official HTTPS origin at the root route', async t => {
  for (const pageURL of [
    'http://yapin.gg/', 'https://yapin.gg.evil.test/', 'https://evil.test/',
    'https://yapin.gg:444/', 'https://www.yapin.gg:8443/',
    'https://yapin.gg/settings', 'https://yapin.gg/login', 'https://yapin.gg/api/login',
  ]) {
    await t.test(pageURL, () => {
      const harness = createHarness({pageURL});
      assert.equal(harness.context.fetch, harness.originalFetch);
      assert.deepEqual(harness.reads, []);
    });
  }
  await t.test('subframes are excluded even at the official URL', () => {
    const harness = createHarness({mainFrame: false});
    assert.equal(harness.context.fetch, harness.originalFetch);
  });
  for (const pageURL of ['https://yapin.gg/', 'https://www.yapin.gg/', 'https://yapin.gg:443/']) {
    await t.test(pageURL, () => {
      const harness = createHarness({pageURL});
      assert.notEqual(harness.context.fetch, harness.originalFetch);
    });
  }
});

test('does not probe existing cookies, storage, passwords or make a request while installing', () => {
  const harness = createHarness();
  assert.deepEqual(harness.calls, []);
  assert.deepEqual(harness.messages, []);
  assert.deepEqual(harness.reads, []);
});

test('leaves an unavailable fetch implementation alone', () => {
  const harness = createHarness({originalFetch: 'unavailable'});
  assert.equal(harness.context.fetch, 'unavailable');
  assert.deepEqual(harness.messages, []);
  assert.deepEqual(harness.reads, []);
});

test('passes through the original fetch arguments and this value unchanged', async () => {
  const result = reply();
  const harness = createHarness({reply: result});
  const input = new harness.Request(tokenURL);
  const init = {method: 'post'};
  forbidden(init, 'body', harness.reads);
  forbidden(init, 'headers', harness.reads);
  const receiver = {marker: 'caller'};
  const returned = await harness.context.fetch.call(receiver, input, init);
  await settle();
  assert.equal(returned, result.response);
  assert.equal(harness.calls[0].thisValue, receiver);
  assert.equal(harness.calls[0].args[0], input);
  assert.equal(harness.calls[0].args[1], init);
  assert.deepEqual(harness.reads, []);
  assert.equal(harness.messages.length, 1);
});

test('captures only the minimal successful response fields and current flow nonce', async () => {
  const result = reply(tokenURL, {data: {...tokens, user: {email: 'ignored@example.invalid'}, password: 'never forwarded', expires_in: 3600, provider_token: 'ignored'}});
  const harness = createHarness({reply: result});
  await invoke(harness);
  assert.deepEqual(harness.messages, [{
    flow: flowID, responseURL: tokenURL, method: 'POST',
    accessToken: tokens.access_token, refreshToken: tokens.refresh_token,
  }]);
  assert.ok(harness.elements.has('yapin-native-handoff-shield'));
  assert.equal(harness.attributes.get('data-yapin-native-handoff'), '');
  assert.deepEqual(harness.reads, []);
});

test('reads a clone and leaves the original response object and body untouched', async () => {
  const result = reply();
  Object.freeze(result.response);
  const harness = createHarness({reply: result});
  const returned = await invoke(harness);
  assert.equal(returned, result.response);
  assert.equal(returned.bodyUsed, false);
  assert.deepEqual(result.counters, {clone: 1, text: 1, originalRead: 0});
});

test('supports URL input and Request metadata without reading their bodies', async t => {
  for (const kind of ['url', 'request']) {
    await t.test(kind, async () => {
      const harness = createHarness({reply: reply()});
      const input = kind === 'url' ? new URL(tokenURL) : new harness.Request(tokenURL, 'POST');
      if (kind === 'request') {
        await harness.context.fetch(input);
        await settle();
      } else {
        await invoke(harness, input, {method: 'POST'});
      }
      assert.equal(harness.messages.length, 1);
      assert.deepEqual(harness.reads, []);
    });
  }
});

test('allows only the canonical password, identity-token, factor-verify and same-origin username endpoints', async t => {
  for (const url of [
    tokenURL,
    `${apiOrigin}/auth/v1/token?grant_type=id_token`,
    `${apiOrigin}/auth/v1/factors/4B742CA9-FA00-4DAB-BC82-750C5416739A/verify`,
    'https://yapin.gg/api/login',
    'https://www.yapin.gg/api/login',
  ]) {
    await t.test(url, async () => {
      const pageURL = url.startsWith('https://www.yapin.gg/') ? 'https://www.yapin.gg/' : 'https://yapin.gg/';
      const harness = createHarness({pageURL, reply: reply(url)});
      await invoke(harness, url);
      assert.equal(harness.messages.length, 1);
      assert.equal(harness.messages[0].responseURL, url);
    });
  }
});

test('resolves a relative same-origin username request to its exact HTTPS URL', async () => {
  const harness = createHarness({reply: reply('https://yapin.gg/api/login')});
  await invoke(harness, '/api/login');
  assert.equal(harness.messages.length, 1);
  assert.equal(harness.messages[0].responseURL, 'https://yapin.gg/api/login');
});

test('rejects GET and other methods, including a method override of a Request', async t => {
  for (const method of ['GET', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS']) {
    await t.test(method, async () => {
      const harness = createHarness({reply: reply()});
      await invoke(harness, new harness.Request(tokenURL, 'POST'), {method});
      assert.deepEqual(harness.messages, []);
    });
  }
  await t.test('an unqualified string fetch defaults to GET', async () => {
    const harness = createHarness({reply: reply()});
    await harness.context.fetch(tokenURL);
    await settle();
    assert.deepEqual(harness.messages, []);
  });
});

test('ignores foreign, noncanonical and non-login auth endpoints before cloning a body', async t => {
  for (const url of [
    'https://evil.test/auth/v1/token?grant_type=password',
    `${apiOrigin}.evil.test/auth/v1/token?grant_type=password`,
    tokenURL.replace('https:', 'http:'),
    tokenURL.replace('/auth/', ':444/auth/'),
    tokenURL.replace('https://', 'https://user:secret@'),
    `${tokenURL}#fragment`,
    `${apiOrigin}/auth/v1/token`,
    `${apiOrigin}/auth/v1/token?grant_type=refresh_token`,
    `${apiOrigin}/auth/v1/token?grant_type=password&extra=1`,
    `${apiOrigin}/auth/v1/token?grant_type=password&grant_type=password`,
    `${apiOrigin}/auth/v1/user`,
    `${apiOrigin}/auth/v1/verify`,
    `${apiOrigin}/auth/v1/factors/not-a-uuid/verify`,
    `${apiOrigin}/auth/v1/factors/4B742CA9-FA00-4DAB-BC82-750C5416739A/verify?extra=1`,
    `${apiOrigin}/auth//v1/factors/4B742CA9-FA00-4DAB-BC82-750C5416739A/verify`,
    `${apiOrigin}/auth/v1/factors/4B742CA9-FA00-4DAB-BC82-750C5416739A/verify/`,
    `${apiOrigin}/auth/v1/factors//4B742CA9-FA00-4DAB-BC82-750C5416739A/verify`,
    'https://yapin.gg/api/login?extra=1',
    'https://yapin.gg/api/login/extra',
    'https://www.yapin.gg/api/login',
  ]) {
    await t.test(url, async () => {
      const result = reply(url);
      const harness = createHarness({reply: result});
      await invoke(harness, url);
      assert.deepEqual(harness.messages, []);
      assert.equal(result.counters.clone, 0);
    });
  }
});

test('requires a successful, nonredirected response at exactly the requested URL', async t => {
  for (const scenario of [
    {name: 'failed response', url: tokenURL, options: {ok: false}},
    {name: 'redirect flag', url: tokenURL, options: {redirected: true}},
    {name: 'another allowed URL', url: `${apiOrigin}/auth/v1/token?grant_type=id_token`},
    {name: 'foreign response', url: 'https://evil.test/auth/v1/token?grant_type=password'},
    {name: 'missing response URL', url: ''},
  ]) {
    await t.test(scenario.name, async () => {
      const result = reply(scenario.url, scenario.options);
      const harness = createHarness({reply: result});
      await invoke(harness);
      assert.deepEqual(harness.messages, []);
      assert.equal(result.counters.clone, 0);
    });
  }
});

test('drops pending handoffs when the official page leaves its login root route', async t => {
  await t.test('route changed while the original fetch was pending', async () => {
    const pending = Promise.withResolvers();
    const result = reply();
    const harness = createHarness({originalFetch: () => pending.promise});
    const fetching = harness.context.fetch(tokenURL, {method: 'POST'});
    harness.context.location.pathname = '/terms';
    pending.resolve(result.response);
    assert.equal(await fetching, result.response);
    await settle();
    assert.deepEqual(harness.messages, []);
    assert.equal(result.counters.clone, 0);
    assert.equal(harness.attributes.has('data-yapin-native-handoff'), false);
  });
  await t.test('route changed while cloned response text was pending', async () => {
    const pending = Promise.withResolvers();
    const result = reply();
    result.response.clone = () => ({headers: {get: () => null}, text: () => pending.promise});
    const harness = createHarness({reply: result});
    assert.equal(await harness.context.fetch(tokenURL, {method: 'POST'}), result.response);
    harness.context.location.pathname = '/privacy';
    pending.resolve(result.body);
    await settle();
    assert.deepEqual(harness.messages, []);
    assert.equal(harness.attributes.has('data-yapin-native-handoff'), false);
  });
  await t.test('a request begun on another route cannot become a root-page login later', async () => {
    const pending = Promise.withResolvers();
    const result = reply();
    const harness = createHarness({originalFetch: () => pending.promise});
    harness.context.location.pathname = '/settings';
    const fetching = harness.context.fetch(tokenURL, {method: 'POST'});
    harness.context.location.pathname = '/';
    pending.resolve(result.response);
    assert.equal(await fetching, result.response);
    await settle();
    assert.deepEqual(harness.messages, []);
    assert.equal(result.counters.clone, 0);
  });
});

test('rejects oversized declared response bodies without reading clone text', async () => {
  const result = reply(tokenURL, {length: '131073'});
  const harness = createHarness({reply: result});
  await invoke(harness);
  assert.deepEqual(harness.messages, []);
  assert.equal(result.counters.text, 0);
});

test('rejects oversized actual text even when the header is absent or misleading', async t => {
  for (const length of [undefined, '1']) {
    await t.test(String(length), async () => {
      const result = reply(tokenURL, {text: JSON.stringify({...tokens, padding: 'x'.repeat(131073)}), length});
      const harness = createHarness({reply: result});
      await invoke(harness);
      assert.deepEqual(harness.messages, []);
      assert.equal(result.counters.text, 1);
    });
  }
});

test('ignores malformed JSON, missing tokens, wrong types and oversized individual tokens', async t => {
  for (const text of [
    '{', 'null', '[]', 'true', '{}',
    JSON.stringify({access_token: tokens.access_token}),
    JSON.stringify({refresh_token: tokens.refresh_token}),
    JSON.stringify({access_token: 123, refresh_token: tokens.refresh_token}),
    JSON.stringify({access_token: tokens.access_token, refresh_token: {value: 'no'}}),
    JSON.stringify({access_token: 'a'.repeat(16385), refresh_token: tokens.refresh_token}),
    JSON.stringify({access_token: tokens.access_token, refresh_token: 'r'.repeat(4097)}),
  ]) {
    await t.test(text.length > 100 ? `oversized token (${text.length} chars)` : text, async () => {
      const harness = createHarness({reply: reply(tokenURL, {text})});
      await invoke(harness);
      assert.deepEqual(harness.messages, []);
      assert.equal(harness.attributes.has('data-yapin-native-handoff'), false);
    });
  }
});

test('preserves a successful fetch result if clone or bridge delivery fails', async t => {
  await t.test('clone throws', async () => {
    const result = reply();
    result.response.clone = () => { throw new Error('clone failed'); };
    const harness = createHarness({reply: result});
    assert.equal(await invoke(harness), result.response);
    assert.deepEqual(harness.messages, []);
  });
  await t.test('clone text rejects', async () => {
    const result = reply();
    result.response.clone = () => ({headers: {get: () => null}, text: async () => { throw new Error('read failed'); }});
    const harness = createHarness({reply: result});
    assert.equal(await invoke(harness), result.response);
    assert.deepEqual(harness.messages, []);
  });
  await t.test('native handler throws', async () => {
    const result = reply();
    const harness = createHarness({reply: result});
    harness.context.webkit.messageHandlers.yapinNativeSignIn.postMessage = () => { throw new Error('view closed'); };
    assert.equal(await invoke(harness), result.response);
  });
});

test('propagates the original fetch rejection unchanged', async () => {
  const expected = new Error('offline transport failure');
  const harness = createHarness({originalFetch: async () => { throw expected; }});
  await assert.rejects(harness.context.fetch(tokenURL, {method: 'POST'}), error => error === expected);
  assert.deepEqual(harness.messages, []);
  assert.deepEqual(harness.reads, []);
});
