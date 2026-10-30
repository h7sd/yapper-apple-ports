/* Yapinplugger 0.1.0 — independent Yapper adaptations of selected Vencord features.
 * SPDX-License-Identifier: GPL-3.0-or-later
 * No Discord modules, account tokens, remote code, or native APIs are loaded here.
 */
(function () {
    'use strict';
    const VERSION = '0.1.0';
    const STORAGE_KEY = 'yappercord.settings.v1';
    const HOSTS = ['yapper.website', 'www.yapper.website', 'yapin.gg', 'www.yapin.gg'];
    const IDS = ['CharacterCounter', 'ClearURLs', 'ImageZoom', 'PictureInPicture', 'NoF1', 'TextReplace'];
    const tracking = /^(utm_.+|fbclid|gclid|dclid|msclkid|twclid|igshid|mc_cid|mc_eid)$/i;
    function trustedURL(value) {
        try { const u = new URL(value); return u.protocol === 'https:' && HOSTS.includes(u.hostname) && (!u.port || u.port === '443') && !u.username && !u.password; }
        catch { return false; }
    }
    function cleanURL(value) {
        try {
            const u = new URL(value);
            if (!['http:', 'https:'].includes(u.protocol) || u.username || u.password) return value;
            let changed = false;
            for (const key of Array.from(u.searchParams.keys())) if (tracking.test(key)) { u.searchParams.delete(key); changed = true; }
            return changed ? u.href : value;
        } catch { return value; }
    }
    function cleanText(text) {
        return text.replace(/https?:\/\/[^\s<>"']+/g, match => {
            const tail = match.match(/[.,;!?)\]]+$/)?.[0] || '';
            return cleanURL(tail ? match.slice(0, -tail.length) : match) + tail;
        });
    }
    function sanitizeSettings(raw) {
        if (!raw || raw.schemaVersion !== 1 || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('Use a Yapinplugger settings export (schema version 1).');
        const plugins = {};
        for (const id of IDS) plugins[id] = raw.plugins?.[id] === true;
        const customCSS = typeof raw.customCSS === 'string' ? raw.customCSS.slice(0, 30000) : '';
        // CSS escapes/comments can disguise network loads. A deliberately small local-only subset.
        if (/@|\\|\/\*|url\s*\(|image-set\s*\(|expression\s*\(|javascript\s*:/i.test(customCSS)) throw new Error('Quick CSS supports local styles only: no imports, URLs, escapes, comments, or expressions.');
        const replacements = Array.isArray(raw.replacements) ? raw.replacements.slice(0, 30).filter(x => x && typeof x.from === 'string' && x.from.length > 0 && x.from.length <= 100 && typeof x.to === 'string' && x.to.length <= 1000).map(x => ({ from: x.from, to: x.to })) : [];
        return { schemaVersion: 1, plugins, customCSS, replacements };
    }
    function replaceText(text, replacements) {
        // Single pass; replacement text cannot recursively trigger other rules.
        const rules = replacements.slice().sort((a, b) => b.from.length - a.from.length);
        if (!rules.length) return text;
        const regex = new RegExp(rules.map(r => r.from.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'), 'g');
        return text.replace(regex, match => rules.find(r => r.from === match).to);
    }
    const helpers = { trustedURL, cleanURL, cleanText, sanitizeSettings, replaceText, IDS };
    if (typeof module !== 'undefined' && module.exports) module.exports = helpers;
    if (typeof window === 'undefined' || window.top !== window || !trustedURL(window.location.href)) return;
    if (window.Yapinplugger || window.YapperCord) return;
    const catalog = typeof YAPPERCORD_CATALOG !== 'undefined' ? YAPPERCORD_CATALOG : { plugins: [], upstream: {} };
    const doc = window.document;
    let settings = sanitizeSettings({ schemaVersion: 1 });
    let storageError = '';
    try { const saved = localStorage.getItem(STORAGE_KEY); if (saved) settings = sanitizeSettings(JSON.parse(saved)); }
    catch { storageError = 'Saved settings could not be read. Defaults are active; save or import to replace them.'; }
    let dead = false;
    const cleanups = new Map();
    const allCleanups = [];
    const host = doc.createElement('div');
    host.id = 'yappercord-root';
    const shadow = host.attachShadow({ mode: 'open' });
    const h = (tag, text, attrs = {}) => {
        const element = doc.createElement(tag);
        if (text != null) element.textContent = text;
        for (const [key, value] of Object.entries(attrs)) element.setAttribute(key, value);
        return element;
    };
    const style = h('style', `
      :host{all:initial;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#ececf1;font-size:14px;color-scheme:dark}
      *{box-sizing:border-box}button,input,textarea,select{font:inherit}button,a,input,textarea,select{outline-offset:3px}button:focus-visible,a:focus-visible,input:focus-visible,textarea:focus-visible,select:focus-visible{outline:2px solid #afa6ff}button{cursor:pointer}button:disabled{cursor:default;opacity:.5}
      button{color:#ececf1;background:#2b2c35;border:1px solid #444550;border-radius:8px;min-height:40px;padding:8px 14px}button:hover:not(:disabled){background:#383a46}a{color:#c5beff;text-underline-offset:3px}p{line-height:1.55;margin:8px 0 16px;color:#c1c2ce}h1{font-size:26px;letter-spacing:-.025em;margin:0}h2{font-size:17px;margin:0 0 4px}label{display:block}small{font-size:12px;color:#b9bac7}input,textarea,select{color:#ececf1;background:#141519;border:1px solid #555661;border-radius:8px;padding:10px;max-width:100%}input[type=search]{width:100%}textarea{width:100%;resize:vertical;min-height:140px;font-family:ui-monospace,monospace}input[type=checkbox]{accent-color:#8d7df2;width:20px;height:20px;margin:0;flex:0 0 auto}
      .launcher{position:fixed;z-index:2147483000;right:max(16px,env(safe-area-inset-right));bottom:calc(84px + env(safe-area-inset-bottom));box-shadow:0 6px 20px #0006;background:#343044}
      dialog{color:#ececf1;background:#1c1d24;padding:0;border:1px solid #444550;border-radius:14px;width:min(920px,calc(100vw - 24px));max-width:100%;max-height:calc(100dvh - 32px);box-shadow:0 24px 70px #0008}dialog::backdrop{background:#0008}.shell{display:flex;flex-direction:column;max-height:calc(100dvh - 36px)}header{padding:24px 24px 18px;display:flex;align-items:flex-start;justify-content:space-between;gap:16px}header p{margin:6px 0 0}nav{display:flex;gap:4px;padding:0 24px 16px;border-bottom:1px solid #383943;flex-wrap:wrap}nav button[aria-current=page]{background:#7161c7;border-color:#9484ee;color:#fff}.content{padding:20px 24px 24px;overflow:auto;scrollbar-color:#60616d #1c1d24}.row{padding:18px 0;border-bottom:1px solid #383943;display:flex;gap:18px;align-items:flex-start}.row>div{min-width:0;flex:1}.row p{margin:4px 0 8px}.row a{display:block;margin-top:8px}.row label{display:flex;align-items:center;gap:10px;min-height:40px}.actions{display:flex;flex-wrap:wrap;gap:8px;margin:16px 0}.notice{padding:12px 14px;background:#2c293d;border-radius:8px;margin:0 0 18px;color:#ddd7ff}.status{min-height:24px;color:#d4caff;line-height:1.5;margin-top:12px}.filters{display:flex;gap:10px;margin-bottom:12px}.filters input{flex:1;min-width:0}.badge{font-size:12px;color:#d1c8ff}.rules{display:grid;gap:10px}.rule{display:flex;gap:8px}.rule input{width:43%;min-width:0}.image-viewer{background:#090a0d}.image-viewer img{display:block;max-width:100%;max-height:75dvh;object-fit:contain;margin:auto}.image-viewer button{display:block;margin:12px auto}.preview-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(120px,1fr));gap:12px}.preview-grid img{width:100%;height:90px;object-fit:contain}.preview-grid button{padding:6px}.count{position:fixed;right:18px;bottom:58px;background:#24252e;color:#dcdde5;border-radius:6px;padding:4px 8px;pointer-events:none;font-variant-numeric:tabular-nums}
      ::selection{background:#7161c7;color:#fff} @media(max-width:600px){header{padding:20px 16px 14px}nav{padding:0 16px 12px}.content{padding:16px}.row{gap:12px}h1{font-size:23px}.filters{flex-wrap:wrap}.filters select{width:100%}.rule{flex-wrap:wrap}.rule input{width:calc(50% - 4px)}.launcher{min-height:44px}button{min-height:44px}}
    `);
    shadow.append(style);
    const launcher = h('button', 'Plugins', { class: 'launcher', 'aria-label': 'Open Yapinplugger plugins' });
    const dialog = h('dialog', null, { 'aria-labelledby': 'yc-title' });
    const shell = h('div', null, { class: 'shell' });
    const header = h('header');
    const titleWrap = h('div');
    titleWrap.append(h('h1', 'Yapinplugger', { id: 'yc-title' }), h('p', 'Plugins for your Yapper client · ' + VERSION));
    const close = h('button', 'Close', { 'aria-label': 'Close plugin manager' });
    header.append(titleWrap, close);
    const nav = h('nav', null, { 'aria-label': 'Yapinplugger settings' });
    const content = h('div', null, { class: 'content' });
    shell.append(header, nav, content); dialog.append(shell); shadow.append(launcher, dialog);
    (doc.body || doc.documentElement).append(host);
    let tab = 'Adapted plugins';
    let lastFocused = null;
    function message(text) { const el = shadow.getElementById('yc-status'); if (el) el.textContent = text; }
    function persist(next) {
        const validated = sanitizeSettings(next);
        try { localStorage.setItem(STORAGE_KEY, JSON.stringify(validated)); }
        catch { throw new Error('Settings could not be saved. Check available website storage.'); }
        settings = validated;
    }
    const on = (target, event, fn, options) => { target.addEventListener(event, fn, options); return () => target.removeEventListener(event, fn, options); };
    const composerSelector = 'textarea[placeholder^="Message"],textarea[aria-label^="Message"],textarea[placeholder^="Nachricht"],[contenteditable="true"][role="textbox"][aria-label^="Message"],[contenteditable="true"][data-placeholder^="Message"],[contenteditable="true"][role="textbox"][aria-label^="Nachricht"]';
    let recentComposer = null;
    allCleanups.push(on(doc, 'focusin', event => { if (event.target.matches?.(composerSelector)) recentComposer = event.target; }));
    function composer() {
        const writable = el => el?.isConnected && el.matches(composerSelector) && !el.disabled && !el.readOnly && el.getAttribute('aria-disabled') !== 'true' && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
        const candidate = writable(recentComposer) ? recentComposer : Array.from(doc.querySelectorAll(composerSelector)).find(writable);
        if (!candidate) throw new Error('Open a chat and focus its message input first. Login and search fields are never edited.');
        return candidate;
    }
    function transformComposer(transform) {
        const el = composer();
        const isText = el.tagName === 'TEXTAREA';
        const original = isText ? el.value : el.innerText;
        const updated = transform(original);
        if (updated === original) { message('No changes needed.'); return; }
        // A framework-controlled rich editor cannot safely be rewritten without its editor API.
        if (!isText) throw new Error('This rich-text composer is unsupported. Use the text workbench below, then paste the result into your chat.');
        Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set.call(el, updated);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        message('Message draft updated. Review it before sending.');
    }
    function meaningfulImages() {
        return Array.from(doc.querySelectorAll('img')).filter(img => (img.naturalWidth >= 180 || img.width >= 180) && /^https?:|^blob:|^data:image\//.test(img.currentSrc || img.src)).slice(0, 40);
    }
    function showImage(image) {
        const viewer = h('dialog', null, { class: 'image-viewer', 'aria-label': 'Image zoom' });
        const img = h('img', null, { alt: image.alt || 'Enlarged image', src: image.currentSrc || image.src });
        const exit = h('button', 'Close image');
        viewer.append(img, exit); shadow.append(viewer);
        exit.onclick = () => viewer.close();
        viewer.addEventListener('close', () => viewer.remove(), { once: true });
        viewer.showModal();
    }
    const definitions = [
        { id: 'CharacterCounter', summary: 'Counts characters in the focused Yapper message input.', detail: 'Uses semantic message fields. Displays the field’s limit only when Yapper declares one; no Discord Nitro limits are assumed.', start() {
            const counter = h('output', '', { class: 'count', 'aria-label': 'Message character count' }); counter.hidden = true; shadow.append(counter);
            function update() {
                const el = doc.activeElement;
                counter.hidden = !el?.matches?.(composerSelector);
                if (counter.hidden) return;
                const text = el.tagName === 'TEXTAREA' ? el.value : el.innerText;
                const max = el.tagName === 'TEXTAREA' && el.maxLength > 0 ? el.maxLength : 0;
                counter.textContent = text.length.toLocaleString() + (max ? ' / ' + max.toLocaleString() : ' characters');
            }
            const unsub = ['input', 'focusin', 'focusout'].map(e => on(doc, e, update)); update();
            return () => { unsub.forEach(f => f()); counter.remove(); };
        } },
        { id: 'ClearURLs', summary: 'Removes common tracking parameters from links you choose to clean.', detail: 'Manual, limited adaptation. Removes UTM, fbclid, gclid and similar query parameters. It does not use upstream provider rules, intercept sends, or alter signed links automatically.', action: () => transformComposer(cleanText), actionLabel: 'Clean message draft' },
        { id: 'ImageZoom', summary: 'Enlarges loaded images without an external service.', detail: 'Shift-click an image on Mac, or open the image gallery here on iPhone. Images must already be present in the current page.', start() {
            return on(doc, 'click', event => {
                if (event.shiftKey && event.target.tagName === 'IMG' && meaningfulImages().includes(event.target)) { event.preventDefault(); event.stopImmediatePropagation(); showImage(event.target); }
            }, true);
        }, action: () => renderGallery(), actionLabel: 'Browse loaded images' },
        { id: 'PictureInPicture', summary: 'Opens a playing video in the system’s picture-in-picture window.', detail: 'Uses the browser’s own video API. Availability depends on the device, the video and operating-system policy.', action: async () => {
            const video = Array.from(doc.querySelectorAll('video')).find(v => !v.paused && v.readyState >= 2) || doc.querySelector('video');
            if (!video) throw new Error('Start a video in Yapper first.');
            if (video.requestPictureInPicture && doc.pictureInPictureEnabled) await video.requestPictureInPicture();
            else if (video.webkitSupportsPresentationMode?.('picture-in-picture')) video.webkitSetPresentationMode('picture-in-picture');
            else throw new Error('Picture-in-picture is unavailable for this video on this device.');
            message('Picture-in-picture requested.');
        }, actionLabel: 'Open playing video' },
        { id: 'NoF1', summary: 'Prevents F1 from opening browser help while Yapper has focus.', detail: 'Only intercepts F1 inside this Yapper page. It does not install a global keyboard hook.', start() { return on(doc, 'keydown', event => { if (event.key === 'F1') { event.preventDefault(); event.stopImmediatePropagation(); } }, true); } },
        { id: 'TextReplace', summary: 'Applies your saved literal text replacements to a draft.', detail: 'Manual adaptation with a single replacement pass. No regular expressions, message interception, clipboard reads, or message history storage.', action: () => transformComposer(text => replaceText(text, settings.replacements)), actionLabel: 'Apply to message draft' }
    ];
    function reconcile() {
        if (dead) return;
        for (const plugin of definitions) {
            if (!settings.plugins[plugin.id] && cleanups.has(plugin.id)) { cleanups.get(plugin.id)(); cleanups.delete(plugin.id); }
            if (settings.plugins[plugin.id] && !cleanups.has(plugin.id)) cleanups.set(plugin.id, plugin.start?.() || (() => {}));
        }
        let css = doc.getElementById('yappercord-custom-css');
        if (!css && settings.customCSS) { css = h('style', '', { id: 'yappercord-custom-css' }); doc.head.append(css); }
        if (css) css.textContent = settings.customCSS;
    }
    function setEnabled(id, enabled) {
        if (dead) throw new Error('Yapinplugger is disabled. Reload the enabled client to use it.');
        if (!IDS.includes(id)) throw new Error('This upstream plugin has no Yapper adaptation yet.');
        if (typeof enabled !== 'boolean') throw new Error('Plugin enabled must be a boolean.');
        persist({ ...settings, plugins: { ...settings.plugins, [id]: enabled } }); reconcile();
    }
    async function run(action) { try { await action(); } catch (error) { message(error.message || 'Action failed. Please try again.'); } }
    function button(label, action) { const btn = h('button', label); btn.onclick = () => run(action); return btn; }
    function status() { content.append(h('div', storageError, { id: 'yc-status', class: 'status', role: 'status' })); }
    function renderPlugins() {
        content.append(h('p', 'Six independent Yapper adaptations. These do not run the original Discord plugins. All plugins start disabled.', { class: 'notice' }));
        for (const plugin of definitions) {
            const row = h('section', null, { class: 'row' });
            const body = h('div'); body.append(h('h2', plugin.id), h('p', plugin.summary), h('small', plugin.detail));
            const label = h('label'); const input = h('input', null, { type: 'checkbox', 'aria-label': 'Enable ' + plugin.id }); input.checked = settings.plugins[plugin.id];
            input.onchange = () => run(() => {
                try { setEnabled(plugin.id, input.checked); render(); }
                catch (error) { input.checked = settings.plugins[plugin.id]; throw error; }
            }); label.append(input, h('span', 'Enable'));
            row.append(body, label);
            if (plugin.action && settings.plugins[plugin.id]) { const actions = h('div', null, { class: 'actions' }); actions.append(button(plugin.actionLabel, plugin.action)); body.append(actions); }
            const entry = catalog.plugins.find(p => p.name === plugin.id);
            if (entry?.sourceUrl) body.append(h('a', 'Upstream source', { href: entry.sourceUrl, target: '_blank', rel: 'noreferrer noopener' }));
            content.append(row);
        }
        const workbench = h('section'); workbench.append(h('h2', 'Text workbench'), h('p', 'For rich-text inputs, transform text here and paste the result into Yapper. Nothing is sent automatically.'));
        const text = h('textarea', '', { 'aria-label': 'Text to transform', placeholder: 'Paste a draft here…' });
        const actions = h('div', null, { class: 'actions' });
        const clean = button('Clean links', () => { text.value = cleanText(text.value); message('Tracking parameters removed where matched. Review the result.'); }); clean.disabled = !settings.plugins.ClearURLs;
        const replace = button('Apply replacements', () => { text.value = replaceText(text.value, settings.replacements); message('Saved replacements applied.'); }); replace.disabled = !settings.plugins.TextReplace;
        actions.append(clean, replace); workbench.append(text, actions); content.append(workbench); status();
    }
    function renderCatalog() {
        content.append(h('p', 'The complete shipped upstream source inventory. Discord internals and webpack patches require individual ports. Internal APIs are listed separately. No entries here download or execute plugin code.', { class: 'notice' }));
        const filters = h('div', null, { class: 'filters' });
        const search = h('input', null, { type: 'search', placeholder: 'Search upstream plugins…', 'aria-label': 'Search upstream plugins' });
        const filter = h('select', null, { 'aria-label': 'Plugin category' });
        for (const [value, label] of [['user','User plugins'],['adapted','Yapper adaptations'],['internal','Internal APIs and core'],['all','All source entries']]) filter.append(h('option', label, { value }));
        filters.append(search, filter); const list = h('div'); const result = h('p', '', { role: 'status' });
        content.append(filters, result, list);
        function update() {
            list.replaceChildren(); const query = search.value.toLowerCase().trim();
            const entries = catalog.plugins.filter(p => {
                const internal = p.kind !== 'plugin';
                return (filter.value === 'all' || filter.value === 'internal' && internal || filter.value === 'user' && !internal || filter.value === 'adapted' && IDS.includes(p.name)) && (p.name + ' ' + p.description).toLowerCase().includes(query);
            });
            result.textContent = entries.length + ' source entries';
            if (!entries.length) list.append(h('p', 'No matching plugins. Try another name or category.'));
            for (const entry of entries) {
                const row = h('section', null, { class: 'row' }); const body = h('div');
                body.append(h('h2', entry.name), h('p', entry.description || 'Internal upstream component.'), h('div', IDS.includes(entry.name) ? 'Limited Yapper adaptation available above' : 'Requires a Yapper port', { class: 'badge' }));
                if (/^https:\/\/github\.com\/(Vendicated\/Vencord|Vencord\/Installer)\//.test(entry.sourceUrl || '')) body.append(h('a', 'Inspect source', { href: entry.sourceUrl, target: '_blank', rel: 'noreferrer noopener' }));
                row.append(body); list.append(row);
            }
        }
        search.oninput = update; filter.onchange = update; update();
    }
    function renderGallery() {
        content.replaceChildren(h('h2', 'Loaded images'), h('p', 'Only images already loaded by this page are shown.'));
        const grid = h('div', null, { class: 'preview-grid' });
        const images = meaningfulImages();
        if (!images.length) content.append(h('p', 'No large loaded images found. Open a chat containing an image first.'));
        for (const image of images) { const btn = button('View image', () => showImage(image)); btn.prepend(h('img', null, { src: image.currentSrc || image.src, alt: image.alt || 'Image preview' })); grid.append(btn); }
        content.append(grid, button('Back to plugins', render)); status();
    }
    function renderAppearance() {
        content.append(h('h2', 'Quick CSS'), h('p', 'Local styles for the Yapper page. Styles can hide controls or change readability; clear the editor and save to restore. Network loads and imports are blocked.'));
        const css = h('textarea', '', { 'aria-label': 'Custom CSS', placeholder: 'body { font-size: 16px; }', spellcheck: 'false' }); css.value = settings.customCSS;
        content.append(css, button('Save CSS', () => { persist({ ...settings, customCSS: css.value }); reconcile(); message('Local CSS saved.'); }), h('h2', 'Text replacements'));
        const rules = h('div', null, { class: 'rules' });
        const current = settings.replacements.length ? settings.replacements : [{ from: '', to: '' }];
        function addRule(rule) {
            const row = h('div', null, { class: 'rule' });
            const from = h('input', null, { 'aria-label': 'Text to replace', placeholder: 'Replace', maxlength: '100' }); from.value = rule.from;
            const to = h('input', null, { 'aria-label': 'Replacement text', placeholder: 'With', maxlength: '1000' }); to.value = rule.to;
            row.append(from, to, button('Remove', () => row.remove())); rules.append(row);
        }
        current.forEach(addRule);
        const actions = h('div', null, { class: 'actions' });
        actions.append(button('Add replacement', () => { if (rules.children.length >= 30) throw new Error('Up to 30 replacements are supported.'); addRule({ from: '', to: '' }); }), button('Save replacements', () => { persist({ ...settings, replacements: Array.from(rules.children).map(row => ({ from: row.children[0].value, to: row.children[1].value })) }); message('Replacements saved. Enable TextReplace under Adapted plugins.'); }));
        content.append(rules, actions); status();
    }
    function renderSettings() {
        content.append(h('h2', 'Settings backup'), h('p', 'Only Yapinplugger switches, your CSS and replacement rules are exported. Drafts, messages, account sessions and website storage are excluded. Copy your export somewhere private if replacement rules contain personal text.'));
        const text = h('textarea', '', { 'aria-label': 'Settings JSON', spellcheck: 'false' });
        const actions = h('div', null, { class: 'actions' });
        actions.append(button('Show export', () => { text.value = JSON.stringify(settings, null, 2); message('Export ready to copy.'); }), button('Import settings', () => { persist(JSON.parse(text.value)); reconcile(); message('Settings imported.'); }), button('Reset plugins and CSS', () => { persist({ schemaVersion: 1 }); reconcile(); text.value = ''; message('All plugins and custom CSS disabled.'); }));
        content.append(text, actions, h('h2', 'About this port'), h('p', 'Unofficial, independent Yapper extension. Not endorsed by Vencord, Discord or Yapper. No universal Discord plugin compatibility is claimed. Features run with the same page access as the website; they are not a security boundary. There is no remote code loader or automatic updater.'), h('a', 'Source and review scope', { href: 'https://github.com/h7sd/yapper-apple-ports/tree/main/extensions/yappercord', target: '_blank', rel: 'noreferrer noopener' })); status();
    }
    function render() {
        if (dead) return;
        const focused = shadow.activeElement;
        const focusedLabel = focused?.getAttribute('aria-label');
        const focusedNav = focused?.parentElement === nav ? focused.textContent : null;
        nav.replaceChildren();
        for (const label of ['Adapted plugins', 'Vencord catalog', 'CSS & text', 'Settings']) {
            const btn = button(label, () => { tab = label; render(); }); if (tab === label) btn.setAttribute('aria-current', 'page'); nav.append(btn);
        }
        content.replaceChildren();
        ({ 'Adapted plugins': renderPlugins, 'Vencord catalog': renderCatalog, 'CSS & text': renderAppearance, Settings: renderSettings })[tab]();
        if (focused && !focused.isConnected) {
            const replacement = focusedLabel
                ? Array.from(shadow.querySelectorAll('[aria-label]')).find(el => el.getAttribute('aria-label') === focusedLabel)
                : Array.from(nav.children).find(el => el.textContent === focusedNav);
            replacement?.focus({ preventScroll: true });
        }
    }
    function open() { if (dead) return; render(); if (!dialog.open) { lastFocused = doc.activeElement; dialog.showModal(); } }
    launcher.onclick = open; close.onclick = () => dialog.close();
    dialog.addEventListener('close', () => lastFocused?.focus?.());
    allCleanups.push(on(doc, 'keydown', event => { if ((event.metaKey || event.ctrlKey) && event.shiftKey && event.key.toLowerCase() === 'p') { event.preventDefault(); open(); } }));
    function destroy() {
        if (dead) return; dead = true;
        cleanups.forEach(fn => fn()); cleanups.clear(); allCleanups.forEach(fn => fn());
        shadow.querySelectorAll('dialog[open]').forEach(el => el.close());
        doc.getElementById('yappercord-custom-css')?.remove(); host.remove(); delete window.Yapinplugger; delete window.YapperCord;
    }
    Object.defineProperty(window, 'Yapinplugger', { configurable: true, value: Object.freeze({
        version: VERSION, open, destroy, setEnabled,
        list: () => definitions.map(p => ({ id: p.id, enabled: settings.plugins[p.id], kind: 'adaptation' })),
        getSettings: () => JSON.parse(JSON.stringify(settings)), exportSettings: () => JSON.parse(JSON.stringify(settings)),
        importSettings: value => { if (dead) throw new Error('Yapinplugger is disabled.'); persist(value); reconcile(); },
        catalog: () => JSON.parse(JSON.stringify(catalog))
    }) });
    // Keep the preview API name as an alias so existing native integrations migrate safely.
    Object.defineProperty(window, 'YapperCord', { configurable: true, value: window.Yapinplugger });
    reconcile();
})();
