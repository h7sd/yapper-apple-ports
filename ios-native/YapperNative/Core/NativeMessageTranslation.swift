import Foundation

nonisolated struct NativeTranslationContent: Sendable {
    let text: String
    let protected: [String]

    init(_ source: String) throws {
        let expression = try NSRegularExpression(pattern: #"```[\s\S]*?```|`[^`\n]+`|<a?:[A-Za-z0-9_]+:[0-9a-f-]+>|<[@#&][^<>\s]{1,80}>|https?://[^\s<>]+"#)
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        protected = matches.compactMap { Range($0.range, in: source).map { String(source[$0]) } }
        var output = source
        for (index, match) in matches.enumerated().reversed() {
            if let range = Range(match.range, in: output) { output.replaceSubrange(range, with: "{{\(index)}}") }
        }
        guard output.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) else {
            throw NativeClientError.api(status: 400, message: "Diese Nachricht enthält keinen übersetzbaren Text.")
        }
        text = output
    }

    func restore(_ translated: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*(\d+)\s*\}\}"#) else { return translated }
        let matches = regex.matches(in: translated, range: NSRange(translated.startIndex..., in: translated))
        var output = translated
        var restored = Set<Int>()
        for match in matches.reversed() {
            guard let digits = Range(match.range(at: 1), in: translated), let index = Int(translated[digits]),
                  protected.indices.contains(index), let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: protected[index])
            restored.insert(index)
        }
        let missing = protected.indices.filter { !restored.contains($0) }.map { protected[$0] }
        return missing.isEmpty ? output : output + " " + missing.joined(separator: " ")
    }

    static func targetLanguage(_ preferred: String) -> String {
        if preferred.lowercased().hasPrefix("zh") {
            return ["tw", "hk", "mo", "hant"].contains(where: preferred.lowercased().contains) ? "zh-TW" : "zh-CN"
        }
        return preferred.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? "en"
    }
}

@MainActor struct NativeMessageTranslationService {
    let api: NativeAPI

    func translate(_ source: String, language: String, session: NativeSession) async throws -> String {
        let content = try NativeTranslationContent(source)
        let target = NativeTranslationContent.targetLanguage(language)
        let result = try await api.webAPI(path: "api/translate", method: "POST", body: .object(["text": .string(content.text), "to": .string(target)]), session: session)
        guard let text = result["text"].string else { throw NativeClientError.malformedResponse("Translation") }
        if let from = result["from"].string, from != "und", from.split(separator: "-").first?.lowercased() == target.split(separator: "-").first?.lowercased() {
            throw NativeClientError.api(status: 400, message: "Diese Nachricht ist bereits in deiner Sprache.")
        }
        return content.restore(text)
    }
}
