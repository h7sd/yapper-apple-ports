import AVFoundation
import Foundation

nonisolated struct NativeNotificationSoundPolicy: Equatable, Sendable {
    let ownerID: String
    let status: String
    let blockedIDs: Set<String>
    /// Include hidden conversations in this set when preparing the policy.
    let mutedIDs: Set<String>

    var canDisturb: Bool { status != "dnd" }
}

extension NativeAPI {
    func nativeNotificationSoundPolicy(mutedIDs: Set<String>, session: NativeSession, defaultPreference: NativePresencePreference = .online) async throws -> NativeNotificationSoundPolicy {
        let preference = try await nativeOwnPresencePreference(session: session, defaultPreference: defaultPreference)
        try Task.checkCancellation()
        let blocks = try await table("blocks", query: [URLQueryItem(name: "select", value: "blocked")], session: session)
        guard case .array = blocks else { throw NativeClientError.invalidResponse }
        let blocked = try blocks.array.map { row in
            guard let id = row["blocked"].string, UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
            return id
        }
        return NativeNotificationSoundPolicy(ownerID: session.userID, status: preference.status, blockedIDs: Set(blocked), mutedIDs: mutedIDs)
    }
}

/// The caller supplies only new messages from its current, authorized DM/group snapshot.
/// Playback leaves the existing audio session untouched so calls and media retain their routing.
@MainActor final class NativeNotificationSound {
    static let preferenceKey = "native.notificationSounds"
    private let defaults: UserDefaults
    private let now: @MainActor () -> Date
    private let injectedPlay: (@MainActor () -> Void)?
    private var player: AVAudioPlayer?
    private var ownerID: String?
    private var seenMessages: [String: Date] = [:]
    private var lastBySender: [Sender: Date] = [:]
    private var lastPlayback: Date?

    private nonisolated struct Sender: Hashable {
        let channelID: String
        let authorID: String
    }

    init(defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Date = Date.init,
         play: (@MainActor () -> Void)? = nil) {
        self.defaults = defaults
        self.now = now
        injectedPlay = play
    }

    /// True means an eligible playback was requested; an unavailable audio device stays silent.
    @discardableResult
    func receive(message: ChatMessage, currentUserID: String, currentConversationID: String?, isActive: Bool,
                 policy: NativeNotificationSoundPolicy) -> Bool {
        guard !currentUserID.isEmpty, policy.ownerID == currentUserID else { return false }
        if ownerID != currentUserID { reset(); ownerID = currentUserID }
        guard isActive, defaults.object(forKey: Self.preferenceKey) == nil || defaults.bool(forKey: Self.preferenceKey),
              policy.canDisturb, !message.id.isEmpty, !message.channelID.isEmpty,
              message.author.id != currentUserID, message.author.id != "system",
              currentConversationID != message.channelID,
              !policy.mutedIDs.contains(message.channelID), !policy.blockedIDs.contains(message.author.id) else { return false }

        let instant = now()
        seenMessages = seenMessages.filter { instant.timeIntervalSince($0.value) < 120 }
        lastBySender = lastBySender.filter { instant.timeIntervalSince($0.value) < 5 }
        guard seenMessages[message.id] == nil else { return false }
        seenMessages[message.id] = instant
        let sender = Sender(channelID: message.channelID, authorID: message.author.id)
        guard lastPlayback.map({ instant.timeIntervalSince($0) >= 0.12 }) ?? true,
              lastBySender[sender].map({ instant.timeIntervalSince($0) >= 5 }) ?? true else { return false }
        lastPlayback = instant
        lastBySender[sender] = instant
        if let injectedPlay { injectedPlay() } else { playBundledSound() }
        return true
    }

    func reset() {
        player?.stop()
        ownerID = nil
        seenMessages.removeAll()
        lastBySender.removeAll()
        lastPlayback = nil
    }

    private func playBundledSound() {
        if player == nil {
            guard let url = Bundle.main.url(forResource: "message", withExtension: "mp3", subdirectory: "OriginalAssets/Sounds")
                    ?? Bundle.main.url(forResource: "message", withExtension: "mp3") else { return }
            player = try? AVAudioPlayer(contentsOf: url)
            player?.volume = 0.9
            player?.prepareToPlay()
        }
        player?.currentTime = 0
        player?.play()
    }
}
