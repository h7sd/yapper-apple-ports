import Foundation

/// The extension runtime receives the same origin boundary as the original app.
/// This adds no native message handlers or desktop bridge methods.
enum YapperCordSupport {
    static let preferenceKey = "yapperCordEnabled"

    static func bundledSource() -> String? {
        guard let url = Bundle.main.url(forResource: "YapperCord", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8), !source.isEmpty else { return nil }
        return guardedSource(source)
    }

    static func guardedSource(_ source: String) -> String {
        TrustedDocumentScript.guardedSource(source)
    }
}
