/* SPDX-License-Identifier: GPL-3.0-or-later
 * iOS viewport/layout integration. This resource is injected only after the
 * native trusted-origin guard, in the main document at document start.
 */
(() => {
  'use strict';
  if (window.top !== window.self) return;
  const doc = document;
  const styleID = 'yapper-ios-viewport-style';
  const css = `
    html[data-yapper-ios-viewport],html[data-yapper-ios-viewport] body{min-height:100%;margin:0}
    html[data-yapper-ios-viewport] .app{box-sizing:border-box!important;padding-top:env(safe-area-inset-top,0px)!important;padding-right:env(safe-area-inset-right,0px)!important;padding-bottom:env(safe-area-inset-bottom,0px)!important;padding-left:env(safe-area-inset-left,0px)!important}
    html[data-yapper-ios-viewport] .app>.stage-row{min-height:0}
    html[data-yapper-ios-viewport] .modal-overlay{box-sizing:border-box;padding-top:max(16px,env(safe-area-inset-top,0px));padding-right:max(16px,env(safe-area-inset-right,0px));padding-bottom:max(16px,env(safe-area-inset-bottom,0px));padding-left:max(16px,env(safe-area-inset-left,0px))}
    @media(max-width:760px){html[data-yapper-ios-viewport]:not(.new-look) .app .rail{padding-top:10px!important}html[data-yapper-ios-viewport]:not(.new-look) .app .sidebar-head{padding-top:10px!important}html[data-yapper-ios-viewport]:not(.new-look) .app .main-head{padding-top:0!important;height:48px!important}html[data-yapper-ios-viewport] .app nav.nl-tabbar:not([data-ypa-nav]){bottom:0!important}html[data-yapper-ios-viewport] .app .user-bar.floating:not([data-ypa-account]){bottom:calc(64px + env(safe-area-inset-bottom,0px))!important}}
  `;
  function apply() {
    const root = doc.documentElement;
    if (!root || !doc.head) return;
    if (!root.hasAttribute('data-yapper-ios-viewport')) root.setAttribute('data-yapper-ios-viewport', '');
    let metas = [...doc.head.querySelectorAll('meta[name="viewport" i]')];
    if (!metas.length) {
      const meta = doc.createElement('meta'); meta.name = 'viewport';
      meta.content = 'width=device-width, initial-scale=1, viewport-fit=cover';
      doc.head.append(meta); metas = [meta];
    }
    for (const meta of metas) {
      const parts = (meta.content || 'width=device-width, initial-scale=1').split(',').map(x => x.trim()).filter(x => x && !/^viewport-fit\s*=/i.test(x));
      const content = [...parts, 'viewport-fit=cover'].join(', ');
      if (meta.content !== content) meta.content = content;
    }
    if (!doc.getElementById(styleID)) {
      const style = doc.createElement('style'); style.id = styleID; style.textContent = css; doc.head.append(style);
    }
    // The addon owns an open shadow root; its dialog must also stay clear of
    // the status bar/home indicator when the document fills the screen.
    const host = doc.getElementById('yappercord-root');
    const shadow = host?.shadowRoot;
    if (shadow && !shadow.getElementById(styleID)) {
      const style = doc.createElement('style'); style.id = styleID;
      style.textContent = `dialog{margin-top:calc(12px + env(safe-area-inset-top,0px));margin-bottom:calc(12px + env(safe-area-inset-bottom,0px));max-height:calc(100dvh - 24px - env(safe-area-inset-top,0px) - env(safe-area-inset-bottom,0px))}.shell{max-height:calc(100dvh - 28px - env(safe-area-inset-top,0px) - env(safe-area-inset-bottom,0px))}`;
      shadow.append(style);
    }
  }
  let queued = false;
  const changes = new MutationObserver(() => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; apply(); });
  });
  changes.observe(doc, { childList: true, subtree: true });
  const metaChanges = new MutationObserver(apply);
  function watchHead() {
    if (doc.head) metaChanges.observe(doc.head, { attributes: true, attributeFilter: ['content'], childList: true, subtree: true });
  }
  apply(); watchHead();
  doc.addEventListener('DOMContentLoaded', () => { apply(); watchHead(); }, { once: true });
  window.addEventListener('pagehide', () => { changes.disconnect(); metaChanges.disconnect(); }, { once: true });
})();
