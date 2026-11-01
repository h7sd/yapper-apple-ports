import Foundation

nonisolated struct NativeMentionTarget: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable { case user, role, channel, everyone, here }
    let kind: Kind
    let targetID: String?
    var id: String { kind.rawValue + ":" + (targetID ?? "") }
}

nonisolated struct NativeMentionToken: Equatable, Sendable {
    let range: NSRange
    let target: NativeMentionTarget
}

nonisolated enum NativeMentionTokens {
    /// Render the observed wire tokens; leave escaped tokens, code and URLs literal.
    static func matches(in text: String) -> [NativeMentionToken] {
        let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let regex = try? NSRegularExpression(pattern: "<(@&|@|#)(" + uuid + ")>|(?<![\\w@])@(everyone|here)\\b"),
              let literals = try? NSRegularExpression(pattern: #"```[\s\S]*?(?:```|$)|`[^`\n]*`|https?://[^\s]+|www\.[^\s]+"#) else { return [] }
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        let ignored = literals.matches(in: text, range: full).map(\.range)
        return regex.matches(in: text, range: full).compactMap { match in
            guard !ignored.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return nil }
            var at = match.range.location, slashes = 0
            while at > 0 && source.character(at: at - 1) == 92 { slashes += 1; at -= 1 }
            guard slashes.isMultiple(of: 2) else { return nil }
            if match.range(at: 3).location != NSNotFound {
                let all = source.substring(with: match.range(at: 3)) == "everyone"
                return NativeMentionToken(range: match.range, target: NativeMentionTarget(kind: all ? .everyone : .here, targetID: nil))
            }
            let prefix = source.substring(with: match.range(at: 1))
            guard let id = UUID(uuidString: source.substring(with: match.range(at: 2)))?.uuidString.lowercased() else { return nil }
            return NativeMentionToken(range: match.range, target: NativeMentionTarget(kind: prefix == "@&" ? .role : prefix == "#" ? .channel : .user, targetID: id))
        }
    }
}
