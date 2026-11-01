import Foundation
import CryptoKit

/// Wire format observed in the official voice module, topic `yapper-e2ee`.
/// P-256 ECDH wraps each sender's independent 32-byte media key with AES-GCM.
nonisolated struct NativeCallKeyPacket: Codable, Sendable {
    let i: Int
    let iv: String
    let ct: String
    let k: String
    let r: Int?
}

nonisolated struct NativeCallCrypto: Sendable {
    private let privateKey: P256.KeyAgreement.PrivateKey
    var publicKey: String { privateKey.publicKey.x963Representation.base64EncodedString() }

    init() { privateKey = P256.KeyAgreement.PrivateKey() }
    init(privateKey: Data) throws { self.privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey) }

    static func mediaKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    private func wrappingKey(peerPublicKey: String) throws -> SymmetricKey {
        guard peerPublicKey.utf8.count <= 100, let raw = Data(base64Encoded: peerPublicKey), raw.count == 65 else { throw NativeClientError.invalidResponse }
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: raw)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { SymmetricKey(data: $0) }
    }

    func wrap(_ key: Data, from sender: String, to recipient: String, index: Int, peerPublicKey: String, requestReply: Bool = false) throws -> NativeCallKeyPacket {
        guard key.count == 32, (0..<16).contains(index), !sender.isEmpty, !recipient.isEmpty else { throw NativeClientError.invalidResponse }
        let box = try AES.GCM.seal(key, using: wrappingKey(peerPublicKey: peerPublicKey), authenticating: Data("\(sender)|\(recipient)|\(index)".utf8))
        return NativeCallKeyPacket(i: index, iv: box.nonce.withUnsafeBytes { Data($0) }.base64EncodedString(), ct: (box.ciphertext + box.tag).base64EncodedString(), k: publicKey, r: requestReply ? 1 : nil)
    }

    func unwrap(_ packet: NativeCallKeyPacket, from sender: String, to recipient: String, peerPublicKey: String) throws -> Data {
        guard (0..<16).contains(packet.i), packet.k == peerPublicKey,
              packet.iv.utf8.count <= 24, packet.ct.utf8.count <= 80,
              let nonce = Data(base64Encoded: packet.iv), nonce.count == 12,
              let combined = Data(base64Encoded: packet.ct), combined.count == 48 else { throw NativeClientError.invalidResponse }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: combined.prefix(32), tag: combined.suffix(16))
        return try AES.GCM.open(box, using: wrappingKey(peerPublicKey: peerPublicKey), authenticating: Data("\(sender)|\(recipient)|\(packet.i)".utf8))
    }

    static func safetyCode(publicKeys: [String]) -> String {
        let keys = Set(publicKeys.filter { !$0.isEmpty }).sorted()
        guard keys.count >= 2 else { return "" }
        let hash = Array(SHA256.hash(data: Data(keys.joined(separator: "\n").utf8)))
        return (0..<6).map { i in
            let p = i * 4
            let number = UInt32(hash[p]) << 24 | UInt32(hash[p + 1]) << 16 | UInt32(hash[p + 2]) << 8 | UInt32(hash[p + 3])
            return String(format: "%05u", number % 100_000)
        }.joined(separator: " ")
    }
}
