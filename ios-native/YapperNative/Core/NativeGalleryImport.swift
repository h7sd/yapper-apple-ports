import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct NativeGalleryAttachment: Sendable {
    let data: Data
    let filename: String
    let contentType: String
}

nonisolated struct NativeGalleryRepresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case image, video }
    let typeIdentifier: String
    let kind: Kind
}

/// An app-owned file, copied before NSItemProvider invalidates its temporary URL.
nonisolated struct NativeGalleryFile: Sendable {
    let url: URL
    let directory: URL
    let representation: NativeGalleryRepresentation
    let sourceTypeIdentifier: String?
    let suggestedFilename: String

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

nonisolated enum NativeGalleryImport {
    // This is the existing attachments policy, including videos. No gallery-specific upload path.
    static let maximumBytes = 10 * 1024 * 1024
    private static let chunkBytes = 64 * 1024
    private static let maximumImageDimension = 4096

    static func representation(for identifiers: [String], prefersStill: Bool = false) -> NativeGalleryRepresentation? {
        let types = identifiers.compactMap(UTType.init)
        let stills = types.filter { $0.conforms(to: .image) && !$0.conforms(to: .livePhoto) }
        // A Live Photo is attached as its still, never as the paired motion resource or a bundle.
        if prefersStill || types.contains(where: { $0.conforms(to: .livePhoto) }) {
            return NativeGalleryRepresentation(typeIdentifier: stills.first?.identifier ?? UTType.image.identifier, kind: .image)
        }
        if let movie = types.first(where: { $0.conforms(to: .movie) }) {
            return NativeGalleryRepresentation(typeIdentifier: movie.identifier, kind: .video)
        }
        if let still = stills.first { return NativeGalleryRepresentation(typeIdentifier: still.identifier, kind: .image) }
        return nil
    }

    /// Called synchronously inside the provider callback; its URL is valid only until that returns.
    /// Size is checked before copying and again while streaming in case the source changes.
    static func copyFile(from sourceURL: URL, representation: NativeGalleryRepresentation, suggestedFilename: String?) throws -> NativeGalleryFile {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        let resource = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentTypeKey])
        guard resource.isRegularFile != false else { throw invalidMedia }
        if let size = resource.fileSize { try validateSize(size) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yapper-gallery-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let fileURL = directory.appendingPathComponent("original").appendingPathExtension(sourceURL.pathExtension)
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else { throw invalidMedia }
            let source = try FileHandle(forReadingFrom: sourceURL)
            defer { try? source.close() }
            let destination = try FileHandle(forWritingTo: fileURL)
            defer { try? destination.close() }
            var count = 0
            while let chunk = try source.read(upToCount: chunkBytes), !chunk.isEmpty {
                count += chunk.count
                try validateSize(count)
                try destination.write(contentsOf: chunk)
            }
            try validateSize(count)
            let sourceType = resource.contentType.flatMap { $0 == .data || $0 == .item ? nil : $0.identifier }
            return NativeGalleryFile(url: fileURL, directory: directory, representation: representation,
                                     sourceTypeIdentifier: sourceType,
                                     suggestedFilename: suggestedFilename ?? sourceURL.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Image decoding and file reads run away from the UI actor. Every exit removes the owned copy.
    @concurrent static func attachment(from file: NativeGalleryFile) async throws -> NativeGalleryAttachment {
        defer { file.remove() }
        try Task.checkCancellation()
        let attachment: NativeGalleryAttachment
        switch file.representation.kind {
        case .image: attachment = try imageAttachment(from: file)
        case .video:
            let types = [file.sourceTypeIdentifier.flatMap(UTType.init), UTType(filenameExtension: file.url.pathExtension), UTType(file.representation.typeIdentifier)]
            guard let contentType = types.compactMap({ $0?.preferredMIMEType }).first,
                  contentType.hasPrefix("video/"), NativeMediaUploadPolicy.attachmentTypes.contains(contentType) else {
                throw unsupportedMedia
            }
            let data = try boundedData(from: file.url)
            attachment = NativeGalleryAttachment(data: data, filename: filename(file.suggestedFilename, contentType: contentType), contentType: contentType)
        }
        try Task.checkCancellation()
        try NativeMediaUploadPolicy.validate(bucket: "attachments", bytes: attachment.data.count, contentType: attachment.contentType)
        return attachment
    }

    private static func imageAttachment(from file: NativeGalleryFile) throws -> NativeGalleryAttachment {
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String) else { throw invalidMedia }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if let contentType = type.preferredMIMEType, NativeMediaUploadPolicy.imageTypes.contains(contentType),
           orientation == 1 || CGImageSourceGetCount(source) > 1 {
            // Preserve GIF/WebP animation and supported originals without recompressing them.
            return NativeGalleryAttachment(data: try boundedData(from: file.url),
                                           filename: filename(file.suggestedFilename, contentType: contentType), contentType: contentType)
        }
        try Task.checkCancellation()
        // Transform EXIF orientation into pixels. Bounding dimensions also bounds HEIC/RAW decode memory.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                       kCGImageSourceThumbnailMaxPixelSize: maximumImageDimension,
                                       kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw invalidMedia }
        let output = file.directory.appendingPathComponent("converted.jpg")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw invalidMedia }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85,
                                                       kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw invalidMedia }
        return NativeGalleryAttachment(data: try boundedData(from: output),
                                       filename: filename(file.suggestedFilename, contentType: "image/jpeg"), contentType: "image/jpeg")
    }

    private static func boundedData(from url: URL) throws -> Data {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize { try validateSize(size) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            try Task.checkCancellation()
            try validateSize(result.count + chunk.count)
            result.append(chunk)
        }
        try validateSize(result.count)
        return result
    }

    private static func validateSize(_ bytes: Int) throws {
        guard bytes > 0 else { throw invalidMedia }
        guard bytes <= maximumBytes else {
            throw NativeClientError.api(status: 413, message: "Das Foto oder Video ist zu groß. Yapper erlaubt Anhänge bis 10 MB. Kürze das Video oder wähle eine kleinere Datei.")
        }
    }

    private static func filename(_ suggested: String, contentType: String) -> String {
        let cleaned = suggested.components(separatedBy: .controlCharacters).joined(separator: " ")
        let name = ((cleaned as NSString).lastPathComponent as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = name.isEmpty ? (contentType.hasPrefix("video/") ? "Video" : "Foto") : name
        return base + "." + NativeMediaUploadPolicy.suffix(filename: base, contentType: contentType)
    }

    private static var invalidMedia: NativeClientError {
        .api(status: 400, message: "Dieses Foto oder Video konnte nicht gelesen werden. Lade es gegebenenfalls zuerst aus iCloud und wähle es erneut aus.")
    }
    private static var unsupportedMedia: NativeClientError {
        .api(status: 400, message: "Dieses Videoformat wird von Yapper nicht unterstützt. Wähle ein MP4-, MOV- oder WebM-Video.")
    }
}
