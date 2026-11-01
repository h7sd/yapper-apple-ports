import SwiftUI

private nonisolated final class NativeEmojiAttachment: NSTextAttachment {
    let emoji: NativeCustomEmoji

    init(emoji: NativeCustomEmoji, font: UIFont) {
        self.emoji = emoji
        super.init(data: nil, ofType: "website.yapper.native.emoji")
        bounds = CGRect(x: 0, y: font.descender, width: font.lineHeight, height: font.lineHeight)
        allowsTextAttachmentView = true
    }

    required init?(coder: NSCoder) { nil }
    override var usesTextAttachmentView: Bool { true }

    override func viewProvider(for parentView: UIView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        NativeEmojiAttachmentProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
    }
}

// TextKit's Objective-C base exposes nonisolated entrypoints. These private instances
// belong exclusively to the main-thread UITextView below; the bridge checks that
// invariant before every superclass callback, and all view state stays on MainActor.
@MainActor private final class NativeEmojiAttachmentProvider: NSTextAttachmentViewProvider {
    nonisolated override init(textAttachment: NSTextAttachment, parentView: UIView?, textLayoutManager: NSTextLayoutManager?, location: any NSTextLocation) {
        precondition(Thread.isMainThread, "Inline emoji providers belong to the main-thread native text view.")
        super.init(textAttachment: textAttachment, parentView: parentView, textLayoutManager: textLayoutManager, location: location)
    }

    nonisolated override func loadView() {
        precondition(Thread.isMainThread, "Inline emoji views are created on the main thread.")
        // UIKit's nonisolated Objective-C callback has already been checked above.
        // Limit the interoperability escape to this synchronous callback; the
        // provider itself deliberately remains non-Sendable.
        nonisolated(unsafe) let mainThreadProvider = self
        MainActor.assumeIsolated { mainThreadProvider.buildView() }
    }

    private func buildView() {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        view = imageView
        guard let attachment = textAttachment as? NativeEmojiAttachment else { return }
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = ":\(attachment.emoji.name):"
        guard let url = attachment.emoji.url else { return }
        Task { [weak self, weak imageView] in
            guard let image = try? await NativeRemoteImage.load(url: url, maximumPixelSize: 144), !Task.isCancelled, self != nil, let imageView else { return }
            imageView.image = UIAccessibility.isReduceMotionEnabled ? image.images?.first ?? image : image
            if !UIAccessibility.isReduceMotionEnabled { imageView.startAnimating() }
        }
    }
}

/// TextKit 2 provides real inline native views for animated custom emoji without a page renderer.
struct NativeMessageRichText: UIViewRepresentable {
    let text: String
    let emojis: [String: NativeCustomEmoji]
    var mentions: [NativeRenderedMention] = []
    var selectMention: ((NativeMentionTarget) -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.dataDetectorTypes = [.link]
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.selectMention = selectMention
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let mentionKey = mentions.map { $0.token.target.id + $0.label + String(describing: UIColor($0.color).resolvedColor(with: traits).cgColor.components) }.joined()
        let key = text + "#" + String(describing: dynamicTypeSize) + String(describing: colorScheme) + mentionKey + emojis.values.sorted { $0.id < $1.id }.map { $0.id + ($0.url?.absoluteString ?? "") }.joined()
        guard key != context.coordinator.key else { return }
        context.coordinator.key = key
        context.coordinator.mentionTargets = [:]
        // Protect wire tokens before Markdown interprets angle brackets as markup.
        let source = NSMutableString(string: text)
        let markers = mentions.map { ($0, "YAPPERMENTION" + UUID().uuidString.replacingOccurrences(of: "-", with: "")) }
        for (mention, marker) in markers.reversed() { source.replaceCharacters(in: mention.token.range, with: marker) }
        let font = OriginalYapper.uiFont(15)
        let attributed: NSMutableAttributedString
        if let markdown = try? AttributedString(markdown: source as String, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { attributed = NSMutableAttributedString(attributedString: NSAttributedString(markdown)) }
        else { attributed = NSMutableAttributedString(string: source as String) }
        let full = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes([.font: font, .foregroundColor: UIColor(YapperPalette.text)], range: full)
        attributed.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            guard let bits = (value as? NSNumber)?.uintValue else { return }
            let intent = InlinePresentationIntent(rawValue: bits)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            let styled: UIFont
            if intent.contains(.code) { styled = .monospacedSystemFont(ofSize: font.pointSize, weight: intent.contains(.stronglyEmphasized) ? .bold : .regular) }
            else if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { styled = UIFont(descriptor: descriptor, size: font.pointSize) }
            else { styled = font }
            attributed.addAttribute(.font, value: styled, range: range)
            if intent.contains(.strikethrough) { attributed.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        }
        for (mention, marker) in markers {
            let range = (attributed.string as NSString).range(of: marker)
            guard range.location != NSNotFound else { continue }
            let link = URL(string: "yapper-native-mention://open/" + UUID().uuidString)!
            context.coordinator.mentionTargets[link] = mention.token.target
            let replacement = NSAttributedString(string: mention.label, attributes: [
                .font: font, .foregroundColor: UIColor(mention.color),
                .backgroundColor: UIColor(mention.color.opacity(0.16)), .link: link,
            ])
            attributed.replaceCharacters(in: range, with: replacement)
        }
        for token in NativeEmojiTokens.matches(attributed.string).reversed() {
            if let emoji = emojis[token.id], emoji.url != nil {
                let attachment = NativeEmojiAttachment(emoji: emoji, font: font)
                attributed.replaceCharacters(in: token.range, with: NSAttributedString(attachment: attachment))
            } else { attributed.replaceCharacters(in: token.range, with: ":\(token.name):") }
        }
        view.attributedText = attributed
        view.linkTextAttributes = [.underlineStyle: 0]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var key = ""
        var mentionTargets: [URL: NativeMentionTarget] = [:]
        var selectMention: ((NativeMentionTarget) -> Void)?
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            if case let .link(url) = textItem.content {
                if let target = mentionTargets[url] { return UIAction { [weak self] _ in self?.selectMention?(target) } }
                return ["http", "https"].contains(url.scheme ?? "") && url.user == nil && url.password == nil ? defaultAction : nil
            }
            return nil
        }
    }
}

struct NativeMessageEmojiPicker: View {
    let store: NativeStore
    let select: @MainActor (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var emojis: [NativeCustomEmoji] = []
    @State private var query = ""
    @State private var busy = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 12)], spacing: 16) {
                    ForEach(emojis.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { emoji in
                        Button { select(emoji.token); dismiss() } label: {
                            VStack(spacing: 6) {
                                NativeRemoteImage(url: emoji.url, maximumPixelSize: 144).frame(width: 44, height: 44)
                                Text(emoji.name).font(OriginalYapper.font(11)).lineLimit(1).foregroundStyle(YapperPalette.secondary)
                            }.frame(minWidth: 60, minHeight: 70)
                        }.buttonStyle(.plain).accessibilityLabel(":\(emoji.name):")
                    }
                }.padding(20)
                if busy { ProgressView("Emojis werden geladen …") }
                if let error { Text(error).padding().foregroundStyle(YapperPalette.danger); Button("Erneut versuchen") { Task { await load() } }.frame(minHeight: 44) }
                if !busy && error == nil && emojis.isEmpty { ContentUnavailableView("Noch keine eigenen Emojis", systemImage: "face.smiling", description: Text("Hier erscheinen deine persönlichen Emojis und die deiner Server. Standard-Emojis kannst du mit der iPhone-Tastatur einfügen.")) }
            }
            .background(YapperPalette.background.ignoresSafeArea())
            .searchable(text: $query, prompt: "Emoji suchen")
            .navigationTitle("Eigene Emojis").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .task { await load() }
            .yapperNavigation()
        }
    }

    private func load() async {
        busy = true; error = nil
        defer { busy = false }
        do { emojis = try await store.withAuthenticatedSession { api, session in try await api.availableMessageEmojis(session: session) } }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
