import Foundation

nonisolated enum BrowserLoginScript {
    /// Observes only the successful response of a login the user initiates in this fresh, private web view.
    /// It never reads request bodies, passwords, cookies or website storage.
    static func source(flowID: UUID) -> String {
        let script = #"""
        (() => {
          'use strict';
          const onLoginPage = () => window.top === window && ['https://yapin.gg','https://www.yapin.gg'].includes(location.origin) && location.pathname === '/';
          if (!onLoginPage()) return;
          const flow = '__NATIVE_FLOW__';
          const apiHost = '__NATIVE_API_HOST__';
          const original = window.fetch;
          if (typeof original !== 'function') return;
          const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
          const allowed = (url, method) => {
            if (method !== 'POST' || url.protocol !== 'https:' || url.username || url.password || (url.port && url.port !== '443') || url.hash) return false;
            if (url.origin === location.origin && url.pathname === '/api/login') return !url.search;
            if (url.hostname !== apiHost) return false;
            if (url.pathname === '/auth/v1/token') {
              const entries = Array.from(url.searchParams.entries());
              return entries.length === 1 && entries[0][0] === 'grant_type' && ['password','id_token'].includes(entries[0][1]);
            }
            const pieces = url.pathname.split('/').filter(Boolean);
            return !url.search && pieces.length === 5 && uuid.test(pieces[3]) && url.pathname === '/auth/v1/factors/' + pieces[3] + '/verify';
          };
          window.fetch = async function(input, init) {
            const beganOnLoginPage = onLoginPage();
            const response = await Reflect.apply(original, this, arguments);
            try {
              if (!beganOnLoginPage || !onLoginPage()) return response;
              const isRequest = typeof Request !== 'undefined' && input instanceof Request;
              const method = String((init && init.method) || (isRequest ? input.method : 'GET')).toUpperCase();
              const requestURL = new URL(isRequest ? input.url : String(input), location.href);
              const responseURL = new URL(response.url);
              if (!response.ok || response.redirected || requestURL.href !== responseURL.href || !allowed(responseURL, method)) return response;
              const copy = response.clone();
              const length = Number(copy.headers.get('content-length') || 0);
              if (length > 131072) return response;
              void copy.text().then(text => {
                if (!onLoginPage() || text.length > 131072) return;
                const data = JSON.parse(text);
                if (!data || typeof data.access_token !== 'string' || typeof data.refresh_token !== 'string' || data.access_token.length > 16384 || data.refresh_token.length > 4096) return;
                if (!document.getElementById('yapin-native-handoff-shield')) {
                  const shield = document.createElement('style');
                  shield.id = 'yapin-native-handoff-shield';
                  shield.textContent = 'html[data-yapin-native-handoff]{visibility:hidden!important}';
                  (document.head || document.documentElement).appendChild(shield);
                }
                document.documentElement.setAttribute('data-yapin-native-handoff','');
                const message = {flow, responseURL: responseURL.href, method, accessToken: data.access_token, refreshToken: data.refresh_token};
                window.webkit.messageHandlers.yapinNativeSignIn.postMessage(message);
              }).catch(() => {});
            } catch (_) {}
            return response;
          };
        })();
        """#
        return script.replacingOccurrences(of: "__NATIVE_FLOW__", with: flowID.uuidString)
            .replacingOccurrences(of: "__NATIVE_API_HOST__", with: NativeConfiguration.apiHost)
    }

    static let revealTwoFactor = "document.documentElement.removeAttribute('data-yapin-native-handoff');"
}
