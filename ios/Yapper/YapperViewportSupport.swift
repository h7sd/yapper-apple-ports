import Foundation

/// Background paint remains the actual web document's canvas, including theme changes.
enum YapperViewportSupport {
    static func rawSource() -> String? {
        guard let url = Bundle.main.url(forResource: "YapperViewport", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
