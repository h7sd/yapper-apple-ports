const { test } = require('node:test');
const assert = require('node:assert/strict');
const { trustedURL, cleanURL, cleanText, sanitizeSettings, replaceText, IDS } = require('../runtime');
test('origin guard rejects credentials, frames handled by runtime, nonstandard ports and lookalike hosts', () => {
    assert(trustedURL('https://yapin.gg/'));
    assert(trustedURL('https://www.yapper.website:443/chat'));
    for (const value of ['http://yapin.gg', 'https://yapin.gg:444', 'https://yapin.gg.evil.test', 'https://x@yapin.gg', 'data:text/html,x', 'file:///tmp/yapin.gg']) assert.equal(trustedURL(value), false);
});
test('cleaner preserves useful parameters, fragments, invalid and credentialed URLs', () => {
    assert.equal(cleanURL('https://example.com/a?id=2&utm_source=spam&fbclid=x#photo'), 'https://example.com/a?id=2#photo');
    for (const value of ['https://example.com/a?token=private&ref=needed#z', 'not a URL', 'https://u:p@example.com/?utm_x=a', 'mailto:x@y.test']) assert.equal(cleanURL(value), value);
    assert.equal(cleanText('See https://x.test/?utm_source=x&id=2. Thanks!'), 'See https://x.test/?id=2. Thanks!');
});
test('settings import never carries account state or unknown plugin code', () => {
    const s = sanitizeSettings({ schemaVersion: 1, token: 'private', plugins: { CharacterCounter: true, Unknown: true }, replacements: [{ from: 'hi', to: 'hello' }], customCSS: 'body { color: white; }' });
    assert.deepEqual(Object.keys(s).sort(), ['customCSS', 'plugins', 'replacements', 'schemaVersion']);
    assert.equal(Object.keys(s.plugins).length, IDS.length); assert(!('Unknown' in s.plugins));
    assert.throws(() => sanitizeSettings({ schemaVersion: 2 }));
});
test('local CSS rejects encoded/commented network and executable constructs', () => {
    for (const css of ['@import "https://evil.test";', 'body{background:url(https://e.test)}', 'body{background:u\\72l(x)}', 'body{background:u/**/rl(x)}', 'body{background:image-set("https://e.test" 1x)}', 'body{width:expression(x)}']) assert.throws(() => sanitizeSettings({ schemaVersion: 1, customCSS: css }));
});
test('literal replacements are longest-first, bounded and nonrecursive', () => {
    assert.equal(replaceText('abc a $1', [{ from: 'a', to: 'b' }, { from: 'abc', to: 'x' }, { from: '$1', to: '$&' }]), 'x b $&');
    assert.deepEqual(sanitizeSettings({ schemaVersion: 1, replacements: [{ from: '', to: 'x' }, { from: 'ok', to: 'yes' }] }).replacements, [{ from: 'ok', to: 'yes' }]);
});
