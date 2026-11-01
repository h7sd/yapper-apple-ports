import Foundation

nonisolated enum NativeCallAudioPolicy {
    static func normalizedOwner(remoteIdentity: String) -> String {
        screenCompanionOwner(remoteIdentity) ?? canonicalUUID(remoteIdentity) ?? remoteIdentity
    }

    static func shouldSubscribe(
        remoteIdentity: String,
        localIdentity: String,
        isScreenAudio: Bool,
        enabledScreenAudioOwner: String?
    ) -> Bool {
        if let companionOwner = screenCompanionOwner(remoteIdentity),
           let localOwner = canonicalUUID(localIdentity),
           companionOwner == localOwner {
            return false
        }
        guard isScreenAudio else { return true }
        guard !remoteIdentity.isEmpty,
              let enabledScreenAudioOwner,
              !enabledScreenAudioOwner.isEmpty else { return false }
        return normalizedOwner(remoteIdentity: remoteIdentity)
            == normalizedOwner(remoteIdentity: enabledScreenAudioOwner)
    }

    static func remoteAudioVolume(
        remoteIdentity: String,
        localIdentity: String,
        isScreenAudio: Bool,
        enabledScreenAudioOwner: String?,
        deafened: Bool,
        requestedVolume: Double
    ) -> Double {
        guard !deafened, requestedVolume.isFinite,
              shouldSubscribe(
                remoteIdentity: remoteIdentity,
                localIdentity: localIdentity,
                isScreenAudio: isScreenAudio,
                enabledScreenAudioOwner: enabledScreenAudioOwner
              ) else { return 0 }
        return min(2, max(0, requestedVolume))
    }

    private static func screenCompanionOwner(_ identity: String) -> String? {
        guard identity.hasSuffix(":screen") else { return nil }
        return canonicalUUID(String(identity.dropLast(":screen".count)))
    }

    private static func canonicalUUID(_ identity: String) -> String? {
        guard identity.utf8.count == 36, let uuid = UUID(uuidString: identity) else { return nil }
        return uuid.uuidString.lowercased()
    }
}
