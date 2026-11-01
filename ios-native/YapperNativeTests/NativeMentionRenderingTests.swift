import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeMentionRenderingTests {
    private let uid = "11111111-1111-4111-8111-111111111111"

    @Test func `Unicode ranges preserve surrounding text and identify user role channel and audience`() {
        let text = "🌙 Hallo <@\(uid)> <@&\(uid)> <#\(uid)> @everyone @here!"
        let tokens = NativeMentionTokens.matches(in: text)
        #expect(tokens.map(\.target.kind) == [.user, .role, .channel, .everyone, .here])
        #expect((text as NSString).substring(with: tokens[0].range) == "<@\(uid)>")
        #expect(tokens[0].range.location == 9)
    }

    @Test(arguments: ["`<@ID>`", "```text\n<@ID>\n```", "```\n<@ID>", "\\<@ID>", "https://example.invalid/<@ID>", "www.example.invalid/<@ID>"])
    func `Code escaped tokens and URLs remain literal`(_ template: String) {
        #expect(NativeMentionTokens.matches(in: template.replacingOccurrences(of: "ID", with: uid)).isEmpty)
    }

    @Test func `Malformed identities and email-like audience text are not interactive mentions`() {
        #expect(NativeMentionTokens.matches(in: "<@not-a-uuid> @@everyone email@here.invalid @everyoneElse").isEmpty)
    }

    @Test func `Authoritative names replace tokens without interpreting their formatting`() throws {
        let store = NativeStore.fixture()
        let source = "🌙 <@\(uid)> und <@33333333-3333-4333-8333-333333333333>"
        #expect(NativeMentionRendering.plainText(source, store: store, snapshot: nil) == "🌙 @Yapper Demo und @Nova")
        let base = try NativeServerFixtures.snapshot()
        let member = NativeServerMember(user: try #require(base.members.first?.user), nickname: "A [B] *C*", joinedAt: nil)
        let snapshot = NativeServerSnapshot(server: base.server, channels: base.channels, categories: base.categories,
                                            members: [member], roles: base.roles, memberRoles: base.memberRoles)
        #expect(NativeMentionRendering.plainText("<@\(member.id)>", store: store, snapshot: snapshot) == "@A [B] *C*")
    }

    @Test func `Unknown profiles remain explicit instead of showing another account name`() {
        let text = "<@aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa>"
        #expect(NativeMentionRendering.plainText(text, store: NativeStore.fixture(), snapshot: nil) == "@Unbekannter Nutzer")
    }
}
