import SwiftUI

/// Native counterpart of module90581: cover, object-position, then rotate/translate/zoom.
/// The caller chooses the viewport and its final shape, so avatars and banners share geometry.
struct NativeCroppedImage: View {
    let url: URL?
    var data: Data? = nil
    var crop: NativeImageCrop = .centered
    var maximumPixelSize = 1024
    var placeholder = "photo"
    var onImageSize: (@MainActor (CGSize) -> Void)? = nil
    @State private var image: UIImage?
    @State private var failed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private struct Source: Hashable { let url: URL?; let data: Data?; let maximumPixelSize: Int }

    var body: some View {
        Group {
            if let image { NativeCropImageView(image: image, crop: crop, animate: !reduceMotion && scenePhase == .active) }
            else if failed || (url == nil && data == nil) { Image(systemName: placeholder).resizable().scaledToFit().foregroundStyle(YapperPalette.secondary).padding(12) }
            else { ProgressView().frame(minWidth: 24, minHeight: 24) }
        }
        .task(id: Source(url: url, data: data, maximumPixelSize: maximumPixelSize)) {
            image = nil; failed = false
            do {
                let loaded: UIImage
                if let data { loaded = try await NativeImageDecoder.decode(data, maximumPixelSize: maximumPixelSize).image }
                else if let url { loaded = try await NativeRemoteImage.load(url: url, maximumPixelSize: maximumPixelSize) }
                else { return }
                try Task.checkCancellation()
                image = loaded; onImageSize?(loaded.size)
            } catch is CancellationError {} catch { failed = true }
        }
    }
}

private struct NativeCropImageView: UIViewRepresentable {
    let image: UIImage
    let crop: NativeImageCrop
    let animate: Bool
    func makeUIView(context: Context) -> NativeCropImageContainer { NativeCropImageContainer() }
    func updateUIView(_ view: NativeCropImageContainer, context: Context) { view.display(image: image, crop: crop, animate: animate) }
    static func dismantleUIView(_ view: NativeCropImageContainer, coordinator: ()) { view.clear() }
}

private final class NativeCropImageContainer: UIView {
    private let transformed = UIView()
    private let imageView = UIImageView()
    private var crop = NativeImageCrop.centered
    private var naturalSize = CGSize(width: 1, height: 1)

    init() {
        super.init(frame: .zero)
        clipsToBounds = true; transformed.clipsToBounds = true
        imageView.contentMode = .scaleToFill
        addSubview(transformed); transformed.addSubview(imageView)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func display(image: UIImage, crop: NativeImageCrop, animate: Bool) {
        self.crop = crop; naturalSize = image.size
        if animate {
            if imageView.image !== image { imageView.image = image }
            if image.images != nil && !imageView.isAnimating { imageView.startAnimating() }
        } else { imageView.stopAnimating(); imageView.image = image.images?.first ?? image }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        transformed.transform = .identity; transformed.frame = bounds
        let cover = max(bounds.width / max(1, naturalSize.width), bounds.height / max(1, naturalSize.height))
        let width = naturalSize.width * cover, height = naturalSize.height * cover
        imageView.frame = CGRect(x: (bounds.width - width) * crop.x / 100, y: (bounds.height - height) * crop.y / 100, width: width, height: height)
        transformed.transform = CGAffineTransform(rotationAngle: crop.rotation * .pi / 180)
            .translatedBy(x: (1 - crop.zoom) * (crop.x - 50) / 100 * bounds.width, y: (1 - crop.zoom) * (crop.y - 50) / 100 * bounds.height)
            .scaledBy(x: crop.zoom, y: crop.zoom)
    }
    func clear() { imageView.stopAnimating(); imageView.image = nil }
}

struct NativeProfileCropEditor: View {
    let url: URL?
    let data: Data?
    let isAvatar: Bool
    let onApply: @MainActor (NativeImageCrop) -> Void
    @State private var crop: NativeImageCrop
    @State private var imageSize = CGSize.zero
    @State private var dragStart: NativeImageCrop?
    @State private var pinchStart: Double?
    @Environment(\.dismiss) private var dismiss

    init(url: URL?, data: Data?, isAvatar: Bool, initial: NativeImageCrop, onApply: @escaping @MainActor (NativeImageCrop) -> Void) {
        self.url = url; self.data = data; self.isAvatar = isAvatar; self.onApply = onApply
        _crop = State(initialValue: initial)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                GeometryReader { geometry in
                    let width = geometry.size.width, height = geometry.size.height
                    NativeCroppedImage(url: url, data: data, crop: crop, maximumPixelSize: 1_024, onImageSize: { imageSize = $0 })
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: isAvatar ? width / 2 : 12))
                        .overlay { RoundedRectangle(cornerRadius: isAvatar ? width / 2 : 12).strokeBorder(YapperPalette.secondary.opacity(0.5), lineWidth: 1) }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if dragStart == nil { dragStart = crop }
                            crop = crop.translated(start: dragStart ?? crop, dx: value.translation.width, dy: value.translation.height, width: width, height: height, imageWidth: imageSize.width, imageHeight: imageSize.height)
                        }.onEnded { _ in dragStart = nil })
                        .simultaneousGesture(MagnifyGesture().onChanged { value in
                            if pinchStart == nil { pinchStart = crop.zoom }
                            crop.zoom = min(3, max(1, (pinchStart ?? crop.zoom) * value.magnification))
                        }.onEnded { _ in pinchStart = nil })
                        .accessibilityLabel(isAvatar ? "Profilbild-Vorschau" : "Banner-Vorschau")
                }
                .aspectRatio(isAvatar ? 1 : 3, contentMode: .fit)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Verschiebe das Bild mit einem Finger. Mit zwei Fingern kannst du zoomen.").font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary)
                    LabeledContent("Zoom", value: crop.zoom.formatted(.number.precision(.fractionLength(2))) + "×")
                    Slider(value: $crop.zoom, in: 1...max(3, crop.zoom), step: 0.01).accessibilityLabel("Zoom")
                    Text("Horizontale Position").font(OriginalYapper.font(14))
                    Slider(value: $crop.x, in: 0...100, step: 0.1).accessibilityLabel("Horizontale Position")
                    Text("Vertikale Position").font(OriginalYapper.font(14))
                    Slider(value: $crop.y, in: 0...100, step: 0.1).accessibilityLabel("Vertikale Position")
                    if isAvatar {
                        Button("Um 90° drehen", systemImage: "rotate.right") { crop.rotation = (crop.rotation + 90).truncatingRemainder(dividingBy: 360) }.frame(minHeight: 44)
                    }
                    Button("Zurücksetzen", systemImage: "arrow.counterclockwise") { crop = .centered }.frame(minHeight: 44)
                }
            }
            .padding(20)
        }
        .background(YapperPalette.background.ignoresSafeArea())
        .navigationTitle(isAvatar ? "Profilbild zuschneiden" : "Banner zuschneiden")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Übernehmen") { onApply(crop); dismiss() }.disabled(imageSize == .zero).accessibilityIdentifier("native.profile.crop.apply") }
        }
        .yapperNavigation()
    }
}
