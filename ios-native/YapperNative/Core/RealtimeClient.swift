import Foundation

nonisolated struct RealtimeMutation: Decodable, Sendable {
    let table: String
    let operation: String
    let record: MessageRow?
    let old_record: DeletedMessage?
    nonisolated struct DeletedMessage: Decodable, Sendable {
        let id: String?
        let channel_id: String?
    }
}

nonisolated struct RealtimeEnvelope: Decodable, Sendable {
    let type: String
    let ok: Bool?
    let event: String?
    let topic: String?
    let payload: RealtimeMutation?
    let approvedTopics: [String]?
    let rawPayload: NativeJSON?

    // `subscribed.ok` is an array, whereas `auth.ok` is a Boolean.
    private enum CodingKeys: String, CodingKey { case type, ok, event, topic, payload }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        ok = type == "auth" ? try c.decodeIfPresent(Bool.self, forKey: .ok) : nil
        approvedTopics = type == "subscribed" ? try c.decodeIfPresent([String].self, forKey: .ok) : nil
        event = try c.decodeIfPresent(String.self, forKey: .event)
        topic = try c.decodeIfPresent(String.self, forKey: .topic)
        payload = type == "event" && event == "message" ? try c.decodeIfPresent(RealtimeMutation.self, forKey: .payload) : nil
        rawPayload = type == "event" ? try c.decodeIfPresent(NativeJSON.self, forKey: .payload) : nil
    }
}

/// A subscription acknowledgement can confirm a topic change on the same socket.
/// Only the first approved user subscription on a replacement socket requires a resync.
nonisolated struct RealtimeSubscriptionLifecycle: Sendable {
    private(set) var hasConnected: Bool
    private var awaitingFirstApproval = true

    init(previouslyConnected: Bool = false) { hasConnected = previouslyConnected }
    mutating func beginSocket() { awaitingFirstApproval = true }
    mutating func acknowledge(userTopicApproved: Bool) -> Bool {
        guard userTopicApproved, awaitingFirstApproval else { return false }
        awaitingFirstApproval = false
        let needsResync = hasConnected
        hasConnected = true
        return needsResync
    }
}

/// Native client for the observed Yapin realtime protocol; no JavaScript engine or embedded page.
@MainActor final class RealtimeClient {
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var generation = 0
    private var credentials: NativeSession?
    private var retryDelay = 1
    private var subscribedTopics: Set<String> = []
    private var desiredTopics: Set<String> = []
    private var authenticated = false
    private var lastReceivedAt = Date()
    private var subscriptionLifecycle = RealtimeSubscriptionLifecycle()
    var onMutation: (@MainActor (RealtimeMutation) -> Void)?
    var onStatus: (@MainActor (String) -> Void)?
    var onReconnect: (@MainActor () -> Void)?
    var onEvent: (@MainActor (String, NativeJSON) -> Void)?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }

    func connect(session credentials: NativeSession) {
        let reconnectingSameAccount = self.credentials?.userID == credentials.userID && subscriptionLifecycle.hasConnected
        let retainedTopics = reconnectingSameAccount ? desiredTopics : []
        disconnect()
        desiredTopics = retainedTopics
        self.credentials = credentials
        subscriptionLifecycle = RealtimeSubscriptionLifecycle(previouslyConnected: reconnectingSameAccount)
        retryDelay = 1
        open()
    }

    func disconnect() {
        generation += 1
        credentials = nil
        subscribedTopics = []
        desiredTopics = []
        authenticated = false
        subscriptionLifecycle = RealtimeSubscriptionLifecycle()
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        reconnectTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        receiveTask = nil
        heartbeatTask = nil
        reconnectTask = nil
    }

    private func open() {
        guard let credentials, !Task.isCancelled else { return }
        generation += 1
        let revision = generation
        subscribedTopics = []
        authenticated = false
        subscriptionLifecycle.beginSocket()
        lastReceivedAt = Date()
        let task = session.webSocketTask(with: URL(string: "wss://rt.yapper.website/ws")!)
        socket = task
        task.resume()
        onStatus?("Verbindung wird hergestellt …")
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.send(["type": "auth", "token": credentials.accessToken], through: task)
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard self.generation == revision, !Task.isCancelled else { return }
                    let data: Data
                    switch message {
                    case let .data(bytes): data = bytes
                    case let .string(text): data = Data(text.utf8)
                    @unknown default: throw NativeClientError.invalidResponse
                    }
                    guard data.count < 1024 * 1024 else { throw NativeClientError.invalidResponse }
                    let envelope = try JSONDecoder().decode(RealtimeEnvelope.self, from: data)
                    self.lastReceivedAt = Date()
                    if envelope.type == "auth" {
                        guard envelope.ok == true else {
                            self.onStatus?("Live-Verbindung abgelehnt. Bitte Chats aktualisieren.")
                            self.disconnect()
                            return
                        }
                        self.authenticated = true
                        try await self.sendTopics(userID: credentials.userID, through: task)
                        guard self.generation == revision, !Task.isCancelled else { return }
                        self.retryDelay = 1
                        self.startHeartbeat(task, revision: revision)
                    } else if envelope.type == "subscribed" {
                        self.subscribedTopics = Set(envelope.approvedTopics ?? [])
                        let approved = self.subscribedTopics.contains("user:\(credentials.userID)")
                        self.onStatus?(approved ? "Verbunden" : "Live-Nachrichten nicht freigegeben. Bitte Chats manuell aktualisieren.")
                        if self.subscriptionLifecycle.acknowledge(userTopicApproved: approved) { self.onReconnect?() }
                    } else if envelope.type == "event", envelope.event == "message",
                              let topic = envelope.topic, self.subscribedTopics.contains(topic),
                              let payload = envelope.payload, payload.table == "messages" {
                        self.onMutation?(payload)
                    } else if envelope.type == "event", envelope.event == "typing", self.authenticated,
                              let payload = envelope.rawPayload,
                              let channel = payload["channel_id"].string, UUID(uuidString: channel) != nil,
                              let uid = payload["uid"].string, UUID(uuidString: uid) != nil {
                        self.onEvent?("typing", payload)
                    } else if envelope.type == "event", let event = envelope.event, let payload = envelope.rawPayload,
                              let topic = envelope.topic, self.subscribedTopics.contains(topic) {
                        self.onEvent?(event, payload)
                    } else if envelope.type == "revoked" {
                        self.onStatus?("Live-Zugriff geändert. Bitte Chats aktualisieren.")
                    }
                }
            } catch {
                guard self.generation == revision, !Task.isCancelled else { return }
                self.retry()
            }
        }
    }

    private func send(_ payload: [String: String], through socket: URLSessionWebSocketTask) async throws {
        let bytes = try JSONEncoder().encode(payload)
        guard let text = String(data: bytes, encoding: .utf8) else { throw NativeClientError.invalidResponse }
        try await socket.send(.string(text))
    }

    private func sendTopics(userID: String, through socket: URLSessionWebSocketTask) async throws {
        nonisolated struct Subscription: Encodable { let type: String; let topics: [String] }
        let topics = desiredTopics.union(["all", "user:\(userID)"])
        let removed = subscribedTopics.subtracting(topics)
        if !removed.isEmpty {
            let data = try JSONEncoder().encode(Subscription(type: "unsubscribe", topics: removed.sorted()))
            if let text = String(data: data, encoding: .utf8) { try await socket.send(.string(text)) }
            subscribedTopics.subtract(removed)
        }
        let bytes = try JSONEncoder().encode(Subscription(type: "subscribe", topics: topics.sorted()))
        guard let text = String(data: bytes, encoding: .utf8) else { throw NativeClientError.invalidResponse }
        try await socket.send(.string(text))
    }

    func observe(channelID: String?, serverID: String?) {
        let topics = Set([channelID.flatMap { UUID(uuidString: $0) == nil ? nil : "chan:\($0)" }, serverID.flatMap { UUID(uuidString: $0) == nil ? nil : "server:\($0)" }].compactMap { $0 })
        guard topics != desiredTopics else { return }
        desiredTopics = topics
        guard authenticated, let socket, let credentials else { return }
        let expected = generation
        Task { [weak self] in
            guard let self, self.generation == expected else { return }
            do { try await self.sendTopics(userID: credentials.userID, through: socket) }
            catch { if self.generation == expected { self.retry() } }
        }
    }

    func typing(channelID: String, recipients: [String]?) {
        guard authenticated, let socket else { return }
        var payload: [String: NativeJSON] = ["type": .string("typing"), "channel": .string(channelID)]
        if let recipients { payload["to"] = .array(recipients.map(NativeJSON.string)) }
        sendEvent(payload, through: socket)
    }

    func read(channelID: String) {
        guard authenticated, let socket else { return }
        sendEvent(["type": .string("read"), "channel": .string(channelID)], through: socket)
    }

    private func sendEvent(_ payload: [String: NativeJSON], through socket: URLSessionWebSocketTask) {
        let expected = generation
        Task { [weak self] in
            guard let self, self.generation == expected else { return }
            do {
                let data = try JSONEncoder().encode(NativeJSON.object(payload))
                guard let text = String(data: data, encoding: .utf8) else { return }
                try await socket.send(.string(text))
            } catch { if self.generation == expected { self.retry() } }
        }
    }

    private func startHeartbeat(_ socket: URLSessionWebSocketTask, revision: Int) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(25))
                    guard let self, self.generation == revision else { return }
                    if Date().timeIntervalSince(self.lastReceivedAt) > 75 { self.retry(); return }
                    try await self.send(["type": "ping"], through: socket)
                }
            } catch {
                guard let self, self.generation == revision, !Task.isCancelled else { return }
                self.retry()
            }
        }
    }

    private func retry() {
        guard credentials != nil else { return }
        generation += 1
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        onStatus?("Verbindung unterbrochen · erneuter Versuch …")
        let delay = retryDelay
        retryDelay = min(30, retryDelay * 2)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.open()
        }
    }
}
