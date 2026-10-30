/* Yapper Appearance 0.1.0 — a reversible layout adapter for existing Yapper UI.
 * Copyright (c) 2026 Yapper Apple Ports contributors.
 * SPDX-License-Identifier: MIT
 * Reads existing structure only; no requests, storage, copied account data,
 * injected artwork, React internals, or replacement application controls.
 */
(function () {
    'use strict';
    const VERSION = '0.1.0';
    const HOSTS = ['yapper.website', 'www.yapper.website', 'yapin.gg', 'www.yapin.gg'];
    function trustedURL(value) {
        try {
            const url = new URL(value);
            return url.protocol === 'https:' && HOSTS.includes(url.hostname) &&
                (!url.port || url.port === '443') && !url.username && !url.password;
        } catch { return false; }
    }
    const CSS = `
/* Geometry is local; paint, artwork, typography and state come from Yapper. */
html[data-yapper-appearance] [data-ypa-account]:not(.top){
  box-sizing:border-box;min-height:72px;height:auto;padding:10px 12px;gap:8px;border-radius:18px;
  background:var(--bg-side-solid,var(--bg-side));border:1px solid var(--border);
  color:var(--text);isolation:isolate;flex-shrink:0;
}
html[data-yapper-appearance] [data-ypa-account]:not(.top):not(.floating){margin:8px;}
html[data-yapper-appearance] [data-ypa-account].floating{
  left:12px;bottom:12px;width:min(316px,calc(100vw - 24px));margin:0;
}
html[data-yapper-appearance] [data-ypa-account]>.who{
  min-width:0;min-height:48px;padding:0 2px;gap:12px;border-radius:12px;
}
html[data-yapper-appearance] [data-ypa-account]:not(.top)>.who>.avatar{
  width:44px!important;height:44px!important;flex:0 0 44px;
}
html[data-yapper-appearance] [data-ypa-account]>.who>div:not(.avatar){min-width:0;flex:1;}
html[data-yapper-appearance] [data-ypa-account] .who .uname{font-size:15px;line-height:1.3;font-weight:700;}
html[data-yapper-appearance] [data-ypa-account] .who .status{max-height:20px;line-height:1.45;font-size:12px;}
html[data-yapper-appearance] [data-ypa-account]>.icon-btn{
  min-width:40px;min-height:44px;flex-shrink:0;border-radius:12px;
}
html[data-yapper-appearance] [data-ypa-account].top{min-height:44px;}
html[data-yapper-appearance] [data-ypa-account]>.status-menu.me-pop{
  border-radius:16px;max-height:calc(var(--vvh,100dvh) - 110px - env(safe-area-inset-top));
}
html[data-yapper-appearance] [data-ypa-account]:not(.top)>.status-menu.me-pop{bottom:calc(100% + 8px);}
html[data-yapper-appearance] [data-ypa-account] .me-card{border-radius:15px 15px 0 0;}
html[data-yapper-appearance] [data-ypa-account] .me-banner{border-radius:15px 15px 0 0;}
html[data-yapper-appearance] [data-ypa-account] .me-row{min-height:44px;}
html[data-yapper-appearance] [data-ypa-profile-shell]{
  width:min(540px,calc(100vw - 32px));max-width:calc(100vw - 32px);
  max-height:calc(var(--vvh,100dvh) - 32px - env(safe-area-inset-top) - env(safe-area-inset-bottom));
  overflow-x:hidden;overflow-y:auto;overscroll-behavior:contain;border-radius:20px;
  scrollbar-color:var(--text-faint) transparent;
}
html[data-yapper-appearance] [data-ypa-profile-frame]{
  display:flex;flex-direction:column;align-items:stretch;gap:0;width:100%;min-width:0;
  background:var(--bg-side-solid,var(--bg-side));border-radius:20px;
}
html[data-yapper-appearance] [data-ypa-profile]{width:100%;max-width:100%;min-width:0;flex-shrink:0;border-radius:20px 20px 0 0;}
html[data-yapper-appearance] [data-ypa-profile] .pc2-banner{border-radius:18px 18px 0 0;}
html[data-yapper-appearance] [data-ypa-profile] .pc2-banner>.banner{aspect-ratio:8/3!important;}
html[data-yapper-appearance] [data-ypa-profile] .pc2-top{gap:10px;padding-right:20px;}
html[data-yapper-appearance] [data-ypa-profile] .pc2-avatar{margin:-46px 0 0 20px;}
html[data-yapper-appearance] [data-ypa-profile] .pc2-head{padding:12px 20px 0;}
html[data-yapper-appearance] [data-ypa-profile] .pc2-name{font-size:clamp(22px,4vw,28px);line-height:1.2;overflow-wrap:anywhere;}
html[data-yapper-appearance] [data-ypa-profile] .pc-sub-row{row-gap:6px;margin-top:5px;}
html[data-yapper-appearance] [data-ypa-profile] .pc2-body{padding:12px 20px 20px;}
html[data-yapper-appearance] [data-ypa-profile] .profile-card-section{
  border-radius:12px;padding:14px;margin-bottom:12px;
}
html[data-yapper-appearance] [data-ypa-profile] .pc2-edit-bar{margin-top:16px;}
html[data-yapper-appearance] [data-ypa-profile] .pc2-edit-bar .btn{min-height:44px;border-radius:12px;}
html[data-yapper-appearance] [data-ypa-profile] .pc-close{min-width:36px;min-height:36px;}
html[data-yapper-appearance] [data-ypa-profile-frame]>.pc2-side{
  width:100%;max-height:none;border:0;border-radius:0 0 20px 20px;padding:0 20px 16px;overflow:visible;
}
html[data-yapper-appearance] [data-ypa-profile-frame] .pc2-side-tabs{
  gap:12px;overflow-x:auto;border-bottom:1px solid var(--border);padding:0;margin-bottom:12px;
}
html[data-yapper-appearance] [data-ypa-profile-frame] .pc2-side-tabs>button{
  min-height:46px;padding:10px 4px;border-radius:0;border-bottom:2px solid transparent;background:none;
  flex:1;white-space:nowrap;color:var(--text-muted);
}
html[data-yapper-appearance] [data-ypa-profile-frame] .pc2-side-tabs>button.on{
  color:var(--text);border-bottom-color:var(--accent);background:none;
}
html[data-yapper-appearance] :is([data-ypa-account],[data-ypa-profile-shell],[data-ypa-nav]) :is(button,a):focus-visible{
  outline:2px solid var(--accent);outline-offset:3px;
}
/* Existing navigation visibility is preserved: no new tabs or destinations. */
@media(max-width:760px){
  html[data-yapper-appearance] [data-ypa-profile-shell]{
    width:calc(100vw - 20px);max-width:calc(100vw - 20px);
    height:auto;max-height:calc(var(--vvh,100dvh) - 20px - env(safe-area-inset-top) - env(safe-area-inset-bottom));
    border-radius:20px;flex:none;padding-bottom:0;overflow-y:auto;
  }
  html[data-yapper-appearance] [data-ypa-profile-frame]{flex:none;min-height:0;max-height:none;overflow:visible;border-radius:20px;}
  html[data-yapper-appearance] [data-ypa-profile-frame]>.pc2{overflow:visible;}
  html[data-yapper-appearance] [data-ypa-profile-frame]>.pc2-side{padding-bottom:16px;}
  html[data-yapper-appearance] .app:not(.chat-open) nav[data-ypa-nav]{
    left:50%;right:auto;bottom:calc(12px + env(safe-area-inset-bottom));transform:translateX(-50%);
    width:min(380px,calc(100vw - 24px));height:64px;min-height:64px;padding:6px;
    border:1px solid var(--border);border-radius:20px;background:var(--bg-side-solid,var(--bg-side));
    box-shadow:0 8px 24px color-mix(in srgb,var(--bg-rail) 60%,transparent);gap:2px;
  }
  html[data-yapper-appearance] [data-ypa-nav]>.nl-tab{
    min-width:48px;min-height:50px;padding:5px 8px;border-radius:14px;gap:4px;flex:1;
  }
  html[data-yapper-appearance] [data-ypa-nav]>.nl-tab.on{
    background:var(--bg-active);color:var(--text);
  }
  html[data-yapper-appearance] [data-ypa-nav]>.nl-tab>span:not(.nl-tab-badge){font-size:11px;font-weight:600;}
  html[data-yapper-appearance] .app.mobile-nav:not(.chat-open) [data-ypa-account]:not(.top){
    position:fixed;left:12px;right:12px;bottom:calc(88px + env(safe-area-inset-bottom));
    width:min(380px,calc(100vw - 24px));max-width:calc(100vw - 24px);margin:0 auto;z-index:20;
  }
  html[data-yapper-appearance] .app.mobile-nav:not(.chat-open) [data-ypa-account]>.status-menu.me-pop{
    position:fixed;left:12px;right:auto;bottom:calc(172px + env(safe-area-inset-bottom));
    max-height:calc(var(--vvh,100dvh) - 188px - env(safe-area-inset-top) - env(safe-area-inset-bottom));
  }
  html[data-yapper-appearance] .app.mobile-nav:not(.chat-open):has([data-ypa-nav]) :is(.sidebar-scroll,.rail){padding-bottom:180px;}
}
@media(prefers-reduced-motion:reduce){
  html[data-yapper-appearance] [data-ypa-profile-shell]{animation:none!important;scroll-behavior:auto;}
}
`;
    if (typeof module !== 'undefined' && module.exports) module.exports = { trustedURL, CSS, VERSION };
    if (typeof window === 'undefined' || window.top !== window || !trustedURL(window.location.href)) return;
    if (window.YapperAppearance) return;
    const doc = window.document;
    let disposed = false;
    let pending = false;
    const marked = new Map();
    const waits = new Set();
    const rootPrevious = doc.documentElement.getAttribute('data-yapper-appearance');
    doc.documentElement.setAttribute('data-yapper-appearance', VERSION);
    const style = doc.createElement('style');
    style.setAttribute('data-yapper-appearance-style', VERSION);
    style.textContent = CSS;
    (doc.head || doc.documentElement).append(style);
    function mark(node, name) {
        let record = marked.get(node);
        if (!record) { record = new Map(); marked.set(node, record); }
        if (!record.has(name)) record.set(name, node.getAttribute(name));
        if (!node.hasAttribute(name)) node.setAttribute(name, '');
    }
    function restore(node, record) {
        for (const [name, previous] of record) {
            if (previous === null) node.removeAttribute(name);
            else node.setAttribute(name, previous);
        }
    }
    function refresh() {
        if (disposed) return false;
        // Drop references to removed profile trees immediately; do not retain
        // previous accounts, messages, or modal content in an adapter cache.
        for (const [node, record] of marked) {
            if (!node.isConnected) { restore(node, record); marked.delete(node); }
        }
        for (const node of doc.querySelectorAll('.app .user-bar')) {
            if (node.querySelector(':scope > button.who .uname') && node.querySelector(':scope > button.who .status')) mark(node, 'data-ypa-account');
        }
        for (const node of doc.querySelectorAll('.modal .profile-card.pc2:not(.preview)')) {
            if (!node.querySelector('.pc2-banner') || !node.querySelector('.pc2-head') || !node.querySelector('.pc2-body')) continue;
            mark(node, 'data-ypa-profile');
            const modal = node.closest('.modal');
            if (modal) mark(modal, 'data-ypa-profile-shell');
            const frame = node.closest('.pc2-frame');
            if (frame) mark(frame, 'data-ypa-profile-frame');
        }
        for (const node of doc.querySelectorAll('.app nav.nl-tabbar')) {
            if (node.querySelectorAll(':scope > button.nl-tab').length >= 2) mark(node, 'data-ypa-nav');
        }
        return true;
    }
    function schedule() {
        if (pending || disposed) return;
        pending = true;
        Promise.resolve().then(() => { pending = false; if (!disposed) refresh(); });
    }
    const observer = new MutationObserver(records => {
        if (records.some(record => record.type === 'childList' || record.attributeName === 'class')) schedule();
    });
    observer.observe(doc.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] });
    function visible(element) {
        return !!element && element.isConnected && !element.hidden && !element.disabled &&
            element.getAttribute('aria-disabled') !== 'true' && !element.closest('[inert],[aria-hidden="true"]') &&
            window.getComputedStyle(element).visibility !== 'hidden' && element.getClientRects().length > 0;
    }
    // Exact translations observed in the captured public locale chunks. Unknown
    // labels fail safely rather than clicking a different account action.
    const PROFILE_LABELS = new Set(['View my profile', 'Mein Profil ansehen', 'Ver mi perfil', 'Voir mon profil', 'Ver meu perfil']);
    function profileAction(account) {
        return [...account.querySelectorAll('.me-menu button.me-row')].find(button =>
            visible(button) && PROFILE_LABELS.has(button.querySelector('.me-row-label')?.textContent.trim()));
    }
    async function openProfile() {
        if (disposed) return false;
        const account = [...doc.querySelectorAll('.app [data-ypa-account]')].find(node => visible(node.querySelector(':scope > button.who')));
        if (!account) return false;
        let action = profileAction(account);
        if (action) { action.click(); return true; }
        const who = account.querySelector(':scope > button.who');
        if (!visible(who) || who.getAttribute('aria-expanded') === 'true') return false;
        who.click();
        return await new Promise(resolve => {
            let finished = false;
            let timer;
            const menuObserver = new MutationObserver(check);
            const stop = result => {
                if (finished) return;
                finished = true; clearTimeout(timer); menuObserver.disconnect(); waits.delete(cancel); resolve(result);
            };
            const cancel = () => stop(false);
            function check() {
                if (disposed || !account.isConnected) { stop(false); return; }
                action = profileAction(account);
                if (action) { action.click(); stop(true); }
            }
            waits.add(cancel);
            menuObserver.observe(account, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'aria-expanded'] });
            timer = setTimeout(() => {
                if (!disposed && who.isConnected && who.getAttribute('aria-expanded') === 'true') who.click();
                stop(false);
            }, 700);
            check();
        });
    }
    function getState() {
        const count = name => disposed ? 0 : [...marked].filter(([node, record]) => node.isConnected && record.has(name)).length;
        return Object.freeze({ version: VERSION, active: !disposed, disposed,
            accounts: count('data-ypa-account'), profiles: count('data-ypa-profile'), navigation: count('data-ypa-nav'),
            mode: 'existing-dom', networkRequests: false });
    }
    function destroy() {
        if (disposed) return;
        disposed = true; observer.disconnect();
        for (const cancel of [...waits]) cancel();
        for (const [node, record] of marked) restore(node, record);
        marked.clear(); style.remove();
        if (rootPrevious === null) doc.documentElement.removeAttribute('data-yapper-appearance');
        else doc.documentElement.setAttribute('data-yapper-appearance', rootPrevious);
        delete window.YapperAppearance;
    }
    Object.defineProperty(window, 'YapperAppearance', { configurable: true, value: Object.freeze({ version: VERSION, refresh, getState, openProfile, destroy }) });
    refresh();
})();
