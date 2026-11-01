import SwiftUI
import ImageIO

nonisolated struct NativeDecodedImage: Sendable {
    let image: UIImage
    let cost: Int
}

nonisolated enum NativeImageDecoder {
    /// ImageIO decodes native image pixels. Bound both frame count and decoded pixel memory.
    @concurrent static func decode(_ data: Data, maximumPixelSize: Int) async throws -> NativeDecodedImage {
        guard data.count <= 16 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw NativeClientError.invalidResponse }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw NativeClientError.invalidResponse }
        let sampledCount = min(count, 240)
        let memorySide = Int(sqrt(Double(8_000_000 / sampledCount)))
        let side = max(32, min(4096, maximumPixelSize, memorySide))
        let thumbnailOptions: CFDictionary = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        var frames: [UIImage] = []
        var delays: [Double] = []
        var cost = 0
        for frame in 0..<sampledCount {
            try Task.checkCancellation()
            let index = frame * count / sampledCount
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, thumbnailOptions) else { continue }
            frames.append(UIImage(cgImage: cg))
            cost += cg.bytesPerRow * cg.height
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
                ?? (png?[kCGImagePropertyAPNGDelayTime] as? Double) ?? 0.1
            delays.append(max(0.02, delay.isFinite ? min(delay, 60) : 0.1) * Double(count) / Double(sampledCount))
        }
        guard let first = frames.first else { throw NativeClientError.invalidResponse }
        guard frames.count > 1 else { return NativeDecodedImage(image: first, cost: cost) }
        let total = delays.reduce(0, +)
        let tick = max(0.01, total / 1000)
        var timedFrames: [UIImage] = []
        for (frame, delay) in zip(frames, delays) {
            timedFrames.append(contentsOf: repeatElement(frame, count: max(1, Int((delay / tick).rounded()))))
        }
        return NativeDecodedImage(image: UIImage.animatedImage(with: timedFrames, duration: total) ?? first, cost: cost)
    }
}

@MainActor private final class NativeImagePipeline {
    static let shared = NativeImagePipeline()
    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession
    private var tasks: [String: Task<NativeDecodedImage, any Error>] = [:]
    private var revision = 0

    private init() {
        cache.totalCostLimit = 48 * 1024 * 1024
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    func image(url: URL, maximumPixelSize: Int) async throws -> UIImage {
        let generation = revision
        guard url.scheme == "https", url.user == nil, url.password == nil, url.host != nil else { throw NativeClientError.invalidEndpoint }
        let key = url.absoluteString + "#native-image-\(maximumPixelSize)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let task: Task<NativeDecodedImage, any Error>
        if let running = tasks[key] { task = running }
        else {
            let session = self.session
            task = Task {
                let (file, response) = try await session.download(from: url)
                defer { try? FileManager.default.removeItem(at: file) }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024 else { throw NativeClientError.invalidResponse }
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                return try await NativeImageDecoder.decode(data, maximumPixelSize: maximumPixelSize)
            }
            tasks[key] = task
        }
        do {
            let decoded = try await task.value
            guard revision == generation else { throw CancellationError() }
            tasks[key] = nil
            cache.setObject(decoded.image, forKey: key as NSString, cost: decoded.cost)
            return decoded.image
        } catch { tasks[key] = nil; throw error }
    }

    func clear() {
        revision += 1
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); cache.removeAllObjects()
    }
}

private struct NativeAnimatedImageView: UIViewRepresentable {
    let image: UIImage
    let mode: ContentMode
    let animate: Bool

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.clipsToBounds = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        view.contentMode = mode == .fill ? .scaleAspectFill : .scaleAspectFit
        if animate {
            if view.image !== image { view.image = image }
            if image.images != nil && !view.isAnimating { view.startAnimating() }
        } else {
            view.stopAnimating()
            view.image = image.images?.first ?? image
        }
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: ()) { view.stopAnimating(); view.image = nil }
}

/// Native GIF/APNG/WebP/bitmap presentation; no HTML, WebKit, or JavaScript runtime.
struct NativeRemoteImage: View {
    let url: URL?
    var maximumPixelSize = 1024
    var mode: ContentMode = .fit
    var placeholder = "photo"
    @State private var image: UIImage?
    @State private var failed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    static func load(url: URL, maximumPixelSize: Int = 96) async throws -> UIImage {
        try await NativeImagePipeline.shared.image(url: url, maximumPixelSize: maximumPixelSize)
    }

    static func clearCache() { NativeImagePipeline.shared.clear() }

    var body: some View {
        Group {
            if let image {
                NativeAnimatedImageView(image: image, mode: mode, animate: !reduceMotion && scenePhase == .active)
                    .aspectRatio(image.size.width / max(1, image.size.height), contentMode: mode)
            } else if failed || url == nil {
                Image(systemName: placeholder).resizable().scaledToFit().foregroundStyle(YapperPalette.secondary).padding(12)
            } else { ProgressView().frame(minWidth: 24, minHeight: 24) }
        }
        .task(id: url?.absoluteString.appending("#\(maximumPixelSize)")) {
            image = nil; failed = false
            guard let url else { return }
            do {
                let loaded = try await NativeImagePipeline.shared.image(url: url, maximumPixelSize: maximumPixelSize)
                guard !Task.isCancelled else { return }
                image = loaded
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}
