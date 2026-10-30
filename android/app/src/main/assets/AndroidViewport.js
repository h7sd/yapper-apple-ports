/* SPDX-License-Identifier: GPL-3.0-or-later
 * Native bars/IME are measured in Android pixels and converted to CSS pixels.
 * The WebView draws the page background edge to edge; .app owns control insets.
 */
(() => {
  'use strict';
  if (window.top !== window.self) return;
  const id = 'yapper-android-viewport';
  const css = `
    html[data-yapper-android-viewport],html[data-yapper-android-viewport] body{margin:0;min-height:100%}
    html[data-yapper-android-viewport] .app{box-sizing:border-box!important;padding:var(--yapper-safe-top,0px) var(--yapper-safe-right,0px) var(--yapper-safe-bottom,0px) var(--yapper-safe-left,0px)!important}
    html[data-yapper-android-viewport] .app>.stage-row{min-height:0}
    html[data-yapper-android-viewport] .modal-overlay{box-sizing:border-box;padding-top:max(16px,var(--yapper-safe-top,0px));padding-right:max(16px,var(--yapper-safe-right,0px));padding-bottom:max(16px,var(--yapper-safe-bottom,0px));padding-left:max(16px,var(--yapper-safe-left,0px))}
    @media(max-width:760px){
      html[data-yapper-android-viewport]:not(.new-look) .app .rail{padding-top:10px!important}
      html[data-yapper-android-viewport]:not(.new-look) .app .sidebar-head{padding-top:10px!important}
      html[data-yapper-android-viewport]:not(.new-look) .app .main-head{padding-top:0!important;height:48px!important}
      html[data-yapper-android-viewport] .app nav.nl-tabbar:not([data-ypa-nav]){bottom:0!important;height:calc(56px + var(--yapper-safe-bottom,0px))!important;padding-bottom:var(--yapper-safe-bottom,0px)!important}
      html[data-yapper-android-viewport] .app .user-bar.floating:not([data-ypa-account]){bottom:calc(64px + var(--yapper-safe-bottom,0px))!important}
      html[data-yapper-android-viewport] .app.mobile-nav:not(.chat-open) .stage-row{padding-bottom:calc(56px + var(--yapper-safe-bottom,0px))}
      html[data-yapper-android-viewport][data-yapper-appearance] .app:not(.chat-open) nav[data-ypa-nav]{bottom:calc(12px + var(--yapper-safe-bottom,0px))!important}
      html[data-yapper-android-viewport][data-yapper-appearance] .app.mobile-nav:not(.chat-open) [data-ypa-account]:not(.top){bottom:calc(88px + var(--yapper-safe-bottom,0px))!important}
      html[data-yapper-android-viewport][data-yapper-appearance] .app.mobile-nav:not(.chat-open) [data-ypa-account]>.status-menu.me-pop{bottom:calc(172px + var(--yapper-safe-bottom,0px))!important;max-height:calc(var(--vvh,100dvh) - 188px - var(--yapper-safe-top,0px) - var(--yapper-safe-bottom,0px))!important}
      html[data-yapper-android-viewport][data-yapper-appearance] [data-ypa-profile-shell]{max-height:calc(var(--vvh,100dvh) - 20px - var(--yapper-safe-top,0px) - var(--yapper-safe-bottom,0px))!important}
    }
  `;
  function apply() {
    const root = document.documentElement;
    if (!root) return;
    root.setAttribute('data-yapper-android-viewport', '');
    const insets = window.__yapperAndroidInsets || {};
    for (const edge of ['top', 'right', 'bottom', 'left']) {
      const value = Number(insets[edge]);
      root.style.setProperty('--yapper-safe-' + edge, Math.max(0, Number.isFinite(value) ? value : 0) + 'px');
    }
    if (document.head && !document.getElementById(id)) {
      const style = document.createElement('style'); style.id = id; style.textContent = css; document.head.append(style);
    }
    const shadow = document.getElementById('yappercord-root')?.shadowRoot;
    if (shadow && !shadow.getElementById(id)) {
      const style = document.createElement('style'); style.id = id;
      style.textContent = 'dialog{margin-top:calc(12px + var(--yapper-safe-top,0px));margin-bottom:calc(12px + var(--yapper-safe-bottom,0px));max-height:calc(100dvh - 24px - var(--yapper-safe-top,0px) - var(--yapper-safe-bottom,0px))}.shell{max-height:calc(100dvh - 28px - var(--yapper-safe-top,0px) - var(--yapper-safe-bottom,0px))}';
      shadow.append(style);
    }
  }
  Object.defineProperty(window, '__yapperAndroidApplyInsets', { value: apply });
  let queued = false;
  const observer = new MutationObserver(() => {
    if (queued) return; queued = true;
    requestAnimationFrame(() => { queued = false; apply(); });
  });
  observer.observe(document, { childList: true, subtree: true });
  document.addEventListener('DOMContentLoaded', apply, { once: true });
  window.addEventListener('pagehide', () => observer.disconnect(), { once: true });
  apply();
})();
