import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import YapperNative

@MainActor @Suite struct NativeGalleryImportTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func image(at url: URL, type: UTType, orientation: Int = 1) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 32), format: format)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
        }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(image.cgImage), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func `Photos representations include images and movies while Live Photos select a still`() {
        #expect(NativeGalleryImport.representation(for: [UTType.jpeg.identifier]) == NativeGalleryRepresentation(typeIdentifier: UTType.jpeg.identifier, kind: .image))
        #expect(NativeGalleryImport.representation(for: [UTType.quickTimeMovie.identifier]) == NativeGalleryRepresentation(typeIdentifier: UTType.quickTimeMovie.identifier, kind: .video))
        #expect(NativeGalleryImport.representation(for: [UTType.livePhoto.identifier, UTType.quickTimeMovie.identifier, UTType.heic.identifier]) == NativeGalleryRepresentation(typeIdentifier: UTType.heic.identifier, kind: .image))
        #expect(NativeGalleryImport.representation(for: [UTType.quickTimeMovie.identifier], prefersStill: true)?.kind == .image)
        #expect(NativeGalleryImport.representation(for: [UTType.pdf.identifier]) == nil)
    }

    @Test func `Oversized gallery files fail before copying and use the existing upload limit`() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("large.mov")
        #expect(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(NativeGalleryImport.maximumBytes + 1))
        let representation = NativeGalleryRepresentation(typeIdentifier: UTType.quickTimeMovie.identifier, kind: .video)
        do {
            _ = try NativeGalleryImport.copyFile(from: source, representation: representation, suggestedFilename: nil)
            Issue.record("An oversized video should not become an attachment.")
        } catch let error as NativeClientError {
            guard case .api(let status, let message) = error else { Issue.record("Expected a useful media policy error."); return }
            #expect(status == 413)
            #expect(message.contains("10 MB"))
            #expect(message.contains("Video"))
        }
        try NativeMediaUploadPolicy.validate(bucket: "attachments", bytes: NativeGalleryImport.maximumBytes, contentType: "video/quicktime")
        #expect(throws: (any Error).self) {
            try NativeMediaUploadPolicy.validate(bucket: "attachments", bytes: NativeGalleryImport.maximumBytes + 1, contentType: "video/quicktime")
        }
    }

    @Test func `Empty media and directories do not become gallery attachments`() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = directory.appendingPathComponent("empty.mp4")
        #expect(FileManager.default.createFile(atPath: empty.path, contents: nil))
        let representation = NativeGalleryRepresentation(typeIdentifier: UTType.mpeg4Movie.identifier, kind: .video)
        #expect(throws: (any Error).self) { try NativeGalleryImport.copyFile(from: empty, representation: representation, suggestedFilename: nil) }
        #expect(throws: (any Error).self) { try NativeGalleryImport.copyFile(from: directory, representation: representation, suggestedFilename: nil) }
    }

    @Test(arguments: [("mov", "video/quicktime"), ("mp4", "video/mp4")])
    func `Movie files retain container MIME even when the provider advertises generic movie`(suffix: String, contentType: String) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("clip").appendingPathExtension(suffix)
        let bytes = Data("synthetic movie representation".utf8)
        try bytes.write(to: source)
        let copied = try NativeGalleryImport.copyFile(from: source, representation: NativeGalleryRepresentation(typeIdentifier: UTType.movie.identifier, kind: .video), suggestedFilename: "Holiday")
        try FileManager.default.removeItem(at: source)
        let attachment = try await NativeGalleryImport.attachment(from: copied)
        #expect(attachment.data == bytes)
        #expect(attachment.contentType == contentType)
        #expect(attachment.filename == "Holiday." + suffix)
        #expect(!FileManager.default.fileExists(atPath: copied.directory.path))
    }

    @Test func `HEIC stills become supported JPEGs with orientation baked into the pixels`() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("camera.HEIC")
        try image(at: source, type: .heic, orientation: 6)
        let copied = try NativeGalleryImport.copyFile(from: source, representation: NativeGalleryRepresentation(typeIdentifier: UTType.heic.identifier, kind: .image), suggestedFilename: "camera.HEIC")
        let attachment = try await NativeGalleryImport.attachment(from: copied)
        #expect(attachment.contentType == "image/jpeg")
        #expect(attachment.filename == "camera.jpg")
        let decoded = try #require(CGImageSourceCreateWithData(attachment.data as CFData, nil))
        #expect(CGImageSourceGetType(decoded) as String? == UTType.jpeg.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
        let pixels = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        #expect(pixels.width == 32)
        #expect(pixels.height == 64)
        #expect(!FileManager.default.fileExists(atPath: copied.directory.path))
    }

    @Test func `JPEG EXIF rotation is normalized instead of losing its visible orientation`() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("rotated.jpg")
        try image(at: source, type: .jpeg, orientation: 8)
        let copied = try NativeGalleryImport.copyFile(from: source, representation: NativeGalleryRepresentation(typeIdentifier: UTType.jpeg.identifier, kind: .image), suggestedFilename: nil)
        let attachment = try await NativeGalleryImport.attachment(from: copied)
        let decoded = try #require(CGImageSourceCreateWithData(attachment.data as CFData, nil))
        let pixels = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        #expect(pixels.width == 32)
        #expect(pixels.height == 64)
    }

    @Test func `Animated GIF bytes survive the native gallery import`() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("animated.gif")
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.gif.identifier as CFString, 2, nil))
        for color in [UIColor.red, UIColor.blue] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
            CGImageDestinationAddImage(destination, try #require(image.cgImage), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: source)
        let copied = try NativeGalleryImport.copyFile(from: source, representation: NativeGalleryRepresentation(typeIdentifier: UTType.gif.identifier, kind: .image), suggestedFilename: "animated.gif")
        let attachment = try await NativeGalleryImport.attachment(from: copied)
        #expect(attachment.contentType == "image/gif")
        #expect(attachment.data == original)
        let decoded = try #require(CGImageSourceCreateWithData(attachment.data as CFData, nil))
        #expect(CGImageSourceGetCount(decoded) == 2)
    }

    @Test func `Cancellation discards the owned gallery file without producing an attachment`() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("clip.mov")
        try Data("synthetic movie representation".utf8).write(to: source)
        let copied = try NativeGalleryImport.copyFile(from: source, representation: NativeGalleryRepresentation(typeIdentifier: UTType.quickTimeMovie.identifier, kind: .video), suggestedFilename: nil)
        let task = Task { try await NativeGalleryImport.attachment(from: copied) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: copied.directory.path))
    }

    @Test func `Unreadable image failures remove their temporary copy`() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("broken.jpg")
        try Data([1, 2, 3]).write(to: source)
        let copied = try NativeGalleryImport.copyFile(from: source, representation: NativeGalleryRepresentation(typeIdentifier: UTType.jpeg.identifier, kind: .image), suggestedFilename: nil)
        await #expect(throws: NativeClientError.self) { try await NativeGalleryImport.attachment(from: copied) }
        #expect(!FileManager.default.fileExists(atPath: copied.directory.path))
    }
}
