import Foundation

nonisolated enum BrowserLoginResult: Equatable {
    case signedIn
    case requiresTwoFactor
    case rejected
}

nonisolated struct BrowserLoginValidation: Sendable {
    let session: NativeSession
    let requiresTwoFactor: Bool
}

nonisolated struct BrowserLoginTokens: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String

    init(accessToken: String, refreshToken: String) throws {
        guard (32...16_384).contains(accessToken.utf8.count),
              (8...4_096).contains(refreshToken.utf8.count),
              !accessToken.contains(where: \.isWhitespace),
              !refreshToken.contains(where: \.isWhitespace) else { throw NativeClientError.invalidResponse }
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

nonisolated struct BrowserTokenClaims: Decodable, Sendable {
    let sub: String
    let iss: String
    let role: String
    let exp: TimeInterval
    let aal: String?

    static func decode(_ token: String) throws -> BrowserTokenClaims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[2].isEmpty, parts[1].utf8.count <= 12_288 else { throw NativeClientError.invalidResponse }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let claims = try? JSONDecoder().decode(BrowserTokenClaims.self, from: data),
              UUID(uuidString: claims.sub) != nil,
              claims.iss == NativeConfiguration.apiURL.absoluteString + "/auth/v1",
              claims.role == "authenticated", claims.exp.isFinite else { throw NativeClientError.invalidResponse }
        return claims
    }
}

nonisolated enum BrowserLoginPolicy {
    static let startURL = URL(string: "https://yapin.gg/?auth=in")!
    static let handlerName = "yapinNativeSignIn"
    static let pageHosts: Set<String> = ["yapin.gg", "www.yapin.gg"]

    static func isLoginPage(_ url: URL) -> Bool {
        isTrustedPage(url) && url.path == "/"
    }

    static func isTrustedPage(_ url: URL) -> Bool {
        url.scheme == "https" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil && pageHosts.contains(url.host ?? "")
    }

    static func acceptsFrame(isMainFrame: Bool, scheme: String, host: String, port: Int, frameURL: URL?, currentURL: URL?) -> Bool {
        guard isMainFrame, scheme == "https", pageHosts.contains(host), port == 0 || port == 443,
              let frameURL, let currentURL else { return false }
        return isLoginPage(frameURL) && isLoginPage(currentURL)
            && frameURL.host == host && currentURL.host == host
    }

    static func isAuthResponse(_ url: URL, method: String) -> Bool {
        guard method == "POST", url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil else { return false }
        let path = url.path(percentEncoded: true)
        if pageHosts.contains(url.host ?? ""), path == "/api/login" { return url.query == nil }
        guard url.host == NativeConfiguration.apiHost else { return false }
        if path == "/auth/v1/token" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return query.count == 1 && query.first?.name == "grant_type" && ["password", "id_token"].contains(query.first?.value ?? "")
        }
        let pieces = path.split(separator: "/")
        return pieces.count == 5 && pieces[0] == "auth" && pieces[1] == "v1" && pieces[2] == "factors"
            && UUID(uuidString: String(pieces[3])) != nil && pieces[4] == "verify" && url.query == nil
            && path == "/auth/v1/factors/\(pieces[3])/verify"
    }

    static func tokens(from body: Any, flowID: UUID, pageURL: URL) throws -> BrowserLoginTokens {
        guard isLoginPage(pageURL), let body = body as? [String: Any], body.count == 5,
              body["flow"] as? String == flowID.uuidString,
              let source = body["responseURL"] as? String, source.utf8.count <= 512,
              let url = URL(string: source),
              let method = body["method"] as? String, isAuthResponse(url, method: method),
              let access = body["accessToken"] as? String,
              let refresh = body["refreshToken"] as? String else { throw NativeClientError.invalidResponse }
        if pageHosts.contains(url.host ?? "") {
            guard url.host == pageURL.host, (url.port ?? 443) == (pageURL.port ?? 443) else { throw NativeClientError.invalidResponse }
        }
        return try BrowserLoginTokens(accessToken: access, refreshToken: refresh)
    }
}
