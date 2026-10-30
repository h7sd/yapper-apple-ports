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
    private var lastReceivedAt = Date()
    private var hasConnected = false
    var onMutation: (@MainActor (RealtimeMutation) -> Void)?
    var onStatus: (@MainActor (String) -> Void)?
    var onReconnect: (@MainActor () -> Void)?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }

    func connect(session credentials: NativeSession) {
        let reconnectingSameAccount = self.credentials?.userID == credentials.userID && hasConnected
        disconnect()
        self.credentials = credentials
        hasConnected = reconnectingSameAccount
        retryDelay = 1
        open()
    }

    func disconnect() {
        generation += 1
        credentials = nil
        subscribedTopics = []
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
                        try await self.sendTopics(userID: credentials.userID, through: task)
                        guard self.generation == revision, !Task.isCancelled else { return }
                        self.retryDelay = 1
                        self.startHeartbeat(task, revision: revision)
                    } else if envelope.type == "subscribed" {
                        self.subscribedTopics = Set(envelope.approvedTopics ?? [])
                        let approved = self.subscribedTopics.contains("user:\(credentials.userID)")
                        self.onStatus?(approved ? "Verbunden" : "Live-Nachrichten nicht freigegeben. Bitte Chats manuell aktualisieren.")
                        if approved {
                            if self.hasConnected { self.onReconnect?() }
                            self.hasConnected = true
                        }
                    } else if envelope.type == "event", envelope.event == "message",
                              envelope.topic == "user:\(credentials.userID)" || envelope.topic == "all",
                              let topic = envelope.topic, self.subscribedTopics.contains(topic),
                              let payload = envelope.payload, payload.table == "messages" {
                        self.onMutation?(payload)
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
        let bytes = try JSONEncoder().encode(Subscription(type: "subscribe", topics: ["all", "user:\(userID)"]))
        guard let text = String(data: bytes, encoding: .utf8) else { throw NativeClientError.invalidResponse }
        try await socket.send(.string(text))
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
