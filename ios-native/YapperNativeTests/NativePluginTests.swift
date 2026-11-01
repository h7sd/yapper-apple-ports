import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativePluginTests {
    @Test func `Text replacement is literal longest-first and never recursive`() {
        let rules = [NativeTextRule(from: "a", to: "b"), NativeTextRule(from: "ab", to: "a"), NativeTextRule(from: "b", to: "c"), NativeTextRule(from: "$1", to: "literal")]
        #expect(NativePluginPreferences.replace("ab a b $1", rules: rules) == "a b c literal")
    }

    @Test func `Tracking cleanup preserves meaningful queries fragments punctuation and credentials`() {
        let input = "Sieh https://example.test/path?a=1&utm_source=test&gclid=123#part)."
        #expect(NativePluginPreferences.cleanURLs(input) == "Sieh https://example.test/path?a=1#part).")
        #expect(NativePluginPreferences.cleanURLs("https://user:secret@example.test/?utm_source=keep") == "https://user:secret@example.test/?utm_source=keep")
        #expect(NativePluginPreferences.cleanURLs("https://example.test/?utm_=keep&word=ä") == "https://example.test/?utm_=keep&word=ä")
    }

    @Test func `Transform settings remain local optional and bounded`() throws {
        let name = "website.yapper.tests.plugins." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let input = "hello https://example.test/?utm_source=x"
        #expect(NativePluginPreferences.transform(text: input, defaults: defaults) == input)
        defaults.set(true, forKey: NativePluginPreferences.clearURLs)
        defaults.set(true, forKey: NativePluginPreferences.textReplace)
        defaults.set(try JSONEncoder().encode([NativeTextRule(from: "hello", to: "Hallo")]), forKey: NativePluginPreferences.rulesKey)
        #expect(NativePluginPreferences.transform(text: input, defaults: defaults) == "Hallo https://example.test/")
        defaults.set(Data(repeating: 65, count: 300_000), forKey: NativePluginPreferences.rulesKey)
        #expect(NativePluginPreferences.rules(defaults: defaults).isEmpty)
    }
}
