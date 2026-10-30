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
    const viewports = [['desktop', 1280, 900], ['tablet', 834, 1112], ['compact-phone', 320, 667],
      ['phone', 390, 844], ['phone-402', 402, 874], ['phone-414', 414, 896],
      ['phone-428', 428, 926], ['phone-430', 430, 932], ['pro-max', 440, 956]];
    for (const look of ['original', 'new-look']) for (const [viewport, width, height] of viewports) {
      const name = `${look}-${viewport}`;
      const mobile = width <= 760;
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
      await page.evaluate(look => document.documentElement.classList.toggle('new-look', look === 'new-look'), look);
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
      let accountGeometry = null;
      if (mobile) {
        assert.equal(navVisible, true);
        const nav = await page.locator('[data-ypa-nav]').boundingBox();
        assert.ok(nav.x > 0 && nav.x + nav.width < width && nav.y + nav.height <= height);
        assert.ok(account.y + account.height < nav.y, 'account strip and floating navigation must not overlap');
        // Wider phones retain the compact card's width while both outside
        // insets stay equal, on the same center line as existing navigation.
        assert.ok(Math.abs(account.x - (width - account.x - account.width)) <= 1, `${name}: account strip must have equal edge insets`);
        assert.ok(Math.abs(account.x + account.width / 2 - (nav.x + nav.width / 2)) <= 1, `${name}: account and navigation centers must agree`);
        accountGeometry = await page.evaluate(() => {
          const bar = document.querySelector('[data-ypa-account]');
          const rect = node => { const { x, y, width, height } = node.getBoundingClientRect(); return { x, y, width, height, centerY: y + height / 2 }; };
          return { account: rect(bar), avatar: rect(bar.querySelector('.who > .avatar')), identity: rect(bar.querySelector('.who > div:not(.avatar)')), actions: [...bar.querySelectorAll(':scope > .icon-btn')].map(rect) };
        });
        for (const child of [accountGeometry.avatar, accountGeometry.identity, ...accountGeometry.actions]) {
          assert.ok(Math.abs(child.centerY - accountGeometry.account.centerY) <= 1, `${name}: identity and actions must be vertically centered`);
          assert.ok(child.x >= account.x && child.x + child.width <= account.x + account.width, `${name}: account child must remain within card`);
        }
        for (const action of accountGeometry.actions) assert.ok(action.width >= 40 && action.height >= 44);
        const originalName = await page.locator('.who .uname').textContent();
        await page.locator('.who .uname').evaluate(node => { node.textContent = 'A deliberately long example member name that cannot fit in a phone account strip'; });
        const longName = await page.evaluate(() => {
          const name = document.querySelector('.who .uname');
          const identity = name.parentElement.getBoundingClientRect();
          const action = document.querySelector('[data-ypa-account] > .icon-btn').getBoundingClientRect();
          return { ellipsis: name.scrollWidth > name.clientWidth && getComputedStyle(name).textOverflow === 'ellipsis', nonoverlapping: identity.right <= action.left, noOverflow: document.documentElement.scrollWidth <= innerWidth };
        });
        assert.deepEqual(longName, { ellipsis: true, nonoverlapping: true, noOverflow: true }, `${name}: long identity must truncate without displacing actions`);
        await page.locator('.who .uname').evaluate((node, text) => { node.textContent = text; }, originalName);
        await page.locator('.who').click();
        const menu = await page.locator('.status-menu.me-pop').boundingBox();
        assert.ok(menu.x >= 0 && menu.y >= 0 && menu.x + menu.width <= width + 1 && menu.y + menu.height <= height + 1, `${name}: original account menu must stay inside viewport`);
        await page.locator('.who').click();
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
      results.push({ viewport, look, width, height, preservedNodesAndActions: true, safeGeometry: true, centeredAccount: mobile ? true : undefined, verticallyAlignedIdentityAndActions: mobile ? true : undefined, longNameEllipsis: mobile ? true : undefined, fixedMenuWithinViewport: mobile ? true : undefined, accountGeometry: accountGeometry || undefined, reversible: true, networkRequests: 0 });
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
