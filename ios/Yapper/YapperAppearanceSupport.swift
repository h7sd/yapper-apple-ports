import Foundation

enum TrustedDocumentScript {
    static func guardedSource(_ source: String) -> String {
        let hosts = URLPolicy.trustedHosts.sorted().map { "\"\($0)\"" }.joined(separator: ",")
        return """
        (() => {
          'use strict';
          try {
            const url = new URL(window.location.href);
            if (window.top !== window.self || url.protocol !== 'https:' ||
                url.username || url.password || (url.port && url.port !== '443') ||
                ![\(hosts)].includes(url.hostname.toLowerCase())) return;
          } catch { return; }
          \(source)
        })();
        """
    }
}

enum YapperAppearanceSupport {
    static let preferenceKey = "enhancedProfileLayoutEnabled"

    static func isEnabled(in preferences: UserDefaults) -> Bool {
        preferences.object(forKey: preferenceKey) == nil || preferences.bool(forKey: preferenceKey)
    }

    static func bundledSource() -> String? {
        guard let url = Bundle.main.url(forResource: "YapperAppearance", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8), !source.isEmpty else { return nil }
        return TrustedDocumentScript.guardedSource(source)
    }
}
