import Foundation
import Observation
import LiveKit

@MainActor @Observable final class NativeCallController: NSObject, RoomDelegate {
    private(set) var room: Room?
    private(set) var channelID: String?
    private(set) var serverID: String?
    private(set) var title = ""
    private(set) var status = ""
    private(set) var isConnecting = false
    private(set) var microphoneOn = false
    private(set) var cameraOn = false
    private(set) var screenOn = false
    private(set) var deafened = false
    private(set) var encrypted = false
    private(set) var listener = false
    private(set) var moderatorMuted = false
    private(set) var safetyCode = ""
    private(set) var outputVolume: Double = 1
    private(set) var speakerPreferred = true
    private(set) var noClip = false
    var featureStore: NativeStore? { store }
    private(set) var participants: [Participant] = []
    var errorMessage: String?
    var presented = false
    @ObservationIgnored private var identity = ""
    @ObservationIgnored private var store: NativeStore?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var keys: NativeCallCrypto?
    @ObservationIgnored private var keyProvider: BaseKeyProvider?
    @ObservationIgnored private var mediaKey = Data()
    @ObservationIgnored private var keyIndex = 0
    @ObservationIgnored private var sentKeys: [String: String] = [:]
    @ObservationIgnored private var rotateTask: Task<Void, Never>?
    @ObservationIgnored private var activeAttempt: NativeCallAttempt?
    @ObservationIgnored private var requestedJoinID: UUID?
    @ObservationIgnored private var pendingEnds: [UUID: NativePendingCallEnd] = [:]
    @ObservationIgnored private var peerPublicKeys: [String: String] = [:]
    @ObservationIgnored private var stageRole: String?
    @ObservationIgnored private var noAnswerTask: Task<Void, Never>?
    @ObservationIgnored private var retryTarget: NativeCallRetryTarget?

    func join(store: NativeStore, channelID: String, title: String, serverID: String? = nil, startNewCall: Bool = true) async {
        if self.channelID == channelID, room != nil { presented = true; return }
        guard !isConnecting, store.authState == .signedIn, let accountID = store.user?.id else { return }
        let requestID = UUID()
        requestedJoinID = requestID
        isConnecting = true
        await disconnectCurrent(preservingJoin: requestID)
        // An old end_call for this account/channel must finish before starting a replacement call.
        while requestedJoinID == requestID {
            let waiting = pendingEnds.filter { $0.value.accountID == accountID && $0.value.channelID == channelID }
            if waiting.isEmpty { break }
            for (id, pending) in waiting { await pending.task.value; pendingEnds.removeValue(forKey: id) }
        }
        guard requestedJoinID == requestID, store.authState == .signedIn, store.user?.id == accountID else { return }
        let attempt = NativeCallAttempt(store: store, accountID: accountID, channelID: channelID, serverID: serverID)
        activeAttempt = attempt
        revision = attempt.id
        self.store = store
        self.channelID = channelID
        self.serverID = serverID
        self.title = title
        retryTarget = NativeCallRetryTarget(store: store, accountID: accountID, channelID: channelID, title: title, serverID: serverID)
        isConnecting = true
        presented = true
        status = "Verbindung wird hergestellt …"
        errorMessage = nil
        do {
            let ticket = try await store.withAuthenticatedSession { api, session in
                guard self.revision == attempt.id, session.userID == accountID else { throw CancellationError() }
                if serverID == nil, startNewCall {
                    _ = try await api.rpc("start_call", arguments: ["cid": .string(channelID)], session: session)
                    attempt.startedRing = true
                }
                guard self.revision == attempt.id else { throw CancellationError() }
                return try await api.webAPI(path: "api/livekit-token", method: "POST", body: .object(["channelId": .string(channelID), "e2ee": .bool(true)]), session: session)
            }
            guard revision == attempt.id, store.authState == .signedIn, store.user?.id == accountID else { throw CancellationError() }
            guard let token = ticket["token"].string, !token.isEmpty,
                  let endpoint = ticket["url"].string, let url = URL(string: endpoint),
                  url.scheme == "wss", url.host != nil, url.user == nil, url.password == nil else { throw NativeClientError.invalidResponse }
            identity = accountID
            guard let encryptionEnabled = ticket["e2ee"].bool else { throw NativeClientError.malformedResponse("Voice encryption policy") }
            encrypted = encryptionEnabled
            stageRole = ticket["stage"].string
            listener = stageRole == "listener"
            moderatorMuted = ticket["voiceMuted"].bool == true
            var options = RoomOptions(adaptiveStream: true, dynacast: true)
            if encrypted {
                let crypto = NativeCallCrypto()
                let provider = BaseKeyProvider(options: KeyProviderOptions(sharedKey: false, ratchetWindowSize: 0, keyRingSize: 16, discardFrameWhenCryptorNotReady: true, keyDerivationAlgorithm: .hkdf))
                keys = crypto
                keyProvider = provider
                mediaKey = NativeCallCrypto.mediaKey()
                keyIndex = 0
                provider.setKey(keyData: mediaKey, participantId: identity, index: 0)
                provider.setCurrentKeyIndex(0)
                // The web client's handshake uses unencrypted *data* packets to wrap media keys.
                // EncryptionOptions would additionally encrypt that channel and break interoperability.
                options = RoomOptions(adaptiveStream: true, dynacast: true, e2eeOptions: E2EEOptions(keyProvider: provider))
            }
            let connected = Room(delegate: self, roomOptions: options)
            attempt.room = connected
            room = connected
            try await connected.connect(url: endpoint, token: token)
            attempt.didConnect = true
            guard revision == attempt.id, room === connected, store.authState == .signedIn, store.user?.id == accountID else { throw CancellationError() }
            guard connected.localParticipant.identity?.stringValue == accountID else { throw NativeClientError.invalidResponse }
            if let keys {
                connected.setE2EEEnabled(true)
                try await connected.localParticipant.set(attributes: ["e2ee": keys.publicKey])
                guard revision == attempt.id, room === connected, store.authState == .signedIn, store.user?.id == accountID else { throw CancellationError() }
                await shareKeys(force: true)
            }
            if noClip { try await connected.localParticipant.set(attributes: ["noclip": "1"]) }
            guard revision == attempt.id, room === connected, store.authState == .signedIn else { throw CancellationError() }
            isConnecting = false
            status = listener ? "Zuhören" : "Verbunden"
            updateParticipants()
            if serverID == nil, startNewCall { scheduleNoAnswer(for: attempt) }
            // Joining starts muted. Enabling the microphone is always a separate user action.
        } catch {
            if revision == attempt.id {
                isConnecting = false
                errorMessage = error is CancellationError ? nil : error.localizedDescription
                status = "Nicht verbunden"
                room = nil
                activeAttempt = nil
                // Clear only this attempt, synchronously, before any disconnect can suspend.
                clearKeys()
            }
            let ending = queueCallEnd(attempt)
            await attempt.room?.disconnect()
            await ending?.value
            pendingEnds.removeValue(forKey: attempt.id)
        }
    }

    func leave() async {
        requestedJoinID = nil
        retryTarget = nil
        await disconnectCurrent(preservingJoin: nil)
    }

    func retry() async {
        guard let target = retryTarget, target.store.authState == .signedIn, target.store.user?.id == target.accountID else { return }
        await join(store: target.store, channelID: target.channelID, title: target.title, serverID: target.serverID, startNewCall: !target.store.activeCallChannels.contains(target.channelID))
    }

    private func disconnectCurrent(preservingJoin requestID: UUID?, finishConnectedCall: Bool = true) async {
        revision = UUID()
        let old = room
        let attempt = activeAttempt
        activeAttempt = nil
        room = nil
        channelID = nil
        serverID = nil
        participants = []
        microphoneOn = false
        cameraOn = false
        screenOn = false
        deafened = false
        listener = false
        moderatorMuted = false
        stageRole = nil
        isConnecting = requestID != nil && requestedJoinID == requestID
        status = ""
        clearKeys()
        let ending = attempt.flatMap { queueCallEnd($0, finishConnectedCall: finishConnectedCall) }
        await old?.disconnect()
        await ending?.value
        if let attempt { pendingEnds.removeValue(forKey: attempt.id) }
    }

    private func queueCallEnd(_ attempt: NativeCallAttempt, finishConnectedCall: Bool = true) -> Task<Void, Never>? {
        if let ending = attempt.endTask { return ending }
        let remotePresence = attempt.room?.remoteParticipants.values.map { NativeCallPresence(identity: $0.identity?.stringValue, audioTrackCount: $0.audioTracks.count) } ?? []
        guard NativeCallLifecyclePolicy.shouldEndGlobalCall(serverID: attempt.serverID, startedRing: attempt.startedRing, didConnect: attempt.didConnect, finishConnectedCall: finishConnectedCall, remoteParticipants: remotePresence) else { return nil }
        if let newer = activeAttempt, newer.id != attempt.id, newer.accountID == attempt.accountID, newer.channelID == attempt.channelID { return nil }
        guard attempt.store.authState == .signedIn, attempt.store.user?.id == attempt.accountID else { return nil }
        let task = Task {
            _ = try? await attempt.store.withAuthenticatedSession { api, session in
                guard session.userID == attempt.accountID else { throw CancellationError() }
                return try await api.rpc("end_call", arguments: ["cid": .string(attempt.channelID)], session: session)
            }
        }
        attempt.endTask = task
        pendingEnds[attempt.id] = NativePendingCallEnd(accountID: attempt.accountID, channelID: attempt.channelID, task: task)
        return task
    }

    func setMicrophone(_ enabled: Bool) async {
        guard let room, !enabled || !listener else { return }
        do {
            if enabled, moderatorMuted {
                guard let store, let channelID else { return }
                let ticket = try await store.withAuthenticatedSession { api, session in
                    try await api.webAPI(path: "api/livekit-token", method: "POST", body: .object(["channelId": .string(channelID), "e2ee": .bool(true)]), session: session)
                }
                guard self.room === room else { return }
                moderatorMuted = ticket["voiceMuted"].bool != false
                guard !moderatorMuted else {
                    errorMessage = "Ein Moderator hat dein Mikrofon vorübergehend stummgeschaltet."
                    return
                }
            }
            try await room.localParticipant.setMicrophone(enabled: enabled)
            guard self.room === room else { return }
            microphoneOn = enabled
            if enabled && deafened { await setDeafened(false) }
        } catch { if self.room === room { errorMessage = error.localizedDescription } }
    }

    func setCamera(_ enabled: Bool) async {
        guard let room, !enabled || !listener else { return }
        do { try await room.localParticipant.setCamera(enabled: enabled); if self.room === room { cameraOn = enabled; updateParticipants() } }
        catch { if self.room === room { errorMessage = error.localizedDescription } }
    }

    func setScreen(_ enabled: Bool) async {
        guard let room, !enabled || !listener else { return }
        do { try await room.localParticipant.setScreenShare(enabled: enabled); if self.room === room { screenOn = enabled; updateParticipants() } }
        catch { if self.room === room { errorMessage = error.localizedDescription } }
    }

    func setDeafened(_ enabled: Bool) async {
        guard let room else { return }
        if enabled { await setMicrophone(false) }
        guard self.room === room else { return }
        for participant in room.remoteParticipants.values {
            for publication in participant.trackPublications.values {
                if let audio = publication.track as? RemoteAudioTrack { audio.volume = enabled ? 0 : outputVolume }
            }
        }
        do {
            var attributes = room.localParticipant.attributes
            attributes["deafened"] = enabled ? "1" : ""
            try await room.localParticipant.set(attributes: attributes)
            if self.room === room { deafened = enabled }
        } catch { if self.room === room { errorMessage = error.localizedDescription } }
    }

    func raiseHand(_ raised: Bool) async {
        guard let room else { return }
        do {
            var attributes = room.localParticipant.attributes
            attributes["hand"] = raised ? "1" : ""
            try await room.localParticipant.set(attributes: attributes)
        } catch { if self.room === room { errorMessage = error.localizedDescription } }
    }

    func setOutputVolume(_ value: Double) {
        outputVolume = min(1, max(0, value))
        guard let room else { return }
        for participant in room.remoteParticipants.values {
            for publication in participant.audioTracks {
                (publication.track as? RemoteAudioTrack)?.volume = deafened ? 0 : outputVolume
            }
        }
    }

    func preferSpeaker(_ preferred: Bool) {
        AudioManager.shared.isSpeakerOutputPreferred = preferred
        speakerPreferred = preferred
    }

    func flipCamera() async {
        guard let room,
              let track = room.localParticipant.videoTracks.first(where: { $0.source == .camera })?.track as? LocalVideoTrack,
              let camera = track.capturer as? CameraCapturer else { return }
        do { _ = try await camera.switchCameraPosition() }
        catch { if self.room === room { errorMessage = error.localizedDescription } }
    }

    func setNoClip(_ enabled: Bool) async {
        guard let room else { return }
        do {
            try await room.localParticipant.set(attributes: ["noclip": enabled ? "1" : ""])
            if self.room === room { noClip = enabled }
        } catch { if self.room === room { errorMessage = error.localizedDescription } }
    }

    private func clearKeys() {
        noAnswerTask?.cancel()
        noAnswerTask = nil
        rotateTask?.cancel()
        rotateTask = nil
        keys = nil
        keyProvider = nil
        mediaKey = Data()
        identity = ""
        keyIndex = 0
        safetyCode = ""
        sentKeys = [:]
        peerPublicKeys = [:]
        encrypted = false
    }

    private func scheduleNoAnswer(for attempt: NativeCallAttempt) {
        noAnswerTask?.cancel()
        noAnswerTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
                guard let self, self.revision == attempt.id, let room = self.room,
                      !room.remoteParticipants.values.contains(where: { !NativeCallLifecyclePolicy.isScreenCompanion($0.identity?.stringValue ?? "") }) else { return }
                self.errorMessage = "Keine Antwort."
                await self.disconnectCurrent(preservingJoin: nil)
            } catch { }
        }
    }

    private func synchronizeLocalMedia(in room: Room) {
        guard self.room === room else { return }
        let publications = room.localParticipant.trackPublications.values
        microphoneOn = publications.contains { $0.source == .microphone && !$0.isMuted }
        cameraOn = publications.contains { $0.source == .camera && !$0.isMuted }
        screenOn = publications.contains { $0.source == .screenShareVideo && !$0.isMuted }
        updateParticipants()
    }

    private func moved(to target: String, in room: Room) async {
        guard self.room === room, let store, let serverID, UUID(uuidString: target) != nil, target != channelID else { return }
        let expected = revision
        status = "Kanalwechsel …"
        do {
            let result = try await store.withAuthenticatedSession { api, session in
                let channels = try await api.table("channels", query: [URLQueryItem(name: "id", value: "eq." + target), URLQueryItem(name: "server_id", value: "eq." + serverID), URLQueryItem(name: "select", value: "id,server_id,name,kind"), URLQueryItem(name: "limit", value: "1")], session: session)
                guard let channel = channels.array.first, channel["id"].string == target, channel["server_id"].string == serverID, channel["kind"].string == "voice" else { throw NativeClientError.invalidResponse }
                let ticket = try await api.webAPI(path: "api/livekit-token", method: "POST", body: .object(["channelId": .string(target), "e2ee": .bool(true)]), session: session)
                return NativeJSON.object(["channel": channel, "ticket": ticket])
            }
            guard self.room === room, revision == expected else { return }
            channelID = target
            title = result["channel"]["name"].string ?? "Sprachkanal"
            stageRole = result["ticket"]["stage"].string
            listener = stageRole == "listener"
            moderatorMuted = result["ticket"]["voiceMuted"].bool == true
            if listener || moderatorMuted { await setMicrophone(false) }
            guard self.room === room, revision == expected else { return }
            if listener { await setCamera(false); await setScreen(false) }
            guard self.room === room, revision == expected else { return }
            retryTarget = NativeCallRetryTarget(store: store, accountID: identity, channelID: target, title: title, serverID: serverID)
            peerPublicKeys = [:]; sentKeys = [:]
            rotateKey()
            status = listener ? "Zuhören" : "Verbunden"
            synchronizeLocalMedia(in: room)
        } catch {
            guard self.room === room, revision == expected else { return }
            errorMessage = "Der Anruf wurde verschoben, aber der neue Kanal konnte nicht geöffnet werden. " + error.localizedDescription
            retryTarget = nil
            await disconnectCurrent(preservingJoin: nil, finishConnectedCall: false)
        }
    }

    private func updateParticipants() {
        guard let room else { participants = []; return }
        participants = [room.localParticipant] + room.remoteParticipants.values.sorted { ($0.identity?.stringValue ?? "") < ($1.identity?.stringValue ?? "") }
        if let keys { safetyCode = NativeCallCrypto.safetyCode(publicKeys: [keys.publicKey] + room.remoteParticipants.values.compactMap { $0.attributes["e2ee"] }) }
    }

    private func shareKeys(force: Bool = false) async {
        guard let room, let keys else { return }
        let expected = revision
        for participant in room.remoteParticipants.values {
            guard revision == expected else { return }
            guard let remoteID = participant.identity?.stringValue, remoteID != identity,
                  let publicKey = participant.attributes["e2ee"] ?? peerPublicKeys[remoteID] else { continue }
            let stamp = "\(publicKey):\(keyIndex)"
            if !force && sentKeys[remoteID] == stamp { continue }
            do {
                let packet = try keys.wrap(mediaKey, from: identity, to: remoteID, index: keyIndex, peerPublicKey: publicKey, requestReply: force)
                try await room.localParticipant.publish(data: JSONEncoder().encode(packet), options: DataPublishOptions(destinationIdentities: [Participant.Identity(from: remoteID)], topic: "yapper-e2ee", reliable: true))
                if revision == expected { sentKeys[remoteID] = stamp }
            } catch { if revision == expected { sentKeys.removeValue(forKey: remoteID) } }
        }
        updateParticipants()
    }

    private func receiveKey(data: Data, participant: RemoteParticipant, in room: Room) async {
        guard self.room === room, data.count <= 1024, let keys,
              let remoteID = participant.identity?.stringValue,
              let packet = try? JSONDecoder().decode(NativeCallKeyPacket.self, from: data) else { return }
        let publicKey = participant.attributes["e2ee"] ?? packet.k
        guard let key = try? keys.unwrap(packet, from: remoteID, to: identity, peerPublicKey: publicKey) else { return }
        peerPublicKeys[remoteID] = publicKey
        keyProvider?.setKey(keyData: key, participantId: remoteID, index: Int32(packet.i))
        if packet.r == 1 { sentKeys.removeValue(forKey: remoteID) }
        await shareKeys()
    }

    private func rotateKey() {
        guard keys != nil else { return }
        let expected = revision
        rotateTask?.cancel()
        rotateTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                guard let self, self.revision == expected else { return }
                self.mediaKey = NativeCallCrypto.mediaKey()
                self.keyIndex = (self.keyIndex + 1) % 16
                let key = self.mediaKey
                let index = self.keyIndex
                await self.shareKeys(force: true)
                try await Task.sleep(for: .milliseconds(1500))
                guard self.revision == expected else { return }
                self.keyProvider?.setKey(keyData: key, participantId: self.identity, index: Int32(index))
                self.keyProvider?.setCurrentKeyIndex(Int32(index))
            } catch { }
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in guard let self, self.room === room else { return }; await self.shareKeys(); self.updateParticipants() }
    }
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in guard let self, self.room === room else { return }; self.updateParticipants(); self.rotateKey() }
    }
    nonisolated func room(_ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]) {
        Task { @MainActor [weak self] in guard let self, self.room === room else { return }; await self.shareKeys(); self.updateParticipants() }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == "yapper-e2ee", let participant else { return }
        Task { @MainActor [weak self] in await self?.receiveKey(data: data, participant: participant, in: room) }
    }
    nonisolated func roomDidReconnect(_ room: Room) {
        Task { @MainActor [weak self] in guard let self, self.room === room else { return }; self.status = "Verbunden"; await self.shareKeys(force: true) }
    }
    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor [weak self] in guard let self, self.room === room else { return }; self.status = connectionState == .connected ? "Verbunden" : "Verbindung wird hergestellt …" }
    }
    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in guard let self, self.room === room else { return }; self.errorMessage = error?.localizedDescription ?? "Die Verbindung zum Anruf wurde getrennt."; await self.disconnectCurrent(preservingJoin: nil, finishConnectedCall: false) }
    }
    nonisolated func room(_ room: Room, didMoveToRoomNamed roomName: String) {
        Task { @MainActor [weak self] in await self?.moved(to: roomName, in: room) }
    }
    nonisolated func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        Task { @MainActor [weak self] in self?.synchronizeLocalMedia(in: room) }
    }
    nonisolated func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        Task { @MainActor [weak self] in self?.synchronizeLocalMedia(in: room) }
    }
    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            if participant === room.localParticipant { self.synchronizeLocalMedia(in: room) }
            else { self.updateParticipants() }
        }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in guard let self, self.room === room else { return }; self.updateParticipants(); self.setOutputVolume(Double(self.outputVolume)) }
    }

    nonisolated func room(_ room: Room, participant: Participant, didUpdatePermissions permissions: ParticipantPermissions) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            if participant === room.localParticipant, self.stageRole != nil, self.stageRole != "mod" {
                self.listener = !permissions.canPublish
                self.stageRole = self.listener ? "listener" : "speaker"
            if self.listener {
                _ = try? await room.localParticipant.setMicrophone(enabled: false)
                _ = try? await room.localParticipant.setScreenShare(enabled: false)
                _ = try? await room.localParticipant.setCamera(enabled: false)
                guard self.room === room else { return }
                self.microphoneOn = false
                self.screenOn = false
                self.cameraOn = false
                self.status = "Zuhören"
            } else {
                var attributes = room.localParticipant.attributes
                attributes["hand"] = ""
                try? await room.localParticipant.set(attributes: attributes)
                if self.room === room { self.status = "Verbunden" }
            }
            }
            await self.shareKeys(force: true)
        }
    }
}

@MainActor private final class NativeCallAttempt {
    let id = UUID()
    let store: NativeStore
    let accountID: String
    let channelID: String
    let serverID: String?
    var startedRing = false
    var didConnect = false
    var room: Room?
    var endTask: Task<Void, Never>?
    init(store: NativeStore, accountID: String, channelID: String, serverID: String?) {
        self.store = store; self.accountID = accountID; self.channelID = channelID; self.serverID = serverID
    }
}

private struct NativePendingCallEnd {
    let accountID: String
    let channelID: String
    let task: Task<Void, Never>
}

private struct NativeCallRetryTarget {
    let store: NativeStore
    let accountID: String
    let channelID: String
    let title: String
    let serverID: String?
}

nonisolated enum NativeCallLifecyclePolicy {
    static func shouldEndGlobalCall(serverID: String?, startedRing: Bool, didConnect: Bool, finishConnectedCall: Bool, remoteParticipants: [NativeCallPresence]) -> Bool {
        guard serverID == nil else { return false }
        if !didConnect { return startedRing }
        // Native users join before publishing a microphone. Zero tracks alone does not mean absent.
        return finishConnectedCall && remoteParticipants.allSatisfy { participant in
            participant.identity.map(isScreenCompanion) == true && participant.audioTrackCount == 0
        }
    }

    static func isScreenCompanion(_ identity: String) -> Bool {
        identity.hasSuffix(":screen") && UUID(uuidString: String(identity.dropLast(7))) != nil
    }
}

nonisolated struct NativeCallPresence: Sendable {
    let identity: String?
    let audioTrackCount: Int
}
