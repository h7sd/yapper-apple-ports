import Foundation
import AVFoundation

nonisolated enum NativeMediaUploadPolicy {
    static let imageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
    static let attachmentTypes: Set<String> = imageTypes.union(["video/mp4", "video/webm", "video/quicktime", "audio/mpeg", "audio/ogg", "audio/wav", "audio/mp4", "audio/webm", "audio/x-m4a", "application/zip", "text/plain", "application/pdf"])

    static func validate(bucket: String, bytes: Int, contentType: String) throws {
        let caps = ["avatars": 8 * 1024 * 1024, "banners": 10 * 1024 * 1024, "icons": 8 * 1024 * 1024, "emojis": 1024 * 1024, "attachments": 10 * 1024 * 1024]
        guard let cap = caps[bucket], bytes > 0 else { throw NativeClientError.invalidResponse }
        guard bytes <= cap else { throw NativeClientError.api(status: 413, message: "Die Datei ist zu groß (maximal \(cap / 1024 / 1024) MB).") }
        let types = bucket == "attachments" ? attachmentTypes : imageTypes
        guard types.contains(contentType) else { throw NativeClientError.api(status: 400, message: "Dieses Dateiformat wird von Yapper nicht unterstützt.") }
    }

    static func suffix(filename: String, contentType: String) -> String {
        let map = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "video/mp4": "mp4", "video/webm": "webm", "video/quicktime": "mov", "audio/mpeg": "mp3", "audio/ogg": "ogg", "audio/wav": "wav", "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/webm": "weba", "application/pdf": "pdf", "application/zip": "zip", "text/plain": "txt"]
        return map[contentType] ?? "bin"
    }

    static func signedDestination(_ url: URL) -> Bool {
        guard url.scheme == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil,
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        // The URL is issued by Yapper's authenticated upload API. No account bearer, cookies,
        // API key or browser credentials are copied to this separate upload connection.
        return host == "files.yapper.website" || host.hasSuffix(".r2.cloudflarestorage.com") || host.hasSuffix(".r2.dev")
    }

    static func voiceWave(_ levels: [Double]) -> String {
        guard !levels.isEmpty, levels.allSatisfy(\.isFinite) else { return "" }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let count = min(64, levels.count)
        let peaks = (0..<count).map { index in
            let start = index * levels.count / count
            let end = max(start + 1, (index + 1) * levels.count / count)
            return levels[start..<end].max() ?? 0
        }
        let maximum = peaks.max().flatMap { $0 > 0 ? $0 : nil } ?? 1
        return String(peaks.map { alphabet[min(63, max(0, Int((63 * sqrt(max(0, $0) / maximum)).rounded())))] })
    }
}

extension NativeAPI {
    /// Private proof storage follows the official client's proofs exception, not public media/CDN.
    /// Raw-data upload is the documented Supabase Storage protocol (storage-js StorageFileApi).
    func uploadProofImage(data: Data, contentType: String, session: NativeSession) async throws -> String {
        guard NativeMediaUploadPolicy.imageTypes.contains(contentType), !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw NativeClientError.invalidResponse }
        let path = "\(session.userID)/\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6).lowercased()).\(NativeMediaUploadPolicy.suffix(filename: "proof", contentType: contentType))"
        var upload = try request(path: "storage/v1/object/proofs/" + path, method: "POST", token: session.accessToken, body: data)
        upload.setValue(contentType, forHTTPHeaderField: "Content-Type")
        upload.setValue("max-age=31536000", forHTTPHeaderField: "cache-control")
        upload.setValue("false", forHTTPHeaderField: "x-upsert")
        let response = try await dataResponse(request: upload)
        let result = try JSONDecoder().decode(NativeJSON.self, from: response)
        guard result["Key"].string == "proofs/" + path else { throw NativeClientError.invalidResponse }
        return path
    }

    /// Observed official media flow: signed upload, then mandatory service-side scan.
    /// A message/profile must not reference the path until this method returns successfully.
    func uploadMedia(bucket: String, data: Data, filename: String, contentType: String, serverID: String? = nil, objectID: String? = nil, purpose: String? = nil, session: NativeSession, uploadTransport: (@MainActor (URLRequest) async throws -> HTTPURLResponse)? = nil) async throws -> String {
        try NativeMediaUploadPolicy.validate(bucket: bucket, bytes: data.count, contentType: contentType)
        if let objectID { guard UUID(uuidString: objectID) != nil else { throw NativeClientError.invalidResponse } }
        if let purpose { guard purpose == "event", bucket == "banners", objectID == nil else { throw NativeClientError.invalidResponse } }
        let voice = filename.hasPrefix("voice-message") && contentType.hasPrefix("audio/")
        if contentType.hasPrefix("audio/") {
            let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(NativeMediaUploadPolicy.suffix(filename: filename, contentType: contentType))
            try data.write(to: local, options: .atomic)
            defer { try? FileManager.default.removeItem(at: local) }
            let duration = try await AVURLAsset(url: local).load(.duration).seconds
            guard duration.isFinite, duration > 0, duration <= (voice ? 305 : 60) else {
                throw NativeClientError.api(status: 400, message: voice ? "Sprachnachrichten dürfen höchstens 5 Minuten lang sein." : "Audioclips dürfen höchstens 1 Minute lang sein.")
            }
        }
        let objectPrefix = (objectID ?? purpose).map { $0 + "-" } ?? ""
        let path = "\(session.userID)/r2-\(objectPrefix)\(voice ? "voice-" : "")\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6).lowercased()).\(NativeMediaUploadPolicy.suffix(filename: filename, contentType: contentType))"
        var body: [String: NativeJSON] = ["bucket": .string(bucket), "path": .string(path), "type": .string(contentType), "size": .number(Double(data.count))]
        if let serverID { body["serverId"] = .string(serverID) }
        let signed = try await webAPI(path: "api/media/upload-url", method: "POST", body: .object(body), session: session)
        guard let rawURL = signed["url"].string, let destination = URL(string: rawURL), NativeMediaUploadPolicy.signedDestination(destination) else { throw NativeClientError.invalidEndpoint }
        var put = URLRequest(url: destination)
        put.httpMethod = "PUT"; put.httpBody = data
        for (key, value) in signed["headers"].object ?? [:] {
            let lower = key.lowercased()
            if let value = value.string, lower.hasPrefix("x-amz-") || ["content-type", "cache-control", "if-none-match"].contains(lower) {
                put.setValue(value, forHTTPHeaderField: key)
            }
        }
        put.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 90
        let connection = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        defer { connection.invalidateAndCancel() }
        let response: HTTPURLResponse
        if let uploadTransport { response = try await uploadTransport(put) }
        else {
            let (_, rawResponse) = try await connection.data(for: put)
            guard let http = rawResponse as? HTTPURLResponse else { throw NativeClientError.invalidResponse }
            response = http
        }
        guard response.url == destination,
              (200...299).contains(response.statusCode) || response.statusCode == 412 else {
            throw NativeClientError.api(status: response.statusCode, message: "Die Datei konnte nicht hochgeladen werden. Bitte erneut versuchen.")
        }
        do {
            var scanBody: [String: NativeJSON] = ["bucket": .string(bucket), "path": .string(path)]
            if let serverID { scanBody["serverId"] = .string(serverID) }
            var lastError: (any Error) = NativeClientError.invalidResponse
            for attempt in 0..<3 {
                try Task.checkCancellation()
                if attempt > 0 { try await Task.sleep(for: .milliseconds(1500 * attempt)) }
                do {
                    let result = try await webAPI(path: "api/media/scan", method: "POST", body: .object(scanBody), session: session)
                    if result["verdict"].string == "ok" { return path }
                    if result["verdict"].string == "blocked" {
                        throw NativeClientError.api(status: 403, message: result["error"].string ?? "Yapper hat diese Datei nach der Prüfung abgelehnt. Sie wurde nicht geteilt.")
                    }
                    lastError = NativeClientError.api(status: 503, message: result["error"].string ?? "Die Dateiprüfung konnte noch nicht abgeschlossen werden. Bitte erneut versuchen.")
                } catch let error as NativeClientError {
                    if case let .api(status, _) = error, status == 400 || status == 401 || status == 403 || status == 429 { throw error }
                    lastError = error
                }
            }
            throw lastError
        } catch {
            _ = try? await webAPI(path: "api/media/remove", method: "POST", body: .object(["bucket": .string(bucket), "path": .string(path)]), session: session)
            throw error
        }
    }

    func sendAttachment(id: String, text: String, data: Data, filename: String, contentType: String, channelID: String, replyToID: String?, session: NativeSession, voiceSeconds: Double? = nil, waveform: [Double] = [], messagePolicy: NativeMessagePolicy = .standard) async throws {
        try messagePolicy.validate(text, for: session.userID)
        guard UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
        let identityQuery = [URLQueryItem(name: "id", value: "eq.\(id)"), URLQueryItem(name: "channel_id", value: "eq.\(channelID)"), URLQueryItem(name: "author_id", value: "eq.\(session.userID)"), URLQueryItem(name: "select", value: "id")]
        if try await table("messages", query: identityQuery, session: session).rows.contains(where: { $0["id"].string == id }) { return }
        let path = try await uploadMedia(bucket: "attachments", data: data, filename: filename, contentType: contentType, session: session)
        var values: [String: NativeJSON] = ["id": .string(id), "channel_id": .string(channelID), "author_id": .string(session.userID), "content": .string(text.trimmingCharacters(in: .whitespacesAndNewlines)), "attachment_path": .string(path), "attachment_name": .string(String(filename.prefix(200))), "attachment_size": .number(Double(data.count))]
        if let voiceSeconds {
            guard voiceSeconds.isFinite, voiceSeconds > 0, voiceSeconds <= 305, waveform.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw NativeClientError.invalidResponse }
            values["voice_secs"] = .number(voiceSeconds)
            values["voice_wave"] = .string(NativeMediaUploadPolicy.voiceWave(waveform))
        }
        if let replyToID { values["reply_to_id"] = .string(replyToID) }
        do {
            let result = try await table("messages", query: [URLQueryItem(name: "select", value: "id")], method: "POST", values: .object(values), session: session, prefer: "return=representation")
            guard result.rows.contains(where: { $0["id"].string == id }) else { throw NativeClientError.invalidResponse }
        } catch let NativeClientError.api(status, _) where status == 409 {
            guard try await table("messages", query: identityQuery, session: session).rows.contains(where: { $0["id"].string == id }) else { throw NativeClientError.invalidResponse }
            _ = try? await webAPI(path: "api/media/remove", method: "POST", body: .object(["bucket": .string("attachments"), "path": .string(path)]), session: session)
        }
    }
}
