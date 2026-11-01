import Foundation

nonisolated struct NativeTextRule: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var from: String
    var to: String
}

enum NativePluginPreferences {
    static let characterCounter = "native.plugin.characterCounter"
    static let imageZoom = "native.plugin.imageZoom"
    static let pictureInPicture = "native.plugin.pictureInPicture"
    static let clearURLs = "native.plugin.clearURLs"
    static let textReplace = "native.plugin.textReplace"
    static let rulesKey = "native.plugin.textRules"

    static func rules(defaults: UserDefaults = .standard) -> [NativeTextRule] {
        guard let data = defaults.data(forKey: rulesKey), data.count <= 256_000,
              let rules = try? JSONDecoder().decode([NativeTextRule].self, from: data) else { return [] }
        return Array(rules.prefix(30)).filter { !$0.from.isEmpty && $0.from.utf16.count <= 100 && $0.to.utf16.count <= 1000 }
    }

    static func transform(text: String, defaults: UserDefaults = .standard) -> String {
        var value = text
        if defaults.bool(forKey: textReplace) { value = replace(value, rules: rules(defaults: defaults)) }
        if defaults.bool(forKey: clearURLs) { value = cleanURLs(value) }
        return value
    }

    static func replace(_ text: String, rules: [NativeTextRule]) -> String {
        let sorted = rules.enumerated().filter { !$0.element.from.isEmpty }.sorted {
            $0.element.from.utf16.count == $1.element.from.utf16.count ? $0.offset < $1.offset : $0.element.from.utf16.count > $1.element.from.utf16.count
        }.map(\.element)
        guard !sorted.isEmpty,
              let regex = try? NSRegularExpression(pattern: sorted.map { NSRegularExpression.escapedPattern(for: $0.from) }.joined(separator: "|")) else { return text }
        let ns = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let original = ns.substring(with: match.range)
            guard let rule = sorted.first(where: { $0.from == original }), let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: rule.to)
        }
        return result
    }

    static func cleanURLs(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let originalRange = Range(match.range, in: text), let outputRange = Range(match.range, in: result) else { continue }
            let original = String(text[originalRange])
            let tail = original.reversed().prefix(while: { ".,;!?) ]".contains($0) }).reversed()
            let candidate = String(original.dropLast(tail.count))
            guard var url = URLComponents(string: candidate), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil, let query = url.queryItems else { continue }
            let tracking: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "twclid", "igshid", "mc_cid", "mc_eid"]
            let filtered = query.filter { item in
                let name = item.name.lowercased()
                return !tracking.contains(name) && !(name.hasPrefix("utm_") && name.count > 4)
            }
            guard filtered.count != query.count else { continue }
            url.queryItems = filtered.isEmpty ? nil : filtered
            if let cleaned = url.string { result.replaceSubrange(outputRange, with: cleaned + String(tail)) }
        }
        return result
    }
}
