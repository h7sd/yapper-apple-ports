import Foundation

enum URLPolicy {
    static let home = URL(string: "https://www.yapper.website")!
    static let trustedHosts: Set<String> = ["www.yapper.website", "yapper.website", "www.yapin.gg", "yapin.gg", "rt.yapper.website", "lk.yapper.website"]

    static func isTrusted(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return trustedHosts.contains(host)
    }

    static func siteURL(for path: String) -> URL {
        let trimmed = path.drop { $0 == "/" || $0 == "\\" || $0.isWhitespace }
        guard let url = URL(string: "/" + trimmed, relativeTo: home)?.absoluteURL,
              isTrusted(url), url.host == home.host else { return home }
        return url
    }

    static func deepLink(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "yapper", url.user == nil, url.password == nil,
              url.port == nil, let input = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var output = URLComponents(url: home, resolvingAgainstBaseURL: false) else { return nil }
        output.path = "/" + (url.host ?? "") + url.path
        output.percentEncodedQuery = input.percentEncodedQuery
        output.percentEncodedFragment = input.percentEncodedFragment
        guard let result = output.url, isTrusted(result) else { return nil }
        return result
    }

    static func canOpenExternally(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil else { return false }
        return ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }
}
