// Headless, synthetic fixture verification; never logs into the live service.
// SPDX-License-Identifier: MIT
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const directory = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(directory, 'appearance.js'), 'utf8');
const fixture = fs.readFileSync(path.join(directory, 'fixtures/real-structure.html'), 'utf8');
const css = fs.readFileSync(path.join(directory, 'fixtures/fixture-base.css'), 'utf8');

(async () => {
  const browser = await chromium.launch({ headless: true });
  const results = [];
  try {
    for (const [name, width, height] of [['desktop', 1280, 900], ['tablet', 834, 1112], ['phone', 390, 844]]) {
      const page = await browser.newPage({ viewport: { width, height }, reducedMotion: 'reduce' });
      const errors = []; const unexpected = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.route('**/*', route => {
        const url = new URL(route.request().url());
        if (url.origin === 'https://www.yapper.website' && url.pathname === '/fixture') return route.fulfill({ contentType: 'text/html', body: fixture });
        if (url.origin === 'https://www.yapper.website' && url.pathname === '/fixture-base.css') return route.fulfill({ contentType: 'text/css', body: css });
        unexpected.push(url.href); return route.abort();
      });
      await page.goto('https://www.yapper.website/fixture');
      const before = await page.evaluate(() => {
        window.originalWho = document.querySelector('.who');
        window.originalAvatar = document.querySelector('.who .avatar');
        window.originalNav = document.querySelector('.nl-tabbar');
        return { font: getComputedStyle(document.body).fontFamily, color: getComputedStyle(document.body).color, draft: document.querySelector('textarea').value };
      });
      await page.addScriptTag({ content: source });
      const initial = await page.evaluate(() => window.YapperAppearance.getState());
      assert.equal(initial.accounts, 1); assert.equal(initial.profiles, 0); assert.equal(initial.navigation, 1);
      assert.equal(await page.evaluate(() => window.originalWho === document.querySelector('.who') && window.originalAvatar === document.querySelector('.who .avatar') && window.originalNav === document.querySelector('.nl-tabbar')), true);
      const account = await page.locator('[data-ypa-account]').boundingBox();
      assert.ok(account.x >= 0 && account.x + account.width <= width + 1);
      const navVisible = await page.locator('.nl-tabbar').isVisible();
      if (name === 'phone') {
        assert.equal(navVisible, true);
        const nav = await page.locator('[data-ypa-nav]').boundingBox();
        assert.ok(nav.x > 0 && nav.x + nav.width < width && nav.y + nav.height <= height);
        assert.ok(account.y + account.height < nav.y, 'account strip and floating navigation must not overlap');
        await page.locator('.nl-tabbar>.nl-tab').nth(1).click();
        assert.equal(await page.evaluate(() => document.body.dataset.navigationClicks), '1');
      }
      if (process.env.APPEARANCE_SCREENSHOTS) {
        fs.mkdirSync(process.env.APPEARANCE_SCREENSHOTS, { recursive: true });
        await page.screenshot({ path: path.join(process.env.APPEARANCE_SCREENSHOTS, `appearance-${name}-account.png`) });
      }
      assert.equal(await page.evaluate(() => window.YapperAppearance.openProfile()), true);
      await page.waitForSelector('[data-ypa-profile]');
      const profile = await page.locator('[data-ypa-profile-shell]').boundingBox();
      assert.ok(profile.x >= 0 && profile.x + profile.width <= width + 1);
      assert.ok(profile.y >= 0 && profile.y + profile.height <= height + 1);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await page.locator('[data-fixture-tab="servers"]').click();
      await page.locator('[data-fixture-edit]').click();
      assert.equal(await page.evaluate(() => document.body.dataset.selectedTab), 'servers');
      assert.equal(await page.evaluate(() => document.body.dataset.editClicks), '1');
      const after = await page.evaluate(() => ({ font: getComputedStyle(document.body).fontFamily, color: getComputedStyle(document.body).color, draft: document.querySelector('textarea').value }));
      assert.deepEqual(after, before);
      if (process.env.APPEARANCE_SCREENSHOTS) {
        fs.mkdirSync(process.env.APPEARANCE_SCREENSHOTS, { recursive: true });
        await page.screenshot({ path: path.join(process.env.APPEARANCE_SCREENSHOTS, `appearance-${name}-profile.png`) });
      }
      await page.locator('.pc-close').click();
      await page.waitForFunction(() => window.YapperAppearance.getState().profiles === 0);
      await page.evaluate(() => {
        const old = document.querySelector('.user-bar');
        window.detachedAccount = old;
        old.remove();
      });
      await page.waitForFunction(() => window.YapperAppearance.getState().accounts === 0);
      assert.equal(await page.evaluate(() => window.detachedAccount.hasAttribute('data-ypa-account')), false);
      await page.evaluate(() => document.querySelector('.sidebar').append(window.detachedAccount));
      await page.waitForFunction(() => window.YapperAppearance.getState().accounts === 1);
      await page.addScriptTag({ content: source });
      assert.equal(await page.locator('[data-yapper-appearance-style]').count(), 1);
      const disposed = await page.evaluate(async () => {
        const retained = window.YapperAppearance; retained.destroy();
        const state = retained.getState();
        return { absent: !window.YapperAppearance, disposed: state.disposed, refreshed: retained.refresh(), opened: await retained.openProfile(), attrs: document.querySelectorAll('[data-ypa-account],[data-ypa-profile],[data-ypa-profile-frame],[data-ypa-profile-shell],[data-ypa-nav],[data-yapper-appearance],[data-yapper-appearance-style]').length };
      });
      assert.deepEqual(disposed, { absent: true, disposed: true, refreshed: false, opened: false, attrs: 0 });
      assert.deepEqual(errors, []); assert.deepEqual(unexpected, []);
      results.push({ viewport: name, width, height, preservedNodesAndActions: true, safeGeometry: true, reversible: true, networkRequests: 0 });
      await page.close();
    }
    const anonymous = await browser.newPage();
    await anonymous.route('**/*', route => route.fulfill({ contentType: 'text/html', body: '<!doctype html><html><head></head><body><main>Anonymous login fixture</main></body></html>' }));
    await anonymous.goto('https://www.yapper.website/anonymous');
    await anonymous.addScriptTag({ content: source });
    const state = await anonymous.evaluate(() => window.YapperAppearance.getState());
    assert.equal(state.active, true); assert.equal(state.accounts, 0); assert.equal(state.profiles, 0);
    assert.equal(await anonymous.evaluate(() => window.YapperAppearance.openProfile()), false);
    await anonymous.close();
    console.log(JSON.stringify({ fixtureOnly: true, viewports: results, anonymousAPI: true }, null, 2));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
