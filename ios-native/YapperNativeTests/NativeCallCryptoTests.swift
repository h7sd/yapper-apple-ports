import Foundation
import Testing
@testable import YapperNative

@Suite struct NativeCallCryptoTests {
    private let sender = "11111111-1111-4111-8111-111111111111"
    private let recipient = "22222222-2222-4222-8222-222222222222"
    private let senderPublic = "BG/wO5SSQc4drdQ1GeaWDgqFtBppoFwygQOqK84VlMoWPE91OlW/AdxT9sCwx+7ni0DG/30lqW4igrmJzvccFEo="
    private let recipientPublic = "BFUPRxAD89+Xw99QaseX9nIfsaH7e49vg9IkSYplyI4kE2CT1wEuUJpzcVy9CwCjzA/0tcAbP/oZarH7MnA2uOY="

    @Test func `CryptoKit opens the independent Node WebCrypto ECDH AES-GCM vector`() throws {
        let receiver = try NativeCallCrypto(privateKey: Data(repeating: 2, count: 32))
        #expect(receiver.publicKey == recipientPublic)
        let packet = NativeCallKeyPacket(i: 7, iv: "BAQEBAQEBAQEBAQE", ct: "sI30W8GmCxaIQo1UChioO698fW/Y3n2ceOftDUubiMTtORgbsf0dDxvbR1pszK/T", k: senderPublic, r: nil)
        #expect(try receiver.unwrap(packet, from: sender, to: recipient, peerPublicKey: senderPublic) == Data(repeating: 3, count: 32))
    }

    @Test func `Participant identities and media-key slot are authenticated`() throws {
        let one = try NativeCallCrypto(privateKey: Data(repeating: 1, count: 32))
        let two = try NativeCallCrypto(privateKey: Data(repeating: 2, count: 32))
        let packet = try one.wrap(Data(repeating: 3, count: 32), from: sender, to: recipient, index: 7, peerPublicKey: two.publicKey)
        #expect(try two.unwrap(packet, from: sender, to: recipient, peerPublicKey: one.publicKey) == Data(repeating: 3, count: 32))
        #expect(throws: (any Error).self) { try two.unwrap(packet, from: recipient, to: sender, peerPublicKey: one.publicKey) }
        let changedSlot = NativeCallKeyPacket(i: 8, iv: packet.iv, ct: packet.ct, k: packet.k, r: nil)
        #expect(throws: (any Error).self) { try two.unwrap(changedSlot, from: sender, to: recipient, peerPublicKey: one.publicKey) }
        #expect(throws: (any Error).self) { try two.unwrap(packet, from: sender, to: recipient, peerPublicKey: two.publicKey) }
    }

    @Test(arguments: [-1, 16, 100]) func `Invalid media-key indices are rejected`(index: Int) throws {
        let one = NativeCallCrypto(), two = NativeCallCrypto()
        #expect(throws: (any Error).self) { try one.wrap(Data(repeating: 0, count: 32), from: sender, to: recipient, index: index, peerPublicKey: two.publicKey) }
    }

    @Test func `Safety code matches WebCrypto and ignores duplicates or ordering`() {
        let expected = "61830 19278 96308 55794 26876 80788"
        #expect(NativeCallCrypto.safetyCode(publicKeys: [recipientPublic, senderPublic, senderPublic]) == expected)
        #expect(NativeCallCrypto.safetyCode(publicKeys: [senderPublic]) == "")
    }

    @Test func `Malformed packets and public keys do not reach media key installation`() throws {
        let one = NativeCallCrypto(), two = NativeCallCrypto()
        #expect(throws: (any Error).self) { try one.wrap(Data(repeating: 0, count: 31), from: sender, to: recipient, index: 0, peerPublicKey: two.publicKey) }
        #expect(throws: (any Error).self) { try one.wrap(Data(repeating: 0, count: 32), from: sender, to: recipient, index: 0, peerPublicKey: "not a public key") }
        let malformed = NativeCallKeyPacket(i: 0, iv: "BAQE", ct: "AAAA", k: one.publicKey, r: 1)
        #expect(throws: (any Error).self) { try two.unwrap(malformed, from: sender, to: recipient, peerPublicKey: one.publicKey) }
    }
}
