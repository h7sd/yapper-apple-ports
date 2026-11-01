import Foundation

nonisolated struct NativeImageCrop: Codable, Hashable, Sendable {
    var x = 50.0
    var y = 50.0
    var zoom = 1.0
    var rotation = 0.0
    static let centered = NativeImageCrop()
    func translated(start: Self, dx: Double, dy: Double, width: Double, height: Double, imageWidth: Double, imageHeight: Double) -> Self {
        guard imageWidth > 0, imageHeight > 0, width > 0, height > 0 else { return self }
        let scale = max(width / imageWidth, height / imageHeight) * zoom
        let overflowX = imageWidth * scale - width, overflowY = imageHeight * scale - height
        let angle = -rotation * .pi / 180
        let rotatedX = dx * cos(angle) - dy * sin(angle), rotatedY = dx * sin(angle) + dy * cos(angle)
        return NativeImageCrop(x: overflowX > 0.5 ? min(100, max(0, start.x - rotatedX / overflowX * 100)) : 50,
                               y: overflowY > 0.5 ? min(100, max(0, start.y - rotatedY / overflowY * 100)) : 50,
                               zoom: zoom, rotation: rotation)
    }
}
