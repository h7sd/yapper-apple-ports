import SwiftUI
import UIKit
import CoreText

/// Literal visual primitives from the shipped frontend. CSS pixels map to points at default text size.
/// Source hashes and cascade contexts are retained in docs/ORIGINAL-UI-SPEC.json.
enum OriginalYapper {
    static func registerFonts() {
        guard let url = resource("Inter-Latin-Variable", extension: "ttf", subdirectory: "Fonts") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func resource(_ name: String, extension ext: String, subdirectory: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "OriginalAssets/" + subdirectory)
            ?? Bundle.main.url(forResource: name, withExtension: ext)
    }

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let value: CGFloat
        switch weight {
        case .ultraLight: value = 100
        case .thin: value = 200
        case .light: value = 300
        case .medium: value = 500
        case .semibold: value = 600
        case .bold: value = 700
        case .heavy: value = 800
        case .black: value = 900
        default: value = 400
        }
        return font(size, numericWeight: value)
    }

    static func font(_ size: CGFloat, numericWeight: CGFloat) -> Font {
        Font(uiFont(size, numericWeight: numericWeight))
    }

    static func fixedFont(_ size: CGFloat, numericWeight: CGFloat = 400) -> Font {
        Font(uiFont(size, numericWeight: numericWeight, scaled: false))
    }

    static func uiFont(_ size: CGFloat, numericWeight: CGFloat = 400, scaled: Bool = true) -> UIFont {
        // Inter's wght axis is 'wght' (2003265652). Source author labels use 650.
        let descriptor = UIFontDescriptor(name: "Inter-Regular", size: size).addingAttributes([
            .init(rawValue: kCTFontVariationAttribute as String): [NSNumber(value: 0x77676874): NSNumber(value: Double(numericWeight))],
            .featureSettings: ["cv11", "ss01", "calt"].map { tag in
                [kCTFontOpenTypeFeatureTag as String: tag, kCTFontOpenTypeFeatureValue as String: 1] as [String: Any]
            }
        ])
        let base = UIFont(descriptor: descriptor, size: size)
        return scaled ? UIFontMetrics(forTextStyle: .body).scaledFont(for: base) : base
    }
}

/// Native paths copied from the original icon module, not approximations with system symbols.
struct OriginalYapperIcon: View {
    let name: String
    let size: CGFloat
    init(_ name: String, size: CGFloat = 20) { self.name = name; self.size = size }

    var body: some View {
        Group {
            if name == "at" || name == "@" {
                Text("@").font(OriginalYapper.fixedFont(size, numericWeight: 700))
            } else if let definition = OriginalIconCatalog.icons[OriginalIconCatalog.aliases[name] ?? name] {
                ZStack {
                    ForEach(Array(definition.shapes.enumerated()), id: \.offset) { _, shape in
                        let path = shape.path.applying(CGAffineTransform(scaleX: size / 24, y: size / 24))
                        if definition.fill { path.fill(.foreground) }
                        path.stroke(.foreground, style: StrokeStyle(lineWidth: definition.strokeWidth * size / 24, lineCap: shape.roundCap ? .round : .butt, lineJoin: shape.roundJoin ? .round : .miter))
                    }
                }
            } else {
                // Unknown exported key: keep geometry; never substitute a different vendor's artwork.
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(name == "chevronRight" ? 180 : 0))
        .accessibilityHidden(true)
    }
}

enum OriginalIconCatalog {
    struct Definition { let shapes: [Vector]; let strokeWidth: CGFloat; let fill: Bool }
    struct Vector { let path: Path; let roundCap: Bool; let roundJoin: Bool }
    static let aliases: [String: String] = [
        "chevronLeft": "Lz", "chevronRight": "Lz", "chevronDown": "CN", "emoji": "Mo", "microphone": "p4", "volume": "nk", "inbox": "Xg", "folder": "ZD", "attach": "m2", "bell": "YM", "trophy": "WV", "accounts": "R4", "status": "HP", "search": "Px", "more": "qj", "edit": "Lw", "createGroup": "Em", "compass": "F5", "home": "GR", "servers": "c4", "settings": "Zs", "logout": "qh", "friends": "XP", "people": "XP",
        "send": "k_", "close": "sa", "phone": "TI", "hash": "Sq", "pin": "Pj", "plus": "vu"
    ]
    static let icons: [String: Definition] = {
        guard let url = OriginalYapper.resource("OriginalIconPaths", extension: "json", subdirectory: "Icons"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["icons"] as? [String: [String: Any]] else { return [:] }
        return entries.reduce(into: [:]) { result, item in
            let (key, entry) = item
            let options = entry["options"] as? [String: Any] ?? [:]
            let vectors: [Vector] = (entry["shapes"] as? [[Any]] ?? []).compactMap { shape in
                guard shape.count == 2, let tag = shape[0] as? String, let attributes = shape[1] as? [String: String] else { return nil }
                var path: Path
                if tag == "path", let d = attributes["d"] { path = SVGPath.read(d) }
                else if tag == "circle", let x = Double(attributes["cx"] ?? ""), let y = Double(attributes["cy"] ?? ""), let r = Double(attributes["r"] ?? "") {
                    path = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                } else { return nil }
                if let transform = attributes["transform"], transform.hasPrefix("matrix(") {
                    let values = transform.dropFirst(7).dropLast().split(separator: " ").compactMap { Double($0) }
                    if values.count == 6 { path = path.applying(CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])) }
                }
                return Vector(path: path, roundCap: attributes["strokeLinecap"] == "round", roundJoin: attributes["strokeLinejoin"] == "round")
            }
            result[key] = Definition(shapes: vectors, strokeWidth: (options["strokeWidth"] as? NSNumber)?.doubleValue ?? 2, fill: options["fill"] as? String == "currentColor")
        }
    }()
}

/// This artifact's complete icon vocabulary uses only absolute M/L/H/V/C/Z commands.
/// Fails closed for anything else rather than silently drawing a different shape.
private enum SVGPath {
    static func read(_ text: String) -> Path {
        let regex = try! NSRegularExpression(pattern: "[MCLHVZ]|[-+]?(?:[0-9]*\\.[0-9]+|[0-9]+\\.?)(?:[eE][-+]?[0-9]+)?")
        let range = NSRange(text.startIndex..., in: text)
        let tokens = regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        var path = Path(), index = 0, command = "", current = CGPoint.zero, origin = CGPoint.zero
        while index < tokens.count {
            if tokens[index].count == 1, tokens[index].first!.isLetter {
                command = tokens[index]; index += 1
                if command == "Z" { path.closeSubpath(); current = origin; continue }
            }
            let count = command == "C" ? 6 : (command == "H" || command == "V" ? 1 : 2)
            guard index + count <= tokens.count else { return Path() }
            let values = tokens[index..<(index + count)].compactMap(Double.init)
            guard values.count == count else { return Path() }
            switch command {
            case "M": current = CGPoint(x: values[0], y: values[1]); origin = current; path.move(to: current); command = "L"
            case "L": current = CGPoint(x: values[0], y: values[1]); path.addLine(to: current)
            case "H": current.x = values[0]; path.addLine(to: current)
            case "V": current.y = values[0]; path.addLine(to: current)
            case "C": current = CGPoint(x: values[4], y: values[5]); path.addCurve(to: current, control1: CGPoint(x: values[0], y: values[1]), control2: CGPoint(x: values[2], y: values[3]))
            default: return Path()
            }
            index += count
        }
        return path
    }
}

struct OriginalYapperButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(OriginalYapper.font(14, weight: .semibold))
            .padding(.horizontal, 16).frame(minHeight: 40)
            .foregroundStyle(primary ? YapperPalette.onAccent : YapperPalette.text)
            .background(primary ? YapperPalette.accentFill : YapperPalette.elevated, in: .rect(cornerRadius: 8))
            .padding(.vertical, 2).contentShape(.rect)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}

struct OriginalYapperTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.font(OriginalYapper.font(14)).padding(.horizontal, 12).frame(minHeight: 42)
            .foregroundStyle(YapperPalette.text).background(YapperPalette.rail, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(YapperPalette.border, lineWidth: 1))
    }
}

struct OriginalYapperToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label.font(OriginalYapper.font(14)).frame(maxWidth: .infinity, alignment: .leading)
            Capsule().fill(configuration.isOn ? YapperPalette.success : YapperPalette.active)
                .frame(width: 34, height: 18)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) { Circle().fill(.white).frame(width: 14, height: 14).padding(2) }
        }
        .frame(minHeight: 44).contentShape(.rect).onTapGesture { if isEnabled { configuration.isOn.toggle() } }
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch).disabled(!isEnabled)
        }
    }
}
